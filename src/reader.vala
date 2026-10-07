using Gtk;
using Singularity.Widgets;

namespace Singularity.Apps.Lettere {

    public class LoadedMessage {
        public MessageInfo info;
        public MimeMessage? mime;
        public CryptoResult? crypto;
        public string error = "";
        public string translation = "";
        public bool images;

        public LoadedMessage (MessageInfo info) {
            this.info = info;
        }
    }

    public class ReaderView : Box {
        public signal void message_shown (MessageInfo m);
        public signal void open_uri (string uri);
        public signal void toast (string text);
        public signal void action_requested (string action, MessageInfo m);

        public MessageInfo? current { get; private set; }
        public MimeMessage? mime { get; private set; }
        public bool images_loaded { get; private set; }
        public bool images_allowed { get; private set; }
        public CryptoResult? crypto { get; private set; }

        private LettereApp app;
        private Label subject;
        private FlowBox chips;
        private Box notice;
        private Box receipt_notice;
        private Box security;
        private Image security_icon;
        private Label security_label;
        private Box unsubscribe_box;
        private Box invite_slot;
        private WebKit.WebView web;
        private WebKit.UserContentManager content;
        private Box paper;
        private Stack body_stack;
        private StatusPage failure;
        private Button failure_retry;
        private Box attachments;
        private ScrolledWindow attachments_scroll;
        private Gee.List<LoadedMessage> loaded = new Gee.ArrayList<LoadedMessage> ();
        private Gee.ArrayList<Attachment> shown_attachments = new Gee.ArrayList<Attachment> ();
        private AccountSync? sync;
        private uint serial;
        private bool file_mode;
        private MimeMessage? file_message;
        private string file_title = "";

        public double zoom {
            get { return web.zoom_level; }
            set { web.zoom_level = value.clamp (0.5, 3.0); }
        }

