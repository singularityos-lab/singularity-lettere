namespace Singularity.Apps.Lettere {

    public class ServerConfig : Object {
        public string host { get; set; default = ""; }
        public uint16 port { get; set; default = 0; }
        public Security security { get; set; default = Security.TLS; }
        public string username { get; set; default = ""; }
    }

    public class MailConfig : Object {
        public string provider { get; set; default = ""; }
        public string source { get; set; default = ""; }
        public ServerConfig imap { get; set; default = new ServerConfig (); }
        public ServerConfig smtp { get; set; default = new ServerConfig (); }
        public bool oauth_only { get; set; }
    }

    namespace Autoconfig {

        public string domain_of (string address) {
            int at = address.last_index_of_char ('@');
            return at < 0 ? "" : address.substring (at + 1).strip ().down ();
        }

        public string local_part (string address) {
            int at = address.last_index_of_char ('@');
            return at < 0 ? address : address.substring (0, at);
        }

        private string expand (string template, string address) {
            return template.replace ("%EMAILADDRESS%", address).replace ("%EMAILLOCALPART%", local_part (address)).replace ("%EMAILDOMAIN%", domain_of (address));
        }

        private Security security_from (string socket_type) {
            switch (socket_type.strip ().up ()) {
                case "SSL":
                case "TLS":
                    return Security.TLS;
                case "STARTTLS":
                    return Security.STARTTLS;
                default:
                    return Security.NONE;
            }
        }

        private int rank (ServerConfig s) {
            if (s.security == Security.TLS) return 3;
            if (s.security == Security.STARTTLS) return 2;
            return 0;
        }

        private class Reader {
            public MailConfig cfg = new MailConfig ();
            public ServerConfig? best_imap;
            public ServerConfig? best_smtp;
            private string address;
            private ServerConfig? current;
            private string current_kind = "";
            private string element = "";
            private bool has_password;
            private bool has_oauth;

            public Reader (string address) {
                this.address = address;
            }

            public void start (MarkupParseContext ctx, string name, string[] attr_names, string[] attr_values) throws MarkupError {
                element = name;
                if (name != "incomingServer" && name != "outgoingServer") return;
                current_kind = "";
                for (int i = 0; i < attr_names.length; i++) {
                    if (attr_names[i] == "type") current_kind = attr_values[i];
                }
                if ((name == "incomingServer" && current_kind == "imap") || (name == "outgoingServer" && current_kind == "smtp")) {
                    current = new ServerConfig ();
                    has_password = false;
                    has_oauth = false;
                } else {
                    current = null;
                }
            }

            public void end (MarkupParseContext ctx, string name) throws MarkupError {
                if ((name == "incomingServer" || name == "outgoingServer") && current != null) {
                    if (current.host != "" && current.port > 0) {
                        if (!has_password && has_oauth) cfg.oauth_only = true;
                        if (has_password || !has_oauth) {
                            if (current_kind == "imap" && (best_imap == null || rank (current) > rank (best_imap))) best_imap = current;
                            if (current_kind == "smtp" && (best_smtp == null || rank (current) > rank (best_smtp))) best_smtp = current;
                        }
                    }
                    current = null;
                }
                element = "";
            }

            public void text (MarkupParseContext ctx, string text, size_t len) throws MarkupError {
                string t = text.substring (0, (long) len).strip ();
                if (t == "") return;
                if (element == "displayName" && cfg.provider == "") cfg.provider = t;
                if (current == null) return;
                switch (element) {
                    case "hostname": current.host = expand (t, address); break;
                    case "port": current.port = (uint16) int.parse (t); break;
                    case "socketType": current.security = security_from (t); break;
                    case "username": current.username = expand (t, address); break;
                    case "authentication":
                        string a = t.down ();
                        if (a.has_prefix ("password")) has_password = true;
                        else if (a == "oauth2") has_oauth = true;
                        break;
                }
            }
        }

        public MailConfig? parse (string xml, string address) {
            var reader = new Reader (address);
            var parser = MarkupParser () {
                start_element = reader.start,
                end_element = reader.end,
                text = reader.text,
                passthrough = null,
                error = null
            };
            var ctx = new MarkupParseContext (parser, 0, reader, null);
            try {
                ctx.parse (xml, -1);
                ctx.end_parse ();
            } catch (MarkupError e) {
                return null;
            }
            var cfg = reader.cfg;
            if (reader.best_imap == null || reader.best_smtp == null) {
                if (cfg.oauth_only) return cfg;
                return null;
            }
            cfg.imap = reader.best_imap;
            cfg.smtp = reader.best_smtp;
            cfg.oauth_only = false;
            return cfg;
        }

        public MailConfig guess (string address) {
            string domain = domain_of (address);
            var cfg = new MailConfig ();
            cfg.source = "guess";
            cfg.provider = domain;
            cfg.imap.host = "imap." + domain;
            cfg.imap.port = 993;
            cfg.imap.security = Security.TLS;
            cfg.imap.username = address;
            cfg.smtp.host = "smtp." + domain;
            cfg.smtp.port = 465;
            cfg.smtp.security = Security.TLS;
            cfg.smtp.username = address;
            return cfg;
        }

        public bool needs_app_password (string address) {
            string d = domain_of (address);
            string[] known = { "gmail.com", "googlemail.com", "outlook.com", "hotmail.com", "live.com", "msn.com", "office365.com", "yahoo.com", "icloud.com", "me.com", "aol.com" };
            return d in known;
        }

        public async MailConfig? lookup (string address, Cancellable? cancel) {
            string domain = domain_of (address);
            if (domain == "") return null;
            var session = new Soup.Session ();
            session.timeout = 8;
            session.user_agent = "Lettere";
            string q = Uri.escape_string (address, null, false);
            string[] urls = {
                "https://autoconfig.%s/mail/config-v1.1.xml?emailaddress=%s".printf (domain, q),
                "https://%s/.well-known/autoconfig/mail/config-v1.1.xml?emailaddress=%s".printf (domain, q),
                "https://autoconfig.thunderbird.net/v1.1/%s".printf (domain)
            };
            foreach (string url in urls) {
                var cfg = yield fetch (session, url, address, cancel);
                if (cfg != null) {
                    cfg.source = url;
                    return cfg;
                }
                if (cancel != null && cancel.is_cancelled ()) return null;
            }
            string? mx_domain = yield mx_base (domain, cancel);
            if (mx_domain != null && mx_domain != domain) {
                var cfg = yield fetch (session, "https://autoconfig.thunderbird.net/v1.1/%s".printf (mx_domain), address, cancel);
                if (cfg != null) {
                    cfg.source = "mx:" + mx_domain;
                    return cfg;
                }
            }
            return null;
        }

        private async MailConfig? fetch (Soup.Session session, string url, string address, Cancellable? cancel) {
            try {
                var msg = new Soup.Message ("GET", url);
                if (msg == null) return null;
                var bytes = yield session.send_and_read_async (msg, Priority.DEFAULT, cancel);
                if (msg.status_code != 200) return null;
                return parse (Mime.bytes_to_string (bytes.get_data ()), address);
            } catch (Error e) {
                return null;
            }
        }

        private async string? mx_base (string domain, Cancellable? cancel) {
            try {
                var records = yield Resolver.get_default ().lookup_records_async (domain, ResolverRecordType.MX, cancel);
                uint16 best = uint16.MAX;
                string host = "";
                foreach (var r in records) {
                    uint16 pref;
                    string name;
                    r.get ("(qs)", out pref, out name);
                    if (pref < best) {
                        best = pref;
                        host = name;
                    }
                }
                if (host == "") return null;
                string[] labels = host.down ().split (".");
                if (labels.length < 2) return null;
                return labels[labels.length - 2] + "." + labels[labels.length - 1];
            } catch (Error e) {
                return null;
            }
        }
    }
}
