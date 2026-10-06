namespace Singularity.Apps.Lettere {

    public class ContactGroup : Object {
        public string name { get; set; default = ""; }
        public Gee.ArrayList<Address> members = new Gee.ArrayList<Address> ();

        public ContactGroup (string name) {
            this.name = name;
        }
    }

    public class ContactBook : Object {
        public Gee.ArrayList<Address> entries = new Gee.ArrayList<Address> ();
        public Gee.ArrayList<ContactGroup> groups = new Gee.ArrayList<ContactGroup> ();
        public Gee.ArrayList<string> extra_dirs = new Gee.ArrayList<string> ();
        private Gee.ArrayList<string> dirs = new Gee.ArrayList<string> ();
        private int64 loaded_at;

        public ContactBook () {
            dirs.add (Path.build_filename (Environment.get_user_data_dir (), "singularity", "contacts"));
            dirs.add (Path.build_filename (Environment.get_user_cache_dir (), "singularity-contacts"));
        }

        public ContactBook.with_dirs (string[] paths) {
            foreach (string p in paths) dirs.add (p);
        }

        private class Card {
            public string name = "";
            public string uid = "";
            public string kind = "";
            public Gee.ArrayList<string> emails = new Gee.ArrayList<string> ();
            public Gee.ArrayList<string> categories = new Gee.ArrayList<string> ();
            public Gee.ArrayList<string> members = new Gee.ArrayList<string> ();
        }

        private static Gee.ArrayList<Card> cards (string text) {
            var list = new Gee.ArrayList<Card> ();
            string unfolded = text.replace ("\r\n", "\n").replace ("\n ", "").replace ("\n\t", "");
            Card? cur = null;
            foreach (string line in unfolded.split ("\n")) {
                string up = line.up ();
                if (up.has_prefix ("BEGIN:VCARD")) {
                    cur = new Card ();
                    continue;
                }
                if (up.has_prefix ("END:VCARD")) {
                    if (cur != null) list.add (cur);
                    cur = null;
                    continue;
                }
                if (cur == null) continue;
                int colon = line.index_of_char (':');
                if (colon < 0) continue;
                string key = up.substring (0, colon);
                int semi = key.index_of_char (';');
                string prop = semi >= 0 ? key.substring (0, semi) : key;
                int dot = prop.index_of_char ('.');
                if (dot >= 0) prop = prop.substring (dot + 1);
                string raw = line.substring (colon + 1).strip ();
                string value = raw.replace ("\\,", ",").replace ("\\;", ";").replace ("\\\\", "\\");
                switch (prop) {
                    case "FN": cur.name = value; break;
                    case "UID": cur.uid = value; break;
                    case "KIND":
                    case "X-ADDRESSBOOKSERVER-KIND": cur.kind = value.down (); break;
                    case "EMAIL": if (value.contains ("@")) cur.emails.add (value); break;
                    case "CATEGORIES":
                        foreach (string c in raw.split (",")) {
                            string t = c.replace ("\\;", ";").strip ();
                            if (t != "") cur.categories.add (t);
                        }
                        break;
                    case "MEMBER":
                    case "X-ADDRESSBOOKSERVER-MEMBER": cur.members.add (value); break;
                }
            }
            return list;
        }

        public static Gee.ArrayList<Address> parse_vcards (string text) {
            var list = new Gee.ArrayList<Address> ();
            foreach (var c in cards (text)) {
                foreach (string e in c.emails) list.add (new Address (c.name, e));
            }
            return list;
        }

        private void take (string text, Gee.List<Card> all) {
            foreach (var c in cards (text)) {
                all.add (c);
                foreach (string e in c.emails) entries.add (new Address (c.name, e));
            }
        }

        private void scan_accounts (string dir, Gee.List<Card> all) {
            try {
                var d = Dir.open (dir);
                string? acc;
                while ((acc = d.read_name ()) != null) {
                    string cdir = Path.build_filename (dir, acc, "contacts");
                    if (!FileUtils.test (cdir, FileTest.IS_DIR)) continue;
                    var cd = Dir.open (cdir);
                    string? n;
                    while ((n = cd.read_name ()) != null) {
                        if (!n.has_suffix (".json")) continue;
                        try {
                            var p = new Json.Parser ();
                            p.load_from_file (Path.build_filename (cdir, n));
                            var items = Js.arr (p.get_root ().get_object (), "items");
                            if (items == null) continue;
                            foreach (var it in items.get_elements ()) {
                                var o = it.get_object ();
                                if (Js.str (o, "state") == "deleted") continue;
                                take (Js.str (o, "data"), all);
                            }
                        } catch (Error e) {
                        }
                    }
                }
            } catch (Error e) {
            }
        }

        public void load () {
            int64 now = get_monotonic_time ();
            if (loaded_at != 0 && now - loaded_at < 30 * TimeSpan.SECOND) return;
            loaded_at = now;
            entries.clear ();
            groups.clear ();
            var all = new Gee.ArrayList<Card> ();
            foreach (string dir in dirs) {
                try {
                    var d = Dir.open (dir);
                    string? n;
                    while ((n = d.read_name ()) != null) {
                        if (!n.has_suffix (".vcf")) continue;
                        string text;
                        FileUtils.get_contents (Path.build_filename (dir, n), out text);
                        take (text, all);
                    }
                } catch (Error e) {
                }
            }
            foreach (string dir in extra_dirs) scan_accounts (dir, all);
            var by_uid = new Gee.HashMap<string, Card> ();
            foreach (var c in all) if (c.uid != "") by_uid[c.uid.down ()] = c;
            var by_cat = new Gee.HashMap<string, ContactGroup> ();
            foreach (var c in all) {
                if (c.kind == "group") {
                    var g = new ContactGroup (c.name);
                    foreach (string m in c.members) {
                        string key = m.down ();
                        if (key.has_prefix ("mailto:")) {
                            g.members.add (new Address ("", m.substring (7)));
                            continue;
                        }
                        if (key.has_prefix ("urn:uuid:")) key = key.substring (9);
                        var member = by_uid[key];
                        if (member != null && member.emails.size > 0) g.members.add (new Address (member.name, member.emails[0]));
                    }
                    if (g.members.size > 0) groups.add (g);
                    continue;
                }
                foreach (string cat in c.categories) {
                    if (c.emails.size == 0) continue;
                    var g = by_cat[cat.down ()];
                    if (g == null) {
                        g = new ContactGroup (cat);
                        by_cat[cat.down ()] = g;
                        groups.add (g);
                    }
                    g.members.add (new Address (c.name, c.emails[0]));
                }
            }
        }

        public Gee.ArrayList<Address> match (string prefix, int limit) {
            var list = new Gee.ArrayList<Address> ();
            string p = prefix.strip ().down ();
            if (p == "") return list;
            load ();
            foreach (var a in entries) {
                string n = a.name.down ();
                if (a.email.down ().has_prefix (p) || n.has_prefix (p) || n.contains (" " + p)) {
                    list.add (a);
                    if (list.size >= limit) break;
                }
            }
            return list;
        }

        public Gee.ArrayList<ContactGroup> match_groups (string prefix) {
            var list = new Gee.ArrayList<ContactGroup> ();
            string p = prefix.strip ().down ();
            if (p == "") return list;
            load ();
            foreach (var g in groups) if (g.name.down ().has_prefix (p) || g.name.down ().contains (" " + p)) list.add (g);
            return list;
        }

        public ContactGroup? group (string name) {
            load ();
            foreach (var g in groups) if (g.name.down () == name.strip ().down ()) return g;
            return null;
        }

        public bool knows (string email) {
            load ();
            foreach (var a in entries) if (a.email.down () == email.down ()) return true;
            return false;
        }

        public void invalidate () {
            loaded_at = 0;
        }
    }
}
