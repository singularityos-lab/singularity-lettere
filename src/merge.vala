namespace Singularity.Apps.Lettere {

    public class MergeTable : Object {
        public Gee.ArrayList<string> columns = new Gee.ArrayList<string> ();
        public Gee.ArrayList<Gee.HashMap<string, string>> rows = new Gee.ArrayList<Gee.HashMap<string, string>> ();

        public static Gee.ArrayList<Gee.ArrayList<string>> parse_csv (string text) {
            var outb = new Gee.ArrayList<Gee.ArrayList<string>> ();
            var row = new Gee.ArrayList<string> ();
            var field = new StringBuilder ();
            bool quoted = false;
            char sep = ',';
            int first_nl = text.index_of_char ('\n');
            string head = first_nl > 0 ? text.substring (0, first_nl) : text;
            if (head.split (";").length > head.split (",").length) sep = ';';
            else if (head.split ("\t").length > head.split (",").length) sep = '\t';
            for (int i = 0; i < text.length; i++) {
                char c = text[i];
                if (quoted) {
                    if (c == '"') {
                        if (i + 1 < text.length && text[i + 1] == '"') {
                            field.append_c ('"');
                            i++;
                        } else {
                            quoted = false;
                        }
                    } else {
                        field.append_c (c);
                    }
                    continue;
                }
                if (c == '"') {
                    quoted = true;
                } else if (c == sep) {
                    row.add (field.str);
                    field.truncate (0);
                } else if (c == '\n' || c == '\r') {
                    if (c == '\r' && i + 1 < text.length && text[i + 1] == '\n') i++;
                    row.add (field.str);
                    field.truncate (0);
                    bool empty = true;
                    foreach (string f in row) if (f.strip () != "") empty = false;
                    if (!empty) outb.add (row);
                    row = new Gee.ArrayList<string> ();
                } else {
                    field.append_c (c);
                }
            }
            if (field.len > 0 || row.size > 0) {
                row.add (field.str);
                bool empty = true;
                foreach (string f in row) if (f.strip () != "") empty = false;
                if (!empty) outb.add (row);
            }
            return outb;
        }

        public static MergeTable from_csv (string text) {
            var t = new MergeTable ();
            var lines = parse_csv (text.has_prefix ("\xef\xbb\xbf") ? text.substring (3) : text);
            if (lines.size == 0) return t;
            foreach (string c in lines[0]) t.columns.add (c.strip ());
            for (int i = 1; i < lines.size; i++) {
                var map = new Gee.HashMap<string, string> ();
                for (int k = 0; k < t.columns.size && k < lines[i].size; k++) map[t.columns[k].down ()] = lines[i][k].strip ();
                t.rows.add (map);
            }
            return t;
        }

        public string email_column () {
            foreach (string c in columns) {
                string l = c.down ();
                if (l == "email" || l == "e-mail" || l == "mail" || l == "email address" || l == "indirizzo email" || l == "posta elettronica") return l;
            }
            foreach (var r in rows) {
                foreach (var e in r.entries) if (e.value.contains ("@") && !e.value.contains (" ")) return e.key;
            }
            return "";
        }

        public static string fill (string template, Gee.Map<string, string> row, bool html) {
            var sb = new StringBuilder ();
            int i = 0;
            while (i < template.length) {
                int a = template.index_of ("{{", i);
                if (a < 0) {
                    sb.append (template.substring (i));
                    break;
                }
                int b = template.index_of ("}}", a + 2);
                if (b < 0) {
                    sb.append (template.substring (i));
                    break;
                }
                sb.append (template.substring (i, a - i));
                string key = Html.decode_entities (template.substring (a + 2, b - a - 2)).strip ().down ();
                string value = row[key] ?? "";
                sb.append (html ? Html.escape (value) : value);
                i = b + 2;
            }
            return sb.str;
        }
    }

    namespace Special {
        public uint8[] mdn (Account a, MessageInfo m, string subject_prefix) {
            string boundary = "=_lettere_mdn_" + Uuid.string_random ().replace ("-", "");
            var sb = new StringBuilder ();
            sb.append ("Date: " + Mime.format_date (new DateTime.now_local ()) + "\r\n");
            sb.append ("From: " + a.address ().to_header () + "\r\n");
            sb.append ("To: " + m.receipt_to + "\r\n");
            sb.append ("Subject: " + Mime.encode_words (subject_prefix + " " + m.subject) + "\r\n");
            sb.append ("Message-ID: <" + Mime.new_message_id (a.email) + ">\r\n");
            if (m.message_id != "") sb.append ("In-Reply-To: <" + m.message_id + ">\r\n");
            sb.append ("MIME-Version: 1.0\r\n");
            sb.append ("Content-Type: multipart/report; report-type=disposition-notification; boundary=\"%s\"\r\n\r\n".printf (boundary));
            sb.append ("--" + boundary + "\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Transfer-Encoding: quoted-printable\r\n\r\n");
            sb.append (Mime.encode_qp (_("The message \"%s\" sent on %s was displayed.").printf (m.subject, format_date_plain (m.date))) + "\r\n");
            sb.append ("--" + boundary + "\r\nContent-Type: message/disposition-notification\r\n\r\n");
            sb.append ("Reporting-UA: Lettere; Singularity\r\n");
            sb.append ("Final-Recipient: rfc822;" + a.email + "\r\n");
            if (m.message_id != "") sb.append ("Original-Message-ID: <" + m.message_id + ">\r\n");
            sb.append ("Disposition: manual-action/MDN-sent-manually; displayed\r\n\r\n");
            sb.append ("--" + boundary + "--\r\n");
            return sb.str.data;
        }

        public string format_date_plain (int64 t) {
            return new DateTime.from_unix_local (t).format ("%Y-%m-%d %H:%M");
        }

        public uint8[] redirect (uint8[] original, Account a, Gee.List<Address> to) {
            var sb = new StringBuilder ();
            sb.append ("Resent-From: " + a.address ().to_header () + "\r\n");
            sb.append ("Resent-To: " + Mime.format_addresses (to) + "\r\n");
            sb.append ("Resent-Date: " + Mime.format_date (new DateTime.now_local ()) + "\r\n");
            sb.append ("Resent-Message-ID: <" + Mime.new_message_id (a.email) + ">\r\n");
            var b = new ByteArray ();
            b.append (sb.str.data);
            b.append (original);
            return b.steal ();
        }

        public class UnsubscribeTarget {
            public string mailto = "";
            public string url = "";
            public bool one_click;
        }

        public UnsubscribeTarget unsubscribe_of (string header) {
            var t = new UnsubscribeTarget ();
            string[] halves = header.split ("\x1f");
            string list = halves[0];
            t.one_click = halves.length > 1 && halves[1].down ().contains ("one-click");
            int pos = 0;
            while ((pos = list.index_of_char ('<', pos)) >= 0) {
                int end = list.index_of_char ('>', pos);
                if (end < 0) break;
                string v = list.substring (pos + 1, end - pos - 1).strip ();
                if (v.down ().has_prefix ("mailto:") && t.mailto == "") t.mailto = v;
                else if (v.down ().has_prefix ("https:") && t.url == "") t.url = v;
                else if (v.down ().has_prefix ("http:") && t.url == "") t.url = v;
                pos = end + 1;
            }
            return t;
        }

        public void mailto_parts (string uri, out string to, out string subject, out string body) {
            string s = uri.has_prefix ("mailto:") ? uri.substring (7) : uri;
            to = s;
            subject = "";
            body = "";
            int q = s.index_of_char ('?');
            if (q >= 0) {
                to = s.substring (0, q);
                foreach (string kv in s.substring (q + 1).split ("&")) {
                    int eq = kv.index_of_char ('=');
                    if (eq <= 0) continue;
                    string k = kv.substring (0, eq).down ();
                    string v = Uri.unescape_string (kv.substring (eq + 1).replace ("+", " ")) ?? "";
                    if (k == "subject") subject = v;
                    else if (k == "body") body = v;
                    else if (k == "to") to = to == "" ? v : to + "," + v;
                }
            }
            to = Uri.unescape_string (to) ?? to;
        }
    }
}
