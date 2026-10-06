using Gtk;
using Singularity.Widgets;

namespace Singularity.Apps.Lettere {

    public class AddressEntry : Box {
        public signal void edited ();
        public Entry entry;
        private Popover popover;
        private ListBox list;
        private LettereApp app;
        private bool applying;

        public AddressEntry (LettereApp app, string label) {
            Object (orientation: Orientation.HORIZONTAL, spacing: 0);
            this.app = app;
            entry = new Entry ();
            entry.hexpand = true;
            entry.input_purpose = InputPurpose.EMAIL;
            entry.update_property (AccessibleProperty.LABEL, label, -1);
            append (entry);
            list = new ListBox ();
            list.selection_mode = SelectionMode.BROWSE;
            list.add_css_class ("navigation-sidebar");
            list.row_activated.connect ((row) => accept (row));
            popover = new Popover ();
            popover.has_arrow = false;
            popover.autohide = false;
            popover.can_focus = false;
            popover.position = PositionType.BOTTOM;
            popover.halign = Align.START;
            popover.child = list;
            popover.set_parent (entry);
            entry.changed.connect (() => {
                if (!applying) {
                    refresh ();
                    edited ();
                }
            });
            var focus = new EventControllerFocus ();
            focus.leave.connect (() => Timeout.add (150, () => {
                popover.popdown ();
                expand_groups ();
                return Source.REMOVE;
            }));
            entry.add_controller (focus);
            var keys = new EventControllerKey ();
            keys.propagation_phase = PropagationPhase.CAPTURE;
            keys.key_pressed.connect ((keyval, code, state) => {
                if (!popover.visible) return false;
                var sel = list.get_selected_row ();
                switch (keyval) {
                    case Gdk.Key.Down:
                        var next = sel == null ? list.get_row_at_index (0) : list.get_row_at_index (sel.get_index () + 1);
                        if (next != null) list.select_row (next);
                        return true;
                    case Gdk.Key.Up:
                        if (sel != null && sel.get_index () > 0) list.select_row (list.get_row_at_index (sel.get_index () - 1));
                        return true;
                    case Gdk.Key.Return:
                    case Gdk.Key.KP_Enter:
                    case Gdk.Key.Tab:
                        if (sel != null) {
                            accept (sel);
                            return true;
                        }
                        return false;
                    case Gdk.Key.Escape:
                        popover.popdown ();
                        return true;
                }
                return false;
            });
            entry.add_controller (keys);
        }

        public void dismiss () {
            popover.popdown ();
        }

        public override void dispose () {
            if (popover != null) popover.unparent ();
            popover = null;
            base.dispose ();
        }

        private string current_token () {
            string t = entry.text;
            int comma = t.last_index_of_char (',');
            return (comma >= 0 ? t.substring (comma + 1) : t).strip ();
        }

        private void refresh () {
            string token = current_token ();
            Widget? c;
            while ((c = list.get_first_child ()) != null) list.remove (c);
            if (token.length < 1) {
                popover.popdown ();
                return;
            }
            int count = 0;
            foreach (var g in app.contacts.match_groups (token)) {
                var row = new ListBoxRow ();
                row.set_data<string> ("address", string.joinv (", ", addresses_of (g)));
                row.child = row_box (_("Group: %s").printf (g.name), ngettext ("%d person", "%d people", g.members.size).printf (g.members.size));
                list.append (row);
                count++;
            }
            var seen = new Gee.HashSet<string> ();
            var found = new Gee.ArrayList<Address> ();
            foreach (var a in app.contacts.match (token, 6)) {
                if (seen.add (a.email.down ())) found.add (a);
            }
            foreach (var a in app.store.suggest (token, 8)) {
                if (found.size >= 8) break;
                if (seen.add (a.email.down ())) found.add (a);
            }
            foreach (var a in found) {
                var row = new ListBoxRow ();
                row.set_data<string> ("address", a.to_string ());
                row.child = row_box (a.name != "" ? a.name : a.email, a.name != "" ? a.email : "");
                list.append (row);
                count++;
            }
            if (count == 0) {
                popover.popdown ();
                return;
            }
            list.select_row (list.get_row_at_index (0));
            popover.popup ();
        }

        private static string[] addresses_of (ContactGroup g) {
            string[] outv = {};
            foreach (var a in g.members) outv += a.to_string ();
            return outv;
        }

        private Widget row_box (string title, string sub) {
            var box = new Box (Orientation.VERTICAL, 0);
            box.margin_top = 4;
            box.margin_bottom = 4;
            box.margin_start = 6;
            box.margin_end = 6;
            var name = new Label (title);
            name.xalign = 0;
            box.append (name);
            if (sub != "") {
                var mail = new Label (sub);
                mail.xalign = 0;
                mail.add_css_class ("caption");
                mail.add_css_class ("dim-label");
                box.append (mail);
            }
            return box;
        }

        private void accept (ListBoxRow row) {
            string addr = row.get_data<string> ("address");
            string t = entry.text;
            int comma = t.last_index_of_char (',');
            string head = comma >= 0 ? t.substring (0, comma + 1) + " " : "";
            applying = true;
            entry.text = head + addr + ", ";
            entry.set_position (-1);
            applying = false;
            popover.popdown ();
            edited ();
        }

        private void expand_groups () {
            bool changed = false;
            var parts = new Gee.ArrayList<string> ();
            foreach (string raw in Mime.split_unquoted (entry.text, ',')) {
                string t = raw.strip ();
                if (t == "") continue;
                if (!t.contains ("@")) {
                    var g = app.contacts.group (t);
                    if (g != null) {
                        foreach (var a in g.members) parts.add (a.to_string ());
                        changed = true;
                        continue;
                    }
                }
                parts.add (t);
            }
            if (!changed) return;
            applying = true;
            entry.text = string.joinv (", ", parts.to_array ());
            applying = false;
        }

        public Gee.ArrayList<Address> addresses () {
            expand_groups ();
            return Mime.parse_addresses (entry.text);
        }

        public void set_addresses (Gee.List<Address> list) {
            applying = true;
            var parts = new Gee.ArrayList<string> ();
            foreach (var a in list) parts.add (a.to_string ());
            entry.text = string.joinv (", ", parts.to_array ());
            applying = false;
        }

