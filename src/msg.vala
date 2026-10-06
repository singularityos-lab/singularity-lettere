namespace Singularity.Apps.Lettere {

    public class CfbEntry {
        public string name = "";
        public int type;
        public uint32 left;
        public uint32 right;
        public uint32 child;
        public uint32 start;
        public uint64 size;
        public Gee.ArrayList<CfbEntry> children = new Gee.ArrayList<CfbEntry> ();
    }

    public class CfbFile : Object {
        private uint8[] data;
        private int sector_size;
        private int mini_size;
        private uint32 mini_cutoff;
        private Gee.ArrayList<uint32> fat = new Gee.ArrayList<uint32> ();
        private Gee.ArrayList<uint32> minifat = new Gee.ArrayList<uint32> ();
        private Gee.ArrayList<CfbEntry> entries = new Gee.ArrayList<CfbEntry> ();
        private uint8[] ministream = {};
        public CfbEntry root;

        public static bool is_cfb (uint8[] d) {
            return d.length > 512 && d[0] == 0xD0 && d[1] == 0xCF && d[2] == 0x11 && d[3] == 0xE0 && d[4] == 0xA1 && d[5] == 0xB1 && d[6] == 0x1A && d[7] == 0xE1;
        }

        public CfbFile (uint8[] bytes) throws Error {
            data = bytes;
            if (!is_cfb (data)) throw new PstError.FORMAT (_("This is not an Outlook message file"));
            sector_size = 1 << Mapi.u16 (data, 0x1E);
            mini_size = 1 << Mapi.u16 (data, 0x20);
            uint32 fat_sectors = Mapi.u32 (data, 0x2C);
            uint32 dir_start = Mapi.u32 (data, 0x30);
            mini_cutoff = Mapi.u32 (data, 0x38);
            uint32 minifat_start = Mapi.u32 (data, 0x3C);
            uint32 difat_start = Mapi.u32 (data, 0x44);
            uint32 difat_count = Mapi.u32 (data, 0x48);
            var fat_list = new Gee.ArrayList<uint32> ();
            for (int i = 0; i < 109 && fat_list.size < fat_sectors; i++) {
                uint32 s = Mapi.u32 (data, 0x4C + i * 4);
                if (s >= 0xFFFFFFFA) break;
                fat_list.add (s);
            }
            uint32 d = difat_start;
            for (uint32 k = 0; k < difat_count && d < 0xFFFFFFFA && fat_list.size < fat_sectors; k++) {
                int per = sector_size / 4 - 1;
                for (int i = 0; i < per && fat_list.size < fat_sectors; i++) {
                    uint32 s = Mapi.u32 (data, (int) offset (d) + i * 4);
                    if (s >= 0xFFFFFFFA) continue;
                    fat_list.add (s);
                }
                d = Mapi.u32 (data, (int) offset (d) + per * 4);
            }
            foreach (uint32 s in fat_list) {
                int o = (int) offset (s);
                for (int i = 0; i < sector_size / 4; i++) fat.add (Mapi.u32 (data, o + i * 4));
            }
            var mf = chain (minifat_start);
            for (int i = 0; i + 4 <= mf.length; i += 4) minifat.add (Mapi.u32 (mf, i));
            var dir = chain (dir_start);
            for (int o = 0; o + 128 <= dir.length; o += 128) {
                var e = new CfbEntry ();
                int name_len = Mapi.u16 (dir, o + 64);
                e.name = name_len >= 2 ? Mapi.utf16 (dir[o:o + int.min (64, name_len)]) : "";
                e.type = dir[o + 66];
                e.left = Mapi.u32 (dir, o + 68);
                e.right = Mapi.u32 (dir, o + 72);
                e.child = Mapi.u32 (dir, o + 76);
                e.start = Mapi.u32 (dir, o + 116);
                e.size = Mapi.u32 (dir, o + 120);
                entries.add (e);
            }
            if (entries.size == 0) throw new PstError.FORMAT (_("The Outlook message file is damaged"));
            root = entries[0];
            ministream = chain (root.start);
            link (root, 0);
        }

        private uint64 offset (uint32 sector) {
            return (uint64) (sector + 1) * sector_size;
        }

        private uint8[] chain (uint32 start) {
            var outb = new ByteArray ();
            uint32 s = start;
            int guard = 0;
            while (s < 0xFFFFFFFA && guard++ < 1000000) {
                uint64 o = offset (s);
                if (o + sector_size > data.length) break;
                outb.append (data[o:o + sector_size]);
                if (s >= fat.size) break;
                s = fat[(int) s];
            }
            return outb.steal ();
        }

        private uint8[] mini_chain (uint32 start, uint64 size) {
            var outb = new ByteArray ();
            uint32 s = start;
            int guard = 0;
            while (s < 0xFFFFFFFA && outb.len < size && guard++ < 1000000) {
                uint64 o = (uint64) s * mini_size;
                if (o + mini_size > ministream.length) break;
                outb.append (ministream[o:o + mini_size]);
                if (s >= minifat.size) break;
                s = minifat[(int) s];
            }
            return outb.steal ();
        }

        private void link (CfbEntry parent, int depth) {
            if (depth > 64 || parent.child >= entries.size) return;
            var stack = new Gee.ArrayList<uint32> ();
            stack.add (parent.child);
            int guard = 0;
            while (stack.size > 0 && guard++ < 100000) {
                uint32 id = stack.remove_at (stack.size - 1);
                if (id >= entries.size) continue;
                var e = entries[(int) id];
                parent.children.add (e);
                if (e.left < entries.size) stack.add (e.left);
                if (e.right < entries.size) stack.add (e.right);
                if (e.type == 1) link (e, depth + 1);
            }
        }

        public uint8[] read (CfbEntry e) {
            if (e.size < mini_cutoff && e.type == 2) {
                var d = mini_chain (e.start, e.size);
                return d.length > e.size ? d[0:e.size] : d;
            }
            var d = chain (e.start);
            return d.length > e.size ? d[0:e.size] : d;
        }

        public static CfbEntry? child (CfbEntry parent, string name) {
            foreach (var c in parent.children) if (c.name.down () == name.down ()) return c;
            return null;
        }
    }

    public class MsgBag : MapiBag {
        private CfbFile file;
        private CfbEntry storage;
        private int header;
        private Gee.HashMap<uint16, MapiValue>? props;

        public MsgBag (CfbFile file, CfbEntry storage, int header) {
            this.file = file;
            this.storage = storage;
            this.header = header;
        }

        private void load () {
            props = new Gee.HashMap<uint16, MapiValue> ();
            var stream = CfbFile.child (storage, "__properties_version1.0");
            if (stream == null) return;
            var d = file.read (stream);
            for (int o = header; o + 16 <= d.length; o += 16) {
                uint32 tag = Mapi.u32 (d, o);
                uint16 type = (uint16) (tag & 0xFFFF);
                uint16 id = (uint16) (tag >> 16);
                if (type == 0x001F || type == 0x001E || type == 0x0102 || type == 0x000D || (type & 0x1000) != 0 || type == 0x0048) {
                    var sub = CfbFile.child (storage, "__substg1.0_%04X%04X".printf (id, type));
                    if (sub == null) continue;
                    props[id] = new MapiValue (type, sub.type == 2 ? file.read (sub) : new uint8[0]);
                    continue;
                }
                props[id] = new MapiValue (type, d[o + 8:o + 16]);
            }
        }

        public override MapiValue? get_prop (uint16 id) {
            if (props == null) load ();
            return props[id];
        }

        public override Gee.List<MapiBag> recipients () {
            var list = new Gee.ArrayList<MapiBag> ();
            var names = new Gee.ArrayList<CfbEntry> ();
            foreach (var c in storage.children) if (c.name.has_prefix ("__recip_version1.0_")) names.add (c);
            names.sort ((a, b) => strcmp (a.name, b.name));
            foreach (var c in names) list.add (new MsgBag (file, c, 8));
            return list;
        }

        public override Gee.List<MapiBag> attachments () {
            var list = new Gee.ArrayList<MapiBag> ();
            var names = new Gee.ArrayList<CfbEntry> ();
            foreach (var c in storage.children) if (c.name.has_prefix ("__attach_version1.0_")) names.add (c);
            names.sort ((a, b) => strcmp (a.name, b.name));
            foreach (var c in names) list.add (new MsgBag (file, c, 8));
            return list;
        }

        public override MapiBag? embedded () {
            var sub = CfbFile.child (storage, "__substg1.0_3701000D");
            if (sub == null) return null;
            return new MsgBag (file, sub, 24);
        }
    }

    namespace MsgFile {
        public bool is_msg (uint8[] data) {
            return CfbFile.is_cfb (data);
        }

        public uint8[] to_mime (uint8[] data) throws Error {
            var cfb = new CfbFile (data);
            return Mapi.to_mime (new MsgBag (cfb, cfb.root, 32));
        }
    }
}
