namespace Singularity.Apps.Lettere {

    public class RuleCondition : Object {
        public string field { get; set; default = "from"; }
        public string op { get; set; default = "contains"; }
        public string value { get; set; default = ""; }

        public RuleCondition (string field, string op, string value) {
            this.field = field;
            this.op = op;
            this.value = value;
        }
    }

    public class RuleAction : Object {
        public string kind { get; set; default = "move"; }
        public string value { get; set; default = ""; }

        public RuleAction (string kind, string value) {
            this.kind = kind;
            this.value = value;
        }
    }

    public class Rule : Object {
        public string id { get; set; default = ""; }
        public string name { get; set; default = ""; }
        public bool enabled { get; set; default = true; }
        public bool match_all { get; set; default = true; }
        public bool stop { get; set; }
        public bool on_server { get; set; }
        public string account { get; set; default = ""; }
        public Gee.ArrayList<RuleCondition> conditions = new Gee.ArrayList<RuleCondition> ();
        public Gee.ArrayList<RuleAction> actions = new Gee.ArrayList<RuleAction> ();

        public Json.Node to_json () {
            var b = new Json.Builder ();
            b.begin_object ();
            b.set_member_name ("id").add_string_value (id);
            b.set_member_name ("name").add_string_value (name);
            b.set_member_name ("enabled").add_boolean_value (enabled);
            b.set_member_name ("match-all").add_boolean_value (match_all);
            b.set_member_name ("stop").add_boolean_value (stop);
            b.set_member_name ("on-server").add_boolean_value (on_server);
            b.set_member_name ("account").add_string_value (account);
            b.set_member_name ("conditions");
            b.begin_array ();
            foreach (var c in conditions) {
                b.begin_object ();
                b.set_member_name ("field").add_string_value (c.field);
                b.set_member_name ("op").add_string_value (c.op);
                b.set_member_name ("value").add_string_value (c.value);
                b.end_object ();
            }
            b.end_array ();
            b.set_member_name ("actions");
            b.begin_array ();
            foreach (var a in actions) {
                b.begin_object ();
                b.set_member_name ("kind").add_string_value (a.kind);
                b.set_member_name ("value").add_string_value (a.value);
                b.end_object ();
            }
            b.end_array ();
            b.end_object ();
            return b.get_root ();
        }

        private static string s (Json.Object o, string k) {
            return o.has_member (k) ? o.get_string_member (k) : "";
        }

        public static Rule from_json (Json.Object o) {
            var r = new Rule ();
            r.id = s (o, "id");
            r.name = s (o, "name");
            r.enabled = !o.has_member ("enabled") || o.get_boolean_member ("enabled");
            r.match_all = !o.has_member ("match-all") || o.get_boolean_member ("match-all");
            r.stop = o.has_member ("stop") && o.get_boolean_member ("stop");
            r.on_server = o.has_member ("on-server") && o.get_boolean_member ("on-server");
            r.account = s (o, "account");
            if (o.has_member ("conditions")) {
                foreach (var n in o.get_array_member ("conditions").get_elements ()) {
                    var c = n.get_object ();
                    r.conditions.add (new RuleCondition (s (c, "field"), s (c, "op"), s (c, "value")));
                }
            }
            if (o.has_member ("actions")) {
                foreach (var n in o.get_array_member ("actions").get_elements ()) {
                    var a = n.get_object ();
                    r.actions.add (new RuleAction (s (a, "kind"), s (a, "value")));
                }
            }
            return r;
        }

        private static string field_text (string field, MessageInfo m, MimeMessage? mime) {
            switch (field) {
                case "from": return m.sender_name + " <" + m.sender_email + ">";
                case "to": return m.to_list;
                case "cc": return m.cc_list;
                case "recipients": return m.to_list + ", " + m.cc_list;
                case "subject": return m.subject;
                case "body": return mime != null ? mime.body_text () : m.preview;
                case "list-id": return m.list_id;
                case "account": return m.account;
            }
            if (field.has_prefix ("header:") && mime != null) {
                string name = field.substring (7);
                return mime.root.decoded_header (name);
            }
            return "";
        }

