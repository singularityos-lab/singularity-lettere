using Gtk;
using Singularity.Widgets;
using Singularity.Calendar;

namespace Singularity.Apps.Lettere {

    public class DailySummary : AppDialog {
        private unowned LettereApp app;
        private CalendarManager calendars;
        private PreferencesGroup mail;
        private PreferencesGroup agenda;
        private PreferencesGroup follow;
        private ulong mail_handler;
        private ulong folder_handler;
        private ulong event_handler;
        private ulong provider_handler;
        private uint refresh_timer;
        private bool loading;
        private bool refresh_again;
        private bool closed;

        public DailySummary (LettereApp app) {
            base (app);
            this.app = app;
            title = _("Daily Summary");
            transient_for = app.main_window ();
            set_default_size (460, 520);
            var box = new Box (Orientation.VERTICAL, 12);
            box.margin_start = 16;
            box.margin_end = 16;
            box.margin_bottom = 16;
            var date = new Label (new DateTime.now_local ().format ("%A, %x"));
            date.xalign = 0;
            date.add_css_class ("heading");
            box.append (date);
            mail = new PreferencesGroup (_("Unread Mail"));
            agenda = new PreferencesGroup (_("Today's Appointments and Tasks"));
            follow = new PreferencesGroup (_("Due Follow-ups"));
            box.append (mail);
            box.append (agenda);
            box.append (follow);
            var startup = new SwitchRow (_("Show at Startup"));
            startup.switch_btn.update_property (AccessibleProperty.LABEL, _("Show at Startup"), -1);
            app.settings.bind ("startup-summary", startup.switch_btn, "active", SettingsBindFlags.DEFAULT);
            box.append (startup);
            var close = new Button.with_label (_("Close"));
            close.halign = Align.END;
            close.add_css_class ("pill");
            close.clicked.connect (() => this.close ());
            box.append (close);
            var scroll = new ScrolledWindow ();
            scroll.hscrollbar_policy = PolicyType.NEVER;
            scroll.vexpand = true;
            scroll.child = box;
            content_box.append (scroll);
            calendars = CalendarManager.get_default ();
            LocalProvider.register_all (calendars);
            WebCalendarProvider.register_all (calendars);
            AccountCalendars.register_all (calendars);
            mail_handler = app.store.changed.connect (() => queue_refresh ());
            folder_handler = app.store.folders_changed.connect (() => queue_refresh ());
            event_handler = calendars.events_changed.connect (() => queue_refresh ());
            provider_handler = calendars.providers_changed.connect (() => queue_refresh ());
            notify["is-active"].connect (() => {
                if (is_active) queue_refresh ();
            });
            ((Gtk.Widget) this).unrealize.connect (() => {
                closed = true;
                if (refresh_timer != 0) Source.remove (refresh_timer);
                app.store.disconnect (mail_handler);
                app.store.disconnect (folder_handler);
                calendars.disconnect (event_handler);
                calendars.disconnect (provider_handler);
            });
            refresh.begin ();
        }

        private void queue_refresh () {
            if (refresh_timer != 0 || closed) return;
            refresh_timer = Timeout.add (100, () => {
                refresh_timer = 0;
                refresh.begin ();
                return Source.REMOVE;
            });
        }