        public ReaderView (LettereApp app) {
            Object (orientation: Orientation.VERTICAL, spacing: 0);
            this.app = app;
            vexpand = true;
            hexpand = true;

            subject = new Label ("");
            subject.xalign = 0;
            subject.wrap = true;
            subject.wrap_mode = Pango.WrapMode.WORD_CHAR;
            subject.selectable = true;
            subject.add_css_class ("lettere-subject");
            subject.margin_start = 20;
            subject.margin_end = 20;
            subject.margin_bottom = 6;
            append (subject);

            chips = new FlowBox ();
            chips.selection_mode = SelectionMode.NONE;
            chips.margin_start = 20;
            chips.margin_end = 20;
            chips.margin_bottom = 6;
            chips.column_spacing = 6;
            chips.row_spacing = 4;
            chips.max_children_per_line = 12;
            chips.visible = false;
            append (chips);

            security = new Box (Orientation.HORIZONTAL, 8);
            security.add_css_class ("lettere-notice");
            security_icon = new Image.from_icon_name ("security-high-symbolic");
            security.append (security_icon);
            security_label = new Label ("");
            security_label.xalign = 0;
            security_label.hexpand = true;
            security_label.wrap = true;
            security.append (security_label);
            security.visible = false;
            append (security);

            unsubscribe_box = new Box (Orientation.HORIZONTAL, 8);
            unsubscribe_box.add_css_class ("lettere-notice");
            var unsub_label = new Label (_("This message comes from a mailing list."));
            unsub_label.xalign = 0;
            unsub_label.hexpand = true;
            unsub_label.wrap = true;
            unsubscribe_box.append (new Image.from_icon_name ("mail-send-receive-symbolic"));
            unsubscribe_box.append (unsub_label);
            var unsub = new Button.with_label (_("Unsubscribe"));
            unsub.add_css_class ("pill");
            unsub.clicked.connect (() => {
                if (current != null) action_requested ("unsubscribe", current);
            });
            unsubscribe_box.append (unsub);
            unsubscribe_box.visible = false;
            append (unsubscribe_box);

            receipt_notice = new Box (Orientation.HORIZONTAL, 8);
            receipt_notice.add_css_class ("lettere-notice");
            receipt_notice.append (new Image.from_icon_name ("mail-read-symbolic"));
            var receipt_label = new Label (_("The sender asked to be told when you read this message."));
            receipt_label.xalign = 0;
            receipt_label.hexpand = true;
            receipt_label.wrap = true;
            receipt_notice.append (receipt_label);
            var ignore = new Button.with_label (_("Ignore"));
            ignore.add_css_class ("flat");
            ignore.clicked.connect (() => {
                if (current != null) action_requested ("receipt-ignore", current);
                receipt_notice.visible = false;
            });
            receipt_notice.append (ignore);
            var send_receipt = new Button.with_label (_("Send Receipt"));
            send_receipt.add_css_class ("pill");
            send_receipt.clicked.connect (() => {
                if (current != null) action_requested ("receipt-send", current);
                receipt_notice.visible = false;
            });
            receipt_notice.append (send_receipt);
            receipt_notice.visible = false;
            append (receipt_notice);

            invite_slot = new Box (Orientation.VERTICAL, 0);
            append (invite_slot);

            notice = new Box (Orientation.HORIZONTAL, 8);
            notice.add_css_class ("lettere-notice");
            notice.append (new Image.from_icon_name ("image-x-generic-symbolic"));
            var notice_label = new Label (_("Images from the web are blocked to protect your privacy."));
            notice_label.xalign = 0;
            notice_label.hexpand = true;
            notice_label.wrap = true;
            notice.append (notice_label);
            var always = new Button.with_label (_("Always for This Sender"));
            always.add_css_class ("flat");
            always.clicked.connect (() => trust_sender ());
            notice.append (always);
            var load = new Button.with_label (_("Load Images"));
            load.add_css_class ("pill");
            load.clicked.connect (() => load_images ());
            notice.append (load);
            notice.visible = false;
            append (notice);

            content = new WebKit.UserContentManager ();
            content.register_script_message_handler ("lettere", "lettere");
            content.script_message_received["lettere"].connect ((value) => on_script (value.to_string ()));
            var ws = new WebKit.Settings ();
            ws.enable_javascript = true;
            ws.enable_javascript_markup = true;
            ws.enable_developer_extras = false;
            ws.enable_html5_database = false;
            ws.enable_html5_local_storage = false;
            ws.enable_page_cache = false;
            ws.enable_webgl = false;
            ws.enable_webaudio = false;
            ws.enable_media = false;
            ws.enable_mediasource = false;
            ws.auto_load_images = true;
            ws.allow_modal_dialogs = false;
            ws.javascript_can_open_windows_automatically = false;
            ws.enable_back_forward_navigation_gestures = false;
            ws.enable_smooth_scrolling = true;
            ws.default_charset = "utf-8";
            web = (WebKit.WebView) Object.new (typeof (WebKit.WebView), "network-session", new WebKit.NetworkSession.ephemeral (), "settings", ws, "user-content-manager", content);
            web.vexpand = true;
            web.hexpand = true;
            web.decide_policy.connect (on_policy);
            web.load_changed.connect ((ev) => {
                if (ev == WebKit.LoadEvent.FINISHED) fit ();
            });
            web.context_menu.connect ((menu, hit) => {
                menu.remove_all ();
                if (hit.context_is_link ()) {
                    string uri = hit.get_link_uri ();
                    var open = new WebKit.ContextMenuItem.from_gaction (new SimpleAction ("x-open", null), _("Open Link"), null);
                    ((SimpleAction) open.get_gaction ()).activate.connect (() => open_uri (uri));
                    menu.append (open);
                    var copy = new WebKit.ContextMenuItem.from_gaction (new SimpleAction ("x-copy", null), _("Copy Link"), null);
                    ((SimpleAction) copy.get_gaction ()).activate.connect (() => get_clipboard ().set_text (uri));
                    menu.append (copy);
                }
                if (hit.context_is_selection ()) menu.append (new WebKit.ContextMenuItem.from_stock_action (WebKit.ContextMenuAction.COPY));
                menu.append (new WebKit.ContextMenuItem.from_stock_action (WebKit.ContextMenuAction.SELECT_ALL));
                return false;
            });
            app.style_changed.connect (() => {
                if (loaded.size > 0 || file_mode) render_all ();
                sync_paper ();
            });
            paper = new Box (Orientation.VERTICAL, 0);
            paper.add_css_class ("lettere-paper");
            paper.overflow = Overflow.HIDDEN;
            paper.append (web);
            sync_paper ();

            var loading = new StatusPage ();
            loading.icon_name = "dev.sinty.lettere";
            loading.title = _("Loading Message");
            var spinner = new Spinner ();
            spinner.spinning = true;
            spinner.set_size_request (24, 24);
            loading.child = spinner;

            failure = new StatusPage ();
            failure.icon_name = "network-error";
            failure.title = _("Message Not Available");
            failure_retry = new Button.with_label (_("Try Again"));
            failure_retry.add_css_class ("pill");
            failure_retry.halign = Align.CENTER;
            failure_retry.clicked.connect (() => {
                if (loaded.size > 0) show_conversation (infos (), current ?? loaded[0].info, sync);
            });
            failure.child = failure_retry;

            body_stack = new Stack ();
            body_stack.vexpand = true;
            body_stack.vhomogeneous = false;
            body_stack.hhomogeneous = false;
            body_stack.add_named (paper, "html");
            body_stack.add_named (loading, "loading");
            body_stack.add_named (failure, "failure");
            attachments = new Box (Orientation.HORIZONTAL, 8);
            attachments.update_property (AccessibleProperty.LABEL, _("Attachments"), -1);
            attachments_scroll = new ScrolledWindow ();
            attachments_scroll.add_css_class ("lettere-attachments");
            attachments_scroll.vscrollbar_policy = PolicyType.NEVER;
            attachments_scroll.hscrollbar_policy = PolicyType.AUTOMATIC;
            attachments_scroll.propagate_natural_height = true;
            attachments_scroll.child = attachments;
            attachments_scroll.visible = false;
            append (attachments_scroll);
            append (body_stack);

            var group = new SimpleActionGroup ();
            var open_action = new SimpleAction ("open-attachment", VariantType.INT32);
            open_action.activate.connect ((v) => {
                var a = attachment_at (v.get_int32 ());
                if (a != null) open_attachment (a);
            });
            group.add_action (open_action);
            var save_action = new SimpleAction ("save-attachment", VariantType.INT32);
            save_action.activate.connect ((v) => {
                var a = attachment_at (v.get_int32 ());
                if (a != null) save_attachment (a);
            });
            group.add_action (save_action);
            var share_action = new SimpleAction ("share-attachment", VariantType.INT32);
            share_action.activate.connect ((v) => {
                var a = attachment_at (v.get_int32 ());
                if (a != null) share_attachment (a);
            });
            group.add_action (share_action);
            var preview_action = new SimpleAction ("preview-attachment", VariantType.INT32);
            preview_action.activate.connect ((v) => {
                var a = attachment_at (v.get_int32 ());
                if (a != null) preview_attachment (a);
            });
            group.add_action (preview_action);
            insert_action_group ("reader", group);
        }

