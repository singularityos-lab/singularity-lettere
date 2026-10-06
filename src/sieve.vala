namespace Singularity.Apps.Lettere {

    public class SieveClient : Object {
        private SocketConnection? socket_conn;
        private IOStream? stream;
        private DataInputStream? input;
        private OutputStream? output;
        public Gee.HashSet<string> capabilities = new Gee.HashSet<string> ();
        public string sasl = "";

        private void set_streams () {
            if (input != null) input.close_base_stream = false;
            input = new DataInputStream (stream.input_stream);
            input.newline_type = DataStreamNewlineType.CR_LF;
            output = stream.output_stream;
        }

        private async string read_line () throws Error {
            size_t len;
            string? line = yield input.read_line_async (Priority.DEFAULT, null, out len);
            if (line == null) throw new MailError.CLOSED (_("The server closed the connection"));
            return line;
        }

        private async void write (string s) throws Error {
            size_t written;
            yield output.write_all_async (s.data, Priority.DEFAULT, null, out written);
            yield output.flush_async (Priority.DEFAULT, null);
        }

        public static int64 literal_of (string line) {
            string l = line.strip ();
            if (!l.has_suffix ("}")) return -1;
            int open = l.last_index_of_char ('{');
            if (open < 0) return -1;
            int64 n;
            if (!int64.try_parse (l.substring (open + 1, l.length - open - 2).replace ("+", ""), out n)) return -1;
            return n;
        }

        private async string read_literal (int64 n) throws Error {
            var buf = new uint8[n];
            size_t got;
            yield input.read_all_async (buf, Priority.DEFAULT, null, out got);
            yield read_line ();
            return Mime.bytes_to_string (buf);
        }

        private async string response (StringBuilder? data = null) throws Error {
            while (true) {
                string line = yield read_line ();
                string up = line.up ();
                if (up.has_prefix ("OK")) return line;
                if (up.has_prefix ("NO") || up.has_prefix ("BYE")) throw new MailError.SERVER (line.substring (int.min (3, line.length)).strip ());
                int64 lit = literal_of (line);
                if (lit >= 0) {
                    string text = yield read_literal (lit);
                    if (data != null) data.append (text);
                    continue;
                }
                if (data != null) data.append (line + "\n");
            }
        }

        private async void read_capabilities () throws Error {
            capabilities.clear ();
            var sb = new StringBuilder ();
            yield response (sb);
            foreach (string line in sb.str.split ("\n")) {
                string[] p = SearchQuery.split (line);
                if (p.length == 0) continue;
                capabilities.add (p[0].up ());
                if (p[0].up () == "SASL" && p.length > 1) sasl = p[1].up ();
            }
        }

        public async void open (string host, uint16 port, string trusted) throws Error {
            var client = new SocketClient ();
            client.timeout = 30;
            try {
                socket_conn = yield client.connect_to_host_async (host, port, null);
            } catch (Error e) {
                throw new MailError.OFFLINE (_("Could not reach %s: %s").printf (host, e.message));
            }
            stream = socket_conn;
            set_streams ();
            yield read_capabilities ();
            if (capabilities.contains ("STARTTLS")) {
                yield write ("STARTTLS\r\n");
                yield response ();
                var outcome = new Tls.Outcome ();
                stream = yield Tls.wrap (socket_conn, host, port, trusted, outcome, null);
                set_streams ();
                try {
                    yield read_capabilities ();
                } catch (Error e) {
                }
            }
        }

        public static string quote (string s) {
            return "\"" + s.replace ("\\", "\\\\").replace ("\"", "\\\"") + "\"";
        }

        public async void login (string user, string password) throws Error {
            try {
                yield write ("AUTHENTICATE \"PLAIN\" " + quote (ImapClient.sasl_plain (user, password)) + "\r\n");
                yield response ();
            } catch (MailError.SERVER e) {
                throw new MailError.AUTH (e.message);
            }
        }

        public async void login_xoauth2 (string token) throws Error {
            try {
                yield write ("AUTHENTICATE \"XOAUTH2\" " + quote (token) + "\r\n");
                yield response ();
            } catch (MailError.SERVER e) {
                throw new MailError.AUTH (e.message);
            }
        }

        public async Gee.List<string> list () throws Error {
            yield write ("LISTSCRIPTS\r\n");
            var sb = new StringBuilder ();
            yield response (sb);
            var names = new Gee.ArrayList<string> ();
            foreach (string line in sb.str.split ("\n")) {
                string[] p = SearchQuery.split (line);
                if (p.length > 0) names.add (p[0]);
            }
            return names;
        }

        public async string get_script (string name) throws Error {
            yield write ("GETSCRIPT " + quote (name) + "\r\n");
            var sb = new StringBuilder ();
            try {
                yield response (sb);
            } catch (MailError.SERVER e) {
                return "";
            }
            return sb.str;
        }

        public async void put_script (string name, string script) throws Error {
            string body = script.replace ("\r\n", "\n").replace ("\n", "\r\n");
            yield write ("PUTSCRIPT %s {%d+}\r\n%s\r\n".printf (quote (name), body.length, body));
            yield response ();
        }

        public async void activate (string name) throws Error {
            yield write ("SETACTIVE " + quote (name) + "\r\n");
            yield response ();
        }

        public void close () {
            if (output != null) write.begin ("LOGOUT\r\n", (o, r) => {
                try {
                    write.end (r);
                } catch (Error e) {
                }
                try {
                    if (stream != null) stream.close ();
                } catch (Error e) {
                }
            });
        }
    }

    namespace SieveScript {
        public const string RULES_BEGIN = "# lettere: rules";
        public const string RULES_END = "# lettere: end rules";
        public const string VACATION_BEGIN = "# lettere: vacation";
        public const string VACATION_END = "# lettere: end vacation";

        public string str (string s) {
            return "\"" + s.replace ("\\", "\\\\").replace ("\"", "\\\"") + "\"";
        }

        private string multiline (string s) {
            string body = s.replace ("\r\n", "\n");
            var sb = new StringBuilder ("text:\n");
            foreach (string line in body.split ("\n")) {
                if (line.has_prefix (".")) sb.append (".");
                sb.append (line + "\n");
            }
            sb.append (".\n");
            return sb.str;
        }

        private string section (string script, string begin, string end, out string before, out string after) {
            int a = script.index_of (begin);
            int b = script.index_of (end);
            if (a < 0 || b < a) {
                before = script;
                after = "";
                return "";
            }
            before = script.substring (0, a);
            after = script.substring (b + end.length);
            return script.substring (a + begin.length, b - a - begin.length);
        }

        private Gee.HashSet<string> requires (string script) {
            var set = new Gee.HashSet<string> ();
            foreach (string line in script.split ("\n")) {
                string l = line.strip ();
                if (!l.has_prefix ("require")) continue;
                foreach (string p in SearchQuery.split (l.substring (7).replace ("[", " ").replace ("]", " ").replace (",", " ").replace (";", " "))) {
                    if (p.strip () != "") set.add (p.strip ());
                }
            }
            return set;
        }

        private string strip_requires (string script) {
            var sb = new StringBuilder ();
            foreach (string line in script.split ("\n")) {
                if (line.strip ().has_prefix ("require")) continue;
                sb.append (line + "\n");
            }
            return sb.str.strip ();
        }

        private string assemble (string rules, string vacation, string rest) {
            var req = new Gee.TreeSet<string> ();
            req.add_all (requires (rules));
            req.add_all (requires (vacation));
            req.add_all (requires (rest));
            var sb = new StringBuilder ();
            if (req.size > 0) {
                var q = new Gee.ArrayList<string> ();
                foreach (string r in req) q.add (str (r));
                sb.append ("require [" + string.joinv (", ", q.to_array ()) + "];\n");
            }
            string v = strip_requires (vacation);
            if (v != "") sb.append (VACATION_BEGIN + "\n" + v + "\n" + VACATION_END + "\n");
            string r = strip_requires (rules);
            if (r != "") sb.append (RULES_BEGIN + "\n" + r + "\n" + RULES_END + "\n");
            string o = strip_requires (rest);
            if (o != "") sb.append (o + "\n");
            return sb.str;
        }

        public string with_vacation (string script, AutoReply r, string address) {
            string before, after;
            string old_rules = section (script, RULES_BEGIN, RULES_END, out before, out after);
            string rest = before + after;
            string b2, a2;
            section (rest, VACATION_BEGIN, VACATION_END, out b2, out a2);
            rest = b2 + a2;
            var v = new StringBuilder ();
            if (r.enabled) {
                v.append ("require [\"vacation\", \"date\", \"relational\"];\n");
                var tests = new Gee.ArrayList<string> ();
                if (r.start > 0) tests.add ("currentdate :value \"ge\" \"iso8601\" " + str (new DateTime.from_unix_utc (r.start).format ("%Y-%m-%dT%H:%M:%SZ")));
                if (r.end > 0) tests.add ("currentdate :value \"lt\" \"iso8601\" " + str (new DateTime.from_unix_utc (r.end).format ("%Y-%m-%dT%H:%M:%SZ")));
                string body = "vacation :days 1 :subject " + str (r.subject) + " :addresses [" + str (address) + "] " + multiline (r.message) + ";";
                if (tests.size > 0) v.append ("if allof (" + string.joinv (", ", tests.to_array ()) + ") {\n" + body + "\n}");
                else v.append (body);
            }
            return assemble (old_rules, v.str, rest);
        }

        public string with_rules (string script, string rules) {
            string before, after;
            section (script, RULES_BEGIN, RULES_END, out before, out after);
            string rest = before + after;
            string b2, a2;
            string vac = section (rest, VACATION_BEGIN, VACATION_END, out b2, out a2);
            return assemble (rules, vac, b2 + a2);
        }

        private int64 iso (string v) {
            var d = new DateTime.from_iso8601 (v, new TimeZone.utc ());
            return d != null ? d.to_unix () : 0;
        }

        public AutoReply parse_vacation (string script) {
            var r = new AutoReply ();
            string before, after;
            string v = section (script, VACATION_BEGIN, VACATION_END, out before, out after);
            if (v.strip () == "") return r;
            r.enabled = true;
            int ge = v.index_of ("\"ge\" \"iso8601\" \"");
            if (ge >= 0) r.start = iso (v.substring (ge + 16, 20));
            int lt = v.index_of ("\"lt\" \"iso8601\" \"");
            if (lt >= 0) r.end = iso (v.substring (lt + 16, 20));
            int subj = v.index_of (":subject \"");
            if (subj >= 0) {
                int s = subj + 10;
                var sb = new StringBuilder ();
                for (int i = s; i < v.length; i++) {
                    if (v[i] == '\\' && i + 1 < v.length) {
                        sb.append_c (v[++i]);
                        continue;
                    }
                    if (v[i] == '"') break;
                    sb.append_c (v[i]);
                }
                r.subject = sb.str;
            }
            int t = v.index_of ("text:\n");
            if (t >= 0) {
                var sb = new StringBuilder ();
                foreach (string line in v.substring (t + 6).split ("\n")) {
                    if (line == ".") break;
                    sb.append ((line.has_prefix ("..") ? line.substring (1) : line) + "\n");
                }
                r.message = sb.str.chomp ();
            }
            return r;
        }
    }
}
