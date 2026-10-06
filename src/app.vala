using Gtk;

namespace Singularity.Apps.Lettere {

    public class LettereApp : Singularity.Application {
        public GLib.Settings settings;
        public Store store;
        public AccountStore accounts;
        public ContactBook contacts;
        public OnlineMail online;
        public RuleStore rules;
        public CategoryStore categories;
        public ItemStore templates;
        public ItemStore quick_parts;
        public ItemStore signatures;
        public JunkFilter junk;
        public signal void style_changed ();
        public signal void new_mail_arrived (Gee.List<MessageInfo> list);
        public signal void rules_ran (int count);
        public Gee.HashMap<string, AccountSync> syncs = new Gee.HashMap<string, AccountSync> ();
        public signal void syncs_changed ();
        public signal void outbox_changed ();
        public signal void outbox_result (int64 id, string error);
        private MailService? mail_service;
        public signal void toast (string text, string? action_label, owned ToastAction? action);

        public delegate void ToastAction ();

        private uint sync_timer;
        private uint outbox_timer;
        private uint minute_timer;
        private Gee.HashSet<int64?> sending = new Gee.HashSet<int64?> ((v) => int64_hash (v), (a, b) => a == b);
        private Gee.HashMap<int64?, SentHook> sent_hooks = new Gee.HashMap<int64?, SentHook> ((v) => int64_hash (v), (a, b) => a == b);

        public class SentHook {
            public string account;
            public Gee.ArrayList<MessageInfo> answered = new Gee.ArrayList<MessageInfo> ();
            public int flag;
            public MessageInfo? draft;
        }

        public LettereApp () {
            Object (application_id: "dev.sinty.lettere", flags: ApplicationFlags.HANDLES_OPEN);
        }

        public static string data_dir () {
            return Path.build_filename (Environment.get_user_data_dir (), "singularity-lettere");
        }

        protected override void startup () {
            base.startup ();
            Environment.set_application_name ("Lettere");
            settings = new GLib.Settings ("dev.sinty.lettere");
            try {
                store = new Store (Path.build_filename (data_dir (), "cache.db"));
            } catch (Error e) {
                critical ("lettere: %s", e.message);
            }
            accounts = new AccountStore (data_dir ());
            contacts = new ContactBook ();
            rules = new RuleStore (data_dir ());
            categories = new CategoryStore (data_dir ());
            templates = new ItemStore (data_dir (), "templates.json");
            quick_parts = new ItemStore (data_dir (), "quick-parts.json");
            signatures = new ItemStore (data_dir (), "signatures.json");
            junk = new JunkFilter (store);
            ContactsBridge.attach_online (contacts);
            rules.changed.connect (() => upload_server_rules.begin ());
            Gtk.Settings.get_default ().notify["gtk-application-prefer-dark-theme"].connect (() => style_changed ());
            settings.changed["dark-messages"].connect (() => style_changed ());
            online = new OnlineMail (this);
            foreach (var a in accounts.accounts) start_sync (a);
            accounts.changed.connect (() => {
                foreach (var a in accounts.accounts) {
                    if (!syncs.has_key (a.id)) start_sync (a);
                }
                var gone = new Gee.ArrayList<string> ();
                foreach (var id in syncs.keys) {
                    if (accounts.find (id) == null) gone.add (id);
                }
                foreach (var id in gone) {
                    syncs[id].stop ();
                    syncs.unset (id);
                    store.remove_account (id);
                }
                syncs_changed ();
            });
            settings.changed["work-offline"].connect (apply_offline);
            settings.changed["sync-interval"].connect (restart_timer);
            settings.changed["cache-limit"].connect (() => store.prune ((int64) settings.get_int ("cache-limit") * 1024 * 1024));
            NetworkMonitor.get_default ().network_changed.connect ((available) => {
                foreach (var s in syncs.values) s.network_changed (available);
            });
            online.start.begin ();
            restart_timer ();
            outbox_timer = Timeout.add_seconds (1, () => {
                pump_outbox ();
                return Source.CONTINUE;
            });
            minute_timer = Timeout.add_seconds (30, () => {
                wake_snoozed.begin ();
                remind_follow_ups ();
                return Source.CONTINUE;
            });

            Singularity.Application.add_app_css (CSS);
            build_menu ();
            rebuild_folder_menu ();
            store.folders_changed.connect ((acc) => rebuild_folder_menu ());
            syncs_changed.connect (() => rebuild_folder_menu ());

            var show = new SimpleAction ("show-message", VariantType.INT64);
            show.activate.connect ((v) => {
                var w = main_window ();
                w.present ();
                w.show_message_id (v.get_int64 ());
            });
            add_action (show);
            var show_inbox = new SimpleAction ("show-inbox", null);
            show_inbox.activate.connect (() => {
                var w = main_window ();
                w.present ();
                w.show_unified ();
            });
            add_action (show_inbox);
            var compose_files = new SimpleAction ("compose-files", new VariantType ("as"));
            compose_files.activate.connect ((v) => compose_shared.begin (v.dup_strv (), null));
            add_action (compose_files);
            var compose_text = new SimpleAction ("compose-text", VariantType.STRING);
            compose_text.activate.connect ((v) => compose_shared.begin ({}, v.get_string ()));
            add_action (compose_text);
        }

