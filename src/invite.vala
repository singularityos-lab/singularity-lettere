using Gtk;
using Singularity.Widgets;
using Singularity.Calendar;

namespace Singularity.Apps.Lettere {

    public class CalendarInvite : Object {
        public string method = "";
        public string text = "";
        public CalendarEvent evt;

        public static CalendarInvite? from_message (MimeMessage msg) {
            foreach (var a in msg.attachments) {
                string ct = a.content_type.down ();
                if (ct != "text/calendar" && ct != "application/ics" && !a.filename.down ().has_suffix (".ics")) continue;
                var inv = parse (Mime.bytes_to_string (a.data.get_data ()));
                if (inv != null) return inv;
            }
            return null;
        }

        public static CalendarInvite? parse (string text) {
            var doc = Ics.parse (text);
            if (doc.events.size == 0) return null;
            var inv = new CalendarInvite ();
            inv.method = doc.method != "" ? doc.method : "PUBLISH";
            inv.text = text;
            inv.evt = doc.events[0];
            return inv;
        }

        public string when_text () {
            if (evt.start_time == null) return "";
            if (evt.all_day) return evt.start_time.format ("%A %e %B %Y").strip ();
            string day = evt.start_time.to_local ().format ("%A %e %B %Y").strip ();
            string end = evt.end_time != null ? evt.end_time.to_local ().format ("%H:%M") : "";
            return "%s, %s%s".printf (day, evt.start_time.to_local ().format ("%H:%M"), end != "" ? " - " + end : "");
        }

        public string status_of (string email) {
            if (evt.attendees == null) return "";
            foreach (var a in evt.attendees) if (a.email.down () == email.down ()) return a.status;
            return "";
        }
    }

    public class CalendarBridge : Object {
        private static CalendarBridge? instance;
        public CalendarManager manager;
        private bool loaded;

        public static CalendarBridge get_default () {
            if (instance == null) instance = new CalendarBridge ();
            return instance;
        }

        private CalendarBridge () {
            manager = CalendarManager.get_default ();
        }

        public void ensure () {
            if (loaded) return;
            loaded = true;
            LocalProvider.register_all (manager);
            AccountCalendars.register_all (manager);
        }

        public Gee.List<WritableCalendarProvider> writable () {
            ensure ();
            return manager.get_writable_providers ();
        }

        public WritableCalendarProvider? holder_of (string uid, out CalendarEvent? found) {
            found = null;
            foreach (var p in writable ()) {
                var e = p.find_event (uid);
                if (e != null) {
                    found = e;
                    return p;
                }
            }
            return null;
        }

        public WritableCalendarProvider? default_calendar () {
            var list = writable ();
            foreach (var p in list) if (p.id != "local-provider" && p.is_visible) return p;
            return list.size > 0 ? list[0] : null;
        }

        public async Gee.List<CalendarEvent?> busy_between (DateTime start, DateTime end) {
            ensure ();
            return yield manager.get_events (start, end);
        }
    }

    public class InviteCard : Box {
        public signal void toast (string text);

        private LettereApp app;
        private CalendarInvite invite;
        private MessageInfo? message;
        private Label status;
        private Box buttons;

        public InviteCard (LettereApp app, CalendarInvite invite, MessageInfo? message) {
            Object (orientation: Orientation.VERTICAL, spacing: 6);
            this.app = app;
            this.invite = invite;
            this.message = message;
            add_css_class ("lettere-invite");
            margin_start = 16;
            margin_end = 16;
            margin_bottom = 10;

            var head = new Box (Orientation.HORIZONTAL, 10);
            var icon = new Image.from_icon_name ("x-office-calendar");
            icon.pixel_size = 32;
            head.append (icon);
            var texts = new Box (Orientation.VERTICAL, 2);
            texts.hexpand = true;
            var title = new Label (invite.evt.title ?? _("Event"));
            title.xalign = 0;
            title.wrap = true;
            title.add_css_class ("heading");
            texts.append (title);
            var when = new Label (invite.when_text ());
            when.xalign = 0;
            when.wrap = true;
            texts.append (when);
            if (invite.evt.location != null && invite.evt.location != "") {
                var where = new Label (invite.evt.location);
                where.xalign = 0;
                where.wrap = true;
                where.add_css_class ("dim-label");
                texts.append (where);
            }
            if (invite.evt.organizer != null && invite.evt.organizer != "") {
                string org = invite.evt.organizer_name != null && invite.evt.organizer_name != "" ? invite.evt.organizer_name : invite.evt.organizer;
                var o = new Label (_("Organizer: %s").printf (org));
                o.xalign = 0;
                o.add_css_class ("caption");
                o.add_css_class ("dim-label");
                texts.append (o);
            }
            head.append (texts);
            append (head);

            status = new Label ("");
            status.xalign = 0;
            status.wrap = true;
            status.add_css_class ("caption");
            append (status);

            buttons = new Box (Orientation.HORIZONTAL, 6);
            append (buttons);
            build ();
        }