        private void sync_paper () {
            if (app.dark_reading ()) {
                paper.add_css_class ("dark");
                web.set_background_color ({ 0.12f, 0.12f, 0.13f, 1 });
            } else {
                paper.remove_css_class ("dark");
                web.set_background_color ({ 1, 1, 1, 1 });
            }
        }

        private Gee.ArrayList<MessageInfo> infos () {
            var list = new Gee.ArrayList<MessageInfo> ();
            foreach (var l in loaded) list.add (l.info);
            return list;
        }

        private bool on_policy (WebKit.PolicyDecision decision, WebKit.PolicyDecisionType type) {
            if (type == WebKit.PolicyDecisionType.RESPONSE) return false;
            var nav = decision as WebKit.NavigationPolicyDecision;
            if (nav == null) return false;
            var action = nav.navigation_action;
            string uri = action.get_request ().uri;
            if (uri == "about:blank" || uri == "about:srcdoc") {
                decision.use ();
                return true;
            }
            if (uri.has_prefix ("lettere:")) {
                handle_action (uri.substring (8));
                decision.ignore ();
                return true;
            }
            if (action.is_user_gesture () && (uri.has_prefix ("http:") || uri.has_prefix ("https:") || uri.has_prefix ("mailto:"))) open_uri (uri);
            decision.ignore ();
            return true;
        }

        private LoadedMessage? find (int64 id) {
            foreach (var l in loaded) if (l.info.id == id) return l;
            return null;
        }

        private void handle_action (string spec) {
            int slash = spec.index_of_char ('/');
            if (slash < 0) return;
            string verb = spec.substring (0, slash);
            string rest = spec.substring (slash + 1);
            string[] parts = rest.split ("/");
            var l = find (int64.parse (parts[0]));
            if (l == null) return;
            if (verb == "attach" && parts.length > 1 && l.mime != null) {
                int idx = int.parse (parts[1]);
                if (idx >= 0 && idx < l.mime.attachments.size) open_attachment (l.mime.attachments[idx]);
                return;
            }
            if (verb == "original") {
                l.translation = "";
                render_all ();
                return;
            }
            focus_message (l, false);
            action_requested (verb, l.info);
        }

        private void on_script (string msg) {
            if (msg.has_prefix ("focus:") || msg.has_prefix ("open:")) {
                var l = find (int64.parse (msg.substring (msg.index_of_char (':') + 1)));
                if (l != null && (current == null || current.id != l.info.id)) focus_message (l, false);
            }
        }

        private const string FIT_SCRIPT = """
(function () {
  function fit (f) {
    try {
      var d = f.contentDocument;
      if (!d || !d.documentElement) return;
      var h = Math.max (d.documentElement.scrollHeight, d.body ? d.body.scrollHeight : 0);
      f.style.height = (h + 6) + 'px';
    } catch (e) {}
  }
  document.querySelectorAll ('iframe').forEach (function (f) {
    fit (f);
    if (!f.dataset.hooked) {
      f.dataset.hooked = '1';
      f.addEventListener ('load', function () { fit (f); setTimeout (function () { fit (f); }, 300); });
    }
  });
  document.querySelectorAll ('details').forEach (function (d) {
    if (d.dataset.hooked) return;
    d.dataset.hooked = '1';
    d.addEventListener ('toggle', function () {
      d.querySelectorAll ('iframe').forEach (fit);
      if (d.open) window.webkit.messageHandlers.lettere.postMessage ('open:' + d.parentNode.dataset.id);
    });
  });
  document.querySelectorAll ('section.msg').forEach (function (s) {
    if (s.dataset.hooked) return;
    s.dataset.hooked = '1';
    s.addEventListener ('mousedown', function () { window.webkit.messageHandlers.lettere.postMessage ('focus:' + s.dataset.id); });
  });
  var cur = document.querySelector ('section.current');
  if (cur && !window.lettereScrolled) { window.lettereScrolled = true; cur.scrollIntoView (); }
  return 1;
}) ();
""";