        private async void compose_shared (owned string[] uris, string? text) {
            var w = main_window ();
            w.present ();
            hold ();
            yield online.start ();
            release ();
            if (text != null) {
                w.compose_text (text);
                return;
            }
            var list = new File[0];
            foreach (string uri in uris) list += File.new_for_uri (uri);
            w.compose_files (list);
        }

        protected override void shutdown () {
            foreach (var s in syncs.values) s.stop ();
            base.shutdown ();
        }

        private GLib.Menu folder_section;

        private GLib.Menu section (string[,] items) {
            var m = new GLib.Menu ();
            for (int i = 0; i < items.length[0]; i++) m.append (items[i, 0], items[i, 1]);
            return m;
        }

        private void build_menu () {
            var menu = new GLib.Menu ();
            var file = new GLib.Menu ();
            file.append_section (null, section ({ { _("New Message"), "win.compose" }, { _("New Message from Template…"), "win.new-from-template" }, { _("Open Draft"), "win.edit-draft" }, { _("Save Draft"), "win.save-draft" }, { _("Send Later…"), "win.send-later" } }));
            file.append_section (null, section ({ { _("Open Message File…"), "win.open-file" }, { _("Save Message As…"), "win.save-message" }, { _("Import Mail…"), "win.import" }, { _("Export Folder…"), "win.export" }, { _("Mail Merge…"), "win.mail-merge" } }));
            file.append_section (null, section ({ { _("Print…"), "win.print" }, { _("Print Conversation…"), "win.print-conversation" } }));
            file.append_section (null, section ({ { _("Close Window"), "win.close" }, { _("Quit"), "app.quit" } }));
            menu.append_submenu (_("File"), file);

            var edit = new GLib.Menu ();
            edit.append_section (null, section ({ { _("Undo"), "win.undo" }, { _("Redo"), "win.redo" } }));
            edit.append_section (null, section ({ { _("Cut"), "win.cut" }, { _("Copy"), "win.copy" }, { _("Paste"), "win.paste" }, { _("Select All"), "win.select-all" } }));
            edit.append_section (null, section ({ { _("Find"), "win.find" }, { _("Settings"), "app.settings" } }));
            menu.append_submenu (_("Edit"), edit);

            var view = new GLib.Menu ();
            view.append_section (null, section ({ { _("All Inboxes"), "win.unified" }, { _("Outbox"), "win.outbox" } }));
            folder_section = new GLib.Menu ();
            view.append_section (null, folder_section);
            view.append_section (null, section ({ { _("Show Sidebar"), "win.sidebar" }, { _("Conversation View"), "win.conversations" }, { _("Focused Inbox"), "win.focused-inbox" }, { _("Dark Messages"), "win.dark-messages" } }));
            var pane = new GLib.Menu ();
            string[,] panes = { { _("Reading Pane on the Right"), "right" }, { _("Reading Pane Below"), "bottom" }, { _("No Reading Pane"), "off" } };
            for (int i = 0; i < panes.length[0]; i++) {
                var it = new GLib.MenuItem (panes[i, 0], null);
                it.set_action_and_target_value ("win.reading-pane", new Variant.string (panes[i, 1]));
                pane.append_item (it);
            }
            view.append_section (null, pane);
            view.append_section (null, section ({ { _("Zoom In"), "win.zoom-in" }, { _("Zoom Out"), "win.zoom-out" }, { _("Actual Size"), "win.zoom-reset" } }));
            view.append_section (null, section ({ { _("Load Images"), "win.load-images" }, { _("View Source"), "win.view-source" }, { _("Next Message"), "win.next" }, { _("Previous Message"), "win.previous" } }));
            menu.append_submenu (_("View"), view);

            var message = new GLib.Menu ();
            message.append_section (null, section ({ { _("Reply"), "win.reply" }, { _("Reply All"), "win.reply-all" }, { _("Forward"), "win.forward" }, { _("Forward as Attachment"), "win.forward-attachment" }, { _("Redirect…"), "win.redirect" }, { _("Edit as New Message"), "win.edit-as-new" } }));
            var follow = section ({ { _("Today"), "win.flag-today" }, { _("Tomorrow"), "win.flag-tomorrow" }, { _("This Week"), "win.flag-week" }, { _("Next Week"), "win.flag-next-week" }, { _("Choose a Date…"), "win.flag-date" }, { _("Mark Complete"), "win.flag-complete" }, { _("Clear Flag"), "win.flag-clear" } });
            var m2 = section ({ { _("Mark as Read or Unread"), "win.toggle-read" }, { _("Flag"), "win.toggle-star" }, { _("Pin"), "win.pin" } });
            m2.append_submenu (_("Follow Up"), follow);
            message.append_section (null, m2);
            message.append_section (null, section ({ { _("Move To…"), "win.move" }, { _("Copy To…"), "win.copy-to" }, { _("Archive"), "win.archive" }, { _("Delete"), "win.delete" }, { _("Spam"), "win.junk" }, { _("Not Spam"), "win.not-junk" }, { _("Block Sender"), "win.block-sender" }, { _("Ignore Conversation"), "win.ignore" }, { _("Sweep…"), "win.sweep" } }));
            message.append_section (null, section ({ { _("Move to Focused"), "win.move-focused" }, { _("Move to Other"), "win.move-other" } }));
            message.append_section (null, section ({ { _("Translate"), "win.translate" }, { _("Read Aloud"), "win.read-aloud" }, { _("Open in New Window"), "win.open-window" }, { _("Add Sender to Contacts"), "win.add-contact" }, { _("Add to Tasks"), "win.add-task" }, { _("Unsubscribe"), "win.unsubscribe" } }));
            menu.append_submenu (_("Message"), message);

            var tools = new GLib.Menu ();
            tools.append_section (null, section ({ { _("Rules…"), "win.rules" }, { _("Create Rule from Message…"), "win.new-rule" }, { _("Run Rules Now"), "win.run-rules" }, { _("Quick Steps…"), "win.quick-steps" } }));
            tools.append_section (null, section ({ { _("Categories…"), "win.categories" }, { _("Templates…"), "win.templates" }, { _("Signatures…"), "win.signatures" } }));
            tools.append_section (null, section ({ { _("Automatic Replies…"), "win.auto-reply" } }));
            menu.append_submenu (_("Tools"), tools);

            var account = new GLib.Menu ();
            account.append_section (null, section ({ { _("Add Account…"), "win.add-account" }, { _("Sync Now"), "win.sync" }, { _("Account Settings…"), "win.edit-account" } }));
            account.append_section (null, section ({ { _("New Folder…"), "win.new-folder" }, { _("Open Shared Mailbox…"), "win.open-shared" }, { _("Mark All as Read"), "win.mark-all-read" }, { _("Empty Folder…"), "win.empty-folder" } }));
            account.append_section (null, section ({ { _("Work Offline"), "win.offline" } }));
            menu.append_submenu (_("Account"), account);

            var help = new GLib.Menu ();
            help.append (_("About Lettere"), "app.about");
            menu.append_submenu (_("Help"), help);
            set_menubar (menu);

            var quit = new SimpleAction ("quit", null);
            quit.activate.connect (() => {
                var windows = new Gee.ArrayList<Gtk.Window> ();
                foreach (var w in get_windows ()) windows.add (w);
                foreach (var w in windows) w.close ();
            });
            add_action (quit);
            var settings_action = new SimpleAction ("settings", null);
            settings_action.activate.connect (() => {
                try {
                    Singularity.Shell.ShellService shell = Bus.get_proxy_sync (BusType.SESSION, "dev.sinty.desktop", "/dev/sinty/Shell");
                    shell.open_app_settings ("dev.sinty.lettere");
                } catch (Error e) {
                    warning ("Failed to open settings: %s", e.message);
                    toast (_("The Settings app is not available"), null, null);
                }
            });
            add_action (settings_action);
            about_name = "Lettere";
            about_version = "0.1.0";
            about_description = _("Read and write email with any IMAP and SMTP account, online or offline.");
            about_website = "https://github.com/singularityos-lab/singularity-desktop";
            about_license = _("GNU General Public License, version 3 only");

            set_accels_for_action ("app.quit", { "<Control>q" });
            set_accels_for_action ("app.settings", { "<Control>comma" });
            set_accels_for_action ("win.compose", { "<Control>n" });
            set_accels_for_action ("win.save-draft", { "<Control>s" });
            set_accels_for_action ("win.open-file", { "<Control>o" });
            set_accels_for_action ("win.print", { "<Control>p" });
            set_accels_for_action ("win.close", { "<Control>w" });
            set_accels_for_action ("win.undo", { "<Control>z" });
            set_accels_for_action ("win.redo", { "<Control><Shift>z" });
            set_accels_for_action ("win.cut", { "<Control>x" });
            set_accels_for_action ("win.copy", { "<Control>c" });
            set_accels_for_action ("win.paste", { "<Control>v" });
            set_accels_for_action ("win.select-all", { "<Control>a" });
            set_accels_for_action ("win.find", { "<Control>f" });
            set_accels_for_action ("win.unified", { "<Control>0" });
            set_accels_for_action ("win.sidebar", { "F9" });
            set_accels_for_action ("win.load-images", { "<Control><Shift>i" });
            set_accels_for_action ("win.next", { "<Alt>Down" });
            set_accels_for_action ("win.previous", { "<Alt>Up" });
            set_accels_for_action ("win.reply", { "<Control>r" });
            set_accels_for_action ("win.reply-all", { "<Control><Shift>r" });
            set_accels_for_action ("win.forward", { "<Control>l" });
            set_accels_for_action ("win.toggle-read", { "<Control>u" });
            set_accels_for_action ("win.toggle-star", { "<Control>d" });
            set_accels_for_action ("win.move", { "<Control><Shift>m" });
            set_accels_for_action ("win.archive", { "<Control>e" });
            set_accels_for_action ("win.delete", { "Delete" });
            set_accels_for_action ("win.junk", { "<Control>j" });
            set_accels_for_action ("win.sync", { "F5" });
            set_accels_for_action ("win.copy-to", { "<Control><Shift>c" });
            set_accels_for_action ("win.forward-attachment", { "<Control><Alt>f" });
            set_accels_for_action ("win.print-conversation", { "<Control><Shift>p" });
            set_accels_for_action ("win.zoom-in", { "<Control>plus", "<Control>equal" });
            set_accels_for_action ("win.zoom-out", { "<Control>minus" });
            set_accels_for_action ("win.flag-today", { "<Control><Shift>g" });
            set_accels_for_action ("win.new-folder", { "<Control><Shift>e" });
            set_accels_for_action ("win.send-later", { "<Control><Shift>Return" });
            set_accels_for_action ("win.translate", { "<Control><Shift>t" });
            set_accels_for_action ("win.view-source", { "<Control><Shift>u" });
            set_accels_for_action ("win.not-junk", { "<Control><Shift>j" });
        }

