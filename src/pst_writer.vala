namespace Singularity.Apps.Lettere {

    public class PstProp {
        public uint16 id;
        public uint16 type;
        public uint8[] value;

        public PstProp (uint16 id, uint16 type, uint8[] value) {
            this.id = id;
            this.type = type;
            this.value = value;
        }
    }

    public class PstExportFolder {
        public string name;
        public Gee.ArrayList<Bytes> messages = new Gee.ArrayList<Bytes> ();
        public Gee.ArrayList<int> flags = new Gee.ArrayList<int> ();
        public Gee.ArrayList<PstExportFolder> children = new Gee.ArrayList<PstExportFolder> ();

        public PstExportFolder (string name) {
            this.name = name;
        }

        public void add (uint8[] raw, int f) {
            messages.add (new Bytes (raw));
            flags.add (f);
        }
    }

    public class PstWriter : Object {
        private const int BLOCK_MAX = 8176;
        private const int HEAP_ITEM_MAX = 3580;
        private ByteArray body = new ByteArray ();
        private uint64 next_bid = 4;
        private uint64 next_page_bid = 4;
        private uint32[] next_nid = new uint32[32];
        private Gee.ArrayList<uint64?> bbt_bid = new Gee.ArrayList<uint64?> ();
        private Gee.ArrayList<uint64?> bbt_ib = new Gee.ArrayList<uint64?> ();
        private Gee.ArrayList<int> bbt_cb = new Gee.ArrayList<int> ();
        private Gee.ArrayList<uint32> nbt_nid = new Gee.ArrayList<uint32> ();
        private Gee.ArrayList<uint64?> nbt_data = new Gee.ArrayList<uint64?> ();
        private Gee.ArrayList<uint64?> nbt_sub = new Gee.ArrayList<uint64?> ();
        private Gee.ArrayList<uint32> nbt_parent = new Gee.ArrayList<uint32> ();
        private uint8[] record_key = new uint8[16];
        private const uint64 DATA_START = 0x4600;

        private static uint32[] crc_table;

        private static uint32 crc (uint8[] d, int len) {
            if (crc_table == null) {
                crc_table = new uint32[256];
                for (uint32 i = 0; i < 256; i++) {
                    uint32 c = i;
                    for (int k = 0; k < 8; k++) c = (c & 1) != 0 ? 0xEDB88320U ^ (c >> 1) : c >> 1;
                    crc_table[i] = c;
                }
            }
            uint32 c = 0;
            for (int i = 0; i < len; i++) c = crc_table[(c ^ d[i]) & 0xFF] ^ (c >> 8);
            return c;
        }

        private static uint16 sig (uint64 ib, uint64 bid) {
            uint64 v = ib ^ bid;
            return (uint16) ((uint16) (v >> 16) ^ (uint16) v);
        }

        private static void p16 (uint8[] b, int o, uint v) {
            b[o] = (uint8) v;
            b[o + 1] = (uint8) (v >> 8);
        }

        private static void p32 (uint8[] b, int o, uint32 v) {
            b[o] = (uint8) v;
            b[o + 1] = (uint8) (v >> 8);
            b[o + 2] = (uint8) (v >> 16);
            b[o + 3] = (uint8) (v >> 24);
        }

        private static void p64 (uint8[] b, int o, uint64 v) {
            p32 (b, o, (uint32) v);
            p32 (b, o + 4, (uint32) (v >> 32));
        }

        public PstWriter () {
            for (int i = 0; i < 16; i++) record_key[i] = (uint8) Random.int_range (0, 256);
            for (int i = 0; i < 32; i++) next_nid[i] = 0x410;
        }

        private uint32 new_nid (uint32 type) {
            uint32 idx = next_nid[type]++;
            return (idx << 5) | type;
        }

        private uint64 offset_now () {
            return DATA_START + body.len;
        }

        private uint64 write_block (uint8[] data, bool internal_block) {
            uint64 bid = next_bid;
            next_bid += 4;
            if (internal_block) bid |= 2;
            uint64 ib = offset_now ();
            int total = ((data.length + 16 + 63) / 64) * 64;
            var blk = new uint8[total];
            Memory.copy (blk, data, data.length);
            int t = total - 16;
            p16 (blk, t, data.length);
            p16 (blk, t + 2, sig (ib, bid));
            p32 (blk, t + 4, crc (data, data.length));
            p64 (blk, t + 8, bid);
            body.append (blk);
            bbt_bid.add (bid);
            bbt_ib.add (ib);
            bbt_cb.add (data.length);
            return bid;
        }

        private uint64 write_data (uint8[] data) {
            if (data.length <= BLOCK_MAX) return write_block (data, false);
            var bids = new Gee.ArrayList<uint64?> ();
            for (int o = 0; o < data.length; o += BLOCK_MAX) bids.add (write_block (data[o:int.min (data.length, o + BLOCK_MAX)], false));
            int per = (BLOCK_MAX - 8) / 8;
            if (bids.size <= per) return xblock (bids, 1, data.length);
            var xs = new Gee.ArrayList<uint64?> ();
            for (int i = 0; i < bids.size; i += per) {
                var slice = new Gee.ArrayList<uint64?> ();
                int total = 0;
                for (int k = i; k < int.min (bids.size, i + per); k++) {
                    slice.add (bids[k]);
                    total += int.min (BLOCK_MAX, data.length - k * BLOCK_MAX);
                }
                xs.add (xblock (slice, 1, total));
            }
            return xblock (xs, 2, data.length);
        }

        private uint64 xblock (Gee.List<uint64?> bids, int level, int total) {
            var b = new uint8[8 + bids.size * 8];
            b[0] = 1;
            b[1] = (uint8) level;
            p16 (b, 2, bids.size);
            p32 (b, 4, total);
            for (int i = 0; i < bids.size; i++) p64 (b, 8 + i * 8, bids[i]);
            return write_block (b, true);
        }

        private void node (uint32 nid, uint64 data, uint64 sub, uint32 parent) {
            nbt_nid.add (nid);
            nbt_data.add (data);
            nbt_sub.add (sub);
            nbt_parent.add (parent);
        }

        private class Heap {
            public Gee.ArrayList<Bytes> items = new Gee.ArrayList<Bytes> ();
            public uint8 client;

            public Heap (uint8 client) {
                this.client = client;
            }

            public int used = 12;

            public uint32 alloc (uint8[] d) {
                items.add (new Bytes (d));
                used += d.length + (d.length % 2) + 2;
                return (uint32) (items.size << 5);
            }

            public uint8[] build (uint32 root) {
                int size = 12;
                foreach (var it in items) size += (int) it.get_size () + ((int) it.get_size () % 2);
                int map = size;
                var b = new uint8[map + 4 + (items.size + 1) * 2];
                b[2] = 0xEC;
                b[3] = client;
                p32 (b, 4, root);
                p16 (b, 0, map);
                p16 (b, map, items.size);
                p16 (b, map + 2, 0);
                int o = 12;
                for (int i = 0; i < items.size; i++) {
                    p16 (b, map + 4 + i * 2, o);
                    var d = items[i].get_data ();
                    Memory.copy (&b[o], d, d.length);
                    o += d.length + (d.length % 2);
                }
                p16 (b, map + 4 + items.size * 2, o);
                return b;
            }
        }

        private class SubnodeSet {
            public Gee.ArrayList<uint32> nids = new Gee.ArrayList<uint32> ();
            public Gee.ArrayList<uint64?> data = new Gee.ArrayList<uint64?> ();
            public Gee.ArrayList<uint64?> subs = new Gee.ArrayList<uint64?> ();
            public uint32 next = 0x1000;

            public uint32 add (uint64 d, uint64 s, uint32 type) {
                uint32 nid = ((next++) << 5) | type;
                nids.add (nid);
                data.add (d);
                subs.add (s);
                return nid;
            }

            public void add_fixed (uint32 nid, uint64 d, uint64 s) {
                nids.add (nid);
                data.add (d);
                subs.add (s);
            }
        }

        private uint64 write_subnodes (SubnodeSet set) {
            if (set.nids.size == 0) return 0;
            var order = new Gee.ArrayList<int> ();
            for (int i = 0; i < set.nids.size; i++) order.add (i);
            order.sort ((a, b) => set.nids[a] < set.nids[b] ? -1 : (set.nids[a] > set.nids[b] ? 1 : 0));
            int per = (BLOCK_MAX - 8) / 24;
            var sls = new Gee.ArrayList<uint64?> ();
            var firsts = new Gee.ArrayList<uint32> ();
            for (int i = 0; i < order.size; i += per) {
                int n = int.min (per, order.size - i);
                var b = new uint8[8 + n * 24];
                b[0] = 2;
                b[1] = 0;
                p16 (b, 2, n);
                for (int k = 0; k < n; k++) {
                    int idx = order[i + k];
                    p64 (b, 8 + k * 24, set.nids[idx]);
                    p64 (b, 8 + k * 24 + 8, set.data[idx]);
                    p64 (b, 8 + k * 24 + 16, set.subs[idx]);
                }
                firsts.add (set.nids[order[i]]);
                sls.add (write_block (b, true));
            }
            if (sls.size == 1) return sls[0];
            var si = new uint8[8 + sls.size * 16];
            si[0] = 2;
            si[1] = 1;
            p16 (si, 2, sls.size);
            for (int k = 0; k < sls.size; k++) {
                p64 (si, 8 + k * 16, firsts[k]);
                p64 (si, 8 + k * 16 + 8, sls[k]);
            }
            return write_block (si, true);
        }

        private static bool fixed_type (uint16 t) {
            return t == 0x0002 || t == 0x0003 || t == 0x000B || t == 0x0004 || t == 0x000A;
        }

        private uint32 value_hnid (Heap heap, SubnodeSet subs, uint8[] v) {
            if (v.length == 0) return 0;
            if (v.length <= HEAP_ITEM_MAX - 64 && heap.used + v.length < 6000) return heap.alloc (v);
            return subs.add (write_data (v), 0, 0x1F);
        }

        private uint32 bth (Heap heap, Gee.List<Bytes> records, int key_size, int data_size) {
            int rec = key_size + data_size;
            var leaves = new Gee.ArrayList<uint32> ();
            var leaf_keys = new Gee.ArrayList<Bytes> ();
            int per = (HEAP_ITEM_MAX - 64) / rec;
            for (int i = 0; i < records.size; i += per) {
                var b = new ByteArray ();
                for (int k = i; k < int.min (records.size, i + per); k++) b.append (records[k].get_data ());
                leaf_keys.add (new Bytes (records[i].get_data ()[0:key_size]));
                leaves.add (heap.alloc (b.data));
            }
            int levels = 0;
            while (leaves.size > 1) {
                levels++;
                var up = new Gee.ArrayList<uint32> ();
                var up_keys = new Gee.ArrayList<Bytes> ();
                int iper = (HEAP_ITEM_MAX - 64) / (key_size + 4);
                for (int i = 0; i < leaves.size; i += iper) {
                    var b = new ByteArray ();
                    for (int k = i; k < int.min (leaves.size, i + iper); k++) {
                        b.append (leaf_keys[k].get_data ());
                        var h = new uint8[4];
                        p32 (h, 0, leaves[k]);
                        b.append (h);
                    }
                    up_keys.add (leaf_keys[i]);
                    up.add (heap.alloc (b.data));
                }
                leaves = up;
                leaf_keys = up_keys;
            }
            var hdr = new uint8[8];
            hdr[0] = 0xB5;
            hdr[1] = (uint8) key_size;
            hdr[2] = (uint8) data_size;
            hdr[3] = (uint8) levels;
            p32 (hdr, 4, records.size > 0 ? leaves[0] : 0);
            return heap.alloc (hdr);
        }

        private void write_pc (uint32 nid, uint32 parent, Gee.List<PstProp> props, SubnodeSet? extra, out uint64 data_bid, out uint64 sub_bid) {
            var heap = new Heap (0xBC);
            var subs = extra ?? new SubnodeSet ();
            props.sort ((a, b) => a.id < b.id ? -1 : (a.id > b.id ? 1 : 0));
            var recs = new Gee.ArrayList<Bytes> ();
            foreach (var p in props) {
                var r = new uint8[8];
                p16 (r, 0, p.id);
                p16 (r, 2, p.type);
                if (fixed_type (p.type)) {
                    for (int i = 0; i < 4 && i < p.value.length; i++) r[4 + i] = p.value[i];
                } else {
                    p32 (r, 4, value_hnid (heap, subs, p.value));
                }
                recs.add (new Bytes (r));
            }
            uint32 root = bth (heap, recs, 2, 6);
            data_bid = write_block (heap.build (root), false);
            sub_bid = write_subnodes (subs);
            if (nid != 0) node (nid, data_bid, sub_bid, parent);
        }

        private class Column {
            public uint32 tag;
            public int size;
            public int offset;
            public int bit;

            public Column (uint32 tag, int size) {
                this.tag = tag;
                this.size = size;
            }
        }

        private void write_tc (uint32 nid, uint32[] tags, Gee.List<Gee.HashMap<uint32, Bytes>> rows, Gee.List<uint32> row_ids, out uint64 data_bid, out uint64 sub_bid) {
            var cols = new Gee.ArrayList<Column> ();
            cols.add (new Column (0x67F20003, 4));
            cols.add (new Column (0x67F30003, 4));
            foreach (uint32 t in tags) {
                uint16 type = (uint16) (t & 0xFFFF);
                int size = type == 0x0014 || type == 0x0040 ? 8 : (type == 0x000B ? 1 : (type == 0x0002 ? 2 : 4));
                cols.add (new Column (t, size));
            }
            int off = 0;
            var ordered = new Gee.ArrayList<Column> ();
            ordered.add (cols[0]);
            ordered.add (cols[1]);
            foreach (int want in new int[] { 8, 4, 2, 1 }) {
                for (int i = 2; i < cols.size; i++) if (cols[i].size == want) ordered.add (cols[i]);
            }
            int end4 = 0, end2 = 0, end1 = 0;
            foreach (var c in ordered) {
                c.offset = off;
                off += c.size;
                if (c.size >= 4) end4 = off;
                if (c.size >= 2) end2 = off;
                end1 = off;
            }
            for (int i = 0; i < cols.size; i++) cols[i].bit = i;
            int ceb = (cols.size + 7) / 8;
            int row_size = end1 + ceb;
            var heap = new Heap (0x7C);
            var subs = new SubnodeSet ();
            var matrix = new ByteArray ();
            var index_recs = new Gee.ArrayList<Bytes> ();
            for (int r = 0; r < rows.size; r++) {
                var row = new uint8[row_size];
                p32 (row, cols[0].offset, row_ids[r]);
                p32 (row, cols[1].offset, 1);
                row[end1] |= 0x80;
                row[end1] |= 0x40;
                foreach (var c in cols) {
                    if (c.tag == 0x67F20003 || c.tag == 0x67F30003) continue;
                    var v = rows[r][c.tag];
                    if (v == null) continue;
                    uint16 type = (uint16) (c.tag & 0xFFFF);
                    var d = v.get_data ();
                    if (fixed_type (type) || type == 0x0014 || type == 0x0040) {
                        for (int i = 0; i < c.size && i < d.length; i++) row[c.offset + i] = d[i];
                    } else {
                        p32 (row, c.offset, value_hnid (heap, subs, d));
                    }
                    row[end1 + c.bit / 8] |= (uint8) (0x80 >> (c.bit % 8));
                }
                matrix.append (row);
                var ir = new uint8[8];
                p32 (ir, 0, row_ids[r]);
                p32 (ir, 4, r);
                index_recs.add (new Bytes (ir));
            }
            index_recs.sort ((a, b) => {
                uint32 x = Mapi.u32 (a.get_data (), 0), y = Mapi.u32 (b.get_data (), 0);
                return x < y ? -1 : (x > y ? 1 : 0);
            });
            uint32 index_hid = bth (heap, index_recs, 4, 4);
            uint32 rows_hnid = 0;
            if (matrix.len > 0) {
                if (matrix.len <= HEAP_ITEM_MAX - 64 && heap.used + matrix.len < 6000) {
                    rows_hnid = heap.alloc (matrix.data);
                } else {
                    int per = BLOCK_MAX / row_size;
                    var blocks = new Gee.ArrayList<uint64?> ();
                    for (int r = 0; r < rows.size; r += per) {
                        int n = int.min (per, rows.size - r);
                        blocks.add (write_block (matrix.data[r * row_size:(r + n) * row_size], false));
                    }
                    uint64 data = blocks.size == 1 ? blocks[0] : xblock (blocks, 1, (int) matrix.len);
                    rows_hnid = subs.add (data, 0, 0x1F);
                }
            }
            var info = new uint8[22 + cols.size * 8];
            info[0] = 0x7C;
            info[1] = (uint8) cols.size;
            p16 (info, 2, end4);
            p16 (info, 4, end2);
            p16 (info, 6, end1);
            p16 (info, 8, row_size);
            p32 (info, 10, index_hid);
            p32 (info, 14, rows_hnid);
            p32 (info, 18, 0);
            var sorted = new Gee.ArrayList<Column> ();
            sorted.add_all (cols);
            sorted.sort ((a, b) => a.tag < b.tag ? -1 : (a.tag > b.tag ? 1 : 0));
            for (int i = 0; i < sorted.size; i++) {
                p32 (info, 22 + i * 8, sorted[i].tag);
                p16 (info, 22 + i * 8 + 4, sorted[i].offset);
                info[22 + i * 8 + 6] = (uint8) sorted[i].size;
                info[22 + i * 8 + 7] = (uint8) sorted[i].bit;
            }
            uint32 root = heap.alloc (info);
            data_bid = write_block (heap.build (root), false);
            sub_bid = write_subnodes (subs);
            if (nid != 0) node (nid, data_bid, sub_bid, 0);
        }

        private static uint8[] ustr (string s) {
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
            return b.steal ();
        }

        private static uint8[] i32 (int32 v) {
            return { (uint8) v, (uint8) (v >> 8), (uint8) (v >> 16), (uint8) (v >> 24) };
        }

        private static uint8[] ftime (int64 t) {
            uint64 ft = (uint64) t * 10000000 + 116444736000000000;
            var b = new uint8[8];
            p64 (b, 0, ft);
            return b;
        }

        private uint8[] entry_id (uint32 nid) {
            var b = new uint8[24];
            Memory.copy (&b[4], record_key, 16);
            p32 (b, 20, nid);
            return b;
        }

        private void folder_props (Gee.List<PstProp> p, string name, int count, int unread, bool subfolders) {
            p.add (new PstProp (Mapi.DISPLAY_NAME, 0x001F, ustr (name)));
            p.add (new PstProp (Mapi.CONTENT_COUNT, 0x0003, i32 (count)));
            p.add (new PstProp (Mapi.CONTENT_UNREAD, 0x0003, i32 (unread)));
            p.add (new PstProp (0x360A, 0x000B, { subfolders ? 1 : 0 }));
            p.add (new PstProp (Mapi.CONTAINER_CLASS, 0x001F, ustr ("IPF.Note")));
        }

        private static uint32[] HIER_TAGS = { 0x3001001F, 0x36020003, 0x36030003, 0x360A000B, 0x3613001F };
        private static uint32[] CONTENT_TAGS = { 0x0037001F, 0x0C1A001F, 0x0E060040, 0x0E070003, 0x0E080003, 0x00170003, 0x001A001F, 0x0E04001F };

        private Gee.HashMap<uint32, Bytes> folder_row (string name, int count, int unread, bool subfolders) {
            var m = new Gee.HashMap<uint32, Bytes> ();
            m[0x3001001F] = new Bytes (ustr (name));
            m[0x36020003] = new Bytes (i32 (count));
            m[0x36030003] = new Bytes (i32 (unread));
            m[0x360A000B] = new Bytes ({ subfolders ? 1 : 0 });
            m[0x3613001F] = new Bytes (ustr ("IPF.Note"));
            return m;
        }

        private uint32 write_message (uint8[] raw, int flags, uint32 folder, out Gee.HashMap<uint32, Bytes> row) {
            var msg = new MimeMessage (raw);
            uint32 nid = new_nid (0x04);
            var props = new Gee.ArrayList<PstProp> ();
            var subs = new SubnodeSet ();
            props.add (new PstProp (Mapi.MESSAGE_CLASS, 0x001F, ustr ("IPM.Note")));
            props.add (new PstProp (Mapi.SUBJECT, 0x001F, ustr (msg.subject)));
            var from = msg.from;
            string sname = from.size > 0 ? (from[0].name != "" ? from[0].name : from[0].email) : "";
            string semail = from.size > 0 ? from[0].email : "";
            props.add (new PstProp (Mapi.SENDER_NAME, 0x001F, ustr (sname)));
            props.add (new PstProp (Mapi.SENDER_EMAIL, 0x001F, ustr (semail)));
            props.add (new PstProp (Mapi.SENDER_ADDRTYPE, 0x001F, ustr ("SMTP")));
            props.add (new PstProp (Mapi.SENT_REPR_NAME, 0x001F, ustr (sname)));
            props.add (new PstProp (Mapi.SENT_REPR_EMAIL, 0x001F, ustr (semail)));
            props.add (new PstProp (Mapi.DISPLAY_TO, 0x001F, ustr (Mime.display_addresses (msg.to))));
            props.add (new PstProp (Mapi.DISPLAY_CC, 0x001F, ustr (Mime.display_addresses (msg.cc))));
            var d = msg.date;
            int64 t = d != null ? d.to_unix () : new DateTime.now_utc ().to_unix ();
            props.add (new PstProp (Mapi.DELIVERY_TIME, 0x0040, ftime (t)));
            props.add (new PstProp (Mapi.CLIENT_SUBMIT_TIME, 0x0040, ftime (t)));
            int mflags = (flags & MessageFlags.SEEN) != 0 ? 1 : 0;
            if (msg.attachments.size > 0) mflags |= 0x10;
            props.add (new PstProp (Mapi.MESSAGE_FLAGS, 0x0003, i32 (mflags)));
            props.add (new PstProp (Mapi.MESSAGE_SIZE, 0x0003, i32 (raw.length)));
            props.add (new PstProp (Mapi.IMPORTANCE, 0x0003, i32 (Mime.importance_of (msg.root) + 1)));
            if ((flags & MessageFlags.FLAGGED) != 0) props.add (new PstProp (Mapi.FLAG_STATUS, 0x0003, i32 ((flags & MessageFlags.COMPLETED) != 0 ? 1 : 2)));
            props.add (new PstProp (Mapi.BODY, 0x001F, ustr (msg.body_text ())));
            if (msg.text_html != "") props.add (new PstProp (Mapi.HTML, 0x0102, msg.text_html.data));
            if (msg.message_id != "") props.add (new PstProp (Mapi.INTERNET_MESSAGE_ID, 0x001F, ustr ("<" + msg.message_id + ">")));
            if (msg.in_reply_to != "") props.add (new PstProp (Mapi.IN_REPLY_TO, 0x001F, ustr ("<" + msg.in_reply_to + ">")));
            string s = Mime.bytes_to_string (raw);
            int hend = s.index_of ("\r\n\r\n");
            if (hend > 0) props.add (new PstProp (Mapi.TRANSPORT_HEADERS, 0x001F, ustr (s.substring (0, hend + 2))));
            var rrows = new Gee.ArrayList<Gee.HashMap<uint32, Bytes>> ();
            var rids = new Gee.ArrayList<uint32> ();
            uint32 ri = 0;
            foreach (int kind in new int[] { 1, 2 }) {
                foreach (var a in kind == 1 ? msg.to : msg.cc) {
                    var r = new Gee.HashMap<uint32, Bytes> ();
                    r[0x0C150003] = new Bytes (i32 (kind));
                    r[0x3001001F] = new Bytes (ustr (a.name != "" ? a.name : a.email));
                    r[0x3002001F] = new Bytes (ustr ("SMTP"));
                    r[0x3003001F] = new Bytes (ustr (a.email));
                    r[0x39FE001F] = new Bytes (ustr (a.email));
                    rrows.add (r);
                    rids.add (ri++);
                }
            }
            uint64 rdata, rsub;
            write_tc (0, { 0x0C150003, 0x3001001F, 0x3002001F, 0x3003001F, 0x39FE001F }, rrows, rids, out rdata, out rsub);
            subs.add_fixed (0x692, rdata, rsub);
            if (msg.attachments.size > 0) {
                var arows = new Gee.ArrayList<Gee.HashMap<uint32, Bytes>> ();
                var aids = new Gee.ArrayList<uint32> ();
                foreach (var a in msg.attachments) {
                    var ap = new Gee.ArrayList<PstProp> ();
                    ap.add (new PstProp (Mapi.ATTACH_METHOD, 0x0003, i32 (1)));
                    ap.add (new PstProp (Mapi.ATTACH_FILENAME, 0x001F, ustr (a.filename)));
                    ap.add (new PstProp (Mapi.ATTACH_LONG_FILENAME, 0x001F, ustr (a.filename)));
                    ap.add (new PstProp (Mapi.DISPLAY_NAME, 0x001F, ustr (a.filename)));
                    ap.add (new PstProp (Mapi.ATTACH_MIME, 0x001F, ustr (a.content_type)));
                    ap.add (new PstProp (0x0E20, 0x0003, i32 ((int32) a.data.get_size ())));
                    ap.add (new PstProp (Mapi.ATTACH_DATA, 0x0102, a.data.get_data ()));
                    if (a.content_id != "") ap.add (new PstProp (Mapi.ATTACH_CONTENT_ID, 0x001F, ustr (a.content_id)));
                    uint64 adata, asub;
                    write_pc (0, 0, ap, null, out adata, out asub);
                    uint32 anid = subs.add (adata, asub, 0x05);
                    var ar = new Gee.HashMap<uint32, Bytes> ();
                    ar[0x37050003] = new Bytes (i32 (1));
                    ar[0x3707001F] = new Bytes (ustr (a.filename));
                    ar[0x0E200003] = new Bytes (i32 ((int32) a.data.get_size ()));
                    arows.add (ar);
                    aids.add (anid);
                }
                uint64 adata2, asub2;
                write_tc (0, { 0x37050003, 0x3707001F, 0x0E200003 }, arows, aids, out adata2, out asub2);
                subs.add_fixed (0x671, adata2, asub2);
            }
            uint64 data, sub;
            write_pc (nid, folder, props, subs, out data, out sub);
            row = new Gee.HashMap<uint32, Bytes> ();
            row[0x0037001F] = new Bytes (ustr (msg.subject));
            row[0x0C1A001F] = new Bytes (ustr (sname));
            row[0x0E060040] = new Bytes (ftime (t));
            row[0x0E070003] = new Bytes (i32 (mflags));
            row[0x0E080003] = new Bytes (i32 (raw.length));
            row[0x00170003] = new Bytes (i32 (Mime.importance_of (msg.root) + 1));
            row[0x001A001F] = new Bytes (ustr ("IPM.Note"));
            row[0x0E04001F] = new Bytes (ustr (Mime.display_addresses (msg.to)));
            return nid;
        }

        private uint32 write_folder (PstExportFolder f, uint32 parent, uint32 forced_nid = 0) {
            uint32 nid = forced_nid != 0 ? forced_nid : new_nid (0x02);
            var crow = new Gee.ArrayList<Gee.HashMap<uint32, Bytes>> ();
            var cids = new Gee.ArrayList<uint32> ();
            int unread = 0;
            for (int i = 0; i < f.messages.size; i++) {
                Gee.HashMap<uint32, Bytes> row;
                uint32 m = write_message (f.messages[i].get_data (), f.flags[i], nid, out row);
                crow.add (row);
                cids.add (m);
                if ((f.flags[i] & MessageFlags.SEEN) == 0) unread++;
            }
            var hrows = new Gee.ArrayList<Gee.HashMap<uint32, Bytes>> ();
            var hids = new Gee.ArrayList<uint32> ();
            foreach (var c in f.children) {
                uint32 cid = write_folder (c, nid);
                hrows.add (folder_row (c.name, c.messages.size, 0, c.children.size > 0));
                hids.add (cid);
            }
            uint64 d, s;
            var props = new Gee.ArrayList<PstProp> ();
            folder_props (props, f.name, f.messages.size, unread, f.children.size > 0);
            write_pc (nid, parent, props, null, out d, out s);
            write_tc ((nid & ~0x1Fu) | 0x0D, HIER_TAGS, hrows, hids, out d, out s);
            write_tc ((nid & ~0x1Fu) | 0x0E, CONTENT_TAGS, crow, cids, out d, out s);
            write_tc ((nid & ~0x1Fu) | 0x0F, CONTENT_TAGS, new Gee.ArrayList<Gee.HashMap<uint32, Bytes>> (), new Gee.ArrayList<uint32> (), out d, out s);
            return nid;
        }

        private uint64 write_btree (bool nbt) {
            int count = nbt ? nbt_nid.size : bbt_bid.size;
            var order = new Gee.ArrayList<int> ();
            for (int i = 0; i < count; i++) order.add (i);
            if (nbt) order.sort ((a, b) => nbt_nid[a] < nbt_nid[b] ? -1 : (nbt_nid[a] > nbt_nid[b] ? 1 : 0));
            else order.sort ((a, b) => bbt_bid[a] < bbt_bid[b] ? -1 : (bbt_bid[a] > bbt_bid[b] ? 1 : 0));
            int esize = nbt ? 32 : 24;
            int per = 488 / esize;
            var keys = new Gee.ArrayList<uint64?> ();
            var pages = new Gee.ArrayList<uint64?> ();
            var page_bids = new Gee.ArrayList<uint64?> ();
            for (int i = 0; i < order.size || (i == 0 && order.size == 0); i += per) {
                var p = new uint8[512];
                int n = int.min (per, order.size - i);
                for (int k = 0; k < n; k++) {
                    int idx = order[i + k];
                    int o = k * esize;
                    if (nbt) {
                        p64 (p, o, nbt_nid[idx]);
                        p64 (p, o + 8, nbt_data[idx]);
                        p64 (p, o + 16, nbt_sub[idx]);
                        p32 (p, o + 24, nbt_parent[idx]);
                    } else {
                        p64 (p, o, bbt_bid[idx]);
                        p64 (p, o + 8, bbt_ib[idx]);
                        p16 (p, o + 16, bbt_cb[idx]);
                        p16 (p, o + 18, 2);
                    }
                }
                p[488] = (uint8) n;
                p[489] = (uint8) per;
                p[490] = (uint8) esize;
                p[491] = 0;
                uint64 bid;
                uint64 ib = page (p, nbt, out bid);
                keys.add (n > 0 ? (nbt ? (uint64) nbt_nid[order[i]] : bbt_bid[order[i]]) : 0);
                pages.add (ib);
                page_bids.add (bid);
                if (order.size == 0) break;
            }
            int level = 0;
            while (pages.size > 1) {
                level++;
                var nk = new Gee.ArrayList<uint64?> ();
                var np = new Gee.ArrayList<uint64?> ();
                var nb = new Gee.ArrayList<uint64?> ();
                for (int i = 0; i < pages.size; i += 20) {
                    var p = new uint8[512];
                    int n = int.min (20, pages.size - i);
                    for (int k = 0; k < n; k++) {
                        p64 (p, k * 24, keys[i + k]);
                        p64 (p, k * 24 + 8, page_bids[i + k]);
                        p64 (p, k * 24 + 16, pages[i + k]);
                    }
                    p[488] = (uint8) n;
                    p[489] = 20;
                    p[490] = 24;
                    p[491] = (uint8) level;
                    uint64 bid;
                    uint64 ib = page (p, nbt, out bid);
                    nk.add (keys[i]);
                    np.add (ib);
                    nb.add (bid);
                }
                keys = nk;
                pages = np;
                page_bids = nb;
            }
            nbt_root_bid = page_bids[0];
            if (!nbt) bbt_root_bid = page_bids[0];
            return pages[0];
        }

        private uint64 nbt_root_bid;
        private uint64 bbt_root_bid;

        private uint64 page (uint8[] p, bool nbt, out uint64 bid) {
            while (offset_now () % 512 != 0) body.append ({ 0 });
            uint64 ib = offset_now ();
            bid = next_page_bid;
            next_page_bid += 4;
            p[496] = nbt ? 0x81 : 0x80;
            p[497] = nbt ? 0x81 : 0x80;
            p16 (p, 498, sig (ib, bid));
            p32 (p, 500, crc (p, 496));
            p64 (p, 504, bid);
            body.append (p);
            return ib;
        }

        private void write_pc_node (uint32 nid, Gee.List<PstProp> props) {
            uint64 d, s;
            write_pc (nid, 0, props, null, out d, out s);
        }

        public uint8[] build (PstExportFolder top) throws Error {
            var store = new Gee.ArrayList<PstProp> ();
            store.add (new PstProp (0x0FF9, 0x0102, record_key));
            store.add (new PstProp (Mapi.DISPLAY_NAME, 0x001F, ustr (top.name)));
            store.add (new PstProp (Mapi.IPM_SUBTREE_ENTRYID, 0x0102, entry_id (0x8022)));
            store.add (new PstProp (0x35E3, 0x0102, entry_id (0x8062)));
            store.add (new PstProp (0x35E7, 0x0102, entry_id (0x8042)));
            store.add (new PstProp (0x340D, 0x0003, i32 (0x00040000)));
            write_pc_node (0x21, store);
            var names = new Gee.ArrayList<PstProp> ();
            names.add (new PstProp (0x0001, 0x0003, i32 (251)));
            names.add (new PstProp (0x0002, 0x0102, { 0x08, 0x20, 0x06, 0x00, 0x00, 0x00, 0x00, 0x00, 0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46 }));
            names.add (new PstProp (0x0003, 0x0102, { 0x02, 0x85, 0x00, 0x00, 0x06, 0x00, 0x00, 0x00 }));
            names.add (new PstProp (0x0004, 0x0102, { 0x00, 0x00, 0x00, 0x00 }));
            write_pc_node (0x61, names);
            uint64 d, s;
            var root = new Gee.ArrayList<PstProp> ();
            folder_props (root, "", 0, 0, true);
            write_pc (0x122, 0x122, root, null, out d, out s);
            var rh = new Gee.ArrayList<Gee.HashMap<uint32, Bytes>> ();
            var rid = new Gee.ArrayList<uint32> ();
            rh.add (folder_row (_("Top of Outlook data file"), 0, 0, true));
            rid.add (0x8022);
            rh.add (folder_row (_("Search Root"), 0, 0, false));
            rid.add (0x8042);
            write_tc (0x12D, HIER_TAGS, rh, rid, out d, out s);
            write_tc (0x12E, CONTENT_TAGS, new Gee.ArrayList<Gee.HashMap<uint32, Bytes>> (), new Gee.ArrayList<uint32> (), out d, out s);
            write_tc (0x12F, CONTENT_TAGS, new Gee.ArrayList<Gee.HashMap<uint32, Bytes>> (), new Gee.ArrayList<uint32> (), out d, out s);
            var search = new Gee.ArrayList<PstProp> ();
            folder_props (search, _("Search Root"), 0, 0, false);
            write_pc (0x8042, 0x122, search, null, out d, out s);
            write_tc (0x804D, HIER_TAGS, new Gee.ArrayList<Gee.HashMap<uint32, Bytes>> (), new Gee.ArrayList<uint32> (), out d, out s);
            write_tc (0x804E, CONTENT_TAGS, new Gee.ArrayList<Gee.HashMap<uint32, Bytes>> (), new Gee.ArrayList<uint32> (), out d, out s);
            var ipm = new PstExportFolder (_("Top of Outlook data file"));
            var deleted = new PstExportFolder (_("Deleted Items"));
            bool has_deleted = false;
            foreach (var c in top.children) if (c.name == deleted.name) has_deleted = true;
            if (!has_deleted) ipm.children.add (deleted);
            ipm.children.add_all (top.children);
            if (top.messages.size > 0) {
                var loose = new PstExportFolder (top.name);
                loose.messages.add_all (top.messages);
                loose.flags.add_all (top.flags);
                ipm.children.add (loose);
            }
            write_folder (ipm, 0x122, 0x8022);
            uint64 nbt = write_btree (true);
            uint64 nbt_bid = nbt_root_bid;
            uint64 bbt = write_btree (false);
            while (offset_now () % 512 != 0) body.append ({ 0 });
            uint64 eof = offset_now ();
            var file = new uint8[DATA_START];
            p32 (file, 0, 0x4E444221);
            p16 (file, 8, 0x4D53);
            p16 (file, 10, 23);
            p16 (file, 12, 19);
            file[14] = 1;
            file[15] = 1;
            p64 (file, 32, next_page_bid);
            p32 (file, 40, 1);
            for (int i = 0; i < 32; i++) p32 (file, 44 + i * 4, next_nid[i]);
            p64 (file, 184, eof);
            p64 (file, 192, 0x4400);
            p64 (file, 216, nbt_bid);
            p64 (file, 224, nbt);
            p64 (file, 232, bbt_root_bid);
            p64 (file, 240, bbt);
            file[248] = 0;
            for (int i = 256; i < 512; i++) file[i] = 0xFF;
            file[512] = 0x80;
            file[513] = 0;
            p64 (file, 516, next_bid);
            p32 (file, 4, crc (file[8:8 + 471], 471));
            p32 (file, 524, crc (file[8:8 + 516], 516));
            var amap = new uint8[512];
            for (int i = 0; i < 496; i++) amap[i] = 0xFF;
            amap[496] = 0x84;
            amap[497] = 0x84;
            p32 (amap, 500, crc (amap, 496));
            p64 (amap, 504, 0x4400);
            Memory.copy (&file[0x4400], amap, 512);
            var outb = new ByteArray ();
            outb.append (file);
            outb.append (body.data);
            return outb.steal ();
        }
    }
}