        private void probe () {
            if (Environment.get_variable ("LETTERE_TEST_SCRIPT") == null) return;
            web.evaluate_javascript.begin ("document.body ? document.body.innerText.length + ' ' + document.querySelectorAll ('iframe').length : 'nobody'", -1, null, null, null, (o, r) => {
                try {
                    var v = web.evaluate_javascript.end (r);
                    printerr ("reader: text %s size %dx%d\n", v.to_string (), web.get_width (), web.get_height ());
                } catch (Error e) {
                    printerr ("reader: probe %s\n", e.message);
                }
            });
        }

        private void fit () {
            probe ();
            web.evaluate_javascript.begin (FIT_SCRIPT, -1, "lettere", null, null, (o, r) => {
                try {
                    web.evaluate_javascript.end (r);
                } catch (Error e) {
                }
            });
            Timeout.add (400, () => {
                web.evaluate_javascript.begin (FIT_SCRIPT, -1, "lettere", null, null, null);
                return Source.REMOVE;
            });
        }

        public void clear () {
            serial++;
            current = null;
            mime = null;
            crypto = null;
            loaded = new Gee.ArrayList<LoadedMessage> ();
            file_mode = false;
            invite_slot_clear ();
        }

        private void invite_slot_clear () {
            Widget? c;
            while ((c = invite_slot.get_first_child ()) != null) invite_slot.remove (c);
        }

        public void show_conversation (Gee.List<MessageInfo> messages, MessageInfo focus, AccountSync? sync) {
            this.sync = sync;
            file_mode = false;
            uint my = ++serial;
            loaded = new Gee.ArrayList<LoadedMessage> ();
            LoadedMessage? target = null;
            foreach (var m in messages) {
                var l = new LoadedMessage (m);
                loaded.add (l);
                if (m.id == focus.id) target = l;
            }
            if (target == null) {
                target = new LoadedMessage (focus);
                loaded.add (target);
            }
            current = focus;
            mime = null;
            crypto = null;
            images_loaded = false;
            subject.label = focus.subject != "" ? focus.subject : _("(No Subject)");
            clear_attachments ();
            invite_slot_clear ();
            notice.visible = false;
            security.visible = false;
            receipt_notice.visible = false;
            unsubscribe_box.visible = false;
            update_chips ();
            body_stack.visible_child_name = "loading";
            load_all.begin (my, target);
        }

        private async void load_one (LoadedMessage l) {
            var cached = app.store.body (l.info.id);
            uint8[]? raw = cached;
            if (raw == null) {
                var s = app.syncs[l.info.account];
                if (s == null) {
                    l.error = _("This message was not saved on this computer.");
                    return;
                }
                try {
                    raw = yield s.load_body (l.info);
                } catch (Error e) {
                    l.error = _("It could not be downloaded because you are offline or the server did not answer. %s").printf (e.message);
                    return;
                }
                if (raw == null) {
                    l.error = _("The server no longer has this message.");
                    return;
                }
            }
            var result = yield Crypto.open (raw, app);
            l.crypto = result;
            l.mime = result.message;
        }

        private async void load_all (uint my, LoadedMessage target) {
            yield load_one (target);
            if (my != serial) return;
            if (target.mime == null) {
                show_failure (target.error);
                return;
            }
            foreach (var l in loaded) {
                if (l == target) continue;
                yield load_one (l);
                if (my != serial) return;
            }
            focus_message (target, true);
            render_all ();
        }

        public void show_file (MimeMessage msg, string title) {
            clear ();
            this.sync = null;
            file_mode = true;
            file_message = msg;
            file_title = title;
            subject.label = msg.subject != "" ? msg.subject : title;
            var info = new MessageInfo ();
            info.id = -1;
            var from = msg.from;
            info.sender_name = from.size > 0 ? from[0].name : "";
            info.sender_email = from.size > 0 ? from[0].email : "";
            info.to_list = Mime.format_addresses (msg.to);
            info.cc_list = Mime.format_addresses (msg.cc);
            info.subject = msg.subject;
            var d = msg.date;
            info.date = d != null ? d.to_unix () : 0;
            var l = new LoadedMessage (info);
            l.mime = msg;
            loaded.add (l);
            current = null;
            mime = msg;
            clear_attachments ();
            foreach (var a in msg.attachments) add_attachment (a);
            finish_attachments ();
            chips.visible = false;
            security.visible = false;
            receipt_notice.visible = false;
            unsubscribe_box.visible = false;
            render_all ();
            show_invite (msg, null);
        }

        private void show_failure (string text) {
            failure.description = text;
            failure_retry.visible = sync != null && current != null;
            body_stack.visible_child_name = "failure";
        }