        public void rebuild_folder_menu () {
            if (folder_section == null) return;
            folder_section.remove_all ();
            bool many = accounts.accounts.size > 1;
            foreach (var a in accounts.accounts) {
                foreach (var f in store.folders (a.id)) {
                    string label = many ? "%s: %s".printf (a.display_name, f.display_name) : f.display_name;
                    var item = new MenuItem (label, null);
                    item.set_action_and_target_value ("win.folder", new Variant.int64 (f.id));
                    folder_section.append_item (item);
                }
            }
        }

        private void start_sync (Account a) {
            var s = new AccountSync (a, store);
            s.max_body_size = 4 * 1024 * 1024;
            s.poll_seconds = int.max (30, settings.get_int ("sync-interval") * 60);
            if (s.backend.local_only || a.protocol != "imap") s.poll_seconds = int.min (s.poll_seconds, 120);
            s.new_mail.connect ((list) => notify_new (a, list));
            s.arrived.connect ((list) => process_arrived.begin (s, list));
            s.folders_remapped.connect ((moved) => {
                rules.remap_folders (a.id, moved);
            });
            syncs[a.id] = s;
            if (settings.get_boolean ("work-offline")) {
                s.go_offline ();
            } else if (a.managed && a.online == null) {
                return;
            } else if (s.backend.local_only) {
                s.sync_all.begin ();
            } else {
                s.sync_all.begin ();
            }
        }

