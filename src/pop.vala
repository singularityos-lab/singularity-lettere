namespace Singularity.Apps.Lettere {

    public class Pop3Client : Object {
        private SocketConnection? socket_conn;
        private IOStream? stream;
        private DataInputStream? input;
        private OutputStream? output;
        public CertificateTrust? tls_failure;
        public Gee.HashSet<string> capabilities = new Gee.HashSet<string> ();

        private void set_streams () {
            if (input != null) input.close_base_stream = false;
            input = new DataInputStream (stream.input_stream);
            input.newline_type = DataStreamNewlineType.CR_LF;
            input.buffer_size = 65536;
            output = stream.output_stream;
        }

        private async string line () throws Error {
            size_t len;
            string? l = yield input.read_line_async (Priority.DEFAULT, null, out len);
            if (l == null) throw new MailError.CLOSED (_("The server closed the connection"));
            return l;
        }

        private async string command (string cmd, bool secret = false) throws Error {
            size_t written;
            yield output.write_all_async ((cmd + "\r\n").data, Priority.DEFAULT, null, out written);
            yield output.flush_async (Priority.DEFAULT, null);
            string reply = yield line ();
            if (!reply.has_prefix ("+OK")) throw new MailError.SERVER (reply.length > 4 ? reply.substring (4).strip () : reply);
            return reply;
        }

        private async uint8[] multiline () throws Error {
            var buf = new ByteArray ();
            while (true) {
                size_t len;
                uint8[]? raw = null;
                string? l = yield input.read_line_async (Priority.DEFAULT, null, out len);
                if (l == null) throw new MailError.CLOSED (_("The server closed the connection"));
                raw = l.data;
                raw.length = (int) len;
                if (len == 1 && raw[0] == '.') break;
                if (len > 0 && raw[0] == '.') raw = raw[1:raw.length];
                buf.append (raw);
                buf.append ("\r\n".data);
            }
            return buf.steal ();
        }

        public async void open (string host, uint16 port, Security security, string trusted) throws Error {
            var client = new SocketClient ();
            client.timeout = 30;
            try {
                socket_conn = yield client.connect_to_host_async (host, port, null);
            } catch (Error e) {
                throw new MailError.OFFLINE (_("Could not reach %s: %s").printf (host, e.message));
            }
            stream = socket_conn;
            if (security == Security.TLS) {
                var outcome = new Tls.Outcome ();
                try {
                    stream = yield Tls.wrap (socket_conn, host, port, trusted, outcome, null);
                } catch (Error e) {
                    tls_failure = outcome.failure;
                    throw e;
                }
            }
            set_streams ();
            string greet = yield line ();
            if (!greet.has_prefix ("+OK")) throw new MailError.SERVER (greet);
            try {
                yield command ("CAPA");
                foreach (string c in Mime.bytes_to_string (yield multiline ()).split ("\r\n")) {
                    if (c.strip () != "") capabilities.add (c.strip ().up ());
                }
            } catch (MailError.SERVER e) {
            }
            if (security == Security.STARTTLS) {
                yield command ("STLS");
                var outcome = new Tls.Outcome ();
                try {
                    stream = yield Tls.wrap (socket_conn, host, port, trusted, outcome, null);
                } catch (Error e) {
                    tls_failure = outcome.failure;
                    throw e;
                }
                set_streams ();
            }
        }

        public async void login (string user, string password) throws Error {
            try {
                yield command ("USER " + user);
                yield command ("PASS " + password, true);
            } catch (MailError.SERVER e) {
                throw new MailError.AUTH (e.message);
            }
        }

        public async void login_xoauth2 (string token) throws Error {
            try {
                yield command ("AUTH XOAUTH2 " + token, true);
            } catch (MailError.SERVER e) {
                throw new MailError.AUTH (e.message);
            }
        }

        public async Gee.List<string> uidl () throws Error {
            yield command ("UIDL");
            var list = new Gee.ArrayList<string> ();
            foreach (string l in Mime.bytes_to_string (yield multiline ()).split ("\r\n")) {
                if (l.strip () == "") continue;
                list.add (l.strip ());
            }
            return list;
        }

        public async uint8[] retr (int n) throws Error {
            yield command ("RETR %d".printf (n));
            return yield multiline ();
        }

        public async void dele (int n) throws Error {
            yield command ("DELE %d".printf (n));
        }

        public async void quit () {
            try {
                yield command ("QUIT");
            } catch (Error e) {
            }
            try {
                stream.close ();
            } catch (Error e) {
            }
        }
    }

    public class LocalBackend : MailBackend {
        protected unowned AccountSync owner;

        public LocalBackend (AccountSync owner) {
            this.owner = owner;
            this.account = owner.account;
            this.store = owner.store;
        }

        public override bool online {
            get { return true; }
        }

        public override bool local_only {
            get { return true; }
        }

        public override string protocol_name {
            owned get { return _("On This Computer"); }
        }

        public override async void connect () throws Error {
        }

        public override void disconnect () {
        }

        public override async Gee.List<RemoteFolder> list_folders () throws Error {
            var list = new Gee.ArrayList<RemoteFolder> ();
            string[,] defaults = {
                { "Inbox", "inbox" }, { "Drafts", "drafts" }, { "Sent", "sent" }, { "Archive", "archive" }, { "Junk", "junk" }, { "Trash", "trash" }
            };
            for (int i = 0; i < defaults.length[0]; i++) {
                if (store.folder_by_role (account.id, defaults[i, 1]) == null) store.local_folder (account.id, defaults[i, 0], defaults[i, 0], defaults[i, 1]);
            }
            foreach (var f in store.folders (account.id)) {
                var r = new RemoteFolder ();
                r.path = f.path;
                r.name = f.name;
                r.role = f.role;
                r.parent = f.parent;
                list.add (r);
            }
            return list;
        }

        public override async void sync_folder (Folder f, bool notify, Gee.List<MessageInfo> fresh) throws Error {
        }

        public override async void prefetch (Folder f, int limit) throws Error {
        }

        public override async uint8[]? fetch_body (Folder f, MessageInfo m) throws Error {
            return store.body (m.id);
        }

        public override async void set_flags (Folder f, string ids, int flag, bool on) throws Error {
        }

        public override async void set_keywords (Folder f, string ids, string[] add, string[] remove) throws Error {
        }

        public override async void move (Folder f, string ids, Folder dest) throws Error {
        }

        public override async void copy (Folder f, string ids, Folder dest) throws Error {
        }

        public override async void expunge (Folder f, string ids) throws Error {
        }

        public override async string append (Folder f, string flags, uint8[] raw) throws Error {
            return "";
        }

        public override async RemoteFolder create_folder (string name, Folder? parent) throws Error {
            var r = new RemoteFolder ();
            r.path = parent != null ? parent.path + "/" + name : name;
            r.name = name;
            r.parent = parent != null ? parent.path : "";
            return r;
        }

        public override async void rename_folder (Folder f, string name) throws Error {
        }

        public override async void delete_folder (Folder f) throws Error {
        }

        public override async Gee.List<string> search (Folder f, SearchQuery q) throws Error {
            return new Gee.ArrayList<string> ();
        }

        public override async bool wait_changes (Cancellable stop) throws Error {
            return false;
        }
    }

    public class PopBackend : LocalBackend {
        public PopBackend (AccountSync owner) {
            base (owner);
        }

        public override bool local_only {
            get { return false; }
        }

        public override string protocol_name {
            owned get { return "POP3"; }
        }

        public override async void connect () throws Error {
        }

        public override async void sync_folder (Folder f, bool notify, Gee.List<MessageInfo> fresh) throws Error {
            if (f.role != "inbox") return;
            var c = new Pop3Client ();
            try {
                yield c.open (account.imap_host, account.imap_port, account.imap_security, account.trusted_imap);
            } catch (MailError.TLS e) {
                trust = c.tls_failure;
                trust_kind = "imap";
                throw e;
            }
            string user = account.imap_user != "" ? account.imap_user : account.email;
            var login = yield owner.current_login ();
            try {
                if (login.is_token) yield c.login_xoauth2 (login.xoauth2);
                else yield c.login (user, login.secret);
            } catch (MailError.AUTH e) {
                if (account.managed) owner.login_refused (e);
                throw e;
            }
            var seen = new Gee.HashSet<string> ();
            foreach (string s in (store.get_value (account.id, "pop-uidl") ?? "").split ("\n")) if (s != "") seen.add (s);
            var present = new Gee.ArrayList<string> ();
            bool initial = seen.size == 0 && store.max_uid (f.id) == 0;
            foreach (string entry in yield c.uidl ()) {
                string[] p = entry.split (" ", 2);
                if (p.length < 2) continue;
                int n = int.parse (p[0]);
                string uid = p[1].strip ();
                present.add (uid);
                if (seen.contains (uid)) continue;
                var raw = yield c.retr (n);
                int64 id = store.insert_message (f, store.max_uid (f.id) + 1, 0, raw.length, raw, new DateTime.now_utc ().to_unix (), "pop:" + uid);
                store.set_body (id, raw);
                seen.add (uid);
                if (!account.pop_keep) yield c.dele (n);
                if (notify && !initial) {
                    var m = store.message (id);
                    if (m != null) fresh.add (m);
                }
            }
            yield c.quit ();
            var keep = new Gee.ArrayList<string> ();
            foreach (string s in seen) if (!account.pop_keep || present.contains (s)) keep.add (s);
            store.set_value (account.id, "pop-uidl", string.joinv ("\n", keep.to_array ()));
        }
    }
}