        private async void refresh () {
            if (closed) return;
            if (loading) {
                refresh_again = true;
                return;
            }
            loading = true;
            var now = new DateTime.now_local ();
            var start = new DateTime.local (now.get_year (), now.get_month (), now.get_day_of_month (), 0, 0, 0);
            var end = start.add_days (1);
            fill_mail ();
            fill_follow (end.to_unix () - 1);
            var events = yield calendars.get_events (start, end);
            if (!closed) {
                events.sort ((a, b) => a.start_time.compare (b.start_time));
                agenda.clear ();
                int shown = 0;
                foreach (var event in events) {
                    if (shown++ >= 8) break;
                    bool task = event.calendar_id == "local-dev.sinty.tasks" && event.id.has_prefix ("task-");
                    string when = event.all_day ? (task ? _("Due Today") : _("All Day")) : event.start_time.to_local ().format ("%R");
                    var row = new ActionRow (event.title, when, task ? "object-select-symbolic" : "x-office-calendar-symbolic");
                    row.activated.connect (() => open_event.begin (event));
                    agenda.add_row (row);
                }
                if (events.size == 0) agenda.add_row (new ActionRow (_("No appointments or tasks today")));
                if (events.size > 8) {
                    var more = new ActionRow (_("Open Calendar"), null, "go-next-symbolic");
                    more.activated.connect (() => open_day.begin (start));
                    agenda.add_row (more);
                }
            }
            loading = false;
            if (refresh_again && !closed) {
                refresh_again = false;
                queue_refresh ();
            }
        }

        private void fill_mail () {
            mail.clear ();
            int count = app.store.unread_inboxes ();
            var total = new ActionRow (ngettext ("%d Unread Message", "%d Unread Messages", count).printf (count), null, "mail-unread-symbolic");
            total.activated.connect (() => app.activate_action ("show-inbox", null));
            mail.add_row (total);
            var folders = new Gee.ArrayList<int64?> ();
            foreach (var account in app.accounts.accounts) {
                foreach (var folder in app.store.folders (account.id)) {
                    if (folder.role == "inbox") folders.add (folder.id);
                }
            }
            var options = new ListOptions ();
            options.filter = ListFilter.UNREAD;
            options.limit = 6;
            foreach (var message in app.store.list (folders, false, null, 6, options)) {
                if ((message.flags & (MessageFlags.JUNK | MessageFlags.DRAFT)) != 0) continue;
                var row = new ActionRow (message.subject != "" ? message.subject : _("(No Subject)"), message.sender_display);
                row.activated.connect (() => app.activate_action ("show-message", new Variant.int64 (message.id)));
                mail.add_row (row);
            }
        }

        private void fill_follow (int64 before) {
            follow.clear ();
            int shown = 0;
            foreach (var message in app.store.due_messages (before)) {
                if ((message.flags & (MessageFlags.DELETED | MessageFlags.JUNK)) != 0) continue;
                if (shown++ >= 6) break;
                var row = new ActionRow (message.subject != "" ? message.subject : _("(No Subject)"),
                    new DateTime.from_unix_local (message.due).format ("%x"), "flag-symbolic");
                row.activated.connect (() => app.activate_action ("show-message", new Variant.int64 (message.id)));
                follow.add_row (row);
            }
            follow.visible = shown > 0;
        }

        private async void open_event (CalendarEvent event) {
            try {
                var bus = yield Bus.get (BusType.SESSION);
                if (event.calendar_id == "local-dev.sinty.tasks" && event.id.has_prefix ("task-")) {
                    yield bus.call ("dev.sinty.tasks", "/dev/sinty/tasks/Tasks", "dev.sinty.Tasks1", "ShowTask",
                        new Variant ("(s)", event.id.substring (5)), null, DBusCallFlags.NONE, 5000, null);
                } else {
                    yield bus.call ("dev.sinty.calendar", "/dev/sinty/calendar/Calendar", "dev.sinty.Calendar1", "OpenEvent",
                        new Variant ("(ssx)", event.calendar_id, event.id, event.start_time.to_unix ()), null, DBusCallFlags.NONE, 5000, null);
                }
            } catch (Error e) {
                app.toast (_("Could not open this item: %s").printf (e.message), null, null);
            }
        }

        private async void open_day (DateTime day) {
            try {
                var bus = yield Bus.get (BusType.SESSION);
                yield bus.call ("dev.sinty.calendar", "/dev/sinty/calendar/Calendar", "dev.sinty.Calendar1", "ShowDay",
                    new Variant ("(x)", day.to_unix ()), null, DBusCallFlags.NONE, 5000, null);
            } catch (Error e) {
                app.toast (_("Could not open Calendar: %s").printf (e.message), null, null);
            }
        }
    }
}