        public void add_address (Address a) {
            foreach (var x in addresses ()) if (x.email.down () == a.email.down ()) return;
            applying = true;
            string t = entry.text.strip ();
            if (t != "" && !t.has_suffix (",")) t += ",";
            entry.text = (t != "" ? t + " " : "") + a.to_string ();
            applying = false;
        }
    }

    public enum ComposeMode {
        NEW,
        REPLY,
        REPLY_ALL,
        FORWARD,
        DRAFT
    }

    public class ComposerView : Box {
        public signal void changed_state ();

        public ComposeMode mode { get; private set; }
        public Account? account { get; private set; }
        public Address? identity { get; private set; }
        public Gee.ArrayList<MessageInfo> answering = new Gee.ArrayList<MessageInfo> ();
        public MessageInfo? draft;
        public bool dirty { get; private set; }
        public uint64 revision { get; private set; }
        public int importance { get; set; }
        public bool request_receipt { get; set; }
        public bool sign { get; set; }
        public bool encrypt { get; set; }
        public bool plain_mode { get; private set; }

        private LettereApp app;
        private DropDown from_drop;
        private Gee.ArrayList<Address> from_list = new Gee.ArrayList<Address> ();
        private Gee.ArrayList<Account> from_accounts = new Gee.ArrayList<Account> ();
        private Label from_label;
        private AddressEntry to;
        private AddressEntry cc;
        private AddressEntry bcc;
        private Box cc_row;
        private Box bcc_row;
        private Button cc_toggle;
        private Entry subject;
        public HtmlEditor editor;
        private TextView plain;
        private Stack body_stack;
        private Singularity.Widgets.ContextRibbon? ribbon;
        private Singularity.Widgets.RibbonSelector style_selector;
        private Singularity.Widgets.RibbonSelector font_selector;
        private Singularity.Widgets.RibbonSelector size_selector;
        private Singularity.Widgets.RibbonSelector importance_selector;
        private Singularity.Widgets.RibbonToggle plain_toggle;
        private Gdk.RGBA text_color = { 0.1f, 0.1f, 0.12f, 1 };
        private Gdk.RGBA highlight_color = { 1, 0.95f, 0.4f, 1 };
        private FlowBox attach_box;
        private Gee.ArrayList<OutgoingAttachment> files = new Gee.ArrayList<OutgoingAttachment> ();
        private string in_reply_to = "";
        private string references = "";
        private Dictation dictation = new Dictation ();
        private Singularity.Widgets.RibbonToggle dictate_toggle;
        private bool syncing_dictate;
        private Label status_label;
        private bool syncing_from;

        public ComposerView (LettereApp app) {
            Object (orientation: Orientation.VERTICAL, spacing: 10);
            this.app = app;
            add_css_class ("lettere-composer");

            var fields = new Grid ();
            fields.add_css_class ("lettere-compose-fields");
            fields.column_spacing = 12;
            fields.row_spacing = 2;
            int row = 0;
            fields.attach (field_label (_("From")), 0, row);
            var from_box = new Box (Orientation.HORIZONTAL, 0);
            from_drop = new DropDown (null, null);
            from_drop.hexpand = true;
            from_drop.halign = Align.START;
            from_drop.update_property (AccessibleProperty.LABEL, _("From"), -1);
            from_drop.notify["selected"].connect (() => {
                if (syncing_from) return;
                int i = (int) from_drop.selected;
                if (i >= 0 && i < from_list.size) switch_identity (from_accounts[i], from_list[i]);
            });
            from_label = new Label ("");
            from_label.xalign = 0;
            from_label.margin_top = 8;
            from_label.margin_bottom = 8;
            from_label.margin_start = 8;
            from_box.append (from_drop);
            from_box.append (from_label);
            fields.attach (from_box, 1, row++);

            fields.attach (field_label (_("To")), 0, row);
            var to_box = new Box (Orientation.HORIZONTAL, 6);
            to = new AddressEntry (app, _("To"));
            to.hexpand = true;
            to.edited.connect (() => mark_dirty ());
            to_box.append (to);
            cc_toggle = new Button.with_label (_("Cc and Bcc"));
            cc_toggle.add_css_class ("flat");
            cc_toggle.valign = Align.CENTER;
            cc_toggle.clicked.connect (() => {
                show_cc ();
                cc.entry.grab_focus ();
            });
            to_box.append (cc_toggle);
            fields.attach (to_box, 1, row++);

            cc = new AddressEntry (app, _("Cc"));
            cc.hexpand = true;
            cc.edited.connect (() => mark_dirty ());
            cc_row = new Box (Orientation.HORIZONTAL, 0);
            var cc_label = field_label (_("Cc"));
            fields.attach (cc_label, 0, row);
            cc_row.append (cc);
            fields.attach (cc_row, 1, row++);
            cc_row.bind_property ("visible", cc_label, "visible", BindingFlags.SYNC_CREATE);

            bcc = new AddressEntry (app, _("Bcc"));
            bcc.hexpand = true;
            bcc.edited.connect (() => mark_dirty ());
            bcc_row = new Box (Orientation.HORIZONTAL, 0);
            var bcc_label = field_label (_("Bcc"));
            fields.attach (bcc_label, 0, row);
            bcc_row.append (bcc);
            fields.attach (bcc_row, 1, row++);
            bcc_row.bind_property ("visible", bcc_label, "visible", BindingFlags.SYNC_CREATE);

            fields.attach (field_label (_("Subject")), 0, row);
            subject = new Entry ();
            subject.hexpand = true;
            subject.update_property (AccessibleProperty.LABEL, _("Subject"), -1);
            subject.changed.connect (() => mark_dirty ());
            fields.attach (subject, 1, row++);
            append (fields);

            var card = new Box (Orientation.VERTICAL, 0);
            card.add_css_class ("lettere-compose-card");
            card.overflow = Overflow.HIDDEN;
            card.vexpand = true;
            editor = new HtmlEditor (app);
            editor.changed.connect (() => mark_dirty ());
            editor.files_dropped.connect ((list) => {
                foreach (var f in list) drop_file.begin (f);
            });
            editor.mention_chosen.connect ((a) => {
                to.add_address (a);
                mark_dirty ();
            });
            plain = new TextView ();
            plain.wrap_mode = WrapMode.WORD_CHAR;
            plain.top_margin = 14;
            plain.bottom_margin = 14;
            plain.left_margin = 16;
            plain.right_margin = 16;
            plain.add_css_class ("lettere-compose-body");
            plain.update_property (AccessibleProperty.LABEL, _("Message"), -1);
            plain.buffer.changed.connect (() => mark_dirty ());
            Singularity.Text.SpellIntegration.attach (plain);
            var plain_scroll = new ScrolledWindow ();
            plain_scroll.hscrollbar_policy = PolicyType.NEVER;
            plain_scroll.child = plain;
            body_stack = new Stack ();
            body_stack.vexpand = true;
            body_stack.add_named (editor, "html");
            body_stack.add_named (plain_scroll, "plain");
            card.append (body_stack);
            status_label = new Label ("");
            status_label.xalign = 0;
            status_label.add_css_class ("caption");
            status_label.add_css_class ("dim-label");
            status_label.margin_start = 16;
            status_label.margin_bottom = 6;
            status_label.visible = false;
            card.append (status_label);
            append (card);

            attach_box = new FlowBox ();
            attach_box.selection_mode = SelectionMode.NONE;
            attach_box.column_spacing = 8;
            attach_box.row_spacing = 8;
            attach_box.max_children_per_line = 4;
            attach_box.visible = false;
            append (attach_box);

            var drop = new DropTarget (typeof (Gdk.FileList), Gdk.DragAction.COPY);
            drop.drop.connect ((v, x, y) => {
                var list = (Gdk.FileList) v.get_boxed ();
                foreach (var f in list.get_files ()) add_file.begin (f);
                return true;
            });
            add_controller (drop);
            notify["sign"].connect (() => update_status ());
            notify["encrypt"].connect (() => update_status ());
            notify["importance"].connect (() => update_status ());
            notify["request-receipt"].connect (() => update_status ());
        }