        private Account? my_account () {
            if (message != null) {
                var a = app.accounts.find (message.account);
                if (a != null) return a;
            }
            return app.accounts.accounts.size > 0 ? app.accounts.accounts[0] : null;
        }

        private string my_email () {
            var a = my_account ();
            if (a == null) return "";
            if (invite.evt.attendees != null) {
                foreach (var id in a.identity_list ()) {
                    foreach (var att in invite.evt.attendees) if (att.email.down () == id.email.down ()) return att.email;
                }
            }
            return a.email;
        }

        private Button action (string label, bool suggested, owned Callback cb) {
            var b = new Button.with_label (label);
            b.add_css_class ("pill");
            if (suggested) b.add_css_class ("suggested-action");
            b.clicked.connect (() => cb ());
            buttons.append (b);
            return b;
        }

        private delegate void Callback ();

        private void build () {
            Widget? c;
            while ((c = buttons.get_first_child ()) != null) buttons.remove (c);
            CalendarEvent? existing;
            var holder = CalendarBridge.get_default ().holder_of (invite.evt.id, out existing);
            string mine = existing != null ? status_in (existing) : invite.status_of (my_email ());
            switch (invite.method) {
                case "REQUEST":
                    status.label = holder != null ? describe (mine) + " " + _("It is in %s.").printf (holder.name) : _("You were invited. Your answer goes back to the organizer.");
                    action (_("Accept"), true, () => respond ("ACCEPTED"));
                    action (_("Tentative"), false, () => respond ("TENTATIVE"));
                    action (_("Decline"), false, () => respond ("DECLINED"));
                    action (_("Propose New Time…"), false, () => propose ());
                    break;
                case "CANCEL":
                    status.label = _("The organizer cancelled this event.");
                    if (holder != null) action (_("Remove from Calendar"), true, () => remove_event ());
                    break;
                case "REPLY":
                    string who = invite.evt.attendees != null && invite.evt.attendees.size > 0 ? invite.evt.attendees[0].display_name () : _("An attendee");
                    string st = invite.evt.attendees != null && invite.evt.attendees.size > 0 ? invite.evt.attendees[0].status : "";
                    status.label = reply_text (who, st);
                    if (holder != null) action (_("Update Calendar"), true, () => apply_reply ());
                    break;
                case "COUNTER":
                    status.label = _("An attendee proposes a new time: %s").printf (invite.when_text ());
                    if (holder != null) action (_("Accept Proposal"), true, () => accept_counter ());
                    break;
                default:
                    status.label = holder != null ? _("This event is in %s.").printf (holder.name) : "";
                    if (holder == null) action (_("Add to Calendar"), true, () => add_to_calendar (""));
                    break;
            }
            action (_("Open in Calendar"), false, () => open_calendar ());
        }

        private string status_in (CalendarEvent e) {
            if (e.attendees == null) return "";
            string me = my_email ().down ();
            foreach (var a in e.attendees) if (a.email.down () == me) return a.status;
            return "";
        }

        private static string describe (string st) {
            switch (st) {
                case "ACCEPTED": return _("You accepted.");
                case "TENTATIVE": return _("You answered tentatively.");
                case "DECLINED": return _("You declined.");
            }
            return _("You have not answered yet.");
        }

        private static string reply_text (string who, string st) {
            switch (st) {
                case "ACCEPTED": return _("%s accepted.").printf (who);
                case "TENTATIVE": return _("%s answered tentatively.").printf (who);
                case "DECLINED": return _("%s declined.").printf (who);
            }
            return _("%s answered.").printf (who);
        }