        public static bool test_text (string op, string hay, string value) {
            string h = hay.down ();
            string v = value.down ();
            switch (op) {
                case "is": return h.strip () == v.strip ();
                case "not-contains": return !h.contains (v);
                case "starts": return h.has_prefix (v);
                case "ends": return h.has_suffix (v);
                case "regex":
                    try {
                        return new Regex (value, RegexCompileFlags.CASELESS).match (hay);
                    } catch (RegexError e) {
                        return false;
                    }
                default: return h.contains (v);
            }
        }

        public bool test (RuleCondition c, MessageInfo m, MimeMessage? mime) {
            switch (c.field) {
                case "has-attachment": return m.has_attachment == (c.value != "false");
                case "importance": return (c.value == "high" && m.importance > 0) || (c.value == "low" && m.importance < 0) || (c.value == "normal" && m.importance == 0);
                case "size-larger": return m.size > SearchQuery.parse_size (c.value);
                case "size-smaller": return m.size < SearchQuery.parse_size (c.value);
                case "all": return true;
            }
            return test_text (c.op, field_text (c.field, m, mime), c.value);
        }

        public bool matches (MessageInfo m, MimeMessage? mime) {
            if (!enabled) return false;
            if (account != "" && account != m.account) return false;
            if (conditions.size == 0) return true;
            foreach (var c in conditions) {
                bool ok = test (c, m, mime);
                if (match_all && !ok) return false;
                if (!match_all && ok) return true;
            }
            return match_all;
        }

        public bool needs_body () {
            foreach (var c in conditions) if (c.field == "body" || c.field.has_prefix ("header:")) return true;
            return false;
        }

        public string describe () {
            var parts = new Gee.ArrayList<string> ();
            foreach (var c in conditions) parts.add ("%s %s".printf (RuleStore.field_label (c.field), c.value));
            var acts = new Gee.ArrayList<string> ();
            foreach (var a in actions) acts.add (RuleStore.action_label (a.kind) + (a.value != "" ? " " + a.value : ""));
            return "%s: %s".printf (string.joinv (match_all ? _(" and ") : _(" or "), parts.to_array ()), string.joinv (", ", acts.to_array ()));
        }
    }

    public class QuickStep : Object {
        public string id { get; set; default = ""; }
        public string name { get; set; default = ""; }
        public Gee.ArrayList<RuleAction> actions = new Gee.ArrayList<RuleAction> ();
    }

    public class RuleStore : Object {
        public signal void changed ();
        public Gee.ArrayList<Rule> rules = new Gee.ArrayList<Rule> ();
        public Gee.ArrayList<QuickStep> steps = new Gee.ArrayList<QuickStep> ();
        private string path;

        public RuleStore (string dir) {
            path = Path.build_filename (dir, "rules.json");
            load ();
        }

        public static string field_label (string field) {
            switch (field) {
                case "from": return _("From");
                case "to": return _("To");
                case "cc": return _("Cc");
                case "recipients": return _("To or Cc");
                case "subject": return _("Subject");
                case "body": return _("Message");
                case "list-id": return _("Mailing List");
                case "has-attachment": return _("Has Attachments");
                case "importance": return _("Importance");
                case "size-larger": return _("Larger Than");
                case "size-smaller": return _("Smaller Than");
                case "all": return _("Every Message");
            }
            if (field.has_prefix ("header:")) return field.substring (7);
            return field;
        }

        public static string action_label (string kind) {
            switch (kind) {
                case "move": return _("Move to");
                case "copy": return _("Copy to");
                case "read": return _("Mark as Read");
                case "flag": return _("Flag");
                case "category": return _("Category");
                case "delete": return _("Delete");
                case "junk": return _("Move to Junk");
                case "forward": return _("Forward to");
                case "redirect": return _("Redirect to");
                case "reply": return _("Reply with Template");
                case "pin": return _("Pin");
                case "archive": return _("Archive");
                case "other": return _("Move to Other");
                case "focused": return _("Move to Focused");
                case "unread": return _("Mark as Unread");
                case "snooze": return _("Snooze Until Tomorrow");
                case "task": return _("Add to Tasks");
            }
            return kind;
        }

        public static string[] field_ids () {
            return { "from", "to", "cc", "recipients", "subject", "body", "list-id", "has-attachment", "importance", "size-larger", "size-smaller", "all" };
        }