        private delegate void HtmlCommand ();

        private void cmd (Singularity.Widgets.RibbonContext c, string icon, string label, string? shortcut, owned HtmlCommand cb) {
            var b = c.add_button (icon, label);
            b.shortcut = shortcut;
            b.activated.connect (() => cb ());
        }

        private Singularity.Widgets.RibbonMenu menu (Singularity.Widgets.RibbonContext c, string icon, string label, string? tip, owned Singularity.Widgets.RibbonMenuBuilder build) {
            var m = c.add_menu (icon, label, tip);
            m.label_in_compact = true;
            m.set_builder ((owned) build);
            return m;
        }

        public void fill_ribbon (Singularity.Widgets.ContextRibbon r, Singularity.Widgets.RibbonContext message) {
            ribbon = r;
            message.add_separator ();
            menu (message, "document-edit-symbolic", _("Signature"), _("Insert a signature"), (m) => fill_signatures (m));
            dictate_toggle = message.add_toggle ("audio-input-microphone-symbolic", _("Dictate"));
            dictate_toggle.toggled.connect (() => {
                if (!syncing_dictate) toggle_dictation.begin ();
            });
            build_insert (r.add_context ("insert", _("Insert"), "insert-object-symbolic"));
            build_format (r.add_context ("format", _("Format Text"), "format-text-bold-symbolic"));
            build_options (r.add_context ("options", _("Options"), "document-properties-symbolic"));
        }

        private void build_insert (Singularity.Widgets.RibbonContext c) {
            var attach = c.add_button ("mail-attachment-symbolic", _("Attach Files"), _("Attach Files…"));
            attach.label_in_compact = true;
            attach.activated.connect (() => pick_files ());
            var cloud = c.add_button ("folder-remote-symbolic", _("Online File"), _("File from Online Account…"));
            cloud.activated.connect (() => attach_cloud.begin ());
            c.add_separator ();
            cmd (c, "insert-link-symbolic", _("Link"), "Ctrl+K", () => insert_link ());
            cmd (c, "insert-image-symbolic", _("Picture"), null, () => pick_image ());
            cmd (c, "view-grid-symbolic", _("Table"), null, () => insert_table ());
            cmd (c, "list-remove-symbolic", _("Horizontal Line"), null, () => editor.command ("InsertHorizontalRule"));
            c.add_separator ();
            menu (c, "document-edit-symbolic", _("Signature"), _("Insert a signature"), (m) => fill_signatures (m));
            menu (c, "x-office-document-symbolic", _("Template"), _("Insert a template"), (m) => {
                fill_items (m, app.templates, true);
                m.add_separator ();
                m.add_item (_("Save as Template…"), null, () => save_as_template.begin ());
            });
            menu (c, "edit-paste-symbolic", _("Quick Part"), _("Insert a Quick Part"), (m) => {
                fill_items (m, app.quick_parts, false);
                m.add_separator ();
                m.add_item (_("Save Selection as Quick Part…"), null, () => save_quick_part.begin ());
            });
        }

        private void build_format (Singularity.Widgets.RibbonContext c) {
            style_selector = c.add_selector (_("Paragraph Style"), 9);
            string[] styles = { _("Paragraph"), _("Heading 1"), _("Heading 2"), _("Heading 3"), _("Quote"), _("Code") };
            string[] tags = { "p", "h1", "h2", "h3", "blockquote", "pre" };
            for (int i = 0; i < styles.length; i++) style_selector.add_option (tags[i], styles[i]);
            style_selector.selected = "p";
            style_selector.changed.connect ((id) => editor.command ("FormatBlock", id));
            font_selector = c.add_selector (_("Font"), 9);
            string[] fonts = { "Sans", "Serif", "Monospace", "Arial", "Georgia", "Times New Roman", "Verdana", "Courier New" };
            foreach (string f in fonts) font_selector.add_option (f, f);
            font_selector.text = _("Font");
            font_selector.changed.connect ((id) => editor.command ("FontName", id));
            size_selector = c.add_selector (_("Text Size"), 6);
            string[] sizes = { _("Small"), _("Normal"), _("Large"), _("Larger"), _("Huge") };
            string[] size_values = { "2", "3", "4", "5", "6" };
            for (int i = 0; i < sizes.length; i++) size_selector.add_option (size_values[i], sizes[i]);
            size_selector.selected = "3";
            size_selector.changed.connect ((id) => editor.command ("FontSize", id));
            c.add_separator ();
            cmd (c, "format-text-bold-symbolic", _("Bold"), "Ctrl+B", () => editor.command ("Bold"));
            cmd (c, "format-text-italic-symbolic", _("Italic"), "Ctrl+I", () => editor.command ("Italic"));
            cmd (c, "format-text-underline-symbolic", _("Underline"), "Ctrl+U", () => editor.command ("Underline"));
            cmd (c, "format-text-strikethrough-symbolic", _("Strikethrough"), null, () => editor.command ("Strikethrough"));
            color_menu (c, _("Text Color"), false);
            color_menu (c, _("Highlight"), true);
            cmd (c, "edit-clear-all-symbolic", _("Clear Formatting"), null, () => editor.command ("RemoveFormat"));
            c.add_separator ();
            cmd (c, "view-list-bullet-symbolic", _("Bulleted List"), null, () => editor.command ("InsertUnorderedList"));
            cmd (c, "view-list-ordered-symbolic", _("Numbered List"), null, () => editor.command ("InsertOrderedList"));
            cmd (c, "format-indent-less-symbolic", _("Decrease Indent"), null, () => editor.command ("Outdent"));
            cmd (c, "format-indent-more-symbolic", _("Increase Indent"), null, () => editor.command ("Indent"));
            c.add_separator ();
            cmd (c, "format-justify-left-symbolic", _("Align Left"), null, () => editor.command ("JustifyLeft"));
            cmd (c, "format-justify-center-symbolic", _("Center"), null, () => editor.command ("JustifyCenter"));
            cmd (c, "format-justify-right-symbolic", _("Align Right"), null, () => editor.command ("JustifyRight"));
            cmd (c, "format-justify-fill-symbolic", _("Justify"), null, () => editor.command ("JustifyFull"));
        }