        private bool sender_trusted (string email) {
            if (email == "") return false;
            foreach (string s in app.settings.get_strv ("image-senders")) {
                if (s.down () == email.down ()) return true;
            }
            return false;
        }

        private bool allow_images (LoadedMessage l) {
            return app.settings.get_boolean ("load-remote-images") || sender_trusted (l.info.sender_email) || images_loaded || l.images;
        }

        private void update_chips () {
            Widget? c;
            while ((c = chips.get_first_child ()) != null) chips.remove (c);
            if (current == null) {
                chips.visible = false;
                return;
            }
            int n = 0;
            if (current.importance > 0) {
                chips.append (chip (_("High Importance"), "#e01b24"));
                n++;
            } else if (current.importance < 0) {
                chips.append (chip (_("Low Importance"), "#77767b"));
                n++;
            }
            foreach (string cat in current.categories ()) {
                chips.append (chip (cat, app.categories.color_of (cat)));
                n++;
            }
            if (current.flagged) {
                string label = current.completed ? _("Completed") : (current.due > 0 ? _("Follow Up by %s").printf (format_when (current.due)) : _("Flagged for Follow Up"));
                chips.append (chip (label, current.completed ? "#2ec27e" : "#e66100"));
                n++;
            }
            chips.visible = n > 0;
        }

        private Widget chip (string text, string color) {
            var box = new Box (Orientation.HORIZONTAL, 6);
            box.add_css_class ("lettere-chip");
            var dot = new Box (Orientation.HORIZONTAL, 0);
            dot.add_css_class ("lettere-chip-dot");
            dot.set_size_request (10, 10);
            dot.valign = Align.CENTER;
            var provider = new CssProvider ();
            provider.load_from_string ("box { background-color: %s; }".printf (color));
            dot.get_style_context ().add_provider (provider, STYLE_PROVIDER_PRIORITY_APPLICATION);
            box.append (dot);
            var l = new Label (text);
            l.add_css_class ("caption");
            box.append (l);
            return box;
        }

        private void focus_message (LoadedMessage l, bool initial) {
            current = l.info;
            mime = l.mime;
            crypto = l.crypto;
            images_allowed = allow_images (l);
            update_chips ();
            clear_attachments ();
            if (l.mime != null) {
                foreach (var a in l.mime.attachments) add_attachment (a);
                finish_attachments ();
            }
            update_security (l);
            unsubscribe_box.visible = l.info.list_unsubscribe != "";
            bool ask = l.info.receipt_to != "" && (l.info.flags & MessageFlags.MDN_SENT) == 0 && app.settings.get_string ("read-receipts") == "ask" && !is_from_me (l.info);
            receipt_notice.visible = ask;
            if (l.info.receipt_to != "" && (l.info.flags & MessageFlags.MDN_SENT) == 0 && app.settings.get_string ("read-receipts") == "always" && !is_from_me (l.info)) action_requested ("receipt-send", l.info);
            invite_slot_clear ();
            if (l.mime != null) show_invite (l.mime, l.info);
            bool any_remote = false;
            foreach (var x in loaded) if (x.mime != null && x.mime.has_remote_content () && !allow_images (x)) any_remote = true;
            notice.visible = any_remote;
            if (!initial) {
                web.evaluate_javascript.begin ("document.querySelectorAll ('section.msg').forEach (function (s) { s.classList.toggle ('current', s.dataset.id == '%s'); });".printf (l.info.id.to_string ()), -1, "lettere", null, null, null);
            }
            message_shown (l.info);
        }

        private bool is_from_me (MessageInfo m) {
            foreach (var a in app.accounts.accounts) if (a.email.down () == m.sender_email.down ()) return true;
            return false;
        }

        private void update_security (LoadedMessage l) {
            var c = l.crypto;
            if (c == null || c.kind == "") {
                security.visible = false;
                return;
            }
            security.visible = true;
            security_icon.icon_name = c.ok ? "security-high-symbolic" : "security-low-symbolic";
            security_label.label = c.describe ();
            if (c.ok) {
                security.remove_css_class ("error");
            } else {
                security.add_css_class ("error");
            }
        }

        private void show_invite (MimeMessage msg, MessageInfo? info) {
            var invite = CalendarInvite.from_message (msg);
            if (invite == null) return;
            var card = new InviteCard (app, invite, info);
            card.toast.connect ((t) => toast (t));
            invite_slot.append (card);
        }