        public static string[] action_ids () {
            return { "move", "copy", "archive", "read", "unread", "flag", "pin", "category", "delete", "junk", "other", "focused", "forward", "redirect", "reply", "snooze", "task" };
        }

        public void load () {
            rules.clear ();
            steps.clear ();
            if (!FileUtils.test (path, FileTest.EXISTS)) {
                default_steps ();
                return;
            }
            try {
                var p = new Json.Parser ();
                p.load_from_file (path);
                var o = p.get_root ().get_object ();
                if (o.has_member ("rules")) {
                    foreach (var n in o.get_array_member ("rules").get_elements ()) rules.add (Rule.from_json (n.get_object ()));
                }
                if (o.has_member ("quick-steps")) {
                    foreach (var n in o.get_array_member ("quick-steps").get_elements ()) {
                        var so = n.get_object ();
                        var q = new QuickStep ();
                        q.id = so.get_string_member ("id");
                        q.name = so.get_string_member ("name");
                        foreach (var an in so.get_array_member ("actions").get_elements ()) {
                            var ao = an.get_object ();
                            q.actions.add (new RuleAction (ao.get_string_member ("kind"), ao.has_member ("value") ? ao.get_string_member ("value") : ""));
                        }
                        steps.add (q);
                    }
                }
            } catch (Error e) {
                warning ("lettere: rules: %s", e.message);
            }
        }

        private void default_steps () {
            var done = new QuickStep ();
            done.id = "done";
            done.name = _("Done");
            done.actions.add (new RuleAction ("read", ""));
            done.actions.add (new RuleAction ("archive", ""));
            steps.add (done);
            var later = new QuickStep ();
            later.id = "later";
            later.name = _("Deal With Later");
            later.actions.add (new RuleAction ("flag", ""));
            later.actions.add (new RuleAction ("snooze", ""));
            steps.add (later);
        }

        private static bool remap_actions (Gee.List<RuleAction> actions, Gee.Map<string, string> moved) {
            bool changed = false;
            foreach (var a in actions) {
                if ((a.kind == "move" || a.kind == "copy") && moved.has_key (a.value)) {
                    a.value = moved[a.value];
                    changed = true;
                }
            }
            return changed;
        }

        public bool remap_folders (string account, Gee.Map<string, string> moved) {
            bool changed = false;
            foreach (var r in rules) {
                if ((r.account == "" || r.account == account) && remap_actions (r.actions, moved)) changed = true;
            }
            foreach (var s in steps) {
                if (remap_actions (s.actions, moved)) changed = true;
            }
            if (changed) {
                save ();
                this.changed ();
            }
            return changed;
        }

        public void save () {
            var b = new Json.Builder ();
            b.begin_object ();
            b.set_member_name ("rules");
            b.begin_array ();
            foreach (var r in rules) b.add_value (r.to_json ());
            b.end_array ();
            b.set_member_name ("quick-steps");
            b.begin_array ();
            foreach (var q in steps) {
                b.begin_object ();
                b.set_member_name ("id").add_string_value (q.id);
                b.set_member_name ("name").add_string_value (q.name);
                b.set_member_name ("actions");
                b.begin_array ();
                foreach (var a in q.actions) {
                    b.begin_object ();
                    b.set_member_name ("kind").add_string_value (a.kind);
                    b.set_member_name ("value").add_string_value (a.value);
                    b.end_object ();
                }
                b.end_array ();
                b.end_object ();
            }
            b.end_array ();
            b.end_object ();
            var g = new Json.Generator ();
            g.pretty = true;
            g.set_root (b.get_root ());
            try {
                DirUtils.create_with_parents (Path.get_dirname (path), 0700);
                FileUtils.set_contents (path, g.to_data (null));
            } catch (Error e) {
                warning ("lettere: rules: %s", e.message);
            }
            changed ();
        }

        public Rule? find (string id) {
            foreach (var r in rules) if (r.id == id) return r;
            return null;
        }

        public void add (Rule r) {
            if (r.id == "") r.id = Uuid.string_random ().substring (0, 8);
            rules.add (r);
            save ();
        }

        public void remove (Rule r) {
            rules.remove (r);
            save ();
        }

