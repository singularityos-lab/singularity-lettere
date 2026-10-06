namespace Singularity.Apps.Lettere {

    namespace Mbox {
        public Gee.ArrayList<Bytes> split (uint8[] data) {
            var list = new Gee.ArrayList<Bytes> ();
            int n = data.length;
            int start = -1;
            int i = 0;
            while (i < n) {
                bool line_start = i == 0 || (data[i - 1] == '\n' && (i < 2 || data[i - 2] == '\n' || (i >= 3 && data[i - 2] == '\r' && data[i - 3] == '\n')));
                if (line_start && i + 5 <= n && data[i] == 'F' && data[i + 1] == 'r' && data[i + 2] == 'o' && data[i + 3] == 'm' && data[i + 4] == ' ' && looks_like_separator (data, i)) {
                    if (start >= 0) list.add (new Bytes (unescape (data[start:i])));
                    int nl = i;
                    while (nl < n && data[nl] != '\n') nl++;
                    start = nl + 1;
                    i = start;
                    continue;
                }
                i++;
            }
            if (start >= 0 && start < n) list.add (new Bytes (unescape (data[start:n])));
            return list;
        }

        private bool looks_like_separator (uint8[] data, int start) {
            int e = start;
            while (e < data.length && data[e] != '\n') e++;
            string line = Mime.bytes_to_string (data[start:e]).strip ();
            string[] parts = line.split (" ");
            if (parts.length < 3) return false;
            string last = parts[parts.length - 1];
            bool year = false;
            foreach (string p in parts) if (p.length == 4 && p[0].isdigit () && p[3].isdigit ()) year = true;
            return year || last.contains (":");
        }

        private uint8[] unescape (uint8[] msg) {
            var outb = new ByteArray ();
            int n = msg.length;
            while (n > 0 && (msg[n - 1] == '\n' || msg[n - 1] == '\r')) n--;
            int i = 0;
            while (i < n) {
                int e = i;
                while (e < n && msg[e] != '\n') e++;
                int k = i;
                while (k < e && msg[k] == '>') k++;
                if (k > i && k + 5 <= e && msg[k] == 'F' && msg[k + 1] == 'r' && msg[k + 2] == 'o' && msg[k + 3] == 'm' && msg[k + 4] == ' ') i++;
                outb.append (msg[i:e]);
                if (e < n) {
                    if (e == 0 || msg[e - 1] != '\r') outb.append ("\r\n".data);
                    else outb.append ("\n".data);
                }
                i = e + 1;
            }
            outb.append ("\r\n".data);
            return outb.steal ();
        }

        public int flags_of (uint8[] raw) {
            var part = Mime.parse_part (raw, "1", 0);
            int f = 0;
            string status = (part.header ("Status") ?? "") + (part.header ("X-Status") ?? "");
            if (status.contains ("R")) f |= MessageFlags.SEEN;
            if (status.contains ("F")) f |= MessageFlags.FLAGGED;
            if (status.contains ("A")) f |= MessageFlags.ANSWERED;
            string moz = part.header ("X-Mozilla-Status") ?? "";
            if (moz != "") {
                int64 v;
                if (int64.try_parse (moz.strip (), out v, null, 16)) {
                    if ((v & 0x1) != 0) f |= MessageFlags.SEEN;
                    if ((v & 0x2) != 0) f |= MessageFlags.ANSWERED;
                    if ((v & 0x4) != 0) f |= MessageFlags.FLAGGED;
                    if ((v & 0x8) != 0) f |= MessageFlags.DELETED;
                }
            }
            return f;
        }

        public string escape (uint8[] raw, string sender, int64 date) {
            var sb = new StringBuilder ();
            var d = new DateTime.from_unix_utc (date > 0 ? date : new DateTime.now_utc ().to_unix ());
            sb.append ("From %s %s\n".printf (sender != "" ? sender : "MAILER-DAEMON", d.format ("%a %b %e %H:%M:%S %Y")));
            foreach (string line in Mime.bytes_to_string (raw).replace ("\r\n", "\n").split ("\n")) {
                int k = 0;
                while (k < line.length && line[k] == '>') k++;
                if (line.substring (k).has_prefix ("From ")) sb.append (">");
                sb.append (line + "\n");
            }
            if (!sb.str.has_suffix ("\n\n")) sb.append ("\n");
            return sb.str;
        }
    }
}