        private CalendarEvent with_status (CalendarEvent src, string st) {
            CalendarEvent e = src;
            var list = new Gee.ArrayList<CalendarAttendee> ();
            string me = my_email ();
            bool found = false;
            if (src.attendees != null) {
                foreach (var a in src.attendees) {
                    var copy = a.copy ();
                    if (a.email.down () == me.down ()) {
                        copy.status = st;
                        found = true;
                    }
                    list.add (copy);
                }
            }
            if (!found && me != "") list.add (new CalendarAttendee (me, "", st));
            e.attendees = list;
            return e;
        }

        private void add_to_calendar (string st) {
            var cal = CalendarBridge.get_default ().default_calendar ();
            if (cal == null) {
                toast (_("There is no calendar to add the event to"));
                return;
            }
            CalendarEvent e = st != "" ? with_status (invite.evt, st) : invite.evt;
            e.calendar_id = cal.id;
            CalendarEvent? existing;
            var holder = CalendarBridge.get_default ().holder_of (invite.evt.id, out existing);
            if (holder != null) holder.update_event (e);
            else cal.add_event (e);
            toast (_("Added to %s").printf (holder != null ? holder.name : cal.name));
        }

        private void respond (string st) {
            if (st == "DECLINED") {
                CalendarEvent? existing;
                var holder = CalendarBridge.get_default ().holder_of (invite.evt.id, out existing);
                if (holder != null) holder.delete_event (invite.evt.id);
            } else {
                add_to_calendar (st);
            }
            send_reply (st, Ics.reply (invite.evt, my_email (), st), "REPLY");
            build ();
        }

        private void send_reply (string st, string ics, string method) {
            var a = my_account ();
            string organizer = invite.evt.organizer ?? "";
            if (a == null || organizer == "") return;
            string word;
            switch (st) {
                case "ACCEPTED": word = _("Accepted"); break;
                case "TENTATIVE": word = _("Tentative"); break;
                case "DECLINED": word = _("Declined"); break;
                default: word = _("New Time Proposed"); break;
            }
            var b = new MessageBuilder ();
            var ident = a.address ();
            string me = my_email ();
            if (me.down () != a.email.down ()) ident = new Address (a.full_name, me);
            b.from = ident;
            b.to.add (new Address (invite.evt.organizer_name ?? "", organizer));
            b.subject = "%s: %s".printf (word, invite.evt.title ?? "");
            b.text = "%s\n\n%s\n%s".printf (word, invite.evt.title ?? "", invite.when_text ());
            var att = new OutgoingAttachment ("invite.ics", "text/calendar; method=" + method, new Bytes (ics.data));
            att.method = method;
            b.attachments.add (att);
            app.queue_message (a, b, null);
            toast (_("Your answer was sent to %s").printf (invite.evt.organizer_name != null && invite.evt.organizer_name != "" ? invite.evt.organizer_name : organizer));
        }

        private void propose () {
            var dlg = new ProposeTimeDialog (app, invite.evt);
            dlg.transient_for = get_root () as Gtk.Window;
            dlg.chosen.connect ((start, end) => {
                CalendarEvent e = with_status (invite.evt, "TENTATIVE");
                e.start_time = start;
                e.end_time = end;
                var list = new Gee.ArrayList<CalendarEvent?> ();
                list.add (e);
                send_reply ("COUNTER", Ics.serialize (list, "COUNTER"), "COUNTER");
            });
            dlg.open_dialog ();
        }

        private void remove_event () {
            CalendarEvent? existing;
            var holder = CalendarBridge.get_default ().holder_of (invite.evt.id, out existing);
            if (holder != null) holder.delete_event (invite.evt.id);
            toast (_("Removed from the calendar"));
            build ();
        }

        private void apply_reply () {
            CalendarEvent? existing;
            var holder = CalendarBridge.get_default ().holder_of (invite.evt.id, out existing);
            if (holder == null || existing == null || invite.evt.attendees == null) return;
            CalendarEvent e = existing;
            var list = new Gee.ArrayList<CalendarAttendee> ();
            if (existing.attendees != null) foreach (var a in existing.attendees) list.add (a.copy ());
            foreach (var r in invite.evt.attendees) {
                bool found = false;
                foreach (var a in list) {
                    if (a.email.down () == r.email.down ()) {
                        a.status = r.status;
                        found = true;
                    }
                }
                if (!found) list.add (r.copy ());
            }
            e.attendees = list;
            holder.update_event (e);
            toast (_("The calendar was updated"));
        }