        private string card_html (LoadedMessage l, bool dark) {
            var m = l.info;
            var sb = new StringBuilder ();
            bool is_current = current != null && m.id == current.id;
            bool open = is_current || m.unread || loaded.size == 1 || l == loaded[loaded.size - 1];
            sb.append ("<section class=\"msg%s\" data-id=\"%s\">".printf (is_current ? " current" : "", m.id.to_string ()));
            sb.append ("<details%s><summary>".printf (open ? " open" : ""));
            string who = m.sender_display != "" ? m.sender_display : _("Unknown Sender");
            string? face = m.sender_email != "" ? app.contacts.photo_for (m.sender_email) : null;
            if (face != null) sb.append ("<img class=\"face\" alt=\"\" src=\"%s\">".printf (Html.attr (face)));
            else sb.append ("<span class=\"face mono\" aria-hidden=\"true\">%s</span>".printf (Html.escape (who.get_char (0).toupper ().to_string ())));
            sb.append ("<span class=\"who\">%s</span>".printf (Html.escape (who)));
            if (m.sender_name != "" && m.sender_email != "") sb.append ("<span class=\"addr\">%s</span>".printf (Html.escape (m.sender_email)));
            if (m.sender_email != "" && !app.contacts.knows (m.sender_email)) sb.append ("<a class=\"add\" href=\"lettere:add-contact/%s\">%s</a>".printf (m.id.to_string (), Html.escape (_("Add to Contacts"))));
            sb.append ("<span class=\"when\">%s</span>".printf (Html.escape (format_full (m.date))));
            sb.append ("<span class=\"pv\">%s</span>".printf (Html.escape (m.preview)));
            sb.append ("</summary>");
            var to = Mime.parse_addresses (m.to_list);
            var cc = Mime.parse_addresses (m.cc_list);
            sb.append ("<div class=\"meta\">");
            if (to.size > 0) sb.append ("<div>%s</div>".printf (Html.escape (_("To: %s").printf (Mime.display_addresses (to)))));
            if (cc.size > 0) sb.append ("<div>%s</div>".printf (Html.escape (_("Cc: %s").printf (Mime.display_addresses (cc)))));
            sb.append ("</div>");
            if (m.id >= 0) {
                sb.append ("<div class=\"acts\">");
                string id = m.id.to_string ();
                sb.append ("<a href=\"lettere:reply/%s\">%s</a>".printf (id, Html.escape (_("Reply"))));
                sb.append ("<a href=\"lettere:reply-all/%s\">%s</a>".printf (id, Html.escape (_("Reply All"))));
                sb.append ("<a href=\"lettere:forward/%s\">%s</a>".printf (id, Html.escape (_("Forward"))));
                if (l.translation == "") sb.append ("<a href=\"lettere:translate/%s\">%s</a>".printf (id, Html.escape (_("Translate"))));
                else sb.append ("<a href=\"lettere:original/%s\">%s</a>".printf (id, Html.escape (_("Show Original"))));
                sb.append ("</div>");
            }
            if (l.mime == null) {
                sb.append ("<div class=\"err\">%s</div>".printf (Html.escape (l.error != "" ? l.error : _("Loading Message"))));
            } else {
                string doc = Html.message_document (l.mime, allow_images (l), dark, l.translation);
                sb.append ("<iframe sandbox=\"allow-same-origin allow-popups allow-popups-to-escape-sandbox\" title=\"%s\" srcdoc=\"%s\"></iframe>".printf (Html.attr (_("Message from %s").printf (who)), Html.attr (doc)));
                if (l.mime.attachments.size > 0 && loaded.size > 1) {
                    sb.append ("<div class=\"atts\">");
                    for (int i = 0; i < l.mime.attachments.size; i++) {
                        var a = l.mime.attachments[i];
                        sb.append ("<a href=\"lettere:attach/%s/%d\">%s (%s)</a>".printf (m.id.to_string (), i, Html.escape (a.filename), Html.escape (format_size (a.data.get_size ()))));
                    }
                    sb.append ("</div>");
                }
            }
            sb.append ("</details></section>");
            return sb.str;
        }

        public void refresh () {
            render_all ();
        }

        private void render_all () {
            bool dark = app.dark_reading ();
            bool allow = true;
            foreach (var l in loaded) if (!allow_images (l)) allow = false;
            images_allowed = allow;
            string fg = dark ? "#e8e8ea" : "#1d1d1f";
            string dim = dark ? "#a0a0a8" : "#6a6a72";
            string card = dark ? "#26262a" : "#ffffff";
            string line = dark ? "#3a3a40" : "#e4e4e8";
            string bg = dark ? "#1f1f22" : "#ffffff";
            var sb = new StringBuilder ();
            sb.append ("<!DOCTYPE html><html><head><meta charset=\"utf-8\">");
            sb.append ("<meta http-equiv=\"Content-Security-Policy\" content=\"%s\">".printf (Html.outer_policy (allow)));
            sb.append ("<style>html,body{margin:0;padding:0;background:%s;color:%s;font-family:sans-serif;font-size:14px;}".printf (bg, fg));
            sb.append ("section.msg{margin:0;padding:10px 16px 6px 16px;border-bottom:1px solid %s;background:%s;}".printf (line, card));
            sb.append ("section.msg.current{box-shadow:inset 3px 0 0 #3584e4;}");
            sb.append ("summary{cursor:pointer;list-style:none;display:flex;gap:10px;align-items:baseline;flex-wrap:wrap;padding:4px 0;}summary::-webkit-details-marker{display:none;}");
            sb.append (".face{width:28px;height:28px;border-radius:50%;object-fit:cover;align-self:center;flex:none;}.face.mono{display:inline-flex;align-items:center;justify-content:center;background:#3584e4;color:#fff;font-weight:700;font-size:13px;}");
            sb.append (".who{font-weight:700;}.addr,.when,.meta{color:%s;font-size:12px;}.when{margin-left:auto;}".printf (dim));
            sb.append ("details[open] .pv{display:none;}.pv{color:%s;font-size:12px;flex-basis:100%%;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;}".printf (dim));
            sb.append (".acts{margin:4px 0 6px 0;display:flex;gap:14px;font-size:12px;}.acts a,.atts a,a.add{color:#3584e4;text-decoration:none;}a.add{font-size:12px;}.atts{display:flex;flex-wrap:wrap;gap:12px;margin:6px 0;font-size:12px;}");
            sb.append ("iframe{border:0;width:100%%;min-height:40px;display:block;background:%s;border-radius:8px;}.err{color:%s;padding:10px 0;}".printf (dark ? "#1f1f22" : "#ffffff", dim));
            sb.append ("</style></head><body>");
            foreach (var l in loaded) sb.append (card_html (l, dark));
            sb.append ("</body></html>");
            web.load_html (sb.str, "about:blank");
            body_stack.visible_child_name = "html";
        }