        public Gee.ArrayList<RuleAction> evaluate (MessageInfo m, MimeMessage? mime, bool client_only) {
            var result = new Gee.ArrayList<RuleAction> ();
            foreach (var r in rules) {
                if (client_only && r.on_server) continue;
                if (!r.matches (m, mime)) continue;
                result.add_all (r.actions);
                if (r.stop) break;
            }
            return result;
        }

        public bool any_needs_body () {
            foreach (var r in rules) if (r.enabled && r.needs_body ()) return true;
            return false;
        }

        public string to_sieve (string account_id, Gee.Map<string, string> folder_paths) {
            var sb = new StringBuilder ();
            var req = new Gee.TreeSet<string> ();
            foreach (var r in rules) {
                if (!r.enabled || !r.on_server) continue;
                if (r.account != "" && r.account != account_id) continue;
                var tests = new Gee.ArrayList<string> ();
                foreach (var c in r.conditions) {
                    string? t = sieve_test (c, req);
                    if (t != null) tests.add (t);
                }
                var acts = new Gee.ArrayList<string> ();
                foreach (var a in r.actions) {
                    string? s = sieve_action (a, folder_paths, req);
                    if (s != null) acts.add (s);
                }
                if (acts.size == 0) continue;
                if (r.stop) acts.add ("stop;");
                string cond = "true";
                if (tests.size == 1) cond = tests[0];
                else if (tests.size > 1) cond = "%s (%s)".printf (r.match_all ? "allof" : "anyof", string.joinv (", ", tests.to_array ()));
                sb.append ("if %s {\n    %s\n}\n".printf (cond, string.joinv ("\n    ", acts.to_array ())));
            }
            if (sb.len == 0) return "";
            var q = new Gee.ArrayList<string> ();
            foreach (string r in req) q.add (SieveScript.str (r));
            return (q.size > 0 ? "require [" + string.joinv (", ", q.to_array ()) + "];\n" : "") + sb.str;
        }

        private static string match_tag (string op) {
            switch (op) {
                case "is": return ":is";
                case "regex": return ":regex";
                default: return ":contains";
            }
        }

        private static string? sieve_test (RuleCondition c, Gee.Set<string> req) {
            string value = c.value;
            if (c.op == "starts") value = value + "*";
            if (c.op == "ends") value = "*" + value;
            string tag = (c.op == "starts" || c.op == "ends") ? ":matches" : match_tag (c.op);
            if (c.op == "regex") req.add ("regex");
            string? t = null;
            switch (c.field) {
                case "from": t = "address %s \"from\" %s".printf (tag, SieveScript.str (value)); break;
                case "to": t = "address %s \"to\" %s".printf (tag, SieveScript.str (value)); break;
                case "cc": t = "address %s \"cc\" %s".printf (tag, SieveScript.str (value)); break;
                case "recipients": t = "address %s [\"to\", \"cc\"] %s".printf (tag, SieveScript.str (value)); break;
                case "subject": t = "header %s \"subject\" %s".printf (tag, SieveScript.str (value)); break;
                case "list-id": t = "header %s \"list-id\" %s".printf (tag, SieveScript.str (value)); break;
                case "body":
                    req.add ("body");
                    t = "body :text %s %s".printf (tag, SieveScript.str (value));
                    break;
                case "size-larger": t = "size :over %s".printf (SearchQuery.parse_size (c.value).to_string ()); break;
                case "size-smaller": t = "size :under %s".printf (SearchQuery.parse_size (c.value).to_string ()); break;
                case "has-attachment": t = "header :contains \"content-type\" \"multipart/mixed\""; break;
                case "importance":
                    t = c.value == "high" ? "anyof (header :is \"importance\" \"high\", header :matches \"x-priority\" \"1*\")" : "header :is \"importance\" %s".printf (SieveScript.str (c.value));
                    break;
                case "all": t = "true"; break;
            }
            if (t == null && c.field.has_prefix ("header:")) t = "header %s %s %s".printf (tag, SieveScript.str (c.field.substring (7)), SieveScript.str (value));
            if (t != null && c.op == "not-contains") t = "not " + t;
            return t;
        }

