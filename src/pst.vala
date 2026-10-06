namespace Singularity.Apps.Lettere {

    public errordomain PstError {
        FORMAT,
        MISSING
    }

    public class PstNode {
        public uint32 nid;
        public uint64 data_bid;
        public uint64 sub_bid;
        public uint32 parent;
    }

    public class PstFolder {
        public uint32 nid;
        public string name = "";
        public string container_class = "";
        public int count;
        public Gee.ArrayList<PstFolder> children = new Gee.ArrayList<PstFolder> ();
        public Gee.ArrayList<uint32> messages = new Gee.ArrayList<uint32> ();
    }

    public class PstFile : Object {
        private FileInputStream? input;
        private uint8[] owned_data;
        private uint64 file_size;
        public bool unicode;
        public bool large_pages;
        private int crypt;
        private Gee.HashMap<uint64?, uint64?> block_offset = new Gee.HashMap<uint64?, uint64?> ((v) => (uint) (v ^ (v >> 32)), (a, b) => a == b);
        private Gee.HashMap<uint64?, uint32> block_size = new Gee.HashMap<uint64?, uint32> ((v) => (uint) (v ^ (v >> 32)), (a, b) => a == b);
        private Gee.HashMap<uint32, PstNode> nodes = new Gee.HashMap<uint32, PstNode> ();

        private static uint8[] COMPRESSIBLE = {
            0x47, 0xf1, 0xb4, 0xe6, 0x0b, 0x6a, 0x72, 0x48, 0x85, 0x4e, 0x9e, 0xeb, 0xe2, 0xf8, 0x94, 0x53,
            0xe0, 0xbb, 0xa0, 0x02, 0xe8, 0x5a, 0x09, 0xab, 0xdb, 0xe3, 0xba, 0xc6, 0x7c, 0xc3, 0x10, 0xdd,
            0x39, 0x05, 0x96, 0x30, 0xf5, 0x37, 0x60, 0x82, 0x8c, 0xc9, 0x13, 0x4a, 0x6b, 0x1d, 0xf3, 0xfb,
            0x8f, 0x26, 0x97, 0xca, 0x91, 0x17, 0x01, 0xc4, 0x32, 0x2d, 0x6e, 0x31, 0x95, 0xff, 0xd9, 0x23,
            0xd1, 0x00, 0x5e, 0x79, 0xdc, 0x44, 0x3b, 0x1a, 0x28, 0xc5, 0x61, 0x57, 0x20, 0x90, 0x3d, 0x83,
            0xb9, 0x43, 0xbe, 0x67, 0xd2, 0x46, 0x42, 0x76, 0xc0, 0x6d, 0x5b, 0x7e, 0xb2, 0x0f, 0x16, 0x29,
            0x3c, 0xa9, 0x03, 0x54, 0x0d, 0xda, 0x5d, 0xdf, 0xf6, 0xb7, 0xc7, 0x62, 0xcd, 0x8d, 0x06, 0xd3,
            0x69, 0x5c, 0x86, 0xd6, 0x14, 0xf7, 0xa5, 0x66, 0x75, 0xac, 0xb1, 0xe9, 0x45, 0x21, 0x70, 0x0c,
            0x87, 0x9f, 0x74, 0xa4, 0x22, 0x4c, 0x6f, 0xbf, 0x1f, 0x56, 0xaa, 0x2e, 0xb3, 0x78, 0x33, 0x50,
            0xb0, 0xa3, 0x92, 0xbc, 0xcf, 0x19, 0x1c, 0xa7, 0x63, 0xcb, 0x1e, 0x4d, 0x3e, 0x4b, 0x1b, 0x9b,
            0x4f, 0xe7, 0xf0, 0xee, 0xad, 0x3a, 0xb5, 0x59, 0x04, 0xea, 0x40, 0x55, 0x25, 0x51, 0xe5, 0x7a,
            0x89, 0x38, 0x68, 0x52, 0x7b, 0xfc, 0x27, 0xae, 0xd7, 0xbd, 0xfa, 0x07, 0xf4, 0xcc, 0x8e, 0x5f,
            0xef, 0x35, 0x9c, 0x84, 0x2b, 0x15, 0xd5, 0x77, 0x34, 0x49, 0xb6, 0x12, 0x0a, 0x7f, 0x71, 0x88,
            0xfd, 0x9d, 0x18, 0x41, 0x7d, 0x93, 0xd8, 0x58, 0x2c, 0xce, 0xfe, 0x24, 0xaf, 0xde, 0xb8, 0x36,
            0xc8, 0xa1, 0x80, 0xa6, 0x99, 0x98, 0xa8, 0x2f, 0x0e, 0x81, 0x65, 0x73, 0xe4, 0xc2, 0xa2, 0x8a,
            0xd4, 0xe1, 0x11, 0xd0, 0x08, 0x8b, 0x2a, 0xf2, 0xed, 0x9a, 0x64, 0x3f, 0xc1, 0x6c, 0xf9, 0xec
        };

        private static uint8[] HIGH1 = {
            0x41, 0x36, 0x13, 0x62, 0xa8, 0x21, 0x6e, 0xbb, 0xf4, 0x16, 0xcc, 0x04, 0x7f, 0x64, 0xe8, 0x5d,
            0x1e, 0xf2, 0xcb, 0x2a, 0x74, 0xc5, 0x5e, 0x35, 0xd2, 0x95, 0x47, 0x9e, 0x96, 0x2d, 0x9a, 0x88,
            0x4c, 0x7d, 0x84, 0x3f, 0xdb, 0xac, 0x31, 0xb6, 0x48, 0x5f, 0xf6, 0xc4, 0xd8, 0x39, 0x8b, 0xe7,
            0x23, 0x3b, 0x38, 0x8e, 0xc8, 0xc1, 0xdf, 0x25, 0xb1, 0x20, 0xa5, 0x46, 0x60, 0x4e, 0x9c, 0xfb,
            0xaa, 0xd3, 0x56, 0x51, 0x45, 0x7c, 0x55, 0x00, 0x07, 0xc9, 0x2b, 0x9d, 0x85, 0x9b, 0x09, 0xa0,
            0x8f, 0xad, 0xb3, 0x0f, 0x63, 0xab, 0x89, 0x4b, 0xd7, 0xa7, 0x15, 0x5a, 0x71, 0x66, 0x42, 0xbf,
            0x26, 0x4a, 0x6b, 0x98, 0xfa, 0xea, 0x77, 0x53, 0xb2, 0x70, 0x05, 0x2c, 0xfd, 0x59, 0x3a, 0x86,
            0x7e, 0xce, 0x06, 0xeb, 0x82, 0x78, 0x57, 0xc7, 0x8d, 0x43, 0xaf, 0xb4, 0x1c, 0xd4, 0x5b, 0xcd,
            0xe2, 0xe9, 0x27, 0x4f, 0xc3, 0x08, 0x72, 0x80, 0xcf, 0xb0, 0xef, 0xf5, 0x28, 0x6d, 0xbe, 0x30,
            0x4d, 0x34, 0x92, 0xd5, 0x0e, 0x3c, 0x22, 0x32, 0xe5, 0xe4, 0xf9, 0x9f, 0xc2, 0xd1, 0x0a, 0x81,
            0x12, 0xe1, 0xee, 0x91, 0x83, 0x76, 0xe3, 0x97, 0xe6, 0x61, 0x8a, 0x17, 0x79, 0xa4, 0xb7, 0xdc,
            0x90, 0x7a, 0x5c, 0x8c, 0x02, 0xa6, 0xca, 0x69, 0xde, 0x50, 0x1a, 0x11, 0x93, 0xb9, 0x52, 0x87,
            0x58, 0xfc, 0xed, 0x1d, 0x37, 0x49, 0x1b, 0x6a, 0xe0, 0x29, 0x33, 0x99, 0xbd, 0x6c, 0xd9, 0x94,
            0xf3, 0x40, 0x54, 0x6f, 0xf0, 0xc6, 0x73, 0xb8, 0xd6, 0x3e, 0x65, 0x18, 0x44, 0x1f, 0xdd, 0x67,
            0x10, 0xf1, 0x0c, 0x19, 0xec, 0xae, 0x03, 0xa1, 0x14, 0x7b, 0xa9, 0x0b, 0xff, 0xf8, 0xa3, 0xc0,
            0xa2, 0x01, 0xf7, 0x2e, 0xbc, 0x24, 0x68, 0x75, 0x0d, 0xfe, 0xba, 0x2f, 0xb5, 0xd0, 0xda, 0x3d
        };

        private static uint8[] HIGH2 = {
            0x14, 0x53, 0x0f, 0x56, 0xb3, 0xc8, 0x7a, 0x9c, 0xeb, 0x65, 0x48, 0x17, 0x16, 0x15, 0x9f, 0x02,
            0xcc, 0x54, 0x7c, 0x83, 0x00, 0x0d, 0x0c, 0x0b, 0xa2, 0x62, 0xa8, 0x76, 0xdb, 0xd9, 0xed, 0xc7,
            0xc5, 0xa4, 0xdc, 0xac, 0x85, 0x74, 0xd6, 0xd0, 0xa7, 0x9b, 0xae, 0x9a, 0x96, 0x71, 0x66, 0xc3,
            0x63, 0x99, 0xb8, 0xdd, 0x73, 0x92, 0x8e, 0x84, 0x7d, 0xa5, 0x5e, 0xd1, 0x5d, 0x93, 0xb1, 0x57,
            0x51, 0x50, 0x80, 0x89, 0x52, 0x94, 0x4f, 0x4e, 0x0a, 0x6b, 0xbc, 0x8d, 0x7f, 0x6e, 0x47, 0x46,
            0x41, 0x40, 0x44, 0x01, 0x11, 0xcb, 0x03, 0x3f, 0xf7, 0xf4, 0xe1, 0xa9, 0x8f, 0x3c, 0x3a, 0xf9,
            0xfb, 0xf0, 0x19, 0x30, 0x82, 0x09, 0x2e, 0xc9, 0x9d, 0xa0, 0x86, 0x49, 0xee, 0x6f, 0x4d, 0x6d,
            0xc4, 0x2d, 0x81, 0x34, 0x25, 0x87, 0x1b, 0x88, 0xaa, 0xfc, 0x06, 0xa1, 0x12, 0x38, 0xfd, 0x4c,
            0x42, 0x72, 0x64, 0x13, 0x37, 0x24, 0x6a, 0x75, 0x77, 0x43, 0xff, 0xe6, 0xb4, 0x4b, 0x36, 0x5c,
            0xe4, 0xd8, 0x35, 0x3d, 0x45, 0xb9, 0x2c, 0xec, 0xb7, 0x31, 0x2b, 0x29, 0x07, 0x68, 0xa3, 0x0e,
            0x69, 0x7b, 0x18, 0x9e, 0x21, 0x39, 0xbe, 0x28, 0x1a, 0x5b, 0x78, 0xf5, 0x23, 0xca, 0x2a, 0xb0,
            0xaf, 0x3e, 0xfe, 0x04, 0x8c, 0xe7, 0xe5, 0x98, 0x32, 0x95, 0xd3, 0xf6, 0x4a, 0xe8, 0xa6, 0xea,
            0xe9, 0xf3, 0xd5, 0x2f, 0x70, 0x20, 0xf2, 0x1f, 0x05, 0x67, 0xad, 0x55, 0x10, 0xce, 0xcd, 0xe3,
            0x27, 0x3b, 0xda, 0xba, 0xd7, 0xc2, 0x26, 0xd4, 0x91, 0x1d, 0xd2, 0x1c, 0x22, 0x33, 0xf8, 0xfa,
            0xf1, 0x5a, 0xef, 0xcf, 0x90, 0xb6, 0x8b, 0xb5, 0xbd, 0xc0, 0xbf, 0x08, 0x97, 0x1e, 0x6c, 0xe2,
            0x61, 0xe0, 0xc6, 0xc1, 0x59, 0xab, 0xbb, 0x58, 0xde, 0x5f, 0xdf, 0x60, 0x79, 0x7e, 0xb2, 0x8a
        };

        public PstFile.from_path (string path) throws Error {
            var f = File.new_for_path (path);
            input = f.read ();
            file_size = (uint64) f.query_info ("standard::size", 0).get_size ();
            open ();
        }

        public PstFile.from_data (owned uint8[] bytes) throws Error {
            owned_data = (owned) bytes;
            file_size = owned_data.length;
            open ();
        }

        private uint8[] read_at (uint64 off, int len) throws Error {
            if (off + len > file_size) throw new PstError.FORMAT (_("The Outlook data file is truncated"));
            if (input == null) return owned_data[off:off + len];
            input.seek ((int64) off, SeekType.SET);
            var buf = new uint8[len];
            size_t got;
            input.read_all (buf, out got);
            if (got < len) throw new PstError.FORMAT (_("The Outlook data file is truncated"));
            return buf;
        }

        private uint64 ptr_in (uint8[] d, int o) {
            return unicode ? Mapi.u64 (d, o) : Mapi.u32 (d, o);
        }

        private int psize {
            get { return unicode ? 8 : 4; }
        }

        private void open () throws Error {
            if (file_size < 564) throw new PstError.FORMAT (_("This is not an Outlook data file"));
            var h = read_at (0, 564);
            if (Mapi.u32 (h, 0) != 0x4E444221) throw new PstError.FORMAT (_("This is not an Outlook data file"));
            uint16 ver = Mapi.u16 (h, 10);
            if (ver == 14 || ver == 15) {
                unicode = false;
            } else if (ver >= 23) {
                unicode = true;
                large_pages = ver >= 36;
            } else {
                throw new PstError.FORMAT (_("This Outlook data file version (%u) is not supported").printf (ver));
            }
            if (large_pages) throw new PstError.FORMAT (_("Outlook 2013 cache files (.ost with 4 KB pages) are not supported; export a .pst from Outlook instead"));
            uint64 nbt_page, bbt_page;
            if (unicode) {
                nbt_page = Mapi.u64 (h, 224);
                bbt_page = Mapi.u64 (h, 240);
                crypt = h[513];
            } else {
                nbt_page = Mapi.u32 (h, 188);
                bbt_page = Mapi.u32 (h, 196);
                crypt = h[461];
            }
            walk_bbt (bbt_page, 0);
            walk_nbt (nbt_page, 0);
            if (nodes.size == 0) throw new PstError.FORMAT (_("The Outlook data file is damaged"));
        }

        private void walk_bbt (uint64 page, int depth) throws Error {
            if (depth > 16) throw new PstError.FORMAT (_("The Outlook data file is damaged"));
            var p = read_at (page, 512);
            int trailer = unicode ? 488 : 496;
            int count = p[trailer];
            int esize = p[trailer + 2];
            int level = p[trailer + 3];
            for (int i = 0; i < count; i++) {
                int e = i * esize;
                if (level > 0) {
                    walk_bbt (ptr_in (p, e + psize * 2), depth + 1);
                } else {
                    uint64 bid = ptr_in (p, e) & ~((uint64) 1);
                    block_offset[bid] = ptr_in (p, e + psize);
                    block_size[bid] = Mapi.u16 (p, e + psize * 2);
                }
            }
        }

        private void walk_nbt (uint64 page, int depth) throws Error {
            if (depth > 16) throw new PstError.FORMAT (_("The Outlook data file is damaged"));
            var p = read_at (page, 512);
            int trailer = unicode ? 488 : 496;
            int count = p[trailer];
            int esize = p[trailer + 2];
            int level = p[trailer + 3];
            for (int i = 0; i < count; i++) {
                int e = i * esize;
                if (level > 0) {
                    walk_nbt (ptr_in (p, e + psize * 2), depth + 1);
                } else {
                    var n = new PstNode ();
                    n.nid = (uint32) ptr_in (p, e);
                    n.data_bid = ptr_in (p, e + psize);
                    n.sub_bid = ptr_in (p, e + psize * 2);
                    n.parent = Mapi.u32 (p, e + psize * 3);
                    nodes[n.nid] = n;
                }
            }
        }

        private uint8[] raw_block (uint64 bid) throws Error {
            uint64 key = bid & ~((uint64) 1);
            if (!block_offset.has_key (key)) throw new PstError.MISSING (_("A block of the Outlook data file is missing"));
            uint64 off = block_offset[key];
            uint32 size = block_size[key];
            var outb = read_at (off, (int) size);
            if ((bid & 2) == 0) decrypt (outb, (uint32) (bid & 0xFFFFFFFF));
            return outb;
        }

        private void decrypt (uint8[] buf, uint32 key) {
            if (crypt == 1) {
                for (int i = 0; i < buf.length; i++) buf[i] = COMPRESSIBLE[buf[i]];
            } else if (crypt == 2) {
                uint16 salt = (uint16) ((key >> 16) ^ (key & 0xFFFF));
                for (int i = 0; i < buf.length; i++) {
                    uint8 lo = (uint8) (salt & 0xFF);
                    uint8 hi = (uint8) (salt >> 8);
                    uint8 idx = buf[i];
                    idx = (uint8) (idx + lo);
                    idx = HIGH1[idx];
                    idx = (uint8) (idx + hi);
                    idx = HIGH2[idx];
                    idx = (uint8) (idx - hi);
                    idx = COMPRESSIBLE[idx];
                    idx = (uint8) (idx - lo);
                    buf[i] = idx;
                    salt++;
                }
            }
        }

        public Gee.ArrayList<Bytes> blocks (uint64 bid) throws Error {
            var list = new Gee.ArrayList<Bytes> ();
            if (bid == 0) return list;
            if ((bid & 2) == 0) {
                list.add (new Bytes (raw_block (bid)));
                return list;
            }
            var b = raw_block (bid);
            if (b.length < 8 || b[0] != 1) throw new PstError.FORMAT (_("The Outlook data file has an unexpected block"));
            int level = b[1];
            int count = Mapi.u16 (b, 2);
            int ps = psize;
            for (int i = 0; i < count; i++) {
                uint64 child = unicode ? Mapi.u64 (b, 8 + i * ps) : Mapi.u32 (b, 8 + i * ps);
                if (level == 1) list.add (new Bytes (raw_block (child)));
                else list.add_all (blocks (child));
            }
            return list;
        }

        public uint8[] read (uint64 bid) throws Error {
            var outb = new ByteArray ();
            foreach (var b in blocks (bid)) outb.append (b.get_data ());
            return outb.steal ();
        }

        public Gee.HashMap<uint32, PstNode> subnodes (uint64 bid) throws Error {
            var map = new Gee.HashMap<uint32, PstNode> ();
            if (bid == 0) return map;
            var b = raw_block (bid);
            if (b.length < 8 || b[0] != 2) return map;
            int level = b[1];
            int count = Mapi.u16 (b, 2);
            int ps = psize;
            int start = unicode ? 8 : 4;
            for (int i = 0; i < count; i++) {
                if (level == 0) {
                    int o = start + i * ps * 3;
                    var n = new PstNode ();
                    n.nid = (uint32) (unicode ? Mapi.u64 (b, o) : Mapi.u32 (b, o));
                    n.data_bid = unicode ? Mapi.u64 (b, o + ps) : Mapi.u32 (b, o + ps);
                    n.sub_bid = unicode ? Mapi.u64 (b, o + ps * 2) : Mapi.u32 (b, o + ps * 2);
                    map[n.nid] = n;
                } else {
                    int o = start + i * ps * 2;
                    uint64 child = unicode ? Mapi.u64 (b, o + ps) : Mapi.u32 (b, o + ps);
                    map.set_all (subnodes (child));
                }
            }
            return map;
        }

        public PstNode? node (uint32 nid) {
            return nodes[nid];
        }

        public PstBag bag (uint32 nid) throws Error {
            var n = nodes[nid];
            if (n == null) throw new PstError.MISSING (_("An item of the Outlook data file is missing"));
            return new PstBag (this, blocks (n.data_bid), subnodes (n.sub_bid));
        }

        public PstTable table (uint32 nid) throws Error {
            var n = nodes[nid];
            if (n == null) throw new PstError.MISSING (_("A table of the Outlook data file is missing"));
            return new PstTable (this, blocks (n.data_bid), subnodes (n.sub_bid));
        }

        public uint32 ipm_root () {
            try {
                var store = bag (0x21);
                var eid = store.bin (Mapi.IPM_SUBTREE_ENTRYID);
                if (eid != null && eid.length >= 24) {
                    uint32 nid = Mapi.u32 (eid, 20);
                    if (nodes.has_key (nid)) return nid;
                }
            } catch (Error e) {
            }
            return 0x122;
        }

        public PstFolder folders () throws Error {
            return load_folder (ipm_root (), 0);
        }

        private PstFolder load_folder (uint32 nid, int depth) throws Error {
            var f = new PstFolder ();
            f.nid = nid;
            try {
                var b = bag (nid);
                f.name = b.str (Mapi.DISPLAY_NAME);
                f.container_class = b.str (Mapi.CONTAINER_CLASS);
            } catch (Error e) {
            }
            uint32 contents = (nid & ~0x1Fu) | 0x0E;
            if (nodes.has_key (contents)) {
                try {
                    var t = table (contents);
                    foreach (var row in t.rows ()) f.messages.add (row.row_id);
                } catch (Error e) {
                }
            }
            f.count = f.messages.size;
            uint32 hier = (nid & ~0x1Fu) | 0x0D;
            if (depth < 32 && nodes.has_key (hier)) {
                try {
                    var t = table (hier);
                    foreach (var row in t.rows ()) {
                        if (!nodes.has_key (row.row_id) || row.row_id == nid) continue;
                        f.children.add (load_folder (row.row_id, depth + 1));
                    }
                } catch (Error e) {
                }
            }
            return f;
        }
    }

    public class PstHeap {
        private Gee.ArrayList<Bytes> blocks;
        public uint8 client_sig;
        public uint32 user_root;

        public PstHeap (Gee.ArrayList<Bytes> blocks) throws Error {
            this.blocks = blocks;
            if (blocks.size == 0) throw new PstError.FORMAT (_("An empty item in the Outlook data file"));
            var b = blocks[0].get_data ();
            if (b.length < 12 || b[2] != 0xEC) throw new PstError.FORMAT (_("An item of the Outlook data file is not readable"));
            client_sig = b[3];
            user_root = Mapi.u32 (b, 4);
        }

        public uint8[]? get (uint32 hid) {
            if (hid == 0 || (hid & 0x1F) != 0) return null;
            int index = (int) ((hid >> 5) & 0x7FF);
            int block = (int) (hid >> 16);
            if (block >= blocks.size || index == 0) return null;
            var b = blocks[block].get_data ();
            int map = Mapi.u16 (b, 0);
            if (map + 4 > b.length) return null;
            int count = Mapi.u16 (b, map);
            if (index > count) return null;
            int start = Mapi.u16 (b, map + 4 + (index - 1) * 2);
            int end = Mapi.u16 (b, map + 4 + index * 2);
            if (start > end || end > b.length) return null;
            return b[start:end];
        }

        public Gee.ArrayList<Bytes> records (uint32 bth_hid, out int key_size, out int data_size) {
            var list = new Gee.ArrayList<Bytes> ();
            key_size = 0;
            data_size = 0;
            var hdr = get (bth_hid);
            if (hdr == null || hdr.length < 8 || hdr[0] != 0xB5) return list;
            key_size = hdr[1];
            data_size = hdr[2];
            int levels = hdr[3];
            uint32 root = Mapi.u32 (hdr, 4);
            collect (root, levels, key_size, data_size, list);
            return list;
        }

        private void collect (uint32 hid, int level, int ks, int ds, Gee.List<Bytes> into) {
            var node = get (hid);
            if (node == null) return;
            if (level == 0) {
                int rs = ks + ds;
                for (int o = 0; o + rs <= node.length; o += rs) into.add (new Bytes (node[o:o + rs]));
                return;
            }
            int rs = ks + 4;
            for (int o = 0; o + rs <= node.length; o += rs) collect (Mapi.u32 (node, o + ks), level - 1, ks, ds, into);
        }
    }

    public class PstBag : MapiBag {
        private PstFile file;
        private PstHeap heap;
        private Gee.HashMap<uint32, PstNode> subs;
        private Gee.HashMap<uint16, MapiValue>? props;

        public PstBag (PstFile file, Gee.ArrayList<Bytes> blocks, Gee.HashMap<uint32, PstNode> subs) throws Error {
            this.file = file;
            this.subs = subs;
            heap = new PstHeap (blocks);
        }

        private uint8[] value_of (uint32 hnid) {
            if (hnid == 0) return {};
            if ((hnid & 0x1F) == 0) return heap.get (hnid) ?? new uint8[0];
            var n = subs[hnid];
            if (n == null) return {};
            try {
                return file.read (n.data_bid);
            } catch (Error e) {
                return {};
            }
        }

        private void load () {
            props = new Gee.HashMap<uint16, MapiValue> ();
            if (heap.client_sig != 0xBC) return;
            int ks, ds;
            foreach (var rec in heap.records (heap.user_root, out ks, out ds)) {
                var r = rec.get_data ();
                if (r.length < 8) continue;
                uint16 id = Mapi.u16 (r, 0);
                uint16 type = Mapi.u16 (r, 2);
                uint32 v = Mapi.u32 (r, 4);
                uint8[] data;
                switch (type) {
                    case 0x0002:
                    case 0x0003:
                    case 0x0004:
                    case 0x000A:
                    case 0x000B:
                        data = { (uint8) v, (uint8) (v >> 8), (uint8) (v >> 16), (uint8) (v >> 24) };
                        break;
                    default:
                        data = value_of (v);
                        break;
                }
                props[id] = new MapiValue (type, data);
            }
        }

        public override MapiValue? get_prop (uint16 id) {
            if (props == null) load ();
            return props[id];
        }

        private MapiBag? sub_bag (uint32 nid) {
            var n = subs[nid];
            if (n == null) return null;
            try {
                return new PstBag (file, file.blocks (n.data_bid), file.subnodes (n.sub_bid));
            } catch (Error e) {
                return null;
            }
        }

        private PstTable? sub_table (uint32 nid) {
            var n = subs[nid];
            if (n == null) return null;
            try {
                return new PstTable (file, file.blocks (n.data_bid), file.subnodes (n.sub_bid));
            } catch (Error e) {
                return null;
            }
        }

        public override Gee.List<MapiBag> recipients () {
            var list = new Gee.ArrayList<MapiBag> ();
            var t = sub_table (0x692);
            if (t == null) return list;
            try {
                foreach (var row in t.rows ()) list.add (row);
            } catch (Error e) {
            }
            return list;
        }

        public override Gee.List<MapiBag> attachments () {
            var list = new Gee.ArrayList<MapiBag> ();
            var t = sub_table (0x671);
            if (t == null) return list;
            try {
                foreach (var row in t.rows ()) {
                    var b = sub_bag (row.row_id);
                    if (b != null) list.add (b);
                }
            } catch (Error e) {
            }
            return list;
        }

        public override MapiBag? embedded () {
            var v = get_prop (Mapi.ATTACH_DATA);
            if (v == null || v.type != 0x000D || v.data.length < 4) return null;
            return sub_bag (Mapi.u32 (v.data, 0));
        }
    }

    public class PstRow : MapiBag {
        public uint32 row_id;
        public Gee.HashMap<uint16, MapiValue> values = new Gee.HashMap<uint16, MapiValue> ();

        public override MapiValue? get_prop (uint16 id) {
            return values[id];
        }

        public override Gee.List<MapiBag> recipients () {
            return new Gee.ArrayList<MapiBag> ();
        }

        public override Gee.List<MapiBag> attachments () {
            return new Gee.ArrayList<MapiBag> ();
        }

        public override MapiBag? embedded () {
            return null;
        }
    }

    public class PstTable : Object {
        private PstFile file;
        private PstHeap heap;
        private Gee.HashMap<uint32, PstNode> subs;

        public PstTable (PstFile file, Gee.ArrayList<Bytes> blocks, Gee.HashMap<uint32, PstNode> subs) throws Error {
            this.file = file;
            this.subs = subs;
            heap = new PstHeap (blocks);
            if (heap.client_sig != 0x7C) throw new PstError.FORMAT (_("A table of the Outlook data file is not readable"));
        }

        private uint8[] value_of (uint32 hnid) {
            if (hnid == 0) return {};
            if ((hnid & 0x1F) == 0) return heap.get (hnid) ?? new uint8[0];
            var n = subs[hnid];
            if (n == null) return {};
            try {
                return file.read (n.data_bid);
            } catch (Error e) {
                return {};
            }
        }

        public Gee.ArrayList<PstRow> rows () throws Error {
            var list = new Gee.ArrayList<PstRow> ();
            var info = heap.get (heap.user_root);
            if (info == null || info.length < 22 || info[0] != 0x7C) return list;
            int cols = info[1];
            int end_1b = Mapi.u16 (info, 6);
            int row_size = Mapi.u16 (info, 8);
            uint32 rows_hnid = Mapi.u32 (info, 14);
            var descs = new Gee.ArrayList<int> ();
            if (row_size == 0 || rows_hnid == 0) return list;
            var row_chunks = new Gee.ArrayList<Bytes> ();
            if ((rows_hnid & 0x1F) == 0) {
                var d = heap.get (rows_hnid);
                if (d != null) row_chunks.add (new Bytes (d));
            } else {
                var n = subs[rows_hnid];
                if (n != null) row_chunks.add_all (file.blocks (n.data_bid));
            }
            int ceb = end_1b;
            foreach (var chunk in row_chunks) {
                var d = chunk.get_data ();
                for (int o = 0; o + row_size <= d.length; o += row_size) {
                    var row = new PstRow ();
                    row.row_id = Mapi.u32 (d, o);
                    for (int c = 0; c < cols; c++) {
                        int base_off = 22 + c * 8;
                        uint32 tag = Mapi.u32 (info, base_off);
                        int ib = Mapi.u16 (info, base_off + 4);
                        int cb = info[base_off + 6];
                        int bit = info[base_off + 7];
                        int byte_index = o + ceb + bit / 8;
                        if (byte_index >= d.length || (d[byte_index] & (1 << (7 - bit % 8))) == 0) continue;
                        uint16 type = (uint16) (tag & 0xFFFF);
                        uint16 id = (uint16) (tag >> 16);
                        uint8[] value;
                        if (type == 0x0002 || type == 0x0003 || type == 0x000B || type == 0x0004 || type == 0x000A || ((type == 0x0014 || type == 0x0040) && cb == 8)) {
                            value = d[o + ib:o + ib + cb];
                        } else {
                            value = value_of (Mapi.u32 (d, o + ib));
                        }
                        row.values[id] = new MapiValue (type, value);
                    }
                    list.add (row);
                }
            }
            return list;
        }
    }
}
