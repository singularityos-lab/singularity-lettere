namespace Singularity.Apps.Lettere {

    public class Address : Object {
        public string name { get; set; default = ""; }
        public string email { get; set; default = ""; }

        public Address (string name, string email) {
            this.name = name;
            this.email = email;
        }

        public string display () {
            return name != "" ? name : email;
        }

        public string to_header () {
            if (name == "") return email;
            return "%s <%s>".printf (Mime.encode_phrase (name), email);
        }

        public string to_string () {
            if (name == "") return email;
            return "%s <%s>".printf (name, email);
        }
    }

    public class HeaderField {
        public string name;
        public string value;

        public HeaderField (string name, string value) {
            this.name = name;
            this.value = value;
        }
    }

    public class MimePart : Object {
        public Gee.ArrayList<HeaderField> headers = new Gee.ArrayList<HeaderField> ();
        public string content_type = "text/plain";
        public Gee.HashMap<string, string> type_params = new Gee.HashMap<string, string> ();
        public string disposition = "";
        public Gee.HashMap<string, string> disposition_params = new Gee.HashMap<string, string> ();
        public Gee.ArrayList<MimePart> children = new Gee.ArrayList<MimePart> ();
        public uint8[] raw_body = {};
        public string path = "";

        public string? header (string name) {
            string key = name.down ();
            foreach (var h in headers) {
                if (h.name.down () == key) return h.value;
            }
            return null;
        }

        public string decoded_header (string name) {
            var v = header (name);
            return v == null ? "" : Mime.decode_words (v).strip ();
        }

        public bool is_multipart {
            get { return content_type.has_prefix ("multipart/"); }
        }

        public string charset {
            owned get { return type_params.has_key ("charset") ? type_params["charset"] : ""; }
        }

        public string filename {
            owned get {
                string f = "";
                if (disposition_params.has_key ("filename")) f = disposition_params["filename"];
                else if (type_params.has_key ("name")) f = type_params["name"];
                return Mime.decode_words (f).replace ("/", "_").replace ("\\", "_").strip ();
            }
        }

        public string content_id {
            owned get {
                var v = header ("Content-ID");
                if (v == null) return "";
                return v.strip ().replace ("<", "").replace (">", "");
            }
        }

        public string transfer_encoding {
            owned get {
                var v = header ("Content-Transfer-Encoding");
                return v == null ? "" : v.strip ().down ();
            }
        }

        public uint8[] decoded () {
            switch (transfer_encoding) {
                case "base64":
                    return Mime.decode_base64 (raw_body);
                case "quoted-printable":
                    return Mime.decode_qp (raw_body);
                default:
                    return raw_body;
            }
        }

        public string text () {
            return Mime.to_utf8 (decoded (), charset);
        }

        public bool is_attachment {
            get {
                if (is_multipart) return false;
                if (disposition == "attachment") return true;
                if (content_type == "message/rfc822") return true;
                if (content_type.has_prefix ("text/") && filename == "") return false;
                if (content_type == "text/plain" || content_type == "text/html") return disposition != "" && filename != "";
                return true;
            }
        }

        public void walk (Gee.List<MimePart> into) {
            into.add (this);
            foreach (var c in children) c.walk (into);
        }
    }

    public class Attachment : Object {
        public string filename { get; set; }
        public string content_type { get; set; }
        public string content_id { get; set; default = ""; }
        public bool inline { get; set; }
        public Bytes data { get; set; }

        public Attachment (string filename, string content_type, Bytes data) {
            this.filename = filename;
            this.content_type = content_type;
            this.data = data;
        }
    }

    public class MimeMessage : Object {
        public MimePart root;
        public string text_plain = "";
        public string text_html = "";
        public Gee.ArrayList<Attachment> attachments = new Gee.ArrayList<Attachment> ();
        public Gee.HashMap<string, Attachment> inline_parts = new Gee.HashMap<string, Attachment> ();

        public MimeMessage (uint8[] data) {
            root = Mime.parse_part (data, "1", 0);
            collect (root, false);
        }

        public MimeMessage.from_bytes (Bytes data) {
            this (data.get_data ());
        }

        private void collect (MimePart part, bool in_alternative) {
            if (part.is_multipart) {
                bool alt = part.content_type == "multipart/alternative";
                foreach (var c in part.children) collect (c, alt || in_alternative);
                return;
            }
            if (!part.is_attachment && part.content_type != "text/calendar" && part.content_type != "text/x-vcard" && part.content_type != "text/vcard") {
                if (part.content_type == "text/html") {
                    if (text_html == "") text_html = part.text ();
                    else if (!in_alternative) text_html += "<hr>" + part.text ();
                    return;
                }
                if (part.content_type == "text/plain" || part.content_type.has_prefix ("text/")) {
                    if (text_plain == "") text_plain = part.text ();
                    else if (!in_alternative) text_plain += "\n\n" + part.text ();
                    return;
                }
            }
            string name = part.filename;
            if (name == "") {
                if (part.content_type == "text/calendar") name = "invite.ics";
                else if (part.content_type == "message/rfc822") name = part.decoded_header ("Subject") + ".eml";
                else name = _("Attachment");
                if (name == ".eml") name = "message.eml";
            }
            var a = new Attachment (name, part.content_type, new Bytes (part.decoded ()));
            a.content_id = part.content_id;
            a.inline = part.disposition == "inline" || (part.disposition == "" && a.content_id != "");
            if (a.content_id != "") inline_parts[a.content_id] = a;
            if (!(a.inline && a.content_id != "" && part.content_type.has_prefix ("image/"))) attachments.add (a);
        }

        public string subject { owned get { return root.decoded_header ("Subject"); } }
        public string message_id { owned get { return Mime.first_id (root.header ("Message-ID") ?? ""); } }
        public string in_reply_to { owned get { return Mime.first_id (root.header ("In-Reply-To") ?? ""); } }
        public string references { owned get { return string.joinv (" ", Mime.parse_ids (root.header ("References") ?? "")); } }

        public Gee.List<Address> from { owned get { return Mime.parse_addresses (root.header ("From") ?? ""); } }
        public Gee.List<Address> to { owned get { return Mime.parse_addresses (root.header ("To") ?? ""); } }
        public Gee.List<Address> cc { owned get { return Mime.parse_addresses (root.header ("Cc") ?? ""); } }
        public Gee.List<Address> reply_to { owned get { return Mime.parse_addresses (root.header ("Reply-To") ?? ""); } }

        public DateTime? date { owned get { return Mime.parse_date (root.header ("Date") ?? ""); } }

        public string body_text () {
            if (text_plain.strip () != "") return text_plain;
            if (text_html != "") return Html.to_text (text_html);
            return "";
        }

        public bool has_remote_content () {
            return text_html != "" && Html.has_remote (text_html);
        }
    }

    namespace Mime {

        public string latin1_to_utf8 (uint8[] data) {
            var sb = new StringBuilder.sized (data.length + 16);
            foreach (uint8 b in data) sb.append_unichar ((unichar) b);
            return sb.str;
        }

        public string bytes_to_string (uint8[] data) {
            var sb = new StringBuilder.sized (data.length + 1);
            sb.append_len ((string) data, data.length);
            string s = sb.str;
            if (s.validate ()) return s;
            return latin1_to_utf8 (data);
        }

        public string normalize_charset (string cs) {
            string c = cs.strip ().down ().replace ("\"", "");
            switch (c) {
                case "":
                case "us-ascii":
                case "ascii":
                case "utf8":
                case "unicode-1-1-utf-8":
                    return "utf-8";
                case "iso-8859-1":
                case "latin1":
                case "iso8859-1":
                case "iso_8859-1":
                    return "windows-1252";
                case "ks_c_5601-1987":
                    return "cp949";
                case "gb2312":
                    return "gb18030";
                case "x-sjis":
                    return "shift_jis";
            }
            return c;
        }

        public string to_utf8 (uint8[] data, string charset) {
            string cs = normalize_charset (charset);
            if (cs == "utf-8") {
                var sb = new StringBuilder.sized (data.length + 1);
                sb.append_len ((string) data, data.length);
                string s = sb.str;
                if (s.validate ()) return s;
                return s.make_valid ();
            }
            try {
                size_t read, written;
                var sb = new StringBuilder.sized (data.length + 1);
                sb.append_len ((string) data, data.length);
                string converted = GLib.convert (sb.str, data.length, "UTF-8", cs, out read, out written);
                if (converted.validate ()) return converted;
            } catch (ConvertError e) {
            }
            return bytes_to_string (data);
        }

        private int hexval (uint8 c) {
            if (c >= '0' && c <= '9') return c - '0';
            if (c >= 'A' && c <= 'F') return c - 'A' + 10;
            if (c >= 'a' && c <= 'f') return c - 'a' + 10;
            return -1;
        }

        public uint8[] decode_qp (uint8[] data, bool header_mode = false) {
            var out_buf = new ByteArray.sized ((uint) data.length);
            int n = data.length;
            int i = 0;
            while (i < n) {
                uint8 c = data[i];
                if (c == '=') {
                    if (i + 2 < n && hexval (data[i + 1]) >= 0 && hexval (data[i + 2]) >= 0) {
                        uint8 v = (uint8) (hexval (data[i + 1]) * 16 + hexval (data[i + 2]));
                        out_buf.append ({ v });
                        i += 3;
                        continue;
                    }
                    int j = i + 1;
                    while (j < n && (data[j] == ' ' || data[j] == '\t')) j++;
                    if (j < n && data[j] == '\r') j++;
                    if (j < n && data[j] == '\n') {
                        i = j + 1;
                        continue;
                    }
                    if (j >= n) {
                        i = n;
                        continue;
                    }
                    out_buf.append ({ c });
                    i++;
                    continue;
                }
                if (header_mode && c == '_') {
                    out_buf.append ({ ' ' });
                    i++;
                    continue;
                }
                out_buf.append ({ c });
                i++;
            }
            return out_buf.steal ();
        }

        public uint8[] decode_base64 (uint8[] data) {
            var sb = new StringBuilder.sized (data.length + 4);
            foreach (uint8 c in data) {
                if ((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '+' || c == '/') sb.append_c ((char) c);
            }
            while (sb.len % 4 != 0) sb.append_c ('=');
            if (sb.len == 0) return {};
            return Base64.decode (sb.str);
        }

        public string encode_base64_lines (uint8[] data, int width = 76) {
            string b = Base64.encode (data);
            var sb = new StringBuilder.sized (b.length + b.length / width * 2 + 4);
            for (int i = 0; i < b.length; i += width) {
                sb.append (b.substring (i, int.min (width, b.length - i)));
                sb.append ("\r\n");
            }
            return sb.str;
        }

        public string encode_qp (string text) {
            var sb = new StringBuilder ();
            string norm = text.replace ("\r\n", "\n").replace ("\r", "\n");
            string[] lines = norm.split ("\n");
            for (int li = 0; li < lines.length; li++) {
                unowned string line = lines[li];
                uint8[] bytes = line.data;
                int col = 0;
                for (int i = 0; i < bytes.length; i++) {
                    uint8 c = bytes[i];
                    string piece;
                    bool last = i == bytes.length - 1;
                    if ((c >= 33 && c <= 126 && c != '=') || ((c == ' ' || c == '\t') && !last)) {
                        piece = ((char) c).to_string ();
                    } else {
                        piece = "=%02X".printf (c);
                    }
                    if (col + piece.length > 75) {
                        sb.append ("=\r\n");
                        col = 0;
                    }
                    sb.append (piece);
                    col += piece.length;
                }
                if (li < lines.length - 1) sb.append ("\r\n");
            }
            return sb.str;
        }

        private bool is_ascii (string s) {
            for (int i = 0; i < s.length; i++) {
                if ((uint8) s[i] > 127) return false;
            }
            return true;
        }

        public string encode_words (string text) {
            if (is_ascii (text) && !text.contains ("=?")) return text;
            var sb = new StringBuilder ();
            var chunk = new StringBuilder ();
            unichar ch;
            int idx = 0;
            while (text.get_next_char (ref idx, out ch)) {
                string s = ch.to_string ();
                if (chunk.len + s.length > 45) {
                    if (sb.len > 0) sb.append ("\r\n ");
                    sb.append ("=?UTF-8?B?" + Base64.encode (chunk.str.data) + "?=");
                    chunk.truncate (0);
                }
                chunk.append (s);
            }
            if (chunk.len > 0) {
                if (sb.len > 0) sb.append ("\r\n ");
                sb.append ("=?UTF-8?B?" + Base64.encode (chunk.str.data) + "?=");
            }
            return sb.str;
        }

        public string encode_phrase (string name) {
            if (!is_ascii (name)) return encode_words (name);
            bool special = false;
            for (int i = 0; i < name.length; i++) {
                if ("()<>[]:;@\\,.\"".index_of_char (name[i]) >= 0) {
                    special = true;
                    break;
                }
            }
            if (!special) return name;
            return "\"" + name.replace ("\\", "\\\\").replace ("\"", "\\\"") + "\"";
        }

        public string decode_words (string input) {
            if (!input.contains ("=?")) {
                return unfold (input);
            }
            string s = unfold (input);
            var sb = new StringBuilder ();
            int pos = 0;
            int flushed = 0;
            int len = s.length;
            string pending_charset = "";
            var pending = new ByteArray ();
            int last_end = -1;
            while (pos < len) {
                int start = s.index_of ("=?", pos);
                if (start < 0) break;
                int q1 = s.index_of_char ('?', start + 2);
                if (q1 < 0) break;
                if (q1 + 2 >= len || s[q1 + 2] != '?') {
                    pos = start + 2;
                    continue;
                }
                char enc = s[q1 + 1].toupper ();
                if (enc != 'B' && enc != 'Q') {
                    pos = start + 2;
                    continue;
                }
                int end = s.index_of ("?=", q1 + 3);
                if (end < 0) break;
                string charset = s.substring (start + 2, q1 - start - 2);
                int star = charset.index_of_char ('*');
                if (star >= 0) charset = charset.substring (0, star);
                string payload = s.substring (q1 + 3, end - q1 - 3);
                string between = s.substring (flushed, start - flushed);
                bool adjacent = last_end >= 0 && last_end == flushed && between.strip () == "";
                if (!adjacent || normalize_charset (charset) != normalize_charset (pending_charset)) {
                    if (pending.len > 0) {
                        sb.append (to_utf8 (pending.data, pending_charset));
                        pending.set_size (0);
                    }
                    if (!adjacent) sb.append (between);
                }
                pending_charset = charset;
                if (enc == 'B') pending.append (decode_base64 (payload.data));
                else pending.append (decode_qp (payload.data, true));
                pos = end + 2;
                flushed = pos;
                last_end = pos;
            }
            if (pending.len > 0) sb.append (to_utf8 (pending.data, pending_charset));
            if (flushed < len) sb.append (s.substring (flushed));
            return sb.str;
        }

        public string unfold (string v) {
            if (!v.contains ("\n")) return v;
            var sb = new StringBuilder ();
            string[] lines = v.replace ("\r\n", "\n").split ("\n");
            for (int i = 0; i < lines.length; i++) {
                string l = lines[i];
                if (i > 0) {
                    l = l.chug ();
                    sb.append_c (' ');
                }
                sb.append (l);
            }
            return sb.str;
        }

        private int find_bytes (uint8[] hay, uint8[] needle, int from) {
            int n = hay.length - needle.length;
            for (int i = from; i <= n; i++) {
                bool ok = true;
                for (int j = 0; j < needle.length; j++) {
                    if (hay[i + j] != needle[j]) {
                        ok = false;
                        break;
                    }
                }
                if (ok) return i;
            }
            return -1;
        }

        private int header_end (uint8[] data, out int body_start) {
            int n = data.length;
            if (n > 0 && (data[0] == '\n' || (n > 1 && data[0] == '\r' && data[1] == '\n'))) {
                body_start = data[0] == '\n' ? 1 : 2;
                return 0;
            }
            for (int i = 0; i < n; i++) {
                if (data[i] != '\n') continue;
                if (i + 1 < n && data[i + 1] == '\n') {
                    body_start = i + 2;
                    return i + 1;
                }
                if (i + 2 < n && data[i + 1] == '\r' && data[i + 2] == '\n') {
                    body_start = i + 3;
                    return i + 1;
                }
            }
            body_start = n;
            return n;
        }

        public Gee.ArrayList<HeaderField> parse_headers (string block) {
            var list = new Gee.ArrayList<HeaderField> ();
            string[] lines = block.replace ("\r\n", "\n").split ("\n");
            HeaderField? current = null;
            foreach (string line in lines) {
                if (line == "") continue;
                if ((line[0] == ' ' || line[0] == '\t') && current != null) {
                    current.value += "\n" + line;
                    continue;
                }
                int colon = line.index_of_char (':');
                if (colon <= 0) continue;
                current = new HeaderField (line.substring (0, colon).strip (), line.substring (colon + 1).chug ());
                list.add (current);
            }
            return list;
        }

        public void parse_params (string value, out string main, Gee.HashMap<string, string> params) {
            var parts = split_unquoted (value, ';');
            main = parts.size > 0 ? unfold (parts[0]).strip ().down () : "";
            var continued = new Gee.TreeMap<string, string> ();
            var encoded_names = new Gee.HashSet<string> ();
            for (int i = 1; i < parts.size; i++) {
                string p = unfold (parts[i]).strip ();
                int eq = p.index_of_char ('=');
                if (eq <= 0) continue;
                string key = p.substring (0, eq).strip ().down ();
                string val = p.substring (eq + 1).strip ();
                if (val.length >= 2 && val[0] == '"' && val[val.length - 1] == '"') {
                    val = val.substring (1, val.length - 2).replace ("\\\"", "\"").replace ("\\\\", "\\");
                }
                int star = key.index_of_char ('*');
                if (star < 0) {
                    params[key] = val;
                    continue;
                }
                string base_name = key.substring (0, star);
                string rest = key.substring (star + 1);
                bool enc = key.has_suffix ("*");
                if (rest == "") {
                    params[base_name] = decode_2231 (val, true);
                    encoded_names.add (base_name);
                    continue;
                }
                string idx = rest.replace ("*", "");
                int num = int.parse (idx);
                continued["%s\x01%05d".printf (base_name, num)] = (enc ? "E" : "P") + val;
            }
            var charsets = new Gee.HashMap<string, string> ();
            var raw = new Gee.HashMap<string, ByteArray> ();
            foreach (var e in continued.entries) {
                string name = e.key.split ("\x01")[0];
                bool enc = e.value[0] == 'E';
                string v = e.value.substring (1);
                if (!raw.has_key (name)) {
                    raw[name] = new ByteArray ();
                    charsets[name] = "";
                    if (enc) {
                        int a = v.index_of_char ('\'');
                        int b = a >= 0 ? v.index_of_char ('\'', a + 1) : -1;
                        if (a >= 0 && b > a) {
                            charsets[name] = v.substring (0, a);
                            v = v.substring (b + 1);
                        }
                    }
                }
                if (enc) raw[name].append (percent_decode (v));
                else raw[name].append (v.data);
            }
            foreach (var e in raw.entries) {
                params[e.key] = to_utf8 (e.value.data, charsets[e.key]);
            }
        }

        private uint8[] percent_decode (string v) {
            var b = new ByteArray ();
            uint8[] d = v.data;
            for (int i = 0; i < d.length; i++) {
                if (d[i] == '%' && i + 2 < d.length && hexval (d[i + 1]) >= 0 && hexval (d[i + 2]) >= 0) {
                    b.append ({ (uint8) (hexval (d[i + 1]) * 16 + hexval (d[i + 2])) });
                    i += 2;
                } else {
                    b.append ({ d[i] });
                }
            }
            return b.steal ();
        }

        private string decode_2231 (string v, bool with_charset) {
            string cs = "";
            string rest = v;
            if (with_charset) {
                int a = v.index_of_char ('\'');
                int b = a >= 0 ? v.index_of_char ('\'', a + 1) : -1;
                if (a >= 0 && b > a) {
                    cs = v.substring (0, a);
                    rest = v.substring (b + 1);
                }
            }
            return to_utf8 (percent_decode (rest), cs);
        }

        public Gee.ArrayList<string> split_unquoted (string s, char sep) {
            var list = new Gee.ArrayList<string> ();
            var cur = new StringBuilder ();
            bool quoted = false;
            int depth = 0;
            int angle = 0;
            for (int i = 0; i < s.length; i++) {
                char c = s[i];
                if (c == '\\' && quoted && i + 1 < s.length) {
                    cur.append_c (c);
                    cur.append_c (s[++i]);
                    continue;
                }
                if (c == '"') quoted = !quoted;
                else if (!quoted && c == '(') depth++;
                else if (!quoted && c == ')' && depth > 0) depth--;
                else if (!quoted && c == '<') angle++;
                else if (!quoted && c == '>' && angle > 0) angle--;
                if (c == sep && !quoted && depth == 0 && angle == 0) {
                    list.add (cur.str);
                    cur.truncate (0);
                    continue;
                }
                cur.append_c (c);
            }
            list.add (cur.str);
            return list;
        }

        public MimePart parse_part (uint8[] data, string path, int depth) {
            var part = new MimePart ();
            part.path = path;
            int body_start;
            int hend = header_end (data, out body_start);
            part.headers = parse_headers (bytes_to_string (data[0:hend]));
            part.raw_body = data[body_start:data.length];
            string ctype_main;
            var ct = part.header ("Content-Type");
            if (ct != null) {
                parse_params (ct, out ctype_main, part.type_params);
                if (ctype_main == "" || !ctype_main.contains ("/")) ctype_main = "text/plain";
                part.content_type = ctype_main;
            }
            var cd = part.header ("Content-Disposition");
            if (cd != null) {
                string disp;
                parse_params (cd, out disp, part.disposition_params);
                part.disposition = disp;
            }
            if (part.is_multipart && depth < 20 && part.type_params.has_key ("boundary")) {
                split_multipart (part, depth);
            } else if (part.is_multipart) {
                part.content_type = "text/plain";
            }
            return part;
        }

        private void split_multipart (MimePart part, int depth) {
            uint8[] body = part.raw_body;
            uint8[] delim = ("--" + part.type_params["boundary"]).data;
            var starts = new Gee.ArrayList<int> ();
            var ends = new Gee.ArrayList<int> ();
            int pos = 0;
            int content_start = -1;
            while (true) {
                int at = find_bytes (body, delim, pos);
                if (at < 0) break;
                if (at > 0 && body[at - 1] != '\n') {
                    pos = at + 1;
                    continue;
                }
                int after = at + delim.length;
                bool closing = after + 1 < body.length && body[after] == '-' && body[after + 1] == '-';
                if (content_start >= 0) {
                    int e = at;
                    if (e > 0 && body[e - 1] == '\n') e--;
                    if (e > 0 && body[e - 1] == '\r') e--;
                    if (e < content_start) e = content_start;
                    starts.add (content_start);
                    ends.add (e);
                }
                if (closing) {
                    content_start = -1;
                    break;
                }
                int eol = after;
                while (eol < body.length && body[eol] != '\n') eol++;
                content_start = eol < body.length ? eol + 1 : body.length;
                pos = content_start;
            }
            if (content_start >= 0 && content_start < body.length) {
                starts.add (content_start);
                ends.add (body.length);
            }
            for (int i = 0; i < starts.size; i++) {
                var child = parse_part (body[starts[i]:ends[i]], "%s.%d".printf (part.path, i + 1), depth + 1);
                if (part.content_type == "multipart/digest" && part.header ("Content-Type") != null && child.header ("Content-Type") == null) {
                    child.content_type = "message/rfc822";
                }
                part.children.add (child);
            }
        }

        public string first_id (string v) {
            var ids = parse_ids (v);
            return ids.length > 0 ? ids[0] : "";
        }

        public string[] parse_ids (string v) {
            string[] ids = {};
            int pos = 0;
            while (true) {
                int a = v.index_of_char ('<', pos);
                if (a < 0) break;
                int b = v.index_of_char ('>', a);
                if (b < 0) break;
                string id = v.substring (a + 1, b - a - 1).strip ();
                if (id != "" && !(id in ids)) ids += id;
                pos = b + 1;
            }
            if (ids.length == 0) {
                string t = unfold (v).strip ();
                if (t != "" && !t.contains (" ") && t.contains ("@")) ids += t;
            }
            return ids;
        }

        private string strip_comments (string s) {
            var sb = new StringBuilder ();
            int depth = 0;
            bool quoted = false;
            for (int i = 0; i < s.length; i++) {
                char c = s[i];
                if (c == '\\' && i + 1 < s.length) {
                    if (depth == 0) {
                        sb.append_c (c);
                        sb.append_c (s[i + 1]);
                    }
                    i++;
                    continue;
                }
                if (c == '"' && depth == 0) quoted = !quoted;
                if (!quoted && c == '(') {
                    depth++;
                    continue;
                }
                if (!quoted && c == ')' && depth > 0) {
                    depth--;
                    continue;
                }
                if (depth == 0) sb.append_c (c);
            }
            return sb.str;
        }

        private string unquote (string s) {
            string t = s.strip ();
            if (t.length >= 2 && t[0] == '"' && t[t.length - 1] == '"') {
                t = t.substring (1, t.length - 2).replace ("\\\"", "\"").replace ("\\\\", "\\");
            }
            return t;
        }

        public Gee.ArrayList<Address> parse_addresses (string header) {
            var list = new Gee.ArrayList<Address> ();
            string s = unfold (header);
            foreach (string item in split_unquoted (s, ',')) {
                string t = item.strip ();
                if (t == "") continue;
                int colon = -1;
                bool quoted = false;
                for (int i = 0; i < t.length; i++) {
                    if (t[i] == '"') quoted = !quoted;
                    if (!quoted && t[i] == '<') break;
                    if (!quoted && t[i] == ':') {
                        colon = i;
                        break;
                    }
                }
                if (colon >= 0) t = t.substring (colon + 1).strip ();
                if (t.has_suffix (";")) t = t.substring (0, t.length - 1).strip ();
                if (t == "") continue;
                int lt = t.last_index_of_char ('<');
                int gt = lt >= 0 ? t.index_of_char ('>', lt) : -1;
                if (lt >= 0 && gt > lt) {
                    string email = t.substring (lt + 1, gt - lt - 1).strip ();
                    string name = decode_words (unquote (strip_comments (t.substring (0, lt)))).strip ();
                    if (email == "") continue;
                    list.add (new Address (name, email));
                    continue;
                }
                string name = "";
                int po = t.index_of_char ('(');
                int pc = t.last_index_of_char (')');
                if (po >= 0 && pc > po) name = decode_words (t.substring (po + 1, pc - po - 1)).strip ();
                string email = strip_comments (t).strip ();
                if (!email.contains ("@")) {
                    if (email == "") continue;
                    email = unquote (email);
                }
                list.add (new Address (name, email));
            }
            return list;
        }

        public string format_addresses (Gee.List<Address> list) {
            var parts = new Gee.ArrayList<string> ();
            foreach (var a in list) parts.add (a.to_header ());
            return string.joinv (", ", parts.to_array ());
        }

        public string display_addresses (Gee.List<Address> list) {
            var parts = new Gee.ArrayList<string> ();
            foreach (var a in list) parts.add (a.display ());
            return string.joinv (", ", parts.to_array ());
        }

        private const string[] MONTHS = { "jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec" };

        public DateTime? parse_date (string header) {
            string s = strip_comments (unfold (header)).strip ();
            if (s == "") return null;
            int comma = s.index_of_char (',');
            if (comma >= 0) s = s.substring (comma + 1);
            string[] tokens = {};
            foreach (string t in s.replace ("\t", " ").split (" ")) {
                if (t.strip () != "") tokens += t.strip ();
            }
            if (tokens.length < 4) return null;
            int day = 0, month = -1, year = 0;
            int ti = 0;
            if (int.try_parse (tokens[0], out day)) {
                for (int m = 0; m < 12; m++) {
                    if (tokens[1].down ().has_prefix (MONTHS[m])) month = m + 1;
                }
                ti = 2;
            } else {
                for (int m = 0; m < 12; m++) {
                    if (tokens[0].down ().has_prefix (MONTHS[m])) month = m + 1;
                }
                if (!int.try_parse (tokens[1], out day)) return null;
                ti = 2;
            }
            if (month < 0) return null;
            if (!int.try_parse (tokens[ti], out year)) return null;
            if (year < 50) year += 2000;
            else if (year < 1000) year += 1900;
            ti++;
            if (ti >= tokens.length) return null;
            string[] hms = tokens[ti].split (":");
            int hh = 0, mm = 0, ss = 0;
            if (hms.length >= 2) {
                hh = int.parse (hms[0]);
                mm = int.parse (hms[1]);
                if (hms.length >= 3) ss = int.parse (hms[2]);
            }
            ti++;
            string zone = ti < tokens.length ? tokens[ti] : "+0000";
            TimeZone tz;
            string z = zone.up ();
            if ((z[0] == '+' || z[0] == '-') && z.length >= 5) {
                tz = timezone_or_utc ("%s%s:%s".printf (z.substring (0, 1), z.substring (1, 2), z.substring (3, 2)));
            } else {
                string off = "+00:00";
                switch (z) {
                    case "EST": off = "-05:00"; break;
                    case "EDT": off = "-04:00"; break;
                    case "CST": off = "-06:00"; break;
                    case "CDT": off = "-05:00"; break;
                    case "MST": off = "-07:00"; break;
                    case "MDT": off = "-06:00"; break;
                    case "PST": off = "-08:00"; break;
                    case "PDT": off = "-07:00"; break;
                    case "CET": off = "+01:00"; break;
                    case "CEST": off = "+02:00"; break;
                }
                tz = timezone_or_utc (off);
            }
            if (day < 1 || day > 31 || hh > 23 || mm > 59 || ss > 60) return null;
            return new DateTime (tz, year, month, day, hh, mm, ss > 59 ? 59 : ss);
        }

        private TimeZone timezone_or_utc (string id) {
            try {
                return new TimeZone.identifier (id);
            } catch (Error e) {
                return new TimeZone.utc ();
            }
        }

        public string format_date (DateTime dt) {
            string[] days = { "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun" };
            string[] months = { "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
            int off = (int) (dt.get_utc_offset () / TimeSpan.MINUTE);
            char sign = off < 0 ? '-' : '+';
            off = off.abs ();
            return "%s, %d %s %d %02d:%02d:%02d %c%02d%02d".printf (days[dt.get_day_of_week () - 1], dt.get_day_of_month (), months[dt.get_month () - 1], dt.get_year (), dt.get_hour (), dt.get_minute (), dt.get_second (), sign, off / 60, off % 60);
        }

        public string new_message_id (string email) {
            string domain = email.contains ("@") ? email.substring (email.last_index_of_char ('@') + 1) : "localhost";
            return "%s.%08x@%s".printf (Uuid.string_random ().replace ("-", "").substring (0, 20), Random.next_int (), domain);
        }

        public int importance_of (MimePart part) {
            string imp = (part.header ("Importance") ?? part.header ("X-MSMail-Priority") ?? "").strip ().down ();
            if (imp == "high") return 1;
            if (imp == "low") return -1;
            string pri = (part.header ("X-Priority") ?? "").strip ();
            if (pri.has_prefix ("1") || pri.has_prefix ("2")) return 1;
            if (pri.has_prefix ("4") || pri.has_prefix ("5")) return -1;
            return 0;
        }

        public string normalize_subject (string subject) {
            string s = subject.strip ();
            bool changed = true;
            while (changed) {
                changed = false;
                string low = s.down ();
                foreach (string p in new string[] { "re:", "fw:", "fwd:", "aw:", "r:", "i:", "sv:", "wg:", "rif:", "tr:" }) {
                    if (low.has_prefix (p)) {
                        s = s.substring (p.length).strip ();
                        changed = true;
                        break;
                    }
                }
                if (!changed && s.has_prefix ("[") && s.index_of_char (']') > 0 && s.index_of_char (']') < 40 && low.index_of ("re:") > s.index_of_char (']')) {
                    string after = s.substring (s.index_of_char (']') + 1).strip ();
                    if (after.down ().has_prefix ("re:")) {
                        s = after;
                        changed = true;
                    }
                }
            }
            return s;
        }
    }

    public class OutgoingAttachment : Object {
        public string filename { get; set; }
        public string content_type { get; set; }
        public Bytes data { get; set; }
        public string content_id { get; set; default = ""; }
        public string method { get; set; default = ""; }

        public OutgoingAttachment (string filename, string content_type, Bytes data) {
            this.filename = filename;
            this.content_type = content_type;
            this.data = data;
        }
    }

    public class MessageBuilder : Object {
        public Address from { get; set; }
        public Gee.ArrayList<Address> to = new Gee.ArrayList<Address> ();
        public Gee.ArrayList<Address> cc = new Gee.ArrayList<Address> ();
        public Gee.ArrayList<Address> bcc = new Gee.ArrayList<Address> ();
        public Gee.ArrayList<Address> reply_to = new Gee.ArrayList<Address> ();
        public string subject { get; set; default = ""; }
        public string text { get; set; default = ""; }
        public string? html { get; set; default = null; }
        public string in_reply_to { get; set; default = ""; }
        public string references { get; set; default = ""; }
        public string message_id { get; set; default = ""; }
        public DateTime? date { get; set; default = null; }
        public int importance { get; set; }
        public bool request_receipt { get; set; }
        public Gee.ArrayList<OutgoingAttachment> attachments = new Gee.ArrayList<OutgoingAttachment> ();
        public Gee.ArrayList<OutgoingAttachment> inline_images = new Gee.ArrayList<OutgoingAttachment> ();
        public Gee.ArrayList<HeaderField> extra_headers = new Gee.ArrayList<HeaderField> ();
        public uint8[]? body_override = null;

        private string boundary () {
            return "=_lettere_" + Uuid.string_random ().replace ("-", "");
        }

        private void header (StringBuilder sb, string name, string value) {
            sb.append (name);
            sb.append (": ");
            sb.append (value);
            sb.append ("\r\n");
        }

        private string text_part (string mime, string body) {
            var sb = new StringBuilder ();
            header (sb, "Content-Type", mime + "; charset=utf-8");
            header (sb, "Content-Transfer-Encoding", "quoted-printable");
            sb.append ("\r\n");
            sb.append (Mime.encode_qp (body));
            sb.append ("\r\n");
            return sb.str;
        }

        public static string filename_param (string name, string key = "filename") {
            bool ascii = true;
            for (int i = 0; i < name.length; i++) {
                if ((uint8) name[i] > 127 || name[i] == '"') ascii = false;
            }
            if (ascii) return "%s=\"%s\"".printf (key, name);
            var sb = new StringBuilder (key + "*=utf-8''");
            foreach (uint8 b in name.data) {
                if ((b >= 'a' && b <= 'z') || (b >= 'A' && b <= 'Z') || (b >= '0' && b <= '9') || b == '.' || b == '-' || b == '_') sb.append_c ((char) b);
                else sb.append ("%%%02X".printf (b));
            }
            return sb.str;
        }

        private string html_part () {
            if (inline_images.size == 0) return text_part ("text/html", html);
            string b = boundary ();
            var sb = new StringBuilder ();
            header (sb, "Content-Type", "multipart/related; type=\"text/html\"; boundary=\"%s\"".printf (b));
            sb.append ("\r\n");
            sb.append ("--" + b + "\r\n");
            sb.append (text_part ("text/html", html));
            foreach (var img in inline_images) {
                sb.append ("--" + b + "\r\n");
                header (sb, "Content-Type", img.content_type != "" ? img.content_type : "application/octet-stream");
                header (sb, "Content-ID", "<" + img.content_id + ">");
                header (sb, "Content-Disposition", "inline; " + filename_param (img.filename));
                header (sb, "Content-Transfer-Encoding", "base64");
                sb.append ("\r\n");
                sb.append (Mime.encode_base64_lines (img.data.get_data ()));
            }
            sb.append ("--" + b + "--\r\n");
            return sb.str;
        }

        private string body_part () {
            if (html == null) return text_part ("text/plain", text);
            string b = boundary ();
            var sb = new StringBuilder ();
            header (sb, "Content-Type", "multipart/alternative; boundary=\"%s\"".printf (b));
            sb.append ("\r\n");
            sb.append ("--" + b + "\r\n");
            sb.append (text_part ("text/plain", text));
            sb.append ("--" + b + "\r\n");
            sb.append (html_part ());
            sb.append ("--" + b + "--\r\n");
            return sb.str;
        }

        public static string attachment_part (OutgoingAttachment a) {
            var sb = new StringBuilder ();
            string ct = a.content_type != "" ? a.content_type : "application/octet-stream";
            if (ct == "message/rfc822") {
                sb.append ("Content-Type: message/rfc822\r\n");
                sb.append ("Content-Disposition: attachment; " + filename_param (a.filename) + "\r\n\r\n");
                string raw = Mime.bytes_to_string (a.data.get_data ()).replace ("\r\n", "\n").replace ("\n", "\r\n");
                sb.append (raw);
                if (!raw.has_suffix ("\r\n")) sb.append ("\r\n");
                return sb.str;
            }
            if (ct.has_prefix ("text/calendar")) {
                sb.append ("Content-Type: " + ct + (ct.contains ("charset") ? "" : "; charset=utf-8") + "\r\n");
                if (a.method == "") sb.append ("Content-Disposition: attachment; " + filename_param (a.filename) + "\r\n");
            } else {
                sb.append ("Content-Type: " + ct + "; " + filename_param (a.filename, "name") + "\r\n");
                sb.append ("Content-Disposition: attachment; " + filename_param (a.filename) + "\r\n");
            }
            sb.append ("Content-Transfer-Encoding: base64\r\n\r\n");
            sb.append (Mime.encode_base64_lines (a.data.get_data ()));
            return sb.str;
        }

        public string entity () {
            if (attachments.size == 0) return body_part ();
            string b = boundary ();
            var sb = new StringBuilder ();
            header (sb, "Content-Type", "multipart/mixed; boundary=\"%s\"".printf (b));
            sb.append ("\r\n");
            sb.append ("--" + b + "\r\n");
            sb.append (body_part ());
            foreach (var a in attachments) {
                sb.append ("--" + b + "\r\n");
                sb.append (attachment_part (a));
            }
            sb.append ("--" + b + "--\r\n");
            return sb.str;
        }

        public string headers (bool include_bcc) {
            var sb = new StringBuilder ();
            if (date == null) date = new DateTime.now_local ();
            if (message_id == "") message_id = Mime.new_message_id (from.email);
            header (sb, "Date", Mime.format_date (date));
            header (sb, "From", from.to_header ());
            if (reply_to.size > 0) header (sb, "Reply-To", Mime.format_addresses (reply_to));
            if (to.size > 0) header (sb, "To", Mime.format_addresses (to));
            if (cc.size > 0) header (sb, "Cc", Mime.format_addresses (cc));
            if (include_bcc && bcc.size > 0) header (sb, "Bcc", Mime.format_addresses (bcc));
            header (sb, "Subject", Mime.encode_words (subject));
            header (sb, "Message-ID", "<" + message_id + ">");
            if (in_reply_to != "") header (sb, "In-Reply-To", "<" + in_reply_to + ">");
            if (references != "") {
                var refs = new Gee.ArrayList<string> ();
                foreach (string r in references.split (" ")) {
                    if (r.strip () != "") refs.add ("<" + r.strip () + ">");
                }
                header (sb, "References", string.joinv ("\r\n ", refs.to_array ()));
            }
            if (importance > 0) {
                header (sb, "Importance", "high");
                header (sb, "X-Priority", "1 (Highest)");
            } else if (importance < 0) {
                header (sb, "Importance", "low");
                header (sb, "X-Priority", "5 (Lowest)");
            }
            if (request_receipt) header (sb, "Disposition-Notification-To", from.to_header ());
            foreach (var h in extra_headers) header (sb, h.name, h.value);
            header (sb, "MIME-Version", "1.0");
            return sb.str;
        }

        public uint8[] build (bool include_bcc = false) {
            var b = new ByteArray ();
            b.append (headers (include_bcc).data);
            if (body_override != null) b.append (body_override);
            else b.append (entity ().data);
            return b.steal ();
        }

        public Gee.ArrayList<string> recipients () {
            var list = new Gee.ArrayList<string> ();
            foreach (var a in to) if (!list.contains (a.email)) list.add (a.email);
            foreach (var a in cc) if (!list.contains (a.email)) list.add (a.email);
            foreach (var a in bcc) if (!list.contains (a.email)) list.add (a.email);
            return list;
        }
    }
}