        private static string? sieve_action (RuleAction a, Gee.Map<string, string> folders, Gee.Set<string> req) {
            switch (a.kind) {
                case "move":
                case "archive":
                case "junk":
                case "delete": {
                    string key = a.kind == "move" ? a.value : a.kind == "archive" ? "role:archive" : a.kind == "junk" ? "role:junk" : "role:trash";
                    string? path = folders[key];
                    if (path == null) path = a.value;
                    if (path == null || path == "") return null;
                    req.add ("fileinto");
                    return "fileinto %s;".printf (SieveScript.str (path));
                }
                case "copy": {
                    string? path = folders[a.value] ?? a.value;
                    req.add ("fileinto");
                    req.add ("copy");
                    return "fileinto :copy %s;".printf (SieveScript.str (path));
                }
                case "read":
                    req.add ("imap4flags");
                    return "addflag \"\\\\Seen\";";
                case "flag":
                    req.add ("imap4flags");
                    return "addflag \"\\\\Flagged\";";
                case "pin":
                    req.add ("imap4flags");
                    return "addflag \"$Pinned\";";
                case "category":
                    req.add ("imap4flags");
                    return "addflag %s;".printf (SieveScript.str (Keywords.to_keyword (a.value)));
                case "forward":
                    req.add ("copy");
                    return "redirect :copy %s;".printf (SieveScript.str (a.value));
                case "redirect":
                    return "redirect %s;".printf (SieveScript.str (a.value));
            }
            return null;
        }
    }

    public class JunkFilter : Object {
        private Store store;

        public JunkFilter (Store store) {
            this.store = store;
        }

        public static Gee.HashSet<string> tokens (MessageInfo m, string body) {
            var set = new Gee.HashSet<string> ();
            add_words (set, m.subject, "s:");
            add_words (set, body, "");
            string email = m.sender_email.down ();
            if (email.contains ("@")) set.add ("d:" + email.substring (email.index_of_char ('@') + 1));
            set.add ("f:" + email);
            if (m.has_attachment) set.add ("x:attach");
            if (m.list_unsubscribe != "") set.add ("x:list");
            return set;
        }

        private static void add_words (Gee.Set<string> set, string text, string prefix) {
            var sb = new StringBuilder ();
            unichar c;
            int i = 0;
            int count = 0;
            string low = text.down ();
            while (low.get_next_char (ref i, out c)) {
                if (c.isalnum () || c == '$' || c == '€' || c == '!' || c == '\'') {
                    sb.append_unichar (c);
                    continue;
                }
                if (sb.len >= 3 && sb.len <= 24) {
                    set.add (prefix + sb.str);
                    if (++count > 400) return;
                }
                sb.truncate (0);
            }
            if (sb.len >= 3 && sb.len <= 24) set.add (prefix + sb.str);
        }

        public void train (MessageInfo m, string body, bool junk) {
            store.learn_tokens (tokens (m, body), junk, 1);
        }

        public void untrain (MessageInfo m, string body, bool junk) {
            store.learn_tokens (tokens (m, body), junk, -1);
        }

        public double score (MessageInfo m, string body) {
            double ngood = double.max (1, double.parse (store.get_value ("", "junk-good") ?? "0"));
            double nbad = double.max (1, double.parse (store.get_value ("", "junk-bad") ?? "0"));
            var probs = new Gee.ArrayList<double?> ();
            foreach (string t in tokens (m, body)) {
                int g, b;
                store.token_counts (t, out g, out b);
                if (g + b == 0) continue;
                double pb = (b / nbad);
                double pg = (g / ngood);
                double p = pb / (pb + pg);
                double n = g + b;
                p = (0.5 * 1.0 + n * p) / (1.0 + n);
                probs.add (double.min (0.99, double.max (0.01, p)));
            }
            if (probs.size == 0) return 0.5;
            probs.sort ((a, b) => {
                double da = Math.fabs (a - 0.5), db = Math.fabs (b - 0.5);
                return da > db ? -1 : (da < db ? 1 : 0);
            });
            double ln_spam = 0, ln_ham = 0;
            int used = int.min (15, probs.size);
            for (int i = 0; i < used; i++) {
                ln_spam += Math.log (probs[i]);
                ln_ham += Math.log (1 - probs[i]);
            }
            return 1.0 / (1.0 + Math.exp (ln_ham - ln_spam));
        }

        public bool trained {
            get {
                return int64.parse (store.get_value ("", "junk-bad") ?? "0") >= 3 && int64.parse (store.get_value ("", "junk-good") ?? "0") >= 3;
            }
        }
    }
}