        public void load_images () {
            images_loaded = true;
            images_allowed = true;
            notice.visible = false;
            foreach (var l in loaded) l.images = true;
            render_all ();
        }

        private void trust_sender () {
            string email = current != null ? current.sender_email : (mime != null && mime.from.size > 0 ? mime.from[0].email : "");
            if (email != "") {
                string[] list = app.settings.get_strv ("image-senders");
                list += email.down ();
                app.settings.set_strv ("image-senders", list);
            }
            load_images ();
        }

        public async void translate_current () {
            LoadedMessage? l = current != null ? find (current.id) : (loaded.size > 0 ? loaded[0] : null);
            if (l == null || l.mime == null) return;
            try {
                string text = yield Translator.translate (l.mime.body_text ());
                l.translation = text;
                render_all ();
            } catch (Error e) {
                toast (_("Could not translate: %s").printf (e.message));
            }
        }

        public void show_translation (MessageInfo m) {
            var l = find (m.id);
            if (l == null) return;
            current = m;
            translate_current.begin ();
        }

        private void clear_attachments () {
            Widget? c;
            while ((c = attachments.get_first_child ()) != null) attachments.remove (c);
            attachments_scroll.visible = false;
            shown_attachments.clear ();
        }

        private Attachment? attachment_at (int index) {
            return index >= 0 && index < shown_attachments.size ? shown_attachments[index] : null;
        }

        private File? write_temp (Attachment a) {
            string dir = Path.build_filename (Environment.get_user_cache_dir (), "singularity-lettere", "attachments", "%u".printf (serial));
            DirUtils.create_with_parents (dir, 0700);
            string name = a.filename.replace ("/", "_");
            if (name == "" || name == "." || name == "..") name = "attachment";
            var f = File.new_for_path (Path.build_filename (dir, name));
            try {
                f.replace_contents (a.data.get_data (), null, false, FileCreateFlags.PRIVATE | FileCreateFlags.REPLACE_DESTINATION, null);
                return f;
            } catch (Error e) {
                toast (_("Could not prepare %s: %s").printf (a.filename, e.message));
                return null;
            }
        }

        private void add_attachment (Attachment a) {
            var chip = new AttachmentChip (a, () => write_temp (a));
            int index = shown_attachments.size;
            shown_attachments.add (a);
            chip.open_requested.connect (() => preview_attachment (a));
            chip.save_requested.connect (() => save_attachment (a));
            var click = new GestureClick ();
            click.button = 3;
            click.pressed.connect ((n, x, y) => {
                click.set_state (EventSequenceState.CLAIMED);
                attachment_menu (chip, index, x, y);
            });
            chip.add_controller (click);
            var press = new GestureLongPress ();
            press.pressed.connect ((x, y) => {
                press.set_state (EventSequenceState.CLAIMED);
                attachment_menu (chip, index, x, y);
            });
            chip.add_controller (press);
            attachments.append (chip);
        }

        private void finish_attachments () {
            attachments_scroll.visible = shown_attachments.size > 0;
            if (shown_attachments.size < 2) return;
            var all = new Button.with_label (_("Save All…"));
            all.add_css_class ("flat");
            all.valign = Align.CENTER;
            all.clicked.connect (() => save_all ());
            attachments.append (all);
        }

        private void attachment_menu (Widget chip, int index, double x, double y) {
            var target = new Variant.int32 (index);
            var menu = new ContextMenu (chip);
            menu.add_item (_("Preview"), "view-reveal-symbolic", () => activate_action_variant ("reader.preview-attachment", target));
            menu.add_item (_("Open"), "document-open-symbolic", () => activate_action_variant ("reader.open-attachment", target));
            menu.add_item (_("Save…"), "document-save-symbolic", () => activate_action_variant ("reader.save-attachment", target));
            menu.add_item (_("Share…"), "singularity-share-symbolic", () => activate_action_variant ("reader.share-attachment", target));
            menu.set_pointing_to ({ (int) x, (int) y, 1, 1 });
            menu.popup ();
        }

