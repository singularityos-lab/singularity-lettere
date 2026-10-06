namespace Singularity.Apps.Lettere {

    public class ThreadInput {
        public int64 id;
        public string message_id;
        public string in_reply_to;
        public string references;
        public string conv = "";

        public ThreadInput (int64 id, string message_id, string in_reply_to, string references) {
            this.id = id;
            this.message_id = message_id;
            this.in_reply_to = in_reply_to;
            this.references = references;
        }
    }

    public class Threader {
        private Gee.HashMap<string, string> parent = new Gee.HashMap<string, string> ();

        private string find (string x) {
            string root = x;
            while (parent.has_key (root) && parent[root] != root) root = parent[root];
            string cur = x;
            while (parent.has_key (cur) && parent[cur] != root) {
                string next = parent[cur];
                parent[cur] = root;
                cur = next;
            }
            return root;
        }

        private void union (string a, string b) {
            if (!parent.has_key (a)) parent[a] = a;
            if (!parent.has_key (b)) parent[b] = b;
            string ra = find (a);
            string rb = find (b);
            if (ra == rb) return;
            if (strcmp (ra, rb) < 0) parent[rb] = ra;
            else parent[ra] = rb;
        }

        public static string key_for (ThreadInput m) {
            return m.message_id != "" ? "<" + m.message_id + ">" : "#" + m.id.to_string ();
        }

        public Gee.HashMap<int64?, string> group (Gee.List<ThreadInput> messages) {
            parent.clear ();
            foreach (var m in messages) {
                string self = key_for (m);
                if (!parent.has_key (self)) parent[self] = self;
                if (m.in_reply_to != "") union (self, "<" + m.in_reply_to + ">");
                if (m.conv != "") union (self, "conv:" + m.conv);
                foreach (string r in m.references.split (" ")) {
                    string t = r.strip ();
                    if (t != "" && t != m.message_id) union (self, "<" + t + ">");
                }
            }
            var result = new Gee.HashMap<int64?, string> ((v) => int64_hash (v), (a, b) => a == b);
            var roots = new Gee.HashMap<string, string> ();
            foreach (var m in messages) {
                string root = find (key_for (m));
                if (!roots.has_key (root)) roots[root] = Checksum.compute_for_string (ChecksumType.SHA1, root).substring (0, 16);
                result[m.id] = roots[root];
            }
            return result;
        }
    }
}
