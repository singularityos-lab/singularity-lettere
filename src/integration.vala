using Gtk;
using Singularity.Widgets;

namespace Singularity.Apps.Lettere {

    namespace TasksBridge {
        public void add (string title, int64 due) {
            string text = title;
            if (due > 0) text += " " + new DateTime.from_unix_local (due).format ("%Y-%m-%d");
            try {
                var conn = Bus.get_sync (BusType.SESSION);
                var group = DBusActionGroup.get (conn, "dev.sinty.tasks", "/dev/sinty/tasks");
                group.activate_action ("add-task", new Variant.string (text));
            } catch (Error e) {
                warning ("lettere: tasks: %s", e.message);
            }
        }
    }

    namespace ContactsBridge {
        public string directory () {
            return Path.build_filename (Environment.get_user_data_dir (), "singularity", "contacts");
        }

        private string escape_value (string v) {
            return v.replace ("\\", "\\\\").replace (",", "\\,").replace (";", "\\;").replace ("\n", "\\n");
        }

        public string add (Address a) throws Error {
            string dir = directory ();
            DirUtils.create_with_parents (dir, 0700);
            string uid = Uuid.string_random ();
            string name = a.name != "" ? a.name : a.email.split ("@")[0];
            string[] parts = name.split (" ");
            string family = parts.length > 1 ? parts[parts.length - 1] : "";
            string given = parts.length > 1 ? string.joinv (" ", parts[0:parts.length - 1]) : name;
            var sb = new StringBuilder ();
            sb.append ("BEGIN:VCARD\r\nVERSION:3.0\r\n");
            sb.append ("UID:%s\r\n".printf (uid));
            sb.append ("FN:%s\r\n".printf (escape_value (name)));
            sb.append ("N:%s;%s;;;\r\n".printf (escape_value (family), escape_value (given)));
            sb.append ("EMAIL;TYPE=INTERNET:%s\r\n".printf (a.email));
            sb.append ("END:VCARD\r\n");
            string path = Path.build_filename (dir, uid + ".vcf");
            FileUtils.set_contents (path, sb.str);
            return path;
        }

        public void attach_online (ContactBook book) {
            book.extra_dirs.add (Path.build_filename (Environment.get_user_data_dir (), "singularity", "accounts"));
        }
    }

    namespace Translator {
        public async string translate (string text) throws Error {
            var conn = yield Bus.get (BusType.SESSION);
            string target = Intl.get_language_names ()[0];
            if (target.contains ("_")) target = target.substring (0, target.index_of_char ('_'));
            if (target == "C" || target == "POSIX") target = "en";
            try {
                var reply = yield conn.call ("dev.sinty.TranslateService", "/dev/sinty/TranslateService", "dev.sinty.TranslateService", "Translate",
                    new Variant ("(sss)", text, "auto", target), new VariantType ("(sss)"), DBusCallFlags.NONE, 60000, null);
                string translation, detected, provider;
                reply.get ("(sss)", out translation, out detected, out provider);
                return translation;
            } catch (Error e) {
                DBusError.strip_remote_error (e);
                if (e is DBusError.SERVICE_UNKNOWN) throw new MailError.PROTOCOL (_("the Translate app is not installed"));
                throw e;
            }
        }
    }

    public class Dictation : Object {
        private Gst.Pipeline? pipeline;
        private string path = "";
        public string problem = "";

        public bool recording {
            get { return pipeline != null; }
        }

        public bool start () {
            string? fake = Environment.get_variable ("SINGULARITY_DICTATION_AUDIO");
            if (fake != null && fake != "") {
                path = fake;
                pipeline = new Gst.Pipeline ("fake");
                return true;
            }
            unowned string[]? args = null;
            Gst.init (ref args);
            string src = Gst.ElementFactory.find ("pipewiresrc") != null ? "pipewiresrc" : (Gst.ElementFactory.find ("pulsesrc") != null ? "pulsesrc" : "autoaudiosrc");
            path = Path.build_filename (Environment.get_user_cache_dir (), "singularity-lettere", "dictation-%s.wav".printf (Uuid.string_random ()));
            DirUtils.create_with_parents (Path.get_dirname (path), 0700);
            try {
                pipeline = (Gst.Pipeline) Gst.parse_launch ("%s ! queue ! audioconvert ! audioresample ! audio/x-raw,format=S16LE,rate=16000,channels=1 ! wavenc ! filesink name=sink".printf (src));
            } catch (Error e) {
                problem = e.message;
                pipeline = null;
                return false;
            }
            pipeline.get_by_name ("sink").set ("location", path);
            if (pipeline.set_state (Gst.State.PLAYING) == Gst.StateChangeReturn.FAILURE) {
                problem = _("The microphone could not be opened");
                pipeline.set_state (Gst.State.NULL);
                pipeline = null;
                return false;
            }
            return true;
        }

