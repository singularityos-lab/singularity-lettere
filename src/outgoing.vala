namespace Singularity.Apps.Lettere {

    public class Outgoing : Object {
        public uint8[] raw;
        public string subject = "";
        public Gee.ArrayList<string> recipients = new Gee.ArrayList<string> ();
        private string from_email = "";

        public Outgoing (owned uint8[] raw) {
            this.raw = (owned) raw;
            var m = new MimeMessage (this.raw);
            subject = m.subject;
            var seen = new Gee.HashSet<string> ();
            foreach (string h in new string[] { "To", "Cc", "Bcc" }) {
                foreach (var a in Mime.parse_addresses (m.root.header (h) ?? "")) {
                    if (a.email != "" && seen.add (a.email.down ())) recipients.add (a.email);
                }
            }
            var from = Mime.parse_addresses (m.root.header ("From") ?? "");
            if (from.size > 0) from_email = from[0].email.down ();
        }

        public static uint8[] normalize (uint8[] data) {
            var b = new ByteArray ();
            for (int i = 0; i < data.length; i++) {
                if (data[i] == '\n' && (i == 0 || data[i - 1] != '\r')) b.append ({ '\r' });
                b.append ({ data[i] });
            }
            return b.steal ();
        }

        public Address pick_from (Account a) {
            foreach (var id in a.identity_list ()) {
                if (id.email.down () == from_email) return id;
            }
            return a.address ();
        }

        public uint8[] with_from (Address from) {
            int end = raw.length;
            for (int i = 0; i + 3 < raw.length; i++) {
                if (raw[i] == '\r' && raw[i + 1] == '\n' && raw[i + 2] == '\r' && raw[i + 3] == '\n') {
                    end = i;
                    break;
                }
            }
            string head = Mime.bytes_to_string (raw[0:end]);
            var sb = new StringBuilder ();
            bool skipping = false;
            bool has_date = false;
            bool has_id = false;
            bool has_version = false;
            foreach (string line in head.split ("\r\n")) {
                if (line == "") continue;
                if (line[0] == ' ' || line[0] == '\t') {
                    if (!skipping) sb.append (line + "\r\n");
                    continue;
                }
                string low = line.down ();
                skipping = low.has_prefix ("from:") || low.has_prefix ("sender:") || low.has_prefix ("bcc:");
                if (low.has_prefix ("date:")) has_date = true;
                if (low.has_prefix ("message-id:")) has_id = true;
                if (low.has_prefix ("mime-version:")) has_version = true;
                if (!skipping) sb.append (line + "\r\n");
            }
            var top = new StringBuilder ();
            top.append ("From: %s\r\n".printf (from.to_header ()));
            if (!has_date) top.append ("Date: %s\r\n".printf (Mime.format_date (new DateTime.now_local ())));
            if (!has_id) {
                string domain = from.email.contains ("@") ? from.email.substring (from.email.index_of_char ('@') + 1) : "localhost";
                top.append ("Message-ID: <%s@%s>\r\n".printf (Uuid.string_random (), domain));
            }
            if (!has_version) top.append ("MIME-Version: 1.0\r\n");
            var b = new ByteArray ();
            b.append (top.str.data);
            b.append (sb.str.data);
            if (end < raw.length) b.append (raw[end + 2:raw.length]);
            else b.append ("\r\n".data);
            return b.steal ();
        }
    }
}