        private const string[] SWATCHES = { "#1d1d1f", "#c0392b", "#d35400", "#f1c40f", "#27ae60", "#2e86de", "#8e44ad", "#7f8c8d" };
        private const string[] HIGHLIGHTS = { "#fff26b", "#b8f5a4", "#a8e1ff", "#ffc2e2", "#ffd59e" };

        private void color_menu (Singularity.Widgets.RibbonContext c, string label, bool highlight) {
            var m = c.add_menu (null, label);
            var face = new DrawingArea ();
            face.set_size_request (16, 16);
            face.valign = Align.CENTER;
            face.set_draw_func ((a, cr, w, h) => {
                var col = highlight ? highlight_color : text_color;
                cr.arc (w / 2.0, h / 2.0, 7, 0, 2 * Math.PI);
                cr.set_source_rgba (col.red, col.green, col.blue, 1);
                cr.fill_preserve ();
                cr.set_source_rgba (0, 0, 0, 0.25);
                cr.set_line_width (1);
                cr.stroke ();
            });
            m.set_face (face);
            m.set_builder ((menu) => {
                foreach (string hex in highlight ? HIGHLIGHTS : SWATCHES) {
                    string hh = hex;
                    menu.add_widget (swatch_row (hh, () => apply_color (hh, highlight, face)));
                }
                menu.add_separator ();
                menu.add_item (_("Other Color…"), null, () => {
                    var d = new ColorDialog ();
                    d.with_alpha = false;
                    d.choose_rgba.begin (get_root () as Gtk.Window, highlight ? highlight_color : text_color, null, (o, res) => {
                        try {
                            apply_color (rgb (d.choose_rgba.end (res)), highlight, face);
                        } catch (Error e) {
                        }
                    });
                });
            });
        }

        private void apply_color (string hex, bool highlight, Widget face) {
            var col = Gdk.RGBA ();
            col.parse (hex);
            if (highlight) highlight_color = col;
            else text_color = col;
            face.queue_draw ();
            editor.command (highlight ? "HiliteColor" : "ForeColor", hex);
        }

        private Widget swatch_row (string hex, owned HtmlCommand cb) {
            var btn = new Button ();
            btn.add_css_class ("flat");
            btn.add_css_class ("menu-row");
            var box = new Box (Orientation.HORIZONTAL, 10);
            var sw = new DrawingArea ();
            sw.set_size_request (16, 16);
            sw.valign = Align.CENTER;
            sw.set_draw_func ((a, cr, w, h) => {
                var col = Gdk.RGBA ();
                col.parse (hex);
                cr.arc (w / 2.0, h / 2.0, 7, 0, 2 * Math.PI);
                cr.set_source_rgba (col.red, col.green, col.blue, 1);
                cr.fill ();
            });
            box.append (sw);
            var l = new Label (hex.up ());
            l.xalign = 0;
            l.add_css_class ("numeric");
            box.append (l);
            btn.child = box;
            btn.clicked.connect (() => {
                var pop = btn.get_ancestor (typeof (Popover)) as Popover;
                if (pop != null) pop.popdown ();
                cb ();
            });
            return btn;
        }

        private void build_options (Singularity.Widgets.RibbonContext c) {
            importance_selector = c.add_selector (_("Importance"), 16, "dialog-warning-symbolic");
            importance_selector.add_option ("0", _("Normal Importance"));
            importance_selector.add_option ("1", _("High Importance"));
            importance_selector.add_option ("-1", _("Low Importance"));
            importance_selector.selected = "0";
            importance_selector.changed.connect ((id) => importance = int.parse (id));
            notify["importance"].connect (() => importance_selector.selected = importance.to_string ());
            var receipt = c.add_toggle ("mail-read-symbolic", _("Read Receipt"), _("Request a Read Receipt"));
            receipt.label_in_compact = true;
            bind_toggle (receipt, "request-receipt");
            c.add_separator ();
            var sign_t = c.add_toggle ("security-high-symbolic", _("Sign"), _("Sign: recipients can check the message comes from you"));
            sign_t.label_in_compact = true;
            bind_toggle (sign_t, "sign");
            var enc_t = c.add_toggle ("channel-secure-symbolic", _("Encrypt"), _("Encrypt: only the recipients can read it"));
            enc_t.label_in_compact = true;
            bind_toggle (enc_t, "encrypt");
            c.add_separator ();
            plain_toggle = c.add_toggle ("text-x-generic-symbolic", _("Plain Text"), _("Plain Text: send without formatting"));
            plain_toggle.label_in_compact = true;
            plain_toggle.toggled.connect ((on) => {
                if (on != plain_mode) set_plain.begin (on);
            });
            notify["plain-mode"].connect (() => plain_toggle.active = plain_mode);
            var spell = c.add_toggle ("tools-check-spelling-symbolic", _("Check Spelling"));
            spell.label_in_compact = true;
            spell.active = app.settings.get_boolean ("spell-check");
            spell.toggled.connect ((on) => {
                app.settings.set_boolean ("spell-check", on);
                editor.web.get_context ().set_spell_checking_enabled (on);
            });
        }

