using Gtk;
using Singularity.Widgets;

namespace Singularity.Apps.Lettere {

    public class HtmlEditor : Box {
        public signal void changed ();
        public signal void files_dropped (File[] files);
        public signal void mention_chosen (Address a);

        public WebKit.WebView web;
        private LettereApp app;
        private bool ready;
        private string? pending_html;
        private Popover mention_popover;
        private ListBox mention_list;
        private string mention_query = "";
        private bool mentioning;

        private const string BASE_STYLE = "body{font-family:sans-serif;font-size:15px;line-height:1.45;margin:14px 16px;min-height:300px;outline:none;word-wrap:break-word;}blockquote{margin:0 0 0 8px;padding-left:10px;border-left:3px solid #c9c9cf;color:#55555c;}table{border-collapse:collapse;}td,th{border:1px solid #b0b0b8;padding:4px 8px;min-width:40px;}img{max-width:100%;}.lettere-signature{color:#555;}a.mention{background:#e8f0fd;border-radius:4px;padding:0 2px;text-decoration:none;}";

        public HtmlEditor (LettereApp app) {
            Object (orientation: Orientation.VERTICAL, spacing: 0);
            this.app = app;
            var ws = new WebKit.Settings ();
            ws.enable_javascript = true;
            ws.enable_javascript_markup = false;
            ws.enable_developer_extras = false;
            ws.enable_html5_database = false;
            ws.enable_html5_local_storage = false;
            ws.enable_page_cache = false;
            ws.enable_webgl = false;
            ws.enable_media = false;
            ws.allow_modal_dialogs = false;
            ws.javascript_can_open_windows_automatically = false;
            ws.javascript_can_access_clipboard = true;
            ws.default_charset = "utf-8";
            var content = new WebKit.UserContentManager ();
            content.register_script_message_handler ("edited", null);
            content.script_message_received["edited"].connect (() => changed ());
            content.add_script (new WebKit.UserScript ("document.addEventListener ('input', function () { window.webkit.messageHandlers.edited.postMessage (''); }, true);", WebKit.UserContentInjectedFrames.TOP_FRAME, WebKit.UserScriptInjectionTime.END, null, null));
            web = (WebKit.WebView) Object.new (typeof (WebKit.WebView), "network-session", new WebKit.NetworkSession.ephemeral (), "settings", ws, "user-content-manager", content);
            web.editable = true;
            web.vexpand = true;
            web.hexpand = true;
            web.update_property (AccessibleProperty.LABEL, _("Message"), -1);
            var ctx = web.get_context ();
            ctx.set_spell_checking_enabled (app.settings.get_boolean ("spell-check"));
            var langs = new string[0];
            foreach (string l in Intl.get_language_names ()) {
                if (l.contains (".") || l.contains ("@") || l == "C" || l == "POSIX") continue;
                langs += l;
                if (langs.length >= 2) break;
            }
            if (langs.length == 0) langs += "en_US";
            ctx.set_spell_checking_languages (langs);
            web.load_changed.connect ((ev) => {
                if (ev != WebKit.LoadEvent.FINISHED) return;
                ready = true;
                if (pending_html != null) {
                    string h = pending_html;
                    pending_html = null;
                    set_html (h);
                }
            });
            web.decide_policy.connect ((decision, type) => {
                var nav = decision as WebKit.NavigationPolicyDecision;
                if (nav == null) return false;
                string uri = nav.navigation_action.get_request ().uri;
                if (uri == "about:blank") {
                    decision.use ();
                    return true;
                }
                decision.ignore ();
                return true;
            });
            web.context_menu.connect ((menu, hit) => {
                var keep = new Gee.ArrayList<WebKit.ContextMenuItem> ();
                foreach (var item in menu.get_items ()) {
                    var a = item.get_stock_action ();
                    if (a == WebKit.ContextMenuAction.SPELLING_GUESS || a == WebKit.ContextMenuAction.IGNORE_SPELLING || a == WebKit.ContextMenuAction.LEARN_SPELLING
                        || a == WebKit.ContextMenuAction.CUT || a == WebKit.ContextMenuAction.COPY || a == WebKit.ContextMenuAction.PASTE
                        || a == WebKit.ContextMenuAction.NO_GUESSES_FOUND) keep.add (item);
                }
                menu.remove_all ();
                foreach (var item in keep) menu.append (item);
                return false;
            });
            var keys = new EventControllerKey ();
            keys.propagation_phase = PropagationPhase.CAPTURE;
            keys.key_pressed.connect (on_key);
            web.add_controller (keys);
            var drop = new DropTarget (typeof (Gdk.FileList), Gdk.DragAction.COPY);
            drop.drop.connect ((v, x, y) => {
                var list = (Gdk.FileList) v.get_boxed ();
                var files = new File[0];
                foreach (var f in list.get_files ()) files += f;
                files_dropped (files);
                return true;
            });
            web.add_controller (drop);
            append (web);
            mention_list = new ListBox ();
            mention_list.selection_mode = SelectionMode.BROWSE;
            mention_list.add_css_class ("navigation-sidebar");
            mention_list.row_activated.connect ((row) => accept_mention (row));
            mention_popover = new Popover ();
            mention_popover.has_arrow = false;
            mention_popover.autohide = false;
            mention_popover.can_focus = false;
            mention_popover.child = mention_list;
            mention_popover.set_parent (web);
            ulong on_map = 0;
            on_map = web.map.connect (() => {
                web.disconnect (on_map);
                load_empty ();
            });
        }