        private void accept_counter () {
            CalendarEvent? existing;
            var holder = CalendarBridge.get_default ().holder_of (invite.evt.id, out existing);
            if (holder == null || existing == null) return;
            CalendarEvent e = existing;
            e.start_time = invite.evt.start_time;
            e.end_time = invite.evt.end_time;
            holder.update_event (e);
            var a = my_account ();
            if (a != null && existing.attendees != null) {
                var list = new Gee.ArrayList<CalendarEvent?> ();
                list.add (e);
                var b = new MessageBuilder ();
                b.from = a.address ();
                foreach (var att in existing.attendees) b.to.add (new Address (att.name, att.email));
                b.subject = _("Updated: %s").printf (e.title ?? "");
                b.text = "%s\n%s".printf (e.title ?? "", new CalendarInvite () { evt = e }.when_text ());
                var ics = new OutgoingAttachment ("invite.ics", "text/calendar; method=REQUEST", new Bytes (Ics.serialize (list, "REQUEST").data));
                ics.method = "REQUEST";
                b.attachments.add (ics);
                if (b.to.size > 0) app.queue_message (a, b, null);
            }
            toast (_("The new time was accepted and sent to the attendees"));
        }

        private void open_calendar () {
            foreach (var info in AppInfo.get_all ()) {
                if (info.get_id () != "dev.sinty.calendar.desktop") continue;
                try {
                    info.launch (null, null);
                    return;
                } catch (Error e) {
                }
            }
            toast (_("The Calendar app is not installed"));
        }
    }

    public class ProposeTimeDialog : ConfirmDialog {
        public signal void chosen (DateTime start, DateTime end);

        private Gtk.Calendar date_picker;
        private SpinButton hour;
        private SpinButton minute;
        private SpinButton length;
        private Label busy;
        private CalendarEvent evt;

        public ProposeTimeDialog (LettereApp app, CalendarEvent evt) {
            base (app, _("Propose New Time"), null, _("Your proposal goes to the organizer, who can accept it."), _("Send Proposal"), ConfirmDialog.ActionStyle.SUGGESTED);
            this.evt = evt;
            modal = true;
            var start = evt.start_time != null ? evt.start_time.to_local () : new DateTime.now_local ();
            date_picker = new Gtk.Calendar ();
            date_picker.year = start.get_year ();
            date_picker.month = start.get_month () - 1;
            date_picker.day = start.get_day_of_month ();
            custom_area.append (date_picker);
            var row = new Box (Orientation.HORIZONTAL, 8);
            row.halign = Align.CENTER;
            row.append (new Label (_("Start")));
            hour = new SpinButton.with_range (0, 23, 1);
            hour.value = start.get_hour ();
            row.append (hour);
            row.append (new Label (":"));
            minute = new SpinButton.with_range (0, 55, 5);
            minute.value = (start.get_minute () / 5) * 5;
            row.append (minute);
            row.append (new Label (_("Minutes")));
            length = new SpinButton.with_range (5, 600, 5);
            int64 dur = evt.end_time != null && evt.start_time != null ? evt.end_time.difference (evt.start_time) / TimeSpan.MINUTE : 60;
            length.value = dur > 0 ? dur : 60;
            row.append (length);
            custom_area.append (row);
            busy = new Label ("");
            busy.wrap = true;
            busy.add_css_class ("caption");
            custom_area.append (busy);
            date_picker.day_selected.connect (() => check_busy.begin ());
            hour.value_changed.connect (() => check_busy.begin ());
            minute.value_changed.connect (() => check_busy.begin ());
            length.value_changed.connect (() => check_busy.begin ());
            check_busy.begin ();
            response.connect ((r) => {
                if (r != ConfirmDialog.Response.PRIMARY) return;
                var s = picked ();
                chosen (s, s.add_minutes ((int) length.value));
            });
        }

        private DateTime picked () {
            var d = date_picker.get_date ();
            return new DateTime.local (d.get_year (), d.get_month (), d.get_day_of_month (), (int) hour.value, (int) minute.value, 0);
        }

        private async void check_busy () {
            var s = picked ();
            var e = s.add_minutes ((int) length.value);
            var events = yield CalendarBridge.get_default ().busy_between (s, e);
            var clash = new Gee.ArrayList<string> ();
            foreach (var ev in events) {
                if (ev.id == evt.id) continue;
                clash.add (ev.title ?? _("Busy"));
            }
            busy.label = clash.size == 0 ? _("You are free at this time.") : _("You are busy then: %s").printf (string.joinv (", ", clash.to_array ()));
        }
    }
}