        private void bind_toggle (Singularity.Widgets.RibbonToggle t, string prop) {
            t.button.bind_property ("active", this, prop, BindingFlags.BIDIRECTIONAL | BindingFlags.SYNC_CREATE);
        }

        private static string rgb (Gdk.RGBA c) {
            return "#%02x%02x%02x".printf ((int) (c.red * 255), (int) (c.green * 255), (int) (c.blue * 255));
        }

        private void update_status () {
            var parts = new Gee.ArrayList<string> ();
            if (importance > 0) parts.add (_("High importance"));
            if (importance < 0) parts.add (_("Low importance"));
            if (request_receipt) parts.add (_("Read receipt requested"));
            if (sign) parts.add (_("Signed"));
            if (encrypt) parts.add (_("Encrypted"));
            if (plain_mode) parts.add (_("Plain text"));
            status_label.label = string.joinv (" · ", parts.to_array ());
            status_label.visible = parts.size > 0;
            mark_dirty ();
        }

        private Label field_label (string text) {
            var l = new Label (text);
            l.xalign = 1;
            l.add_css_class ("lettere-field-label");
            return l;
        }

        private void mark_dirty () {
            revision++;
            dirty = true;
        }

        private void show_cc () {
            cc_row.visible = true;
            bcc_row.visible = true;
            cc_toggle.visible = false;
        }

        private void refresh_from () {
            from_list.clear ();
            from_accounts.clear ();
            string[] names = {};
            foreach (var a in app.accounts.accounts) {
                if (a.protocol == "local") continue;
                foreach (var id in a.identity_list ()) {
                    from_list.add (id);
                    from_accounts.add (a);
                    names += id.name != "" ? "%s <%s>".printf (id.name, id.email) : id.email;
                }
                foreach (string mb in a.shared_mailboxes ()) {
                    if (!mb.contains ("@")) continue;
                    var id = new Address ("", mb);
                    from_list.add (id);
                    from_accounts.add (a);
                    names += _("%s (shared)").printf (mb);
                }
            }
            syncing_from = true;
            from_drop.model = new StringList (names);
            bool many = names.length > 1;
            from_drop.visible = many;
            from_label.visible = !many;
            if (account != null && identity != null) {
                from_label.label = identity.name != "" ? "%s <%s>".printf (identity.name, identity.email) : identity.email;
                for (int i = 0; i < from_list.size; i++) {
                    if (from_accounts[i] == account && from_list[i].email.down () == identity.email.down ()) from_drop.selected = i;
                }
            }
            syncing_from = false;
        }

        private string signature_for (Account? a, bool reply) {
            if (a == null) return "";
            string name = reply ? a.sig_reply : a.sig_new;
            if (name != "") {
                var s = app.signatures.find (name);
                if (s != null) return s.html;
                return "";
            }
            if (a.signature.strip () == "") return "";
            return "-- <br>" + Html.escape (a.signature).replace ("\n", "<br>");
        }

        private void switch_identity (Account a, Address id) {
            bool account_changed = account != a;
            account = a;
            identity = id;
            if (account_changed) {
                editor.set_signature (signature_for (a, mode == ComposeMode.REPLY || mode == ComposeMode.REPLY_ALL || mode == ComposeMode.FORWARD));
                sign = a.sign_default;
                encrypt = a.encrypt_default;
            }
            refresh_from ();
            mark_dirty ();
        }

        private void reset (Account? a) {
            account = a ?? (app.accounts.accounts.size > 0 ? app.accounts.accounts[0] : null);
            identity = account != null ? account.address () : null;
            answering.clear ();
            draft = null;
            files.clear ();
            Widget? c;
            while ((c = attach_box.get_first_child ()) != null) attach_box.remove (c);
            attach_box.visible = false;
            in_reply_to = "";
            references = "";
            to.entry.text = "";
            cc.entry.text = "";
            bcc.entry.text = "";
            subject.text = "";
            plain.buffer.text = "";
            cc_row.visible = false;
            bcc_row.visible = false;
            cc_toggle.visible = true;
            importance = 0;
            request_receipt = false;
            sign = account != null && account.sign_default;
            encrypt = account != null && account.encrypt_default;
            if (plain_mode) {
                plain_mode = false;
                body_stack.visible_child_name = "html";
            }
            refresh_from ();
        }

        private void finish_start () {
            dirty = false;
            update_status ();
            dirty = false;
            changed_state ();
        }

        private string sig_block (bool reply) {
            string s = signature_for (account, reply);
            return s != "" ? "<div class=\"lettere-signature\">" + s + "</div>" : "";
        }

        public void start_new (Account? a, string to_text = "", string subject_text = "", string body_text = "") {
            reset (a);
            mode = ComposeMode.NEW;
            to.entry.text = to_text;
            subject.text = subject_text;
            string body = body_text != "" ? Html.plain_body (body_text) : "<p><br></p>";
            editor.set_html (body + sig_block (false));
            finish_start ();
            if (to_text == "") to.entry.grab_focus ();
            else subject.grab_focus ();
        }

        public void insert_body_text (string text) {
            if (plain_mode) {
                TextIter start;
                plain.buffer.get_start_iter (out start);
                plain.buffer.insert (ref start, text, -1);
                return;
            }
            editor.focus_start ();
            editor.insert_text (text);
        }

        private string prefixed (string prefix, string subj) {
            string low = subj.down ();
            if (low.has_prefix (prefix.down ())) return subj;
            return prefix + " " + subj;
        }

        private bool is_mine (string email) {
            foreach (var a in app.accounts.accounts) {
                foreach (var id in a.identity_list ()) if (id.email.down () == email.down ()) return true;
            }
            return false;
        }

        private static string body_of (string html) {
            string low = html.down ();
            int b = low.index_of ("<body");
            if (b < 0) return html;
            int s = low.index_of_char ('>', b);
            int e = low.last_index_of ("</body>");
            if (s < 0) return html;
            return e > s ? html.substring (s + 1, e - s - 1) : html.substring (s + 1);
        }

        private static string strip_dangerous (string html) {
            string outs = html;
            foreach (string tag in new string[] { "script", "style", "iframe", "object", "embed", "form" }) {
                while (true) {
                    string low = outs.down ();
                    int a = low.index_of ("<" + tag);
                    if (a < 0) break;
                    int b = low.index_of ("</" + tag + ">", a);
                    int end = b >= 0 ? b + tag.length + 3 : low.index_of_char ('>', a) + 1;
                    if (end <= a) break;
                    outs = outs.substring (0, a) + outs.substring (end);
                }
            }
            return outs;
        }