        private void apply_offline () {
            bool off = settings.get_boolean ("work-offline");
            foreach (var s in syncs.values) {
                if (off) s.go_offline ();
                else s.go_online ();
            }
        }

        private void restart_timer () {
            if (sync_timer != 0) Source.remove (sync_timer);
            int minutes = int.max (1, settings.get_int ("sync-interval"));
            sync_timer = Timeout.add_seconds (minutes * 60, () => {
                sync_all ();
                return Source.CONTINUE;
            });
        }

        public void sync_all () {
            foreach (var s in syncs.values) {
                if (!s.work_offline && !s.blocked) s.sync_all.begin ();
            }
            store.prune ((int64) settings.get_int ("cache-limit") * 1024 * 1024);
        }

        private void notify_new (Account a, Gee.List<MessageInfo> list) {
            if (!settings.get_boolean ("notify-new-mail") || list.size == 0) return;
            new_mail_arrived (list);
            Notification n;
            if (list.size == 1) {
                var m = list[0];
                n = new Notification (m.sender_display);
                n.set_body (m.subject != "" ? m.subject : _("(No Subject)"));
                n.set_default_action_and_target_value ("app.show-message", new Variant.int64 (m.id));
            } else {
                n = new Notification (ngettext ("%d New Message", "%d New Messages", list.size).printf (list.size));
                var senders = new Gee.ArrayList<string> ();
                foreach (var m in list) {
                    if (!senders.contains (m.sender_display)) senders.add (m.sender_display);
                    if (senders.size >= 3) break;
                }
                n.set_body (_("From %s").printf (string.joinv (", ", senders.to_array ())));
                n.set_default_action ("app.show-inbox");
            }
            n.set_icon (new ThemedIcon ("dev.sinty.lettere"));
            n.set_category ("email.arrived");
            send_notification ("new-mail-" + a.id, n);
        }

        public int64 queue_message (Account a, MessageBuilder b, SentHook? hook, int64 send_at = 0) {
            uint8[] raw = b.build (true);
            return queue_raw (a, raw, b.recipients (), b.from != null ? b.from.email : a.email, b.subject, hook, send_at);
        }

        public int64 queue_raw (Account a, uint8[] raw, Gee.List<string> recipients, string sender, string subject, SentHook? hook, int64 send_at = 0) {
            int delay = settings.get_int ("send-delay");
            int64 at = send_at > 0 ? send_at : new DateTime.now_utc ().to_unix () + delay;
            int64 id = store.add_outbox (a.id, raw, string.joinv (",", recipients.to_array ()), sender, at, subject);
            if (hook != null) sent_hooks[id] = hook;
            outbox_changed ();
            if (send_at <= 0 && delay <= 0) pump_outbox ();
            return id;
        }

        public bool is_sending (int64 id) {
            return sending.contains (id);
        }

        public override bool dbus_register (DBusConnection connection, string object_path) throws Error {
            if (!base.dbus_register (connection, object_path)) return false;
            mail_service = new MailService (this);
            mail_service.register (connection, object_path);
            return true;
        }

        public override void dbus_unregister (DBusConnection connection, string object_path) {
            if (mail_service != null) mail_service.unregister (connection);
            mail_service = null;
            base.dbus_unregister (connection, object_path);
        }

        public bool cancel_outbox (int64 id) {
            if (sending.contains (id)) return false;
            foreach (var o in store.outbox ()) {
                if (o.id == id) {
                    store.remove_outbox (id);
                    sent_hooks.unset (id);
                    outbox_changed ();
                    return true;
                }
            }
            return false;
        }