        public override void dispose () {
            if (mention_popover != null) mention_popover.unparent ();
            mention_popover = null;
            base.dispose ();
        }

        private void load_empty () {
            ready = false;
            web.load_html ("<!DOCTYPE html><html><head><meta charset=\"utf-8\"><style>%s</style></head><body></body></html>".printf (BASE_STYLE), "about:blank");
        }

        private void js (string code) {
            web.evaluate_javascript.begin (code, -1, null, null, null, (o, r) => {
                try {
                    web.evaluate_javascript.end (r);
                } catch (Error e) {
                }
            });
        }

        public static string js_string (string s) {
            var sb = new StringBuilder ("\"");
            unichar c;
            int i = 0;
            while (s.get_next_char (ref i, out c)) {
                switch (c) {
                    case '\\': sb.append ("\\\\"); break;
                    case '"': sb.append ("\\\""); break;
                    case '\n': sb.append ("\\n"); break;
                    case '\r': sb.append ("\\r"); break;
                    case '\t': sb.append ("\\t"); break;
                    case '<': sb.append ("\\u003c"); break;
                    case 0x2028: sb.append ("\\u2028"); break;
                    case 0x2029: sb.append ("\\u2029"); break;
                    default: sb.append_unichar (c); break;
                }
            }
            sb.append ("\"");
            return sb.str;
        }

        public void set_html (string html) {
            if (!ready) {
                pending_html = html;
                return;
            }
            js ("document.body.innerHTML = %s; var r = document.createRange (); r.setStart (document.body, 0); r.collapse (true); var s = window.getSelection (); s.removeAllRanges (); s.addRange (r);".printf (js_string (html)));
        }

        public async string get_html () {
            try {
                var v = yield web.evaluate_javascript ("document.body.innerHTML", -1, null, null, null);
                return v.to_string ();
            } catch (Error e) {
                return "";
            }
        }

        public async string get_text () {
            try {
                var v = yield web.evaluate_javascript ("document.body.innerText", -1, null, null, null);
                return v.to_string ();
            } catch (Error e) {
                return "";
            }
        }

        public async void get_body (out string html, out string text) throws Error {
            html = "";
            text = "";
            if (!ready || pending_html != null) throw new IOError.PENDING (_("The message editor is still loading"));
            var v = yield web.evaluate_javascript ("[document.body.innerHTML, document.body.innerText]", -1, null, null, null);
            html = v.object_get_property_at_index (0).to_string ();
            text = v.object_get_property_at_index (1).to_string ();
        }

        public async string selection_html () {
            try {
                var v = yield web.evaluate_javascript ("(function () { var s = window.getSelection (); if (!s.rangeCount) return ''; var d = document.createElement ('div'); d.appendChild (s.getRangeAt (0).cloneContents ()); return d.innerHTML; }) ()", -1, null, null, null);
                return v.to_string ();
            } catch (Error e) {
                return "";
            }
        }

        public void command (string name, string? arg = null) {
            if (arg != null) web.execute_editing_command_with_argument (name, arg);
            else web.execute_editing_command (name);
            changed ();
        }

        public void insert_html (string html) {
            web.grab_focus ();
            web.execute_editing_command_with_argument ("InsertHTML", html);
            changed ();
        }

        public void insert_text (string text) {
            web.grab_focus ();
            web.execute_editing_command_with_argument ("InsertText", text);
            changed ();
        }

        public void set_signature (string html) {
            js ("(function () { var s = document.querySelector ('.lettere-signature'); var h = %s; if (s) { if (h == '') s.remove (); else s.innerHTML = h; } else if (h != '') { var d = document.createElement ('div'); d.className = 'lettere-signature'; d.innerHTML = h; var q = document.querySelector ('.lettere-quote'); if (q) document.body.insertBefore (d, q); else document.body.appendChild (d); } }) ()".printf (js_string (html)));
            changed ();
        }

