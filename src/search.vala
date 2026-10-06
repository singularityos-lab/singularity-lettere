namespace Singularity.Apps.Lettere {

    public class SearchTerm {
        public string key;
        public string value;
        public bool negated;

        public SearchTerm (string key, string value, bool negated) {
            this.key = key;
            this.value = value;
            this.negated = negated;
        }
    }

    public class SearchQuery {
        public Gee.ArrayList<SearchTerm> terms = new Gee.ArrayList<SearchTerm> ();
        public string folder_name = "";
        public string account_name = "";

        public bool is_empty {
            get { return terms.size == 0 && folder_name == "" && account_name == ""; }
        }

        public bool all_folders {
            get {
                foreach (var t in terms) if (t.key == "in" && t.value.down () == "all") return true;
                return false;
            }
        }

        public static string[] split (string text) {
            string[] outv = {};
            var sb = new StringBuilder ();
            bool quoted = false;
            unichar c;
            int i = 0;
            while (text.get_next_char (ref i, out c)) {
                if (c == '"') {
                    quoted = !quoted;
                    continue;
                }
                if (c.isspace () && !quoted) {
                    if (sb.len > 0) outv += sb.str;
                    sb.truncate (0);
                    continue;
                }
                sb.append_unichar (c);
            }
            if (sb.len > 0) outv += sb.str;
            return outv;
        }

        private static string canonical (string key) {
            switch (key.down ()) {
                case "da":
                case "from": return "from";
                case "a":
                case "to": return "to";
                case "cc": return "cc";
                case "bcc": return "bcc";
                case "oggetto":
                case "subject": return "subject";
                case "corpo":
                case "body": return "body";
                case "ha":
                case "has": return "has";
                case "is":
                case "è": return "is";
                case "in":
                case "folder":
                case "cartella": return "in";
                case "label":
                case "etichetta":
                case "category":
                case "categoria": return "category";
                case "before":
                case "prima": return "before";
                case "after":
                case "dopo": return "after";
                case "on":
                case "il": return "on";
                case "larger":
                case "size": return "larger";
                case "smaller": return "smaller";
                case "account": return "account";
                case "filename":
                case "allegato": return "filename";
                case "older_than": return "older";
                case "newer_than": return "newer";
            }
            return "";
        }

        public static SearchQuery parse (string text) {
            var q = new SearchQuery ();
            foreach (string raw in split (text)) {
                string token = raw;
                bool neg = false;
                if (token.has_prefix ("-") && token.length > 1) {
                    neg = true;
                    token = token.substring (1);
                }
                int colon = token.index_of_char (':');
                if (colon > 0 && colon < token.length - 1) {
                    string key = canonical (token.substring (0, colon));
                    if (key != "") {
                        string value = token.substring (colon + 1);
                        if (key == "in" && value.down () != "all") q.folder_name = value;
                        if (key == "account") q.account_name = value;
                        q.terms.add (new SearchTerm (key, value, neg));
                        continue;
                    }
                }
                q.terms.add (new SearchTerm ("text", token, neg));
            }
            return q;
        }

        public static int64 parse_day (string v, bool end_of_day) {
            string s = v.strip ().replace ("/", "-").replace (".", "-");
            string[] p = s.split ("-");
            if (p.length != 3) return -1;
            int a = int.parse (p[0]), b = int.parse (p[1]), c = int.parse (p[2]);
            int y, mo, d;
            if (p[0].length == 4) {
                y = a;
                mo = b;
                d = c;
            } else {
                d = a;
                mo = b;
                y = c;
            }
            if (y < 1970 || mo < 1 || mo > 12 || d < 1 || d > 31) return -1;
            var dt = new DateTime.local (y, mo, d, 0, 0, 0);
            if (dt == null) return -1;
            if (end_of_day) dt = dt.add_days (1);
            return dt.to_unix ();
        }

        public static int64 parse_size (string v) {
            string s = v.strip ().down ();
            int64 mult = 1;
            if (s.has_suffix ("kb") || s.has_suffix ("k")) mult = 1024;
            else if (s.has_suffix ("mb") || s.has_suffix ("m")) mult = 1024 * 1024;
            else if (s.has_suffix ("gb") || s.has_suffix ("g")) mult = 1024 * 1024 * 1024;
            string num = s;
            while (num.length > 0 && !num[num.length - 1].isdigit ()) num = num.substring (0, num.length - 1);
            int64 n;
            if (!int64.try_parse (num, out n)) return -1;
            return n * mult;
        }

        public static int64 parse_age (string v) {
            string s = v.strip ().down ();
            if (s.length < 2) return -1;
            int64 n;
            if (!int64.try_parse (s.substring (0, s.length - 1), out n)) return -1;
            switch (s[s.length - 1]) {
                case 'd': return n * 86400;
                case 'w': return n * 7 * 86400;
                case 'm': return n * 30 * 86400;
                case 'y': return n * 365 * 86400;
            }
            return -1;
        }

        private static string fts_value (string col, string value) {
            var parts = new Gee.ArrayList<string> ();
            foreach (string w in value.split (" ")) {
                string t = w.strip ().replace ("\"", "");
                if (t == "") continue;
                parts.add ((col != "" ? col + ":" : "") + "\"" + t + "\"*");
            }
            return string.joinv (" ", parts.to_array ());
        }

        private static string like (string v) {
            return "%" + v.down ().replace ("\\", "\\\\").replace ("%", "\\%").replace ("_", "\\_") + "%";
        }

        public string to_sql (Gee.List<string> binds) {
            var parts = new Gee.ArrayList<string> ();
            foreach (var t in terms) {
                string? clause = null;
                switch (t.key) {
                    case "text":
                        clause = "m.id IN (SELECT rowid FROM search WHERE search MATCH ?)";
                        binds.add (fts_value ("", t.value));
                        break;
                    case "subject":
                        clause = "m.id IN (SELECT rowid FROM search WHERE search MATCH ?)";
                        binds.add (fts_value ("subject", t.value));
                        break;
                    case "body":
                        clause = "m.id IN (SELECT rowid FROM search WHERE search MATCH ?)";
                        binds.add (fts_value ("body", t.value));
                        break;
                    case "filename":
                        clause = "m.id IN (SELECT rowid FROM search WHERE search MATCH ?)";
                        binds.add (fts_value ("body", t.value));
                        break;
                    case "from":
                        clause = "(lower(m.sender_email) LIKE ? ESCAPE '\\' OR lower(m.sender_name) LIKE ? ESCAPE '\\')";
                        binds.add (like (t.value));
                        binds.add (like (t.value));
                        break;
                    case "to":
                        clause = "(lower(m.to_list) LIKE ? ESCAPE '\\' OR lower(m.cc_list) LIKE ? ESCAPE '\\')";
                        binds.add (like (t.value));
                        binds.add (like (t.value));
                        break;
                    case "cc":
                        clause = "lower(m.cc_list) LIKE ? ESCAPE '\\'";
                        binds.add (like (t.value));
                        break;
                    case "has":
                        switch (t.value.down ()) {
                            case "attachment":
                            case "attachments":
                            case "allegato":
                            case "allegati": clause = "m.has_attach = 1"; break;
                            case "flag":
                            case "star": clause = "(m.flags & 2) != 0"; break;
                            case "category":
                            case "userlabels": clause = "m.keywords != ''"; break;
                        }
                        break;
                    case "is":
                        switch (t.value.down ()) {
                            case "unread":
                            case "nonletto": clause = "(m.flags & 1) = 0"; break;
                            case "read":
                            case "letto": clause = "(m.flags & 1) != 0"; break;
                            case "flagged":
                            case "starred":
                            case "contrassegnato": clause = "(m.flags & 2) != 0"; break;
                            case "answered":
                            case "replied": clause = "(m.flags & 4) != 0"; break;
                            case "pinned": clause = "(m.flags & 128) != 0"; break;
                            case "completed":
                            case "done": clause = "(m.flags & 64) != 0"; break;
                            case "important":
                            case "high": clause = "m.importance > 0"; break;
                            case "focused": clause = "m.focus != 0"; break;
                            case "other": clause = "m.focus = 0"; break;
                        }
                        break;
                    case "in":
                        if (t.value.down () == "all") break;
                        clause = "(lower(f.name) = ? OR lower(f.path) = ? OR f.role = ?)";
                        binds.add (t.value.down ());
                        binds.add (t.value.down ());
                        binds.add (role_alias (t.value));
                        break;
                    case "category":
                        clause = "('\x1f' || lower(m.keywords) || '\x1f') LIKE ? ESCAPE '\\'";
                        binds.add ("%\x1f" + t.value.down ().replace ("_", " ").replace ("%", "\\%") + "\x1f%");
                        break;
                    case "before": {
                        int64 d = parse_day (t.value, false);
                        if (d >= 0) clause = "m.date < %s".printf (d.to_string ());
                        break;
                    }
                    case "after": {
                        int64 d = parse_day (t.value, true);
                        if (d >= 0) clause = "m.date >= %s".printf ((d - 86400).to_string ());
                        break;
                    }
                    case "on": {
                        int64 d = parse_day (t.value, false);
                        if (d >= 0) clause = "(m.date >= %s AND m.date < %s)".printf (d.to_string (), (d + 86400).to_string ());
                        break;
                    }
                    case "older": {
                        int64 a = parse_age (t.value);
                        if (a >= 0) clause = "m.date < %s".printf ((new DateTime.now_utc ().to_unix () - a).to_string ());
                        break;
                    }
                    case "newer": {
                        int64 a = parse_age (t.value);
                        if (a >= 0) clause = "m.date >= %s".printf ((new DateTime.now_utc ().to_unix () - a).to_string ());
                        break;
                    }
                    case "larger": {
                        int64 s = parse_size (t.value);
                        if (s >= 0) clause = "m.size > %s".printf (s.to_string ());
                        break;
                    }
                    case "smaller": {
                        int64 s = parse_size (t.value);
                        if (s >= 0) clause = "m.size < %s".printf (s.to_string ());
                        break;
                    }
                    case "account":
                        clause = "m.account IN (SELECT DISTINCT account FROM folders WHERE account = ?)";
                        binds.add (t.value);
                        break;
                }
                if (clause == null) continue;
                parts.add (t.negated ? "NOT " + clause : clause);
            }
            if (parts.size == 0) return "1";
            return string.joinv (" AND ", parts.to_array ());
        }

        public static string role_alias (string v) {
            switch (v.down ()) {
                case "inbox":
                case "arrivo": return "inbox";
                case "sent":
                case "inviata":
                case "inviati": return "sent";
                case "drafts":
                case "bozze": return "drafts";
                case "trash":
                case "cestino": return "trash";
                case "junk":
                case "spam":
                case "indesiderata": return "junk";
                case "archive":
                case "archivio": return "archive";
            }
            return "-";
        }

        private static string imap_date (int64 t) {
            var d = new DateTime.from_unix_local (t);
            string[] months = { "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
            return "%d-%s-%d".printf (d.get_day_of_month (), months[d.get_month () - 1], d.get_year ());
        }

        public string to_imap () {
            var parts = new Gee.ArrayList<string> ();
            foreach (var t in terms) {
                string? c = null;
                string v = ImapClient.quote (t.value);
                switch (t.key) {
                    case "text": c = "TEXT " + v; break;
                    case "subject": c = "SUBJECT " + v; break;
                    case "body": c = "BODY " + v; break;
                    case "filename": c = "BODY " + v; break;
                    case "from": c = "FROM " + v; break;
                    case "to": c = "TO " + v; break;
                    case "cc": c = "CC " + v; break;
                    case "category": c = "KEYWORD " + Keywords.to_keyword (t.value); break;
                    case "has":
                        if (t.value.down ().has_prefix ("attach") || t.value.down ().has_prefix ("allegat")) c = "HEADER Content-Type \"multipart/mixed\"";
                        else if (t.value.down () == "flag" || t.value.down () == "star") c = "FLAGGED";
                        break;
                    case "is":
                        switch (t.value.down ()) {
                            case "unread":
                            case "nonletto": c = "UNSEEN"; break;
                            case "read":
                            case "letto": c = "SEEN"; break;
                            case "flagged":
                            case "starred":
                            case "contrassegnato": c = "FLAGGED"; break;
                            case "answered":
                            case "replied": c = "ANSWERED"; break;
                        }
                        break;
                    case "before": {
                        int64 d = parse_day (t.value, false);
                        if (d >= 0) c = "BEFORE " + imap_date (d);
                        break;
                    }
                    case "after": {
                        int64 d = parse_day (t.value, false);
                        if (d >= 0) c = "SINCE " + imap_date (d);
                        break;
                    }
                    case "on": {
                        int64 d = parse_day (t.value, false);
                        if (d >= 0) c = "ON " + imap_date (d);
                        break;
                    }
                    case "larger": {
                        int64 s = parse_size (t.value);
                        if (s >= 0) c = "LARGER " + s.to_string ();
                        break;
                    }
                    case "smaller": {
                        int64 s = parse_size (t.value);
                        if (s >= 0) c = "SMALLER " + s.to_string ();
                        break;
                    }
                }
                if (c == null) continue;
                parts.add (t.negated ? "NOT " + c : c);
            }
            if (parts.size == 0) return "ALL";
            return string.joinv (" ", parts.to_array ());
        }

        public string to_gmail () {
            var parts = new Gee.ArrayList<string> ();
            foreach (var t in terms) {
                string v = t.value.contains (" ") ? "\"" + t.value + "\"" : t.value;
                string? c = null;
                switch (t.key) {
                    case "text": c = v; break;
                    case "subject": c = "subject:" + v; break;
                    case "body": c = v; break;
                    case "filename": c = "filename:" + v; break;
                    case "from": c = "from:" + v; break;
                    case "to": c = "to:" + v; break;
                    case "cc": c = "cc:" + v; break;
                    case "category": c = "label:" + v.replace (" ", "-"); break;
                    case "has": c = t.value.down ().has_prefix ("attach") ? "has:attachment" : null; break;
                    case "is":
                        switch (t.value.down ()) {
                            case "unread": c = "is:unread"; break;
                            case "read": c = "is:read"; break;
                            case "flagged":
                            case "starred": c = "is:starred"; break;
                            case "important": c = "is:important"; break;
                        }
                        break;
                    case "before":
                    case "after": {
                        int64 d = parse_day (t.value, false);
                        if (d >= 0) c = t.key + ":" + new DateTime.from_unix_local (d).format ("%Y/%m/%d");
                        break;
                    }
                    case "larger":
                    case "smaller": c = t.key + ":" + t.value; break;
                    case "older": c = "older_than:" + t.value; break;
                    case "newer": c = "newer_than:" + t.value; break;
                }
                if (c == null) continue;
                parts.add (t.negated ? "-" + c : c);
            }
            return string.joinv (" ", parts.to_array ());
        }

        public string to_kql () {
            var parts = new Gee.ArrayList<string> ();
            foreach (var t in terms) {
                string v = "\"" + t.value.replace ("\"", "") + "\"";
                string? c = null;
                switch (t.key) {
                    case "text": c = t.value.replace ("\"", ""); break;
                    case "subject": c = "subject:" + v; break;
                    case "body": c = "body:" + v; break;
                    case "filename": c = "attachment:" + v; break;
                    case "from": c = "from:" + v; break;
                    case "to": c = "to:" + v; break;
                    case "cc": c = "cc:" + v; break;
                    case "category": c = "category:" + v; break;
                    case "has": c = t.value.down ().has_prefix ("attach") ? "hasattachments:true" : null; break;
                    case "is":
                        if (t.value.down () == "unread") c = "isread:false";
                        else if (t.value.down () == "read") c = "isread:true";
                        else if (t.value.down () == "flagged") c = "isflagged:true";
                        break;
                    case "before": {
                        int64 d = parse_day (t.value, false);
                        if (d >= 0) c = "received<" + new DateTime.from_unix_local (d).format ("%Y-%m-%d");
                        break;
                    }
                    case "after": {
                        int64 d = parse_day (t.value, false);
                        if (d >= 0) c = "received>=" + new DateTime.from_unix_local (d).format ("%Y-%m-%d");
                        break;
                    }
                    case "larger": {
                        int64 s = parse_size (t.value);
                        if (s >= 0) c = "size>" + s.to_string ();
                        break;
                    }
                    case "smaller": {
                        int64 s = parse_size (t.value);
                        if (s >= 0) c = "size<" + s.to_string ();
                        break;
                    }
                }
                if (c == null) continue;
                parts.add (t.negated ? "NOT " + c : c);
            }
            return string.joinv (" AND ", parts.to_array ());
        }

        public Json.Node to_jmap_filter () {
            var b = new Json.Builder ();
            b.begin_object ();
            b.set_member_name ("operator").add_string_value ("AND");
            b.set_member_name ("conditions");
            b.begin_array ();
            foreach (var t in terms) {
                string? prop = null;
                string? value = t.value;
                switch (t.key) {
                    case "text": prop = "text"; break;
                    case "subject": prop = "subject"; break;
                    case "body": prop = "body"; break;
                    case "filename": prop = "text"; break;
                    case "from": prop = "from"; break;
                    case "to": prop = "to"; break;
                    case "cc": prop = "cc"; break;
                    case "category": prop = "hasKeyword"; value = Keywords.to_keyword (t.value); break;
                    case "is":
                        if (t.value.down () == "unread") {
                            prop = "notKeyword";
                            value = "$seen";
                        } else if (t.value.down () == "read") {
                            prop = "hasKeyword";
                            value = "$seen";
                        } else if (t.value.down () == "flagged") {
                            prop = "hasKeyword";
                            value = "$flagged";
                        }
                        break;
                    case "before": {
                        int64 d = parse_day (t.value, false);
                        if (d >= 0) {
                            prop = "before";
                            value = new DateTime.from_unix_utc (d).format ("%Y-%m-%dT%H:%M:%SZ");
                        }
                        break;
                    }
                    case "after": {
                        int64 d = parse_day (t.value, false);
                        if (d >= 0) {
                            prop = "after";
                            value = new DateTime.from_unix_utc (d).format ("%Y-%m-%dT%H:%M:%SZ");
                        }
                        break;
                    }
                }
                if (t.key == "has" && t.value.down ().has_prefix ("attach")) {
                    b.begin_object ();
                    b.set_member_name ("hasAttachment").add_boolean_value (!t.negated);
                    b.end_object ();
                    continue;
                }
                if (t.key == "larger" || t.key == "smaller") {
                    int64 s = parse_size (t.value);
                    if (s < 0) continue;
                    b.begin_object ();
                    b.set_member_name (t.key == "larger" ? "minSize" : "maxSize").add_int_value (s);
                    b.end_object ();
                    continue;
                }
                if (prop == null) continue;
                if (t.negated) {
                    b.begin_object ();
                    b.set_member_name ("operator").add_string_value ("NOT");
                    b.set_member_name ("conditions");
                    b.begin_array ();
                }
                b.begin_object ();
                b.set_member_name (prop).add_string_value (value);
                b.end_object ();
                if (t.negated) {
                    b.end_array ();
                    b.end_object ();
                }
            }
            b.end_array ();
            b.end_object ();
            return b.get_root ();
        }

        public string to_aqs () {
            var parts = new Gee.ArrayList<string> ();
            foreach (var t in terms) {
                string v = t.value.contains (" ") ? "\"" + t.value + "\"" : t.value;
                string? c = null;
                switch (t.key) {
                    case "text": c = v; break;
                    case "subject": c = "subject:" + v; break;
                    case "body": c = "body:" + v; break;
                    case "filename": c = "attachment:" + v; break;
                    case "from": c = "from:" + v; break;
                    case "to": c = "to:" + v; break;
                    case "cc": c = "cc:" + v; break;
                    case "category": c = "category:" + v; break;
                    case "has": c = t.value.down ().has_prefix ("attach") ? "hasattachment:true" : null; break;
                    case "is":
                        if (t.value.down () == "unread") c = "isread:false";
                        else if (t.value.down () == "read") c = "isread:true";
                        else if (t.value.down () == "flagged") c = "isflagged:true";
                        break;
                    case "before":
                    case "after": {
                        int64 d = parse_day (t.value, false);
                        if (d >= 0) c = "received:" + (t.key == "before" ? "<" : ">=") + new DateTime.from_unix_local (d).format ("%m/%d/%Y");
                        break;
                    }
                }
                if (c == null) continue;
                parts.add (t.negated ? "NOT " + c : c);
            }
            return string.joinv (" AND ", parts.to_array ());
        }
    }

    public class SavedSearch : Object {
        public string name { get; set; }
        public string query { get; set; }

        public SavedSearch (string name, string query) {
            this.name = name;
            this.query = query;
        }

        public static Gee.ArrayList<SavedSearch> load (string[] entries) {
            var list = new Gee.ArrayList<SavedSearch> ();
            foreach (string e in entries) {
                int tab = e.index_of_char ('\t');
                if (tab <= 0) continue;
                list.add (new SavedSearch (e.substring (0, tab), e.substring (tab + 1)));
            }
            return list;
        }

        public string to_entry () {
            return name.replace ("\t", " ") + "\t" + query;
        }
    }
}
