using Gtk;

namespace Singularity.Apps.Lettere {

    public string format_when (int64 stamp) {
        if (stamp <= 0) return "";
        var d = new DateTime.from_unix_local (stamp);
        var now = new DateTime.now_local ();
        if (d.get_year () == now.get_year () && d.get_day_of_year () == now.get_day_of_year ()) return d.format ("%H:%M");
        var yesterday = now.add_days (-1);
        if (d.get_year () == yesterday.get_year () && d.get_day_of_year () == yesterday.get_day_of_year ()) return _("Yesterday");
        if (now.difference (d) < 6 * TimeSpan.DAY) return d.format ("%a");
        if (d.get_year () == now.get_year ()) return d.format ("%e %b").strip ();
        return d.format ("%e %b %Y").strip ();
    }

    public string format_full (int64 stamp) {
        if (stamp <= 0) return "";
        return new DateTime.from_unix_local (stamp).format ("%A %e %B %Y, %H:%M");
    }

    public class MessageRow : Box {
        private Label sender;
        private Label date;
        private Label subject;
        private Label preview;
        private Label count;
        private Image star;
        private Image clip;
        private Image answered;
        private Image pin;
        private Image important;
        private Box cats;
        private Label due;
        private Widget dot;
        private MessageInfo? message;
        private ulong flags_handler;
        private LettereApp app;

        public MessageRow (LettereApp app) {
            Object (orientation: Orientation.HORIZONTAL, spacing: 10);
            this.app = app;
            var marker = new Box (Orientation.VERTICAL, 0);
            marker.valign = Align.START;
            marker.margin_top = 6;
            marker.set_size_request (8, -1);
            dot = new Box (Orientation.HORIZONTAL, 0);
            dot.add_css_class ("lettere-unread-dot");
            dot.set_size_request (8, 8);
            marker.append (dot);
            append (marker);

            var texts = new Box (Orientation.VERTICAL, 2);
            texts.hexpand = true;
            var head = new Box (Orientation.HORIZONTAL, 6);
            sender = new Label ("");
            sender.xalign = 0;
            sender.hexpand = true;
            sender.ellipsize = Pango.EllipsizeMode.END;
            sender.add_css_class ("lettere-row-sender");
            head.append (sender);
            pin = new Image.from_icon_name ("view-pin-symbolic");
            pin.pixel_size = 12;
            pin.tooltip_text = _("Pinned");
            head.append (pin);
            important = new Image.from_icon_name ("mail-mark-important-symbolic");
            important.pixel_size = 12;
            important.tooltip_text = _("High Importance");
            head.append (important);
            count = new Label ("");
            count.add_css_class ("lettere-count");
            count.valign = Align.CENTER;
            head.append (count);
            answered = new Image.from_icon_name ("mail-replied-symbolic");
            answered.pixel_size = 12;
            answered.tooltip_text = _("Replied");
            head.append (answered);
            clip = new Image.from_icon_name ("mail-attachment-symbolic");
            clip.pixel_size = 12;
            clip.tooltip_text = _("Has Attachments");
            head.append (clip);
            star = new Image.from_icon_name ("starred-symbolic");
            star.pixel_size = 12;
            star.tooltip_text = _("Starred");
            head.append (star);
            date = new Label ("");
            date.add_css_class ("lettere-row-date");
            head.append (date);
            texts.append (head);

            var subject_line = new Box (Orientation.HORIZONTAL, 6);
            subject = new Label ("");
            subject.xalign = 0;
            subject.hexpand = true;
            subject.ellipsize = Pango.EllipsizeMode.END;
            subject.add_css_class ("lettere-row-subject");
            subject_line.append (subject);
            cats = new Box (Orientation.HORIZONTAL, 3);
            cats.valign = Align.CENTER;
            subject_line.append (cats);
            due = new Label ("");
            due.add_css_class ("lettere-row-due");
            subject_line.append (due);
            texts.append (subject_line);

            preview = new Label ("");
            preview.xalign = 0;
            preview.wrap = true;
            preview.wrap_mode = Pango.WrapMode.WORD_CHAR;
            preview.lines = 2;
            preview.ellipsize = Pango.EllipsizeMode.END;
            preview.add_css_class ("lettere-row-preview");
            texts.append (preview);
            append (texts);
        }