        private void pump_outbox () {
            int64 now = new DateTime.now_utc ().to_unix ();
            foreach (var item in store.outbox ()) {
                if (item.send_at > now || sending.contains (item.id)) continue;
                var s = syncs[item.account];
                if (s == null) continue;
                if (s.work_offline) continue;
                sending.add (item.id);
                send_item.begin (s, item);
            }
        }

        private async void send_item (AccountSync s, OutboxItem item) {
            try {
                yield s.send (item);
                store.remove_outbox (item.id);
                var hook = sent_hooks[item.id];
                sent_hooks.unset (item.id);
                if (hook != null) {
                    if (hook.answered.size > 0) yield s.set_flag (hook.answered, hook.flag, true);
                    if (hook.draft != null) {
                        var list = new Gee.ArrayList<MessageInfo> ();
                        list.add (hook.draft);
                        yield s.destroy (list);
                    }
                }
                toast (_("Message sent"), null, null);
                outbox_result (item.id, "");
            } catch (Error e) {
                int64 retry = new DateTime.now_utc ().to_unix () + 60;
                store.set_outbox_error (item.id, e.message, retry);
                outbox_result (item.id, e.message);
                if (e is MailError.OFFLINE || e is IOError) {
                    toast (_("Could not reach the server. Lettere will send the message when you are back online."), null, null);
                } else if (e is MailError.TLS) {
                    s.state = SyncState.TLS_ERROR;
                    s.error_text = e.message;
                    toast (_("The message was not sent: %s").printf (e.message), null, null);
                } else {
                    toast (_("The message was not sent: %s").printf (e.message), null, null);
                }
            } finally {
                sending.remove (item.id);
                outbox_changed ();
            }
        }

        public override void activate () {
            main_window ().present ();
            TestScript.maybe_run (this);
        }

        public override void open (File[] files, string hint) {
            var w = main_window ();
            w.present ();
            foreach (var f in files) {
                if (f.get_uri_scheme () == "mailto") w.compose_to (f.get_uri ());
                else w.open_file.begin (f);
            }
        }

        public Account local_account () {
            var a = accounts.find ("local");
            if (a != null) return a;
            a = new Account ();
            a.id = "local";
            a.email = "local";
            a.label = _("On This Computer");
            a.protocol = "local";
            accounts.add (a);
            return a;
        }

        public bool is_ignored (MessageInfo m) {
            string key = m.account + "\x01" + m.thread;
            foreach (string s in settings.get_strv ("ignored-threads")) if (s == key) return true;
            return false;
        }

        public bool dark_reading () {
            if (!settings.get_boolean ("dark-messages")) return false;
            var gs = Gtk.Settings.get_default ();
            return gs != null && gs.gtk_application_prefer_dark_theme;
        }

        public bool is_blocked (string email) {
            string e = email.down ();
            foreach (string b in settings.get_strv ("blocked-senders")) {
                string x = b.down ();
                if (x == e || (x.has_prefix ("@") && e.has_suffix (x)) || (!x.contains ("@") && e.has_suffix ("@" + x))) return true;
            }
            return false;
        }

        public void block_sender (string email) {
            if (is_blocked (email)) return;
            string[] list = settings.get_strv ("blocked-senders");
            list += email.down ();
            settings.set_strv ("blocked-senders", list);
        }

        private async void process_arrived (AccountSync s, Gee.List<MessageInfo> list) {
            var notify = new Gee.ArrayList<MessageInfo> ();
            var junk_folder = store.folder_by_role (s.account.id, "junk");
            int applied = 0;
            foreach (var m in list) {
                var f = store.folder (m.folder);
                if (f == null || f.role != "inbox") {
                    notify.add (m);
                    continue;
                }
                MimeMessage? mime = null;
                var raw = store.body (m.id);
                if (raw == null && (rules.any_needs_body () || settings.get_boolean ("junk-filter"))) {
                    try {
                        raw = yield s.load_body (m);
                    } catch (Error e) {
                    }
                }
                if (raw != null) mime = new MimeMessage (raw);
                var one = new Gee.ArrayList<MessageInfo> ();
                one.add (m);
                var fresh_m = store.message (m.id);
                if (fresh_m != null && is_ignored (fresh_m)) {
                    var trash = yield s.ensure_folder ("trash", "Trash");
                    if (trash != null) yield s.move (one, trash);
                    continue;
                }
                if (is_blocked (m.sender_email)) {
                    var dest = junk_folder ?? yield s.ensure_folder ("junk", "Junk");
                    if (dest != null) yield s.move (one, dest);
                    continue;
                }
                bool known = contacts.knows (m.sender_email);
                if (settings.get_boolean ("junk-filter") && junk.trained && !known) {
                    double score = junk.score (m, mime != null ? mime.body_text () : m.preview);
                    if (score >= 0.9) {
                        var dest = junk_folder ?? yield s.ensure_folder ("junk", "Junk");
                        if (dest != null) {
                            yield s.set_flag (one, MessageFlags.JUNK, true);
                            yield s.move (one, dest);
                            continue;
                        }
                    }
                }
                var actions = rules.evaluate (m, mime, true);
                if (actions.size > 0) {
                    applied++;
                    bool moved = yield execute (s, one, actions);
                    if (moved) continue;
                }
                if (settings.get_boolean ("focused-inbox") && settings.get_boolean ("notify-focused-only")) {
                    var fresh = store.message (m.id);
                    if (fresh != null && fresh.focus == 0) continue;
                }
                notify.add (m);
            }
            if (applied > 0) rules_ran (applied);
            notify_new (s.account, notify);
        }

