namespace Singularity.Apps.Lettere {

    public class HubBridge : Object {
        private const int LIMIT = 60;
        private const string PREFIX = "lettere:";

        private unowned LettereApp app;
        private DBusConnection? bus = null;
        private Gee.HashMap<string, Gee.HashSet<string>> published = new Gee.HashMap<string, Gee.HashSet<string>> ();
        private Gee.HashMap<string, string> bodies = new Gee.HashMap<string, string> ();
        private Gee.HashMap<string, string> deleted = new Gee.HashMap<string, string> ();
        private Gee.HashSet<string> dirty = new Gee.HashSet<string> ();
        private uint flush_source = 0;

        public HubBridge (LettereApp app) {
            this.app = app;
            if (app.store == null) return;
            app.store.changed.connect ((account) => schedule (account));
            app.accounts.changed.connect (() => schedule_all ());
            Singularity.Hub.install_action (app, on_action);
            Bus.get.begin (BusType.SESSION, null, (obj, res) => {
                try {
                    bus = Bus.get.end (res);
                    Bus.watch_name_on_connection (bus, Singularity.Hub.BUS_NAME, BusNameWatcherFlags.NONE,
                        () => schedule_all (), null);
                } catch (Error e) {
                    warning ("lettere: hub: %s", e.message);
                }
            });
        }

        private static string hub_account (string id) {
            return PREFIX + id;
        }

        private void schedule_all () {
            foreach (var a in app.accounts.accounts) dirty.add (a.id);
            var gone = new Gee.ArrayList<string> ();
            foreach (var id in published.keys) {
                if (app.accounts.find (id) == null) gone.add (id);
            }
            foreach (var id in gone) {
                foreach (var item in published[id]) Singularity.Hub.withdraw (hub_account (id), item);
                published.unset (id);
            }
            queue_flush ();
        }

        private void schedule (string account) {
            dirty.add (account);
            queue_flush ();
        }

        private void queue_flush () {
            if (flush_source != 0) return;
            flush_source = Timeout.add (300, () => {
                flush_source = 0;
                var accounts = dirty.to_array ();
                dirty.clear ();
                foreach (var id in accounts) {
                    var a = app.accounts.find (id);
                    if (a != null) publish_account (a);
                }
                return Source.REMOVE;
            });
        }

        private void publish_account (Account a) {
            var account = new Singularity.Hub.Account (hub_account (a.id), a.display_name, Singularity.Hub.AccountKind.EMAIL);
            account.detail = a.email;
            account.icon_name = "mail-unread-symbolic";
            account.app_id = "dev.sinty.lettere";
            Singularity.Hub.register_account (account);

            var inbox = app.store.folder_by_role (a.id, "inbox");
            if (inbox == null) return;
            var folders = new Gee.ArrayList<int64?> ();
            folders.add (inbox.id);
            var keep = new Gee.HashSet<string> ();
            foreach (var m in app.store.list (folders, false, null, LIMIT)) {
                string id = m.id.to_string ();
                keep.add (id);
                var item = new Singularity.Hub.Item (account.id, id, Singularity.Hub.ItemKind.EMAIL);
                item.sender = m.sender_display;
                item.subject = m.subject != "" ? m.subject : _("(No Subject)");
                item.preview = m.preview;
                item.timestamp = m.date;
                item.unread = m.unread;
                item.flagged = (m.flags & MessageFlags.FLAGGED) != 0;
                item.attachment = m.has_attachment;
                item.priority = m.importance > 1;
                item.app_id = "dev.sinty.lettere";
                item.body = body_of (m);
                Singularity.Hub.publish (item);
            }
            var before = published.has_key (a.id) ? published[a.id] : new Gee.HashSet<string> ();
            foreach (var id in before) {
                if (!keep.contains (id)) Singularity.Hub.withdraw (account.id, id);
            }
            published[a.id] = keep;
        }

        private string body_of (MessageInfo m) {
            string key = m.id.to_string ();
            if (bodies.has_key (key)) return bodies[key];
            var raw = app.store.body (m.id);
            if (raw == null) return m.preview;
            string text = new MimeMessage (raw).body_text ().strip ();
            bodies[key] = text;
            return text;
        }

        private void on_action (string account, string id, string action) {
            if (!account.has_prefix (PREFIX)) return;
            string account_id = account.substring (PREFIX.length);
            if (action == "restore") {
                restore (account_id, id);
                return;
            }
            var m = app.store.message (int64.parse (id));
            if (m == null) return;
            var s = app.syncs[m.account];
            var list = new Gee.ArrayList<MessageInfo> ();
            list.add (m);
            switch (action) {
                case "mark-read":
                case "mark-unread":
                    if (s != null) s.set_flag.begin (list, MessageFlags.SEEN, action == "mark-read");
                    break;
                case "flag":
                case "unflag":
                    if (s != null) s.set_flag.begin (list, MessageFlags.FLAGGED, action == "flag");
                    break;
                case "delete":
                    if (s == null) break;
                    deleted[id] = m.message_id;
                    s.ensure_folder.begin ("trash", "Trash", (o, res) => {
                        var trash = s.ensure_folder.end (res);
                        if (trash != null) s.move.begin (list, trash);
                    });
                    break;
                case "open":
                    app.activate_action ("show-message", new Variant.int64 (m.id));
                    break;
                case "reply":
                case "reply-all":
                case "forward":
                    app.respond (m.id, action);
                    break;
            }
        }

        private void restore (string account_id, string id) {
            if (!deleted.has_key (id)) return;
            string mid = deleted[id];
            deleted.unset (id);
            var m = app.store.message_by_mid (account_id, mid);
            var s = app.syncs[account_id];
            var inbox = app.store.folder_by_role (account_id, "inbox");
            if (m == null || s == null || inbox == null || m.folder == inbox.id) return;
            var list = new Gee.ArrayList<MessageInfo> ();
            list.add (m);
            s.move.begin (list, inbox);
        }
    }
}
