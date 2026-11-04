using Gtk;

namespace Singularity.Apps.Lettere {

    public class AgentCard : Box {
        private static bool styled = false;
        private string token;
        private Entry to;
        private Entry cc;
        private Entry subject;
        private TextView body;
        private Label status;
        private Button send;
        private Button open;

        private static string text (Json.Object o, string key) {
            return o.has_member (key) ? o.get_string_member (key) : "";
        }

        public AgentCard (Json.Object o) {
            Object (orientation: Orientation.VERTICAL, spacing: 10);
            if (!styled) {
                var css = new CssProvider ();
                css.load_from_string (ComposeFields.STYLE);
                Gtk.StyleContext.add_provider_for_display (Gdk.Display.get_default (), css, STYLE_PROVIDER_PRIORITY_USER + 1);
                styled = true;
            }
            token = text (o.get_object_member ("private"), "token");

            var fields = new Grid ();
            fields.add_css_class ("lettere-compose-fields");
            fields.column_spacing = 12;
            fields.row_spacing = 2;
            int row = 0;
            fields.attach (ComposeFields.label (_("From")), 0, row);
            var from = new Label (text (o, "from"));
            from.xalign = 0;
            from.margin_top = 8;
            from.margin_bottom = 8;
            from.margin_start = 8;
            from.ellipsize = Pango.EllipsizeMode.END;
            fields.attach (from, 1, row++);
            to = field (fields, ref row, _("To"), text (o, "to"));
            cc = field (fields, ref row, _("Cc"), text (o, "cc"));
            cc.visible = cc.text != "";
            subject = field (fields, ref row, _("Subject"), text (o, "subject"));
            append (fields);

            var card = new Box (Orientation.VERTICAL, 0);
            card.add_css_class ("lettere-compose-card");
            card.overflow = Overflow.HIDDEN;
            body = ComposeFields.body ();
            body.buffer.text = text (o, "body");
            var scroll = new ScrolledWindow ();
            scroll.hscrollbar_policy = PolicyType.NEVER;
            scroll.propagate_natural_height = true;
            scroll.min_content_height = 120;
            scroll.max_content_height = 260;
            scroll.child = body;
            card.append (scroll);
            append (card);

            var actions = new Box (Orientation.HORIZONTAL, 8);
            status = new Label ("");
            status.add_css_class ("dim-label");
            status.xalign = 0;
            status.hexpand = true;
            status.wrap = true;
            actions.append (status);
            open = new Button.with_label (_("Open in Lettere"));
            open.add_css_class ("flat");
            open.clicked.connect (open_in_lettere);
            actions.append (open);
            send = new Button.with_label (_("Send"));
            send.add_css_class ("suggested-action");
            send.clicked.connect (() => deliver.begin ());
            actions.append (send);
            append (actions);
        }

        private static Entry field (Grid fields, ref int row, string name, string value) {
            var label = ComposeFields.label (name);
            fields.attach (label, 0, row);
            var e = new Entry ();
            e.hexpand = true;
            e.text = value;
            e.update_property (AccessibleProperty.LABEL, name, -1);
            fields.attach (e, 1, row++);
            e.bind_property ("visible", label, "visible", BindingFlags.SYNC_CREATE);
            return e;
        }

        private MessageBuilder? message (out string problem) {
            problem = "";
            var b = new MessageBuilder ();
            b.to.add_all (Mime.parse_addresses (to.text));
            b.cc.add_all (Mime.parse_addresses (cc.text));
            if (b.to.size == 0 && b.cc.size == 0) {
                problem = _("Add at least one recipient");
                return null;
            }
            foreach (var list in new Gee.ArrayList<Address>[] { b.to, b.cc }) {
                foreach (var a in list) {
                    if (!a.email.contains ("@") || a.email.contains (" ")) {
                        problem = _("“%s” is not an email address").printf (a.email);
                        return null;
                    }
                }
            }
            b.from = new Address ("", "");
            b.subject = subject.text.strip ();
            b.text = body.buffer.text;
            return b;
        }

        private void lock_fields (bool locked) {
            foreach (var w in new Widget[] { to, cc, subject, body, send, open }) w.sensitive = !locked;
        }

        private async void deliver () {
            string problem;
            var b = message (out problem);
            if (b == null) {
                status.label = problem;
                return;
            }
            lock_fields (true);
            status.label = _("Sending…");
            try {
                var bus = yield Bus.get (BusType.SESSION);
                uint8[] raw = b.build (false);
                yield bus.call ("dev.sinty.lettere", "/dev/sinty/lettere", "dev.sinty.Lettere.Mail", "SendPrepared",
                    new Variant ("(s@ay)", token, new Variant.from_bytes (new VariantType ("ay"), new Bytes (raw), true)),
                    new VariantType ("(x)"), DBusCallFlags.NONE, 30000, null);
                status.label = _("Sent from the Outbox of Lettere");
            } catch (Error e) {
                bool expired = DBusError.get_remote_error (e) == "dev.sinty.Lettere.Mail.Error.Denied";
                DBusError.strip_remote_error (e);
                status.label = expired ? _("This draft expired. Open it in Lettere to send it.") : e.message;
                lock_fields (false);
            }
        }

        private void open_in_lettere () {
            var uri = new StringBuilder ("mailto:");
            uri.append (Uri.escape_string (to.text.strip (), "@,", false));
            uri.append ("?subject=");
            uri.append (Uri.escape_string (subject.text.strip (), null, false));
            if (cc.text.strip () != "") {
                uri.append ("&cc=");
                uri.append (Uri.escape_string (cc.text.strip (), "@,", false));
            }
            uri.append ("&body=");
            uri.append (Uri.escape_string (body.buffer.text, null, false));
            var info = new DesktopAppInfo ("dev.sinty.lettere.desktop");
            if (info == null) return;
            var files = new List<File> ();
            files.append (File.new_for_uri (uri.str));
            try {
                info.launch (files, null);
            } catch (Error e) {
                status.label = e.message;
            }
        }
    }

    [CCode (cname = "singularity_lettere_card_new")]
    public Widget? agent_card_new (string intent, string args, string result) {
        try {
            var root = Json.from_string (result);
            if (root == null || root.get_node_type () != Json.NodeType.OBJECT) return null;
            var o = root.get_object ();
            var hidden = o.has_member ("private") ? o.get_object_member ("private") : null;
            if (hidden == null || !hidden.has_member ("token")) return null;
            return new AgentCard (o);
        } catch (Error e) {
            return null;
        }
    }
}
