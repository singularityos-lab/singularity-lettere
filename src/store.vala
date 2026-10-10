namespace Singularity.Apps.Lettere {

    [Flags]
    public enum MessageFlags {
        SEEN = 1,
        FLAGGED = 2,
        ANSWERED = 4,
        DRAFT = 8,
        DELETED = 16,
        FORWARDED = 32,
        COMPLETED = 64,
        PINNED = 128,
        JUNK = 256,
        NOT_JUNK = 512,
        MDN_SENT = 1024
    }

    public enum SortKey {
        DATE,
        SENDER,
        SUBJECT,
        SIZE,
        FLAGGED,
        UNREAD;

        public string to_id () {
            switch (this) {
                case SENDER: return "sender";
                case SUBJECT: return "subject";
                case SIZE: return "size";
                case FLAGGED: return "flagged";
                case UNREAD: return "unread";
                default: return "date";
            }
        }

        public static SortKey from_id (string id) {
            switch (id) {
                case "sender": return SENDER;
                case "subject": return SUBJECT;
                case "size": return SIZE;
                case "flagged": return FLAGGED;
                case "unread": return UNREAD;
                default: return DATE;
            }
        }
    }

    public enum ListFilter {
        ALL,
        UNREAD,
        FLAGGED,
        ATTACHMENTS,
        MENTIONS,
        FOCUSED,
        OTHER;

        public string to_id () {
            switch (this) {
                case UNREAD: return "unread";
                case FLAGGED: return "flagged";
                case ATTACHMENTS: return "attachments";
                case MENTIONS: return "mentions";
                case FOCUSED: return "focused";
                case OTHER: return "other";
                default: return "all";
            }
        }

        public static ListFilter from_id (string id) {
            switch (id) {
                case "unread": return UNREAD;
                case "flagged": return FLAGGED;
                case "attachments": return ATTACHMENTS;
                case "mentions": return MENTIONS;
                case "focused": return FOCUSED;
                case "other": return OTHER;
                default: return ALL;
            }
        }
    }

    public class ListOptions {
        public SortKey sort = SortKey.DATE;
        public bool ascending;
        public ListFilter filter = ListFilter.ALL;
        public string mention = "";
        public int limit = 3000;
    }

    public class Folder : Object {
        public int64 id { get; set; }
        public string account { get; set; default = ""; }
        public string path { get; set; default = ""; }
        public string name { get; set; default = ""; }
        public string role { get; set; default = ""; }
        public string delimiter { get; set; default = "/"; }
        public int64 uidvalidity { get; set; }
        public int64 uidnext { get; set; }
        public int64 modseq { get; set; }
        public int unread { get; set; }
        public int total { get; set; }
        public string sync_state { get; set; default = ""; }
        public string parent { get; set; default = ""; }
        public bool favorite { get; set; }
        public bool local { get; set; }
        public bool shared { get; set; }

        public int sort_key {
            get {
                switch (role) {
                    case "inbox": return 0;
                    case "drafts": return 1;
                    case "sent": return 2;
                    case "scheduled": return 3;
                    case "snoozed": return 4;
                    case "archive": return 5;
                    case "junk": return 6;
                    case "trash": return 7;
                    default: return 10;
                }
            }
        }

        public string icon_name {
            owned get {
                switch (role) {
                    case "inbox": return "mail-inbox-symbolic";
                    case "drafts": return "document-edit-symbolic";
                    case "sent": return "mail-send-symbolic";
                    case "archive": return "mail-archive-symbolic";
                    case "junk": return "mail-mark-junk-symbolic";
                    case "trash": return "user-trash-symbolic";
                    case "snoozed": return "alarm-symbolic";
                    case "scheduled": return "document-open-recent-symbolic";
                    default: return shared ? "folder-publicshare-symbolic" : "folder-symbolic";
                }
            }
        }

        public string display_name {
            owned get {
                switch (role) {
                    case "inbox": return _("Inbox");
                    case "drafts": return _("Drafts");
                    case "sent": return _("Sent");
                    case "archive": return _("Archive");
                    case "junk": return _("Junk");
                    case "trash": return _("Trash");
                    case "snoozed": return _("Snoozed");
                    case "scheduled": return _("Scheduled");
                    default: return name;
                }
            }
        }

        public int depth {
            get {
                if (delimiter == "" || role == "inbox") return 0;
                int d = 0;
                int pos = 0;
                while ((pos = path.index_of (delimiter, pos)) >= 0) {
                    d++;
                    pos += delimiter.length;
                }
                if (path.has_prefix ("INBOX" + delimiter) && d > 0) d--;
                return d;
            }
        }
    }

    public class MessageInfo : Object {
        public int64 id { get; set; }
        public int64 folder { get; set; }
        public string account { get; set; default = ""; }
        public int64 uid { get; set; }
        public string rid { get; set; default = ""; }
        public string message_id { get; set; default = ""; }
        public string in_reply_to { get; set; default = ""; }
        public string references { get; set; default = ""; }
        public string thread { get; set; default = ""; }
        public string conv { get; set; default = ""; }
        public string subject { get; set; default = ""; }
        public string sender_name { get; set; default = ""; }
        public string sender_email { get; set; default = ""; }
        public string to_list { get; set; default = ""; }
        public string cc_list { get; set; default = ""; }
        public int64 date { get; set; }
        public int flags { get; set; }
        public int64 size { get; set; }
        public bool has_attachment { get; set; }
        public string preview { get; set; default = ""; }
        public bool has_body { get; set; }
        public string keywords { get; set; default = ""; }
        public int importance { get; set; }
        public int focus { get; set; default = -1; }
        public int64 due { get; set; }
        public string list_unsubscribe { get; set; default = ""; }
        public string list_id { get; set; default = ""; }
        public string receipt_to { get; set; default = ""; }
        public int thread_count { get; set; default = 1; }
        public bool thread_unread { get; set; }
        public bool thread_flagged { get; set; }
        public string participants { get; set; default = ""; }

        public bool unread {
            get { return (flags & MessageFlags.SEEN) == 0; }
        }

        public bool flagged {
            get { return (flags & MessageFlags.FLAGGED) != 0; }
        }

        public bool completed {
            get { return (flags & MessageFlags.COMPLETED) != 0; }
        }

        public bool pinned {
            get { return (flags & MessageFlags.PINNED) != 0; }
        }

        public string sender_display {
            owned get { return sender_name != "" ? sender_name : sender_email; }
        }

        public string ident {
            owned get { return rid != "" ? rid : uid.to_string (); }
        }

        public string[] categories () {
            string[] outv = {};
            foreach (string k in keywords.split ("\x1f")) {
                if (k != "") outv += k;
            }
            return outv;
        }

        public bool has_category (string name) {
            foreach (string k in categories ()) if (k.down () == name.down ()) return true;
            return false;
        }
    }

    public class OutboxItem {
        public int64 id;
        public string account;
        public uint8[] raw;
        public string recipients;
        public string sender;
        public int64 send_at;
        public string error;
        public string subject = "";
    }

    public class PendingOp {
        public int64 id;
        public string account;
        public string kind;
        public string folder;
        public string uids;
        public string arg;
    }

    public class SnoozeItem {
        public int64 id;
        public string account;
        public string message_id;
        public int64 until;
        public string origin;
        public string subject;
    }

    public class Store : Object {
        public signal void changed (string account);
        public signal void folders_changed (string account);

        private Sqlite.Database db;
        public string path { get; private set; }

        public Store (string path) throws Error {
            this.path = path;
            DirUtils.create_with_parents (Path.get_dirname (path), 0700);
            if (Sqlite.Database.open_v2 (path, out db) != Sqlite.OK) throw new IOError.FAILED ("Cannot open %s".printf (path));
            FileUtils.chmod (path, 0600);
            exec ("PRAGMA journal_mode=WAL");
            exec ("PRAGMA synchronous=NORMAL");
            exec ("PRAGMA foreign_keys=ON");
            exec ("""CREATE TABLE IF NOT EXISTS folders (
                id INTEGER PRIMARY KEY, account TEXT NOT NULL, path TEXT NOT NULL, name TEXT, role TEXT, delim TEXT,
                uidvalidity INTEGER DEFAULT 0, uidnext INTEGER DEFAULT 0, modseq INTEGER DEFAULT 0,
                UNIQUE(account, path))""");
            exec ("""CREATE TABLE IF NOT EXISTS messages (
                id INTEGER PRIMARY KEY, folder INTEGER NOT NULL REFERENCES folders(id) ON DELETE CASCADE, account TEXT NOT NULL,
                uid INTEGER NOT NULL, message_id TEXT, in_reply_to TEXT, refs TEXT, thread TEXT, subject TEXT,
                sender_name TEXT, sender_email TEXT, to_list TEXT, cc_list TEXT, date INTEGER, flags INTEGER DEFAULT 0,
                size INTEGER DEFAULT 0, has_attach INTEGER DEFAULT 0, preview TEXT DEFAULT '', raw BLOB,
                UNIQUE(folder, uid))""");
            add_column ("folders", "sync_state", "TEXT DEFAULT ''");
            add_column ("folders", "parent", "TEXT DEFAULT ''");
            add_column ("folders", "favorite", "INTEGER DEFAULT 0");
            add_column ("folders", "local", "INTEGER DEFAULT 0");
            add_column ("folders", "shared", "INTEGER DEFAULT 0");
            add_column ("messages", "rid", "TEXT DEFAULT ''");
            add_column ("messages", "conv", "TEXT DEFAULT ''");
            add_column ("messages", "keywords", "TEXT DEFAULT ''");
            add_column ("messages", "importance", "INTEGER DEFAULT 0");
            add_column ("messages", "focus", "INTEGER DEFAULT -1");
            add_column ("messages", "due", "INTEGER DEFAULT 0");
            add_column ("messages", "list_unsub", "TEXT DEFAULT ''");
            add_column ("messages", "list_id", "TEXT DEFAULT ''");
            add_column ("messages", "receipt_to", "TEXT DEFAULT ''");
            exec ("CREATE INDEX IF NOT EXISTS messages_thread ON messages(account, thread)");
            exec ("CREATE INDEX IF NOT EXISTS messages_date ON messages(folder, date)");
            exec ("CREATE INDEX IF NOT EXISTS messages_mid ON messages(account, message_id)");
            exec ("CREATE INDEX IF NOT EXISTS messages_rid ON messages(folder, rid)");
            exec ("CREATE VIRTUAL TABLE IF NOT EXISTS search USING fts5(subject, sender, recipients, body, tokenize='unicode61 remove_diacritics 2')");
            exec ("""CREATE TABLE IF NOT EXISTS addresses (email TEXT PRIMARY KEY, name TEXT, uses INTEGER DEFAULT 0, last INTEGER DEFAULT 0)""");
            exec ("""CREATE TABLE IF NOT EXISTS outbox (id INTEGER PRIMARY KEY, account TEXT, raw BLOB, recipients TEXT, sender TEXT, send_at INTEGER, error TEXT DEFAULT '')""");
            add_column ("outbox", "subject", "TEXT DEFAULT ''");
            exec ("""CREATE TABLE IF NOT EXISTS ops (id INTEGER PRIMARY KEY, account TEXT, kind TEXT, folder TEXT, uids TEXT, arg TEXT)""");
            exec ("""CREATE TABLE IF NOT EXISTS kv (account TEXT NOT NULL, key TEXT NOT NULL, value TEXT, PRIMARY KEY(account, key))""");
            exec ("""CREATE TABLE IF NOT EXISTS snoozes (id INTEGER PRIMARY KEY, account TEXT, message_id TEXT, until INTEGER, origin TEXT, subject TEXT)""");
            exec ("""CREATE TABLE IF NOT EXISTS focus_senders (email TEXT PRIMARY KEY, focus INTEGER)""");
            exec ("""CREATE TABLE IF NOT EXISTS junk_tokens (token TEXT PRIMARY KEY, good INTEGER DEFAULT 0, bad INTEGER DEFAULT 0)""");
        }

        private void add_column (string table, string column, string decl) {
            var st = prepare ("PRAGMA table_info(%s)".printf (table));
            while (st.step () == Sqlite.ROW) {
                if (text (st, 1) == column) return;
            }
            exec ("ALTER TABLE %s ADD COLUMN %s %s".printf (table, column, decl));
        }

        public void exec (string sql) {
            string? err;
            if (db.exec (sql, null, out err) != Sqlite.OK) warning ("lettere sql: %s (%s)", err ?? "", sql);
        }

        private Sqlite.Statement prepare (string sql) {
            Sqlite.Statement st;
            if (db.prepare_v2 (sql, -1, out st) != Sqlite.OK) warning ("lettere sql: %s (%s)", db.errmsg (), sql);
            return st;
        }

        public void begin () {
            exec ("BEGIN");
        }

        public void commit () {
            exec ("COMMIT");
        }

        private static string text (Sqlite.Statement st, int col) {
            unowned string? s = st.column_text (col);
            return s ?? "";
        }

        private Folder read_folder (Sqlite.Statement st) {
            var f = new Folder ();
            f.id = st.column_int64 (0);
            f.account = text (st, 1);
            f.path = text (st, 2);
            f.name = text (st, 3);
            f.role = text (st, 4);
            f.delimiter = text (st, 5);
            f.uidvalidity = st.column_int64 (6);
            f.uidnext = st.column_int64 (7);
            f.modseq = st.column_int64 (8);
            f.sync_state = text (st, 9);
            f.parent = text (st, 10);
            f.favorite = st.column_int (11) != 0;
            f.local = st.column_int (12) != 0;
            f.shared = st.column_int (13) != 0;
            return f;
        }

        private const string FOLDER_COLS = "id, account, path, name, role, delim, uidvalidity, uidnext, modseq, sync_state, parent, favorite, local, shared";

        public Variant recent_with (string[] emails, int limit) {
            var result = new VariantBuilder (new VariantType ("a(xsxb)"));
            if (emails.length == 0) return result.end ();
            var where = new StringBuilder ();
            for (int i = 0; i < emails.length; i++) {
                if (i > 0) where.append (" OR ");
                where.append ("lower(sender_email) = ? OR lower(to_list) LIKE ? OR lower(cc_list) LIKE ?");
            }
            string sql = "SELECT id, subject, date, sender_email FROM messages WHERE %s ORDER BY date DESC LIMIT %d".printf (where.str, int.max (1, limit) * 3);
            Sqlite.Statement st;
            if (db.prepare_v2 (sql, -1, out st) != Sqlite.OK) return result.end ();
            int n = 1;
            foreach (string e in emails) {
                string low = e.down ();
                st.bind_text (n++, low);
                st.bind_text (n++, "%" + low + "%");
                st.bind_text (n++, "%" + low + "%");
            }
            var seen = new Gee.HashSet<string> ();
            int count = 0;
            while (st.step () == Sqlite.ROW && count < limit) {
                string subject = st.column_text (1) ?? "";
                int64 date = st.column_int64 (2);
                string sender = (st.column_text (3) ?? "").down ();
                bool from_them = false;
                foreach (string e in emails) if (e.down () == sender) from_them = true;
                if (!seen.add (subject + date.to_string ())) continue;
                result.add ("(xsxb)", st.column_int64 (0), subject, date, from_them);
                count++;
            }
            return result.end ();
        }

        public Gee.ArrayList<Folder> folders (string account) {
            var list = new Gee.ArrayList<Folder> ();
            var st = prepare ("SELECT " + FOLDER_COLS + " FROM folders WHERE account = ?");
            st.bind_text (1, account);
            while (st.step () == Sqlite.ROW) list.add (read_folder (st));
            foreach (var f in list) count_folder (f);
            list.sort ((a, b) => {
                if (a.sort_key != b.sort_key) return a.sort_key - b.sort_key;
                if (a.shared != b.shared) return a.shared ? 1 : -1;
                return a.path.collate (b.path);
            });
            return list;
        }

        public Gee.ArrayList<Folder> favorites () {
            var list = new Gee.ArrayList<Folder> ();
            var st = prepare ("SELECT " + FOLDER_COLS + " FROM folders WHERE favorite = 1 ORDER BY account, path");
            while (st.step () == Sqlite.ROW) list.add (read_folder (st));
            foreach (var f in list) count_folder (f);
            return list;
        }

        public Folder? folder (int64 id) {
            var st = prepare ("SELECT " + FOLDER_COLS + " FROM folders WHERE id = ?");
            st.bind_int64 (1, id);
            if (st.step () != Sqlite.ROW) return null;
            var f = read_folder (st);
            count_folder (f);
            return f;
        }

        public Folder? folder_by_role (string account, string role) {
            foreach (var f in folders (account)) if (f.role == role) return f;
            return null;
        }

        public Folder? folder_by_path (string account, string path) {
            var st = prepare ("SELECT " + FOLDER_COLS + " FROM folders WHERE account = ? AND path = ?");
            st.bind_text (1, account);
            st.bind_text (2, path);
            if (st.step () != Sqlite.ROW) return null;
            return read_folder (st);
        }

        public void count_folder (Folder f) {
            var st = prepare ("SELECT COUNT(*), SUM(CASE WHEN flags & 1 = 0 THEN 1 ELSE 0 END) FROM messages WHERE folder = ? AND (flags & 16) = 0");
            st.bind_int64 (1, f.id);
            if (st.step () == Sqlite.ROW) {
                f.total = st.column_int (0);
                f.unread = st.column_int (1);
            }
        }

        public Folder upsert_folder (string account, string path, string name, string role, string delim, string parent = "", bool shared = false) {
            var existing = folder_by_path (account, path);
            if (existing != null) {
                if (existing.role != role || existing.name != name || existing.parent != parent || existing.shared != shared) {
                    var up = prepare ("UPDATE folders SET role = ?, name = ?, delim = ?, parent = ?, shared = ? WHERE id = ?");
                    up.bind_text (1, role);
                    up.bind_text (2, name);
                    up.bind_text (3, delim);
                    up.bind_text (4, parent);
                    up.bind_int (5, shared ? 1 : 0);
                    up.bind_int64 (6, existing.id);
                    up.step ();
                    existing.role = role;
                    existing.name = name;
                    existing.parent = parent;
                    existing.shared = shared;
                }
                return existing;
            }
            var st = prepare ("INSERT INTO folders (account, path, name, role, delim, parent, shared) VALUES (?, ?, ?, ?, ?, ?, ?)");
            st.bind_text (1, account);
            st.bind_text (2, path);
            st.bind_text (3, name);
            st.bind_text (4, role);
            st.bind_text (5, delim);
            st.bind_text (6, parent);
            st.bind_int (7, shared ? 1 : 0);
            st.step ();
            return folder_by_path (account, path);
        }

        public Folder local_folder (string account, string path, string name, string role) {
            var f = upsert_folder (account, path, name, role, "/");
            var st = prepare ("UPDATE folders SET local = 1 WHERE id = ?");
            st.bind_int64 (1, f.id);
            st.step ();
            f.local = true;
            return f;
        }

        public void set_favorite (int64 id, bool on) {
            var st = prepare ("UPDATE folders SET favorite = ? WHERE id = ?");
            st.bind_int (1, on ? 1 : 0);
            st.bind_int64 (2, id);
            st.step ();
        }

        public void rename_folder (int64 id, string path, string name, string parent) {
            var st = prepare ("UPDATE folders SET path = ?, name = ?, parent = ? WHERE id = ?");
            st.bind_text (1, path);
            st.bind_text (2, name);
            st.bind_text (3, parent);
            st.bind_int64 (4, id);
            st.step ();
        }

        public void remove_folder (int64 id) {
            var ids = new Gee.ArrayList<int64?> ();
            var q = prepare ("SELECT id FROM messages WHERE folder = ?");
            q.bind_int64 (1, id);
            while (q.step () == Sqlite.ROW) ids.add (q.column_int64 (0));
            foreach (var mid in ids) remove_fts (mid);
            var st = prepare ("DELETE FROM folders WHERE id = ?");
            st.bind_int64 (1, id);
            st.step ();
        }

        public void set_folder_state (Folder f) {
            var st = prepare ("UPDATE folders SET uidvalidity = ?, uidnext = ?, modseq = ?, sync_state = ? WHERE id = ?");
            st.bind_int64 (1, f.uidvalidity);
            st.bind_int64 (2, f.uidnext);
            st.bind_int64 (3, f.modseq);
            st.bind_text (4, f.sync_state);
            st.bind_int64 (5, f.id);
            st.step ();
        }

        public void clear_folder (int64 folder_id) {
            var ids = new Gee.ArrayList<int64?> ();
            var q = prepare ("SELECT id FROM messages WHERE folder = ?");
            q.bind_int64 (1, folder_id);
            while (q.step () == Sqlite.ROW) ids.add (q.column_int64 (0));
            foreach (var mid in ids) remove_fts (mid);
            var st = prepare ("DELETE FROM messages WHERE folder = ?");
            st.bind_int64 (1, folder_id);
            st.step ();
        }

        public int64 max_uid (int64 folder_id) {
            var st = prepare ("SELECT MAX(uid) FROM messages WHERE folder = ?");
            st.bind_int64 (1, folder_id);
            return st.step () == Sqlite.ROW ? st.column_int64 (0) : 0;
        }

        public Gee.HashMap<int64?, int> uid_flags (int64 folder_id) {
            var map = new Gee.HashMap<int64?, int> ((v) => int64_hash (v), (a, b) => a == b);
            var st = prepare ("SELECT uid, flags FROM messages WHERE folder = ?");
            st.bind_int64 (1, folder_id);
            while (st.step () == Sqlite.ROW) map[st.column_int64 (0)] = st.column_int (1);
            return map;
        }

        public Gee.HashMap<string, int64?> rid_map (int64 folder_id) {
            var map = new Gee.HashMap<string, int64?> ();
            var st = prepare ("SELECT rid, id FROM messages WHERE folder = ?");
            st.bind_int64 (1, folder_id);
            while (st.step () == Sqlite.ROW) map[text (st, 0)] = st.column_int64 (1);
            return map;
        }

        public int64 id_for_rid (int64 folder_id, string rid) {
            var st = prepare ("SELECT id FROM messages WHERE folder = ? AND rid = ?");
            st.bind_int64 (1, folder_id);
            st.bind_text (2, rid);
            return st.step () == Sqlite.ROW ? st.column_int64 (0) : 0;
        }

        public static int flags_from (Gee.List<string> list) {
            int f = 0;
            foreach (string s in list) {
                switch (s.down ()) {
                    case "\\seen": f |= MessageFlags.SEEN; break;
                    case "\\flagged": f |= MessageFlags.FLAGGED; break;
                    case "\\answered": f |= MessageFlags.ANSWERED; break;
                    case "\\draft": f |= MessageFlags.DRAFT; break;
                    case "\\deleted": f |= MessageFlags.DELETED; break;
                    case "$forwarded": f |= MessageFlags.FORWARDED; break;
                    case "$completed": f |= MessageFlags.COMPLETED; break;
                    case "$pinned": f |= MessageFlags.PINNED; break;
                    case "$junk":
                    case "junk": f |= MessageFlags.JUNK; break;
                    case "$notjunk":
                    case "nonjunk": f |= MessageFlags.NOT_JUNK; break;
                    case "$mdnsent": f |= MessageFlags.MDN_SENT; break;
                }
            }
            return f;
        }

        public static string keywords_from (Gee.List<string> list) {
            var parts = new Gee.ArrayList<string> ();
            foreach (string s in list) {
                if (s.has_prefix ("\\") || s.has_prefix ("$")) continue;
                string low = s.down ();
                if (low == "junk" || low == "nonjunk" || low == "notjunk") continue;
                string name = Keywords.to_category (s);
                if (name != "" && !parts.contains (name)) parts.add (name);
            }
            return string.joinv ("\x1f", parts.to_array ());
        }

        public int64 insert_message (Folder f, int64 uid, int flags, int64 size, uint8[] header, int64 fallback_date, string rid = "", string conv = "", string keywords = "") {
            var part = Mime.parse_part (header, "1", 0);
            var from = Mime.parse_addresses (part.header ("From") ?? "");
            var to = Mime.parse_addresses (part.header ("To") ?? "");
            var cc = Mime.parse_addresses (part.header ("Cc") ?? "");
            var date = Mime.parse_date (part.header ("Date") ?? "");
            string subject = part.decoded_header ("Subject");
            string mid = Mime.first_id (part.header ("Message-ID") ?? "");
            string irt = Mime.first_id (part.header ("In-Reply-To") ?? "");
            string refs = string.joinv (" ", Mime.parse_ids (part.header ("References") ?? ""));
            string ctype = (part.header ("Content-Type") ?? "").down ();
            bool attach = ctype.contains ("multipart/mixed") || ctype.contains ("application/");
            string unsub = Mime.unfold (part.header ("List-Unsubscribe") ?? "").strip ();
            string post = (part.header ("List-Unsubscribe-Post") ?? "").strip ();
            if (unsub != "" && post != "") unsub += "\x1f" + post;
            string list_id = Mime.unfold (part.header ("List-Id") ?? "").strip ();
            var receipt = Mime.parse_addresses (part.header ("Disposition-Notification-To") ?? "");
            int importance = Mime.importance_of (part);
            int focus = -1;
            if (f.role == "inbox" && from.size > 0) focus = classify_focus (from[0].email, part);
            var st = prepare ("""INSERT OR REPLACE INTO messages (folder, account, uid, message_id, in_reply_to, refs, thread, subject,
                sender_name, sender_email, to_list, cc_list, date, flags, size, has_attach, rid, conv, keywords, importance, focus,
                list_unsub, list_id, receipt_to) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""");
            st.bind_int64 (1, f.id);
            st.bind_text (2, f.account);
            st.bind_int64 (3, uid);
            st.bind_text (4, mid);
            st.bind_text (5, irt);
            st.bind_text (6, refs);
            st.bind_text (7, conv != "" ? "c:" + conv : (mid != "" ? mid : "#" + uid.to_string ()));
            st.bind_text (8, subject);
            st.bind_text (9, from.size > 0 ? from[0].name : "");
            st.bind_text (10, from.size > 0 ? from[0].email : "");
            st.bind_text (11, Mime.format_addresses (to));
            st.bind_text (12, Mime.format_addresses (cc));
            st.bind_int64 (13, date != null ? date.to_unix () : fallback_date);
            st.bind_int (14, flags);
            st.bind_int64 (15, size);
            st.bind_int (16, attach ? 1 : 0);
            st.bind_text (17, rid != "" ? rid : uid.to_string ());
            st.bind_text (18, conv);
            st.bind_text (19, keywords);
            st.bind_int (20, importance);
            st.bind_int (21, focus);
            st.bind_text (22, unsub);
            st.bind_text (23, list_id);
            st.bind_text (24, receipt.size > 0 ? receipt[0].email : "");
            st.step ();
            int64 id = db.last_insert_rowid ();
            var fts = prepare ("INSERT INTO search (rowid, subject, sender, recipients, body) VALUES (?, ?, ?, ?, '')");
            fts.bind_int64 (1, id);
            fts.bind_text (2, subject);
            fts.bind_text (3, from.size > 0 ? from[0].to_string () : "");
            fts.bind_text (4, Mime.display_addresses (to) + " " + Mime.format_addresses (to) + " " + Mime.format_addresses (cc));
            fts.step ();
            if (f.role == "sent") {
                foreach (var a in to) note_address (a, date != null ? date.to_unix () : fallback_date, 3);
                foreach (var a in cc) note_address (a, date != null ? date.to_unix () : fallback_date, 2);
            } else if (from.size > 0 && f.role != "junk") {
                note_address (from[0], date != null ? date.to_unix () : fallback_date, 1);
            }
            return id;
        }

        public int sender_focus (string email) {
            var st = prepare ("SELECT focus FROM focus_senders WHERE email = ?");
            st.bind_text (1, email.down ());
            return st.step () == Sqlite.ROW ? st.column_int (0) : -1;
        }

        public void set_sender_focus (string email, int focus) {
            var st = prepare ("INSERT OR REPLACE INTO focus_senders (email, focus) VALUES (?, ?)");
            st.bind_text (1, email.down ());
            st.bind_int (2, focus);
            st.step ();
            var up = prepare ("UPDATE messages SET focus = ? WHERE lower(sender_email) = ? AND folder IN (SELECT id FROM folders WHERE role = 'inbox')");
            up.bind_int (1, focus);
            up.bind_text (2, email.down ());
            up.step ();
        }

        private int classify_focus (string email, MimePart header) {
            int forced = sender_focus (email);
            if (forced >= 0) return forced;
            string e = email.down ();
            var st = prepare ("SELECT uses FROM addresses WHERE email = ?");
            st.bind_text (1, e);
            int uses = st.step () == Sqlite.ROW ? st.column_int (0) : 0;
            if (uses >= 2) return 1;
            string prec = (header.header ("Precedence") ?? "").down ();
            string auto = (header.header ("Auto-Submitted") ?? "").down ();
            if (header.header ("List-Unsubscribe") != null || header.header ("List-Id") != null) return 0;
            if (prec.contains ("bulk") || prec.contains ("list") || prec.contains ("junk")) return 0;
            if (auto != "" && auto != "no") return 0;
            string local = e.contains ("@") ? e.substring (0, e.index_of_char ('@')) : e;
            if (local.contains ("noreply") || local.contains ("no-reply") || local.contains ("newsletter") || local.contains ("notification") || local == "news" || local == "marketing") return 0;
            return 1;
        }

        public void set_focus (int64 id, int focus) {
            var st = prepare ("UPDATE messages SET focus = ? WHERE id = ?");
            st.bind_int (1, focus);
            st.bind_int64 (2, id);
            st.step ();
        }

        private void remove_fts (int64 id) {
            var st = prepare ("DELETE FROM search WHERE rowid = ?");
            st.bind_int64 (1, id);
            st.step ();
        }

        public void set_body (int64 id, uint8[] raw) {
            var msg = new MimeMessage (raw);
            string body = msg.body_text ();
            string preview = body.replace ("\r", " ").replace ("\n", " ").replace ("\t", " ");
            while (preview.contains ("  ")) preview = preview.replace ("  ", " ");
            preview = preview.strip ();
            if (preview.char_count () > 200) preview = preview.substring (0, preview.index_of_nth_char (200));
            var st = prepare ("UPDATE messages SET raw = ?, preview = ?, has_attach = ? WHERE id = ?");
            st.bind_blob (1, raw, raw.length, null);
            st.bind_text (2, preview);
            st.bind_int (3, msg.attachments.size > 0 ? 1 : 0);
            st.bind_int64 (4, id);
            st.step ();
            var q = prepare ("SELECT subject, sender, recipients FROM search WHERE rowid = ?");
            q.bind_int64 (1, id);
            string subject = "", sender = "", recipients = "";
            if (q.step () == Sqlite.ROW) {
                subject = text (q, 0);
                sender = text (q, 1);
                recipients = text (q, 2);
            }
            remove_fts (id);
            var names = new StringBuilder ();
            foreach (var a in msg.attachments) names.append (" " + a.filename);
            var fts = prepare ("INSERT INTO search (rowid, subject, sender, recipients, body) VALUES (?, ?, ?, ?, ?)");
            fts.bind_int64 (1, id);
            fts.bind_text (2, subject);
            fts.bind_text (3, sender);
            fts.bind_text (4, recipients);
            fts.bind_text (5, body + names.str);
            fts.step ();
        }

        public uint8[]? body (int64 id) {
            var st = prepare ("SELECT raw FROM messages WHERE id = ?");
            st.bind_int64 (1, id);
            if (st.step () != Sqlite.ROW) return null;
            int n = st.column_bytes (0);
            if (n == 0 || st.column_type (0) == Sqlite.NULL) return null;
            uint8[] data = new uint8[n];
            Memory.copy (data, st.column_blob (0), n);
            return data;
        }

        public Gee.ArrayList<int64?> missing_bodies (int64 folder_id, int64 max_size, int limit) {
            var list = new Gee.ArrayList<int64?> ();
            var st = prepare ("SELECT uid FROM messages WHERE folder = ? AND raw IS NULL AND size <= ? ORDER BY date DESC LIMIT ?");
            st.bind_int64 (1, folder_id);
            st.bind_int64 (2, max_size);
            st.bind_int (3, limit);
            while (st.step () == Sqlite.ROW) list.add (st.column_int64 (0));
            return list;
        }

        public Gee.ArrayList<MessageInfo> missing_body_messages (int64 folder_id, int64 max_size, int limit) {
            var list = new Gee.ArrayList<MessageInfo> ();
            var st = prepare ("SELECT " + MSG_COLS + " FROM messages m WHERE m.folder = ? AND m.raw IS NULL AND m.size <= ? ORDER BY m.date DESC LIMIT ?");
            st.bind_int64 (1, folder_id);
            st.bind_int64 (2, max_size);
            st.bind_int (3, limit);
            while (st.step () == Sqlite.ROW) list.add (read_message (st));
            return list;
        }

        public int64 id_for_uid (int64 folder_id, int64 uid) {
            var st = prepare ("SELECT id FROM messages WHERE folder = ? AND uid = ?");
            st.bind_int64 (1, folder_id);
            st.bind_int64 (2, uid);
            return st.step () == Sqlite.ROW ? st.column_int64 (0) : 0;
        }

        public void set_flags (int64 folder_id, int64 uid, int flags) {
            var st = prepare ("UPDATE messages SET flags = ? WHERE folder = ? AND uid = ?");
            st.bind_int (1, flags);
            st.bind_int64 (2, folder_id);
            st.bind_int64 (3, uid);
            st.step ();
        }

        public void set_flags_by_id (int64 id, int flags) {
            var st = prepare ("UPDATE messages SET flags = ? WHERE id = ?");
            st.bind_int (1, flags);
            st.bind_int64 (2, id);
            st.step ();
        }

        public void set_keywords (int64 id, string keywords) {
            var st = prepare ("UPDATE messages SET keywords = ? WHERE id = ?");
            st.bind_text (1, keywords);
            st.bind_int64 (2, id);
            st.step ();
        }

        public void set_due (int64 id, int64 due) {
            var st = prepare ("UPDATE messages SET due = ? WHERE id = ?");
            st.bind_int64 (1, due);
            st.bind_int64 (2, id);
            st.step ();
        }

        public void set_state (int64 id, int flags, string keywords) {
            var st = prepare ("UPDATE messages SET flags = ?, keywords = ? WHERE id = ?");
            st.bind_int (1, flags);
            st.bind_text (2, keywords);
            st.bind_int64 (3, id);
            st.step ();
        }

        public void delete_uid (int64 folder_id, int64 uid) {
            int64 id = id_for_uid (folder_id, uid);
            if (id == 0) return;
            delete_message (id);
        }

        public void delete_message (int64 id) {
            remove_fts (id);
            var st = prepare ("DELETE FROM messages WHERE id = ?");
            st.bind_int64 (1, id);
            st.step ();
        }

        private const string MSG_COLS = "m.id, m.folder, m.account, m.uid, m.message_id, m.in_reply_to, m.refs, m.thread, m.subject, m.sender_name, m.sender_email, m.to_list, m.cc_list, m.date, m.flags, m.size, m.has_attach, m.preview, m.raw IS NOT NULL, m.rid, m.conv, m.keywords, m.importance, m.focus, m.due, m.list_unsub, m.list_id, m.receipt_to";

        private MessageInfo read_message (Sqlite.Statement st) {
            var m = new MessageInfo ();
            m.id = st.column_int64 (0);
            m.folder = st.column_int64 (1);
            m.account = text (st, 2);
            m.uid = st.column_int64 (3);
            m.message_id = text (st, 4);
            m.in_reply_to = text (st, 5);
            m.references = text (st, 6);
            m.thread = text (st, 7);
            m.subject = text (st, 8);
            m.sender_name = text (st, 9);
            m.sender_email = text (st, 10);
            m.to_list = text (st, 11);
            m.cc_list = text (st, 12);
            m.date = st.column_int64 (13);
            m.flags = st.column_int (14);
            m.size = st.column_int64 (15);
            m.has_attachment = st.column_int (16) != 0;
            m.preview = text (st, 17);
            m.has_body = st.column_int (18) != 0;
            m.rid = text (st, 19);
            m.conv = text (st, 20);
            m.keywords = text (st, 21);
            m.importance = st.column_int (22);
            m.focus = st.column_int (23);
            m.due = st.column_int64 (24);
            m.list_unsubscribe = text (st, 25);
            m.list_id = text (st, 26);
            m.receipt_to = text (st, 27);
            return m;
        }

        public MessageInfo? message (int64 id) {
            var st = prepare ("SELECT " + MSG_COLS + " FROM messages m WHERE m.id = ?");
            st.bind_int64 (1, id);
            if (st.step () != Sqlite.ROW) return null;
            return read_message (st);
        }

        public MessageInfo? message_by_mid (string account, string message_id) {
            if (message_id == "") return null;
            var st = prepare ("SELECT " + MSG_COLS + " FROM messages m WHERE m.account = ? AND m.message_id = ? ORDER BY m.raw IS NULL LIMIT 1");
            st.bind_text (1, account);
            st.bind_text (2, message_id);
            if (st.step () != Sqlite.ROW) return null;
            return read_message (st);
        }

        private string id_list (Gee.Collection<int64?> ids) {
            var parts = new Gee.ArrayList<string> ();
            foreach (var i in ids) parts.add (i.to_string ());
            if (parts.size == 0) return "-1";
            return string.joinv (",", parts.to_array ());
        }

        private static string order_by (ListOptions o) {
            string dir = o.ascending ? "ASC" : "DESC";
            string key;
            switch (o.sort) {
                case SortKey.SENDER: key = "lower(CASE WHEN m.sender_name != '' THEN m.sender_name ELSE m.sender_email END) %s, m.date DESC".printf (o.ascending ? "ASC" : "DESC"); break;
                case SortKey.SUBJECT: key = "lower(m.subject) %s, m.date DESC".printf (dir); break;
                case SortKey.SIZE: key = "m.size %s".printf (dir); break;
                case SortKey.FLAGGED: key = "(m.flags & 2) %s, m.date DESC".printf (dir); break;
                case SortKey.UNREAD: key = "(m.flags & 1) %s, m.date DESC".printf (o.ascending ? "DESC" : "ASC"); break;
                default: key = "m.date %s".printf (dir); break;
            }
            return " ORDER BY (m.flags & 128) DESC, " + key;
        }

        private string filter_sql (ListOptions o) {
            switch (o.filter) {
                case ListFilter.UNREAD: return " AND (m.flags & 1) = 0";
                case ListFilter.FLAGGED: return " AND (m.flags & 2) != 0";
                case ListFilter.ATTACHMENTS: return " AND m.has_attach = 1";
                case ListFilter.FOCUSED: return " AND m.focus != 0";
                case ListFilter.OTHER: return " AND m.focus = 0";
                case ListFilter.MENTIONS:
                    if (o.mention == "") return " AND 0";
                    return " AND m.id IN (SELECT rowid FROM search WHERE search MATCH '%s')".printf (fts_query ("@" + o.mention).replace ("'", "''"));
                default: return "";
            }
        }

        public Gee.ArrayList<MessageInfo> list (Gee.Collection<int64?> folder_ids, bool threaded, Gee.Collection<int64?>? only = null, int limit = 3000, ListOptions? options = null) {
            var o = options ?? new ListOptions ();
            if (options == null) o.limit = limit;
            var result = new Gee.ArrayList<MessageInfo> ();
            string sql = "SELECT " + MSG_COLS + " FROM messages m WHERE m.folder IN (%s) AND (m.flags & 16) = 0".printf (id_list (folder_ids));
            if (only != null) sql += " AND m.id IN (%s)".printf (id_list (only));
            sql += filter_sql (o);
            sql += order_by (o) + " LIMIT %d".printf (o.limit);
            var st = prepare (sql);
            var seen = new Gee.HashMap<string, MessageInfo> ();
            while (st.step () == Sqlite.ROW) {
                var m = read_message (st);
                if (!threaded) {
                    result.add (m);
                    m.thread_unread = m.unread;
                    m.thread_flagged = m.flagged;
                    continue;
                }
                string key = m.account + "\x01" + m.thread;
                var lead = seen[key];
                if (lead == null) {
                    seen[key] = m;
                    result.add (m);
                    m.thread_unread = m.unread;
                    m.thread_flagged = m.flagged;
                    m.participants = m.sender_display;
                    continue;
                }
                if (m.unread) lead.thread_unread = true;
                if (m.flagged) lead.thread_flagged = true;
                if (m.has_attachment) lead.has_attachment = true;
                if (!lead.participants.contains (m.sender_display)) lead.participants = lead.participants + ", " + m.sender_display;
            }
            if (threaded && result.size > 0) {
                var counts = new Gee.HashMap<string, int> ();
                var cq = prepare ("SELECT m.account, m.thread, COUNT(DISTINCT COALESCE(NULLIF(m.message_id, ''), m.id)) FROM messages m JOIN folders f ON f.id = m.folder WHERE f.role NOT IN ('trash', 'junk') AND (m.flags & 16) = 0 GROUP BY m.account, m.thread HAVING COUNT(*) > 1");
                while (cq.step () == Sqlite.ROW) counts[text (cq, 0) + "\x01" + text (cq, 1)] = cq.column_int (2);
                foreach (var m in result) {
                    string key = m.account + "\x01" + m.thread;
                    if (counts.has_key (key)) m.thread_count = counts[key];
                }
            }
            return result;
        }

        public Gee.ArrayList<MessageInfo> conversation (string account, string thread, bool include_trash) {
            var list = new Gee.ArrayList<MessageInfo> ();
            string sql = "SELECT " + MSG_COLS + " FROM messages m JOIN folders f ON f.id = m.folder WHERE m.account = ? AND m.thread = ? AND (m.flags & 16) = 0";
            if (!include_trash) sql += " AND f.role NOT IN ('trash', 'junk')";
            sql += " ORDER BY m.date ASC";
            var st = prepare (sql);
            st.bind_text (1, account);
            st.bind_text (2, thread);
            var by_mid = new Gee.HashMap<string, MessageInfo> ();
            while (st.step () == Sqlite.ROW) {
                var m = read_message (st);
                if (m.message_id != "" && by_mid.has_key (m.message_id)) {
                    var prev = by_mid[m.message_id];
                    if (!prev.has_body && m.has_body) {
                        list[list.index_of (prev)] = m;
                        by_mid[m.message_id] = m;
                    }
                    continue;
                }
                if (m.message_id != "") by_mid[m.message_id] = m;
                list.add (m);
            }
            return list;
        }

        public static string fts_query (string q) {
            var parts = new Gee.ArrayList<string> ();
            foreach (string raw in q.split (" ")) {
                string t = raw.strip ().replace ("\"", "");
                if (t == "") continue;
                parts.add ("\"" + t + "\"*");
            }
            return string.joinv (" ", parts.to_array ());
        }

        public Gee.HashSet<int64?> search (string query) {
            var set = new Gee.HashSet<int64?> ((v) => int64_hash (v), (a, b) => a == b);
            string fq = fts_query (query);
            if (fq == "") return set;
            var st = prepare ("SELECT rowid FROM search WHERE search MATCH ? ORDER BY rank LIMIT 1000");
            st.bind_text (1, fq);
            while (st.step () == Sqlite.ROW) set.add (st.column_int64 (0));
            return set;
        }

        public Gee.ArrayList<MessageInfo> query (SearchQuery q, Gee.Collection<int64?>? folder_ids, Gee.Collection<int64?>? extra = null, int limit = 2000) {
            var list = new Gee.ArrayList<MessageInfo> ();
            var binds = new Gee.ArrayList<string> ();
            string where = q.to_sql (binds);
            string sql = "SELECT " + MSG_COLS + " FROM messages m JOIN folders f ON f.id = m.folder WHERE (m.flags & 16) = 0";
            if (folder_ids != null) sql += " AND m.folder IN (%s)".printf (id_list (folder_ids));
            else sql += " AND f.role NOT IN ('trash', 'junk')";
            if (extra != null && extra.size > 0) sql += " AND ((%s) OR m.id IN (%s))".printf (where, id_list (extra));
            else sql += " AND (%s)".printf (where);
            sql += " ORDER BY m.date DESC LIMIT %d".printf (limit);
            var st = prepare (sql);
            for (int i = 0; i < binds.size; i++) st.bind_text (i + 1, binds[i]);
            var seen = new Gee.HashSet<string> ();
            while (st.step () == Sqlite.ROW) {
                var m = read_message (st);
                string key = m.account + "\x01" + (m.message_id != "" ? m.message_id : m.id.to_string ()) + "\x01" + m.folder.to_string ();
                if (!seen.add (key)) continue;
                m.thread_unread = m.unread;
                m.thread_flagged = m.flagged;
                list.add (m);
            }
            return list;
        }

        public void rethread (string account) {
            var inputs = new Gee.ArrayList<ThreadInput> ();
            var current = new Gee.HashMap<int64?, string> ((v) => int64_hash (v), (a, b) => a == b);
            var st = prepare ("SELECT id, message_id, in_reply_to, refs, thread, conv FROM messages WHERE account = ?");
            st.bind_text (1, account);
            while (st.step () == Sqlite.ROW) {
                int64 id = st.column_int64 (0);
                var input = new ThreadInput (id, text (st, 1), text (st, 2), text (st, 3));
                input.conv = text (st, 5);
                inputs.add (input);
                current[id] = text (st, 4);
            }
            var groups = new Threader ().group (inputs);
            var up = prepare ("UPDATE messages SET thread = ? WHERE id = ?");
            begin ();
            foreach (var e in groups.entries) {
                if (current[e.key] == e.value) continue;
                up.reset ();
                up.bind_text (1, e.value);
                up.bind_int64 (2, e.key);
                up.step ();
            }
            commit ();
        }

        public void note_address (Address a, int64 when, int weight) {
            if (a.email == "" || !a.email.contains ("@")) return;
            var st = prepare ("""INSERT INTO addresses (email, name, uses, last) VALUES (?, ?, ?, ?)
                ON CONFLICT(email) DO UPDATE SET uses = uses + excluded.uses, last = MAX(last, excluded.last), name = CASE WHEN excluded.name != '' THEN excluded.name ELSE name END""");
            st.bind_text (1, a.email.down ());
            st.bind_text (2, a.name);
            st.bind_int (3, weight);
            st.bind_int64 (4, when);
            st.step ();
        }

        public Gee.ArrayList<Address> suggest (string prefix, int limit) {
            var list = new Gee.ArrayList<Address> ();
            string p = prefix.strip ().down ();
            if (p == "") return list;
            var st = prepare ("SELECT email, name FROM addresses WHERE email LIKE ? ESCAPE '\\' OR lower(name) LIKE ? ESCAPE '\\' OR lower(name) LIKE ? ESCAPE '\\' ORDER BY uses DESC, last DESC LIMIT ?");
            string esc = p.replace ("\\", "\\\\").replace ("%", "\\%").replace ("_", "\\_");
            st.bind_text (1, esc + "%");
            st.bind_text (2, esc + "%");
            st.bind_text (3, "% " + esc + "%");
            st.bind_int (4, limit);
            while (st.step () == Sqlite.ROW) list.add (new Address (text (st, 1), text (st, 0)));
            return list;
        }

        public void forget_address (string email) {
            var st = prepare ("DELETE FROM addresses WHERE email = ?");
            st.bind_text (1, email.down ());
            st.step ();
        }

        public int64 add_outbox (string account, uint8[] raw, string recipients, string sender, int64 send_at, string subject = "") {
            var st = prepare ("INSERT INTO outbox (account, raw, recipients, sender, send_at, subject) VALUES (?, ?, ?, ?, ?, ?)");
            st.bind_text (1, account);
            st.bind_blob (2, raw, raw.length, null);
            st.bind_text (3, recipients);
            st.bind_text (4, sender);
            st.bind_int64 (5, send_at);
            st.bind_text (6, subject);
            st.step ();
            return db.last_insert_rowid ();
        }

        public Gee.ArrayList<OutboxItem> outbox (string? account = null) {
            var list = new Gee.ArrayList<OutboxItem> ();
            var st = prepare ("SELECT id, account, raw, recipients, sender, send_at, error, subject FROM outbox ORDER BY send_at");
            while (st.step () == Sqlite.ROW) {
                var o = new OutboxItem ();
                o.id = st.column_int64 (0);
                o.account = text (st, 1);
                int n = st.column_bytes (2);
                o.raw = new uint8[n];
                if (n > 0) Memory.copy (o.raw, st.column_blob (2), n);
                o.recipients = text (st, 3);
                o.sender = text (st, 4);
                o.send_at = st.column_int64 (5);
                o.error = text (st, 6);
                o.subject = text (st, 7);
                if (account == null || o.account == account) list.add (o);
            }
            return list;
        }

        public void remove_outbox (int64 id) {
            var st = prepare ("DELETE FROM outbox WHERE id = ?");
            st.bind_int64 (1, id);
            st.step ();
        }

        public void set_outbox_error (int64 id, string error, int64 retry_at) {
            var st = prepare ("UPDATE outbox SET error = ?, send_at = ? WHERE id = ?");
            st.bind_text (1, error);
            st.bind_int64 (2, retry_at);
            st.bind_int64 (3, id);
            st.step ();
        }

        public void set_outbox_time (int64 id, int64 send_at) {
            var st = prepare ("UPDATE outbox SET send_at = ?, error = '' WHERE id = ?");
            st.bind_int64 (1, send_at);
            st.bind_int64 (2, id);
            st.step ();
        }

        public void add_op (string account, string kind, string folder, string uids, string arg) {
            var st = prepare ("INSERT INTO ops (account, kind, folder, uids, arg) VALUES (?, ?, ?, ?, ?)");
            st.bind_text (1, account);
            st.bind_text (2, kind);
            st.bind_text (3, folder);
            st.bind_text (4, uids);
            st.bind_text (5, arg);
            st.step ();
        }

        public Gee.ArrayList<PendingOp> ops (string account) {
            var list = new Gee.ArrayList<PendingOp> ();
            var st = prepare ("SELECT id, account, kind, folder, uids, arg FROM ops WHERE account = ? ORDER BY id");
            st.bind_text (1, account);
            while (st.step () == Sqlite.ROW) {
                var o = new PendingOp ();
                o.id = st.column_int64 (0);
                o.account = text (st, 1);
                o.kind = text (st, 2);
                o.folder = text (st, 3);
                o.uids = text (st, 4);
                o.arg = text (st, 5);
                list.add (o);
            }
            return list;
        }

        public void remove_op (int64 id) {
            var st = prepare ("DELETE FROM ops WHERE id = ?");
            st.bind_int64 (1, id);
            st.step ();
        }

        public string? get_value (string account, string key) {
            var st = prepare ("SELECT value FROM kv WHERE account = ? AND key = ?");
            st.bind_text (1, account);
            st.bind_text (2, key);
            if (st.step () != Sqlite.ROW) return null;
            return text (st, 0);
        }

        public void set_value (string account, string key, string? value) {
            if (value == null) {
                var d = prepare ("DELETE FROM kv WHERE account = ? AND key = ?");
                d.bind_text (1, account);
                d.bind_text (2, key);
                d.step ();
                return;
            }
            var st = prepare ("INSERT OR REPLACE INTO kv (account, key, value) VALUES (?, ?, ?)");
            st.bind_text (1, account);
            st.bind_text (2, key);
            st.bind_text (3, value);
            st.step ();
        }

        public int64 add_snooze (string account, string message_id, int64 until, string origin, string subject) {
            var st = prepare ("INSERT INTO snoozes (account, message_id, until, origin, subject) VALUES (?, ?, ?, ?, ?)");
            st.bind_text (1, account);
            st.bind_text (2, message_id);
            st.bind_int64 (3, until);
            st.bind_text (4, origin);
            st.bind_text (5, subject);
            st.step ();
            return db.last_insert_rowid ();
        }

        public Gee.ArrayList<SnoozeItem> snoozes () {
            var list = new Gee.ArrayList<SnoozeItem> ();
            var st = prepare ("SELECT id, account, message_id, until, origin, subject FROM snoozes ORDER BY until");
            while (st.step () == Sqlite.ROW) {
                var s = new SnoozeItem ();
                s.id = st.column_int64 (0);
                s.account = text (st, 1);
                s.message_id = text (st, 2);
                s.until = st.column_int64 (3);
                s.origin = text (st, 4);
                s.subject = text (st, 5);
                list.add (s);
            }
            return list;
        }

        public void remove_snooze (int64 id) {
            var st = prepare ("DELETE FROM snoozes WHERE id = ?");
            st.bind_int64 (1, id);
            st.step ();
        }

        public void learn_tokens (Gee.Collection<string> tokens, bool junk, int delta) {
            var st = prepare (junk ? "INSERT INTO junk_tokens (token, bad) VALUES (?, ?) ON CONFLICT(token) DO UPDATE SET bad = MAX(0, bad + excluded.bad)"
                                   : "INSERT INTO junk_tokens (token, good) VALUES (?, ?) ON CONFLICT(token) DO UPDATE SET good = MAX(0, good + excluded.good)");
            begin ();
            foreach (string t in tokens) {
                st.reset ();
                st.bind_text (1, t);
                st.bind_int (2, delta);
                st.step ();
            }
            commit ();
            string key = junk ? "junk-bad" : "junk-good";
            int64 n = int64.parse (get_value ("", key) ?? "0") + delta;
            set_value ("", key, int64.max (0, n).to_string ());
        }

        public void token_counts (string token, out int good, out int bad) {
            var st = prepare ("SELECT good, bad FROM junk_tokens WHERE token = ?");
            st.bind_text (1, token);
            good = 0;
            bad = 0;
            if (st.step () == Sqlite.ROW) {
                good = st.column_int (0);
                bad = st.column_int (1);
            }
        }

        public int64 total_bytes (string account) {
            var st = prepare ("SELECT COALESCE(SUM(size), 0) FROM messages WHERE account = ?");
            st.bind_text (1, account);
            return st.step () == Sqlite.ROW ? st.column_int64 (0) : 0;
        }

        public Gee.ArrayList<MessageInfo> by_sender (string account, int64 folder_id, string email) {
            var list = new Gee.ArrayList<MessageInfo> ();
            var st = prepare ("SELECT " + MSG_COLS + " FROM messages m WHERE m.account = ? AND m.folder = ? AND lower(m.sender_email) = ? AND (m.flags & 16) = 0 ORDER BY m.date DESC");
            st.bind_text (1, account);
            st.bind_int64 (2, folder_id);
            st.bind_text (3, email.down ());
            while (st.step () == Sqlite.ROW) list.add (read_message (st));
            return list;
        }

        public Gee.ArrayList<MessageInfo> folder_messages (int64 folder_id) {
            var list = new Gee.ArrayList<MessageInfo> ();
            var st = prepare ("SELECT " + MSG_COLS + " FROM messages m WHERE m.folder = ? AND (m.flags & 16) = 0 ORDER BY m.date ASC");
            st.bind_int64 (1, folder_id);
            while (st.step () == Sqlite.ROW) list.add (read_message (st));
            return list;
        }

        public int unread_inboxes () {
            var st = prepare ("SELECT COUNT(*) FROM messages m JOIN folders f ON f.id = m.folder WHERE f.role = 'inbox' AND (m.flags & ?) = 0");
            st.bind_int (1, MessageFlags.SEEN | MessageFlags.DELETED | MessageFlags.JUNK | MessageFlags.DRAFT);
            return st.step () == Sqlite.ROW ? st.column_int (0) : 0;
        }

        public Gee.ArrayList<MessageInfo> due_messages (int64 before) {
            var list = new Gee.ArrayList<MessageInfo> ();
            var st = prepare ("SELECT " + MSG_COLS + " FROM messages m WHERE m.due > 0 AND m.due <= ? AND (m.flags & 2) != 0 AND (m.flags & 64) = 0");
            st.bind_int64 (1, before);
            while (st.step () == Sqlite.ROW) list.add (read_message (st));
            return list;
        }

        public void remove_account (string account) {
            var fl = folders (account);
            foreach (var f in fl) remove_folder (f.id);
            var st = prepare ("DELETE FROM ops WHERE account = ?");
            st.bind_text (1, account);
            st.step ();
            var ob = prepare ("DELETE FROM outbox WHERE account = ?");
            ob.bind_text (1, account);
            ob.step ();
            var kv = prepare ("DELETE FROM kv WHERE account = ?");
            kv.bind_text (1, account);
            kv.step ();
            var sn = prepare ("DELETE FROM snoozes WHERE account = ?");
            sn.bind_text (1, account);
            sn.step ();
        }

        private string folder_chain (Gee.List<Folder> all, Folder f) {
            var names = new Gee.ArrayList<string> ();
            var seen = new Gee.HashSet<string> ();
            Folder? cur = f;
            while (cur != null && seen.add (cur.path)) {
                names.insert (0, cur.name.down ());
                Folder? up = null;
                if (cur.parent != "") foreach (var o in all) if (o.path == cur.parent) up = o;
                cur = up;
            }
            return string.joinv ("/", names.to_array ());
        }

        public void begin_protocol_switch (string account) {
            var all = folders (account);
            var lines = new Gee.ArrayList<string> ();
            string earlier = get_value (account, "folder-remap") ?? "";
            if (earlier != "") lines.add (earlier);
            var keep = new Gee.ArrayList<string> ();
            string kept = get_value (account, "message-keep") ?? "";
            if (kept != "") keep.add (kept);
            var st = prepare ("SELECT m.message_id, m.flags, m.due FROM messages m JOIN folders f ON f.id = m.folder WHERE m.account = ? AND f.local = 0 AND m.message_id != '' AND ((m.flags & ?) != 0 OR m.due > 0)");
            st.bind_text (1, account);
            st.bind_int (2, MessageFlags.PINNED | MessageFlags.ANSWERED | MessageFlags.FORWARDED);
            while (st.step () == Sqlite.ROW) {
                keep.add ("%s\t%d\t%s".printf (text (st, 0), st.column_int (1) & (MessageFlags.PINNED | MessageFlags.ANSWERED | MessageFlags.FORWARDED), st.column_int64 (2).to_string ()));
            }
            begin ();
            foreach (var f in all) {
                if (f.local) continue;
                if (earlier == "") lines.add ("%s\t%s\t%s\t%d".printf (f.path, f.role, folder_chain (all, f), f.favorite ? 1 : 0));
                remove_folder (f.id);
            }
            if (lines.size > 0) set_value (account, "folder-remap", string.joinv ("\n", lines.to_array ()));
            if (keep.size > 0) set_value (account, "message-keep", string.joinv ("\n", keep.to_array ()));
            commit ();
        }

        public Gee.HashMap<string, string> finish_protocol_switch (string account) {
            var moved = new Gee.HashMap<string, string> ();
            string saved = get_value (account, "folder-remap") ?? "";
            if (saved == "") return moved;
            var all = folders (account);
            var by_role = new Gee.HashMap<string, Folder> ();
            var by_chain = new Gee.HashMap<string, Folder> ();
            int remote = 0;
            foreach (var f in all) {
                if (f.local) continue;
                remote++;
                if (f.role != "" && !by_role.has_key (f.role)) by_role[f.role] = f;
                string chain = folder_chain (all, f);
                if (!by_chain.has_key (chain)) by_chain[chain] = f;
            }
            if (remote == 0) return moved;
            begin ();
            foreach (string line in saved.split ("\n")) {
                string[] p = line.split ("\t");
                if (p.length < 4) continue;
                Folder? hit = p[1] != "" ? by_role[p[1]] : null;
                if (hit == null) hit = by_chain[p[2]];
                if (hit == null) continue;
                moved[p[0]] = hit.path;
                if (p[3] == "1") set_favorite (hit.id, true);
                var up = prepare ("UPDATE snoozes SET origin = ? WHERE account = ? AND origin = ?");
                up.bind_text (1, hit.path);
                up.bind_text (2, account);
                up.bind_text (3, p[0]);
                up.step ();
            }
            set_value (account, "folder-remap", null);
            commit ();
            return moved;
        }

        public void restore_message_state (string account) {
            string saved = get_value (account, "message-keep") ?? "";
            if (saved == "") return;
            var left = new Gee.ArrayList<string> ();
            begin ();
            foreach (string line in saved.split ("\n")) {
                string[] p = line.split ("\t");
                if (p.length < 3) continue;
                var st = prepare ("UPDATE messages SET flags = flags | ?, due = CASE WHEN ? > 0 THEN ? ELSE due END WHERE account = ? AND message_id = ?");
                int64 due = int64.parse (p[2]);
                st.bind_int (1, int.parse (p[1]));
                st.bind_int64 (2, due);
                st.bind_int64 (3, due);
                st.bind_text (4, account);
                st.bind_text (5, p[0]);
                st.step ();
                if (db.changes () == 0) left.add (line);
            }
            set_value (account, "message-keep", left.size > 0 ? string.joinv ("\n", left.to_array ()) : null);
            commit ();
        }

        public int64 cache_bytes () {
            var st = prepare ("SELECT COALESCE(SUM(LENGTH(raw)), 0) FROM messages");
            return st.step () == Sqlite.ROW ? st.column_int64 (0) : 0;
        }

        public void prune (int64 limit_bytes) {
            int64 total = cache_bytes ();
            if (total <= limit_bytes) return;
            var st = prepare ("SELECT m.id, LENGTH(m.raw) FROM messages m JOIN folders f ON f.id = m.folder WHERE m.raw IS NOT NULL AND f.local = 0 ORDER BY m.date ASC");
            var drop = new Gee.ArrayList<int64?> ();
            while (st.step () == Sqlite.ROW && total > limit_bytes) {
                drop.add (st.column_int64 (0));
                total -= st.column_int64 (1);
            }
            begin ();
            var up = prepare ("UPDATE messages SET raw = NULL WHERE id = ?");
            foreach (var id in drop) {
                up.reset ();
                up.bind_int64 (1, id);
                up.step ();
            }
            commit ();
        }
    }

    namespace Keywords {
        public string to_keyword (string category) {
            var sb = new StringBuilder ();
            unichar c;
            int i = 0;
            string clean = category.strip ();
            while (clean.get_next_char (ref i, out c)) {
                if (c == ' ') sb.append_c ('_');
                else if (c == '(' || c == ')' || c == '{' || c == '}' || c == '"' || c == '\\' || c == ']' || c == '%' || c == '*' || c < 0x21) sb.append_c ('_');
                else sb.append_unichar (c);
            }
            return Utf7.encode (sb.str);
        }

        public string to_category (string keyword) {
            return Utf7.decode (keyword).replace ("_", " ");
        }
    }
}