        public async string stop () throws Error {
            if (pipeline == null) return "";
            bool fake = pipeline.name == "fake";
            if (!fake) {
                pipeline.send_event (new Gst.Event.eos ());
                pipeline.get_bus ().timed_pop_filtered (3 * Gst.SECOND, Gst.MessageType.EOS | Gst.MessageType.ERROR);
                pipeline.set_state (Gst.State.NULL);
            }
            pipeline = null;
            try {
                var conn = yield Bus.get (BusType.SESSION);
                string lang = Intl.get_language_names ()[0];
                if (lang.contains ("_")) lang = lang.substring (0, lang.index_of_char ('_'));
                if (lang == "C" || lang == "POSIX") lang = "auto";
                var reply = yield conn.call ("dev.sinty.Dictation", "/dev/sinty/Dictation", "dev.sinty.Dictation", "TranscribeFile",
                    new Variant ("(ss)", path, lang), new VariantType ("(s)"), DBusCallFlags.NONE, 10 * 60 * 1000, null);
                string text;
                reply.get ("(s)", out text);
                return text.strip ();
            } catch (Error e) {
                DBusError.strip_remote_error (e);
                if (e is DBusError.SERVICE_UNKNOWN) throw new MailError.PROTOCOL (_("dictation is not available in this session"));
                throw e;
            } finally {
                if (!fake) FileUtils.unlink (path);
            }
        }
    }

    public class AttachmentPreview : AppDialog {
        public signal void open_requested ();
        public signal void save_requested ();

        public AttachmentPreview (LettereApp app, Attachment a, owned AttachmentChip.DragFile provider) {
            base (app, true);
            set_title (a.filename);
            set_default_size (760, 620);
            var box = new Box (Orientation.VERTICAL, 12);
            box.margin_start = 16;
            box.margin_end = 16;
            box.margin_bottom = 16;
            box.vexpand = true;
            string ct = a.content_type.down ();
            Widget view;
            if (ct.has_prefix ("image/")) {
                try {
                    var tex = Gdk.Texture.from_bytes (a.data);
                    var pic = new Picture.for_paintable (tex);
                    pic.content_fit = ContentFit.CONTAIN;
                    pic.vexpand = true;
                    view = pic;
                } catch (Error e) {
                    view = message (_("This image could not be shown."));
                }
            } else if (ct == "application/pdf" || a.filename.down ().has_suffix (".pdf")) {
                view = pdf_view (a);
            } else if (ct.has_prefix ("text/") || ct == "application/json" || ct == "application/xml") {
                var tv = new TextView ();
                tv.editable = false;
                tv.monospace = true;
                tv.wrap_mode = WrapMode.WORD_CHAR;
                tv.buffer.text = Mime.bytes_to_string (a.data.get_data ());
                var sc = new ScrolledWindow ();
                sc.vexpand = true;
                sc.child = tv;
                view = sc;
            } else if (ct == "message/rfc822") {
                var msg = new MimeMessage (a.data.get_data ());
                var tv = new TextView ();
                tv.editable = false;
                tv.wrap_mode = WrapMode.WORD_CHAR;
                tv.buffer.text = "%s\n%s\n\n%s".printf (msg.subject, Mime.format_addresses (msg.from), msg.body_text ());
                var sc = new ScrolledWindow ();
                sc.vexpand = true;
                sc.child = tv;
                view = sc;
            } else {
                view = message (_("There is no preview for this kind of file. Open it with an app or save it."));
            }
            box.append (view);
            var row = new Box (Orientation.HORIZONTAL, 8);
            row.halign = Align.END;
            var open = new Button.with_label (_("Open With App"));
            open.add_css_class ("pill");
            open.clicked.connect (() => {
                open_requested ();
                close_dialog ();
            });
            row.append (open);
            var save = new Button.with_label (_("Save…"));
            save.add_css_class ("pill");
            save.add_css_class ("suggested-action");
            save.clicked.connect (() => save_requested ());
            row.append (save);
            box.append (row);
            content_box.append (box);
        }

        private Widget message (string text) {
            var l = new Label (text);
            l.wrap = true;
            l.vexpand = true;
            l.add_css_class ("dim-label");
            return l;
        }

        private Widget pdf_view (Attachment a) {
            try {
                var doc = new Poppler.Document.from_bytes (a.data, null);
                var pages = new Box (Orientation.VERTICAL, 12);
                int n = int.min (doc.get_n_pages (), 20);
                for (int i = 0; i < n; i++) {
                    var page = doc.get_page (i);
                    double w, h;
                    page.get_size (out w, out h);
                    double scale = 1.3;
                    var surface = new Cairo.ImageSurface (Cairo.Format.ARGB32, (int) (w * scale), (int) (h * scale));
                    var cr = new Cairo.Context (surface);
                    cr.set_source_rgb (1, 1, 1);
                    cr.paint ();
                    cr.scale (scale, scale);
                    page.render (cr);
                    surface.flush ();
                    var pic = new Picture.for_paintable (texture_of (surface));
                    pic.can_shrink = true;
                    pic.content_fit = ContentFit.CONTAIN;
                    pic.set_size_request (-1, (int) (h * 0.9));
                    pages.append (pic);
                }
                var sc = new ScrolledWindow ();
                sc.vexpand = true;
                sc.child = pages;
                return sc;
            } catch (Error e) {
                return message (_("This PDF could not be shown."));
            }
        }

        private static Gdk.Texture texture_of (Cairo.ImageSurface s) {
            var bytes = new Bytes (s.get_data ()[0:s.get_stride () * s.get_height ()]);
            return new Gdk.MemoryTexture (s.get_width (), s.get_height (), Gdk.MemoryFormat.B8G8R8A8_PREMULTIPLIED, bytes, s.get_stride ());
        }
    }
}
