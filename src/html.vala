namespace Singularity.Apps.Lettere.Html {

    public string escape (string text) {
        return text.replace ("&", "&amp;").replace ("<", "&lt;").replace (">", "&gt;").replace ("\"", "&quot;");
    }

    private string entity (string name) {
        switch (name) {
            case "amp": return "&";
            case "lt": return "<";
            case "gt": return ">";
            case "quot": return "\"";
            case "apos": return "'";
            case "nbsp": return " ";
            case "copy": return "©";
            case "reg": return "®";
            case "hellip": return "...";
            case "mdash": return "-";
            case "ndash": return "-";
            case "laquo": return "«";
            case "raquo": return "»";
            case "rsquo": return "'";
            case "lsquo": return "'";
            case "rdquo": return "\"";
            case "ldquo": return "\"";
            case "euro": return "€";
            case "zwnj": return "";
            case "shy": return "";
        }
        if (name.has_prefix ("#x") || name.has_prefix ("#X")) {
            int64 v;
            if (int64.try_parse (name.substring (2), out v, null, 16) && v > 0 && v < 0x110000) return ((unichar) v).to_string ();
        } else if (name.has_prefix ("#")) {
            int64 v;
            if (int64.try_parse (name.substring (1), out v) && v > 0 && v < 0x110000) return ((unichar) v).to_string ();
        }
        return "&" + name + ";";
    }

    public string decode_entities (string s) {
        if (!s.contains ("&")) return s;
        var sb = new StringBuilder ();
        int i = 0;
        while (i < s.length) {
            if (s[i] == '&') {
                int semi = s.index_of_char (';', i);
                if (semi > i && semi - i < 12) {
                    sb.append (entity (s.substring (i + 1, semi - i - 1)));
                    i = semi + 1;
                    continue;
                }
            }
            sb.append_c (s[i]);
            i++;
        }
        return sb.str;
    }

    public string to_text (string html) {
        var sb = new StringBuilder ();
        int i = 0;
        int n = html.length;
        string skip_until = "";
        while (i < n) {
            char c = html[i];
            if (c == '<') {
                int end = html.index_of_char ('>', i);
                if (end < 0) break;
                string tag = html.substring (i + 1, end - i - 1).strip ().down ();
                string tname = tag;
                int sp = tname.index_of_char (' ');
                if (sp > 0) tname = tname.substring (0, sp);
                if (tname.has_suffix ("/")) tname = tname.substring (0, tname.length - 1);
                if (skip_until != "") {
                    if (tname == "/" + skip_until) skip_until = "";
                    i = end + 1;
                    continue;
                }
                if (tag.has_prefix ("!--")) {
                    int cend = html.index_of ("-->", i);
                    i = cend < 0 ? n : cend + 3;
                    continue;
                }
                switch (tname) {
                    case "style":
                    case "script":
                    case "head":
                    case "title":
                        skip_until = tname;
                        break;
                    case "br":
                        sb.append_c ('\n');
                        break;
                    case "p":
                    case "/p":
                    case "div":
                    case "/div":
                    case "tr":
                    case "/table":
                    case "h1":
                    case "h2":
                    case "h3":
                    case "/h1":
                    case "/h2":
                    case "/h3":
                    case "blockquote":
                    case "/blockquote":
                        if (sb.len > 0 && !sb.str.has_suffix ("\n")) sb.append_c ('\n');
                        break;
                    case "li":
                        if (sb.len > 0 && !sb.str.has_suffix ("\n")) sb.append_c ('\n');
                        sb.append ("• ");
                        break;
                    case "td":
                        sb.append_c (' ');
                        break;
                }
                i = end + 1;
                continue;
            }
            if (skip_until != "") {
                i++;
                continue;
            }
            if (c == '\r' || c == '\n' || c == '\t') {
                if (sb.len > 0 && !sb.str.has_suffix (" ") && !sb.str.has_suffix ("\n")) sb.append_c (' ');
                i++;
                continue;
            }
            sb.append_c (c);
            i++;
        }
        string text = decode_entities (sb.str);
        var lines = new StringBuilder ();
        int blank = 0;
        foreach (string line in text.split ("\n")) {
            string t = line.strip ();
            if (t == "") {
                blank++;
                if (blank > 1) continue;
            } else {
                blank = 0;
            }
            lines.append (t);
            lines.append_c ('\n');
        }
        return lines.str.strip ();
    }

    private class MarkupWriter {
        public StringBuilder result = new StringBuilder ();
        public int bold;
        public int italic;
        public int underline;
        public int heading;
        private StringBuilder run = new StringBuilder ();
        private char last = '\n';

        public void text (string s) {
            if (s == "") return;
            run.append (s);
            last = s[s.length - 1];
        }

        public void space () {
            if (last != ' ' && last != '\n') text (" ");
        }

        public void flush () {
            if (run.len == 0) return;
            string t = Markup.escape_text (decode_entities (run.str));
            run.truncate (0);
            string attrs = "";
            if (bold > 0 || heading > 0) attrs += " weight=\"bold\"";
            if (italic > 0) attrs += " style=\"italic\"";
            if (underline > 0) attrs += " underline=\"single\"";
            if (heading > 0) attrs += " size=\"%s\"".printf (heading == 1 ? "x-large" : (heading == 2 ? "large" : "medium"));
            if (attrs == "") result.append (t);
            else result.append ("<span%s>%s</span>".printf (attrs, t));
        }

        public void newline (int count) {
            flush ();
            if (result.len == 0) return;
            int have = 0;
            while (have < result.len && result.str[result.len - 1 - have] == '\n') have++;
            for (; have < count; have++) result.append_c ('\n');
            last = '\n';
        }
    }

    public string to_markup (string html) {
        var w = new MarkupWriter ();
        int i = 0;
        int n = html.length;
        string skip_until = "";
        while (i < n) {
            char c = html[i];
            if (c == '<') {
                int end = html.index_of_char ('>', i);
                if (end < 0) break;
                string tag = html.substring (i + 1, end - i - 1).strip ().down ();
                string tname = tag;
                int sp = tname.index_of_char (' ');
                if (sp > 0) tname = tname.substring (0, sp);
                if (tname.has_suffix ("/")) tname = tname.substring (0, tname.length - 1);
                if (skip_until != "") {
                    if (tname == "/" + skip_until) skip_until = "";
                    i = end + 1;
                    continue;
                }
                if (tag.has_prefix ("!--")) {
                    int cend = html.index_of ("-->", i);
                    i = cend < 0 ? n : cend + 3;
                    continue;
                }
                switch (tname) {
                    case "style":
                    case "script":
                    case "head":
                    case "title":
                        skip_until = tname;
                        break;
                    case "b":
                    case "strong":
                        w.flush ();
                        w.bold++;
                        break;
                    case "/b":
                    case "/strong":
                        w.flush ();
                        if (w.bold > 0) w.bold--;
                        break;
                    case "i":
                    case "em":
                        w.flush ();
                        w.italic++;
                        break;
                    case "/i":
                    case "/em":
                        w.flush ();
                        if (w.italic > 0) w.italic--;
                        break;
                    case "u":
                        w.flush ();
                        w.underline++;
                        break;
                    case "/u":
                        w.flush ();
                        if (w.underline > 0) w.underline--;
                        break;
                    case "h1":
                    case "h2":
                    case "h3":
                        w.newline (2);
                        w.heading = tname[1] - '0';
                        break;
                    case "/h1":
                    case "/h2":
                    case "/h3":
                        w.flush ();
                        w.heading = 0;
                        w.newline (2);
                        break;
                    case "br":
                        w.newline (1);
                        break;
                    case "p":
                    case "/p":
                        w.newline (2);
                        break;
                    case "div":
                    case "/div":
                    case "tr":
                    case "/table":
                    case "blockquote":
                    case "/blockquote":
                    case "ul":
                    case "/ul":
                    case "ol":
                    case "/ol":
                        w.newline (1);
                        break;
                    case "li":
                        w.newline (1);
                        w.text ("• ");
                        break;
                    case "td":
                        w.space ();
                        break;
                }
                i = end + 1;
                continue;
            }
            if (skip_until != "") {
                i++;
                continue;
            }
            if (c == '\r' || c == '\n' || c == '\t' || c == ' ') {
                w.space ();
                i++;
                continue;
            }
            int next = html.index_of_char ('<', i);
            if (next < 0) next = n;
            int stop = i;
            while (stop < next && html[stop] != '\r' && html[stop] != '\n' && html[stop] != '\t' && html[stop] != ' ') stop++;
            w.text (html.substring (i, stop - i));
            i = stop;
        }
        w.flush ();
        return w.result.str.strip ();
    }

    public bool has_remote (string html) {
        string low = html.down ();
        string[] keys = { "src=", "background=", "url(", "srcset=", "poster=", "href=" };
        foreach (string k in keys) {
            int pos = 0;
            while ((pos = low.index_of (k, pos)) >= 0) {
                int v = pos + k.length;
                while (v < low.length && (low[v] == '"' || low[v] == '\'' || low[v] == ' ')) v++;
                string rest = low.substring (v, int.min (8, low.length - v));
                bool remote = rest.has_prefix ("http:") || rest.has_prefix ("https:") || rest.has_prefix ("//");
                if (remote && k != "href=") return true;
                if (remote && k == "href=") {
                    int tag_start = pos;
                    while (tag_start > 0 && low[tag_start] != '<') tag_start--;
                    if (tag_start >= 0 && low.substring (tag_start, int.min (5, low.length - tag_start)).has_prefix ("<link")) return true;
                }
                pos = v;
            }
        }
        return false;
    }

    public string inline_cids (string html, Gee.Map<string, Attachment> parts) {
        if (parts.size == 0 || !html.down ().contains ("cid:")) return html;
        var sb = new StringBuilder ();
        int pos = 0;
        string low = html.down ();
        while (true) {
            int at = low.index_of ("cid:", pos);
            if (at < 0) break;
            int end = at + 4;
            while (end < html.length && html[end] != '"' && html[end] != '\'' && html[end] != ')' && html[end] != ' ' && html[end] != '>') end++;
            string id = Uri.unescape_string (html.substring (at + 4, end - at - 4)) ?? html.substring (at + 4, end - at - 4);
            sb.append (html.substring (pos, at - pos));
            var a = parts[id];
            if (a != null && a.data.get_size () < 8 * 1024 * 1024) {
                sb.append ("data:%s;base64,%s".printf (a.content_type, Base64.encode (a.data.get_data ())));
            } else {
                sb.append ("about:blank");
            }
            pos = end;
        }
        sb.append (html.substring (pos));
        return sb.str;
    }

    public string policy (bool allow_remote) {
        string img = allow_remote ? "data: https: http:" : "data:";
        return "default-src 'none'; img-src %s; style-src 'unsafe-inline'%s; font-src data:; media-src 'none'; script-src 'none'; object-src 'none'; frame-src 'none'; form-action 'none'".printf (img, allow_remote ? " https: http:" : "");
    }

    public string document (string html, Gee.Map<string, Attachment> parts, bool allow_remote) {
        string body = inline_cids (html, parts);
        string meta = "<meta http-equiv=\"Content-Security-Policy\" content=\"%s\"><meta charset=\"utf-8\"><meta name=\"color-scheme\" content=\"light\"><style>html{background:#ffffff;color:#1d1d1f;}body{margin:18px;font-family:sans-serif;font-size:14px;line-height:1.45;word-wrap:break-word;overflow-wrap:anywhere;}img{max-width:100%%;height:auto;}blockquote{margin:0 0 0 8px;padding-left:10px;border-left:3px solid #c9c9cf;color:#55555c;}pre{white-space:pre-wrap;}</style>".printf (policy (allow_remote));
        return "<!DOCTYPE html><html><head>" + meta + "</head><body>" + body + "</body></html>";
    }

    public string from_text (string text) {
        var sb = new StringBuilder ();
        foreach (string line in text.split ("\n")) {
            sb.append (escape (line));
            sb.append ("<br>\n");
        }
        return sb.str;
    }

    public string linkify (string escaped) {
        var sb = new StringBuilder ();
        int i = 0;
        while (i < escaped.length) {
            int h = escaped.index_of ("http", i);
            if (h < 0) {
                sb.append (escaped.substring (i));
                break;
            }
            string rest = escaped.substring (h);
            if (!rest.has_prefix ("http://") && !rest.has_prefix ("https://")) {
                sb.append (escaped.substring (i, h - i + 4));
                i = h + 4;
                continue;
            }
            int e = h;
            while (e < escaped.length && escaped[e] != ' ' && escaped[e] != '\n' && escaped[e] != '<' && escaped[e] != '"' && escaped[e] != '\t' && !(escaped[e] == '&' && escaped.substring (e).has_prefix ("&gt;"))) e++;
            while (e > h && (escaped[e - 1] == '.' || escaped[e - 1] == ',' || escaped[e - 1] == ')' || escaped[e - 1] == ';')) e--;
            string url = escaped.substring (h, e - h);
            sb.append (escaped.substring (i, h - i));
            sb.append ("<a href=\"%s\">%s</a>".printf (url, url));
            i = e;
        }
        return sb.str;
    }

    public string plain_body (string text) {
        var sb = new StringBuilder ("<div class=\"lettere-plain\">");
        int depth = 0;
        foreach (string raw in text.replace ("\r\n", "\n").split ("\n")) {
            int q = 0;
            string line = raw;
            while (line.has_prefix (">")) {
                q++;
                line = line.substring (1);
                if (line.has_prefix (" ")) line = line.substring (1);
            }
            while (depth < q) {
                sb.append ("<blockquote>");
                depth++;
            }
            while (depth > q) {
                sb.append ("</blockquote>");
                depth--;
            }
            sb.append (linkify (escape (line)));
            sb.append ("<br>\n");
        }
        while (depth-- > 0) sb.append ("</blockquote>");
        sb.append ("</div>");
        return sb.str;
    }

    public const string DARK_STYLE = "<style>html{filter:invert(1) hue-rotate(180deg);background:#ffffff !important;}img,video,picture,svg,[style*=\"background-image\"]{filter:invert(1) hue-rotate(180deg);}</style>";

    public string message_document (MimeMessage msg, bool allow_remote, bool dark, string override_text = "") {
        string body;
        if (override_text != "") body = plain_body (override_text);
        else if (msg.text_html != "") body = msg.text_html;
        else body = plain_body (msg.text_plain);
        string doc = document (body, msg.inline_parts, allow_remote);
        string extra = "<style>.lettere-plain{white-space:normal;font-family:sans-serif;}body{margin:4px 2px;}</style>" + (dark ? DARK_STYLE : "");
        return doc.replace ("</head>", extra + "</head>");
    }

    public string outer_policy (bool allow_remote) {
        string img = allow_remote ? "data: https: http:" : "data:";
        return "default-src 'none'; img-src %s; style-src 'unsafe-inline'%s; font-src data:; frame-src 'self' about: data:; child-src 'self' about: data:; script-src 'none'; object-src 'none'; form-action 'none'".printf (img, allow_remote ? " https: http:" : "");
    }

    public string attr (string s) {
        return s.replace ("&", "&amp;").replace ("\"", "&quot;").replace ("<", "&lt;").replace (">", "&gt;");
    }
}