        public async bool execute (AccountSync s, Gee.List<MessageInfo> msgs, Gee.List<RuleAction> actions) {
            bool moved = false;
            var ordered = new Gee.ArrayList<RuleAction> ();
            foreach (var a in actions) if (!(a.kind in new string[] { "move", "archive", "delete", "junk", "snooze" })) ordered.add (a);
            foreach (var a in actions) if (a.kind in new string[] { "move", "archive", "delete", "junk", "snooze" }) ordered.add (a);
            foreach (var a in ordered) {
                if (moved) break;
                switch (a.kind) {
                    case "read": yield s.set_flag (msgs, MessageFlags.SEEN, true); break;
                    case "unread": yield s.set_flag (msgs, MessageFlags.SEEN, false); break;
                    case "flag": yield s.set_flag (msgs, MessageFlags.FLAGGED, true); break;
                    case "pin": yield s.set_flag (msgs, MessageFlags.PINNED, true); break;
                    case "category":
                        categories.ensure (a.value);
                        yield s.set_categories (msgs, { a.value }, {});
                        break;
                    case "other":
                    case "focused":
                        foreach (var m in msgs) store.set_focus (m.id, a.kind == "focused" ? 1 : 0);
                        s.data_changed ();
                        break;
                    case "copy": {
                        var dest = store.folder_by_path (s.account.id, a.value);
                        if (dest != null) yield s.copy (msgs, dest);
                        break;
                    }
                    case "move": {
                        var dest = store.folder_by_path (s.account.id, a.value);
                        if (dest != null) {
                            yield s.move (msgs, dest);
                            moved = true;
                        }
                        break;
                    }
                    case "archive": {
                        var dest = yield s.ensure_folder ("archive", "Archive");
                        if (dest != null) {
                            yield s.move (msgs, dest);
                            moved = true;
                        }
                        break;
                    }
                    case "delete": {
                        var dest = yield s.ensure_folder ("trash", "Trash");
                        if (dest != null) {
                            yield s.move (msgs, dest);
                            moved = true;
                        }
                        break;
                    }
                    case "junk": {
                        var dest = yield s.ensure_folder ("junk", "Junk");
                        if (dest != null) {
                            foreach (var m in msgs) junk.train (m, m.preview, true);
                            yield s.move (msgs, dest);
                            moved = true;
                        }
                        break;
                    }
                    case "snooze": {
                        var now = new DateTime.now_local ();
                        var t = new DateTime.local (now.get_year (), now.get_month (), now.get_day_of_month (), 8, 0, 0).add_days (1);
                        yield snooze (s, msgs, t.to_unix ());
                        moved = true;
                        break;
                    }
                    case "forward":
                        foreach (var m in msgs) yield forward_as_attachment (s.account, m, a.value);
                        break;
                    case "redirect":
                        foreach (var m in msgs) {
                            var raw = store.body (m.id);
                            if (raw == null) {
                                try {
                                    raw = yield s.load_body (m);
                                } catch (Error e) {
                                }
                            }
                            if (raw == null) continue;
                            var to = Mime.parse_addresses (a.value);
                            var rcpts = new Gee.ArrayList<string> ();
                            foreach (var x in to) rcpts.add (x.email);
                            queue_raw (s.account, Special.redirect (raw, s.account, to), rcpts, s.account.email, m.subject, null);
                        }
                        break;
                    case "reply": {
                        var tpl = templates.find (a.value);
                        if (tpl == null) break;
                        foreach (var m in msgs) {
                            if (m.sender_email == "" || m.sender_email.down () == s.account.email.down ()) continue;
                            var b = new MessageBuilder ();
                            b.from = s.account.address ();
                            b.to.add (new Address (m.sender_name, m.sender_email));
                            b.subject = tpl.subject != "" ? tpl.subject : "Re: " + m.subject;
                            b.in_reply_to = m.message_id;
                            b.references = (m.references + " " + m.message_id).strip ();
                            b.html = tpl.html;
                            b.text = Html.to_text (tpl.html);
                            b.extra_headers.add (new HeaderField ("Auto-Submitted", "auto-replied"));
                            queue_message (s.account, b, null);
                        }
                        break;
                    }
                    case "task":
                        foreach (var m in msgs) TasksBridge.add (_("Follow up: %s").printf (m.subject), 0);
                        break;
                }
            }
            return moved;
        }

        public async void forward_as_attachment (Account a, MessageInfo m, string to) {
            var s = syncs[m.account];
            var raw = store.body (m.id);
            if (raw == null && s != null) {
                try {
                    raw = yield s.load_body (m);
                } catch (Error e) {
                }
            }
            if (raw == null) return;
            var b = new MessageBuilder ();
            b.from = a.address ();
            b.to.add_all (Mime.parse_addresses (to));
            b.subject = "Fwd: " + m.subject;
            b.text = _("Forwarded message attached.");
            string name = (m.subject != "" ? m.subject : "message").replace ("/", "_") + ".eml";
            b.attachments.add (new OutgoingAttachment (name, "message/rfc822", new Bytes (raw)));
            queue_message (a, b, null);
        }

