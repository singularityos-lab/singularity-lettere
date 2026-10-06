namespace Singularity.Apps.Lettere {

    public class NamedItem : Object {
        public string name { get; set; default = ""; }
        public string subject { get; set; default = ""; }
        public string html { get; set; default = ""; }
        public string color { get; set; default = ""; }

        public NamedItem (string name) {
            this.name = name;
        }
    }

    public class ItemStore : Object {
        public signal void changed ();
        public Gee.ArrayList<NamedItem> items = new Gee.ArrayList<NamedItem> ();
        private string path;

        public ItemStore (string dir, string file) {
            path = Path.build_filename (dir, file);
            load ();
        }

        public void load () {
            items.clear ();
            if (!FileUtils.test (path, FileTest.EXISTS)) return;
            try {
                var p = new Json.Parser ();
                p.load_from_file (path);
                foreach (var n in p.get_root ().get_array ().get_elements ()) {
                    var o = n.get_object ();
                    var it = new NamedItem (Js.str (o, "name"));
                    it.subject = Js.str (o, "subject");
                    it.html = Js.str (o, "html");
                    it.color = Js.str (o, "color");
                    if (it.name != "") items.add (it);
                }
            } catch (Error e) {
                warning ("lettere: %s: %s", path, e.message);
            }
        }

        public void save () {
            var b = new Json.Builder ();
            b.begin_array ();
            foreach (var it in items) {
                b.begin_object ();
                b.set_member_name ("name").add_string_value (it.name);
                if (it.subject != "") b.set_member_name ("subject").add_string_value (it.subject);
                if (it.html != "") b.set_member_name ("html").add_string_value (it.html);
                if (it.color != "") b.set_member_name ("color").add_string_value (it.color);
                b.end_object ();
            }
            b.end_array ();
            var g = new Json.Generator ();
            g.pretty = true;
            g.set_root (b.get_root ());
            try {
                DirUtils.create_with_parents (Path.get_dirname (path), 0700);
                FileUtils.set_contents (path, g.to_data (null));
            } catch (Error e) {
                warning ("lettere: %s: %s", path, e.message);
            }
            changed ();
        }

        public NamedItem? find (string name) {
            foreach (var it in items) if (it.name.down () == name.down ()) return it;
            return null;
        }

        public NamedItem put (string name) {
            var it = find (name);
            if (it == null) {
                it = new NamedItem (name);
                items.add (it);
            }
            return it;
        }

        public void remove (string name) {
            var it = find (name);
            if (it != null) items.remove (it);
            save ();
        }
    }

    public class CategoryStore : ItemStore {
        public const string[] PALETTE = { "#e01b24", "#ff7800", "#f6d32d", "#33d17a", "#3584e4", "#9141ac", "#865e3c", "#77767b" };

        public CategoryStore (string dir) {
            base (dir, "categories.json");
            if (items.size == 0) {
                string[] names = { _("Red Category"), _("Orange Category"), _("Yellow Category"), _("Green Category"), _("Blue Category"), _("Purple Category") };
                for (int i = 0; i < names.length; i++) {
                    var it = new NamedItem (names[i]);
                    it.color = PALETTE[i];
                    items.add (it);
                }
            }
        }

        public string color_of (string name) {
            var it = find (name);
            if (it != null && it.color != "") return it.color;
            uint h = str_hash (name.down ());
            return PALETTE[h % PALETTE.length];
        }

        public void ensure (string name) {
            if (find (name) != null) return;
            var it = new NamedItem (name);
            it.color = color_of (name);
            items.add (it);
            save ();
        }
    }
}