        public string original_html (MimeMessage mime) {
            if (mime.text_html != "") return strip_dangerous (body_of (Html.inline_cids (mime.text_html, mime.inline_parts)));
            return Html.plain_body (mime.text_plain);
        }

        private Address pick_identity (Account a, MimeMessage mime) {
            var ids = a.identity_list ();
            var pool = new Gee.ArrayList<Address> ();
            pool.add_all (mime.to);
            pool.add_all (mime.cc);
            foreach (var p in pool) {
                foreach (var id in ids) if (id.email.down () == p.email.down ()) return id;
            }
            return a.address ();
        }

        public void start_reply (Account a, MessageInfo m, MimeMessage mime, bool all) {
            reset (a);
            identity = pick_identity (a, mime);
            mode = all ? ComposeMode.REPLY_ALL : ComposeMode.REPLY;
            answering.add (m);
            var targets = new Gee.ArrayList<Address> ();
            var reply_to = mime.reply_to;
            bool from_me = is_mine (m.sender_email);
            if (from_me) {
                targets.add_all (mime.to);
            } else if (reply_to.size > 0) {
                targets.add_all (reply_to);
            } else {
                targets.add_all (mime.from);
            }
            to.set_addresses (targets);
            if (all) {
                var extra = new Gee.ArrayList<Address> ();
                var seen = new Gee.HashSet<string> ();
                foreach (var t in targets) seen.add (t.email.down ());
                var pool = new Gee.ArrayList<Address> ();
                if (!from_me) pool.add_all (mime.to);
                pool.add_all (mime.cc);
                foreach (var x in pool) {
                    if (is_mine (x.email) || !seen.add (x.email.down ())) continue;
                    extra.add (x);
                }
                if (extra.size > 0) {
                    cc.set_addresses (extra);
                    show_cc ();
                }
            }
            subject.text = prefixed ("Re:", mime.subject);
            in_reply_to = m.message_id;
            string refs = m.references;
            if (m.message_id != "") refs = (refs + " " + m.message_id).strip ();
            references = refs;
            string header = _("On %s, %s wrote:").printf (format_full (m.date), m.sender_display);
            editor.set_html ("<p><br></p>" + sig_block (true) + "<div class=\"lettere-quote\"><p>" + Html.escape (header) + "</p><blockquote>" + original_html (mime) + "</blockquote></div>");
            refresh_from ();
            finish_start ();
            editor.focus_start ();
        }

        public void start_forward (Account a, MessageInfo m, MimeMessage mime, bool as_attachment = false, uint8[]? raw = null) {
            reset (a);
            identity = pick_identity (a, mime);
            mode = ComposeMode.FORWARD;
            answering.add (m);
            subject.text = prefixed ("Fwd:", mime.subject);
            if (as_attachment && raw != null) {
                editor.set_html ("<p><br></p>" + sig_block (true));
                string name = (mime.subject != "" ? mime.subject : "message").replace ("/", "_") + ".eml";
                add_attachment (new OutgoingAttachment (name, "message/rfc822", new Bytes (raw)));
            } else {
                var sb = new StringBuilder ();
                sb.append ("<p><br></p>" + sig_block (true) + "<div class=\"lettere-quote\"><p>");
                sb.append (Html.escape (_("Forwarded message")) + "<br>");
                sb.append (Html.escape (_("From: %s").printf (Mime.format_addresses (mime.from))) + "<br>");
                sb.append (Html.escape (_("Date: %s").printf (format_full (m.date))) + "<br>");
                sb.append (Html.escape (_("Subject: %s").printf (mime.subject)) + "<br>");
                if (mime.to.size > 0) sb.append (Html.escape (_("To: %s").printf (Mime.format_addresses (mime.to))) + "<br>");
                sb.append ("</p>" + original_html (mime) + "</div>");
                editor.set_html (sb.str);
                foreach (var at in mime.attachments) add_attachment (new OutgoingAttachment (at.filename, at.content_type, at.data));
            }
            refresh_from ();
            finish_start ();
            to.entry.grab_focus ();
        }

        public void start_draft (Account a, MessageInfo? m, MimeMessage mime) {
            reset (a);
            mode = ComposeMode.DRAFT;
            draft = m;
            var from = mime.from;
            if (from.size > 0) {
                foreach (var id in a.identity_list ()) if (id.email.down () == from[0].email.down ()) identity = id;
            }
            to.set_addresses (mime.to);
            if (mime.cc.size > 0) {
                cc.set_addresses (mime.cc);
                show_cc ();
            }
            var bcc_list = Mime.parse_addresses (mime.root.header ("Bcc") ?? "");
            if (bcc_list.size > 0) {
                bcc.set_addresses (bcc_list);
                show_cc ();
            }
            subject.text = mime.subject;
            in_reply_to = mime.in_reply_to;
            references = mime.references;
            importance = Mime.importance_of (mime.root);
            request_receipt = mime.root.header ("Disposition-Notification-To") != null;
            editor.set_html (original_html (mime));
            foreach (var at in mime.attachments) add_attachment (new OutgoingAttachment (at.filename, at.content_type, at.data));
            refresh_from ();
            finish_start ();
            editor.focus_start ();
        }

        public void start_template (Account? a, NamedItem tpl) {
            reset (a);
            mode = ComposeMode.NEW;
            subject.text = tpl.subject;
            editor.set_html (tpl.html + sig_block (false));
            finish_start ();
            to.entry.grab_focus ();
        }

        private async void set_plain (bool on) {
            if (on == plain_mode) return;
            if (on) {
                plain.buffer.text = yield editor.get_text ();
                body_stack.visible_child_name = "plain";
            } else {
                editor.set_html (Html.plain_body (plain.buffer.text));
                body_stack.visible_child_name = "html";
            }
            plain_mode = on;
            update_status ();
        }