        public async void snooze (AccountSync s, Gee.List<MessageInfo> msgs, int64 until) {
            var dest = yield s.ensure_folder ("snoozed", "Snoozed");
            if (dest == null) return;
            foreach (var m in msgs) {
                var f = store.folder (m.folder);
                store.add_snooze (s.account.id, m.message_id != "" ? m.message_id : m.rid, until, f != null ? f.path : "", m.subject);
            }
            yield s.move (msgs, dest);
        }

        private async void wake_snoozed () {
            int64 now = new DateTime.now_utc ().to_unix ();
            foreach (var item in store.snoozes ()) {
                if (item.until > now) continue;
                var s = syncs[item.account];
                if (s == null) {
                    store.remove_snooze (item.id);
                    continue;
                }
                var snoozed = store.folder_by_role (item.account, "snoozed");
                var origin = store.folder_by_path (item.account, item.origin) ?? store.folder_by_role (item.account, "inbox");
                if (snoozed == null || origin == null) {
                    store.remove_snooze (item.id);
                    continue;
                }
                MessageInfo? m = null;
                foreach (var x in store.folder_messages (snoozed.id)) if (x.message_id == item.message_id || x.rid == item.message_id) m = x;
                store.remove_snooze (item.id);
                if (m == null) continue;
                var one = new Gee.ArrayList<MessageInfo> ();
                one.add (m);
                yield s.set_flag (one, MessageFlags.SEEN, false);
                yield s.move (one, origin);
                var n = new Notification (_("Snoozed Message"));
                n.set_body (m.subject != "" ? m.subject : _("(No Subject)"));
                n.set_icon (new ThemedIcon ("dev.sinty.lettere"));
                n.set_default_action ("app.show-inbox");
                send_notification ("snooze-" + item.id.to_string (), n);
            }
        }

        private void remind_follow_ups () {
            int64 now = new DateTime.now_utc ().to_unix ();
            foreach (var m in store.due_messages (now)) {
                string key = "reminded-" + m.id.to_string ();
                if (store.get_value ("", key) != null) continue;
                store.set_value ("", key, "1");
                var n = new Notification (_("Follow Up"));
                n.set_body (m.subject != "" ? m.subject : _("(No Subject)"));
                n.set_icon (new ThemedIcon ("dev.sinty.lettere"));
                n.set_default_action_and_target_value ("app.show-message", new Variant.int64 (m.id));
                send_notification ("follow-" + m.id.to_string (), n);
            }
        }

        public async void upload_server_rules () {
            foreach (var s in syncs.values) {
                bool wants = false;
                foreach (var r in rules.rules) if (r.on_server && (r.account == "" || r.account == s.account.id)) wants = true;
                if (!wants && s.account.protocol == "imap") continue;
                if (!s.backend.supports_rules || s.work_offline) continue;
                try {
                    yield s.ensure ();
                    yield s.backend.upload_rules (rules);
                } catch (Error e) {
                    toast (_("Could not save the server rules for %s: %s").printf (s.account.email, e.message), null, null);
                }
            }
        }

        public async void run_rules_now (Folder f) {
            var s = syncs[f.account];
            if (s == null) return;
            int count = 0;
            foreach (var m in store.folder_messages (f.id)) {
                MimeMessage? mime = null;
                var raw = store.body (m.id);
                if (raw != null) mime = new MimeMessage (raw);
                var actions = rules.evaluate (m, mime, false);
                if (actions.size == 0) continue;
                var one = new Gee.ArrayList<MessageInfo> ();
                one.add (m);
                yield execute (s, one, actions);
                count++;
            }
            toast (ngettext ("Rules applied to %d message", "Rules applied to %d messages", count).printf (count), null, null);
        }

        public void send_receipt (MessageInfo m) {
            var a = accounts.find (m.account);
            var s = syncs[m.account];
            if (a == null || s == null) return;
            var raw = Special.mdn (a, m, _("Read:"));
            var rcpts = new Gee.ArrayList<string> ();
            foreach (var x in Mime.parse_addresses (m.receipt_to)) rcpts.add (x.email);
            if (rcpts.size == 0) rcpts.add (m.receipt_to);
            queue_raw (a, raw, rcpts, a.email, m.subject, null);
            var one = new Gee.ArrayList<MessageInfo> ();
            one.add (m);
            s.set_flag.begin (one, MessageFlags.MDN_SENT, true);
        }

        public void ignore_receipt (MessageInfo m) {
            var s = syncs[m.account];
            if (s == null) return;
            var one = new Gee.ArrayList<MessageInfo> ();
            one.add (m);
            s.set_flag.begin (one, MessageFlags.MDN_SENT, true);
        }

        public async void unsubscribe (MessageInfo m, Gtk.Window? parent) {
            var target = Special.unsubscribe_of (m.list_unsubscribe);
            var a = accounts.find (m.account);
            if (target.url != "" && target.one_click) {
                try {
                    var session = new Soup.Session ();
                    var msg = new Soup.Message ("POST", target.url);
                    msg.set_request_body_from_bytes ("application/x-www-form-urlencoded", new Bytes ("List-Unsubscribe=One-Click".data));
                    yield session.send_and_read_async (msg, Priority.DEFAULT, null);
                    if (msg.status_code < 300) {
                        toast (_("You were unsubscribed from this list"), null, null);
                        return;
                    }
                } catch (Error e) {
                }
            }
            if (target.mailto != "" && a != null) {
                string to, subject, body;
                Special.mailto_parts (target.mailto, out to, out subject, out body);
                var b = new MessageBuilder ();
                b.from = a.address ();
                b.to.add_all (Mime.parse_addresses (to));
                b.subject = subject != "" ? subject : "unsubscribe";
                b.text = body != "" ? body : "unsubscribe";
                queue_message (a, b, null);
                toast (_("An unsubscribe request was sent to %s").printf (to), null, null);
                return;
            }
            if (target.url != "") {
                new UriLauncher (target.url).launch.begin (parent, null);
                return;
            }
            toast (_("This list did not say how to unsubscribe"), null, null);
        }

