namespace Singularity.Apps.Lettere {

    namespace Importer {
        private string clean (string name) {
            string n = name.replace ("/", "-").strip ();
            return n != "" ? n : _("Imported");
        }

        private Folder make_folder (Store store, string account, string path, string name, string parent) {
            var f = store.local_folder (account, path, name, "");
            store.rename_folder (f.id, path, name, parent);
            return store.folder (f.id);
        }

        private void add (Store store, Folder f, uint8[] raw, int flags) {
            var part = Mime.parse_part (raw, "1", 0);
            var date = Mime.parse_date (part.header ("Date") ?? "");
            int64 id = store.insert_message (f, store.max_uid (f.id) + 1, flags, raw.length, raw, date != null ? date.to_unix () : new DateTime.now_utc ().to_unix ());
            store.set_body (id, raw);
        }

        private int import_pst_folder (Store store, string account, PstFile pst, PstFolder pf, string parent_path, int depth) {
            int n = 0;
            string path = parent_path != "" ? parent_path + "/" + clean (pf.name) : clean (pf.name);
            bool mail = pf.container_class == "" || pf.container_class.has_prefix ("IPF.Note");
            Folder? f = null;
            if (mail && (pf.messages.size > 0 || pf.children.size > 0)) {
                f = make_folder (store, account, path, clean (pf.name), parent_path);
                store.begin ();
                foreach (uint32 nid in pf.messages) {
                    try {
                        var bag = pst.bag (nid);
                        string cls = bag.str (Mapi.MESSAGE_CLASS);
                        if (cls != "" && !cls.has_prefix ("IPM.Note") && !cls.has_prefix ("IPM.Schedule") && !cls.has_prefix ("REPORT")) continue;
                        var raw = Mapi.to_mime (bag);
                        add (store, f, raw, Mapi.flags_of (bag));
                        n++;
                    } catch (Error e) {
                        warning ("lettere: pst item %u: %s", nid, e.message);
                    }
                }
                store.commit ();
            }
            if (depth < 32) foreach (var c in pf.children) n += import_pst_folder (store, account, pst, c, f != null ? path : parent_path, depth + 1);
            return n;
        }

        public async int import_file (LettereApp app, AccountSync s, File file) throws Error {
            var store = app.store;
            string account = s.account.id;
            string base_name = file.get_basename () ?? "import";
            int dot = base_name.last_index_of_char ('.');
            string stem = dot > 0 ? base_name.substring (0, dot) : base_name;
            string ext = dot > 0 ? base_name.substring (dot + 1).down () : "";
            if (ext == "pst" || ext == "ost") {
                var pst = new PstFile.from_path (file.get_path ());
                var root = pst.folders ();
                string top = clean (stem);
                make_folder (store, account, top, top, "");
                int n = 0;
                foreach (var c in root.children) n += import_pst_folder (store, account, pst, c, top, 1);
                if (root.messages.size > 0) {
                    root.name = _("Messages");
                    root.children.clear ();
                    n += import_pst_folder (store, account, pst, root, top, 1);
                }
                store.folders_changed (account);
                return n;
            }
            uint8[] data;
            string etag;
            yield file.load_contents_async (null, out data, out etag);
            if (ext == "msg" || MsgFile.is_msg (data)) {
                var f = store.folder_by_path (account, _("Imported")) ?? make_folder (store, account, _("Imported"), _("Imported"), "");
                add (store, f, MsgFile.to_mime (data), MessageFlags.SEEN);
                store.folders_changed (account);
                return 1;
            }
            if (ext == "eml" || !(data.length > 5 && data[0] == 'F' && data[1] == 'r' && data[2] == 'o' && data[3] == 'm' && data[4] == ' ')) {
                var f = store.folder_by_path (account, _("Imported")) ?? make_folder (store, account, _("Imported"), _("Imported"), "");
                add (store, f, data, MessageFlags.SEEN);
                store.folders_changed (account);
                return 1;
            }
            string path = clean (stem);
            var folder = store.folder_by_path (account, path) ?? make_folder (store, account, path, path, "");
            int n = 0;
            store.begin ();
            foreach (var msg in Mbox.split (data)) {
                var raw = msg.get_data ();
                int flags = Mbox.flags_of (raw);
                if ((flags & MessageFlags.DELETED) != 0) continue;
                add (store, folder, raw, flags);
                n++;
            }
            store.commit ();
            store.folders_changed (account);
            return n;
        }

        public async int export_mbox (LettereApp app, Folder f, File target) throws Error {
            var s = app.syncs[f.account];
            var stream = yield target.replace_async (null, false, FileCreateFlags.REPLACE_DESTINATION, Priority.DEFAULT, null);
            int n = 0;
            foreach (var m in app.store.folder_messages (f.id)) {
                uint8[]? raw = app.store.body (m.id);
                if (raw == null && s != null) {
                    try {
                        raw = yield s.load_body (m);
                    } catch (Error e) {
                    }
                }
                if (raw == null) continue;
                string entry = Mbox.escape (raw, m.sender_email, m.date);
                size_t written;
                yield stream.write_all_async (entry.data, Priority.DEFAULT, null, out written);
                n++;
            }
            yield stream.close_async ();
            return n;
        }
    
        private async PstExportFolder collect (LettereApp app, Folder f, Gee.List<Folder> all) {
            var out_f = new PstExportFolder (f.display_name);
            var s = app.syncs[f.account];
            foreach (var m in app.store.folder_messages (f.id)) {
                uint8[]? raw = app.store.body (m.id);
                if (raw == null && s != null) {
                    try {
                        raw = yield s.load_body (m);
                    } catch (Error e) {
                    }
                }
                if (raw != null) out_f.add (raw, m.flags);
            }
            foreach (var c in all) {
                if (c.id == f.id) continue;
                string parent = c.parent != "" ? c.parent : (c.delimiter != "" && c.path.contains (c.delimiter) ? c.path.substring (0, c.path.last_index_of (c.delimiter)) : "");
                if (parent == f.path) out_f.children.add (yield collect (app, c, all));
            }
            return out_f;
        }

        public async int export_pst (LettereApp app, Gee.List<Folder> roots, string title, File target) throws Error {
            var top = new PstExportFolder (title);
            int n = 0;
            foreach (var f in roots) {
                var all = app.store.folders (f.account);
                var ef = yield collect (app, f, all);
                n += count (ef);
                top.children.add (ef);
            }
            var data = new PstWriter ().build (top);
            yield target.replace_contents_async (data, null, false, FileCreateFlags.REPLACE_DESTINATION, null, null);
            return n;
        }

        private int count (PstExportFolder f) {
            int n = f.messages.size;
            foreach (var c in f.children) n += count (c);
            return n;
        }
    }
}