        public void insert_link () {
            var dlg = new ConfirmDialog (app, _("Insert Link"), null, null, _("Insert"), ConfirmDialog.ActionStyle.SUGGESTED);
            dlg.transient_for = get_root () as Gtk.Window;
            dlg.modal = true;
            var group = new PreferencesGroup ();
            var text_row = new EntryRow (_("Text"));
            group.add_row (text_row);
            var url_row = new EntryRow (_("Address"));
            url_row.text = "https://";
            group.add_row (url_row);
            dlg.custom_area.append (group);
            editor.selection_html.begin ((o, r) => {
                string sel = Html.to_text (editor.selection_html.end (r));
                text_row.text = sel;
                if (sel.has_prefix ("http")) url_row.text = sel;
            });
            dlg.response.connect ((resp) => {
                if (resp != ConfirmDialog.Response.PRIMARY) return;
                string url = url_row.text.strip ();
                if (url == "" || url == "https://") return;
                string label = text_row.text.strip () != "" ? text_row.text.strip () : url;
                editor.insert_html ("<a href=\"%s\">%s</a>".printf (Html.attr (url), Html.escape (label)));
            });
            dlg.open_dialog ();
        }

        public void toggle_style (string name) {
            switch (name) {
                case "bold": editor.command ("Bold"); break;
                case "italic": editor.command ("Italic"); break;
            }
        }

        public void toggle_list () {
            editor.command ("InsertUnorderedList");
        }

        private void pick_image () {
            var dialog = new FileDialog ();
            dialog.title = _("Insert Picture");
            var filter = new FileFilter ();
            filter.name = _("Pictures");
            filter.add_mime_type ("image/*");
            var filters = new GLib.ListStore (typeof (FileFilter));
            filters.append (filter);
            dialog.filters = filters;
            dialog.open.begin (get_root () as Gtk.Window, null, (o, res) => {
                try {
                    var f = dialog.open.end (res);
                    if (f != null) editor.insert_image.begin (f);
                } catch (Error e) {
                }
            });
        }

        private void insert_table () {
            var dlg = new ConfirmDialog (app, _("Insert Table"), null, null, _("Insert"), ConfirmDialog.ActionStyle.SUGGESTED);
            dlg.transient_for = get_root () as Gtk.Window;
            dlg.modal = true;
            var group = new PreferencesGroup ();
            var rows = new SpinRow (_("Rows"), null, 1, 50, 1, 3);
            var cols = new SpinRow (_("Columns"), null, 1, 20, 1, 3);
            group.add_row (rows);
            group.add_row (cols);
            dlg.custom_area.append (group);
            dlg.response.connect ((r) => {
                if (r == ConfirmDialog.Response.PRIMARY) editor.insert_table ((int) rows.value, (int) cols.value);
            });
            dlg.open_dialog ();
        }

        private void fill_signatures (ContextMenu m) {
            foreach (var sig in app.signatures.items) {
                string html = sig.html;
                m.add_item (sig.name, null, () => editor.set_signature (html));
            }
            if (account != null && account.signature.strip () != "") {
                m.add_item (_("Account Signature"), null, () => editor.set_signature ("-- <br>" + Html.escape (account.signature).replace ("\n", "<br>")));
            }
            m.add_separator ();
            m.add_item (_("No Signature"), null, () => editor.set_signature (""));
        }

        private void fill_items (ContextMenu m, ItemStore store, bool template) {
            if (store.items.size == 0) {
                var empty = new Label (template ? _("No templates yet") : _("No Quick Parts yet"));
                empty.add_css_class ("dim-label");
                empty.xalign = 0;
                empty.margin_start = 12;
                empty.margin_end = 12;
                empty.margin_top = 6;
                empty.margin_bottom = 6;
                m.add_widget (empty);
                return;
            }
            foreach (var it in store.items) {
                var item = it;
                m.add_item (it.name, null, () => {
                    if (template && subject.text.strip () == "" && item.subject != "") subject.text = item.subject;
                    editor.insert_html (item.html);
                });
            }
        }

        private async void save_as_template () {
            string html = yield editor.get_html ();
            ask_name (_("Save as Template"), subject.text.strip () != "" ? subject.text.strip () : _("Template"), (name) => {
                var it = app.templates.put (name);
                it.subject = subject.text;
                it.html = html;
                app.templates.save ();
                app.toast (_("Template “%s” saved").printf (name), null, null);
            });
        }

        private async void save_quick_part () {
            string html = yield editor.selection_html ();
            if (html.strip () == "") {
                app.toast (_("Select the text to keep as a Quick Part first"), null, null);
                return;
            }
            ask_name (_("Save as Quick Part"), Html.to_text (html).strip ().substring (0, int.min (24, Html.to_text (html).strip ().length)), (name) => {
                var it = app.quick_parts.put (name);
                it.html = html;
                app.quick_parts.save ();
                app.toast (_("Quick Part “%s” saved").printf (name), null, null);
            });
        }

        public delegate void NameCallback (string name);

        private void ask_name (string title, string initial, owned NameCallback cb) {
            var dlg = new ConfirmDialog (app, title, null, null, _("Save"), ConfirmDialog.ActionStyle.SUGGESTED);
            dlg.transient_for = get_root () as Gtk.Window;
            dlg.modal = true;
            var group = new PreferencesGroup ();
            var name = new EntryRow (_("Name"));
            name.text = initial;
            group.add_row (name);
            dlg.custom_area.append (group);
            dlg.response.connect ((r) => {
                if (r == ConfirmDialog.Response.PRIMARY && name.text.strip () != "") cb (name.text.strip ());
            });
            dlg.open_dialog ();
        }

        private async void attach_cloud () {
            var w = get_root () as Gtk.Window;
            var cf = yield Singularity.Accounts.CloudFileDialog.open (w, null);
            if (cf == null) return;
            var acc = Singularity.Accounts.Manager.get_default ().get_account (cf.account_id);
            var sharing = acc != null ? Singularity.Accounts.LinkSharing.for_account (acc) : null;
            if (sharing == null) {
                yield add_file (cf.local);
                return;
            }
            try {
                var link = yield sharing.create_link (cf.entry, Singularity.Accounts.LinkAccess.VIEW, null, null);
                editor.insert_html ("<p><a href=\"%s\">%s</a> (%s)</p>".printf (Html.attr (link.url), Html.escape (cf.entry.name), Html.escape (_("shared from %s").printf (acc.display_name))));
            } catch (Error e) {
                app.toast (_("Could not share %s: %s").printf (cf.entry.name, e.message), null, null);
            }
        }

        private void set_dictating (bool on) {
            syncing_dictate = true;
            dictate_toggle.active = on;
            dictate_toggle.label = on ? _("Stop Dictation") : _("Dictate");
            syncing_dictate = false;
        }

