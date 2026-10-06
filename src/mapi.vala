namespace Singularity.Apps.Lettere {

    public class MapiValue {
        public uint16 type;
        public uint8[] data;

        public MapiValue (uint16 type, uint8[] data) {
            this.type = type;
            this.data = data;
        }

        public string text () {
            if (type == 0x001F) return Mapi.utf16 (data);
            if (type == 0x001E) return Mapi.ansi (data);
            if (type == 0x0102) return Mime.bytes_to_string (data);
            return "";
        }

        public int64 integer () {
            if (data.length >= 8 && (type == 0x0014 || type == 0x0040)) return (int64) Mapi.u64 (data, 0);
            if (data.length >= 4) return (int64) Mapi.u32 (data, 0);
            if (data.length >= 2) return Mapi.u16 (data, 0);
            if (data.length >= 1) return data[0];
            return 0;
        }

        public int64 unix_time () {
            if (type != 0x0040 || data.length < 8) return 0;
            uint64 ft = Mapi.u64 (data, 0);
            if (ft < 116444736000000000) return 0;
            return (int64) ((ft - 116444736000000000) / 10000000);
        }
    }

    public abstract class MapiBag : Object {
        public abstract MapiValue? get_prop (uint16 id);
        public abstract Gee.List<MapiBag> recipients ();
        public abstract Gee.List<MapiBag> attachments ();
        public abstract MapiBag? embedded ();

        public string str (uint16 id) {
            var v = get_prop (id);
            return v != null ? v.text ().replace ("\0", "") : "";
        }

        public int64 num (uint16 id) {
            var v = get_prop (id);
            return v != null ? v.integer () : 0;
        }

        public uint8[]? bin (uint16 id) {
            var v = get_prop (id);
            return v != null ? v.data : null;
        }
    }

    namespace Mapi {
        public const uint16 SUBJECT = 0x0037;
        public const uint16 MESSAGE_CLASS = 0x001A;
        public const uint16 IMPORTANCE = 0x0017;
        public const uint16 CLIENT_SUBMIT_TIME = 0x0039;
        public const uint16 SENT_REPR_NAME = 0x0042;
        public const uint16 SENT_REPR_EMAIL = 0x0065;
        public const uint16 TRANSPORT_HEADERS = 0x007D;
        public const uint16 SENDER_NAME = 0x0C1A;
        public const uint16 SENDER_EMAIL = 0x0C1F;
        public const uint16 SENDER_ADDRTYPE = 0x0C1E;
        public const uint16 RECIPIENT_TYPE = 0x0C15;
        public const uint16 DISPLAY_CC = 0x0E03;
        public const uint16 DISPLAY_TO = 0x0E04;
        public const uint16 DELIVERY_TIME = 0x0E06;
        public const uint16 MESSAGE_FLAGS = 0x0E07;
        public const uint16 MESSAGE_SIZE = 0x0E08;
        public const uint16 BODY = 0x1000;
        public const uint16 RTF_COMPRESSED = 0x1009;
        public const uint16 HTML = 0x1013;
        public const uint16 INTERNET_MESSAGE_ID = 0x1035;
        public const uint16 INTERNET_REFERENCES = 0x1039;
        public const uint16 IN_REPLY_TO = 0x1042;
        public const uint16 FLAG_STATUS = 0x1090;
        public const uint16 DISPLAY_NAME = 0x3001;
        public const uint16 ADDRTYPE = 0x3002;
        public const uint16 EMAIL_ADDRESS = 0x3003;
        public const uint16 CONTENT_COUNT = 0x3602;
        public const uint16 CONTENT_UNREAD = 0x3603;
        public const uint16 CONTAINER_CLASS = 0x3613;
        public const uint16 ATTACH_DATA = 0x3701;
        public const uint16 ATTACH_FILENAME = 0x3704;
        public const uint16 ATTACH_METHOD = 0x3705;
        public const uint16 ATTACH_LONG_FILENAME = 0x3707;
        public const uint16 ATTACH_MIME = 0x370E;
        public const uint16 ATTACH_CONTENT_ID = 0x3712;
        public const uint16 SMTP_ADDRESS = 0x39FE;
        public const uint16 SENDER_SMTP = 0x5D01;
        public const uint16 SENT_REPR_SMTP = 0x5D02;
        public const uint16 IPM_SUBTREE_ENTRYID = 0x35E0;

        public uint16 u16 (uint8[] d, int o) {
            if (o + 2 > d.length) return 0;
            return (uint16) (d[o] | (d[o + 1] << 8));
        }

        public uint32 u32 (uint8[] d, int o) {
            if (o + 4 > d.length) return 0;
            return (uint32) d[o] | ((uint32) d[o + 1] << 8) | ((uint32) d[o + 2] << 16) | ((uint32) d[o + 3] << 24);
        }

        public uint64 u64 (uint8[] d, int o) {
            return (uint64) u32 (d, o) | ((uint64) u32 (d, o + 4) << 32);
        }

        public string utf16 (uint8[] d) {
            var sb = new StringBuilder ();
            int n = d.length / 2;
            for (int i = 0; i < n; i++) {
                uint c = u16 (d, i * 2);
                if (c == 0) break;
                if (c >= 0xD800 && c <= 0xDBFF && i + 1 < n) {
                    uint lo = u16 (d, (i + 1) * 2);
                    if (lo >= 0xDC00 && lo <= 0xDFFF) {
                        sb.append_unichar ((unichar) (0x10000 + ((c - 0xD800) << 10) + (lo - 0xDC00)));
                        i++;
                        continue;
                    }
                }
                sb.append_unichar ((unichar) c);
            }
            return sb.str;
        }

        public string ansi (uint8[] d) {
            int n = d.length;
            while (n > 0 && d[n - 1] == 0) n--;
            return Mime.to_utf8 (d[0:n], "windows-1252");
        }

        public string rfc_date (int64 t) {
            return Mime.format_date (new DateTime.from_unix_local (t > 0 ? t : new DateTime.now_utc ().to_unix ()));
        }

        private string address_of (MapiBag r) {
            string email = r.str (SMTP_ADDRESS);
            if (email == "") email = r.str (EMAIL_ADDRESS);
            if (!email.contains ("@")) {
                string alt = r.str (0x39FF);
                if (alt.contains ("@")) email = alt;
            }
            return new Address (r.str (DISPLAY_NAME), email).to_header ();
        }

        private string strip_mime_headers (string headers) {
            var sb = new StringBuilder ();
            bool skip = false;
            foreach (string line in headers.replace ("\r\n", "\n").split ("\n")) {
                if (line == "") continue;
                if (line[0] == ' ' || line[0] == '\t') {
                    if (!skip) sb.append (line + "\r\n");
                    continue;
                }
                string low = line.down ();
                skip = low.has_prefix ("content-type:") || low.has_prefix ("content-transfer-encoding:") || low.has_prefix ("mime-version:") || low.has_prefix ("content-disposition:");
                if (!skip) sb.append (line + "\r\n");
            }
            return sb.str;
        }

        public uint8[] to_mime (MapiBag bag, int depth = 0) {
            var b = new MessageBuilder ();
            string sender = bag.str (SENDER_SMTP);
            if (sender == "") sender = bag.str (SENDER_EMAIL);
            if (!sender.contains ("@")) {
                string repr = bag.str (SENT_REPR_SMTP);
                if (repr == "") repr = bag.str (SENT_REPR_EMAIL);
                if (repr.contains ("@")) sender = repr;
            }
            b.from = new Address (bag.str (SENDER_NAME) != "" ? bag.str (SENDER_NAME) : bag.str (SENT_REPR_NAME), sender);
            foreach (var r in bag.recipients ()) {
                var list = Mime.parse_addresses (address_of (r));
                int64 kind = r.num (RECIPIENT_TYPE);
                if (kind == 2) b.cc.add_all (list);
                else if (kind == 3) b.bcc.add_all (list);
                else b.to.add_all (list);
            }
            b.subject = bag.str (SUBJECT);
            var t = bag.get_prop (DELIVERY_TIME) ?? bag.get_prop (CLIENT_SUBMIT_TIME);
            int64 when = t != null ? t.unix_time () : 0;
            b.date = new DateTime.from_unix_local (when > 0 ? when : new DateTime.now_utc ().to_unix ());
            b.message_id = Mime.first_id (bag.str (INTERNET_MESSAGE_ID));
            if (b.message_id == "") b.message_id = Mime.new_message_id (sender.contains ("@") ? sender : "import.lettere");
            b.in_reply_to = Mime.first_id (bag.str (IN_REPLY_TO));
            b.references = string.joinv (" ", Mime.parse_ids (bag.str (INTERNET_REFERENCES)));
            int64 imp = bag.num (IMPORTANCE);
            b.importance = imp == 2 ? 1 : (imp == 0 && bag.get_prop (IMPORTANCE) != null ? -1 : 0);
            string text = bag.str (BODY);
            string html = "";
            var hv = bag.get_prop (HTML);
            if (hv != null) html = hv.type == 0x0102 ? Mime.bytes_to_string (hv.data) : hv.text ();
            if (html == "") {
                var rtf = bag.bin (RTF_COMPRESSED);
                if (rtf != null && rtf.length > 16) {
                    string plain_rtf = Rtf.decompress (rtf);
                    string from_html = Rtf.html_of (plain_rtf);
                    if (from_html != "") html = from_html;
                    else if (text == "") text = Rtf.text_of (plain_rtf);
                }
            }
            if (text == "" && html != "") text = Html.to_text (html);
            b.text = text;
            if (html != "") b.html = html;
            foreach (var a in bag.attachments ()) {
                int64 method = a.num (ATTACH_METHOD);
                string name = a.str (ATTACH_LONG_FILENAME);
                if (name == "") name = a.str (ATTACH_FILENAME);
                if (name == "") name = a.str (DISPLAY_NAME);
                if (method == 5) {
                    var inner = a.embedded ();
                    if (inner == null || depth > 4) continue;
                    var raw = to_mime (inner, depth + 1);
                    string subj = inner.str (SUBJECT);
                    b.attachments.add (new OutgoingAttachment ((subj != "" ? subj : "message") + ".eml", "message/rfc822", new Bytes (raw)));
                    continue;
                }
                var data = a.bin (ATTACH_DATA);
                if (data == null) continue;
                string mime = a.str (ATTACH_MIME);
                if (mime == "") mime = ContentType.get_mime_type (ContentType.guess (name, data, null)) ?? "application/octet-stream";
                string cid = Mime.first_id (a.str (ATTACH_CONTENT_ID));
                var att = new OutgoingAttachment (name != "" ? name : "attachment", mime, new Bytes (data));
                if (cid != "" && html != "" && html.contains ("cid:" + cid)) {
                    att.content_id = cid;
                    b.inline_images.add (att);
                } else {
                    b.attachments.add (att);
                }
            }
            string transport = bag.str (TRANSPORT_HEADERS);
            if (transport.strip () != "" && transport.contains (":")) {
                var body = new ByteArray ();
                body.append (strip_mime_headers (transport).data);
                if (!transport.down ().contains ("\nmime-version:")) body.append ("MIME-Version: 1.0\r\n".data);
                else body.append ("MIME-Version: 1.0\r\n".data);
                body.append (b.entity ().data);
                return body.steal ();
            }
            return b.build (true);
        }

        public int flags_of (MapiBag bag) {
            int f = 0;
            if ((bag.num (MESSAGE_FLAGS) & 1) != 0) f |= MessageFlags.SEEN;
            if ((bag.num (MESSAGE_FLAGS) & 8) != 0) f |= MessageFlags.DRAFT;
            int64 fs = bag.num (FLAG_STATUS);
            if (fs == 2) f |= MessageFlags.FLAGGED;
            if (fs == 1) f |= MessageFlags.FLAGGED | MessageFlags.COMPLETED;
            return f;
        }
    }

    namespace Rtf {
        private const string PREBUF = "{\\rtf1\\ansi\\mac\\deff0\\deftab720{\\fonttbl;}{\\f0\\fnil \\froman \\fswiss \\fmodern \\fscript \\fdecor MS Sans SerifSymbolArialTimes New RomanCourier{\\colortbl\\red0\\green0\\blue0\r\n\\par \\pard\\plain\\f0\\fs20\\b\\i\\u\\tab\\tx";

        public string decompress (uint8[] data) {
            if (data.length < 16) return "";
            uint32 comp_size = Mapi.u32 (data, 0);
            uint32 raw_size = Mapi.u32 (data, 4);
            uint32 magic = Mapi.u32 (data, 8);
            if (magic == 0x414C454D) {
                int n = int.min ((int) raw_size, data.length - 16);
                return Mapi.ansi (data[16:16 + n]);
            }
            if (magic != 0x75465A4C) return "";
            var dict = new uint8[4096];
            int pre = PREBUF.length;
            for (int i = 0; i < pre; i++) dict[i] = (uint8) PREBUF[i];
            int wpos = pre;
            var outb = new ByteArray ();
            int pos = 16;
            int end = int.min (data.length, (int) comp_size + 4);
            while (pos < end && outb.len < raw_size) {
                uint8 control = data[pos++];
                for (int bit = 0; bit < 8 && pos < end; bit++) {
                    if ((control & (1 << bit)) != 0) {
                        if (pos + 1 >= end) break;
                        int token = (data[pos] << 8) | data[pos + 1];
                        pos += 2;
                        int offset = (token >> 4) & 0xFFF;
                        int length = (token & 0xF) + 2;
                        if (offset == wpos) return (string) outb.data;
                        for (int k = 0; k < length; k++) {
                            uint8 c = dict[(offset + k) & 0xFFF];
                            outb.append ({ c });
                            dict[wpos] = c;
                            wpos = (wpos + 1) & 0xFFF;
                        }
                    } else {
                        uint8 c = data[pos++];
                        outb.append ({ c });
                        dict[wpos] = c;
                        wpos = (wpos + 1) & 0xFFF;
                    }
                }
            }
            outb.append ({ 0 });
            return Mapi.ansi (outb.data);
        }

        public string html_of (string rtf) {
            if (!rtf.contains ("\\fromhtml")) return "";
            var sb = new StringBuilder ();
            int i = 0;
            int n = rtf.length;
            int depth = 0;
            int skip_depth = -1;
            int html_depth = -1;
            while (i < n) {
                char c = rtf[i];
                if (c == '{') {
                    depth++;
                    i++;
                    if (i < n && rtf[i] == '\\' && rtf.substring (i).has_prefix ("\\*\\htmltag")) {
                        html_depth = depth;
                        i += 10;
                        while (i < n && rtf[i].isdigit ()) i++;
                        if (i < n && rtf[i] == ' ') i++;
                    } else if (i < n && rtf[i] == '\\' && rtf.substring (i).has_prefix ("\\*") && skip_depth < 0) {
                        skip_depth = depth;
                    }
                    continue;
                }
                if (c == '}') {
                    if (depth == skip_depth) skip_depth = -1;
                    if (depth == html_depth) html_depth = -1;
                    depth--;
                    i++;
                    continue;
                }
                if (c == '\r' || c == '\n') {
                    i++;
                    continue;
                }
                if (c == '\\') {
                    i++;
                    if (i >= n) break;
                    char d = rtf[i];
                    if (d == '\\' || d == '{' || d == '}') {
                        if (skip_depth < 0) sb.append_c (d);
                        i++;
                        continue;
                    }
                    if (d == '\'') {
                        if (i + 2 < n) {
                            int64 v;
                            if (int64.try_parse (rtf.substring (i + 1, 2), out v, null, 16) && skip_depth < 0) sb.append (Mime.to_utf8 ({ (uint8) v }, "windows-1252"));
                        }
                        i += 3;
                        continue;
                    }
                    var word = new StringBuilder ();
                    while (i < n && rtf[i].isalpha ()) word.append_c (rtf[i++]);
                    var num = new StringBuilder ();
                    if (i < n && rtf[i] == '-') num.append_c (rtf[i++]);
                    while (i < n && rtf[i].isdigit ()) num.append_c (rtf[i++]);
                    if (i < n && rtf[i] == ' ') i++;
                    string w = word.str;
                    if (skip_depth >= 0) continue;
                    bool in_tag = html_depth >= 0;
                    if (w == "par" && !in_tag) sb.append ("\r\n");
                    else if (w == "tab") sb.append ("\t");
                    else if (w == "u" && num.len > 0) {
                        int64 v = int64.parse (num.str);
                        if (v < 0) v += 65536;
                        sb.append_unichar ((unichar) v);
                        if (i < n && rtf[i] == '?') i++;
                    } else if (w == "htmlrtf") {
                        bool on = num.str != "0";
                        if (on) {
                            int close = rtf.index_of ("\\htmlrtf0", i);
                            if (close > 0) i = close + 9;
                            if (i < n && rtf[i] == ' ') i++;
                        }
                    }
                    continue;
                }
                if (skip_depth < 0) sb.append_c (c);
                i++;
            }
            return sb.str;
        }

        public string text_of (string rtf) {
            var sb = new StringBuilder ();
            int i = 0;
            int n = rtf.length;
            int depth = 0;
            int skip = -1;
            while (i < n) {
                char c = rtf[i];
                if (c == '{') {
                    depth++;
                    i++;
                    if (i < n && rtf.substring (i).has_prefix ("\\*") && skip < 0) skip = depth;
                    else if (skip < 0 && (rtf.substring (i).has_prefix ("\\fonttbl") || rtf.substring (i).has_prefix ("\\colortbl") || rtf.substring (i).has_prefix ("\\stylesheet") || rtf.substring (i).has_prefix ("\\info"))) skip = depth;
                    continue;
                }
                if (c == '}') {
                    if (depth == skip) skip = -1;
                    depth--;
                    i++;
                    continue;
                }
                if (c == '\r' || c == '\n') {
                    i++;
                    continue;
                }
                if (c == '\\') {
                    i++;
                    if (i >= n) break;
                    char d = rtf[i];
                    if (d == '\\' || d == '{' || d == '}') {
                        if (skip < 0) sb.append_c (d);
                        i++;
                        continue;
                    }
                    if (d == '\'') {
                        int64 v = 0;
                        if (i + 2 < n && int64.try_parse (rtf.substring (i + 1, 2), out v, null, 16) && skip < 0) sb.append (Mime.to_utf8 ({ (uint8) v }, "windows-1252"));
                        i += 3;
                        continue;
                    }
                    var word = new StringBuilder ();
                    while (i < n && rtf[i].isalpha ()) word.append_c (rtf[i++]);
                    var num = new StringBuilder ();
                    if (i < n && rtf[i] == '-') num.append_c (rtf[i++]);
                    while (i < n && rtf[i].isdigit ()) num.append_c (rtf[i++]);
                    if (i < n && rtf[i] == ' ') i++;
                    if (skip >= 0) continue;
                    if (word.str == "par" || word.str == "line") sb.append ("\n");
                    else if (word.str == "tab") sb.append ("\t");
                    else if (word.str == "u" && num.len > 0) {
                        int64 v = int64.parse (num.str);
                        if (v < 0) v += 65536;
                        sb.append_unichar ((unichar) v);
                        if (i < n && rtf[i] == '?') i++;
                    }
                    continue;
                }
                if (skip < 0) sb.append_c (c);
                i++;
            }
            return sb.str.strip ();
        }
    }
}