        public void focus_start () {
            web.grab_focus ();
            js ("var r = document.createRange (); r.setStart (document.body, 0); r.collapse (true); var s = window.getSelection (); s.removeAllRanges (); s.addRange (r);");
        }

        public async void insert_image (File f) {
            try {
                var info = yield f.query_info_async ("standard::content-type,standard::display-name", FileQueryInfoFlags.NONE);
                uint8[] data;
                string etag;
                yield f.load_contents_async (null, out data, out etag);
                string ct = ContentType.get_mime_type (info.get_content_type () ?? "image/png") ?? "image/png";
                insert_image_data (data, ct, info.get_display_name ());
            } catch (Error e) {
                app.toast (_("Could not insert the image: %s").printf (e.message), null, null);
            }
        }

        public void insert_image_data (uint8[] data, string content_type, string name) {
            insert_html ("<img src=\"data:%s;base64,%s\" alt=\"%s\" data-name=\"%s\">".printf (content_type, Base64.encode (data), Html.attr (name), Html.attr (name)));
        }

        public void insert_table (int rows, int cols) {
            var sb = new StringBuilder ("<table><tbody>");
            for (int r = 0; r < rows; r++) {
                sb.append ("<tr>");
                for (int c = 0; c < cols; c++) sb.append (r == 0 ? "<th><br></th>" : "<td><br></td>");
                sb.append ("</tr>");
            }
            sb.append ("</tbody></table><p><br></p>");
            insert_html (sb.str);
        }

        private bool on_key (uint keyval, uint code, Gdk.ModifierType state) {
            bool ctrl = (state & Gdk.ModifierType.CONTROL_MASK) != 0;
            if (mention_popover.visible) {
                var sel = mention_list.get_selected_row ();
                switch (keyval) {
                    case Gdk.Key.Down:
                        var next = sel == null ? mention_list.get_row_at_index (0) : mention_list.get_row_at_index (sel.get_index () + 1);
                        if (next != null) mention_list.select_row (next);
                        return true;
                    case Gdk.Key.Up:
                        if (sel != null && sel.get_index () > 0) mention_list.select_row (mention_list.get_row_at_index (sel.get_index () - 1));
                        return true;
                    case Gdk.Key.Return:
                    case Gdk.Key.KP_Enter:
                    case Gdk.Key.Tab:
                        if (sel != null) {
                            accept_mention (sel);
                            return true;
                        }
                        break;
                    case Gdk.Key.Escape:
                        end_mention ();
                        return true;
                }
            }
            if (ctrl && keyval == Gdk.Key.v) {
                paste.begin ();
                return true;
            }
            if (ctrl) {
                switch (keyval) {
                    case Gdk.Key.b: command ("Bold"); return true;
                    case Gdk.Key.i: command ("Italic"); return true;
                    case Gdk.Key.u: command ("Underline"); return true;
                }
            }
            unichar ch = Gdk.keyval_to_unicode (keyval);
            if (ch == '@' && !ctrl) {
                mentioning = true;
                mention_query = "";
                changed ();
                return false;
            }
            if (mentioning) {
                if (keyval == Gdk.Key.BackSpace) {
                    if (mention_query.length == 0) end_mention ();
                    else mention_query = mention_query.substring (0, mention_query.length - 1);
                    refresh_mentions.begin ();
                } else if (ch != 0 && (ch.isalnum () || ch == '.' || ch == '-' || ch == '_')) {
                    mention_query += ch.to_string ();
                    refresh_mentions.begin ();
                } else if (ch != 0 || keyval == Gdk.Key.Escape) {
                    end_mention ();
                }
            }
            if (ch != 0 || keyval == Gdk.Key.BackSpace || keyval == Gdk.Key.Delete || keyval == Gdk.Key.Return) changed ();
            return false;
        }

        private void end_mention () {
            mentioning = false;
            mention_query = "";
            mention_popover.popdown ();
        }

