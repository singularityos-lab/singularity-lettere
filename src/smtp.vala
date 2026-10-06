namespace Singularity.Apps.Lettere {

    public class SmtpReply {
        public int code;
        public Gee.ArrayList<string> lines = new Gee.ArrayList<string> ();

        public string text {
            owned get { return string.joinv (" ", lines.to_array ()); }
        }
    }

    public class SmtpClient : Object {
        public Gee.HashSet<string> extensions = new Gee.HashSet<string> ();
        public Gee.HashSet<string> auth_methods = new Gee.HashSet<string> ();
        public CertificateTrust? tls_failure;

        private SocketConnection? socket_conn;
        private IOStream? stream;
        private DataInputStream? input;
        private OutputStream? output;
        private Cancellable cancel = new Cancellable ();
        private string helo_name;

        public SmtpClient () {
            helo_name = Environment.get_host_name ();
            if (helo_name == "" || helo_name == "localhost") helo_name = "localhost.localdomain";
        }

        public static uint8[] dot_stuff (uint8[] message) {
            var b = new ByteArray.sized ((uint) message.length + 64);
            bool line_start = true;
            int n = message.length;
            for (int i = 0; i < n; i++) {
                uint8 c = message[i];
                if (c == '\n' && (i == 0 || message[i - 1] != '\r')) {
                    b.append ("\r\n".data);
                    line_start = true;
                    continue;
                }
                if (c == '\r' && (i + 1 >= n || message[i + 1] != '\n')) {
                    b.append ("\r\n".data);
                    line_start = true;
                    continue;
                }
                if (line_start && c == '.') b.append ({ '.' });
                b.append ({ c });
                line_start = c == '\n';
            }
            if (b.len < 2 || b.data[b.len - 2] != '\r' || b.data[b.len - 1] != '\n') b.append ("\r\n".data);
            b.append (".\r\n".data);
            return b.steal ();
        }

        public static SmtpReply parse_reply (Gee.List<string> raw) throws MailError {
            var r = new SmtpReply ();
            foreach (string line in raw) {
                if (line.length < 3) throw new MailError.PROTOCOL (_("Unexpected reply from the mail server"));
                r.code = int.parse (line.substring (0, 3));
                r.lines.add (line.length > 4 ? line.substring (4) : "");
            }
            if (r.code < 200 || r.code > 599) throw new MailError.PROTOCOL (_("Unexpected reply from the mail server"));
            return r;
        }

        private async SmtpReply read_reply () throws Error {
            var raw = new Gee.ArrayList<string> ();
            while (true) {
                size_t len;
                string? line = yield input.read_line_async (Priority.DEFAULT, cancel, out len);
                if (line == null) throw new MailError.CLOSED (_("The server closed the connection"));
                raw.add (line);
                if (line.length < 4 || line[3] != '-') break;
            }
            return parse_reply (raw);
        }

        private async void write (string s) throws Error {
            size_t w;
            yield output.write_all_async (s.data, Priority.DEFAULT, cancel, out w);
            yield output.flush_async (Priority.DEFAULT, cancel);
        }

        private async SmtpReply command (string line, int expect) throws Error {
            yield write (line + "\r\n");
            var r = yield read_reply ();
            if (r.code / 100 != expect) {
                if (r.code == 535 || r.code == 534 || r.code == 530) throw new MailError.AUTH (r.text);
                throw new MailError.SERVER ("%d %s".printf (r.code, r.text));
            }
            return r;
        }

        private void set_streams () {
            if (input != null) input.close_base_stream = false;
            input = new DataInputStream (stream.input_stream);
            input.newline_type = DataStreamNewlineType.ANY;
            output = stream.output_stream;
        }

        private async void ehlo () throws Error {
            SmtpReply r;
            try {
                r = yield command ("EHLO " + helo_name, 2);
            } catch (MailError.SERVER e) {
                yield command ("HELO " + helo_name, 2);
                extensions.clear ();
                return;
            }
            extensions.clear ();
            auth_methods.clear ();
            for (int i = 1; i < r.lines.size; i++) {
                string l = r.lines[i].strip ().up ();
                string[] parts = l.split (" ");
                extensions.add (parts[0]);
                if (parts[0] == "AUTH" || parts[0] == "AUTH=") {
                    for (int k = 1; k < parts.length; k++) auth_methods.add (parts[k]);
                }
            }
        }

        public async void open (string host, uint16 port, Security security, string trusted_fingerprint) throws Error {
            var client = new SocketClient ();
            client.timeout = 30;
            try {
                socket_conn = yield client.connect_to_host_async (host, port, cancel);
            } catch (Error e) {
                throw new MailError.OFFLINE (_("Could not reach %s: %s").printf (host, e.message));
            }
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
            var greet = yield read_reply ();
            if (greet.code != 220) throw new MailError.SERVER ("%d %s".printf (greet.code, greet.text));
            yield ehlo ();
            if (security == Security.STARTTLS) {
                if (!extensions.contains ("STARTTLS")) throw new MailError.TLS (_("%s does not offer STARTTLS").printf (host));
                yield command ("STARTTLS", 2);
                var outcome = new Tls.Outcome ();
                try {
                    stream = yield Tls.wrap (socket_conn, host, port, trusted_fingerprint, outcome, cancel);
                } catch (Error e) {
                    tls_failure = outcome.failure;
                    throw e;
                }
                set_streams ();
                yield ehlo ();
            }
        }

        public async void login (string user, string password) throws Error {
            if (auth_methods.contains ("PLAIN") || auth_methods.size == 0) {
                yield command ("AUTH PLAIN " + ImapClient.sasl_plain (user, password), 2);
                return;
            }
            if (auth_methods.contains ("LOGIN")) {
                yield command ("AUTH LOGIN", 3);
                yield command (Base64.encode (user.data), 3);
                yield command (Base64.encode (password.data), 2);
                return;
            }
            throw new MailError.AUTH (_("The server offers no sign-in method Lettere supports"));
        }

        public async void login_xoauth2 (string response) throws Error {
            yield write ("AUTH XOAUTH2 " + response + "\r\n");
            var r = yield read_reply ();
            if (r.code == 334) {
                yield write ("\r\n");
                r = yield read_reply ();
            }
            if (r.code / 100 == 2) return;
            if (r.code == 535 || r.code == 534 || r.code == 530) throw new MailError.AUTH (r.text);
            throw new MailError.SERVER ("%d %s".printf (r.code, r.text));
        }

        public async void send (string from, Gee.List<string> recipients, uint8[] message) throws Error {
            string size = extensions.contains ("SIZE") ? " SIZE=%d".printf (message.length) : "";
            yield command ("MAIL FROM:<%s>%s".printf (from, size), 2);
            int accepted = 0;
            string last_error = "";
            foreach (string rcpt in recipients) {
                try {
                    yield command ("RCPT TO:<%s>".printf (rcpt), 2);
                    accepted++;
                } catch (MailError.SERVER e) {
                    last_error = e.message;
                }
            }
            if (accepted == 0) {
                try {
                    yield command ("RSET", 2);
                } catch (Error e) {
                }
                throw new MailError.SERVER (_("No recipient was accepted: %s").printf (last_error));
            }
            yield command ("DATA", 3);
            size_t w;
            yield output.write_all_async (dot_stuff (message), Priority.DEFAULT, cancel, out w);
            yield output.flush_async (Priority.DEFAULT, cancel);
            var r = yield read_reply ();
            if (r.code / 100 != 2) throw new MailError.SERVER ("%d %s".printf (r.code, r.text));
        }

        public async void quit () {
            try {
                yield command ("QUIT", 2);
            } catch (Error e) {
            }
            try {
                if (stream != null) stream.close ();
            } catch (Error e) {
            }
        }
    }
}