        public LettereWindow main_window () {
            foreach (var w in get_windows ()) {
                if (w is LettereWindow) return (LettereWindow) w;
            }
            return new LettereWindow (this);
        }

        private const string CSS = """
.lettere-list {
    background: transparent;
    padding: 0 6px 6px 6px;
}

.lettere-list > row {
    border-radius: 12px;
    padding: 9px 10px;
    margin: 1px 0;
}

.lettere-list > row:selected {
    background-color: @hover_btn_bg;
    color: @hover_btn_fg;
}

.lettere-list-pane {
    border-right: 1px solid alpha(@borders, 0.6);
}

.lettere-unread-dot {
    border-radius: 99px;
    background-color: @accent_bg_color;
    min-width: 8px;
    min-height: 8px;
}

.lettere-list > row:selected .lettere-unread-dot {
    background-color: @hover_btn_fg;
}

.lettere-row-sender {
    font-weight: 600;
}

.lettere-row-sender.unread,
.lettere-row-subject.unread {
    font-weight: 800;
}

.lettere-row-date,
.lettere-row-preview {
    font-size: 12px;
    opacity: 0.7;
}

.lettere-count {
    font-size: 11px;
    font-weight: 700;
    font-feature-settings: "tnum";
    padding: 0 6px;
    border-radius: 99px;
    background-color: alpha(@window_fg_color, 0.1);
}

.lettere-badge {
    font-size: 12px;
    font-feature-settings: "tnum";
    opacity: 0.65;
}

.lettere-subject {
    font-size: 20px;
    font-weight: 800;
}

.lettere-strip {
    padding: 0 16px;
}

.lettere-strip > row {
    border-radius: 10px;
    padding: 6px 10px;
}

.lettere-strip > row:selected {
    background-color: alpha(@accent_bg_color, 0.14);
    color: @window_fg_color;
}

.lettere-header {
    padding: 4px 20px 10px 20px;
}

.lettere-paper {
    border-radius: 14px;
    background-color: #ffffff;
    margin: 0 16px 12px 16px;
}

.lettere-plain,
.lettere-plain text {
    background: transparent;
    font-size: 14px;
}

.lettere-plain {
    margin: 0 16px 12px 16px;
    padding: 16px 20px;
    border-radius: 14px;
    background-color: alpha(@window_fg_color, 0.035);
}

.lettere-notice {
    margin: 0 16px 10px 16px;
    padding: 6px 6px 6px 14px;
    border-radius: 12px;
    background-color: alpha(@accent_bg_color, 0.1);
}

.lettere-attachment {
    padding: 6px 10px;
    border-radius: 12px;
    background-color: alpha(@window_fg_color, 0.06);
}

.lettere-attachments {
    margin: 0 16px 14px 16px;
}

.lettere-composer {
    padding: 12px 20px 20px 20px;
}

.lettere-filter-chip {
    min-height: 24px;
    padding: 0 10px;
    border-radius: 99px;
    font-size: 12px;
    font-weight: 600;
    background-color: alpha(@accent_bg_color, 0.14);
    color: @accent_color;
}

.lettere-list-header {
    padding: 6px 10px 2px 10px;
}

.context-ribbon button.context-ribbon-item.lettere-send {
    background-color: @accent_bg_color;
    color: @accent_fg_color;
}

.context-ribbon button.context-ribbon-item.lettere-send image,
.context-ribbon button.context-ribbon-item.lettere-send label {
    color: @accent_fg_color;
}

.lettere-compose-fields {
    border-radius: 14px;
    padding: 6px 14px;
    background-color: alpha(@window_fg_color, 0.04);
}

.lettere-compose-fields entry,
.lettere-compose-fields dropdown > button {
    background: transparent;
    box-shadow: none;
    border: none;
}

.lettere-field-label {
    opacity: 0.6;
    font-weight: 600;
}

.lettere-compose-body,
.lettere-compose-body text {
    background: transparent;
    font-size: 15px;
}

.lettere-compose-card {
    border-radius: 14px;
    background-color: alpha(@window_fg_color, 0.04);
}

.lettere-drop {
    background-color: alpha(@accent_bg_color, 0.2);
    border-radius: 10px;
}
""";
    }

    public static int main (string[] args) {
        Intl.setlocale (LocaleCategory.ALL, "");
        string locale_dir = "/usr/share/locale";
        try {
            string exe = FileUtils.read_link ("/proc/self/exe");
            locale_dir = Path.build_filename (Path.get_dirname (Path.get_dirname (exe)), "share", "locale");
        } catch (Error e) {
        }
        Intl.bindtextdomain ("singularity-lettere", locale_dir);
        Intl.bind_textdomain_codeset ("singularity-lettere", "UTF-8");
        Intl.textdomain ("singularity-lettere");
        return new LettereApp ().run (args);
    }
}