        private async void refresh_mentions () {
            Widget? c;
            while ((c = mention_list.get_first_child ()) != null) mention_list.remove (c);
            if (mention_query.length < 1) {
                mention_popover.popdown ();
                return;
            }
            var seen = new Gee.HashSet<string> ();
            var found = new Gee.ArrayList<Address> ();
            foreach (var a in app.contacts.match (mention_query, 6)) if (seen.add (a.email.down ())) found.add (a);
            foreach (var a in app.store.suggest (mention_query, 6)) if (found.size < 6 && seen.add (a.email.down ())) found.add (a);
            if (found.size == 0) {
                mention_popover.popdown ();
                return;
            }
            foreach (var a in found) {
                var row = new ListBoxRow ();
                row.set_data<Address> ("address", a);
                var l = new Label (a.name != "" ? "%s  %s".printf (a.name, a.email) : a.email);
                l.xalign = 0;
                l.margin_start = 6;
                l.margin_end = 6;
                l.margin_top = 3;
                l.margin_bottom = 3;
                row.child = l;
                mention_list.append (row);
            }
            mention_list.select_row (mention_list.get_row_at_index (0));
            try {
                var v = yield web.evaluate_javascript ("(function () { var s = window.getSelection (); if (!s.rangeCount) return '0,0'; var r = s.getRangeAt (0).getBoundingClientRect (); return Math.round (r.left) + ',' + Math.round (r.bottom); }) ()", -1, null, null, null);
                string[] p = v.to_string ().split (",");
                if (p.length == 2) mention_popover.set_pointing_to ({ int.parse (p[0]), int.parse (p[1]), 1, 1 });
            } catch (Error e) {
            }
            mention_popover.popup ();
        }

        private void accept_mention (ListBoxRow row) {
            var a = row.get_data<Address> ("address");
            int n = mention_query.length + 1;
            string name = a.name != "" ? a.name : a.email;
            js ("(function () { var s = window.getSelection (); for (var i = 0; i < %d; i++) s.modify ('extend', 'backward', 'character'); }) ()".printf (n));
            web.execute_editing_command_with_argument ("InsertHTML", "<a class=\"mention\" href=\"mailto:%s\">@%s</a>&nbsp;".printf (Html.attr (a.email), Html.escape (name)));
            end_mention ();
            mention_chosen (a);
            changed ();
        }

        private async void paste () {
            var cb = get_clipboard ();
            var formats = cb.get_formats ();
            if (formats.contain_gtype (typeof (Gdk.Texture)) && !formats.contain_mime_type ("text/html")) {
                try {
                    var tex = yield cb.read_texture_async (null);
                    if (tex != null) {
                        var bytes = tex.save_to_png_bytes ();
                        insert_image_data (bytes.get_data (), "image/png", _("Pasted Image.png"));
                        return;
                    }
                } catch (Error e) {
                }
            }
            if (formats.contain_gtype (typeof (Gdk.FileList))) {
                try {
                    var v = yield cb.read_value_async (typeof (Gdk.FileList), Priority.DEFAULT, null);
                    var list = (Gdk.FileList) v.get_boxed ();
                    var files = new File[0];
                    foreach (var f in list.get_files ()) files += f;
                    if (files.length > 0) {
                        files_dropped (files);
                        return;
                    }
                } catch (Error e) {
                }
            }
            web.execute_editing_command (WebKit.EDITING_COMMAND_PASTE);
            changed ();
        }

        public static void extract_images (string html, out string out_html, Gee.List<OutgoingAttachment> images, string domain) {
            var sb = new StringBuilder ();
            int pos = 0;
            int n = 0;
            while (true) {
                int at = html.index_of ("src=\"data:", pos);
                if (at < 0) break;
                int start = at + 5;
                int end = html.index_of_char ('"', start);
                if (end < 0) break;
                string uri = html.substring (start, end - start);
                int semi = uri.index_of (";base64,");
                if (semi < 0) {
                    sb.append (html.substring (pos, end - pos));
                    pos = end;
                    continue;
                }
                string ct = uri.substring (5, semi - 5);
                var data = Base64.decode (uri.substring (semi + 8));
                n++;
                string cid = "img%d.%s@%s".printf (n, Uuid.string_random ().substring (0, 8), domain);
                string ext = ct.contains ("/") ? ct.substring (ct.index_of_char ('/') + 1) : "png";
                var att = new OutgoingAttachment ("image%d.%s".printf (n, ext), ct, new Bytes (data));
                att.content_id = cid;
                images.add (att);
                sb.append (html.substring (pos, start - pos));
                sb.append ("cid:" + cid);
                pos = end;
            }
            sb.append (html.substring (pos));
            out_html = sb.str;
        }

        public static string inline_images_back (string html, Gee.Map<string, Attachment> parts) {
            return Html.inline_cids (html, parts);
        }

        public static string wrap_document (string body) {
            return "<!DOCTYPE html><html><head><meta charset=\"utf-8\"><style>%s</style></head><body>%s</body></html>".printf (BASE_STYLE.replace ("min-height:300px;", ""), body);
        }
    }
}
