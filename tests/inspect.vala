using Singularity.Apps.Lettere;

void walk (PstFile pst, PstFolder f, int depth, ref int total) {
    stdout.printf ("%s%s (%d)\n", string.nfill (depth * 2, ' '), f.name, f.messages.size);
    total += f.messages.size;
    foreach (var c in f.children) walk (pst, c, depth + 1, ref total);
}

int main (string[] args) {
    if (args.length < 3) return 2;
    try {
        if (args[1] == "msg") {
            uint8[] data;
            FileUtils.get_data (args[2], out data);
            stdout.printf ("%s", (string) MsgFile.to_mime (data));
            return 0;
        }
        if (args[1] == "tomsg") {
            uint8[] data;
            FileUtils.get_data (args[2], out data);
            FileUtils.set_data (args[3], MsgWriter.from_mime (data));
            return 0;
        }
        if (args[1] == "topst") {
            var top = new PstExportFolder ("Export");
            var inbox = new PstExportFolder ("Inbox");
            var sub = new PstExportFolder ("Projects");
            inbox.children.add (sub);
            top.children.add (inbox);
            for (int i = 3; i < args.length; i++) {
                uint8[] data;
                FileUtils.get_data (args[i], out data);
                (i % 2 == 0 ? sub : inbox).add (data, i == 3 ? MessageFlags.SEEN : 0);
            }
            FileUtils.set_data (args[2], new PstWriter ().build (top));
            return 0;
        }
        if (args[1] == "pst") {
            var pst = new PstFile.from_path (args[2]);
            var root = pst.folders ();
            int total = 0;
            walk (pst, root, 0, ref total);
            stdout.printf ("total %d\n", total);
            int shown = 0;
            var stack = new Gee.ArrayList<PstFolder> ();
            stack.add (root);
            while (stack.size > 0 && shown < (args.length > 3 ? int.parse (args[3]) : 3)) {
                var f = stack.remove_at (0);
                stack.add_all (f.children);
                foreach (uint32 nid in f.messages) {
                    if (shown >= (args.length > 3 ? int.parse (args[3]) : 3)) break;
                    var m = new MimeMessage (Mapi.to_mime (pst.bag (nid)));
                    stdout.printf ("--- %s | %s | %d att | %s\n", m.subject, Mime.format_addresses (m.from), m.attachments.size, m.body_text ().substring (0, int.min (60, m.body_text ().length)).replace ("\n", " "));
                    shown++;
                }
            }
        }
    } catch (Error e) {
        stderr.printf ("error: %s\n", e.message);
        return 1;
    }
    return 0;
}
