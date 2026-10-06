namespace Singularity.Apps.Lettere {

    public enum SyncState {
        IDLE,
        CONNECTING,
        SYNCING,
        OFFLINE,
        WORKING_OFFLINE,
        AUTH_FAILED,
        TLS_ERROR,
        SERVER_ERROR
    }

    public class AccountSync : Object {
        public signal void new_mail (Gee.List<MessageInfo> messages);
        public signal void arrived (Gee.List<MessageInfo> messages);
        public signal void data_changed ();
        public signal void folders_remapped (Gee.Map<string, string> moved);

        public Account account { get; private set; }
        public SyncState state { get; set; default = SyncState.IDLE; }
        public string error_text { get; set; default = ""; }
        public CertificateTrust? trust { get; set; }
        public string trust_kind { get; set; default = "imap"; }
        public bool busy { get; private set; }
        public bool work_offline { get; set; }
        public int64 max_body_size { get; set; default = 2 * 1024 * 1024; }
        public int poll_seconds { get; set; default = 60; }
        public MailBackend backend;

        public Store store;
        private Cancellable? idle_stop;
        private bool idle_running;
        private bool stopped;
        private bool pending_sync;
        private uint retry_id;
        private int retry_step;
        private string? password;
        private bool first_sync_done;
        private bool locked;
        private Gee.ArrayQueue<LockWaiter> lock_waiters = new Gee.ArrayQueue<LockWaiter> ();

        private class LockWaiter {
            public SourceFunc cb;

            public LockWaiter (owned SourceFunc cb) {
                this.cb = (owned) cb;
            }
        }

        private async void op_lock () {
            while (locked) {
                lock_waiters.offer (new LockWaiter (op_lock.callback));
                yield;
            }
            locked = true;
        }

        private void op_unlock () {
            locked = false;
            var w = lock_waiters.poll ();
            if (w != null) Idle.add ((owned) w.cb);
        }

        public AccountSync (Account account, Store store) {
            this.account = account;
            this.store = store;
            backend = create_backend ();
        }

        private MailBackend create_backend () {
            switch (account.protocol) {
                case "graph": return new GraphBackend (this);
                case "gmail": return new GmailBackend (this);
                case "jmap": return new JmapBackend (this);
                case "ews": return new EwsBackend (this);
                case "pop3": return new PopBackend (this);
                case "local": return new LocalBackend (this);
            }
            return new ImapBackend (this);
        }

        public bool online {
            get { return backend.online; }
        }

        public bool blocked {
            get { return state == SyncState.AUTH_FAILED || state == SyncState.TLS_ERROR; }
        }

        public void forget_password () {
            password = null;
        }

        private async string get_password (string kind) throws Error {
            if (kind == "imap" && password != null) return password;
            string? p = yield Secrets.lookup (account, kind);
            if (p == null) throw new MailError.AUTH (_("No password is saved for %s").printf (account.email));
            if (kind == "imap") password = p;
            return p;
        }

        private async MailLogin online_login (bool refresh) throws Error {
            if (account.online == null) throw new MailError.OFFLINE (_("Online Accounts is not available"));
            return yield account.online.fetch (refresh);
        }

        private Error refused (Error e) {
            if (account.online != null) account.online.report_reauth ();
            state = SyncState.AUTH_FAILED;
            error_text = e.message;
            return new MailError.AUTH (e.message);
        }

        public async MailLogin current_login (bool refresh = false) throws Error {
            if (account.managed) return yield online_login (refresh);
            var l = new MailLogin ();
            l.user = account.imap_user != "" ? account.imap_user : account.email;
            l.secret = yield get_password ("imap");
            return l;
        }

        public void login_refused (Error e) throws Error {
            throw refused (e);
        }

        public async void sign_in_imap (ImapClient c, string user) throws Error {
            if (!account.managed) {
                yield c.login (user, yield get_password ("imap"));
                return;
            }
            var login = yield online_login (false);
            try {
                if (login.is_token) yield c.login_xoauth2 (login.xoauth2);
                else yield c.login (user, login.secret);
                return;
            } catch (MailError.AUTH e) {
                if (!login.is_token) throw refused (e);
            }
            login = yield online_login (true);
            try {
                yield c.login_xoauth2 (login.xoauth2);
            } catch (MailError.AUTH e) {
                throw refused (e);
            }
        }

        public async void sign_in_smtp (SmtpClient smtp, string user) throws Error {
            if (!account.managed) {
                yield smtp.login (user, yield get_password ("smtp"));
                return;
            }
            var login = yield online_login (false);
            try {
                if (login.is_token) yield smtp.login_xoauth2 (login.xoauth2);
                else yield smtp.login (user, login.secret);
                return;
            } catch (MailError.AUTH e) {
                if (!login.is_token) throw refused (e);
            }
            login = yield online_login (true);
            try {
                yield smtp.login_xoauth2 (login.xoauth2);
            } catch (MailError.AUTH e) {
                throw refused (e);
            }
        }

        private void set_error (Error e) {
            bool drop = true;
            if (e is MailError.AUTH) {
                state = SyncState.AUTH_FAILED;
                password = null;
            } else if (e is MailError.TLS) {
                state = SyncState.TLS_ERROR;
                if (backend.trust != null) {
                    trust = backend.trust;
                    trust_kind = backend.trust_kind;
                }
            } else if (e is MailError.SERVER) {
                state = SyncState.SERVER_ERROR;
                drop = false;
            } else if (e is MailError.PROTOCOL) {
                state = SyncState.SERVER_ERROR;
            } else {
                state = SyncState.OFFLINE;
            }
            error_text = e.message;
            warning ("lettere: %s: %s", account.email, e.message);
            if (drop) backend.disconnect ();
            schedule_retry ();
        }

        private void schedule_retry () {
            if (stopped || blocked || work_offline) return;
            if (retry_id != 0) Source.remove (retry_id);
            int[] delays = { 15, 30, 60, 120, 300 };
            int d = delays[int.min (retry_step, delays.length - 1)];
            retry_step++;
            retry_id = Timeout.add_seconds (d, () => {
                retry_id = 0;
                sync_all.begin ();
                return Source.REMOVE;
            });
        }

        public void network_changed (bool available) {
            if (!available || stopped || work_offline) return;
            if (state == SyncState.OFFLINE || state == SyncState.SERVER_ERROR) {
                retry_step = 0;
                sync_all.begin ();
            }
        }

        public async void ensure () throws Error {
            if (work_offline && !backend.local_only) throw new MailError.OFFLINE (_("Lettere is working offline"));
            if (backend.online) return;
            state = SyncState.CONNECTING;
            yield backend.connect ();
        }

        public void stop () {
            stopped = true;
            if (retry_id != 0) Source.remove (retry_id);
            retry_id = 0;
            if (idle_stop != null) idle_stop.cancel ();
            var imap = backend as ImapBackend;
            if (imap != null) imap.logout ();
            else backend.disconnect ();
        }

        public void go_offline () {
            work_offline = true;
            if (retry_id != 0) Source.remove (retry_id);
            retry_id = 0;
            if (idle_stop != null) idle_stop.cancel ();
            backend.disconnect ();
            state = SyncState.WORKING_OFFLINE;
            error_text = "";
        }

        public void go_online () {
            work_offline = false;
            stopped = false;
            state = SyncState.IDLE;
            retry_step = 0;
            sync_all.begin ();
        }

        public void trust_certificate () {
            if (trust == null) return;
            if (trust_kind == "smtp") account.trusted_smtp = trust.fingerprint;
            else account.trusted_imap = trust.fingerprint;
            trust = null;
            backend.trust = null;
            state = SyncState.IDLE;
            retry_step = 0;
        }

        public void credentials_updated () {
            password = null;
            state = SyncState.IDLE;
            retry_step = 0;
            sync_all.begin ();
        }

        public static string role_for (MailboxInfo info) {
            if (info.name.up () == "INBOX") return "inbox";
            if (info.has ("\\Sent")) return "sent";
            if (info.has ("\\Drafts")) return "drafts";
            if (info.has ("\\Trash")) return "trash";
            if (info.has ("\\Junk")) return "junk";
            if (info.has ("\\Archive") || info.has ("\\All")) return "archive";
            string leaf = info.name;
            if (info.delimiter != "" && leaf.contains (info.delimiter)) leaf = leaf.substring (leaf.last_index_of (info.delimiter) + info.delimiter.length);
            return role_for_name (leaf);
        }

        public static string role_for_name (string leaf) {
            switch (leaf.down ()) {
                case "inbox":
                    return "inbox";
                case "sent":
                case "sent items":
                case "sent messages":
                case "sent mail":
                case "inviata":
                case "posta inviata":
                    return "sent";
                case "drafts":
                case "draft":
                case "bozze":
                    return "drafts";
                case "trash":
                case "deleted items":
                case "deleted messages":
                case "bin":
                case "cestino":
                case "posta eliminata":
                    return "trash";
                case "junk":
                case "spam":
                case "junk e-mail":
                case "junk email":
                case "posta indesiderata":
                    return "junk";
                case "archive":
                case "archives":
                case "archivio":
                    return "archive";
                case "snoozed":
                case "posticipati":
                    return "snoozed";
            }
            return "";
        }

        private async void sync_folder_locked (Folder f, bool notify, int prefetch, Gee.List<MessageInfo> fresh) throws Error {
            if (f.local && !(backend is LocalBackend)) return;
            yield op_lock ();
            try {
                yield backend.sync_folder (f, notify, fresh);
                if (prefetch > 0) yield backend.prefetch (f, prefetch);
            } finally {
                op_unlock ();
            }
        }

        private void refresh_folders (Gee.List<RemoteFolder> boxes) {
            var seen = new Gee.HashSet<string> ();
            var roles_taken = new Gee.HashSet<string> ();
            foreach (var b in boxes) {
                string role = b.role;
                if (role != "" && role != "inbox" && roles_taken.contains (role)) role = "";
                if (role == "inbox" && roles_taken.contains ("inbox")) role = "";
                if (role != "") roles_taken.add (role);
                store.upsert_folder (account.id, b.path, b.name, role, b.delimiter, b.parent, b.shared);
                seen.add (b.path);
            }
            foreach (var f in store.folders (account.id)) {
                if (!seen.contains (f.path) && !f.local) store.remove_folder (f.id);
            }
            var moved = store.finish_protocol_switch (account.id);
            if (moved.size > 0) folders_remapped (moved);
            store.folders_changed (account.id);
        }

        public async void sync_all () {
            if (stopped || (work_offline && !backend.local_only)) return;
            if (busy) {
                pending_sync = true;
                return;
            }
            busy = true;
            try {
                yield ensure ();
                state = SyncState.SYNCING;
                yield replay_ops ();
                Gee.List<RemoteFolder> boxes = new Gee.ArrayList<RemoteFolder> ();
                yield op_lock ();
                try {
                    boxes = yield backend.list_folders ();
                } finally {
                    op_unlock ();
                }
                refresh_folders (boxes);
                var folders = store.folders (account.id);
                var fresh = new Gee.ArrayList<MessageInfo> ();
                foreach (var f in folders) {
                    if (f.role == "inbox") yield sync_folder_locked (f, first_sync_done, 0, fresh);
                }
                data_changed ();
                var ignored = new Gee.ArrayList<MessageInfo> ();
                foreach (var f in folders) {
                    if (f.role != "inbox") yield sync_folder_locked (f, false, 0, ignored);
                }
                store.restore_message_state (account.id);
                store.rethread (account.id);
                data_changed ();
                foreach (var f in folders) {
                    if (f.local && !(backend is LocalBackend)) continue;
                    yield op_lock ();
                    try {
                        yield backend.prefetch (f, f.role == "inbox" ? 200 : 60);
                    } finally {
                        op_unlock ();
                    }
                }
                first_sync_done = true;
                state = SyncState.IDLE;
                error_text = "";
                retry_step = 0;
                data_changed ();
                deliver (fresh);
                start_watch ();
            } catch (Error e) {
                set_error (e);
                data_changed ();
            } finally {
                busy = false;
            }
            if (pending_sync) {
                pending_sync = false;
                yield sync_all ();
            }
        }

        private void deliver (Gee.List<MessageInfo> fresh) {
            if (fresh.size == 0) return;
            arrived (fresh);
        }

        public async void sync_inbox () {
            if (stopped || (work_offline && !backend.local_only)) return;
            if (busy) {
                pending_sync = true;
                return;
            }
            var f = store.folder_by_role (account.id, "inbox");
            if (f == null) {
                yield sync_all ();
                return;
            }
            busy = true;
            var fresh = new Gee.ArrayList<MessageInfo> ();
            try {
                yield ensure ();
                yield sync_folder_locked (f, true, 20, fresh);
                store.rethread (account.id);
                state = SyncState.IDLE;
                data_changed ();
            } catch (Error e) {
                set_error (e);
            } finally {
                busy = false;
            }
            deliver (fresh);
            if (pending_sync) {
                pending_sync = false;
                yield sync_all ();
            }
        }

        public async uint8[]? load_body (MessageInfo m) throws Error {
            var cached = store.body (m.id);
            if (cached != null) return cached;
            var f = store.folder (m.folder);
            if (f == null) return null;
            yield ensure ();
            uint8[]? data = null;
            yield op_lock ();
            try {
                data = yield backend.fetch_body (f, m);
            } finally {
                op_unlock ();
            }
            if (data != null) {
                store.set_body (m.id, data);
                m.has_body = true;
            }
            return data;
        }

        private static string id_set (Gee.List<MessageInfo> list) {
            var parts = new Gee.ArrayList<string> ();
            foreach (var m in list) parts.add (m.ident);
            return string.joinv (",", parts.to_array ());
        }

        private Gee.HashMap<int64?, Gee.ArrayList<MessageInfo>> by_folder (Gee.List<MessageInfo> list) {
            var map = new Gee.HashMap<int64?, Gee.ArrayList<MessageInfo>> ((v) => int64_hash (v), (a, b) => a == b);
            foreach (var m in list) {
                if (m.account != account.id) continue;
                if (!map.has_key (m.folder)) map[m.folder] = new Gee.ArrayList<MessageInfo> ();
                map[m.folder].add (m);
            }
            return map;
        }

        public async void set_flag (Gee.List<MessageInfo> list, int flag, bool on) {
            var changed = new Gee.ArrayList<MessageInfo> ();
            foreach (var m in list) {
                if (m.account != account.id) continue;
                int nf = on ? (m.flags | flag) : (m.flags & ~flag);
                if (nf == m.flags) continue;
                m.flags = nf;
                store.set_flags_by_id (m.id, nf);
                changed.add (m);
            }
            data_changed ();
            foreach (var e in by_folder (changed).entries) {
                var f = store.folder (e.key);
                if (f == null || f.local) continue;
                yield run_op ("flag", f.path, id_set (e.value), "%d:%d".printf (flag, on ? 1 : 0));
            }
        }

        public async void set_categories (Gee.List<MessageInfo> list, string[] add, string[] remove) {
            var changed = new Gee.ArrayList<MessageInfo> ();
            foreach (var m in list) {
                if (m.account != account.id) continue;
                var cats = new Gee.ArrayList<string> ();
                foreach (string c in m.categories ()) cats.add (c);
                bool dirty = false;
                foreach (string r in remove) {
                    foreach (string c in cats.to_array ()) {
                        if (c.down () == r.down ()) {
                            cats.remove (c);
                            dirty = true;
                        }
                    }
                }
                foreach (string a in add) {
                    if (!m.has_category (a)) {
                        cats.add (a);
                        dirty = true;
                    }
                }
                if (!dirty) continue;
                m.keywords = string.joinv ("\x1f", cats.to_array ());
                store.set_keywords (m.id, m.keywords);
                changed.add (m);
            }
            data_changed ();
            var arg = new StringBuilder ();
            arg.append (string.joinv ("\x1f", add));
            arg.append ("\x1e");
            arg.append (string.joinv ("\x1f", remove));
            foreach (var e in by_folder (changed).entries) {
                var f = store.folder (e.key);
                if (f == null || f.local) continue;
                yield run_op ("kw", f.path, id_set (e.value), arg.str);
            }
        }

        public async void move (Gee.List<MessageInfo> list, Folder dest) {
            var groups = by_folder (list);
            foreach (var m in list) {
                if (m.account != account.id || m.folder == dest.id) continue;
                var f = store.folder (m.folder);
                if (f != null && (f.local || dest.local)) {
                    var raw = store.body (m.id);
                    if (raw == null) {
                        try {
                            raw = yield load_body (m);
                        } catch (Error e) {
                        }
                    }
                    if (raw != null && dest.local) {
                        int64 nid = store.insert_message (dest, store.max_uid (dest.id) + 1, m.flags, m.size, raw, m.date, "", "", m.keywords);
                        store.set_body (nid, raw);
                    } else if (raw != null && !dest.local) {
                        try {
                            yield ensure ();
                            yield append (dest, (m.flags & MessageFlags.SEEN) != 0 ? "\\Seen" : "", raw);
                        } catch (Error e) {
                            warning ("lettere: move to %s failed: %s", dest.path, e.message);
                            continue;
                        }
                    }
                }
                store.delete_message (m.id);
            }
            data_changed ();
            foreach (var e in groups.entries) {
                if (e.key == dest.id) continue;
                var f = store.folder (e.key);
                if (f == null) continue;
                if (f.local || dest.local) {
                    if (!f.local) yield run_op ("expunge", f.path, id_set (e.value), "");
                    continue;
                }
                yield run_op ("move", f.path, id_set (e.value), dest.path);
            }
            if (online && !dest.local) {
                try {
                    var fresh = new Gee.ArrayList<MessageInfo> ();
                    yield sync_folder_locked (dest, false, 20, fresh);
                    store.rethread (account.id);
                } catch (Error e) {
                }
                data_changed ();
            }
            store.rethread (account.id);
        }

        public async void copy (Gee.List<MessageInfo> list, Folder dest) {
            foreach (var e in by_folder (list).entries) {
                var f = store.folder (e.key);
                if (f == null) continue;
                if (f.local || dest.local) {
                    foreach (var m in e.value) {
                        uint8[]? raw = null;
                        try {
                            raw = yield load_body (m);
                        } catch (Error err) {
                        }
                        if (raw == null) continue;
                        if (dest.local) {
                            int64 nid = store.insert_message (dest, store.max_uid (dest.id) + 1, m.flags, m.size, raw, m.date, "", "", m.keywords);
                            store.set_body (nid, raw);
                        } else {
                            try {
                                yield append (dest, "\\Seen", raw);
                            } catch (Error err) {
                            }
                        }
                    }
                    continue;
                }
                yield run_op ("copy", f.path, id_set (e.value), dest.path);
            }
            if (online && !dest.local) {
                try {
                    var fresh = new Gee.ArrayList<MessageInfo> ();
                    yield sync_folder_locked (dest, false, 20, fresh);
                } catch (Error e) {
                }
            }
            store.rethread (account.id);
            data_changed ();
        }

        public async void destroy (Gee.List<MessageInfo> list) {
            var groups = by_folder (list);
            foreach (var m in list) {
                if (m.account == account.id) store.delete_message (m.id);
            }
            data_changed ();
            foreach (var e in groups.entries) {
                var f = store.folder (e.key);
                if (f == null || f.local) continue;
                yield run_op ("expunge", f.path, id_set (e.value), "");
            }
        }

        public async Folder? ensure_folder (string role, string name) {
            var f = store.folder_by_role (account.id, role);
            if (f != null) return f;
            if (backend.local_only) return store.local_folder (account.id, name, name, role);
            try {
                yield ensure ();
                yield op_lock ();
                RemoteFolder r = new RemoteFolder ();
                try {
                    r = yield backend.create_folder (name, null);
                } finally {
                    op_unlock ();
                }
                var made = store.upsert_folder (account.id, r.path, r.name, role, r.delimiter, r.parent);
                store.folders_changed (account.id);
                return made;
            } catch (Error e) {
                if (!online) return null;
                warning ("lettere: could not create %s: %s", name, e.message);
            }
            return store.folder_by_role (account.id, role);
        }

        public async Folder? create_folder (string name, Folder? parent) throws Error {
            if (backend.local_only || (parent != null && parent.local)) {
                string path = parent != null ? parent.path + "/" + name : name;
                var f = store.local_folder (account.id, path, name, "");
                store.rename_folder (f.id, path, name, parent != null ? parent.path : "");
                store.folders_changed (account.id);
                return store.folder (f.id);
            }
            yield ensure ();
            yield op_lock ();
            RemoteFolder r = new RemoteFolder ();
            try {
                r = yield backend.create_folder (name, parent);
            } finally {
                op_unlock ();
            }
            var made = store.upsert_folder (account.id, r.path, r.name, "", r.delimiter, r.parent);
            store.folders_changed (account.id);
            return made;
        }

        public async void rename_folder (Folder f, string name) throws Error {
            if (f.local) {
                string path = f.parent != "" ? f.parent + "/" + name : name;
                store.rename_folder (f.id, path, name, f.parent);
                store.folders_changed (account.id);
                return;
            }
            yield ensure ();
            yield op_lock ();
            try {
                yield backend.rename_folder (f, name);
            } finally {
                op_unlock ();
            }
            yield sync_all ();
        }

        public async void delete_folder (Folder f) throws Error {
            if (!f.local) {
                yield ensure ();
                yield op_lock ();
                try {
                    yield backend.delete_folder (f);
                } finally {
                    op_unlock ();
                }
            }
            store.remove_folder (f.id);
            store.folders_changed (account.id);
            data_changed ();
        }

        private async void run_op (string kind, string folder, string ids, string arg) {
            if (!online || work_offline) {
                store.add_op (account.id, kind, folder, ids, arg);
                return;
            }
            try {
                yield apply_op (kind, folder, ids, arg);
            } catch (Error e) {
                store.add_op (account.id, kind, folder, ids, arg);
                if (!(e is MailError.SERVER)) set_error (e);
            }
        }

        private async void apply_op (string kind, string folder, string ids, string arg) throws Error {
            yield op_lock ();
            try {
                yield apply_op_unlocked (kind, folder, ids, arg);
            } finally {
                op_unlock ();
            }
        }

        private static int legacy_flag (string name) {
            var l = new Gee.ArrayList<string> ();
            l.add (name);
            return Store.flags_from (l);
        }

        private async void apply_op_unlocked (string kind, string folder, string ids, string arg) throws Error {
            var f = store.folder_by_path (account.id, folder);
            if (f == null) {
                f = new Folder ();
                f.account = account.id;
                f.path = folder;
            }
            switch (kind) {
                case "flag":
                    if (arg.has_prefix ("+") || arg.has_prefix ("-")) {
                        string[] p = arg.split (" ", 2);
                        yield backend.set_flags (f, ids, legacy_flag (p[1]), p[0].has_prefix ("+"));
                    } else {
                        string[] p = arg.split (":");
                        yield backend.set_flags (f, ids, int.parse (p[0]), p.length > 1 && p[1] == "1");
                    }
                    break;
                case "kw": {
                    string[] halves = arg.split ("\x1e");
                    string[] add = {};
                    string[] rem = {};
                    foreach (string s in halves[0].split ("\x1f")) if (s != "") add += s;
                    if (halves.length > 1) foreach (string s in halves[1].split ("\x1f")) if (s != "") rem += s;
                    yield backend.set_keywords (f, ids, add, rem);
                    break;
                }
                case "move": {
                    var dest = store.folder_by_path (account.id, arg);
                    if (dest == null) {
                        dest = new Folder ();
                        dest.account = account.id;
                        dest.path = arg;
                    }
                    yield backend.move (f, ids, dest);
                    break;
                }
                case "copy": {
                    var dest = store.folder_by_path (account.id, arg);
                    if (dest == null) {
                        dest = new Folder ();
                        dest.account = account.id;
                        dest.path = arg;
                    }
                    yield backend.copy (f, ids, dest);
                    break;
                }
                case "expunge":
                    yield backend.expunge (f, ids);
                    break;
            }
        }

        private async void replay_ops () throws Error {
            foreach (var op in store.ops (account.id)) {
                try {
                    yield apply_op (op.kind, op.folder, op.uids, op.arg);
                } catch (MailError.SERVER e) {
                    warning ("lettere: dropped %s on %s: %s", op.kind, op.folder, e.message);
                }
                store.remove_op (op.id);
            }
        }

        public async string append (Folder f, string flags, uint8[] raw) throws Error {
            if (f.local) {
                int flag_bits = 0;
                foreach (string fl in flags.split (" ")) flag_bits |= legacy_flag (fl);
                int64 id = store.insert_message (f, store.max_uid (f.id) + 1, flag_bits, raw.length, raw, new DateTime.now_utc ().to_unix ());
                store.set_body (id, raw);
                store.rethread (account.id);
                data_changed ();
                var m = store.message (id);
                return m != null ? m.ident : "";
            }
            yield ensure ();
            yield op_lock ();
            try {
                return yield backend.append (f, flags, raw);
            } finally {
                op_unlock ();
            }
        }

        public async void refresh_folder (Folder f) {
            if (!online || f.local) return;
            try {
                var fresh = new Gee.ArrayList<MessageInfo> ();
                yield sync_folder_locked (f, false, 20, fresh);
                store.rethread (account.id);
            } catch (Error e) {
                set_error (e);
            }
            data_changed ();
        }

        public async Gee.List<int64?> search_server (Folder f, SearchQuery query) throws Error {
            var ids = new Gee.ArrayList<int64?> ();
            if (f.local) return ids;
            yield ensure ();
            Gee.List<string> found = new Gee.ArrayList<string> ();
            yield op_lock ();
            try {
                found = yield backend.search (f, query);
            } finally {
                op_unlock ();
            }
            foreach (var r in found) {
                int64 id = store.id_for_rid (f.id, r);
                if (id != 0) ids.add (id);
            }
            return ids;
        }

        public async Quota? quota () throws Error {
            yield ensure ();
            yield op_lock ();
            try {
                return yield backend.quota ();
            } finally {
                op_unlock ();
            }
        }

        private void start_watch () {
            if (idle_running || stopped || work_offline) return;
            idle_running = true;
            watch_loop.begin ();
        }

        private async void watch_loop () {
            while (!stopped && !work_offline) {
                try {
                    idle_stop = new Cancellable ();
                    var stop = idle_stop;
                    uint limit = backend.can_push ? 25 * 60 : (uint) poll_seconds;
                    uint timer = Timeout.add_seconds (limit, () => {
                        stop.cancel ();
                        return Source.REMOVE;
                    });
                    bool changed;
                    if (backend.can_push) {
                        changed = yield backend.wait_changes (stop);
                    } else {
                        ulong h = stop.cancelled.connect (() => Idle.add (watch_loop.callback));
                        if (!stop.is_cancelled ()) yield;
                        stop.disconnect (h);
                        changed = !stopped && !work_offline;
                    }
                    if (!stop.is_cancelled ()) Source.remove (timer);
                    if (changed) yield sync_inbox ();
                } catch (Error e) {
                    var imap = backend as ImapBackend;
                    if (imap != null) imap.drop_idle ();
                    if (stopped || work_offline) break;
                    Timeout.add_seconds (30, () => {
                        watch_loop.callback ();
                        return Source.REMOVE;
                    });
                    yield;
                }
            }
            idle_running = false;
        }

        public async void send (OutboxItem item) throws Error {
            if (work_offline) throw new MailError.OFFLINE (_("Lettere is working offline"));
            var rcpts = new Gee.ArrayList<string> ();
            foreach (string r in item.recipients.split (",")) {
                if (r.strip () != "") rcpts.add (r.strip ());
            }
            if (backend.sends_mail) {
                yield ensure ();
                yield op_lock ();
                try {
                    yield backend.send (strip_bcc (item.raw), item.sender, rcpts);
                } finally {
                    op_unlock ();
                }
            } else {
                var smtp = new SmtpClient ();
                try {
                    yield smtp.open (account.smtp_host, account.smtp_port, account.smtp_security, account.trusted_smtp);
                } catch (MailError.TLS e) {
                    trust = smtp.tls_failure;
                    trust_kind = "smtp";
                    throw e;
                }
                string user = account.smtp_user != "" ? account.smtp_user : (account.imap_user != "" ? account.imap_user : account.email);
                yield sign_in_smtp (smtp, user);
                yield smtp.send (item.sender, rcpts, strip_bcc (item.raw));
                yield smtp.quit ();
            }
            if (backend.saves_sent || account.imap_host.down ().has_suffix ("gmail.com")) return;
            try {
                var sent = yield ensure_folder ("sent", "Sent");
                if (sent != null) {
                    yield append (sent, "\\Seen", strip_bcc (item.raw));
                    yield refresh_folder (sent);
                }
            } catch (Error e) {
                warning ("lettere: could not save a copy in Sent: %s", e.message);
            }
        }

        public static uint8[] strip_bcc (uint8[] raw) {
            string s = Mime.bytes_to_string (raw);
            int end = s.index_of ("\r\n\r\n");
            if (end < 0) return raw;
            string head = s.substring (0, end + 2);
            if (!head.down ().contains ("\nbcc:") && !head.down ().has_prefix ("bcc:")) return raw;
            var sb = new StringBuilder ();
            bool skipping = false;
            foreach (string line in head.split ("\r\n")) {
                if (line == "") continue;
                if (line[0] == ' ' || line[0] == '\t') {
                    if (!skipping) sb.append (line + "\r\n");
                    continue;
                }
                skipping = line.down ().has_prefix ("bcc:");
                if (!skipping) sb.append (line + "\r\n");
            }
            var b = new ByteArray ();
            b.append (sb.str.data);
            b.append (raw[end + 2:raw.length]);
            return b.steal ();
        }
    }
}