        public void bind (MessageInfo m, bool sent_folder) {
            unbind ();
            message = m;
            if (sent_folder) {
                var to = Mime.parse_addresses (m.to_list);
                sender.label = to.size > 0 ? _("To %s").printf (Mime.display_addresses (to)) : _("No Recipients");
            } else {
                sender.label = m.thread_count > 1 && m.participants != "" ? m.participants : m.sender_display;
            }
            subject.label = m.subject != "" ? m.subject : _("(No Subject)");
            date.label = format_when (m.date);
            date.tooltip_text = format_full (m.date);
            preview.label = m.preview;
            preview.visible = m.preview != "";
            count.label = m.thread_count.to_string ();
            count.visible = m.thread_count > 1;
            clip.visible = m.has_attachment;
            important.visible = m.importance > 0;
            Widget? c;
            while ((c = cats.get_first_child ()) != null) cats.remove (c);
            foreach (string cat in m.categories ()) {
                var d = new Box (Orientation.HORIZONTAL, 0);
                d.add_css_class ("lettere-chip-dot");
                d.set_size_request (10, 10);
                d.tooltip_text = cat;
                var provider = new CssProvider ();
                provider.load_from_string ("box { background-color: %s; }".printf (app.categories.color_of (cat)));
                d.get_style_context ().add_provider (provider, STYLE_PROVIDER_PRIORITY_APPLICATION);
                cats.append (d);
            }
            cats.visible = cats.get_first_child () != null;
            flags_handler = m.notify["flags"].connect (sync);
            sync ();
        }

        private void sync () {
            if (message == null) return;
            bool unread = message.unread || message.thread_unread;
            dot.opacity = unread ? 1 : 0;
            star.visible = message.flagged || message.thread_flagged;
            star.icon_name = message.completed ? "object-select-symbolic" : "starred-symbolic";
            star.tooltip_text = message.completed ? _("Completed") : _("Flagged");
            answered.visible = (message.flags & MessageFlags.ANSWERED) != 0;
            answered.icon_name = (message.flags & MessageFlags.FORWARDED) != 0 && (message.flags & MessageFlags.ANSWERED) == 0 ? "mail-forward-symbolic" : "mail-replied-symbolic";
            if ((message.flags & MessageFlags.FORWARDED) != 0) answered.visible = true;
            pin.visible = message.pinned;
            bool overdue = message.due > 0 && !message.completed && message.flagged;
            due.visible = overdue;
            if (overdue) {
                due.label = format_when (message.due);
                if (message.due < new DateTime.now_utc ().to_unix ()) due.add_css_class ("overdue");
                else due.remove_css_class ("overdue");
            }
            if (unread) {
                sender.add_css_class ("unread");
                subject.add_css_class ("unread");
            } else {
                sender.remove_css_class ("unread");
                subject.remove_css_class ("unread");
            }
            string state = unread ? _("Unread") : _("Read");
            update_property (AccessibleProperty.LABEL, "%s, %s, %s, %s".printf (sender.label, subject.label, date.label, state), -1);
        }

        public void unbind () {
            if (message != null && flags_handler != 0) message.disconnect (flags_handler);
            flags_handler = 0;
            message = null;
        }
    }

    public class AttachmentChip : Box {
        public signal void open_requested ();
        public signal void save_requested ();

        public AttachmentChip (Attachment a, owned DragFile provider) {
            Object (orientation: Orientation.HORIZONTAL, spacing: 8);
            add_css_class ("lettere-attachment");
            var icon = new Image.from_gicon (ContentType.get_icon (ContentType.from_mime_type (a.content_type) ?? a.content_type));
            icon.pixel_size = 32;
            append (icon);
            var texts = new Box (Orientation.VERTICAL, 0);
            texts.valign = Align.CENTER;
            var name = new Label (a.filename);
            name.xalign = 0;
            name.ellipsize = Pango.EllipsizeMode.MIDDLE;
            name.max_width_chars = 28;
            texts.append (name);
            var size = new Label (format_size (a.data.get_size ()));
            size.xalign = 0;
            size.add_css_class ("dim-label");
            size.add_css_class ("caption");
            texts.append (size);
            append (texts);
            var open = new Button.from_icon_name ("document-open-symbolic");
            open.add_css_class ("flat");
            open.add_css_class ("circular");
            open.valign = Align.CENTER;
            open.tooltip_text = _("Open %s").printf (a.filename);
            open.clicked.connect (() => open_requested ());
            append (open);
            var save = new Button.from_icon_name ("document-save-symbolic");
            save.add_css_class ("flat");
            save.add_css_class ("circular");
            save.valign = Align.CENTER;
            save.tooltip_text = _("Save %s").printf (a.filename);
            save.clicked.connect (() => save_requested ());
            append (save);
            var drag = new DragSource ();
            drag.actions = Gdk.DragAction.COPY;
            drag.prepare.connect ((x, y) => {
                var file = provider ();
                if (file == null) return null;
                var list = new Gdk.FileList.from_array ({ file });
                var v = Value (typeof (Gdk.FileList));
                v.set_boxed (list);
                return new Gdk.ContentProvider.for_value (v);
            });
            drag.drag_begin.connect ((d) => {
                var paintable = new WidgetPaintable (icon);
                drag.set_icon (paintable, 16, 16);
            });
            add_controller (drag);
            var click = new GestureClick ();
            click.button = 1;
            click.released.connect ((n, x, y) => {
                if (n == 2) open_requested ();
            });
            add_controller (click);
        }

        public delegate File? DragFile ();
    }
}