        private async void toggle_dictation () {
            if (!dictation.recording) {
                if (!dictation.start ()) {
                    set_dictating (false);
                    app.toast (_("Dictation could not start: %s").printf (dictation.problem), null, null);
                    return;
                }
                set_dictating (true);
                return;
            }
            set_dictating (false);
            try {
                string text = yield dictation.stop ();
                if (text != "") {
                    if (plain_mode) plain.buffer.insert_at_cursor (text + " ", -1);
                    else editor.insert_text (text + " ");
                }
            } catch (Error e) {
                app.toast (_("Dictation failed: %s").printf (e.message), null, null);
            }
        }

        public void pick_files () {
            var dialog = new FileDialog ();
            dialog.title = _("Attach Files");
            dialog.open_multiple.begin (get_root () as Gtk.Window, null, (o, res) => {
                try {
                    var list = dialog.open_multiple.end (res);
                    for (uint i = 0; i < list.get_n_items (); i++) add_file.begin ((File) list.get_item (i));
                } catch (Error e) {
                }
            });
        }

        private async void drop_file (File f) {
            try {
                var info = yield f.query_info_async ("standard::content-type", FileQueryInfoFlags.NONE);
                string ct = ContentType.get_mime_type (info.get_content_type () ?? "") ?? "";
                if (ct.has_prefix ("image/") && !plain_mode) {
                    yield editor.insert_image (f);
                    return;
                }
            } catch (Error e) {
            }
            yield add_file (f);
        }

        public async void add_file (File f) {
            try {
                var info = yield f.query_info_async ("standard::content-type,standard::display-name,standard::size", FileQueryInfoFlags.NONE);
                if (info.get_size () > 25 * 1024 * 1024) {
                    app.toast (_("%s is larger than 25 MB, most servers refuse such attachments. Share it from an online account instead.").printf (info.get_display_name ()), null, null);
                    return;
                }
                uint8[] data;
                string etag;
                yield f.load_contents_async (null, out data, out etag);
                string ctype = ContentType.get_mime_type (info.get_content_type () ?? "application/octet-stream") ?? "application/octet-stream";
                add_attachment (new OutgoingAttachment (info.get_display_name (), ctype, new Bytes (data)));
                mark_dirty ();
            } catch (Error e) {
                app.toast (_("Could not attach the file: %s").printf (e.message), null, null);
            }
        }

        public void add_attachment (OutgoingAttachment a) {
            files.add (a);
            var chip = new Box (Orientation.HORIZONTAL, 8);
            chip.add_css_class ("lettere-attachment");
            chip.halign = Align.START;
            var icon = new Image.from_gicon (ContentType.get_icon (ContentType.from_mime_type (a.content_type) ?? a.content_type));
            icon.pixel_size = 32;
            chip.append (icon);
            var name = new Label ("%s (%s)".printf (a.filename, format_size (a.data.get_size ())));
            name.ellipsize = Pango.EllipsizeMode.MIDDLE;
            name.max_width_chars = 30;
            chip.append (name);
            var remove = new Button.from_icon_name ("window-close-symbolic");
            remove.add_css_class ("flat");
            remove.add_css_class ("circular");
            remove.tooltip_text = _("Remove %s").printf (a.filename);
            remove.clicked.connect (() => {
                files.remove (a);
                attach_box.remove (chip.get_parent ());
                attach_box.visible = files.size > 0;
                mark_dirty ();
            });
            chip.append (remove);
            attach_box.append (chip);
            attach_box.visible = true;
        }

        public async MessageBuilder? build (out string problem) {
            problem = "";
            if (account == null) {
                problem = _("Add an account before writing a message");
                return null;
            }
            var b = new MessageBuilder ();
            b.from = identity ?? account.address ();
            b.to.add_all (to.addresses ());
            b.cc.add_all (cc.addresses ());
            b.bcc.add_all (bcc.addresses ());
            foreach (var list in new Gee.ArrayList<Address>[] { b.to, b.cc, b.bcc }) {
                foreach (var a in list) {
                    if (!a.email.contains ("@") || a.email.contains (" ")) {
                        problem = _("“%s” is not an email address").printf (a.email);
                        return null;
                    }
                }
            }
            b.subject = subject.text.strip ();
            if (plain_mode) {
                b.text = plain.buffer.text;
            } else {
                string html, text;
                try {
                    yield editor.get_body (out html, out text);
                } catch (Error e) {
                    problem = e.message;
                    return null;
                }
                string cleaned;
                string domain = account.email.contains ("@") ? account.email.substring (account.email.index_of_char ('@') + 1) : "lettere";
                HtmlEditor.extract_images (html, out cleaned, b.inline_images, domain);
                b.html = HtmlEditor.wrap_document (cleaned);
                b.text = text;
            }
            b.in_reply_to = in_reply_to;
            b.references = references;
            b.importance = importance;
            b.request_receipt = request_receipt;
            b.attachments.add_all (files);
            if (account.pgp_key != "") {
                string? ac = yield Crypto.autocrypt_header (account);
                if (ac != null) b.extra_headers.add (new HeaderField ("Autocrypt", ac));
            }
            if (sign || encrypt) {
                bool smime = account.smime_cert != "" && (account.pgp_key == "" || app.settings.get_string ("crypto-preference") == "smime");
                try {
                    b.body_override = yield Crypto.protect (b, account, sign, encrypt, smime);
                } catch (Error e) {
                    problem = e.message;
                    return null;
                }
            }
            return b;
        }

        public void script_set (string what, string value) {
            switch (what) {
                case "to":
                    to.entry.text = value;
                    to.dismiss ();
                    break;
                case "cc":
                    show_cc ();
                    cc.entry.text = value;
                    break;
                case "subject": subject.text = value; break;
                case "toolbar":
                    if (ribbon != null) ribbon.active_context = value;
                    break;
            }
            mark_dirty ();
        }

        public bool has_recipients () {
            return to.addresses ().size + cc.addresses ().size + bcc.addresses ().size > 0;
        }

        public string subject_text {
            owned get { return subject.text; }
        }

        public void mark_clean () {
            dirty = false;
        }

        public void mark_modified () {
            mark_dirty ();
        }

        public void focus_first () {
            if (to.entry.text == "") to.entry.grab_focus ();
            else editor.focus_start ();
        }
    }
}
