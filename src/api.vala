namespace Singularity.Apps.Lettere {

    public class HttpReply {
        public Bytes body;
        public uint status;

        public HttpReply (Bytes body, uint status) {
            this.body = body;
            this.status = status;
        }
    }

    public class ApiClient : Object {
        public Soup.Session session;
        private unowned AccountSync owner;
        private MailLogin? login;
        public bool ntlm;

        public ApiClient (AccountSync owner, bool ntlm = false) {
            this.owner = owner;
            this.ntlm = ntlm;
            session = new Soup.Session ();
            session.timeout = 60;
            session.user_agent = "Lettere/1.0 (Singularity)";
            if (ntlm) session.add_feature_by_type (typeof (Soup.AuthNTLM));
        }

        public async void sign_in (bool refresh = false) throws Error {
            login = yield owner.current_login (refresh);
        }

        public MailLogin? current {
            get { return login; }
        }

        private void authorize (Soup.Message msg) {
            if (login == null) return;
            if (login.is_token || owner.account.auth_mechanism == "bearer") {
                msg.request_headers.replace ("Authorization", "Bearer " + login.secret);
            } else if (!ntlm) {
                string raw = login.user + ":" + login.secret;
                msg.request_headers.replace ("Authorization", "Basic " + Base64.encode (raw.data));
            } else {
                string user = login.user;
                string secret = login.secret;
                msg.authenticate.connect ((auth, retrying) => {
                    if (retrying) return false;
                    auth.authenticate (user, secret);
                    return false;
                });
            }
        }

        private void check_graph_url (string url) throws Error {
            Uri endpoint;
            Uri request;
            try {
                endpoint = Uri.parse (owner.account.api_url != "" ? owner.account.api_url : "https://graph.microsoft.com/v1.0/", UriFlags.NONE);
                request = Uri.parse (url, UriFlags.NONE);
            } catch (UriError e) {
                throw new MailError.PROTOCOL (_("Invalid Microsoft Graph address"));
            }
            string scheme = endpoint.get_scheme ();
            string? host = endpoint.get_host ();
            bool loopback = host == "127.0.0.1" || host == "::1";
            string path = endpoint.get_path ();
            if (!path.has_suffix ("/")) path += "/";
            int endpoint_port = endpoint.get_port ();
            int request_port = request.get_port ();
            if (endpoint_port < 0) endpoint_port = scheme == "https" ? 443 : 80;
            if (request_port < 0) request_port = request.get_scheme () == "https" ? 443 : 80;
            if (host == null || scheme != "https" && !(scheme == "http" && loopback)
                || endpoint.get_userinfo () != null || endpoint.get_fragment () != null || endpoint.get_query () != null
                || request.get_scheme () != scheme || request.get_host () == null
                || request.get_host ().ascii_down () != host.ascii_down () || request_port != endpoint_port
                || request.get_userinfo () != null || request.get_fragment () != null
                || !request.get_path ().has_prefix (path) || request.get_path ().contains ("\\")) {
                throw new MailError.PROTOCOL (_("The Microsoft Graph address is outside the account endpoint"));
            }
            foreach (string part in request.get_path ().split ("/")) {
                if (part == "." || part == "..") throw new MailError.PROTOCOL (_("Invalid Microsoft Graph path"));
            }
        }

        private async HttpReply request (string method, string url, string? content_type, Bytes? body, Gee.Map<string, string>? headers) throws Error {
            bool graph = owner.account.protocol == "graph";
            string next = url;
            for (int redirects = 0; ; redirects++) {
                if (graph) check_graph_url (next);
                var msg = new Soup.Message (method, next);
                if (msg == null) throw new MailError.PROTOCOL (_("Invalid address: %s").printf (next));
                if (graph) msg.add_flags (Soup.MessageFlags.NO_REDIRECT);
                authorize (msg);
                if (headers != null) foreach (var e in headers.entries) msg.request_headers.replace (e.key, e.value);
                if (body != null) msg.set_request_body_from_bytes (content_type ?? "application/octet-stream", body);
                Bytes reply;
                try {
                    reply = yield session.send_and_read_async (msg, Priority.DEFAULT, null);
                } catch (Error e) {
                    if (e is TlsError) throw new MailError.TLS (e.message);
                    throw new MailError.OFFLINE (_("Could not reach %s: %s").printf (msg.uri.get_host () ?? next, e.message));
                }
                uint status = msg.status_code;
                if (!graph || status != 301 && status != 302 && status != 303 && status != 307 && status != 308) {
                    return new HttpReply (reply, status);
                }
                string? location = msg.response_headers.get_one ("Location");
                if (redirects == 5 || location == null || location == "" || method != "GET" && method != "HEAD" && status != 307 && status != 308) {
                    throw new MailError.PROTOCOL (_("The Microsoft Graph redirect could not be followed safely"));
                }
                try {
                    next = Uri.resolve_relative (next, location, UriFlags.ENCODED);
                } catch (UriError e) {
                    throw new MailError.PROTOCOL (_("Invalid Microsoft Graph redirect"));
                }
            }
        }

        public async HttpReply send (string method, string url, string? content_type, Bytes? body, Gee.Map<string, string>? headers = null) throws Error {
            if (owner.account.protocol == "graph") check_graph_url (url);
            if (login == null) yield sign_in ();
            for (int attempt = 0; attempt < 2; attempt++) {
                var reply = yield request (method, url, content_type, body, headers);
                uint status = reply.status;
                if (status == 401 && attempt == 0) {
                    yield sign_in (true);
                    continue;
                }
                if (status == 401 || status == 403 && (Mime.bytes_to_string (reply.body.get_data ()).contains ("InvalidAuthenticationToken"))) {
                    owner.login_refused (new MailError.AUTH (_("The server refused the sign-in (HTTP %u)").printf (status)));
                }
                return reply;
            }
            throw new MailError.AUTH (_("The server refused the sign-in"));
        }

        public static string error_text (Bytes reply, uint status) {
            string body = Mime.bytes_to_string (reply.get_data ());
            try {
                var p = new Json.Parser ();
                p.load_from_data (body);
                var root = p.get_root ();
                if (root != null && root.get_node_type () == Json.NodeType.OBJECT) {
                    var o = root.get_object ();
                    if (o.has_member ("error")) {
                        var err = o.get_member ("error");
                        if (err.get_node_type () == Json.NodeType.OBJECT && err.get_object ().has_member ("message")) return err.get_object ().get_string_member ("message");
                        if (err.get_node_type () == Json.NodeType.VALUE) return err.get_string ();
                    }
                    if (o.has_member ("detail")) return o.get_string_member ("detail");
                }
            } catch (Error e) {
            }
            return "HTTP %u".printf (status);
        }

        public async Json.Node? json (string method, string url, Json.Node? body = null, Gee.Map<string, string>? headers = null) throws Error {
            Bytes? data = null;
            if (body != null) {
                var g = new Json.Generator ();
                g.set_root (body);
                data = new Bytes (g.to_data (null).data);
            }
            var r = yield send (method, url, "application/json", data, headers);
            var reply = r.body;
            uint status = r.status;
            if (status == 404) throw new MailError.SERVER (_("Not found: %s").printf (error_text (reply, status)));
            if (status >= 400) throw new MailError.SERVER (error_text (reply, status));
            if (reply.get_size () == 0) return null;
            var p = new Json.Parser ();
            p.load_from_data (Mime.bytes_to_string (reply.get_data ()));
            return p.get_root ();
        }

        public async Bytes raw (string method, string url, string? content_type = null, Bytes? body = null, Gee.Map<string, string>? headers = null) throws Error {
            var r = yield send (method, url, content_type, body, headers);
            var reply = r.body;
            uint status = r.status;
            if (status >= 400) throw new MailError.SERVER (error_text (reply, status));
            return reply;
        }
    }

    namespace Js {
        public string str (Json.Object? o, string key, string fallback = "") {
            if (o == null || !o.has_member (key)) return fallback;
            var n = o.get_member (key);
            if (n.get_node_type () != Json.NodeType.VALUE) return fallback;
            if (n.get_value_type () == typeof (string)) return n.get_string () ?? fallback;
            if (n.get_value_type () == typeof (int64)) return n.get_int ().to_string ();
            if (n.get_value_type () == typeof (bool)) return n.get_boolean () ? "true" : "false";
            return fallback;
        }

        public int64 num (Json.Object? o, string key, int64 fallback = 0) {
            if (o == null || !o.has_member (key)) return fallback;
            var n = o.get_member (key);
            if (n.get_node_type () != Json.NodeType.VALUE) return fallback;
            if (n.get_value_type () == typeof (int64)) return n.get_int ();
            if (n.get_value_type () == typeof (double)) return (int64) n.get_double ();
            if (n.get_value_type () == typeof (string)) return int64.parse (n.get_string ());
            return fallback;
        }

        public bool flag (Json.Object? o, string key) {
            if (o == null || !o.has_member (key)) return false;
            var n = o.get_member (key);
            return n.get_node_type () == Json.NodeType.VALUE && n.get_value_type () == typeof (bool) && n.get_boolean ();
        }

        public Json.Object? obj (Json.Object? o, string key) {
            if (o == null || !o.has_member (key)) return null;
            var n = o.get_member (key);
            return n.get_node_type () == Json.NodeType.OBJECT ? n.get_object () : null;
        }

        public Json.Array? arr (Json.Object? o, string key) {
            if (o == null || !o.has_member (key)) return null;
            var n = o.get_member (key);
            return n.get_node_type () == Json.NodeType.ARRAY ? n.get_array () : null;
        }

        public Json.Node parse (string text) throws Error {
            var p = new Json.Parser ();
            p.load_from_data (text);
            return p.get_root ();
        }

        public int64 iso_time (string v) {
            if (v == "") return 0;
            var d = new DateTime.from_iso8601 (v, new TimeZone.utc ());
            return d != null ? d.to_unix () : 0;
        }

        public string iso (int64 t) {
            return new DateTime.from_unix_utc (t).format ("%Y-%m-%dT%H:%M:%SZ");
        }

        public string b64url (uint8[] data) {
            return Base64.encode (data).replace ("+", "-").replace ("/", "_").replace ("=", "");
        }

        public uint8[] from_b64url (string s) {
            string t = s.replace ("-", "+").replace ("_", "/");
            while (t.length % 4 != 0) t += "=";
            return Base64.decode (t);
        }
    }

    public class XmlNode {
        public string name = "";
        public Gee.HashMap<string, string> attrs = new Gee.HashMap<string, string> ();
        public Gee.ArrayList<XmlNode> children = new Gee.ArrayList<XmlNode> ();
        public StringBuilder text = new StringBuilder ();

        public XmlNode? child (string n) {
            foreach (var c in children) if (c.name == n) return c;
            return null;
        }

        public Gee.ArrayList<XmlNode> all (string n) {
            var list = new Gee.ArrayList<XmlNode> ();
            foreach (var c in children) if (c.name == n) list.add (c);
            return list;
        }

        public void find_all (string n, Gee.List<XmlNode> into) {
            foreach (var c in children) {
                if (c.name == n) into.add (c);
                c.find_all (n, into);
            }
        }

        public XmlNode? find (string n) {
            foreach (var c in children) {
                if (c.name == n) return c;
                var d = c.find (n);
                if (d != null) return d;
            }
            return null;
        }

        public string value (string n) {
            var c = child (n);
            return c != null ? c.text.str.strip () : "";
        }

        public string attr (string n) {
            return attrs[n] ?? "";
        }

        private static string local (string n) {
            int c = n.index_of_char (':');
            return c >= 0 ? n.substring (c + 1) : n;
        }

        private class Builder {
            public XmlNode root = new XmlNode ();
            public Gee.ArrayList<XmlNode> stack = new Gee.ArrayList<XmlNode> ();

            public Builder () {
                stack.add (root);
            }

            public void start (MarkupParseContext ctx, string name, string[] attr_names, string[] attr_values) throws MarkupError {
                var n = new XmlNode ();
                n.name = local (name);
                for (int i = 0; i < attr_names.length; i++) n.attrs[local (attr_names[i])] = attr_values[i];
                stack[stack.size - 1].children.add (n);
                stack.add (n);
            }

            public void end (MarkupParseContext ctx, string name) throws MarkupError {
                if (stack.size > 1) stack.remove_at (stack.size - 1);
            }

            public void text (MarkupParseContext ctx, string text, size_t len) throws MarkupError {
                stack[stack.size - 1].text.append (text.substring (0, (long) len));
            }
        }

        public static XmlNode parse (string xml) throws Error {
            var builder = new Builder ();
            var parser = MarkupParser () {
                start_element = builder.start,
                end_element = builder.end,
                text = builder.text,
                passthrough = null,
                error = null
            };
            string body = xml.strip ();
            if (body.has_prefix ("<?xml")) {
                int end = body.index_of ("?>");
                if (end > 0) body = body.substring (end + 2);
            }
            var ctx = new MarkupParseContext (parser, MarkupParseFlags.TREAT_CDATA_AS_TEXT, builder, null);
            ctx.parse (body, -1);
            ctx.end_parse ();
            return builder.root;
        }

        public static string esc (string s) {
            return Markup.escape_text (s);
        }
    }
}
