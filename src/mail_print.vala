namespace Singularity.Apps.Lettere {

    public class MailPrintView : Object {
        private static WebKit.WebView? shared_view;
        private static bool expect_load;
        private static bool busy;

        public static void prepare () {
            if (shared_view != null) return;
            var ws = new WebKit.Settings ();
            ws.enable_javascript = false;
            ws.enable_javascript_markup = false;
            ws.enable_html5_database = false;
            ws.enable_html5_local_storage = false;
            ws.enable_page_cache = false;
            ws.enable_webgl = false;
            ws.enable_webaudio = false;
            ws.enable_media = false;
            ws.enable_mediasource = false;
            ws.auto_load_images = true;
            ws.allow_modal_dialogs = false;
            ws.javascript_can_open_windows_automatically = false;
            ws.print_backgrounds = true;
            ws.default_charset = "utf-8";
            shared_view = (WebKit.WebView) Object.new (typeof (WebKit.WebView), "network-session", new WebKit.NetworkSession.ephemeral (), "settings", ws);
            shared_view.set_background_color ({ 1, 1, 1, 1 });
            shared_view.decide_policy.connect ((decision, type) => {
                if (type == WebKit.PolicyDecisionType.RESPONSE) return false;
                if (type == WebKit.PolicyDecisionType.NAVIGATION_ACTION && expect_load) {
                    expect_load = false;
                    decision.use ();
                    return true;
                }
                decision.ignore ();
                return true;
            });
            expect_load = true;
            shared_view.load_html ("<!DOCTYPE html><html><body></body></html>", null);
        }

        public static async WebKit.WebView acquire () {
            prepare ();
            while (busy) {
                Timeout.add (40, acquire.callback);
                yield;
            }
            busy = true;
            return shared_view;
        }

        public static void release () {
            busy = false;
        }

        public static async void load (string document) {
            var view = shared_view;
            view.stop_loading ();
            bool done = false;
            ulong handler = view.load_changed.connect ((ev) => {
                if (ev == WebKit.LoadEvent.FINISHED && !done) {
                    done = true;
                    Idle.add (load.callback);
                }
            });
            uint timer = 0;
            timer = Timeout.add_seconds (30, () => {
                timer = 0;
                if (!done) {
                    done = true;
                    view.stop_loading ();
                    load.callback ();
                }
                return Source.REMOVE;
            });
            expect_load = true;
            view.load_html (document, null);
            yield;
            if (timer != 0) Source.remove (timer);
            view.disconnect (handler);
        }

        public static string header_block (string subject, string from, string to, string cc, string date) {
            var sb = new StringBuilder ("<div class=\"lettere-print-header\">");
            sb.append ("<div class=\"lettere-print-subject\">%s</div>".printf (Html.escape (subject)));
            foreach (string line in new string[] { from, to, cc, date }) {
                if (line.strip () != "") sb.append ("<div class=\"lettere-print-line\">%s</div>".printf (Html.escape (line)));
            }
            sb.append ("</div>");
            return sb.str;
        }

        public static string print_document (string html, Gee.Map<string, Attachment> parts, bool allow_remote, string header_html, int css_width) {
            string doc = Html.document (html, parts, allow_remote);
            var style = new StringBuilder ("<style>");
            if (css_width > 0) style.append ("html{width:%dpx;min-width:%dpx;max-width:%dpx;}".printf (css_width, css_width, css_width));
            style.append ("body{margin:0;}.lettere-print-header{font-family:sans-serif;color:#1d1d1f;border-bottom:1px solid #c9c9cf;padding-bottom:10px;margin-bottom:14px;break-inside:avoid;}.lettere-print-subject{font-size:18px;font-weight:bold;margin-bottom:4px;}.lettere-print-line{font-size:12px;color:#55555c;}");
            style.append ("@media print{html,body{-webkit-print-color-adjust:exact;print-color-adjust:exact;}img{break-inside:avoid;}td:not([valign]):not([style*=\"vertical-align\"]),th:not([valign]):not([style*=\"vertical-align\"]){vertical-align:top;}}</style>");
            int head = doc.index_of ("</head>");
            if (head >= 0) doc = doc.substring (0, head) + style.str + doc.substring (head);
            int body = doc.index_of ("<body");
            if (body >= 0) {
                int close = doc.index_of (">", body);
                if (close >= 0) doc = doc.substring (0, close + 1) + header_html + doc.substring (close + 1);
            }
            return doc;
        }
    }

    public class MailPrintSource : Singularity.Print.PageSource {
        public string html { get; construct; }
        public bool allow_remote { get; construct; }
        public string header_html { get; construct; }
        private Gee.Map<string, Attachment> parts;
        private Poppler.Document? pdf;
        private MailSnapshotSource? fallback;
        private int serial;

        private static string? file_printer;
        private static bool printer_searched;

        public MailPrintSource (string title, string html, Gee.Map<string, Attachment> parts, bool allow_remote, string header_html) {
            Object (html: html, allow_remote: allow_remote, header_html: header_html);
            this.title = title;
            this.parts = parts;
        }

        public static void prepare () {
            MailPrintView.prepare ();
        }

        public static string header_block (string subject, string from, string to, string cc, string date) {
            return MailPrintView.header_block (subject, from, to, cc, date);
        }

        public override async int paginate (Singularity.Print.PageFormat format) throws Error {
            int ticket = ++serial;
            if (fallback == null) {
                string? printer = yield find_file_printer ();
                if (printer != null) {
                    try {
                        var doc = yield print_to_pdf (printer, format);
                        if (ticket != serial) throw new IOError.CANCELLED (_("A newer layout replaced this one"));
                        pdf = doc;
                        page_width = format.width;
                        page_height = format.height;
                        return int.max (doc.get_n_pages (), 1);
                    } catch (IOError.CANCELLED e) {
                        throw e;
                    } catch (Error e) {
                        warning ("print: %s", e.message);
                    }
                }
                fallback = new MailSnapshotSource (title, html, parts, allow_remote, header_html);
            }
            pdf = null;
            int n = yield fallback.paginate (format);
            if (ticket != serial) throw new IOError.CANCELLED (_("A newer layout replaced this one"));
            page_width = fallback.page_width;
            page_height = fallback.page_height;
            return n;
        }

        public override void render_page (Cairo.Context cr, int index) {
            if (pdf == null) {
                if (fallback != null) fallback.render_page (cr, index);
                return;
            }
            if (index < 0 || index >= pdf.get_n_pages ()) return;
            var page = pdf.get_page (index);
            double w, h;
            page.get_size (out w, out h);
            cr.save ();
            if (w > 0 && h > 0 && ((w - page_width).abs () > 0.5 || (h - page_height).abs () > 0.5)) {
                double s = double.min (page_width / w, page_height / h);
                cr.translate ((page_width - w * s) / 2, (page_height - h * s) / 2);
                cr.scale (s, s);
            }
            page.render_for_printing (cr);
            cr.restore ();
        }

        private static async string? find_file_printer () {
            if (printer_searched) return file_printer;
            bool done = false;
            string? found = null;
            uint timer = 0;
            timer = Timeout.add_seconds (5, () => {
                timer = 0;
                if (!done) {
                    done = true;
                    find_file_printer.callback ();
                }
                return Source.REMOVE;
            });
            Gtk.enumerate_printers ((p) => {
                if (done) return true;
                if (p.is_virtual && p.accepts_pdf) {
                    found = p.get_name ();
                    done = true;
                    Idle.add (find_file_printer.callback);
                    return true;
                }
                return false;
            }, false);
            yield;
            if (timer != 0) Source.remove (timer);
            printer_searched = true;
            file_printer = found;
            return found;
        }

        private async Poppler.Document print_to_pdf (string printer, Singularity.Print.PageFormat format) throws Error {
            var view = yield MailPrintView.acquire ();
            string path;
            try {
                int fd = FileUtils.open_tmp ("lettere-print-XXXXXX.pdf", out path);
                FileUtils.close (fd);
            } catch (Error e) {
                MailPrintView.release ();
                throw e;
            }
            var file = File.new_for_path (path);
            try {
                yield MailPrintView.load (MailPrintView.print_document (html, parts, allow_remote, header_html, 0));
                var settings = new Gtk.PrintSettings ();
                settings.set_printer (printer);
                settings.set (Gtk.PRINT_SETTINGS_OUTPUT_FILE_FORMAT, "pdf");
                settings.set (Gtk.PRINT_SETTINGS_OUTPUT_URI, file.get_uri ());
                settings.set_orientation (format.landscape ? Gtk.PageOrientation.LANDSCAPE : Gtk.PageOrientation.PORTRAIT);
                var op = new WebKit.PrintOperation (view);
                op.set_page_setup (format.to_page_setup ());
                op.set_print_settings (settings);
                bool done = false;
                bool failed = false;
                op.finished.connect (() => {
                    if (done) return;
                    done = true;
                    Idle.add (print_to_pdf.callback);
                });
                op.failed.connect (() => {
                    failed = true;
                });
                uint timer = 0;
                timer = Timeout.add_seconds (60, () => {
                    timer = 0;
                    if (!done) {
                        done = true;
                        failed = true;
                        print_to_pdf.callback ();
                    }
                    return Source.REMOVE;
                });
                op.print ();
                yield;
                if (timer != 0) Source.remove (timer);
                if (failed) throw new IOError.FAILED (_("The mail could not be laid out for printing"));
                uint8[] data;
                FileUtils.get_data (path, out data);
                if (data.length == 0) throw new IOError.FAILED (_("The mail could not be laid out for printing"));
                return new Poppler.Document.from_bytes (new Bytes (data), null);
            } finally {
                FileUtils.unlink (path);
                MailPrintView.release ();
            }
        }
    }

    public class MailSnapshotSource : Singularity.Print.SnapshotSource {
        public string html { get; construct; }
        public bool allow_remote { get; construct; }
        public string header_html { get; construct; }
        private Gee.Map<string, Attachment> parts;

        public MailSnapshotSource (string title, string html, Gee.Map<string, Attachment> parts, bool allow_remote, string header_html) {
            Object (html: html, allow_remote: allow_remote, header_html: header_html);
            this.title = title;
            this.parts = parts;
        }

        protected override async Cairo.ImageSurface render_strip (int css_width, double resolution) throws Error {
            var view = yield MailPrintView.acquire ();
            try {
                view.zoom_level = resolution;
                yield MailPrintView.load (MailPrintView.print_document (html, parts, allow_remote, header_html, css_width));
                var texture = yield view.get_snapshot (WebKit.SnapshotRegion.FULL_DOCUMENT, WebKit.SnapshotOptions.NONE, null);
                return Singularity.Print.SnapshotSource.surface_from_texture (texture);
            } finally {
                view.zoom_level = 1;
                MailPrintView.release ();
            }
        }
    }
}
