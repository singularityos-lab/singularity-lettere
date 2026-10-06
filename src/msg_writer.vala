namespace Singularity.Apps.Lettere {

    public class CfbNode {
        public string name;
        public bool storage;
        public uint8[] data = {};
        public Gee.ArrayList<CfbNode> children = new Gee.ArrayList<CfbNode> ();
        public int id;
        public int left = -1;
        public int right = -1;
        public int child = -1;
        public bool red;
        public uint32 start = 0xFFFFFFFEU;

        public CfbNode (string name, bool storage) {
            this.name = name;
            this.storage = storage;
        }

        public CfbNode add_storage (string n) {
            var c = new CfbNode (n, true);
            children.add (c);
            return c;
        }

        public void add_stream (string n, uint8[] d) {
            var c = new CfbNode (n, false);
            c.data = d;
            children.add (c);
        }
    }

    public class CfbWriter : Object {
        private const uint32 FREE = 0xFFFFFFFFU;
        private const uint32 END = 0xFFFFFFFEU;
        private const uint32 FATSECT = 0xFFFFFFFDU;
        public CfbNode root = new CfbNode ("Root Entry", true);
        private Gee.ArrayList<CfbNode> flat = new Gee.ArrayList<CfbNode> ();
        private ByteArray sectors;
        private Gee.ArrayList<uint32> fat;

        private uint32 alloc (uint8[] d) {
            if (d.length == 0) return END;
            uint32 first = (uint32) fat.size;
            int count = (d.length + 511) / 512;
            for (int i = 0; i < count; i++) fat.add (i == count - 1 ? END : first + i + 1);
            sectors.append (d);
            while (sectors.len % 512 != 0) sectors.append ({ 0 });
            return first;
        }

        private static int compare (CfbNode a, CfbNode b) {
            int la = a.name.length, lb = b.name.length;
            if (la != lb) return la - lb;
            return strcmp (a.name.up (), b.name.up ());
        }

        private void number (CfbNode n) {
            n.id = flat.size;
            flat.add (n);
            foreach (var c in n.children) number (c);
        }

        private int build (Gee.List<CfbNode> sorted, int lo, int hi, int depth, int red_depth) {
            if (lo > hi) return -1;
            int mid = (lo + hi) / 2;
            var n = sorted[mid];
            n.red = depth == red_depth;
            n.left = build (sorted, lo, mid - 1, depth + 1, red_depth);
            n.right = build (sorted, mid + 1, hi, depth + 1, red_depth);
            return n.id;
        }

        private void link (CfbNode n) {
            if (n.children.size == 0) return;
            var sorted = new Gee.ArrayList<CfbNode> ();
            sorted.add_all (n.children);
            sorted.sort (compare);
            int count = sorted.size;
            int full = 0;
            int levels = 0;
            while (full < count) {
                full = full * 2 + 1;
                levels++;
            }
            int red_depth = full == count ? -1 : levels - 1;
            n.child = build (sorted, 0, count - 1, 0, red_depth);
            foreach (var c in n.children) link (c);
        }

        private static void put16 (uint8[] b, int o, uint v) {
            b[o] = (uint8) v;
            b[o + 1] = (uint8) (v >> 8);
        }

        private static void put32 (uint8[] b, int o, uint32 v) {
            b[o] = (uint8) v;
            b[o + 1] = (uint8) (v >> 8);
            b[o + 2] = (uint8) (v >> 16);
            b[o + 3] = (uint8) (v >> 24);
        }

        public uint8[] write () {
            flat.clear ();
            number (root);
            link (root);
            sectors = new ByteArray ();
            fat = new Gee.ArrayList<uint32> ();
            var mini = new ByteArray ();
            var minifat = new Gee.ArrayList<uint32> ();
            foreach (var n in flat) {
                if (n.storage || n.data.length == 0) continue;
                if (n.data.length < 4096) {
                    n.start = (uint32) (mini.len / 64);
                    int count = (n.data.length + 63) / 64;
                    for (int i = 0; i < count; i++) minifat.add (i == count - 1 ? END : n.start + i + 1);
                    mini.append (n.data);
                    while (mini.len % 64 != 0) mini.append ({ 0 });
                }
            }
            foreach (var n in flat) {
                if (!n.storage && n.data.length >= 4096) n.start = alloc (n.data);
            }
            root.start = alloc (mini.data);
            var mf = new uint8[minifat.size * 4];
            for (int i = 0; i < minifat.size; i++) put32 (mf, i * 4, minifat[i]);
            uint32 minifat_start = alloc (mf);
            var dir = new uint8[((flat.size + 3) / 4) * 4 * 128];
            for (int i = flat.size; i < dir.length / 128; i++) {
                put32 (dir, i * 128 + 68, FREE);
                put32 (dir, i * 128 + 72, FREE);
                put32 (dir, i * 128 + 76, FREE);
            }
            foreach (var n in flat) {
                int o = n.id * 128;
                int k = 0;
                unichar c;
                int idx = 0;
                while (n.name.get_next_char (ref idx, out c) && k < 31) {
                    put16 (dir, o + k * 2, (uint) c);
                    k++;
                }
                put16 (dir, o + 64, (uint) ((k + 1) * 2));
                dir[o + 66] = n == root ? 5 : (n.storage ? 1 : 2);
                dir[o + 67] = n.red ? 0 : 1;
                put32 (dir, o + 68, n.left < 0 ? FREE : n.left);
                put32 (dir, o + 72, n.right < 0 ? FREE : n.right);
                put32 (dir, o + 76, n.child < 0 ? FREE : n.child);
                if (n == root) {
                    put32 (dir, o + 116, mini.len > 0 ? root.start : END);
                    put32 (dir, o + 120, (uint32) mini.len);
                } else if (!n.storage) {
                    put32 (dir, o + 116, n.data.length > 0 ? n.start : END);
                    put32 (dir, o + 120, n.data.length);
                }
            }
            uint32 dir_start = alloc (dir);
            int fat_sectors = 1;
            while ((fat.size + fat_sectors) > fat_sectors * 128) fat_sectors++;
            uint32 fat_first = (uint32) fat.size;
            for (int i = 0; i < fat_sectors; i++) fat.add (FATSECT);
            while (fat.size % 128 != 0) fat.add (FREE);
            var fatb = new uint8[fat.size * 4];
            for (int i = 0; i < fat.size; i++) put32 (fatb, i * 4, fat[i]);
            var header = new uint8[512];
            uint8[] magic = { 0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1 };
            for (int i = 0; i < 8; i++) header[i] = magic[i];
            put16 (header, 0x18, 0x3E);
            put16 (header, 0x1A, 3);
            put16 (header, 0x1C, 0xFFFE);
            put16 (header, 0x1E, 9);
            put16 (header, 0x20, 6);
            put32 (header, 0x2C, fat_sectors);
            put32 (header, 0x30, dir_start);
            put32 (header, 0x38, 4096);
            put32 (header, 0x3C, minifat.size > 0 ? minifat_start : END);
            put32 (header, 0x40, (uint32) ((mf.length + 511) / 512));
            put32 (header, 0x44, END);
            put32 (header, 0x48, 0);
            for (int i = 0; i < 109; i++) put32 (header, 0x4C + i * 4, i < fat_sectors ? fat_first + i : FREE);
            var outb = new ByteArray ();
            outb.append (header);
            outb.append (sectors.data);
            outb.append (fatb);
            return outb.steal ();
        }
    }

    namespace MsgWriter {
        private uint8[] utf16 (string s) {
            var b = new ByteArray ();
            unichar c;
            int i = 0;
            while (s.get_next_char (ref i, out c)) {
                if (c >= 0x10000) {
                    uint v = c - 0x10000;
                    uint hi = 0xD800 + (v >> 10), lo = 0xDC00 + (v & 0x3FF);
                    b.append ({ (uint8) hi, (uint8) (hi >> 8), (uint8) lo, (uint8) (lo >> 8) });
                } else {
                    b.append ({ (uint8) c, (uint8) (c >> 8) });
                }
            }
            b.append ({ 0, 0 });
            return b.steal ();
        }

        private class Props {
            public ByteArray table = new ByteArray ();
            public CfbNode storage;

            public Props (CfbNode storage, uint8[] header) {
                this.storage = storage;
                table.append (header);
            }

            private void entry (uint16 id, uint16 type, uint8[] value8) {
                var e = new uint8[16];
                uint32 tag = ((uint32) id << 16) | type;
                e[0] = (uint8) tag;
                e[1] = (uint8) (tag >> 8);
                e[2] = (uint8) (tag >> 16);
                e[3] = (uint8) (tag >> 24);
                e[4] = 6;
                for (int i = 0; i < 8 && i < value8.length; i++) e[8 + i] = value8[i];
                table.append (e);
            }

            public void str (uint16 id, string v) {
                if (v == "") return;
                var d = utf16 (v);
                uint32 n = d.length;
                entry (id, 0x001F, { (uint8) n, (uint8) (n >> 8), (uint8) (n >> 16), (uint8) (n >> 24) });
                storage.add_stream ("__substg1.0_%04X001F".printf (id), d[0:d.length - 2]);
            }

            public void blob (uint16 id, uint8[] d) {
                blob_typed (id, 0x0102, d);
            }

            private void blob_typed (uint16 id, uint16 type, uint8[] d) {
                uint32 n = d.length;
                entry (id, type, { (uint8) n, (uint8) (n >> 8), (uint8) (n >> 16), (uint8) (n >> 24) });
                storage.add_stream ("__substg1.0_%04X%04X".printf (id, type), d);
            }

            public void put_int (uint16 id, int32 v) {
                entry (id, 0x0003, { (uint8) v, (uint8) (v >> 8), (uint8) (v >> 16), (uint8) (v >> 24) });
            }

            public void put_time (uint16 id, int64 seconds) {
                uint64 ft = (uint64) seconds * 10000000 + 116444736000000000;
                entry (id, 0x0040, { (uint8) ft, (uint8) (ft >> 8), (uint8) (ft >> 16), (uint8) (ft >> 24), (uint8) (ft >> 32), (uint8) (ft >> 40), (uint8) (ft >> 48), (uint8) (ft >> 56) });
            }

            public void put_object (uint16 id) {
                entry (id, 0x000D, { 0xFF, 0xFF, 0xFF, 0xFF });
            }

            public void finish () {
                storage.add_stream ("__properties_version1.0", table.data);
            }
        }

        private uint8[] header (int size, int recipients, int attachments) {
            var h = new uint8[size];
            if (size >= 24) {
                h[8] = (uint8) recipients;
                h[12] = (uint8) attachments;
                h[16] = (uint8) recipients;
                h[20] = (uint8) attachments;
            }
            return h;
        }

        private string raw_headers (uint8[] raw) {
            string s = Mime.bytes_to_string (raw);
            int end = s.index_of ("\r\n\r\n");
            if (end < 0) end = s.index_of ("\n\n");
            return end > 0 ? s.substring (0, end + 2) : "";
        }

        private void message (CfbNode storage, uint8[] raw, int header_size, int depth) {
            var msg = new MimeMessage (raw);
            var atts = msg.attachments;
            var p = new Props (storage, header (header_size, msg.to.size + msg.cc.size, atts.size));
            p.str (Mapi.MESSAGE_CLASS, "IPM.Note");
            p.put_int (0x340D, 0x00040000);
            p.str (Mapi.SUBJECT, msg.subject);
            p.str (0x0E1D, msg.subject);
            var from = msg.from;
            if (from.size > 0) {
                p.str (Mapi.SENDER_NAME, from[0].name != "" ? from[0].name : from[0].email);
                p.str (Mapi.SENDER_EMAIL, from[0].email);
                p.str (Mapi.SENDER_ADDRTYPE, "SMTP");
                p.str (Mapi.SENDER_SMTP, from[0].email);
                p.str (Mapi.SENT_REPR_NAME, from[0].name != "" ? from[0].name : from[0].email);
                p.str (Mapi.SENT_REPR_EMAIL, from[0].email);
                p.str (0x0064, "SMTP");
            }
            p.str (Mapi.DISPLAY_TO, Mime.display_addresses (msg.to));
            p.str (Mapi.DISPLAY_CC, Mime.display_addresses (msg.cc));
            var d = msg.date;
            int64 t = d != null ? d.to_unix () : new DateTime.now_utc ().to_unix ();
            p.put_time (Mapi.DELIVERY_TIME, t);
            p.put_time (Mapi.CLIENT_SUBMIT_TIME, t);
            p.put_int (Mapi.MESSAGE_FLAGS, 1);
            p.put_int (Mapi.IMPORTANCE, Mime.importance_of (msg.root) + 1);
            p.str (Mapi.BODY, msg.body_text ());
            if (msg.text_html != "") p.blob (Mapi.HTML, msg.text_html.data);
            p.str (Mapi.INTERNET_MESSAGE_ID, msg.message_id != "" ? "<" + msg.message_id + ">" : "");
            p.str (Mapi.IN_REPLY_TO, msg.in_reply_to != "" ? "<" + msg.in_reply_to + ">" : "");
            p.str (Mapi.TRANSPORT_HEADERS, raw_headers (raw));
            int ri = 0;
            foreach (var kind in new int[] { 1, 2 }) {
                foreach (var a in kind == 1 ? msg.to : msg.cc) {
                    var rs = storage.add_storage ("__recip_version1.0_#%08X".printf (ri));
                    var rp = new Props (rs, new uint8[8]);
                    rp.put_int (0x3000, ri);
                    rp.put_int (Mapi.RECIPIENT_TYPE, kind);
                    rp.str (Mapi.DISPLAY_NAME, a.name != "" ? a.name : a.email);
                    rp.str (Mapi.EMAIL_ADDRESS, a.email);
                    rp.str (Mapi.ADDRTYPE, "SMTP");
                    rp.str (Mapi.SMTP_ADDRESS, a.email);
                    rp.finish ();
                    ri++;
                }
            }
            for (int i = 0; i < atts.size; i++) {
                var a = atts[i];
                var st = storage.add_storage ("__attach_version1.0_#%08X".printf (i));
                var ap = new Props (st, new uint8[8]);
                ap.put_int (0x0E21, i);
                ap.put_int (0x370B, -1);
                ap.str (Mapi.ATTACH_LONG_FILENAME, a.filename);
                ap.str (Mapi.ATTACH_FILENAME, a.filename);
                ap.str (Mapi.DISPLAY_NAME, a.filename);
                ap.str (Mapi.ATTACH_MIME, a.content_type);
                if (a.content_id != "") ap.str (Mapi.ATTACH_CONTENT_ID, a.content_id);
                if (a.content_type == "message/rfc822" && depth < 4) {
                    ap.put_int (Mapi.ATTACH_METHOD, 5);
                    ap.put_object (Mapi.ATTACH_DATA);
                    var inner = st.add_storage ("__substg1.0_3701000D");
                    message (inner, a.data.get_data (), 24, depth + 1);
                } else {
                    ap.put_int (Mapi.ATTACH_METHOD, 1);
                    ap.blob (Mapi.ATTACH_DATA, a.data.get_data ());
                }
                ap.finish ();
            }
            p.finish ();
        }

        public uint8[] from_mime (uint8[] raw) {
            var w = new CfbWriter ();
            var names = w.root.add_storage ("__nameid_version1.0");
            names.add_stream ("__substg1.0_00020102", {});
            names.add_stream ("__substg1.0_00030102", {});
            names.add_stream ("__substg1.0_00040102", {});
            message (w.root, raw, 32, 0);
            return w.write ();
        }
    }
}