        private void preview_attachment (Attachment a) {
            var dlg = new AttachmentPreview (app, a, () => write_temp (a));
            dlg.transient_for = get_root () as Gtk.Window;
            dlg.open_requested.connect (() => open_attachment (a));
            dlg.save_requested.connect (() => save_attachment (a));
            dlg.open_dialog ();
        }

        private void open_attachment (Attachment a) {
            var f = write_temp (a);
            if (f == null) return;
            new FileLauncher (f).launch.begin (get_root () as Gtk.Window, null, (o, res) => {
                try {
                    new FileLauncher (f).launch.end (res);
                } catch (Error e) {
                    toast (_("No app can open %s").printf (a.filename));
                }
            });
        }

        private void share_attachment (Attachment a) {
            var f = write_temp (a);
            if (f == null) return;
            Singularity.Share.files (get_root () as Gtk.Window, { f });
        }

        public void save_attachment (Attachment a) {
            var dialog = new FileDialog ();
            dialog.title = _("Save Attachment");
            dialog.initial_name = a.filename;
            dialog.save.begin (get_root () as Gtk.Window, null, (o, res) => {
                try {
                    var f = dialog.save.end (res);
                    if (f == null) return;
                    f.replace_contents (a.data.get_data (), null, false, FileCreateFlags.REPLACE_DESTINATION, null);
                    toast (_("Saved %s").printf (f.get_basename ()));
                } catch (Error e) {
                    if (!(e is IOError.CANCELLED) && !(e is DialogError)) toast (_("Could not save: %s").printf (e.message));
                }
            });
        }

        public void save_all () {
            var dialog = new FileDialog ();
            dialog.title = _("Save All Attachments");
            dialog.select_folder.begin (get_root () as Gtk.Window, null, (o, res) => {
                try {
                    var dir = dialog.select_folder.end (res);
                    if (dir == null) return;
                    int n = 0;
                    foreach (var a in shown_attachments) {
                        string name = a.filename.replace ("/", "_");
                        var f = dir.get_child (name);
                        int k = 2;
                        while (f.query_exists ()) {
                            int dot = name.last_index_of_char ('.');
                            f = dir.get_child (dot > 0 ? "%s (%d)%s".printf (name.substring (0, dot), k, name.substring (dot)) : "%s (%d)".printf (name, k));
                            k++;
                        }
                        f.replace_contents (a.data.get_data (), null, false, FileCreateFlags.NONE, null);
                        n++;
                    }
                    toast (ngettext ("Saved %d attachment", "Saved %d attachments", n).printf (n));
                } catch (Error e) {
                    if (!(e is IOError.CANCELLED) && !(e is DialogError)) toast (_("Could not save: %s").printf (e.message));
                }
            });
        }

        public uint8[]? current_raw () {
            if (current != null) return app.store.body (current.id);
            return null;
        }

        public void print (Gtk.Window parent) {
            if (mime == null) return;
            string from = current != null ? (current.sender_name + " " + current.sender_email).strip () : (mime.from.size > 0 ? mime.from[0].to_string () : "");
            string to = mime.to.size > 0 ? _("To: %s").printf (Mime.display_addresses (mime.to)) : "";
            string cc = mime.cc.size > 0 ? _("Cc: %s").printf (Mime.display_addresses (mime.cc)) : "";
            var d = current != null ? current.date : (mime.date != null ? mime.date.to_unix () : 0);
            string header = MailPrintSource.header_block (subject.label, from, to, cc, format_full (d));
            string html = mime.text_html != "" ? mime.text_html : Html.plain_body (mime.text_plain);
            var source = new MailPrintSource (subject.label, html, mime.inline_parts, images_allowed, header);
            Singularity.Print.run_source.begin (parent, source);
        }

        public void print_conversation (Gtk.Window parent) {
            if (loaded.size == 0) return;
            var sb = new StringBuilder ();
            foreach (var l in loaded) {
                if (l.mime == null) continue;
                string to = l.mime.to.size > 0 ? _("To: %s").printf (Mime.display_addresses (l.mime.to)) : "";
                sb.append (MailPrintSource.header_block (l.info.subject, (l.info.sender_name + " " + l.info.sender_email).strip (), to, "", format_full (l.info.date)));
                sb.append (l.mime.text_html != "" ? l.mime.text_html : Html.plain_body (l.mime.text_plain));
                sb.append ("<hr>");
            }
            var parts = new Gee.HashMap<string, Attachment> ();
            foreach (var l in loaded) if (l.mime != null) parts.set_all (l.mime.inline_parts);
            var source = new MailPrintSource (subject.label, sb.str, parts, images_allowed, "");
            Singularity.Print.run_source.begin (parent, source);
        }
    }
}
