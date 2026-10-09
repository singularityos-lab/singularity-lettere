namespace Singularity.Apps.Lettere {

    public class RemoteFolder {
        public string path = "";
        public string name = "";
        public string role = "";
        public string delimiter = "/";
        public string parent = "";
        public bool shared;
    }

    public class Quota {
        public int64 used;
        public int64 limit;
    }

    public class AutoReply {
        public bool enabled;
        public string subject = "";
        public string message = "";
        public string external_message = "";
        public int64 start;
        public int64 end;
        public bool external = true;
    }

    public abstract class MailBackend : Object {
        public Account account;
        public Store store;
        public int64 max_body_size = 4 * 1024 * 1024;
        public CertificateTrust? trust;
        public string trust_kind = "imap";
        public signal void changed_remotely ();

        public abstract bool online { get; }
        public virtual bool can_push { get { return false; } }
        public virtual bool sends_mail { get { return false; } }
        public virtual bool saves_sent { get { return false; } }
        public virtual bool supports_rules { get { return false; } }
        public virtual bool supports_auto_reply { get { return false; } }
        public virtual bool local_only { get { return false; } }
        public virtual string protocol_name { owned get { return "IMAP"; } }


        public abstract async void connect () throws Error;
        public abstract void disconnect ();
        public abstract async Gee.List<RemoteFolder> list_folders () throws Error;
        public abstract async void sync_folder (Folder f, bool notify, Gee.List<MessageInfo> fresh) throws Error;
        public abstract async void prefetch (Folder f, int limit) throws Error;
        public abstract async uint8[]? fetch_body (Folder f, MessageInfo m) throws Error;
        public virtual bool concurrent_bodies {
            get { return false; }
        }
        public abstract async void set_flags (Folder f, string ids, int flag, bool on) throws Error;
        public abstract async void set_keywords (Folder f, string ids, string[] add, string[] remove) throws Error;
        public abstract async void move (Folder f, string ids, Folder dest) throws Error;
        public abstract async void copy (Folder f, string ids, Folder dest) throws Error;
        public abstract async void expunge (Folder f, string ids) throws Error;
        public abstract async string append (Folder f, string flags, uint8[] raw) throws Error;
        public abstract async RemoteFolder create_folder (string name, Folder? parent) throws Error;
        public abstract async void rename_folder (Folder f, string name) throws Error;
        public abstract async void delete_folder (Folder f) throws Error;
        public abstract async Gee.List<string> search (Folder f, SearchQuery q) throws Error;
        public abstract async bool wait_changes (Cancellable stop) throws Error;

        public virtual async void send (uint8[] raw, string sender, Gee.List<string> recipients) throws Error {
            throw new MailError.PROTOCOL (_("This account sends mail through SMTP"));
        }

        public virtual async Quota? quota () throws Error {
            return null;
        }

        public virtual async AutoReply get_auto_reply () throws Error {
            throw new MailError.PROTOCOL (_("Automatic replies are not available for this account"));
        }

        public virtual async void set_auto_reply (AutoReply r) throws Error {
            throw new MailError.PROTOCOL (_("Automatic replies are not available for this account"));
        }

        public virtual async string get_rules_script () throws Error {
            throw new MailError.PROTOCOL (_("Server rules are not available for this account"));
        }

        public virtual async void put_rules_script (string script) throws Error {
            throw new MailError.PROTOCOL (_("Server rules are not available for this account"));
        }

        public virtual async void upload_rules (RuleStore rules) throws Error {
            throw new MailError.PROTOCOL (_("Server rules are not available for this account"));
        }

        public virtual async Gee.List<RemoteFolder> open_shared (string mailbox) throws Error {
            throw new MailError.PROTOCOL (_("Shared mailboxes are not available for this account"));
        }

        public static string flag_keyword (int flag) {
            switch (flag) {
                case MessageFlags.SEEN: return "\\Seen";
                case MessageFlags.FLAGGED: return "\\Flagged";
                case MessageFlags.ANSWERED: return "\\Answered";
                case MessageFlags.DELETED: return "\\Deleted";
                case MessageFlags.DRAFT: return "\\Draft";
                case MessageFlags.FORWARDED: return "$Forwarded";
                case MessageFlags.COMPLETED: return "$Completed";
                case MessageFlags.PINNED: return "$Pinned";
                case MessageFlags.JUNK: return "$Junk";
                case MessageFlags.NOT_JUNK: return "$NotJunk";
                case MessageFlags.MDN_SENT: return "$MDNSent";
            }
            return "\\Seen";
        }

        public static string jmap_keyword (int flag) {
            switch (flag) {
                case MessageFlags.SEEN: return "$seen";
                case MessageFlags.FLAGGED: return "$flagged";
                case MessageFlags.ANSWERED: return "$answered";
                case MessageFlags.DRAFT: return "$draft";
                case MessageFlags.FORWARDED: return "$forwarded";
                case MessageFlags.COMPLETED: return "$completed";
                case MessageFlags.PINNED: return "$pinned";
                case MessageFlags.JUNK: return "$junk";
                case MessageFlags.NOT_JUNK: return "$notjunk";
                case MessageFlags.MDN_SENT: return "$mdnsent";
            }
            return "$seen";
        }

        public static string synth_header (string from, string to, string cc, string subject, int64 date, string message_id, string in_reply_to, string references, string extra = "") {
            var sb = new StringBuilder ();
            if (from != "") sb.append ("From: " + from + "\r\n");
            if (to != "") sb.append ("To: " + to + "\r\n");
            if (cc != "") sb.append ("Cc: " + cc + "\r\n");
            sb.append ("Subject: " + Mime.encode_words (subject) + "\r\n");
            sb.append ("Date: " + Mime.format_date (new DateTime.from_unix_local (date > 0 ? date : new DateTime.now_utc ().to_unix ())) + "\r\n");
            if (message_id != "") sb.append ("Message-ID: <" + Mime.first_id (message_id) + ">\r\n");
            if (in_reply_to != "") sb.append ("In-Reply-To: <" + Mime.first_id (in_reply_to) + ">\r\n");
            if (references != "") sb.append ("References: " + references + "\r\n");
            sb.append (extra);
            sb.append ("\r\n");
            return sb.str;
        }
    }

    public class ImapBackend : MailBackend {
        public ImapClient? conn;
        private ImapClient? idle_conn;
        private unowned AccountSync owner;
        private Gee.HashMap<string, string> namespaces = new Gee.HashMap<string, string> ();

        public ImapBackend (AccountSync owner) {
            this.owner = owner;
            this.account = owner.account;
            this.store = owner.store;
        }

        public override bool online {
            get { return conn != null && conn.connected; }
        }

        public override bool can_push {
            get { return conn != null && conn.has_cap ("IDLE"); }
        }

        public override bool supports_rules {
            get { return true; }
        }

        public override bool supports_auto_reply {
            get { return true; }
        }

        private async ImapClient open_client () throws Error {
            var c = new ImapClient ();
            c.debug = (Environment.get_variable ("LETTERE_DEBUG") ?? "") != "";
            try {
                yield c.open (account.imap_host, account.imap_port, account.imap_security, account.trusted_imap);
            } catch (MailError.TLS e) {
                trust = c.tls_failure;
                trust_kind = "imap";
                throw e;
            }
            string user = account.imap_user != "" ? account.imap_user : account.email;
            yield owner.sign_in_imap (c, user);
            yield c.enable_condstore ();
            return c;
        }

        private bool connecting;
        private Gee.ArrayList<ConnectWaiter> connect_waiters = new Gee.ArrayList<ConnectWaiter> ();

        public override async void connect () throws Error {
            while (connecting) {
                connect_waiters.add (new ConnectWaiter (connect.callback));
                yield;
            }
            if (conn != null && conn.connected) return;
            connecting = true;
            ImapClient? c = null;
            try {
                c = yield open_client ();
            } finally {
                connecting = false;
                var waiting = connect_waiters;
                connect_waiters = new Gee.ArrayList<ConnectWaiter> ();
                foreach (var w in waiting) Idle.add ((owned) w.resume);
            }
            conn = c;
            c.closed.connect (() => {
                if (conn == c) conn = null;
            });
            namespaces.clear ();
            if (conn.has_cap ("NAMESPACE")) {
                try {
                    foreach (var r in yield conn.run ("NAMESPACE")) {
                        if (r.tag != "*" || r.word (0) != "NAMESPACE" || r.values.size < 4) continue;
                        for (int kind = 2; kind <= 3; kind++) {
                            var v = r.values[kind];
                            if (!v.is_list) continue;
                            foreach (var ns in v.items) {
                                if (!ns.is_list || ns.items.size < 1) continue;
                                string prefix = Utf7.decode (ns.items[0].str ());
                                if (prefix != "") namespaces[prefix] = ns.items.size > 1 ? ns.items[1].str () : "/";
                            }
                        }
                    }
                } catch (Error e) {
                }
            }
        }

        public override void disconnect () {
            if (idle_conn != null) idle_conn.close ();
            idle_conn = null;
            if (conn != null) conn.close ();
            conn = null;
        }

        public void logout () {
            if (idle_conn != null) idle_conn.close ();
            idle_conn = null;
            if (conn != null) conn.logout.begin ();
            conn = null;
        }

        private RemoteFolder remote_of (MailboxInfo b, bool shared) {
            var r = new RemoteFolder ();
            r.path = b.name;
            r.delimiter = b.delimiter;
            string leaf = b.name;
            if (b.delimiter != "" && leaf.contains (b.delimiter)) {
                r.parent = leaf.substring (0, leaf.last_index_of (b.delimiter));
                leaf = leaf.substring (leaf.last_index_of (b.delimiter) + b.delimiter.length);
            }
            r.name = leaf;
            r.role = shared ? "" : AccountSync.role_for (b);
            r.shared = shared;
            return r;
        }

        public override async Gee.List<RemoteFolder> list_folders () throws Error {
            var list = new Gee.ArrayList<RemoteFolder> ();
            var boxes = yield conn.list ();
            var seen = new Gee.HashSet<string> ();
            foreach (var b in boxes) {
                bool shared = false;
                foreach (string prefix in namespaces.keys) if (b.name.has_prefix (prefix)) shared = true;
                seen.add (b.name);
                list.add (remote_of (b, shared));
            }
            foreach (string prefix in namespaces.keys) {
                try {
                    foreach (var b in yield conn.list_pattern (prefix + "*")) {
                        if (!seen.add (b.name)) continue;
                        list.add (remote_of (b, true));
                    }
                } catch (Error e) {
                }
            }
            foreach (string extra in account.shared_mailboxes ()) {
                try {
                    foreach (var b in yield conn.list_pattern (extra + "*")) {
                        if (!seen.add (b.name)) continue;
                        list.add (remote_of (b, true));
                    }
                } catch (Error e) {
                }
            }
            return list;
        }

        public override async Gee.List<RemoteFolder> open_shared (string mailbox) throws Error {
            yield connect ();
            var list = new Gee.ArrayList<RemoteFolder> ();
            var candidates = new Gee.ArrayList<string> ();
            foreach (var e in namespaces.entries) candidates.add (e.key + mailbox + e.value);
            candidates.add (mailbox + "/");
            candidates.add ("user/" + mailbox + "/");
            candidates.add ("Other Users/" + mailbox + "/");
            candidates.add ("shared/" + mailbox + "/");
            foreach (string c in candidates) {
                Gee.List<MailboxInfo> found;
                try {
                    found = yield conn.list_pattern (c + "*");
                } catch (Error e) {
                    continue;
                }
                var parent = yield conn.list_pattern (c.substring (0, c.length - 1));
                foreach (var b in parent) list.add (remote_of (b, true));
                foreach (var b in found) list.add (remote_of (b, true));
                if (list.size > 0) {
                    account.add_shared_mailbox (c.substring (0, c.length - 1));
                    return list;
                }
            }
            throw new MailError.SERVER (_("The server has no mailbox called %s that you can open").printf (mailbox));
        }

        private int64 parse_internal (string s) {
            string[] p = s.replace ("-", " ").split (" ");
            if (p.length >= 4) {
                var d = Mime.parse_date ("%s %s %s %s".printf (p[0], p[1], p[2], string.joinv (" ", p[3:p.length])));
                if (d != null) return d.to_unix ();
            }
            return new DateTime.now_utc ().to_unix ();
        }

        public const string HEADER_FIELDS = "FROM TO CC SUBJECT DATE MESSAGE-ID IN-REPLY-TO REFERENCES CONTENT-TYPE LIST-UNSUBSCRIBE LIST-UNSUBSCRIBE-POST LIST-ID PRECEDENCE AUTO-SUBMITTED IMPORTANCE X-PRIORITY X-MSMAIL-PRIORITY DISPOSITION-NOTIFICATION-TO REPLY-TO";

        public override async void sync_folder (Folder f, bool notify, Gee.List<MessageInfo> fresh) throws Error {
            var c = conn;
            SelectInfo info;
            try {
                info = yield c.select (f.path);
            } catch (MailError.SERVER e) {
                return;
            }
            if (f.uidvalidity != 0 && info.uidvalidity != f.uidvalidity) {
                store.clear_folder (f.id);
                f.modseq = 0;
                f.uidnext = 0;
            }
            bool initial = f.uidnext == 0;
            int64 max_uid = store.max_uid (f.id);
            string header_items = "UID FLAGS INTERNALDATE RFC822.SIZE BODY.PEEK[HEADER.FIELDS (" + HEADER_FIELDS + ")]";
            if (info.exists > 0 && (info.uidnext == 0 || info.uidnext > max_uid + 1)) {
                string range = (max_uid + 1).to_string () + ":*";
                if (max_uid == 0 && info.exists > 2000) {
                    var all = yield c.search ("ALL");
                    if (all.size > 2000) range = all[all.size - 2000].to_string () + ":*";
                }
                var items = yield c.fetch (range, header_items);
                store.begin ();
                foreach (var it in items) {
                    if (it.uid <= max_uid || it.header == null) continue;
                    if (store.id_for_uid (f.id, it.uid) != 0) continue;
                    int flags = Store.flags_from (it.flags);
                    int64 id = store.insert_message (f, it.uid, flags, it.size, it.header, parse_internal (it.internaldate), "", "", Store.keywords_from (it.flags));
                    if (notify && !initial && (flags & MessageFlags.SEEN) == 0) {
                        var m = store.message (id);
                        if (m != null) fresh.add (m);
                    }
                }
                store.commit ();
            }
            if (max_uid > 0) {
                var local = store.uid_flags (f.id);
                bool condstore = c.has_cap ("CONDSTORE") && f.modseq > 0 && info.highestmodseq > 0;
                if (!condstore || info.highestmodseq != f.modseq) {
                    string modifier = condstore ? "(CHANGEDSINCE " + f.modseq.to_string () + ")" : "";
                    var changes = yield c.fetch ("1:" + max_uid.to_string (), "UID FLAGS", modifier);
                    store.begin ();
                    foreach (var it in changes) {
                        if (!it.has_flags || !local.has_key (it.uid)) continue;
                        int fl = Store.flags_from (it.flags);
                        int64 id = store.id_for_uid (f.id, it.uid);
                        if (id == 0) continue;
                        var m = store.message (id);
                        string kw = Store.keywords_from (it.flags);
                        if (m != null && (m.flags != fl || m.keywords != kw)) store.set_state (id, fl, kw);
                    }
                    store.commit ();
                }
                store.count_folder (f);
                if (info.exists != f.total) {
                    var server = yield c.search ("ALL");
                    var present = new Gee.HashSet<int64?> ((v) => int64_hash (v), (a, b) => a == b);
                    foreach (var u in server) present.add (u);
                    store.begin ();
                    foreach (var u in store.uid_flags (f.id).keys) {
                        if (!present.contains (u)) store.delete_uid (f.id, u);
                    }
                    store.commit ();
                }
            }
            f.uidvalidity = info.uidvalidity;
            f.uidnext = info.uidnext > 0 ? info.uidnext : store.max_uid (f.id) + 1;
            f.modseq = info.highestmodseq;
            store.set_folder_state (f);
        }

        public override async void prefetch (Folder f, int limit) throws Error {
            var c = conn;
            var uids = store.missing_bodies (f.id, max_body_size, limit);
            if (uids.size == 0) return;
            if (c.selected != f.path) yield c.select (f.path);
            for (int i = 0; i < uids.size; i += 10) {
                var chunk = new Gee.ArrayList<string> ();
                for (int k = i; k < int.min (i + 10, uids.size); k++) chunk.add (uids[k].to_string ());
                var items = yield c.fetch (string.joinv (",", chunk.to_array ()), "UID BODY.PEEK[]");
                store.begin ();
                foreach (var it in items) {
                    if (it.body == null) continue;
                    int64 id = store.id_for_uid (f.id, it.uid);
                    if (id != 0) store.set_body (id, it.body);
                }
                store.commit ();
            }
        }

        public override async uint8[]? fetch_body (Folder f, MessageInfo m) throws Error {
            var c = conn;
            if (c.selected != f.path) yield c.select (f.path);
            var items = yield c.fetch (m.uid.to_string (), "UID BODY.PEEK[]");
            foreach (var it in items) {
                if (it.uid == m.uid && it.body != null) return it.body;
            }
            return null;
        }

        private async void select (Folder f) throws Error {
            if (conn.selected != f.path) yield conn.select (f.path);
        }

        public override async void set_flags (Folder f, string ids, int flag, bool on) throws Error {
            yield select (f);
            yield conn.store_flags (ids, on ? "+FLAGS" : "-FLAGS", flag_keyword (flag));
        }

        public override async void set_keywords (Folder f, string ids, string[] add, string[] remove) throws Error {
            yield select (f);
            string[] a = {};
            foreach (string k in add) a += Keywords.to_keyword (k);
            string[] r = {};
            foreach (string k in remove) r += Keywords.to_keyword (k);
            if (a.length > 0) yield conn.store_flags (ids, "+FLAGS", string.joinv (" ", a));
            if (r.length > 0) yield conn.store_flags (ids, "-FLAGS", string.joinv (" ", r));
        }

        public override async void move (Folder f, string ids, Folder dest) throws Error {
            yield select (f);
            yield conn.move (ids, dest.path);
        }

        public override async void copy (Folder f, string ids, Folder dest) throws Error {
            yield select (f);
            yield conn.run ("UID COPY %s %s".printf (ids, ImapClient.mailbox_arg (dest.path)));
        }

        public override async void expunge (Folder f, string ids) throws Error {
            yield select (f);
            yield conn.store_flags (ids, "+FLAGS", "\\Deleted");
            yield conn.expunge (ids);
        }

        public override async string append (Folder f, string flags, uint8[] raw) throws Error {
            int64 uid = yield conn.append (f.path, flags, raw);
            return uid > 0 ? uid.to_string () : "";
        }

        public override async RemoteFolder create_folder (string name, Folder? parent) throws Error {
            string delim = parent != null && parent.delimiter != "" ? parent.delimiter : "/";
            string path = parent != null ? parent.path + delim + name : name;
            yield conn.create (path);
            try {
                yield conn.run ("SUBSCRIBE " + ImapClient.mailbox_arg (path));
            } catch (Error e) {
            }
            var r = new RemoteFolder ();
            r.path = path;
            r.name = name;
            r.delimiter = delim;
            r.parent = parent != null ? parent.path : "";
            return r;
        }

        public override async void rename_folder (Folder f, string name) throws Error {
            string path = f.parent != "" ? f.parent + f.delimiter + name : name;
            if (conn.selected == f.path) conn.selected = "";
            yield conn.run ("RENAME %s %s".printf (ImapClient.mailbox_arg (f.path), ImapClient.mailbox_arg (path)));
            try {
                yield conn.run ("SUBSCRIBE " + ImapClient.mailbox_arg (path));
            } catch (Error e) {
            }
        }

        public override async void delete_folder (Folder f) throws Error {
            if (conn.selected == f.path) {
                try {
                    yield conn.run ("UNSELECT");
                } catch (Error e) {
                }
                conn.selected = "";
            }
            yield conn.run ("DELETE " + ImapClient.mailbox_arg (f.path));
        }

        public override async Gee.List<string> search (Folder f, SearchQuery q) throws Error {
            yield select (f);
            var list = new Gee.ArrayList<string> ();
            foreach (var u in yield conn.search (q.to_imap ())) list.add (u.to_string ());
            return list;
        }

        public override async bool wait_changes (Cancellable stop) throws Error {
            if (idle_conn == null || !idle_conn.connected) {
                idle_conn = yield open_client ();
                idle_conn.set_idle_timeout (0);
                yield idle_conn.select ("INBOX", true);
            }
            return yield idle_conn.idle (stop);
        }

        public void drop_idle () {
            if (idle_conn != null) idle_conn.close ();
            idle_conn = null;
        }

        public override async Quota? quota () throws Error {
            if (!conn.has_cap ("QUOTA")) return null;
            var q = new Quota ();
            bool found = false;
            foreach (var r in yield conn.run ("GETQUOTAROOT INBOX")) {
                if (r.tag != "*" || r.word (0) != "QUOTA" || r.values.size < 3 || !r.values[2].is_list) continue;
                var items = r.values[2].items;
                for (int i = 0; i + 2 < items.size; i += 3) {
                    if (items[i].text.up () == "STORAGE") {
                        q.used = items[i + 1].number () * 1024;
                        q.limit = items[i + 2].number () * 1024;
                        found = true;
                    }
                }
            }
            return found ? q : null;
        }

        private async SieveClient sieve () throws Error {
            var s = new SieveClient ();
            string host = account.sieve_host != "" ? account.sieve_host : account.imap_host;
            yield s.open (host, account.sieve_port > 0 ? (uint16) account.sieve_port : 4190, account.trusted_imap);
            string user = account.imap_user != "" ? account.imap_user : account.email;
            var login = yield owner.current_login ();
            if (login.is_token) yield s.login_xoauth2 (login.xoauth2);
            else yield s.login (user, login.secret);
            return s;
        }

        public override async string get_rules_script () throws Error {
            var s = yield sieve ();
            try {
                return yield s.get_script ("lettere");
            } finally {
                s.close ();
            }
        }

        public override async void put_rules_script (string script) throws Error {
            var s = yield sieve ();
            try {
                yield s.put_script ("lettere", script);
                yield s.activate ("lettere");
            } finally {
                s.close ();
            }
        }

        public override async void upload_rules (RuleStore rules) throws Error {
            var paths = new Gee.HashMap<string, string> ();
            foreach (var f in store.folders (account.id)) {
                paths[f.path] = f.path;
                if (f.role != "") paths["role:" + f.role] = f.path;
            }
            string script = "";
            try {
                script = yield get_rules_script ();
            } catch (Error e) {
            }
            yield put_rules_script (SieveScript.with_rules (script, rules.to_sieve (account.id, paths)));
        }

        public override async AutoReply get_auto_reply () throws Error {
            string script = yield get_rules_script ();
            return SieveScript.parse_vacation (script);
        }

        public override async void set_auto_reply (AutoReply r) throws Error {
            string script = "";
            try {
                script = yield get_rules_script ();
            } catch (Error e) {
            }
            yield put_rules_script (SieveScript.with_vacation (script, r, account.email));
        }
    }

    public class ConnectWaiter {
        public SourceFunc resume;

        public ConnectWaiter (owned SourceFunc resume) {
            this.resume = (owned) resume;
        }
    }
}
