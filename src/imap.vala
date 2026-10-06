namespace Singularity.Apps.Lettere {

    public errordomain MailError {
        AUTH,
        TLS,
        SERVER,
        PROTOCOL,
        CLOSED,
        OFFLINE
    }

    public enum Security {
        TLS,
        STARTTLS,
        NONE;

        public string to_id () {
            switch (this) {
                case STARTTLS: return "starttls";
                case NONE: return "none";
                default: return "tls";
            }
        }

        public static Security from_id (string id) {
            switch (id.down ()) {
                case "starttls": return STARTTLS;
                case "none":
                case "plain": return NONE;
                default: return TLS;
            }
        }
    }

    public enum ImapKind {
        ATOM,
        STRING,
        LIST,
        NIL
    }

    public class ImapValue {
        public ImapKind kind;
        public string text = "";
        public uint8[]? data = null;
        public Gee.ArrayList<ImapValue> items = new Gee.ArrayList<ImapValue> ();

        public ImapValue (ImapKind kind) {
            this.kind = kind;
        }

        public string str () {
            if (kind == ImapKind.NIL) return "";
            if (data != null) return Mime.bytes_to_string (data);
            return text;
        }

        public int64 number () {
            int64 v = 0;
            int64.try_parse (text, out v);
            return v;
        }

        public bool is_list {
            get { return kind == ImapKind.LIST; }
        }

        public uint8[] bytes () {
            if (data != null) return data;
            return text.data;
        }
    }

    public class ImapParser {
        private uint8[] buf;
        private int pos;

        public ImapParser (uint8[] buf, int start = 0) {
            this.buf = buf;
            this.pos = start;
        }

        public bool at_end {
            get {
                skip_spaces ();
                return pos >= buf.length || buf[pos] == '\r' || buf[pos] == '\n';
            }
        }

        public int position {
            get { return pos; }
        }

        private void skip_spaces () {
            while (pos < buf.length && buf[pos] == ' ') pos++;
        }

        public string rest () {
            if (pos >= buf.length) return "";
            var end = buf.length;
            while (end > pos && (buf[end - 1] == '\n' || buf[end - 1] == '\r')) end--;
            string r = Mime.bytes_to_string (buf[pos:end]);
            pos = buf.length;
            return r;
        }

        public ImapValue? next () throws MailError {
            skip_spaces ();
            if (pos >= buf.length) return null;
            uint8 c = buf[pos];
            if (c == '\r' || c == '\n') return null;
            if (c == '(') {
                pos++;
                var list = new ImapValue (ImapKind.LIST);
                while (true) {
                    skip_spaces ();
                    if (pos >= buf.length) throw new MailError.PROTOCOL ("Unterminated list");
                    if (buf[pos] == ')') {
                        pos++;
                        break;
                    }
                    var v = next ();
                    if (v == null) throw new MailError.PROTOCOL ("Unterminated list");
                    list.items.add (v);
                }
                return list;
            }
            if (c == ')') throw new MailError.PROTOCOL ("Unexpected )");
            if (c == '"') {
                pos++;
                var b = new ByteArray ();
                while (pos < buf.length && buf[pos] != '"') {
                    if (buf[pos] == '\\' && pos + 1 < buf.length) pos++;
                    b.append ({ buf[pos] });
                    pos++;
                }
                if (pos >= buf.length) throw new MailError.PROTOCOL ("Unterminated string");
                pos++;
                var v = new ImapValue (ImapKind.STRING);
                v.data = b.steal ();
                return v;
            }
            if (c == '{' || (c == '~' && pos + 1 < buf.length && buf[pos + 1] == '{')) {
                if (c == '~') pos++;
                int close = pos;
                while (close < buf.length && buf[close] != '}') close++;
                if (close >= buf.length) throw new MailError.PROTOCOL ("Bad literal");
                string num = Mime.bytes_to_string (buf[pos + 1:close]).replace ("+", "");
                int64 n = 0;
                if (!int64.try_parse (num, out n) || n < 0) throw new MailError.PROTOCOL ("Bad literal size");
                pos = close + 1;
                if (pos < buf.length && buf[pos] == '\r') pos++;
                if (pos < buf.length && buf[pos] == '\n') pos++;
                if (pos + n > buf.length) throw new MailError.PROTOCOL ("Truncated literal");
                var v = new ImapValue (ImapKind.STRING);
                v.data = buf[pos:pos + (int) n];
                pos += (int) n;
                return v;
            }
            int start = pos;
            int depth = 0;
            while (pos < buf.length) {
                uint8 d = buf[pos];
                if (d == '[') depth++;
                else if (d == ']' && depth > 0) depth--;
                else if (depth == 0 && (d == ' ' || d == '(' || d == ')' || d == '\r' || d == '\n' || d == '{')) break;
                pos++;
            }
            string atom = Mime.bytes_to_string (buf[start:pos]);
            if (atom.up () == "NIL") return new ImapValue (ImapKind.NIL);
            var v = new ImapValue (ImapKind.ATOM);
            v.text = atom;
            return v;
        }
    }

    public class ImapResponse {
        public string tag = "";
        public string status = "";
        public string code = "";
        public string text = "";
        public Gee.ArrayList<ImapValue> values = new Gee.ArrayList<ImapValue> ();
        public uint8[] raw;

        public static ImapResponse parse (uint8[] raw) throws MailError {
            var r = new ImapResponse ();
            r.raw = raw;
            var p = new ImapParser (raw);
            var tag = p.next ();
            if (tag == null) throw new MailError.PROTOCOL ("Empty response");
            r.tag = tag.text;
            if (r.tag == "+") {
                r.text = p.rest ();
                return r;
            }
            var first = p.next ();
            if (first == null) return r;
            string word = first.text.up ();
            if (word == "OK" || word == "NO" || word == "BAD" || word == "BYE" || word == "PREAUTH") {
                r.status = word;
                string rest = p.rest ().strip ();
                if (rest.has_prefix ("[")) {
                    int close = rest.index_of_char (']');
                    if (close > 0) {
                        r.code = rest.substring (1, close - 1);
                        rest = rest.substring (close + 1).strip ();
                    }
                }
                r.text = rest;
                return r;
            }
            r.values.add (first);
            if (word == "CAPABILITY" || word == "ENABLED") {
                foreach (string s in p.rest ().split (" ")) {
                    if (s.strip () == "") continue;
                    var v = new ImapValue (ImapKind.ATOM);
                    v.text = s.strip ();
                    r.values.add (v);
                }
                return r;
            }
            while (!p.at_end) {
                var v = p.next ();
                if (v == null) break;
                r.values.add (v);
            }
            return r;
        }

        public string word (int i) {
            if (i >= values.size) return "";
            return values[i].kind == ImapKind.ATOM ? values[i].text.up () : "";
        }

        public string code_word {
            owned get {
                int sp = code.index_of_char (' ');
                return (sp < 0 ? code : code.substring (0, sp)).up ();
            }
        }

        public string code_arg {
            owned get {
                int sp = code.index_of_char (' ');
                return sp < 0 ? "" : code.substring (sp + 1).strip ();
            }
        }
    }

    public class FetchItem {
        public int64 seq;
        public int64 uid;
        public Gee.ArrayList<string> flags = new Gee.ArrayList<string> ();
        public bool has_flags;
        public int64 size;
        public int64 modseq;
        public string internaldate = "";
        public uint8[]? header = null;
        public uint8[]? body = null;

        public static FetchItem? from (ImapResponse r) {
            if (r.tag != "*" || r.values.size < 3 || r.word (1) != "FETCH" || !r.values[2].is_list) return null;
            var f = new FetchItem ();
            f.seq = r.values[0].number ();
            var items = r.values[2].items;
            for (int i = 0; i + 1 < items.size; i += 2) {
                string key = items[i].text.up ();
                var val = items[i + 1];
                if (key == "UID") {
                    f.uid = val.number ();
                } else if (key == "FLAGS") {
                    f.has_flags = true;
                    foreach (var fl in val.items) f.flags.add (fl.text);
                } else if (key == "RFC822.SIZE") {
                    f.size = val.number ();
                } else if (key == "MODSEQ") {
                    if (val.items.size > 0) f.modseq = val.items[0].number ();
                } else if (key == "INTERNALDATE") {
                    f.internaldate = val.str ();
                } else if (key.has_prefix ("BODY[HEADER") || key == "RFC822.HEADER") {
                    f.header = val.kind == ImapKind.NIL ? new uint8[0] : val.bytes ();
                } else if (key.has_prefix ("BODY[]") || key == "RFC822" || key.has_prefix ("BINARY[]")) {
                    f.body = val.kind == ImapKind.NIL ? new uint8[0] : val.bytes ();
                } else if (key.has_prefix ("BODY[") && key.has_suffix ("]")) {
                    f.body = val.bytes ();
                }
            }
            return f;
        }

        public bool has (string flag) {
            foreach (string s in flags) if (s.down () == flag.down ()) return true;
            return false;
        }
    }

    public class MailboxInfo {
        public string name;
        public string delimiter = "/";
        public Gee.ArrayList<string> attributes = new Gee.ArrayList<string> ();

        public bool has (string attr) {
            foreach (string a in attributes) if (a.down () == attr.down ()) return true;
            return false;
        }
    }

    public class SelectInfo {
        public int64 exists;
        public int64 uidvalidity;
        public int64 uidnext;
        public int64 highestmodseq;
        public bool read_only;
    }

    public class CertificateTrust : Object {
        public string host { get; set; }
        public string fingerprint { get; set; }
        public string problem { get; set; }

        public CertificateTrust (string host, string fingerprint, string problem) {
            this.host = host;
            this.fingerprint = fingerprint;
            this.problem = problem;
        }
    }

    namespace Tls {
        public string fingerprint (TlsCertificate cert) {
            var der = cert.certificate;
            if (der == null) return "";
            return Checksum.compute_for_data (ChecksumType.SHA256, der.data);
        }

        public string describe (TlsCertificateFlags errors) {
            var parts = new Gee.ArrayList<string> ();
            if (TlsCertificateFlags.UNKNOWN_CA in errors) parts.add (_("it is not signed by a known authority"));
            if (TlsCertificateFlags.BAD_IDENTITY in errors) parts.add (_("it belongs to a different server"));
            if (TlsCertificateFlags.EXPIRED in errors) parts.add (_("it has expired"));
            if (TlsCertificateFlags.NOT_ACTIVATED in errors) parts.add (_("it is not valid yet"));
            if (TlsCertificateFlags.REVOKED in errors) parts.add (_("it was revoked"));
            if (TlsCertificateFlags.INSECURE in errors) parts.add (_("it uses an insecure algorithm"));
            if (parts.size == 0) parts.add (_("it could not be verified"));
            return string.joinv (", ", parts.to_array ());
        }

        public class Outcome {
            public CertificateTrust? failure;
        }

        public async IOStream wrap (IOStream base_stream, string host, uint16 port, string trusted, Outcome outcome, Cancellable? cancel) throws Error {
            var tls = TlsClientConnection.new (base_stream, new NetworkAddress (host, port));
            CertificateTrust? bad = null;
            tls.accept_certificate.connect ((cert, errors) => {
                string fp = fingerprint (cert);
                if (trusted == "*" || (trusted != "" && fp == trusted)) return true;
                bad = new CertificateTrust (host, fp, describe (errors));
                return false;
            });
            try {
                yield tls.handshake_async (Priority.DEFAULT, cancel);
            } catch (Error e) {
                outcome.failure = bad;
                if (bad != null) throw new MailError.TLS (_("The certificate of %s is not trusted: %s").printf (host, bad.problem));
                throw new MailError.TLS (_("Secure connection to %s failed: %s").printf (host, e.message));
            }
            return tls;
        }
    }

    public class ImapClient : Object {
        public signal void untagged (ImapResponse r);
        public signal void closed ();

        public Gee.HashSet<string> capabilities = new Gee.HashSet<string> ();
        public CertificateTrust? tls_failure;
        public string selected = "";
        public bool connected { get; private set; }
        public bool debug;

        private SocketConnection? socket_conn;
        private IOStream? stream;
        private DataInputStream? input;
        private OutputStream? output;
        private int tag_counter;
        private bool busy;
        private Gee.ArrayQueue<Waiter> waiters = new Gee.ArrayQueue<Waiter> ();
        private Cancellable cancel = new Cancellable ();

        private class Waiter {
            public SourceFunc cb;

            public Waiter (owned SourceFunc cb) {
                this.cb = (owned) cb;
            }
        }

        public bool has_cap (string cap) {
            return capabilities.contains (cap.up ());
        }

        private async void acquire () {
            while (busy) {
                waiters.offer (new Waiter (acquire.callback));
                yield;
            }
            busy = true;
        }

        private void release () {
            busy = false;
            var w = waiters.poll ();
            if (w != null) Idle.add ((owned) w.cb);
        }

        public async void open (string host, uint16 port, Security security, string trusted_fingerprint, int timeout = 30) throws Error {
            var client = new SocketClient ();
            client.timeout = timeout;
            try {
                socket_conn = yield client.connect_to_host_async (host, port, cancel);
            } catch (Error e) {
                throw new MailError.OFFLINE (_("Could not reach %s: %s").printf (host, e.message));
            }
            socket_conn.socket.keepalive = true;
            stream = socket_conn;
            if (security == Security.TLS) {
                var outcome = new Tls.Outcome ();
                try {
                    stream = yield Tls.wrap (socket_conn, host, port, trusted_fingerprint, outcome, cancel);
                } catch (Error e) {
                    tls_failure = outcome.failure;
                    throw e;
                }
            }
            set_streams ();
            var greeting = yield read_response ();
            if (greeting.status == "BYE") throw new MailError.SERVER (greeting.text);
            if (greeting.code_word == "CAPABILITY") parse_caps (greeting.code_arg);
            if (security == Security.STARTTLS) {
                if (capabilities.size == 0) yield load_capabilities ();
                if (!has_cap ("STARTTLS")) throw new MailError.TLS (_("%s does not offer STARTTLS").printf (host));
                yield run ("STARTTLS");
                var outcome = new Tls.Outcome ();
                try {
                    stream = yield Tls.wrap (socket_conn, host, port, trusted_fingerprint, outcome, cancel);
                } catch (Error e) {
                    tls_failure = outcome.failure;
                    throw e;
                }
                set_streams ();
                capabilities.clear ();
            }
            connected = true;
            if (capabilities.size == 0) yield load_capabilities ();
        }

        private void set_streams () {
            if (input != null) input.close_base_stream = false;
            input = new DataInputStream (stream.input_stream);
            input.newline_type = DataStreamNewlineType.ANY;
            input.buffer_size = 65536;
            output = stream.output_stream;
        }

        public void set_idle_timeout (uint seconds) {
            if (socket_conn != null) socket_conn.socket.timeout = seconds;
        }

        private void parse_caps (string text) {
            capabilities.clear ();
            foreach (string c in text.split (" ")) {
                if (c.strip () != "") capabilities.add (c.strip ().up ());
            }
        }

        public async void load_capabilities () throws Error {
            var res = yield run ("CAPABILITY");
            foreach (var r in res) {
                if (r.tag == "*" && r.word (0) == "CAPABILITY") {
                    capabilities.clear ();
                    for (int i = 1; i < r.values.size; i++) capabilities.add (r.values[i].text.up ());
                }
            }
        }

        public async void login (string user, string password) throws Error {
            Gee.List<ImapResponse> res;
            try {
                if (has_cap ("AUTH=PLAIN")) {
                    string token = sasl_plain (user, password);
                    if (has_cap ("SASL-IR")) {
                        res = yield run ("AUTHENTICATE PLAIN " + token, null, true);
                    } else {
                        res = yield run_continued ("AUTHENTICATE PLAIN", token);
                    }
                } else {
                    if (has_cap ("LOGINDISABLED")) throw new MailError.AUTH (_("The server does not accept passwords on this connection"));
                    res = yield run_login (user, password);
                }
            } catch (MailError.SERVER e) {
                throw new MailError.AUTH (e.message);
            }
            yield signed_in (res);
        }

        private async void signed_in (Gee.List<ImapResponse> res) throws Error {
            foreach (var r in res) {
                if (r.status == "OK" && r.code_word == "CAPABILITY") parse_caps (r.code_arg);
            }
            if (!has_cap ("IMAP4REV1") && !has_cap ("IMAP4REV2")) yield load_capabilities ();
        }

        public async void login_xoauth2 (string response) throws Error {
            var list = new Gee.ArrayList<ImapResponse> ();
            yield acquire ();
            try {
                string tag = next_tag ();
                bool initial = has_cap ("SASL-IR");
                if (debug) stderr.printf ("C: %s AUTHENTICATE XOAUTH2 [hidden]\n", tag);
                yield write_all ((tag + " AUTHENTICATE XOAUTH2" + (initial ? " " + response : "") + "\r\n").data);
                bool sent = initial;
                while (true) {
                    var r = yield read_response ();
                    if (r.tag == "+") {
                        yield write_all (((sent ? "" : response) + "\r\n").data);
                        sent = true;
                        continue;
                    }
                    list.add (r);
                    if (r.tag == "*") {
                        untagged (r);
                        continue;
                    }
                    if (r.tag == tag) {
                        if (r.status != "OK") throw new MailError.AUTH (r.text != "" ? r.text : r.status);
                        break;
                    }
                }
            } finally {
                release ();
            }
            yield signed_in (list);
        }

        private async Gee.List<ImapResponse> run_login (string user, string password) throws Error {
            bool literal = needs_literal (user) || needs_literal (password);
            if (!literal) return yield run ("LOGIN %s %s".printf (quote (user), quote (password)), null, true);
            var lits = new Gee.ArrayList<Bytes> ();
            lits.add (new Bytes (user.data));
            lits.add (new Bytes (password.data));
            return yield run_parts ("LOGIN ", lits, true);
        }

        public static string sasl_plain (string user, string password) {
            var b = new ByteArray ();
            b.append ({ 0 });
            b.append (user.data);
            b.append ({ 0 });
            b.append (password.data);
            return Base64.encode (b.data);
        }

        public static bool needs_literal (string s) {
            for (int i = 0; i < s.length; i++) {
                uint8 c = (uint8) s[i];
                if (c > 126 || c < 32) return true;
            }
            return false;
        }

        public static string quote (string s) {
            return "\"" + s.replace ("\\", "\\\\").replace ("\"", "\\\"") + "\"";
        }

        public static string mailbox_arg (string name) {
            return quote (Utf7.encode (name));
        }

        private async void write_all (uint8[] data) throws Error {
            size_t written;
            yield output.write_all_async (data, Priority.DEFAULT, cancel, out written);
            yield output.flush_async (Priority.DEFAULT, cancel);
        }

        private string next_tag () {
            tag_counter++;
            return "L%04d".printf (tag_counter);
        }

        private async uint8[] read_raw () throws Error {
            var buf = new ByteArray ();
            while (true) {
                size_t len;
                string? line = yield input.read_line_async (Priority.DEFAULT, cancel, out len);
                if (line == null) {
                    connected = false;
                    closed ();
                    throw new MailError.CLOSED (_("The server closed the connection"));
                }
                uint8[] lb = line.data;
                lb.length = (int) len;
                buf.append (lb);
                buf.append ("\r\n".data);
                int64 lit = literal_size (line, len);
                if (lit < 0) break;
                if (lit > 0) {
                    var chunk = new uint8[lit];
                    size_t got;
                    yield input.read_all_async (chunk, Priority.DEFAULT, cancel, out got);
                    if (got < lit) {
                        connected = false;
                        throw new MailError.CLOSED (_("The server closed the connection"));
                    }
                    buf.append (chunk);
                }
            }
            if (debug) stderr.printf ("S: %s", Mime.bytes_to_string (buf.data).substring (0, int.min (400, (int) buf.len)));
            return buf.steal ();
        }

        public static int64 literal_size (string line, size_t len) {
            if (len < 3 || line[(long) len - 1] != '}') return -1;
            int open = line.last_index_of_char ('{');
            if (open < 0) return -1;
            string num = line.substring (open + 1, (long) len - open - 2).replace ("+", "");
            int64 n;
            if (!int64.try_parse (num, out n)) return -1;
            return n;
        }

        public async ImapResponse read_response () throws Error {
            var raw = yield read_raw ();
            return ImapResponse.parse (raw);
        }

        public async Gee.List<ImapResponse> run (string command, Cancellable? c = null, bool secret = false) throws Error {
            yield acquire ();
            try {
                string tag = next_tag ();
                if (debug) stderr.printf ("C: %s %s\n", tag, secret ? "[hidden]" : command);
                yield write_all ((tag + " " + command + "\r\n").data);
                return yield collect (tag);
            } finally {
                release ();
            }
        }

        private async Gee.List<ImapResponse> collect (string tag) throws Error {
            var list = new Gee.ArrayList<ImapResponse> ();
            while (true) {
                var r = yield read_response ();
                list.add (r);
                if (r.tag == "*") {
                    if (r.status == "BYE") {
                        connected = false;
                    }
                    untagged (r);
                    continue;
                }
                if (r.tag == tag) {
                    if (r.status != "OK") throw new MailError.SERVER (r.text != "" ? r.text : r.status);
                    return list;
                }
            }
        }

        private async Gee.List<ImapResponse> run_continued (string command, string response) throws Error {
            yield acquire ();
            try {
                string tag = next_tag ();
                yield write_all ((tag + " " + command + "\r\n").data);
                var r = yield read_response ();
                if (r.tag == tag) {
                    if (r.status != "OK") throw new MailError.SERVER (r.text);
                    var l = new Gee.ArrayList<ImapResponse> ();
                    l.add (r);
                    return l;
                }
                if (r.tag != "+") throw new MailError.PROTOCOL ("Expected continuation");
                yield write_all ((response + "\r\n").data);
                return yield collect (tag);
            } finally {
                release ();
            }
        }

        private async Gee.List<ImapResponse> run_parts (string prefix, Gee.List<Bytes> literals, bool secret = false) throws Error {
            yield acquire ();
            try {
                string tag = next_tag ();
                bool plus = has_cap ("LITERAL+");
                var head = new StringBuilder (tag + " " + prefix);
                for (int i = 0; i < literals.size; i++) {
                    if (i > 0) head.append (" ");
                    head.append ("{%d%s}\r\n".printf ((int) literals[i].get_size (), plus ? "+" : ""));
                    yield write_all (head.str.data);
                    head.truncate (0);
                    if (!plus) {
                        var r = yield read_response ();
                        if (r.tag == tag) throw new MailError.SERVER (r.text);
                        if (r.tag != "+") throw new MailError.PROTOCOL ("Expected continuation");
                    }
                    yield write_all (literals[i].get_data ());
                }
                yield write_all ("\r\n".data);
                return yield collect (tag);
            } finally {
                release ();
            }
        }

        public async void enable_condstore () {
            if (!has_cap ("CONDSTORE")) return;
            if (has_cap ("ENABLE")) {
                try {
                    yield run ("ENABLE CONDSTORE");
                } catch (Error e) {
                }
            }
        }

        public async Gee.List<MailboxInfo> list () throws Error {
            string cmd = has_cap ("SPECIAL-USE") ? "LIST \"\" \"*\" RETURN (SPECIAL-USE)" : "LIST \"\" \"*\"";
            Gee.List<ImapResponse> res;
            try {
                res = yield run (cmd);
            } catch (MailError.SERVER e) {
                res = yield run ("LIST \"\" \"*\"");
            }
            var list = new Gee.ArrayList<MailboxInfo> ();
            foreach (var r in res) {
                if (r.tag != "*" || r.word (0) != "LIST" || r.values.size < 4) continue;
                var info = new MailboxInfo ();
                foreach (var a in r.values[1].items) info.attributes.add (a.text);
                info.delimiter = r.values[2].str ();
                info.name = Utf7.decode (r.values[3].str ());
                if (info.has ("\\NoSelect") || info.has ("\\NonExistent")) continue;
                list.add (info);
            }
            return list;
        }

        public async Gee.List<MailboxInfo> list_pattern (string pattern) throws Error {
            var res = yield run ("LIST \"\" " + mailbox_arg (pattern));
            var list = new Gee.ArrayList<MailboxInfo> ();
            foreach (var r in res) {
                if (r.tag != "*" || r.word (0) != "LIST" || r.values.size < 4) continue;
                var info = new MailboxInfo ();
                foreach (var a in r.values[1].items) info.attributes.add (a.text);
                info.delimiter = r.values[2].str ();
                info.name = Utf7.decode (r.values[3].str ());
                if (info.has ("\\NoSelect") || info.has ("\\NonExistent")) continue;
                list.add (info);
            }
            return list;
        }

        public async SelectInfo select (string mailbox, bool read_only = false) throws Error {
            string cmd = "%s %s".printf (read_only ? "EXAMINE" : "SELECT", mailbox_arg (mailbox));
            if (has_cap ("CONDSTORE")) cmd += " (CONDSTORE)";
            var res = yield run (cmd);
            var info = new SelectInfo ();
            foreach (var r in res) {
                if (r.tag == "*" && r.values.size >= 2 && r.word (1) == "EXISTS") info.exists = r.values[0].number ();
                string arg = r.code_arg;
                switch (r.code_word) {
                    case "UIDVALIDITY": info.uidvalidity = int64.parse (arg); break;
                    case "UIDNEXT": info.uidnext = int64.parse (arg); break;
                    case "HIGHESTMODSEQ": info.highestmodseq = int64.parse (arg); break;
                    case "READ-ONLY": info.read_only = true; break;
                }
            }
            selected = mailbox;
            return info;
        }

        public async Gee.List<FetchItem> fetch (string uid_set, string items, string modifier = "") throws Error {
            var res = yield run ("UID FETCH %s (%s)%s".printf (uid_set, items, modifier != "" ? " " + modifier : ""));
            var list = new Gee.ArrayList<FetchItem> ();
            foreach (var r in res) {
                var f = FetchItem.from (r);
                if (f != null && f.uid > 0) list.add (f);
            }
            return list;
        }

        public async Gee.List<int64?> search (string criteria) throws Error {
            string cmd = "UID SEARCH " + criteria;
            Gee.List<ImapResponse> res;
            if (needs_literal (criteria)) {
                res = yield run ("UID SEARCH CHARSET UTF-8 " + criteria);
            } else {
                res = yield run (cmd);
            }
            var list = new Gee.ArrayList<int64?> ();
            foreach (var r in res) {
                if (r.tag == "*" && r.word (0) == "SEARCH") {
                    for (int i = 1; i < r.values.size; i++) {
                        if (r.values[i].is_list) continue;
                        list.add (r.values[i].number ());
                    }
                }
            }
            return list;
        }

        public async void store_flags (string uid_set, string op, string flags) throws Error {
            yield run ("UID STORE %s %s.SILENT (%s)".printf (uid_set, op, flags));
        }

        public async void move (string uid_set, string dest) throws Error {
            if (has_cap ("MOVE")) {
                yield run ("UID MOVE %s %s".printf (uid_set, mailbox_arg (dest)));
                return;
            }
            yield run ("UID COPY %s %s".printf (uid_set, mailbox_arg (dest)));
            yield store_flags (uid_set, "+FLAGS", "\\Deleted");
            yield expunge (uid_set);
        }

        public async void expunge (string uid_set) throws Error {
            if (has_cap ("UIDPLUS")) yield run ("UID EXPUNGE " + uid_set);
            else yield run ("EXPUNGE");
        }

        public async int64 append (string mailbox, string flags, uint8[] message) throws Error {
            var lits = new Gee.ArrayList<Bytes> ();
            lits.add (new Bytes (message));
            var res = yield run_parts ("APPEND %s (%s) ".printf (mailbox_arg (mailbox), flags), lits);
            foreach (var r in res) {
                if (r.status == "OK" && r.code_word == "APPENDUID") {
                    string[] p = r.code_arg.split (" ");
                    if (p.length >= 2) return int64.parse (p[1]);
                }
            }
            return 0;
        }

        public async void create (string mailbox) throws Error {
            yield run ("CREATE " + mailbox_arg (mailbox));
        }

        public async void noop () throws Error {
            yield run ("NOOP");
        }

        public async bool idle (Cancellable stop) throws Error {
            yield acquire ();
            bool changed = false;
            ulong handler = 0;
            try {
                string tag = next_tag ();
                yield write_all ((tag + " IDLE\r\n").data);
                var first = yield read_response ();
                if (first.tag == tag) throw new MailError.SERVER (first.text);
                if (first.tag != "+") {
                    untagged (first);
                    changed = true;
                }
                bool done_sent = false;
                handler = stop.cancelled.connect (() => {
                    if (done_sent) return;
                    done_sent = true;
                    Idle.add (() => {
                        write_all.begin ("DONE\r\n".data, (o, res) => {
                            try {
                                write_all.end (res);
                            } catch (Error e) {
                            }
                        });
                        return Source.REMOVE;
                    });
                });
                if (stop.is_cancelled () && !done_sent) {
                    done_sent = true;
                    yield write_all ("DONE\r\n".data);
                }
                while (true) {
                    var r = yield read_response ();
                    if (r.tag == tag) {
                        if (r.status != "OK") throw new MailError.SERVER (r.text);
                        break;
                    }
                    if (r.tag == "*") {
                        string w = r.word (1);
                        if (w == "EXISTS" || w == "EXPUNGE" || w == "FETCH" || r.word (0) == "VANISHED") changed = true;
                        untagged (r);
                        if (changed && !done_sent) {
                            done_sent = true;
                            yield write_all ("DONE\r\n".data);
                        }
                    }
                }
            } finally {
                if (handler != 0) stop.disconnect (handler);
                release ();
            }
            return changed;
        }

        public async void logout () {
            if (!connected) {
                close ();
                return;
            }
            try {
                yield run ("LOGOUT");
            } catch (Error e) {
            }
            close ();
        }

        public void close () {
            connected = false;
            cancel.cancel ();
            if (stream != null) {
                try {
                    stream.close ();
                } catch (Error e) {
                }
            }
            stream = null;
        }
    }

    namespace Utf7 {
        private const string ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+,";

        public string decode (string s) {
            if (!s.contains ("&")) return s;
            var sb = new StringBuilder ();
            int i = 0;
            while (i < s.length) {
                char c = s[i];
                if (c != '&') {
                    sb.append_c (c);
                    i++;
                    continue;
                }
                int end = s.index_of_char ('-', i);
                if (end < 0) {
                    sb.append (s.substring (i));
                    break;
                }
                if (end == i + 1) {
                    sb.append_c ('&');
                    i = end + 1;
                    continue;
                }
                string b64 = s.substring (i + 1, end - i - 1);
                uint bits = 0;
                int nbits = 0;
                var units = new Gee.ArrayList<uint16> ();
                for (int k = 0; k < b64.length; k++) {
                    int v = ALPHABET.index_of_char (b64[k]);
                    if (v < 0) continue;
                    bits = (bits << 6) | v;
                    nbits += 6;
                    if (nbits >= 16) {
                        nbits -= 16;
                        units.add ((uint16) ((bits >> nbits) & 0xffff));
                    }
                }
                for (int k = 0; k < units.size; k++) {
                    uint u = units[k];
                    if (u >= 0xd800 && u <= 0xdbff && k + 1 < units.size) {
                        uint lo = units[k + 1];
                        sb.append_unichar ((unichar) (0x10000 + ((u - 0xd800) << 10) + (lo - 0xdc00)));
                        k++;
                    } else {
                        sb.append_unichar ((unichar) u);
                    }
                }
                i = end + 1;
            }
            return sb.str;
        }

        public string encode (string s) {
            var sb = new StringBuilder ();
            var pending = new Gee.ArrayList<uint16> ();
            unichar ch;
            int idx = 0;
            while (true) {
                bool more = s.get_next_char (ref idx, out ch);
                bool direct = more && ch >= 0x20 && ch <= 0x7e;
                if ((direct || !more) && pending.size > 0) {
                    sb.append_c ('&');
                    uint bits = 0;
                    int nbits = 0;
                    foreach (uint16 u in pending) {
                        bits = (bits << 16) | u;
                        nbits += 16;
                        while (nbits >= 6) {
                            nbits -= 6;
                            sb.append_c (ALPHABET[(int) ((bits >> nbits) & 0x3f)]);
                        }
                    }
                    if (nbits > 0) sb.append_c (ALPHABET[(int) ((bits << (6 - nbits)) & 0x3f)]);
                    sb.append_c ('-');
                    pending.clear ();
                }
                if (!more) break;
                if (direct) {
                    if (ch == '&') sb.append ("&-");
                    else sb.append_unichar (ch);
                } else if (ch >= 0x10000) {
                    uint v = ch - 0x10000;
                    pending.add ((uint16) (0xd800 + (v >> 10)));
                    pending.add ((uint16) (0xdc00 + (v & 0x3ff)));
                } else {
                    pending.add ((uint16) ch);
                }
            }
            return sb.str;
        }
    }
}
