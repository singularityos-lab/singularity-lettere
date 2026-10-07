using Gtk;
using Singularity.Widgets;

namespace Singularity.Apps.Lettere {

    public class LettereWindow : Singularity.Widgets.Window {
        private LettereApp app;
        private AppSidebar sidebar;
        private Stack stack;
        private GLib.ListStore model;
        private MultiSelection selection;
        private ListView list;
        private Stack list_stack;
        private Box list_empty;
        private string empty_key = "";
        private string empty_inbox = "";
        private Banner banner;
        private Stack reader_stack;
        private ReaderView reader;
        private ComposerView composer;
        private Singularity.Widgets.Toast? last_toast = null;
        private Paned paned;
        private SearchBubble search;
        private BubbleSwitcher focus_switch;
        private Box list_header;
        private Button filter_chip;
        private WelcomePage multi_page;
        private Box outbox_page;
        private Label outbox_title;
        private Label outbox_detail;
        private ContextRibbon mail_ribbon;
        private ContextRibbon compose_ribbon;
        private RibbonButton edit_draft_item;
        private RibbonButton reply_item;
        private RibbonButton reply_all_item;
        private RibbonButton forward_item;
        private RibbonButton delete_item;
        private RibbonButton star_item;
        private RibbonButton read_item;
        private RibbonButton sync_item;
        private RibbonButton save_search_item;
        private RibbonMenu move_item;
        private RibbonMenu snooze_item;
        private RibbonMenu category_item;
        private RibbonMenu steps_item;
        private RibbonSelector filter_selector;
        private RibbonSelector sort_selector;
        private SimpleAction conversations_action;
        private SimpleAction offline_action;
        private SimpleAction dark_action;
        private SimpleAction focused_action;
        private SimpleAction layout_action;
        private Gee.HashMap<string, SidebarRow> rows = new Gee.HashMap<string, SidebarRow> ();
        private Gee.HashMap<string, Label> badges = new Gee.HashMap<string, Label> ();
        private Gee.HashSet<AccountSync> watched = new Gee.HashSet<AccountSync> ();
        private string source = "unified";
        private string query = "";
        private Gee.Collection<int64?>? server_hits;
        private uint rebuild_id;
        private uint search_id;
        private bool rebuilding;
        private bool composing;
        private bool saving_draft { get; set; }
        private bool closing;
        private bool file_view;
        private int compose_serial;
        private MessageInfo? lead;
        private int64 outbox_selected;

        public LettereWindow (LettereApp app) {
            Object (application: app);
            this.app = app;
            set_title ("Lettere");
            set_default_size (1240, 800);
            set_size_request (420, 480);

            sidebar = new AppSidebar (250);
            set_sidebar (sidebar);
            sidebar.add_bubble_icon ("list-add-symbolic", _("Add Account"), () => add_account ());

            stack = new Stack ();
            stack.transition_type = StackTransitionType.CROSSFADE;
            stack.add_named (build_welcome (), "welcome");
            stack.add_named (build_mail (), "mail");
            composer = new ComposerView (app);
            stack.add_named (build_compose_page (), "compose");
            var overlay = new Overlay ();
            overlay.child = stack;
            set_content (overlay);

            mail_ribbon.attach (this);
            compose_ribbon.attach (this);
            search = add_bubble_search (_("Search Mail, try from: or has:attachment"), (t) => {
                query = t.strip ();
                server_hits = null;
                if (search_id != 0) Source.remove (search_id);
                search_id = Timeout.add (220, () => {
                    search_id = 0;
                    rebuild_list ();
                    return Source.REMOVE;
                });
            });
            set_bubble_priority (search, 5);

            install_actions ();
            app.toast.connect ((text, label, cb) => show_toast (text, label, (owned) cb));
            app.syncs_changed.connect (on_accounts_changed);
            app.store.folders_changed.connect ((acc) => rebuild_sidebar ());
            app.outbox_changed.connect (() => {
                update_counts ();
                if (source == "outbox") rebuild_list ();
            });
            app.rules_ran.connect ((n) => show_toast (ngettext ("A rule sorted %d new message", "Rules sorted %d new messages", n).printf (n)));
            app.settings.changed["conversations"].connect (() => {
                conversations_action.set_state (new Variant.boolean (app.settings.get_boolean ("conversations")));
                rebuild_list ();
            });
            app.settings.changed["work-offline"].connect (() => {
                offline_action.set_state (new Variant.boolean (app.settings.get_boolean ("work-offline")));
                update_banner ();
                sync_actions ();
            });
            app.settings.changed["reading-pane"].connect (() => apply_layout ());
            app.settings.changed["focused-inbox"].connect (() => {
                focused_action.set_state (new Variant.boolean (app.settings.get_boolean ("focused-inbox")));
                rebuild_list ();
            });
            app.settings.changed["saved-searches"].connect (() => rebuild_sidebar ());
            app.settings.changed["sort"].connect (() => rebuild_list ());
            app.settings.changed["sort-ascending"].connect (() => rebuild_list ());
            app.settings.changed["filter"].connect (() => rebuild_list ());
            reader.message_shown.connect (on_message_shown);
            reader.open_uri.connect ((uri) => launch (uri));
            reader.toast.connect ((t) => show_toast (t));
            reader.action_requested.connect (on_reader_action);
            reader.notify["images-loaded"].connect (() => sync_actions ());
            composer.changed_state.connect (() => sync_actions ());
            on_accounts_changed ();
            apply_layout ();
            close_request.connect (() => {
                if (paned.orientation == Orientation.HORIZONTAL) app.settings.set_int ("list-width", paned.position);
                if (closing) return true;
                if (composing && (composer.dirty || saving_draft)) {
                    closing = true;
                    set_sensitive (false);
                    save_draft.begin (false, (o, res) => {
                        bool saved = save_draft.end (res);
                        closing = false;
                        set_sensitive (true);
                        if (saved) close ();
                    });
                    return true;
                }
                return false;
            });
            Timeout.add_seconds (120, () => {
                if (composing && composer.dirty && app.settings.get_boolean ("autosave-drafts")) save_draft.begin (true);
                return Source.CONTINUE;
            });
        }

        private Widget build_welcome () {
            var wp = new WelcomePage ();
            wp.app_icon_name = "dev.sinty.lettere";
            wp.title = "Lettere";
            wp.subtitle = _("Read and write email from all your accounts, even offline");
            wp.add_action ("network-server", _("Add Account"), _("IMAP, POP, Exchange or JMAP with your email address and password"), () => add_account ());
            wp.add_action ("folder-remote", _("Use an Online Account…"), _("Google, Microsoft and others added in Settings appear here by themselves"), () => OnlineMail.open_settings ());
            wp.add_action ("document-open", _("Import Mail"), _("Bring in an Outlook data file (.pst), a mailbox (.mbox) or messages (.eml, .msg)"), () => import_mail ());
            wp.add_action ("text-x-generic", _("Open a Message File"), _("View a message saved as an .eml or .msg file"), () => open_file_dialog ());
            wp.close_requested.connect (() => close ());
            return wp;
        }

        private Widget build_mail () {
            model = new GLib.ListStore (typeof (MessageInfo));
            selection = new MultiSelection (model);
            selection.selection_changed.connect ((pos, n) => {
                if (rebuilding) return;
                on_selection ();
            });

            var factory = new SignalListItemFactory ();
            factory.setup.connect ((o) => {
                var item = (ListItem) o;
                var row = new MessageRow (app);
                item.child = row;
                var drag = new DragSource ();
                drag.actions = Gdk.DragAction.MOVE | Gdk.DragAction.COPY;
                drag.prepare.connect ((x, y) => {
                    var m = item.item as MessageInfo;
                    if (m == null) return null;
                    if (!selection.is_selected (item.position)) {
                        rebuilding = true;
                        selection.select_item (item.position, true);
                        rebuilding = false;
                        on_selection ();
                    }
                    return new Gdk.ContentProvider.for_value ("lettere-ids:" + ids_string (selected_targets ()));
                });
                drag.drag_begin.connect ((d) => drag.set_icon (new WidgetPaintable (row), 20, 20));
                row.add_controller (drag);
                var click = new GestureClick ();
                click.button = 3;
                click.pressed.connect ((n, x, y) => {
                    click.set_state (EventSequenceState.CLAIMED);
                    var m = item.item as MessageInfo;
                    if (m != null) {
                        if (!selection.is_selected (item.position)) selection.select_item (item.position, true);
                        row_menu (row, x, y);
                    }
                });
                row.add_controller (click);
                var dbl = new GestureClick ();
                dbl.button = 1;
                dbl.released.connect ((n, x, y) => {
                    if (n == 2) {
                        var m = item.item as MessageInfo;
                        if (m != null && source != "outbox") open_in_window (m);
                    }
                });
                row.add_controller (dbl);
            });
            factory.bind.connect ((o) => {
                var item = (ListItem) o;
                var m = (MessageInfo) item.item;
                var f = app.store.folder (m.folder);
                ((MessageRow) item.child).bind (m, source == "outbox" || (f != null && (f.role == "sent" || f.role == "drafts")));
            });
            factory.unbind.connect ((o) => {
                ((MessageRow) ((ListItem) o).child).unbind ();
            });
            list = new ListView (selection, factory);
            list.add_css_class ("lettere-list");
            list.update_property (AccessibleProperty.LABEL, _("Messages"), -1);
            list.activate.connect ((pos) => {
                var m = (MessageInfo) model.get_item (pos);
                var f = m != null ? app.store.folder (m.folder) : null;
                if (f != null && f.role == "drafts") edit_draft ();
                else if (app.settings.get_string ("reading-pane") == "off" && m != null) open_in_window (m);
                else reader.grab_focus ();
            });
            var scroll = new ScrolledWindow ();
            scroll.hscrollbar_policy = PolicyType.NEVER;
            scroll.vexpand = true;
            scroll.child = list;

            list_empty = new Box (Orientation.VERTICAL, 0);
            list_empty.vexpand = true;

            list_stack = new Stack ();
            list_stack.add_named (scroll, "list");
            list_stack.add_named (list_empty, "empty");
            list_stack.vexpand = true;

            banner = new Banner ();
            banner.visible = false;
            banner.button_clicked.connect (on_banner_action);
            banner.secondary_clicked.connect (on_banner_secondary);

            list_header = new Box (Orientation.HORIZONTAL, 6);
            list_header.add_css_class ("lettere-list-header");
            focus_switch = new BubbleSwitcher ();
            focus_switch.add_option ("focused", _("Focused"));
            focus_switch.add_option ("other", _("Other"));
            focus_switch.set_active ("focused");
            focus_switch.selected.connect ((name) => {
                app.settings.set_string ("focus-view", name);
                rebuild_list ();
            });
            focus_switch.halign = Align.START;
            list_header.append (focus_switch);
            var spacer = new Box (Orientation.HORIZONTAL, 0);
            spacer.hexpand = true;
            list_header.append (spacer);
            filter_chip = new Button ();
            filter_chip.add_css_class ("lettere-filter-chip");
            var chip_box = new Box (Orientation.HORIZONTAL, 6);
            var chip_label = new Label ("");
            chip_box.append (chip_label);
            var chip_icon = new Image.from_icon_name ("window-close-symbolic");
            chip_icon.pixel_size = 12;
            chip_box.append (chip_icon);
            filter_chip.child = chip_box;
            filter_chip.tooltip_text = _("Show All Messages");
            filter_chip.clicked.connect (() => activate_action ("win.filter", new Variant.string ("all")));
            list_header.append (filter_chip);

            var list_pane = new Box (Orientation.VERTICAL, 0);
            list_pane.add_css_class ("lettere-list-pane");
            list_pane.set_size_request (300, -1);
            list_pane.append (banner);
            list_pane.append (list_header);
            list_pane.append (list_stack);

            reader = new ReaderView (app);
            var none = new WelcomePage ();
            none.is_section = true;
            none.app_icon_name = "dev.sinty.lettere";
            none.title = _("No Message Selected");
            none.subtitle = _("Choose a message from the list. Use the arrow keys, or J and K, to move between messages. Hold Ctrl or Shift to choose several.");
            none.add_action ("document-new", _("New Message"), _("Write to someone"), () => compose_new ());
            none.add_action ("emblem-synchronizing", _("Sync Now"), _("Check every account for new mail"), () => sync_now ());
            none.add_action ("system-search", _("Search Mail"), _("Find a message by sender, subject or words"), () => search.grab_focus_entry ());

            multi_page = new WelcomePage ();
            multi_page.is_section = true;
            multi_page.app_icon_name = "dev.sinty.lettere";
            multi_page.subtitle = _("Choose what to do with all of them. Flag, categorize and the rest are in the toolbar.");
            multi_page.add_action ("mail-archive", _("Archive"), _("Move them to the archive"), () => bulk_action ("archive"));
            multi_page.add_action ("user-trash", _("Delete"), _("Move them to the trash"), () => bulk_action ("delete"));
            multi_page.add_action ("mail-mark-read", _("Mark as Read"), _("Clear the unread mark on all of them"), () => bulk_action ("read"));
            multi_page.add_action ("folder", _("Move To…"), _("Choose a folder for all of them"), () => bulk_action ("move"));
            var multi = multi_page;

            outbox_page = new Box (Orientation.VERTICAL, 12);
            outbox_page.margin_top = 24;
            outbox_page.margin_start = 24;
            outbox_page.margin_end = 24;
            outbox_title = new Label ("");
            outbox_title.add_css_class ("title-2");
            outbox_title.wrap = true;
            outbox_title.xalign = 0;
            outbox_page.append (outbox_title);
            outbox_detail = new Label ("");
            outbox_detail.wrap = true;
            outbox_detail.xalign = 0;
            outbox_detail.add_css_class ("dim-label");
            outbox_page.append (outbox_detail);
            var ob_actions = new Box (Orientation.HORIZONTAL, 8);
            var send_now = new Button.with_label (_("Send Now"));
            send_now.add_css_class ("pill");
            send_now.add_css_class ("suggested-action");
            send_now.clicked.connect (() => outbox_action ("send"));
            ob_actions.append (send_now);
            var change = new Button.with_label (_("Change Time…"));
            change.add_css_class ("pill");
            change.clicked.connect (() => outbox_action ("time"));
            ob_actions.append (change);
            var edit = new Button.with_label (_("Edit"));
            edit.add_css_class ("pill");
            edit.clicked.connect (() => outbox_action ("edit"));
            ob_actions.append (edit);
            var cancel = new Button.with_label (_("Cancel Sending"));
            cancel.add_css_class ("pill");
            cancel.add_css_class ("destructive-action");
            cancel.clicked.connect (() => outbox_action ("cancel"));
            ob_actions.append (cancel);
            outbox_page.append (ob_actions);

            reader_stack = new Stack ();
            reader_stack.transition_type = StackTransitionType.CROSSFADE;
            reader_stack.add_named (none, "none");
            reader_stack.add_named (new Box (Orientation.VERTICAL, 0), "blank");
            reader_stack.add_named (reader, "reader");
            reader_stack.add_named (multi, "multi");
            reader_stack.add_named (outbox_page, "outbox");
            reader_stack.hexpand = true;
            reader_stack.set_size_request (380, 240);

            paned = new Paned (Orientation.HORIZONTAL);
            paned.start_child = list_pane;
            paned.end_child = reader_stack;
            paned.resize_start_child = false;
            paned.shrink_start_child = false;
            paned.shrink_end_child = false;
            paned.position = int.max (300, app.settings.get_int ("list-width"));
            paned.vexpand = true;

            mail_ribbon = new ContextRibbon ();
            build_home (mail_ribbon.add_context ("home", _("Home"), "go-home-symbolic"));
            build_send_receive (mail_ribbon.add_context ("send-receive", _("Send / Receive"), "mail-send-receive-symbolic"));
            build_folder (mail_ribbon.add_context ("folder", _("Folder"), "folder-symbolic"));
            build_view (mail_ribbon.add_context ("view", _("View"), "view-reveal-symbolic"));

            var page = new Box (Orientation.VERTICAL, 0);
            page.append (mail_ribbon);
            page.append (paned);
            Singularity.Widgets.apply_view_edge (page);
            return page;
        }

        private Widget build_compose_page () {
            compose_ribbon = new ContextRibbon ();
            var message = compose_ribbon.add_context ("message", _("Message"), "mail-message-new-symbolic");
            var send_item = message.add_button ("mail-send-symbolic", _("Send"), _("Send the message"));
            send_item.label_in_compact = true;
            send_item.button.add_css_class ("lettere-send");
            send_item.activated.connect (() => send.begin (0));
            labeled (message.add_button ("document-open-recent-symbolic", _("Send Later"), _("Send Later…"), "win.send-later"));
            labeled (message.add_button ("user-trash-symbolic", _("Discard"), _("Discard the message"))).activated.connect (() => discard ());
            message.add_separator ();
            message.add_button ("document-save-symbolic", _("Save Draft"), null, "win.save-draft");
            message.add_button ("mail-attachment-symbolic", _("Attach Files"), _("Attach Files…")).activated.connect (() => composer.pick_files ());
            composer.fill_ribbon (compose_ribbon, message);
            compose_ribbon.context_changed.connect (() => sync_actions ());

            var page = new Box (Orientation.VERTICAL, 0);
            page.append (compose_ribbon);
            page.append (composer);
            Singularity.Widgets.apply_view_edge (page);
            return page;
        }

        private RibbonButton labeled (RibbonButton b) {
            b.label_in_compact = true;
            return b;
        }

        private RibbonMenu ribbon_menu (RibbonContext c, string icon, string label, string? tip, bool with_label, owned RibbonMenuBuilder build) {
            var m = c.add_menu (icon, label, tip);
            m.label_in_compact = with_label;
            m.set_builder ((owned) build);
            return m;
        }

        private void build_home (RibbonContext c) {
            labeled (c.add_button ("mail-message-new-symbolic", _("New Message"), null, "win.compose"));
            edit_draft_item = labeled (c.add_button ("document-edit-symbolic", _("Edit Draft"), null, "win.edit-draft"));
            c.add_separator ();
            delete_item = c.add_button ("user-trash-symbolic", _("Delete"), null, "win.delete");
            c.add_button ("mail-archive-symbolic", _("Archive"), null, "win.archive");
            c.add_button ("mail-mark-junk-symbolic", _("Spam"), null, "win.junk");
            c.add_button ("edit-clear-all-symbolic", _("Sweep"), _("Sweep messages from this sender…"), "win.sweep");
            c.add_separator ();
            reply_item = c.add_button ("mail-reply-sender-symbolic", _("Reply"), null, "win.reply");
            reply_all_item = c.add_button ("mail-reply-all-symbolic", _("Reply All"), null, "win.reply-all");
            forward_item = c.add_button ("mail-forward-symbolic", _("Forward"), null, "win.forward");
            c.add_separator ();
            move_item = ribbon_menu (c, "folder-symbolic", _("Move"), _("Move To (Ctrl+Shift+M)"), true, (m) => fill_move (m, false));
            category_item = ribbon_menu (c, "bookmark-new-symbolic", _("Categorize"), null, false, (m) => fill_categories (m));
            steps_item = ribbon_menu (c, "media-playlist-consecutive-symbolic", _("Quick Steps"), null, false, (m) => fill_steps (m));
            c.add_separator ();
            read_item = c.add_button ("mail-unread-symbolic", _("Mark as Unread"), null, "win.toggle-read");
            star_item = c.add_button ("non-starred-symbolic", _("Flag"), null, "win.toggle-star");
            snooze_item = ribbon_menu (c, "alarm-symbolic", _("Snooze"), null, false, (m) => fill_snooze (m));
        }

        private void build_send_receive (RibbonContext c) {
            sync_item = labeled (c.add_button ("view-refresh-symbolic", _("Sync Now"), _("Send and receive on every account"), "win.sync"));
            var offline = c.add_toggle ("network-offline-symbolic", _("Work Offline"), null, "win.offline");
            offline.label_in_compact = true;
            c.add_separator ();
            labeled (c.add_button ("mail-send-symbolic", _("Outbox"), _("Messages waiting to be sent"), "win.outbox"));
            labeled (c.add_button ("mail-reply-sender-symbolic", _("Automatic Replies"), _("Automatic Replies…"), "win.auto-reply"));
        }

        private void build_folder (RibbonContext c) {
            labeled (c.add_button ("folder-new-symbolic", _("New Folder"), _("New Folder…"), "win.new-folder"));
            labeled (c.add_button ("mail-read-symbolic", _("Mark All as Read"), null, "win.mark-all-read"));
            labeled (c.add_button ("user-trash-full-symbolic", _("Empty Folder"), _("Empty Folder…"), "win.empty-folder"));
            c.add_separator ();
            ribbon_menu (c, "media-playlist-consecutive-symbolic", _("Rules"), null, true, (m) => {
                m.add_item (_("Manage Rules…"), null, () => activate_action ("win.rules", null));
                m.add_item (_("Create Rule from Message…"), null, () => activate_action ("win.new-rule", null));
                m.add_item (_("Run Rules Now"), null, () => activate_action ("win.run-rules", null));
            });
            save_search_item = labeled (c.add_button ("bookmark-new-symbolic", _("Save Search"), _("Save this search as a folder")));
            save_search_item.activated.connect (() => save_search ());
        }

        private void build_view (RibbonContext c) {
            filter_selector = c.add_selector (_("Show"), 13, "view-reveal-symbolic");
            string[,] filters = { { "all", _("All Messages") }, { "unread", _("Unread") }, { "flagged", _("Flagged") }, { "attachments", _("Has Attachments") }, { "mentions", _("Mentions Me") } };
            for (int i = 0; i < filters.length[0]; i++) filter_selector.add_option (filters[i, 0], filters[i, 1]);
            filter_selector.changed.connect ((id) => activate_action ("win.filter", new Variant.string (id)));
            sort_selector = c.add_selector (_("Sort By"), 9, "view-sort-descending-symbolic");
            string[,] sorts = { { "date", _("Date") }, { "sender", _("From") }, { "subject", _("Subject") }, { "size", _("Size") }, { "flagged", _("Flagged First") }, { "unread", _("Unread First") } };
            for (int i = 0; i < sorts.length[0]; i++) sort_selector.add_option (sorts[i, 0], sorts[i, 1]);
            sort_selector.changed.connect ((id) => activate_action ("win.sort", new Variant.string (id)));
            c.add_toggle ("view-sort-ascending-symbolic", _("Oldest on Top"), null, "win.sort-ascending");
            c.add_separator ();
            labeled_toggle (c.add_toggle ("mail-reply-all-symbolic", _("Conversations"), _("Conversation View"), "win.conversations"));
            labeled_toggle (c.add_toggle ("starred-symbolic", _("Focused Inbox"), null, "win.focused-inbox"));
            c.add_toggle ("weather-clear-night-symbolic", _("Dark Messages"), null, "win.dark-messages");
            c.add_separator ();
            var pane = new GLib.Menu ();
            string[,] panes = { { _("Right"), "right" }, { _("Bottom"), "bottom" }, { _("Off"), "off" } };
            for (int i = 0; i < panes.length[0]; i++) {
                var it = new GLib.MenuItem (panes[i, 0], null);
                it.set_action_and_target_value ("win.reading-pane", new Variant.string (panes[i, 1]));
                pane.append_item (it);
            }
            var pane_menu = c.add_menu ("view-dual-symbolic", _("Reading Pane"));
            pane_menu.label_in_compact = true;
            pane_menu.set_menu_model (pane);
            c.add_button ("sidebar-show-symbolic", _("Folder Pane"), null, "win.sidebar");
            c.add_separator ();
            c.add_button ("zoom-out-symbolic", _("Zoom Out"), null, "win.zoom-out");
            c.add_button ("zoom-original-symbolic", _("Actual Size"), null, "win.zoom-reset");
            c.add_button ("zoom-in-symbolic", _("Zoom In"), null, "win.zoom-in");
            c.add_button ("image-x-generic-symbolic", _("Load Images"), null, "win.load-images");
        }

        private void labeled_toggle (RibbonToggle t) {
            t.label_in_compact = true;
        }

        private void popup_menu (RibbonMenu? item, owned RibbonMenuBuilder build) {
            if (item != null && item.button.get_mapped () && item.button.get_child_visible ()) {
                item.popup ();
                return;
            }
            var m = new ContextMenu (list);
            m.add_css_class ("context-ribbon-menu");
            build (m);
            Gdk.Rectangle r = { list.get_width () / 2, 8, 1, 1 };
            m.set_pointing_to (r);
            m.closed.connect (() => Idle.add (() => {
                if (m.get_parent () != null) m.unparent ();
                return Source.REMOVE;
            }));
            m.popup ();
        }

        private void popdown_menus (Widget w) {
            for (var c = w.get_first_child (); c != null; c = c.get_next_sibling ()) {
                if (c is Popover) ((Popover) c).popdown ();
                else popdown_menus (c);
            }
        }

        private void apply_layout () {
            string mode = app.settings.get_string ("reading-pane");
            if (layout_action != null) layout_action.set_state (new Variant.string (mode));
            if (mode == "bottom") {
                paned.orientation = Orientation.VERTICAL;
                paned.end_child.visible = true;
                paned.position = int.max (220, app.settings.get_int ("list-height"));
            } else if (mode == "off") {
                paned.orientation = Orientation.HORIZONTAL;
                paned.end_child.visible = false;
            } else {
                paned.orientation = Orientation.HORIZONTAL;
                paned.end_child.visible = true;
                paned.position = int.max (300, app.settings.get_int ("list-width"));
            }
        }

        private void fill_move (ContextMenu m, bool copy) {
            if (lead == null) return;
            var box = new Box (Orientation.VERTICAL, 0);
            foreach (var f in app.store.folders (lead.account)) {
                if (f.id == lead.folder && !copy) continue;
                var row = new Button ();
                row.add_css_class ("flat");
                row.add_css_class ("menu-row");
                var inner = new Box (Orientation.HORIZONTAL, 10);
                inner.margin_start = 14 * folder_depth (f);
                var icon = new Image.from_icon_name (f.icon_name);
                icon.pixel_size = 16;
                inner.append (icon);
                var l = new Label (f.display_name);
                l.xalign = 0;
                inner.append (l);
                row.child = inner;
                var target = f;
                row.clicked.connect (() => {
                    m.popdown ();
                    if (copy) copy_to (target);
                    else move_to (target);
                });
                box.append (row);
            }
            var scroll = new ScrolledWindow ();
            scroll.hscrollbar_policy = PolicyType.NEVER;
            scroll.propagate_natural_height = true;
            scroll.propagate_natural_width = true;
            scroll.max_content_height = 400;
            scroll.child = box;
            m.add_widget (scroll);
        }

        private void fill_snooze (ContextMenu m) {
            string[] labels = { _("Later Today"), _("Tomorrow"), _("This Weekend"), _("Next Week") };
            for (int i = 0; i < labels.length; i++) {
                int idx = i;
                m.add_item (labels[i], null, () => snooze_choice (idx));
            }
            m.add_separator ();
            m.add_item (_("Choose a Date…"), "x-office-calendar-symbolic", () => snooze_choice (4));
        }

        public static int64 preset_time (int idx) {
            var now = new DateTime.now_local ();
            var today8 = new DateTime.local (now.get_year (), now.get_month (), now.get_day_of_month (), 8, 0, 0);
            switch (idx) {
                case 0: return now.add_hours (3).to_unix ();
                case 1: return today8.add_days (1).to_unix ();
                case 2: {
                    int dow = now.get_day_of_week ();
                    int add = dow >= 6 ? 7 - dow + 6 : 6 - dow;
                    return today8.add_days (add == 0 ? 7 : add).to_unix ();
                }
                case 3: {
                    int dow = now.get_day_of_week ();
                    return today8.add_days (8 - dow).to_unix ();
                }
            }
            return 0;
        }

        private void snooze_choice (int idx) {
            if (idx == 4) {
                var dlg = new WhenDialog (app, _("Snooze Until"), preset_time (1), _("Snooze"));
                dlg.transient_for = this;
                dlg.chosen.connect ((t) => do_snooze (t));
                dlg.open_dialog ();
                return;
            }
            do_snooze (preset_time (idx));
        }

        private void do_snooze (int64 until) {
            var targets = selected_targets ();
            if (targets.size == 0) return;
            var s = app.syncs[targets[0].account];
            if (s == null) return;
            advance_after_removal ();
            app.snooze.begin (s, targets, until);
            show_toast (_("Snoozed until %s").printf (format_full (until)));
        }

        private void fill_categories (ContextMenu m) {
            var targets = selected_targets ();
            foreach (var cat in app.categories.items) {
                bool all = targets.size > 0;
                foreach (var t in targets) if (!t.has_category (cat.name)) all = false;
                string name = cat.name;
                bool on = all;
                m.add_item (cat.name, on ? "object-select-symbolic" : null, () => set_category (name, !on), on ? "checked" : null);
            }
            if (app.categories.items.size > 0) m.add_separator ();
            m.add_item (_("Manage Categories…"), null, () => {
                var dlg = new CategoriesDialog (app);
                dlg.transient_for = this;
                dlg.open_dialog ();
            });
        }

        private void set_category (string name, bool on) {
            var targets = selected_targets ();
            if (targets.size == 0) return;
            var s = app.syncs[targets[0].account];
            if (s == null) return;
            if (on) s.set_categories.begin (targets, { name }, {});
            else s.set_categories.begin (targets, {}, { name });
            reader_refresh_chips ();
        }

        private void reader_refresh_chips () {
            Idle.add (() => {
                if (lead != null) open_lead (lead);
                return Source.REMOVE;
            });
        }

        private void fill_steps (ContextMenu m) {
            foreach (var step in app.rules.steps) {
                var st = step;
                m.add_item (step.name, null, () => run_step (st));
            }
            if (app.rules.steps.size > 0) m.add_separator ();
            m.add_item (_("Manage Quick Steps…"), null, () => {
                var dlg = new QuickStepsDialog (app);
                dlg.transient_for = this;
                dlg.open_dialog ();
            });
        }

        private void run_step (QuickStep step) {
            var targets = selected_targets ();
            if (targets.size == 0) return;
            var s = app.syncs[targets[0].account];
            if (s == null) return;
            bool moves = false;
            foreach (var a in step.actions) if (a.kind in new string[] { "move", "archive", "delete", "junk", "snooze" }) moves = true;
            if (moves) advance_after_removal ();
            app.execute.begin (s, targets, step.actions, () => {
                show_toast (_("Quick step “%s” done").printf (step.name));
            });
        }

        private void install_actions () {
            string[] names = { "compose", "edit-draft", "save-draft", "open-file", "print", "print-conversation", "close", "undo", "redo", "cut", "copy", "paste", "select-all", "find",
                "unified", "sidebar", "load-images", "next", "previous", "reply", "reply-all", "forward", "forward-attachment", "redirect", "edit-as-new", "toggle-read", "toggle-star", "move", "copy-to", "archive",
                "delete", "junk", "not-junk", "block-sender", "add-account", "sync", "edit-account", "pin", "flag-today", "flag-tomorrow", "flag-week", "flag-next-week", "flag-date", "flag-complete", "flag-clear",
                "rules", "new-rule", "sweep", "view-source", "save-message", "open-window", "translate", "add-contact", "add-task", "move-other", "move-focused", "unsubscribe", "ignore",
                "import", "export", "mail-merge", "auto-reply", "open-shared", "new-folder", "zoom-in", "zoom-out", "zoom-reset", "categories", "quick-steps", "new-from-template", "run-rules",
                "mark-all-read", "outbox", "send-later", "templates", "signatures", "empty-folder", "read-aloud", "stop-reading" };
            foreach (string n in names) {
                var a = new SimpleAction (n, null);
                string name = n;
                a.activate.connect (() => run_action (name));
                add_action (a);
            }
            var folder = new SimpleAction ("folder", VariantType.INT64);
            folder.activate.connect ((v) => select_source ("folder:" + v.get_int64 ().to_string ()));
            add_action (folder);
            conversations_action = new SimpleAction.stateful ("conversations", null, new Variant.boolean (app.settings.get_boolean ("conversations")));
            conversations_action.activate.connect (() => app.settings.set_boolean ("conversations", !app.settings.get_boolean ("conversations")));
            add_action (conversations_action);
            offline_action = new SimpleAction.stateful ("offline", null, new Variant.boolean (app.settings.get_boolean ("work-offline")));
            offline_action.activate.connect (() => app.settings.set_boolean ("work-offline", !app.settings.get_boolean ("work-offline")));
            add_action (offline_action);
            dark_action = new SimpleAction.stateful ("dark-messages", null, new Variant.boolean (app.settings.get_boolean ("dark-messages")));
            dark_action.activate.connect (() => {
                app.settings.set_boolean ("dark-messages", !app.settings.get_boolean ("dark-messages"));
                dark_action.set_state (new Variant.boolean (app.settings.get_boolean ("dark-messages")));
            });
            add_action (dark_action);
            focused_action = new SimpleAction.stateful ("focused-inbox", null, new Variant.boolean (app.settings.get_boolean ("focused-inbox")));
            focused_action.activate.connect (() => app.settings.set_boolean ("focused-inbox", !app.settings.get_boolean ("focused-inbox")));
            add_action (focused_action);
            layout_action = new SimpleAction.stateful ("reading-pane", VariantType.STRING, new Variant.string (app.settings.get_string ("reading-pane")));
            layout_action.activate.connect ((v) => app.settings.set_string ("reading-pane", v.get_string ()));
            add_action (layout_action);
            var filter = new SimpleAction.stateful ("filter", VariantType.STRING, new Variant.string (app.settings.get_string ("filter")));
            filter.activate.connect ((v) => {
                filter.set_state (v);
                app.settings.set_string ("filter", v.get_string ());
            });
            add_action (filter);
            var sort = new SimpleAction.stateful ("sort", VariantType.STRING, new Variant.string (app.settings.get_string ("sort")));
            sort.activate.connect ((v) => {
                sort.set_state (v);
                app.settings.set_string ("sort", v.get_string ());
            });
            add_action (sort);
            var asc = new SimpleAction.stateful ("sort-ascending", null, new Variant.boolean (app.settings.get_boolean ("sort-ascending")));
            asc.activate.connect (() => {
                bool v = !app.settings.get_boolean ("sort-ascending");
                app.settings.set_boolean ("sort-ascending", v);
                asc.set_state (new Variant.boolean (v));
            });
            add_action (asc);
            var saved = new SimpleAction ("saved-search", VariantType.STRING);
            saved.activate.connect ((v) => select_source ("search:" + v.get_string ()));
            add_action (saved);

            var keys = new EventControllerKey ();
            keys.key_pressed.connect ((keyval, code, state) => {
                if ((state & (Gdk.ModifierType.CONTROL_MASK | Gdk.ModifierType.ALT_MASK | Gdk.ModifierType.SUPER_MASK)) != 0) return false;
                var focus = get_focus ();
                bool in_web = false;
                for (Widget? w = focus; w != null; w = w.get_parent ()) if (w is WebKit.WebView && w.is_ancestor (composer)) in_web = true;
                if (focus is Editable || focus is TextView || in_web) {
                    if (keyval == Gdk.Key.Escape && focus.is_ancestor (search) && search.text != "") {
                        search.clear ();
                        list.grab_focus ();
                        return true;
                    }
                    if (keyval == Gdk.Key.Down && focus.is_ancestor (search)) {
                        list.grab_focus ();
                        return true;
                    }
                    return false;
                }
                if (composing || stack.visible_child_name != "mail") return false;
                switch (keyval) {
                    case Gdk.Key.j:
                        move_selection (1);
                        return true;
                    case Gdk.Key.k:
                        move_selection (-1);
                        return true;
                    case Gdk.Key.s:
                        toggle_star ();
                        return true;
                    case Gdk.Key.m:
                        toggle_read ();
                        return true;
                    case Gdk.Key.p:
                        run_action ("pin");
                        return true;
                    case Gdk.Key.b:
                        snooze_choice (1);
                        return true;
                    case Gdk.Key.Insert:
                        toggle_star ();
                        return true;
                    case Gdk.Key.slash:
                        search.grab_focus_entry ();
                        return true;
                }
                return false;
            });
            ((Widget) this).add_controller (keys);
        }

        private void run_action (string name) {
            switch (name) {
                case "compose": compose_new (); break;
                case "edit-draft": edit_draft (); break;
                case "save-draft": save_draft.begin (false); break;
                case "open-file": open_file_dialog (); break;
                case "print": reader.print (this); break;
                case "print-conversation": reader.print_conversation (this); break;
                case "close": close (); break;
                case "undo": forward_edit ("text.undo", "Undo"); break;
                case "redo": forward_edit ("text.redo", "Redo"); break;
                case "cut": forward_edit ("clipboard.cut", WebKit.EDITING_COMMAND_CUT); break;
                case "copy": forward_edit ("clipboard.copy", WebKit.EDITING_COMMAND_COPY); break;
                case "paste": forward_edit ("clipboard.paste", WebKit.EDITING_COMMAND_PASTE); break;
                case "select-all":
                    if (!composing && stack.visible_child_name == "mail" && list.has_focus) selection.select_all ();
                    else forward_edit ("selection.select-all", WebKit.EDITING_COMMAND_SELECT_ALL);
                    break;
                case "find": search.grab_focus_entry (); break;
                case "unified": select_source ("unified"); break;
                case "sidebar": set_sidebar_visible (!get_sidebar_visible ()); break;
                case "load-images": reader.load_images (); sync_actions (); break;
                case "next": move_selection (1); break;
                case "previous": move_selection (-1); break;
                case "reply": reply (false); break;
                case "reply-all": reply (true); break;
                case "forward": forward (false); break;
                case "forward-attachment": forward (true); break;
                case "redirect": redirect (); break;
                case "edit-as-new": edit_as_new (); break;
                case "toggle-read": toggle_read (); break;
                case "toggle-star": toggle_star (); break;
                case "move": popup_menu (move_item, (m) => fill_move (m, false)); break;
                case "copy-to": popup_menu (null, (m) => fill_move (m, true)); break;
                case "archive": archive (); break;
                case "delete": delete_selected (); break;
                case "junk": junk (); break;
                case "not-junk": not_junk (); break;
                case "block-sender": block_sender (); break;
                case "add-account": add_account (); break;
                case "sync": sync_now (); break;
                case "edit-account": edit_account (current_account ()); break;
                case "pin": toggle_flag (MessageFlags.PINNED); break;
                case "flag-today": flag_due (0); break;
                case "flag-tomorrow": flag_due (1); break;
                case "flag-week": flag_due (2); break;
                case "flag-next-week": flag_due (3); break;
                case "flag-date": flag_due (4); break;
                case "flag-complete": flag_complete (); break;
                case "flag-clear": flag_clear (); break;
                case "rules": open_rules (null); break;
                case "new-rule": open_rules (reader.current ?? lead); break;
                case "run-rules": {
                    var f = source_folder ();
                    if (f != null) app.run_rules_now.begin (f);
                    break;
                }
                case "sweep": sweep (); break;
                case "view-source": view_source (); break;
                case "save-message": save_message (); break;
                case "open-window":
                    if (reader.current != null) open_in_window (reader.current);
                    break;
                case "translate": reader.translate_current.begin (); break;
                case "add-contact": add_contact (); break;
                case "add-task": add_task (); break;
                case "move-other": set_focus_class (0); break;
                case "move-focused": set_focus_class (1); break;
                case "unsubscribe":
                    if (reader.current != null) app.unsubscribe.begin (reader.current, this);
                    break;
                case "ignore": ignore_conversation (); break;
                case "import": import_mail (); break;
                case "export": export_mail (); break;
                case "mail-merge": mail_merge (); break;
                case "auto-reply": auto_reply (); break;
                case "open-shared": open_shared (); break;
                case "new-folder": new_folder (source_folder ()); break;
                case "zoom-in": reader.zoom = reader.zoom + 0.1; break;
                case "zoom-out": reader.zoom = reader.zoom - 0.1; break;
                case "zoom-reset": reader.zoom = 1.0; break;
                case "categories": {
                    var dlg = new CategoriesDialog (app);
                    dlg.transient_for = this;
                    dlg.open_dialog ();
                    break;
                }
                case "quick-steps": {
                    var dlg = new QuickStepsDialog (app);
                    dlg.transient_for = this;
                    dlg.open_dialog ();
                    break;
                }
                case "templates": {
                    var dlg = new TextItemsDialog (app, app.templates, _("Templates"), true);
                    dlg.transient_for = this;
                    dlg.open_dialog ();
                    break;
                }
                case "signatures": {
                    var dlg = new TextItemsDialog (app, app.signatures, _("Signatures"), false);
                    dlg.transient_for = this;
                    dlg.open_dialog ();
                    break;
                }
                case "new-from-template": new_from_template (); break;
                case "mark-all-read": mark_all_read (source_folder ()); break;
                case "empty-folder": empty_folder (source_folder ()); break;
                case "outbox": select_source ("outbox"); break;
                case "send-later": send_later (); break;
                case "read-aloud": read_aloud (); break;
                case "stop-reading": stop_reading (); break;
            }
        }

        private void forward_edit (string gtk_action, string? web_command) {
            var focus = get_focus ();
            if (focus == null) return;
            for (Widget? w = focus; w != null; w = w.get_parent ()) {
                var web = w as WebKit.WebView;
                if (web != null) {
                    if (web_command != null) web.execute_editing_command (web_command);
                    return;
                }
            }
            focus.activate_action (gtk_action, null);
        }

        private void set_enabled (string name, bool on) {
            var a = lookup_action (name) as SimpleAction;
            if (a != null) a.set_enabled (on);
        }

        private bool lead_in (string role) {
            if (reader.current == null) return false;
            var f = app.store.folder (reader.current.folder);
            return f != null && f.role == role;
        }

        private uint selected_count () {
            var bits = selection.get_selection ();
            return (uint) bits.get_size ();
        }

        private void sync_actions () {
            bool accounts = app.accounts.accounts.size > 0;
            bool mail = stack.visible_child_name == "mail" && !composing;
            bool multi = mail && selected_count () > 1;
            bool has_msg = mail && !file_view && ((reader.current != null && reader_stack.visible_child_name == "reader") || multi);
            bool one = has_msg && !multi;
            bool has_mime = one && reader.mime != null;
            bool viewing = mail && reader_stack.visible_child_name == "reader" && reader.mime != null;
            bool offline = app.settings.get_boolean ("work-offline");
            set_enabled ("compose", accounts && !composing);
            set_enabled ("edit-draft", has_mime && lead_in ("drafts"));
            set_enabled ("save-draft", composing);
            set_enabled ("print", viewing);
            set_enabled ("print-conversation", viewing);
            set_enabled ("find", accounts && mail);
            set_enabled ("unified", accounts && !composing);
            set_enabled ("folder", accounts && !composing);
            set_enabled ("sidebar", accounts && !composing);
            set_enabled ("next", mail && model.get_n_items () > 0);
            set_enabled ("previous", mail && model.get_n_items () > 0);
            foreach (string n in new string[] { "reply", "reply-all", "forward", "forward-attachment", "redirect", "edit-as-new", "view-source", "save-message", "open-window", "translate", "add-contact", "add-task", "new-rule", "sweep", "block-sender", "ignore" }) set_enabled (n, has_mime);
            foreach (string n in new string[] { "toggle-read", "toggle-star", "move", "copy-to", "delete", "pin", "flag-today", "flag-tomorrow", "flag-week", "flag-next-week", "flag-date", "flag-complete", "flag-clear", "move-other", "move-focused" }) set_enabled (n, has_msg);
            set_enabled ("archive", has_msg && !lead_in ("archive"));
            set_enabled ("junk", has_msg && !lead_in ("junk"));
            set_enabled ("not-junk", has_msg && lead_in ("junk"));
            set_enabled ("unsubscribe", one && reader.current != null && reader.current.list_unsubscribe != "");
            set_enabled ("load-images", viewing && reader.mime.has_remote_content () && !reader.images_loaded);
            set_enabled ("sync", accounts && !offline);
            set_enabled ("edit-account", accounts);
            set_enabled ("conversations", accounts);
            set_enabled ("offline", accounts);
            set_enabled ("run-rules", source_folder () != null);
            set_enabled ("mark-all-read", source_folder () != null);
            set_enabled ("empty-folder", source_folder () != null && (source_folder ().role == "trash" || source_folder ().role == "junk"));
            set_enabled ("new-folder", accounts);
            set_enabled ("send-later", composing);

            search.visible = mail && accounts;
            bool drafts = lead_in ("drafts");
            save_search_item.button.sensitive = mail && query != "" && !source.has_prefix ("search:");
            reply_item.widget.visible = !drafts;
            reply_all_item.widget.visible = !drafts;
            forward_item.widget.visible = !drafts;
            edit_draft_item.widget.visible = drafts;
            foreach (var item in new RibbonMenu[] { move_item, snooze_item, category_item, steps_item }) item.button.sensitive = has_msg;
            bool busy = false;
            foreach (var s in app.syncs.values) if (s.busy) busy = true;
            sync_item.button.sensitive = !busy;
            sync_item.label = busy ? _("Syncing…") : _("Sync Now");
            if (one && reader.current != null) {
                var m = reader.current;
                star_item.icon_name = m.flagged ? "starred-symbolic" : "non-starred-symbolic";
                star_item.label = m.flagged ? _("Remove Flag") : _("Flag");
                bool unread = lead != null && lead.thread_unread;
                read_item.icon_name = unread ? "mail-read-symbolic" : "mail-unread-symbolic";
                read_item.label = unread ? _("Mark as Read") : _("Mark as Unread");
                delete_item.label = lead_in ("trash") ? _("Delete Forever") : _("Delete");
            }
            mail_ribbon.tabs.visible = mail && accounts;
            compose_ribbon.tabs.visible = composing;
            var f = source_folder ();
            bool inbox = f != null ? f.role == "inbox" : source == "unified";
            focus_switch.visible = inbox && app.settings.get_boolean ("focused-inbox") && query == "";
            string filt = app.settings.get_string ("filter");
            filter_selector.selected = filt;
            sort_selector.selected = app.settings.get_string ("sort");
            sort_selector.icon_name = app.settings.get_boolean ("sort-ascending") ? "view-sort-ascending-symbolic" : "view-sort-descending-symbolic";
            filter_chip.visible = filt != "all";
            if (filter_chip.visible) ((Label) filter_chip.child.get_first_child ()).label = filter_selector.text;
            list_header.visible = mail && accounts && (focus_switch.visible || filter_chip.visible);
        }

        private void on_accounts_changed () {
            foreach (var old in watched.to_array ()) {
                if (app.syncs[old.account.id] != old) watched.remove (old);
            }
            foreach (var s in app.syncs.values) {
                if (watched.contains (s)) continue;
                watched.add (s);
                s.data_changed.connect (() => {
                    schedule_rebuild ();
                    update_counts ();
                    update_banner ();
                    sync_actions ();
                });
                s.notify["state"].connect (() => {
                    update_banner ();
                    sync_actions ();
                });
                s.notify["busy"].connect (() => {
                    sync_actions ();
                    update_empty ();
                });
            }
            bool has = app.accounts.accounts.size > 0;
            if (!has && !composing && !file_view) {
                stack.visible_child_name = "welcome";
            } else if (!composing) {
                stack.visible_child_name = "mail";
            }
            set_sidebar_visible (has && !composing);
            rebuild_sidebar ();
            rebuild_list ();
            update_banner ();
            sync_actions ();
        }

        private int folder_depth (Folder f) {
            if (f.parent == "") return f.depth;
            int d = 0;
            string p = f.parent;
            while (p != "" && d < 8) {
                var parent = app.store.folder_by_path (f.account, p);
                if (parent == null) break;
                d++;
                p = parent.parent;
            }
            return d;
        }

        private SidebarRow add_row (string id, string icon, string title, Folder? folder, int depth = 0) {
            var row = new SidebarRow (icon, title);
            var badge = new Label ("");
            badge.add_css_class ("lettere-badge");
            var inner = row.get_child () as Box;
            if (inner != null) inner.append (badge);
            if (depth > 0) row.margin_start = 14 * depth;
            row.clicked.connect (() => select_source (id));
            rows[id] = row;
            badges[id] = badge;
            if (folder != null) {
                int64 fid = folder.id;
                var drop = new DropTarget (typeof (string), Gdk.DragAction.MOVE | Gdk.DragAction.COPY);
                drop.enter.connect ((x, y) => {
                    row.add_css_class ("lettere-drop");
                    return Gdk.DragAction.MOVE;
                });
                drop.leave.connect (() => row.remove_css_class ("lettere-drop"));
                drop.drop.connect ((v, x, y) => {
                    row.remove_css_class ("lettere-drop");
                    string s = v.get_string ();
                    if (!s.has_prefix ("lettere-ids:")) return false;
                    var f = app.store.folder (fid);
                    if (f == null) return false;
                    var msgs = new Gee.ArrayList<MessageInfo> ();
                    foreach (string p in s.substring (12).split (",")) {
                        var m = app.store.message (int64.parse (p));
                        if (m != null && m.account == f.account) msgs.add (m);
                    }
                    if (msgs.size == 0) {
                        show_toast (_("Messages can only be moved within the same account"));
                        return false;
                    }
                    var mods = drop.get_current_event_state ();
                    if ((mods & Gdk.ModifierType.CONTROL_MASK) != 0) {
                        var s2 = app.syncs[f.account];
                        if (s2 != null) s2.copy.begin (msgs, f);
                        show_toast (ngettext ("Copied %d message to %s", "Copied %d messages to %s", msgs.size).printf (msgs.size, f.display_name));
                    } else {
                        do_move (msgs, f);
                    }
                    return true;
                });
                row.add_controller (drop);
                var click = new GestureClick ();
                click.button = 3;
                click.pressed.connect ((n, x, y) => {
                    click.set_state (EventSequenceState.CLAIMED);
                    var f = app.store.folder (fid);
                    if (f != null) folder_menu (row, f, x, y);
                });
                row.add_controller (click);
            }
            sidebar.box.append (row);
            return row;
        }

        private void folder_menu (Widget row, Folder f, double x, double y) {
            var menu = new ContextMenu (row);
            menu.add_item (_("New Subfolder…"), "folder-new-symbolic", () => new_folder (f));
            if (f.role == "") {
                menu.add_item (_("Rename…"), "document-edit-symbolic", () => rename_folder (f));
                menu.add_item (_("Delete Folder"), "user-trash-symbolic", () => delete_folder (f), "destructive");
            }
            menu.add_separator ();
            menu.add_item (f.favorite ? _("Remove from Favorites") : _("Add to Favorites"), "starred-symbolic", () => {
                app.store.set_favorite (f.id, !f.favorite);
                rebuild_sidebar ();
            });
            menu.add_item (_("Mark All as Read"), "mail-read-symbolic", () => mark_all_read (f));
            menu.add_item (_("Run Rules Now"), "system-run-symbolic", () => app.run_rules_now.begin (f));
            if (f.role == "trash" || f.role == "junk") menu.add_item (_("Empty Folder…"), "edit-clear-all-symbolic", () => empty_folder (f), "destructive");
            menu.add_item (_("Export…"), "document-save-symbolic", () => export_folder (f));
            menu.set_pointing_to ({ (int) x, (int) y, 1, 1 });
            menu.popup ();
        }

        private void rebuild_sidebar () {
            Widget? child;
            while ((child = sidebar.box.get_first_child ()) != null) sidebar.box.remove (child);
            rows.clear ();
            badges.clear ();
            bool many = app.accounts.accounts.size > 1;
            var favs = app.store.favorites ();
            var saved = SavedSearch.load (app.settings.get_strv ("saved-searches"));
            if (many || favs.size > 0 || saved.size > 0 || app.store.outbox ().size > 0) {
                sidebar.box.append (new SidebarSectionLabel (_("Favorites")));
                if (many) add_row ("unified", "mail-inbox-symbolic", _("All Inboxes"), null);
                add_row ("flagged", "starred-symbolic", _("Flagged"), null);
                foreach (var f in favs) {
                    var a = app.accounts.find (f.account);
                    string label = many && a != null ? "%s (%s)".printf (f.display_name, a.display_name) : f.display_name;
                    add_row ("folder:" + f.id.to_string (), f.icon_name, label, f);
                }
                foreach (var s in saved) {
                    var r = add_row ("search:" + s.name, "system-search-symbolic", s.name, null);
                    string sname = s.name;
                    var click = new GestureClick ();
                    click.button = 3;
                    click.pressed.connect ((n, x, y) => {
                        click.set_state (EventSequenceState.CLAIMED);
                        var menu = new ContextMenu (r);
                        menu.add_item (_("Remove Saved Search"), "user-trash-symbolic", () => remove_saved (sname), "destructive");
                        menu.set_pointing_to ({ (int) x, (int) y, 1, 1 });
                        menu.popup ();
                    });
                    r.add_controller (click);
                }
                if (app.store.outbox ().size > 0) add_row ("outbox", "document-open-recent-symbolic", _("Outbox"), null);
            }
            foreach (var a in app.accounts.accounts) {
                var label = new SidebarSectionLabel (a.display_name);
                var acc = a;
                var click = new GestureClick ();
                click.button = 3;
                click.pressed.connect ((n, x, y) => {
                    click.set_state (EventSequenceState.CLAIMED);
                    account_menu (label, acc, x, y);
                });
                label.add_controller (click);
                sidebar.box.append (label);
                var folders = app.store.folders (a.id);
                if (folders.size == 0) {
                    var s = app.syncs[a.id];
                    var hint = new Label (s != null && s.busy ? _("Getting folders…") : _("No folders yet"));
                    hint.xalign = 0;
                    hint.margin_start = 14;
                    hint.add_css_class ("dim-label");
                    hint.add_css_class ("caption");
                    sidebar.box.append (hint);
                }
                foreach (var f in ordered_tree (folders)) add_row ("folder:" + f.id.to_string (), f.icon_name, f.display_name, f, f.role == "" ? folder_depth (f) : 0);
            }
            if (!rows.has_key (source) && source != "outbox") {
                if (!many && app.accounts.accounts.size > 0) {
                    var inbox = app.store.folder_by_role (app.accounts.accounts[0].id, "inbox");
                    source = inbox != null ? "folder:" + inbox.id.to_string () : "unified";
                } else {
                    source = "unified";
                }
            }
            foreach (var e in rows.entries) e.value.set_active (e.key == source);
            update_counts ();
        }

        private Gee.ArrayList<Folder> ordered_tree (Gee.List<Folder> folders) {
            var outb = new Gee.ArrayList<Folder> ();
            var by_path = new Gee.HashMap<string, Folder> ();
            foreach (var f in folders) by_path[f.path] = f;
            var children = new Gee.HashMap<string, Gee.ArrayList<Folder>> ();
            var roots = new Gee.ArrayList<Folder> ();
            foreach (var f in folders) {
                string parent = f.parent;
                if (parent == "" && f.delimiter != "" && f.path.contains (f.delimiter) && f.role == "") parent = f.path.substring (0, f.path.last_index_of (f.delimiter));
                if (f.role != "" || parent == "" || !by_path.has_key (parent)) {
                    roots.add (f);
                    continue;
                }
                if (!children.has_key (parent)) children[parent] = new Gee.ArrayList<Folder> ();
                children[parent].add (f);
            }
            foreach (var r in roots) walk (r, children, outb);
            return outb;
        }

        private void walk (Folder f, Gee.Map<string, Gee.ArrayList<Folder>> children, Gee.List<Folder> outb) {
            outb.add (f);
            var kids = children[f.path];
            if (kids == null) return;
            kids.sort ((a, b) => a.display_name.collate (b.display_name));
            foreach (var k in kids) walk (k, children, outb);
        }

        private void account_menu (Widget label, Account acc, double x, double y) {
            var menu = new ContextMenu (label);
            menu.add_item (_("Account Settings"), "emblem-system-symbolic", () => edit_account (acc));
            menu.add_item (_("Sync Now"), "view-refresh-symbolic", () => {
                var s = app.syncs[acc.id];
                if (s != null) s.sync_all.begin ();
            });
            menu.add_item (_("New Folder…"), "folder-new-symbolic", () => new_folder_in (acc, null));
            var s = app.syncs[acc.id];
            if (s != null && s.backend.supports_auto_reply) menu.add_item (_("Automatic Replies…"), "mail-reply-sender-symbolic", () => auto_reply_for (acc));
            if (s != null && !s.backend.local_only) menu.add_item (_("Open Shared Mailbox…"), "folder-publicshare-symbolic", () => open_shared_for (acc));
            menu.add_item (_("Storage Used…"), "drive-harddisk-symbolic", () => show_quota.begin (acc));
            menu.add_item (_("Export to Outlook Data File…"), "document-save-symbolic", () => export_account (acc));
            menu.set_pointing_to ({ (int) x, (int) y, 1, 1 });
            menu.popup ();
        }

        private void update_counts () {
            int unified = 0;
            int flagged = 0;
            foreach (var a in app.accounts.accounts) {
                foreach (var f in app.store.folders (a.id)) {
                    int n = f.role == "drafts" ? f.total : (f.role == "sent" || f.role == "trash" || f.role == "junk" || f.role == "snoozed" ? 0 : f.unread);
                    set_badge ("folder:" + f.id.to_string (), n);
                    if (f.role == "inbox") unified += f.unread;
                }
            }
            var inboxes = new Gee.ArrayList<int64?> ();
            foreach (var a in app.accounts.accounts) {
                foreach (var f in app.store.folders (a.id)) if (f.role != "trash" && f.role != "junk") inboxes.add (f.id);
            }
            var o = new ListOptions ();
            o.filter = ListFilter.FLAGGED;
            flagged = app.store.list (inboxes, false, null, 3000, o).size;
            set_badge ("flagged", flagged);
            set_badge ("unified", unified);
            set_badge ("outbox", app.store.outbox ().size);
            string title = unified > 0 ? "Lettere (%d)".printf (unified) : "Lettere";
            set_title (title);
        }

        private void set_badge (string id, int count) {
            var b = badges[id];
            if (b == null) return;
            b.label = count > 9999 ? "9999+" : count.to_string ();
            b.visible = count > 0;
            var row = rows[id];
            if (row != null) row.update_property (AccessibleProperty.LABEL, count > 0 ? "%s, %s".printf (row.text, ngettext ("%d unread", "%d unread", count).printf (count)) : row.text, -1);
        }

        public void show_unified () {
            leave_compose ();
            select_source (app.accounts.accounts.size > 1 ? "unified" : source);
        }

        private void select_source (string id) {
            if (composing) return;
            file_view = false;
            source = id;
            if (!rows.has_key (source) && source == "unified" && app.accounts.accounts.size == 1) {
                var inbox = app.store.folder_by_role (app.accounts.accounts[0].id, "inbox");
                if (inbox != null) source = "folder:" + inbox.id.to_string ();
            }
            foreach (var e in rows.entries) e.value.set_active (e.key == source);
            stack.visible_child_name = app.accounts.accounts.size > 0 ? "mail" : "welcome";
            lead = null;
            server_hits = null;
            if (source.has_prefix ("search:")) {
                foreach (var s in SavedSearch.load (app.settings.get_strv ("saved-searches"))) {
                    if ("search:" + s.name == source) {
                        query = s.query;
                        search.text = s.query;
                    }
                }
            }
            show_none ();
            rebuild_list ();
            if (source.has_prefix ("folder:")) {
                var f = app.store.folder (int64.parse (source.substring (7)));
                if (f != null) {
                    var s = app.syncs[f.account];
                    if (s != null && s.online && f.role != "inbox") s.refresh_folder.begin (f);
                }
            }
        }

        private Gee.ArrayList<int64?> source_folders () {
            var ids = new Gee.ArrayList<int64?> ();
            if (source.has_prefix ("folder:")) {
                ids.add (int64.parse (source.substring (7)));
                return ids;
            }
            if (source == "flagged" || source.has_prefix ("search:")) {
                foreach (var a in app.accounts.accounts) {
                    foreach (var f in app.store.folders (a.id)) if (f.role != "trash" && f.role != "junk") ids.add (f.id);
                }
                return ids;
            }
            foreach (var a in app.accounts.accounts) {
                var f = app.store.folder_by_role (a.id, "inbox");
                if (f != null) ids.add (f.id);
            }
            return ids;
        }

        private Folder? source_folder () {
            if (!source.has_prefix ("folder:")) return null;
            return app.store.folder (int64.parse (source.substring (7)));
        }

        private bool threaded () {
            var f = source_folder ();
            if (f != null && f.role == "drafts") return false;
            if (source == "outbox" || source == "flagged") return false;
            return app.settings.get_boolean ("conversations");
        }

        private void schedule_rebuild () {
            if (rebuild_id != 0) return;
            rebuild_id = Timeout.add (120, () => {
                rebuild_id = 0;
                rebuild_list ();
                return Source.REMOVE;
            });
        }

        private string my_first_name () {
            var a = current_account ();
            if (a == null || a.full_name == "") return "";
            return a.full_name.split (" ")[0];
        }

        private ListOptions list_options () {
            var o = new ListOptions ();
            o.sort = SortKey.from_id (app.settings.get_string ("sort"));
            o.ascending = app.settings.get_boolean ("sort-ascending");
            o.filter = ListFilter.from_id (app.settings.get_string ("filter"));
            o.mention = my_first_name ();
            if (source == "flagged") o.filter = ListFilter.FLAGGED;
            var f = source_folder ();
            bool inbox = f != null ? f.role == "inbox" : source == "unified";
            if (inbox && app.settings.get_boolean ("focused-inbox") && o.filter == ListFilter.ALL && query == "") {
                o.filter = app.settings.get_string ("focus-view") == "other" ? ListFilter.OTHER : ListFilter.FOCUSED;
            }
            return o;
        }

        private Gee.ArrayList<MessageInfo> outbox_items () {
            var items = new Gee.ArrayList<MessageInfo> ();
            foreach (var o in app.store.outbox ()) {
                var m = new MessageInfo ();
                m.id = -o.id;
                m.account = o.account;
                var mime = new MimeMessage (o.raw);
                m.subject = mime.subject;
                m.to_list = Mime.format_addresses (mime.to);
                m.date = o.send_at;
                m.flags = MessageFlags.SEEN;
                m.preview = o.error != "" ? _("Not sent: %s").printf (o.error) : _("Sends %s").printf (format_full (o.send_at));
                items.add (m);
            }
            return items;
        }

        private void rebuild_list () {
            if (model == null) return;
            var folders = source_folders ();
            Gee.ArrayList<MessageInfo> items;
            if (source == "outbox") {
                items = outbox_items ();
            } else if (query != "") {
                var q = SearchQuery.parse (query);
                Gee.Collection<int64?>? scope = q.all_folders || q.folder_name != "" ? null : folders;
                items = app.store.query (q, scope, server_hits);
                if (items.size == 0 && server_hits == null) search_server.begin (q);
            } else {
                items = app.store.list (folders, threaded (), null, 3000, list_options ());
            }
            rebuilding = true;
            var keep_ids = new Gee.HashSet<int64?> ((v) => int64_hash (v), (a, b) => a == b);
            var bits = selection.get_selection ();
            for (uint i = 0; i < bits.get_size (); i++) {
                var m = model.get_item (bits.get_nth (i)) as MessageInfo;
                if (m != null) keep_ids.add (m.id);
            }
            string keep_thread = lead != null ? lead.thread : "";
            string keep_account = lead != null ? lead.account : "";
            var arr = new Object[items.size];
            for (int i = 0; i < items.size; i++) arr[i] = items[i];
            model.splice (0, model.get_n_items (), arr);
            var sel = new Gtk.Bitset.empty ();
            int lead_pos = -1;
            for (int i = 0; i < items.size; i++) {
                bool match = keep_ids.contains (items[i].id) || (keep_ids.size <= 1 && keep_thread != "" && threaded () && query == "" && items[i].thread == keep_thread && items[i].account == keep_account);
                if (match) {
                    sel.add (i);
                    if (lead != null && (items[i].id == lead.id || items[i].thread == keep_thread)) lead_pos = i;
                }
            }
            selection.set_selection (sel, new Gtk.Bitset.range (0, model.get_n_items ()));
            if (lead_pos >= 0) lead = items[lead_pos];
            rebuilding = false;
            if (sel.get_size () == 0 && lead != null && !file_view) {
                lead = null;
                show_none ();
            }
            update_empty ();
            sync_actions ();
        }

        private async void search_server (SearchQuery q) {
            string original = query;
            var f = source_folder ();
            var hits = new Gee.ArrayList<int64?> ();
            var targets = new Gee.ArrayList<Folder> ();
            if (f != null && !q.all_folders) {
                targets.add (f);
            } else {
                foreach (var a in app.accounts.accounts) {
                    var inbox = app.store.folder_by_role (a.id, "inbox");
                    if (inbox != null) targets.add (inbox);
                    if (q.all_folders) {
                        var arch = app.store.folder_by_role (a.id, "archive");
                        if (arch != null) targets.add (arch);
                    }
                }
            }
            foreach (var t in targets) {
                var s = app.syncs[t.account];
                if (s == null || !s.online) continue;
                try {
                    hits.add_all (yield s.search_server (t, q));
                } catch (Error e) {
                }
                if (original != query) return;
            }
            server_hits = hits;
            if (hits.size > 0) rebuild_list ();
        }

        private void save_search () {
            if (query == "") return;
            var dlg = new ConfirmDialog (app, _("Save Search"), null, _("The search appears under Favorites and updates by itself."), _("Save"), ConfirmDialog.ActionStyle.SUGGESTED);
            dlg.transient_for = this;
            dlg.modal = true;
            var group = new PreferencesGroup ();
            var name = new EntryRow (_("Name"));
            name.text = query;
            group.add_row (name);
            dlg.custom_area.append (group);
            dlg.response.connect ((r) => {
                if (r != ConfirmDialog.Response.PRIMARY || name.text.strip () == "") return;
                string[] list = app.settings.get_strv ("saved-searches");
                list += new SavedSearch (name.text.strip (), query).to_entry ();
                app.settings.set_strv ("saved-searches", list);
                show_toast (_("Search saved in Favorites"));
            });
            dlg.open_dialog ();
        }

        private void remove_saved (string name) {
            string[] keep = {};
            foreach (var s in SavedSearch.load (app.settings.get_strv ("saved-searches"))) if (s.name != name) keep += s.to_entry ();
            app.settings.set_strv ("saved-searches", keep);
            if (source == "search:" + name) select_source ("unified");
        }

        private void update_empty () {
            if (model.get_n_items () > 0) {
                list_stack.visible_child_name = "list";
                if (reader_stack.visible_child_name == "blank") reader_stack.visible_child_name = "none";
                return;
            }
            if (reader_stack.visible_child_name == "none") reader_stack.visible_child_name = "blank";
            bool busy = false;
            foreach (var s in app.syncs.values) if (s.busy) busy = true;
            var f = source_folder ();
            string key = query != "" ? "q:" + query : busy ? "busy" : f != null ? "f:%s:%s".printf (f.id.to_string (), f.display_name) : "none:" + source + app.settings.get_string ("filter");
            if (key != empty_key || list_empty.get_first_child () == null) {
                empty_key = key;
                var old = list_empty.get_first_child ();
                if (old != null) list_empty.remove (old);
                list_empty.append (build_empty (f, busy));
            }
            list_stack.visible_child_name = "empty";
        }

        private Widget build_empty (Folder? f, bool busy) {
            if (query != "") {
                var page = new StatusPage ();
                page.icon_name = "system-search";
                page.title = _("No Results");
                page.description = _("No message matches “%s”. Lettere searched the mail saved on this computer and, when online, the server. Add in:all to search every folder.").printf (query);
                var clear = new Button.with_label (_("Clear Search"));
                clear.add_css_class ("pill");
                clear.add_css_class ("suggested-action");
                clear.halign = Align.CENTER;
                clear.clicked.connect (() => search.clear ());
                page.child = clear;
                return page;
            }
            if (app.settings.get_string ("filter") != "all") {
                var page = new StatusPage ();
                page.icon_name = "view-reveal-symbolic";
                page.title = _("Nothing Matches the Filter");
                var clear = new Button.with_label (_("Show All Messages"));
                clear.add_css_class ("pill");
                clear.halign = Align.CENTER;
                clear.clicked.connect (() => app.settings.set_string ("filter", "all"));
                page.child = clear;
                return page;
            }
            if (busy) {
                var page = new StatusPage ();
                page.icon_name = "dev.sinty.lettere";
                page.title = _("Getting Your Mail");
                page.description = _("New messages appear here as soon as they arrive.");
                var spinner = new Spinner ();
                spinner.set_size_request (24, 24);
                spinner.spinning = true;
                page.child = spinner;
                return page;
            }
            var wp = new WelcomePage ();
            wp.is_section = true;
            wp.vexpand = true;
            wp.app_icon_name = "dev.sinty.lettere";
            if (f != null) {
                wp.title = _("%s Is Empty").printf (f.display_name);
                wp.subtitle = f.role == "inbox" ? _("New messages will appear here.") : _("There are no messages in this folder.");
            } else if (source == "outbox") {
                wp.title = _("Nothing to Send");
                wp.subtitle = _("Messages you schedule for later wait here.");
            } else {
                wp.title = _("No Messages");
                wp.subtitle = _("New messages will appear here.");
            }
            wp.add_action ("document-new", _("New Message"), _("Write to someone"), () => compose_new ());
            wp.add_action ("emblem-synchronizing", _("Sync Now"), _("Check every account for new mail"), () => sync_now ());
            if (f != null && f.role != "inbox") {
                var inbox = app.store.folder_by_role (f.account, "inbox");
                if (inbox != null) {
                    empty_inbox = "folder:" + inbox.id.to_string ();
                    wp.add_action ("folder-download", _("Inbox"), _("Go back to your incoming mail"), () => select_source (empty_inbox));
                }
            }
            return wp;
        }

        private void update_banner () {
            AccountSync? worst = null;
            int worst_rank = 0;
            foreach (var s in app.syncs.values) {
                int r = 0;
                switch (s.state) {
                    case SyncState.AUTH_FAILED: r = 6; break;
                    case SyncState.TLS_ERROR: r = 5; break;
                    case SyncState.SERVER_ERROR: r = 4; break;
                    case SyncState.OFFLINE: r = 3; break;
                    case SyncState.WORKING_OFFLINE: r = 2; break;
                }
                if (r > worst_rank) {
                    worst_rank = r;
                    worst = s;
                }
            }
            banner.set_data<string> ("account", worst != null ? worst.account.id : "");
            if (worst == null) {
                banner.visible = false;
                return;
            }
            string who = worst.account.email;
            switch (worst.state) {
                case SyncState.AUTH_FAILED:
                    if (worst.account.managed) show_banner ("dialog-password-symbolic", _("Sign in again in Settings to keep using %s.").printf (who), _("Open Settings"), null, true);
                    else show_banner ("dialog-password-symbolic", _("The server refused the password for %s.").printf (who), _("Update Password"), null, true);
                    break;
                case SyncState.TLS_ERROR:
                    string text = worst.error_text;
                    if (worst.trust != null) text = _("The certificate of %s is not trusted because %s.").printf (worst.trust.host, worst.trust.problem);
                    show_banner ("security-low-symbolic", text, worst.trust != null ? _("Trust") : null, _("Settings"), true);
                    break;
                case SyncState.SERVER_ERROR:
                    show_banner ("dialog-warning-symbolic", _("%s: the server reported an error. %s").printf (who, worst.error_text), _("Retry"), null, true);
                    break;
                case SyncState.OFFLINE:
                    show_banner ("network-offline-symbolic", _("Cannot reach the server for %s. Showing the mail saved on this computer.").printf (who), _("Retry"), null, false);
                    break;
                case SyncState.WORKING_OFFLINE:
                    show_banner ("network-offline-symbolic", _("Working offline. Changes are sent to the server when you go back online."), _("Go Online"), null, false);
                    break;
            }
        }

        private void show_banner (string icon, string text, string? action_label, string? secondary_label, bool error) {
            banner.icon_name = icon;
            banner.title = text;
            banner.button_label = action_label;
            banner.secondary_label = secondary_label;
            banner.style = error ? BannerStyle.ERROR : BannerStyle.INFO;
            banner.visible = true;
        }

        public void show_toast (string text, string? action_label = null, owned LettereApp.ToastAction? cb = null, uint seconds = 5) {
            if (last_toast != null) last_toast.dismiss ();
            var toast = new Singularity.Widgets.Toast (text);
            toast.button_label = action_label;
            toast.timeout = seconds;
            if (cb != null) {
                LettereApp.ToastAction action = (owned) cb;
                toast.button_clicked.connect (() => action ());
            }
            last_toast = toast;
            add_toast (toast);
        }

        private AccountSync? banner_sync () {
            string id = banner.get_data<string> ("account") ?? "";
            return app.syncs[id];
        }

        private void on_banner_action () {
            var s = banner_sync ();
            if (s == null) return;
            switch (s.state) {
                case SyncState.AUTH_FAILED:
                    if (s.account.managed) OnlineMail.open_settings ();
                    else edit_account (s.account);
                    break;
                case SyncState.TLS_ERROR:
                    s.trust_certificate ();
                    app.accounts.save ();
                    s.sync_all.begin ();
                    break;
                case SyncState.WORKING_OFFLINE:
                    app.settings.set_boolean ("work-offline", false);
                    break;
                default:
                    s.go_online ();
                    break;
            }
            update_banner ();
        }

        private void on_banner_secondary () {
            var s = banner_sync ();
            if (s != null) edit_account (s.account);
        }

        private void show_none () {
            reader.clear ();
            reader_stack.visible_child_name = model.get_n_items () > 0 ? "none" : "blank";
            sync_actions ();
        }

        private void on_selection () {
            uint n = selected_count ();
            if (n == 0) {
                lead = null;
                show_none ();
                return;
            }
            if (source == "outbox") {
                var m = (MessageInfo) model.get_item (selection.get_selection ().get_nth (0));
                show_outbox (-m.id);
                return;
            }
            if (n > 1) {
                var bits = selection.get_selection ();
                lead = (MessageInfo) model.get_item (bits.get_nth (0));
                multi_page.title = ngettext ("%u Message Selected", "%u Messages Selected", n).printf (n);
                reader.clear ();
                reader_stack.visible_child_name = "multi";
                sync_actions ();
                return;
            }
            open_lead ((MessageInfo) model.get_item (selection.get_selection ().get_nth (0)));
        }

        private void show_outbox (int64 id) {
            outbox_selected = id;
            foreach (var o in app.store.outbox ()) {
                if (o.id != id) continue;
                var mime = new MimeMessage (o.raw);
                outbox_title.label = mime.subject != "" ? mime.subject : _("(No Subject)");
                string detail = _("To: %s").printf (Mime.display_addresses (mime.to)) + "\n" + _("Sends %s").printf (format_full (o.send_at));
                if (o.error != "") detail += "\n" + _("Last attempt failed: %s").printf (o.error);
                outbox_detail.label = detail;
            }
            reader_stack.visible_child_name = "outbox";
            sync_actions ();
        }

        private void outbox_action (string what) {
            OutboxItem? item = null;
            foreach (var o in app.store.outbox ()) if (o.id == outbox_selected) item = o;
            if (item == null) return;
            switch (what) {
                case "send":
                    app.store.set_outbox_time (item.id, 0);
                    app.outbox_changed ();
                    show_toast (_("Sending…"));
                    break;
                case "cancel":
                    if (app.cancel_outbox (item.id)) show_toast (_("The message will not be sent"));
                    break;
                case "time": {
                    var dlg = new WhenDialog (app, _("Send At"), item.send_at, _("Change"));
                    dlg.transient_for = this;
                    int64 oid = item.id;
                    dlg.chosen.connect ((t) => {
                        app.store.set_outbox_time (oid, t);
                        app.outbox_changed ();
                    });
                    dlg.open_dialog ();
                    break;
                }
                case "edit": {
                    var a = app.accounts.find (item.account);
                    if (a == null || !app.cancel_outbox (item.id)) return;
                    composer.start_draft (a, null, new MimeMessage (item.raw));
                    enter_compose ();
                    composer.mark_modified ();
                    break;
                }
            }
            show_none ();
        }

        private void open_lead (MessageInfo m) {
            lead = m;
            file_view = false;
            var s = app.syncs[m.account];
            Gee.List<MessageInfo> conv;
            var f = app.store.folder (m.folder);
            bool trashy = f != null && (f.role == "trash" || f.role == "junk");
            if (threaded () && query == "" && m.thread_count > 1) {
                conv = app.store.conversation (m.account, m.thread, trashy);
                if (conv.size == 0) conv.add (m);
            } else {
                conv = new Gee.ArrayList<MessageInfo> ();
                conv.add (m);
            }
            MessageInfo focus = conv[conv.size - 1];
            foreach (var c in conv) {
                if (c.unread) {
                    focus = c;
                    break;
                }
            }
            reader_stack.visible_child_name = "reader";
            reader.show_conversation (conv, focus, s);
            sync_actions ();
        }

        private void on_message_shown (MessageInfo m) {
            sync_actions ();
            if (!m.unread) return;
            var s = app.syncs[m.account];
            if (s == null) return;
            int delay = app.settings.get_int ("mark-read-delay");
            int64 id = m.id;
            Timeout.add (int.max (0, delay) * 1000 + 1, () => {
                if (reader.current == null || reader.current.id != id) return Source.REMOVE;
                var one = new Gee.ArrayList<MessageInfo> ();
                one.add (m);
                s.set_flag.begin (one, MessageFlags.SEEN, true);
                return Source.REMOVE;
            });
        }

        private void on_reader_action (string action, MessageInfo m) {
            switch (action) {
                case "reply": reply (false); break;
                case "reply-all": reply (true); break;
                case "forward": forward (false); break;
                case "translate": reader.show_translation (m); break;
                case "unsubscribe": app.unsubscribe.begin (m, this); break;
                case "receipt-send":
                    app.send_receipt (m);
                    show_toast (_("A read receipt was sent"));
                    break;
                case "receipt-ignore": app.ignore_receipt (m); break;
                case "add-contact":
                    add_contact ();
                    reader.refresh ();
                    break;
            }
        }

        public void show_message_id (int64 id) {
            leave_compose ();
            var m = app.store.message (id);
            if (m == null) return;
            select_source ("folder:" + m.folder.to_string ());
            for (uint i = 0; i < model.get_n_items (); i++) {
                var x = (MessageInfo) model.get_item (i);
                if (x.id == id || (x.thread == m.thread && x.account == m.account)) {
                    selection.select_item (i, true);
                    list.scroll_to (i, ListScrollFlags.FOCUS, null);
                    return;
                }
            }
        }

        private void move_selection (int delta) {
            uint n = model.get_n_items ();
            if (n == 0) return;
            var bits = selection.get_selection ();
            int pos = bits.get_size () == 0 ? -1 : (int) (delta > 0 ? bits.get_maximum () : bits.get_minimum ());
            int next = pos < 0 ? 0 : pos + delta;
            if (next < 0 || next >= n) return;
            selection.select_item (next, true);
            list.scroll_to (next, ListScrollFlags.FOCUS, null);
        }

        private string ids_string (Gee.List<MessageInfo> list) {
            var parts = new Gee.ArrayList<string> ();
            foreach (var m in list) parts.add (m.id.to_string ());
            return string.joinv (",", parts.to_array ());
        }

        private Gee.ArrayList<MessageInfo> target_messages (MessageInfo m) {
            var list = new Gee.ArrayList<MessageInfo> ();
            if (threaded () && query == "" && m.thread_count > 1) {
                var folders = source_folders ();
                foreach (var c in app.store.conversation (m.account, m.thread, true)) {
                    if (folders.contains (c.folder)) list.add (c);
                }
            }
            if (list.size == 0) list.add (m);
            return list;
        }

        private Gee.ArrayList<MessageInfo> selected_targets () {
            var outb = new Gee.ArrayList<MessageInfo> ();
            if (source == "outbox") return outb;
            var bits = selection.get_selection ();
            var seen = new Gee.HashSet<int64?> ((v) => int64_hash (v), (a, b) => a == b);
            for (uint i = 0; i < bits.get_size (); i++) {
                var m = model.get_item (bits.get_nth (i)) as MessageInfo;
                if (m == null) continue;
                foreach (var t in target_messages (m)) if (seen.add (t.id)) outb.add (t);
            }
            if (outb.size == 0 && lead != null) outb.add_all (target_messages (lead));
            return outb;
        }

        private Gee.HashMap<string, Gee.ArrayList<MessageInfo>> by_account (Gee.List<MessageInfo> list) {
            var map = new Gee.HashMap<string, Gee.ArrayList<MessageInfo>> ();
            foreach (var m in list) {
                if (!map.has_key (m.account)) map[m.account] = new Gee.ArrayList<MessageInfo> ();
                map[m.account].add (m);
            }
            return map;
        }

        private void row_menu (Widget row, double x, double y) {
            var menu = new ContextMenu (row);
            bool multi = selected_count () > 1;
            if (!multi) {
                menu.add_item (_("Reply"), "mail-reply-sender-symbolic", () => reply (false));
                menu.add_item (_("Reply All"), "mail-reply-all-symbolic", () => reply (true));
                menu.add_item (_("Forward"), "mail-forward-symbolic", () => forward (false));
                menu.add_item (_("Open in New Window"), "window-new-symbolic", () => {
                    if (lead != null) open_in_window (lead);
                });
                menu.add_separator ();
            }
            menu.add_item (lead != null && lead.thread_unread ? _("Mark as Read") : _("Mark as Unread"), "mail-unread-symbolic", () => toggle_read ());
            var flag = menu.add_submenu (_("Follow Up"), "starred-symbolic");
            flag.add_item (_("Today"), null, () => flag_due (0));
            flag.add_item (_("Tomorrow"), null, () => flag_due (1));
            flag.add_item (_("This Week"), null, () => flag_due (2));
            flag.add_item (_("Next Week"), null, () => flag_due (3));
            flag.add_item (_("Choose a Date…"), null, () => flag_due (4));
            flag.add_item (_("Mark Complete"), null, () => flag_complete ());
            flag.add_item (_("Clear Flag"), null, () => flag_clear ());
            menu.add_item (_("Pin"), "view-pin-symbolic", () => toggle_flag (MessageFlags.PINNED));
            var snooze = menu.add_submenu (_("Snooze"), "alarm-symbolic");
            string[] labels = { _("Later Today"), _("Tomorrow"), _("This Weekend"), _("Next Week"), _("Choose a Date…") };
            for (int i = 0; i < labels.length; i++) {
                int idx = i;
                snooze.add_item (labels[i], null, () => snooze_choice (idx));
            }
            var cats = menu.add_submenu (_("Categorize"), "bookmark-new-symbolic");
            foreach (var c in app.categories.items) {
                string name = c.name;
                cats.add_item (name, null, () => {
                    bool all = true;
                    foreach (var m in selected_targets ()) if (!m.has_category (name)) all = false;
                    set_category (name, !all);
                });
            }
            menu.add_item (_("Archive"), "mail-archive-symbolic", () => archive ());
            menu.add_item (_("Move To…"), "folder-symbolic", () => run_action ("move"));
            menu.add_item (_("Copy To…"), "edit-copy-symbolic", () => run_action ("copy-to"));
            if (!multi) {
                var more = menu.add_submenu (_("More"), "view-more-horizontal-symbolic");
                more.add_item (_("Forward as Attachment"), null, () => forward (true));
                more.add_item (_("Redirect…"), null, () => redirect ());
                more.add_item (_("Edit as New Message"), null, () => edit_as_new ());
                more.add_item (_("Create Rule…"), null, () => open_rules (lead));
                more.add_item (_("Sweep…"), null, () => sweep ());
                more.add_item (_("Ignore Conversation"), null, () => ignore_conversation ());
                more.add_item (_("Add Sender to Contacts"), null, () => add_contact ());
                more.add_item (_("Add to Tasks"), null, () => add_task ());
                more.add_item (_("Move to Other"), null, () => set_focus_class (0));
                more.add_item (_("Move to Focused"), null, () => set_focus_class (1));
                more.add_item (_("Block Sender"), null, () => block_sender ());
                more.add_item (_("Save as File…"), null, () => save_message ());
                more.add_item (_("View Source"), null, () => view_source ());
            }
            menu.add_separator ();
            menu.add_item (_("Spam"), "mail-mark-junk-symbolic", () => junk ());
            menu.add_item (_("Delete"), "user-trash-symbolic", () => delete_selected (), "destructive");
            menu.set_pointing_to ({ (int) x, (int) y, 1, 1 });
            menu.popup ();
        }

        private Account? current_account () {
            if (lead != null) return app.accounts.find (lead.account);
            var f = source_folder ();
            if (f != null) return app.accounts.find (f.account);
            foreach (var a in app.accounts.accounts) if (a.protocol != "local") return a;
            return app.accounts.accounts.size > 0 ? app.accounts.accounts[0] : null;
        }

        private void toggle_read () {
            var targets = selected_targets ();
            if (targets.size == 0) return;
            bool mark_read = false;
            foreach (var m in targets) if (m.unread) mark_read = true;
            if (!mark_read && selected_count () <= 1 && reader.current != null) {
                targets = new Gee.ArrayList<MessageInfo> ();
                targets.add (reader.current);
            }
            foreach (var e in by_account (targets).entries) {
                var s = app.syncs[e.key];
                if (s != null) s.set_flag.begin (e.value, MessageFlags.SEEN, mark_read);
            }
            if (lead != null) lead.thread_unread = !mark_read;
            sync_actions ();
        }

        private void toggle_star () {
            var targets = selected_count () > 1 ? selected_targets () : new Gee.ArrayList<MessageInfo> ();
            if (targets.size == 0 && reader.current != null) targets.add (reader.current);
            if (targets.size == 0) return;
            bool on = !targets[0].flagged;
            foreach (var e in by_account (targets).entries) {
                var s = app.syncs[e.key];
                if (s != null) s.set_flag.begin (e.value, MessageFlags.FLAGGED, on);
            }
            sync_actions ();
        }

        private void toggle_flag (int flag) {
            var targets = selected_targets ();
            if (targets.size == 0) return;
            bool on = (targets[0].flags & flag) == 0;
            foreach (var e in by_account (targets).entries) {
                var s = app.syncs[e.key];
                if (s != null) s.set_flag.begin (e.value, flag, on);
            }
            if (flag == MessageFlags.PINNED) show_toast (on ? _("Pinned to the top") : _("Unpinned"));
        }

        private void flag_due (int preset) {
            var targets = selected_count () > 1 ? selected_targets () : new Gee.ArrayList<MessageInfo> ();
            if (targets.size == 0 && reader.current != null) targets.add (reader.current);
            if (targets.size == 0) return;
            if (preset == 4) {
                var dlg = new WhenDialog (app, _("Follow Up By"), preset_time (1), _("Flag"));
                dlg.transient_for = this;
                dlg.chosen.connect ((t) => apply_due (targets, t));
                dlg.open_dialog ();
                return;
            }
            var now = new DateTime.now_local ();
            var end_today = new DateTime.local (now.get_year (), now.get_month (), now.get_day_of_month (), 17, 0, 0);
            int64 due;
            switch (preset) {
                case 0: due = end_today.to_unix (); break;
                case 1: due = end_today.add_days (1).to_unix (); break;
                case 2: due = end_today.add_days (int.max (0, 5 - now.get_day_of_week ())).to_unix (); break;
                default: due = end_today.add_days (8 - now.get_day_of_week ()).to_unix (); break;
            }
            apply_due (targets, due);
        }

        private void apply_due (Gee.List<MessageInfo> targets, int64 due) {
            foreach (var m in targets) {
                app.store.set_due (m.id, due);
                m.due = due;
            }
            foreach (var e in by_account (targets).entries) {
                var s = app.syncs[e.key];
                if (s == null) continue;
                s.set_flag.begin (e.value, MessageFlags.COMPLETED, false);
                s.set_flag.begin (e.value, MessageFlags.FLAGGED, true);
            }
            show_toast (_("Flagged for follow-up by %s").printf (format_full (due)), _("Add to Tasks"), () => {
                foreach (var m in targets) TasksBridge.add (_("Follow up: %s").printf (m.subject), due);
            });
            reader_refresh_chips ();
        }

        private void flag_complete () {
            var targets = selected_count () > 1 ? selected_targets () : new Gee.ArrayList<MessageInfo> ();
            if (targets.size == 0 && reader.current != null) targets.add (reader.current);
            foreach (var e in by_account (targets).entries) {
                var s = app.syncs[e.key];
                if (s != null) s.set_flag.begin (e.value, MessageFlags.COMPLETED, true);
            }
            reader_refresh_chips ();
        }

        private void flag_clear () {
            var targets = selected_count () > 1 ? selected_targets () : new Gee.ArrayList<MessageInfo> ();
            if (targets.size == 0 && reader.current != null) targets.add (reader.current);
            foreach (var m in targets) app.store.set_due (m.id, 0);
            foreach (var e in by_account (targets).entries) {
                var s = app.syncs[e.key];
                if (s == null) continue;
                s.set_flag.begin (e.value, MessageFlags.FLAGGED, false);
                s.set_flag.begin (e.value, MessageFlags.COMPLETED, false);
            }
            reader_refresh_chips ();
        }

        private void do_move (Gee.List<MessageInfo> msgs, Folder dest) {
            var s = app.syncs[dest.account];
            if (s == null || msgs.size == 0) return;
            bool current_moved = false;
            var origins = new Gee.HashMap<int64?, int64?> ((v) => int64_hash (v), (a, b) => a == b);
            foreach (var m in msgs) {
                origins[m.id] = m.folder;
                if (lead != null && (m.id == lead.id || (m.account == lead.account && m.thread == lead.thread && threaded ()))) current_moved = true;
            }
            if (current_moved || selected_count () > 1) advance_after_removal ();
            var moved = new Gee.ArrayList<string> ();
            foreach (var m in msgs) moved.add (m.message_id);
            var origin = app.store.folder (msgs[0].folder);
            s.move.begin (msgs, dest);
            show_toast (ngettext ("Moved %d message to %s", "Moved %d messages to %s", msgs.size).printf (msgs.size, dest.display_name), _("Undo"), () => {
                if (origin == null) return;
                var back = new Gee.ArrayList<MessageInfo> ();
                foreach (var m in app.store.folder_messages (dest.id)) if (m.message_id != "" && moved.contains (m.message_id)) back.add (m);
                if (back.size > 0) s.move.begin (back, origin);
            });
        }

        private void advance_after_removal () {
            var bits = selection.get_selection ();
            uint n = model.get_n_items ();
            if (bits.get_size () == 0 || n <= bits.get_size ()) {
                lead = null;
                show_none ();
                return;
            }
            uint last = bits.get_maximum ();
            uint first = bits.get_minimum ();
            uint next = last + 1 < n ? last + 1 : (first > 0 ? first - 1 : 0);
            var m = (MessageInfo) model.get_item (next);
            rebuilding = true;
            selection.select_item (next, true);
            rebuilding = false;
            open_lead (m);
        }

        private void move_to (Folder f) {
            var targets = selected_targets ();
            if (targets.size == 0) return;
            do_move (targets, f);
        }

        private void copy_to (Folder f) {
            var targets = selected_targets ();
            if (targets.size == 0) return;
            var s = app.syncs[f.account];
            if (s == null) return;
            s.copy.begin (targets, f);
            show_toast (ngettext ("Copied %d message to %s", "Copied %d messages to %s", targets.size).printf (targets.size, f.display_name));
        }

        private void with_role_folder (string role, string name, owned FolderCallback cb) {
            var targets = selected_targets ();
            if (targets.size == 0) return;
            foreach (var e in by_account (targets).entries) {
                var s = app.syncs[e.key];
                if (s == null) continue;
                var list = e.value;
                s.ensure_folder.begin (role, name, (o, res) => {
                    var f = s.ensure_folder.end (res);
                    if (f == null) {
                        show_toast (_("There is no %s folder and Lettere could not create one while offline").printf (name));
                        return;
                    }
                    cb (list, f);
                });
            }
        }

        private delegate void FolderCallback (Gee.List<MessageInfo> list, Folder f);

        private void archive () {
            with_role_folder ("archive", "Archive", (list, f) => {
                do_move (list, f);
                app.store.folders_changed (f.account);
            });
        }

        private void junk () {
            with_role_folder ("junk", "Junk", (list, f) => {
                foreach (var m in list) app.junk.train (m, body_text_of (m), true);
                var s = app.syncs[f.account];
                if (s != null) s.set_flag.begin (list, MessageFlags.JUNK, true);
                do_move (list, f);
            });
        }

        private string body_text_of (MessageInfo m) {
            var raw = app.store.body (m.id);
            return raw != null ? new MimeMessage (raw).body_text () : m.preview;
        }

        private void not_junk () {
            with_role_folder ("inbox", "INBOX", (list, f) => {
                foreach (var m in list) {
                    app.junk.untrain (m, body_text_of (m), true);
                    app.junk.train (m, body_text_of (m), false);
                }
                var s = app.syncs[f.account];
                if (s != null) {
                    s.set_flag.begin (list, MessageFlags.JUNK, false);
                    s.set_flag.begin (list, MessageFlags.NOT_JUNK, true);
                }
                do_move (list, f);
            });
        }

        private void block_sender () {
            var m = reader.current ?? lead;
            if (m == null || m.sender_email == "") return;
            string email = m.sender_email;
            var dlg = new ConfirmDialog (app, _("Block %s?").printf (email), null, _("New messages from this address go straight to Junk. Messages already here are moved there too."), _("Block"), ConfirmDialog.ActionStyle.DESTRUCTIVE);
            dlg.transient_for = this;
            dlg.modal = true;
            dlg.response.connect ((r) => {
                if (r != ConfirmDialog.Response.PRIMARY) return;
                app.block_sender (email);
                var f = app.store.folder (m.folder);
                var s = app.syncs[m.account];
                if (f == null || s == null) return;
                var list = app.store.by_sender (m.account, f.id, email);
                s.ensure_folder.begin ("junk", "Junk", (o, res) => {
                    var junkf = s.ensure_folder.end (res);
                    if (junkf != null && list.size > 0) do_move (list, junkf);
                });
                show_toast (_("%s is blocked").printf (email));
            });
            dlg.open_dialog ();
        }

        private void delete_selected () {
            if (composing) return;
            var targets = selected_targets ();
            if (targets.size == 0) return;
            foreach (var e in by_account (targets).entries) {
                var s = app.syncs[e.key];
                if (s == null) continue;
                var list = e.value;
                var f = app.store.folder (list[0].folder);
                if (f != null && f.role == "trash") {
                    advance_after_removal ();
                    s.destroy.begin (list);
                    show_toast (ngettext ("Deleted %d message forever", "Deleted %d messages forever", list.size).printf (list.size));
                    continue;
                }
                s.ensure_folder.begin ("trash", "Trash", (o, res) => {
                    var trash = s.ensure_folder.end (res);
                    if (trash == null) {
                        show_toast (_("There is no Trash folder and Lettere could not create one while offline"));
                        return;
                    }
                    do_move (list, trash);
                });
            }
        }

        private void bulk_action (string kind) {
            switch (kind) {
                case "read":
                case "unread": {
                    var targets = selected_targets ();
                    foreach (var e in by_account (targets).entries) {
                        var s = app.syncs[e.key];
                        if (s != null) s.set_flag.begin (e.value, MessageFlags.SEEN, kind == "read");
                    }
                    break;
                }
                case "flag": {
                    var targets = selected_targets ();
                    foreach (var e in by_account (targets).entries) {
                        var s = app.syncs[e.key];
                        if (s != null) s.set_flag.begin (e.value, MessageFlags.FLAGGED, true);
                    }
                    break;
                }
                case "pin": toggle_flag (MessageFlags.PINNED); break;
                case "archive": archive (); break;
                case "move": run_action ("move"); break;
                case "delete": delete_selected (); break;
                case "junk": junk (); break;
            }
        }

        private void set_focus_class (int focus) {
            var m = reader.current ?? lead;
            if (m == null) return;
            string email = m.sender_email;
            var targets = selected_targets ();
            foreach (var t in targets) app.store.set_focus (t.id, focus);
            show_toast (focus == 0 ? _("Moved to Other") : _("Moved to Focused"), _("Always for This Sender"), () => {
                app.store.set_sender_focus (email, focus);
                rebuild_list ();
            });
            advance_after_removal ();
            rebuild_list ();
        }

        private void ignore_conversation () {
            var m = reader.current ?? lead;
            if (m == null) return;
            string[] list = app.settings.get_strv ("ignored-threads");
            list += m.account + "\x01" + m.thread;
            app.settings.set_strv ("ignored-threads", list);
            delete_selected ();
            show_toast (_("This conversation and new replies to it go to Trash"));
        }

        private void sync_now () {
            if (app.settings.get_boolean ("work-offline")) {
                show_toast (_("Lettere is working offline"), _("Go Online"), () => app.settings.set_boolean ("work-offline", false));
                return;
            }
            foreach (var s in app.syncs.values) {
                if (s.blocked) continue;
                if (s.state == SyncState.OFFLINE || s.state == SyncState.SERVER_ERROR) s.go_online ();
                else s.sync_all.begin ();
            }
            sync_actions ();
        }

        private void add_account () {
            var dlg = new AccountDialog (app, null);
            dlg.transient_for = this;
            dlg.modal = true;
            dlg.saved.connect ((a) => show_toast (_("%s was added").printf (a.email)));
            dlg.open_dialog ();
        }

        private void edit_account (Account? a) {
            if (a == null) return;
            var dlg = new AccountDialog (app, a);
            dlg.transient_for = this;
            dlg.modal = true;
            dlg.saved.connect (() => {
                rebuild_sidebar ();
                update_banner ();
            });
            dlg.open_dialog ();
        }

        private void open_rules (MessageInfo? from_message) {
            var dlg = new RulesDialog (app, from_message);
            dlg.transient_for = this;
            dlg.open_dialog ();
        }

        private void sweep () {
            var m = reader.current ?? lead;
            if (m == null) return;
            var dlg = new SweepDialog (app, m);
            dlg.transient_for = this;
            dlg.done.connect ((n) => show_toast (ngettext ("Swept %d message", "Swept %d messages", n).printf (n)));
            dlg.open_dialog ();
        }

        private void view_source () {
            var raw = reader.current_raw ();
            if (raw == null) return;
            var dlg = new SourceDialog (app, raw, reader.current != null ? reader.current.subject : "");
            dlg.transient_for = this;
            dlg.open_dialog ();
        }

        private void save_message () {
            var raw = reader.current_raw ();
            if (raw == null || reader.current == null) return;
            var dialog = new FileDialog ();
            dialog.title = _("Save Message");
            dialog.initial_name = (reader.current.subject != "" ? reader.current.subject : "message").replace ("/", "_") + ".eml";
            var eml = new FileFilter ();
            eml.name = _("Email Message (.eml)");
            eml.add_pattern ("*.eml");
            var msgf = new FileFilter ();
            msgf.name = _("Outlook Message (.msg)");
            msgf.add_pattern ("*.msg");
            var filters = new GLib.ListStore (typeof (FileFilter));
            filters.append (eml);
            filters.append (msgf);
            dialog.filters = filters;
            dialog.save.begin (this, null, (o, res) => {
                try {
                    var f = dialog.save.end (res);
                    if (f == null) return;
                    bool as_msg = (f.get_basename () ?? "").down ().has_suffix (".msg");
                    f.replace_contents (as_msg ? MsgWriter.from_mime (raw) : raw, null, false, FileCreateFlags.REPLACE_DESTINATION, null);
                    show_toast (_("Saved %s").printf (f.get_basename ()));
                } catch (Error e) {
                    if (!(e is IOError.CANCELLED) && !(e is DialogError)) show_toast (_("Could not save: %s").printf (e.message));
                }
            });
        }

        private void open_in_window (MessageInfo m) {
            var w = new MessageWindow (app, m);
            w.present ();
        }

        private void add_contact () {
            var m = reader.current ?? lead;
            if (m == null || m.sender_email == "") return;
            if (app.contacts.knows (m.sender_email)) {
                show_toast (_("%s is already in Contacts").printf (m.sender_display));
                return;
            }
            try {
                ContactsBridge.add (new Address (m.sender_name, m.sender_email));
                app.contacts.invalidate ();
                show_toast (_("%s was added to Contacts").printf (m.sender_display));
            } catch (Error e) {
                show_toast (_("Could not add the contact: %s").printf (e.message));
            }
        }

        private Subprocess? speaker;

        private string speech_command () {
            var cfg = Singularity.Accessibility.ScreenReaderConfig.load ();
            string cmd = cfg.voices_command != "" ? cfg.voices_command : "spd-say";
            return cmd;
        }

        private void read_aloud () {
            var mime = reader.mime;
            if (mime == null) return;
            string cmd = speech_command ();
            if (Environment.find_program_in_path (cmd) == null) {
                show_toast (_("Reading aloud needs a speech engine (%s)").printf (cmd));
                return;
            }
            stop_reading ();
            string text = "%s. %s. %s".printf (reader.current != null ? reader.current.sender_display : "", mime.subject, mime.body_text ());
            try {
                speaker = new Subprocess.newv ({ cmd, "-e" }, SubprocessFlags.STDIN_PIPE);
                speaker.communicate_utf8_async.begin (text, null, (o, r) => {
                    try {
                        string a, b;
                        speaker.communicate_utf8_async.end (r, out a, out b);
                    } catch (Error e) {
                    }
                });
                show_toast (_("Reading the message aloud"), _("Stop"), () => stop_reading ());
            } catch (Error e) {
                show_toast (_("Could not read aloud: %s").printf (e.message));
            }
        }

        private void stop_reading () {
            if (speaker != null) speaker.force_exit ();
            speaker = null;
            try {
                string cmd = speech_command ();
                if (Environment.find_program_in_path (cmd) != null) Process.spawn_command_line_async (cmd + " -S");
            } catch (Error e) {
            }
        }

        private void add_task () {
            var m = reader.current ?? lead;
            if (m == null) return;
            TasksBridge.add (_("Follow up: %s").printf (m.subject != "" ? m.subject : m.sender_display), m.due);
            show_toast (_("Added to Tasks"));
        }

        private void new_folder (Folder? parent) {
            var a = parent != null ? app.accounts.find (parent.account) : current_account ();
            if (a == null) return;
            new_folder_in (a, parent);
        }

        private void new_folder_in (Account a, Folder? parent) {
            ask_text (parent != null ? _("New Folder in %s").printf (parent.display_name) : _("New Folder"), "", _("Create"), (name) => {
                var s = app.syncs[a.id];
                if (s == null) return;
                s.create_folder.begin (name, parent, (o, r) => {
                    try {
                        s.create_folder.end (r);
                        show_toast (_("Folder %s created").printf (name));
                    } catch (Error e) {
                        show_toast (_("Could not create the folder: %s").printf (e.message));
                    }
                });
            });
        }

        private void rename_folder (Folder f) {
            ask_text (_("Rename Folder"), f.name, _("Rename"), (name) => {
                var s = app.syncs[f.account];
                if (s == null) return;
                s.rename_folder.begin (f, name, (o, r) => {
                    try {
                        s.rename_folder.end (r);
                    } catch (Error e) {
                        show_toast (_("Could not rename the folder: %s").printf (e.message));
                    }
                });
            });
        }

        private void delete_folder (Folder f) {
            var dlg = new ConfirmDialog (app, _("Delete %s?").printf (f.display_name), null, _("The folder and every message in it are deleted on the server."), _("Delete"), ConfirmDialog.ActionStyle.DESTRUCTIVE);
            dlg.transient_for = this;
            dlg.modal = true;
            dlg.response.connect ((r) => {
                if (r != ConfirmDialog.Response.PRIMARY) return;
                var s = app.syncs[f.account];
                if (s == null) return;
                if (source == "folder:" + f.id.to_string ()) select_source ("unified");
                s.delete_folder.begin (f, (o, res) => {
                    try {
                        s.delete_folder.end (res);
                    } catch (Error e) {
                        show_toast (_("Could not delete the folder: %s").printf (e.message));
                    }
                });
            });
            dlg.open_dialog ();
        }

        private void mark_all_read (Folder? f) {
            if (f == null) return;
            var s = app.syncs[f.account];
            if (s == null) return;
            var unread = new Gee.ArrayList<MessageInfo> ();
            foreach (var m in app.store.folder_messages (f.id)) if (m.unread) unread.add (m);
            s.set_flag.begin (unread, MessageFlags.SEEN, true);
            show_toast (ngettext ("Marked %d message as read", "Marked %d messages as read", unread.size).printf (unread.size));
        }

        private void empty_folder (Folder? f) {
            if (f == null) return;
            var dlg = new ConfirmDialog (app, _("Empty %s?").printf (f.display_name), null, _("Every message in this folder is deleted forever."), _("Empty"), ConfirmDialog.ActionStyle.DESTRUCTIVE);
            dlg.transient_for = this;
            dlg.modal = true;
            dlg.response.connect ((r) => {
                if (r != ConfirmDialog.Response.PRIMARY) return;
                var s = app.syncs[f.account];
                if (s != null) s.destroy.begin (app.store.folder_messages (f.id));
                show_none ();
            });
            dlg.open_dialog ();
        }

        public delegate void TextCallback (string text);

        private void ask_text (string title, string initial, string action, owned TextCallback cb) {
            var dlg = new ConfirmDialog (app, title, null, null, action, ConfirmDialog.ActionStyle.SUGGESTED);
            dlg.transient_for = this;
            dlg.modal = true;
            var group = new PreferencesGroup ();
            var name = new EntryRow (_("Name"));
            name.text = initial;
            group.add_row (name);
            dlg.custom_area.append (group);
            dlg.response.connect ((r) => {
                if (r == ConfirmDialog.Response.PRIMARY && name.text.strip () != "") cb (name.text.strip ());
            });
            dlg.open_dialog ();
        }

        private void auto_reply () {
            var a = current_account ();
            if (a != null) auto_reply_for (a);
        }

        private void auto_reply_for (Account a) {
            var s = app.syncs[a.id];
            if (s == null) return;
            var dlg = new AutoReplyDialog (app, s);
            dlg.transient_for = this;
            dlg.open_dialog ();
        }

        private void open_shared () {
            var a = current_account ();
            if (a != null) open_shared_for (a);
        }

        private void open_shared_for (Account a) {
            ask_text (_("Open Shared Mailbox"), "", _("Open"), (name) => {
                var s = app.syncs[a.id];
                if (s == null) return;
                open_shared_async.begin (s, name);
            });
        }

        private async void open_shared_async (AccountSync s, string name) {
            try {
                yield s.ensure ();
                var list = yield s.backend.open_shared (name);
                app.accounts.save ();
                foreach (var r in list) app.store.upsert_folder (s.account.id, r.path, r.name, "", r.delimiter, r.parent, true);
                app.store.folders_changed (s.account.id);
                show_toast (ngettext ("Opened %d folder of %s", "Opened %d folders of %s", list.size).printf (list.size, name));
                s.sync_all.begin ();
            } catch (Error e) {
                show_toast (_("Could not open %s: %s").printf (name, e.message));
            }
        }

        private async void show_quota (Account a) {
            var s = app.syncs[a.id];
            if (s == null) return;
            string text;
            try {
                var q = yield s.quota ();
                if (q != null && q.limit > 0) text = _("%s of %s used (%d%%)").printf (format_size (q.used), format_size (q.limit), (int) (q.used * 100 / q.limit));
                else if (q != null) text = _("%s used").printf (format_size (q.used));
                else text = _("The server does not report a limit. Mail kept on this computer for this account: %s").printf (format_size (app.store.total_bytes (a.id)));
            } catch (Error e) {
                text = _("Mail kept on this computer for this account: %s").printf (format_size (app.store.total_bytes (a.id)));
            }
            var dlg = new ConfirmDialog.message (app, _("Storage for %s").printf (a.email), null, text);
            dlg.transient_for = this;
            dlg.open_dialog ();
        }

        private void import_mail () {
            var dialog = new FileDialog ();
            dialog.title = _("Import Mail");
            var filter = new FileFilter ();
            filter.name = _("Mail Files");
            foreach (string p in new string[] { "*.pst", "*.ost", "*.mbox", "*.mbx", "*.eml", "*.msg", "*.PST", "*.MBOX", "*.EML", "*.MSG" }) filter.add_pattern (p);
            filter.add_mime_type ("application/mbox");
            filter.add_mime_type ("message/rfc822");
            filter.add_mime_type ("application/vnd.ms-outlook");
            var all = new FileFilter ();
            all.name = _("All Files");
            all.add_pattern ("*");
            var filters = new GLib.ListStore (typeof (FileFilter));
            filters.append (filter);
            filters.append (all);
            dialog.filters = filters;
            dialog.open_multiple.begin (this, null, (o, res) => {
                try {
                    var files = dialog.open_multiple.end (res);
                    var list = new Gee.ArrayList<File> ();
                    for (uint i = 0; i < files.get_n_items (); i++) list.add ((File) files.get_item (i));
                    if (list.size > 0) run_import.begin (list);
                } catch (Error e) {
                }
            });
        }

        private async void run_import (Gee.List<File> files) {
            var local = app.local_account ();
            var s = app.syncs[local.id];
            if (s == null) return;
            yield s.sync_all ();
            int total = 0;
            show_toast (_("Importing…"), null, null, 60);
            foreach (var f in files) {
                try {
                    total += yield Importer.import_file (app, s, f);
                } catch (Error e) {
                    show_toast (_("Could not import %s: %s").printf (f.get_basename (), e.message));
                    return;
                }
            }
            app.store.rethread (local.id);
            s.data_changed ();
            rebuild_sidebar ();
            show_toast (ngettext ("Imported %d message into On This Computer", "Imported %d messages into On This Computer", total).printf (total));
        }

        private void export_mail () {
            var f = source_folder ();
            if (f != null) export_folder (f);
        }

        private void export_folder (Folder f) {
            var dialog = new FileDialog ();
            dialog.title = _("Export Folder");
            dialog.initial_name = f.display_name.replace ("/", "_") + ".pst";
            var pst = new FileFilter ();
            pst.name = _("Outlook Data File (.pst)");
            pst.add_pattern ("*.pst");
            var mbox = new FileFilter ();
            mbox.name = _("Mailbox (.mbox)");
            mbox.add_pattern ("*.mbox");
            var filters = new GLib.ListStore (typeof (FileFilter));
            filters.append (pst);
            filters.append (mbox);
            dialog.filters = filters;
            dialog.save.begin (this, null, (o, res) => {
                try {
                    var file = dialog.save.end (res);
                    if (file == null) return;
                    if (!(file.get_basename () ?? "").down ().has_suffix (".mbox")) {
                        var roots = new Gee.ArrayList<Folder> ();
                        roots.add (f);
                        show_toast (_("Exporting…"), null, null, 60);
                        Importer.export_pst.begin (app, roots, f.display_name, file, (o3, r3) => {
                            try {
                                int n = Importer.export_pst.end (r3);
                                show_toast (ngettext ("Exported %d message to an Outlook data file", "Exported %d messages to an Outlook data file", n).printf (n));
                            } catch (Error e) {
                                show_toast (_("Could not export: %s").printf (e.message));
                            }
                        });
                        return;
                    }
                    Importer.export_mbox.begin (app, f, file, (o2, r2) => {
                        try {
                            int n = Importer.export_mbox.end (r2);
                            show_toast (ngettext ("Exported %d message", "Exported %d messages", n).printf (n));
                        } catch (Error e) {
                            show_toast (_("Could not export: %s").printf (e.message));
                        }
                    });
                } catch (Error e) {
                }
            });
        }

        private void export_account (Account a) {
            var dialog = new FileDialog ();
            dialog.title = _("Export to Outlook Data File");
            dialog.initial_name = a.display_name.replace ("/", "_").replace ("@", "-") + ".pst";
            dialog.save.begin (this, null, (o, res) => {
                try {
                    var file = dialog.save.end (res);
                    if (file == null) return;
                    var roots = new Gee.ArrayList<Folder> ();
                    foreach (var f in ordered_tree (app.store.folders (a.id))) if (folder_depth (f) == 0 || f.role != "") roots.add (f);
                    show_toast (_("Exporting…"), null, null, 120);
                    Importer.export_pst.begin (app, roots, a.display_name, file, (o2, r2) => {
                        try {
                            int n = Importer.export_pst.end (r2);
                            show_toast (ngettext ("Exported %d message to an Outlook data file", "Exported %d messages to an Outlook data file", n).printf (n));
                        } catch (Error e) {
                            show_toast (_("Could not export: %s").printf (e.message));
                        }
                    });
                } catch (Error e) {
                }
            });
        }

        private void mail_merge () {
            var a = current_account ();
            if (a == null) return;
            var dlg = new MergeDialog (app, a);
            dlg.transient_for = this;
            dlg.open_dialog ();
        }

        private void new_from_template () {
            if (app.templates.items.size == 0) {
                show_toast (_("There are no templates yet. Write a message and choose Insert, Save as Template."));
                return;
            }
            var dlg = new PickItemDialog (app, app.templates, _("New Message from Template"));
            dlg.transient_for = this;
            dlg.picked.connect ((it) => {
                if (composing) return;
                composer.start_template (current_account (), it);
                enter_compose ();
            });
            dlg.open_dialog ();
        }

        private void open_file_dialog () {
            var dialog = new FileDialog ();
            dialog.title = _("Open Message File");
            var filter = new FileFilter ();
            filter.name = _("Email Messages");
            filter.add_pattern ("*.eml");
            filter.add_pattern ("*.msg");
            filter.add_mime_type ("message/rfc822");
            filter.add_mime_type ("application/vnd.ms-outlook");
            var filters = new GLib.ListStore (typeof (FileFilter));
            filters.append (filter);
            dialog.filters = filters;
            dialog.open.begin (this, null, (o, res) => {
                try {
                    var f = dialog.open.end (res);
                    if (f != null) open_file.begin (f);
                } catch (Error e) {
                }
            });
        }

        public async void open_file (File f) {
            try {
                uint8[] data;
                string etag;
                yield f.load_contents_async (null, out data, out etag);
                if (MsgFile.is_msg (data)) data = MsgFile.to_mime (data);
                leave_compose ();
                file_view = true;
                stack.visible_child_name = "mail";
                selection.unselect_all ();
                lead = null;
                reader_stack.visible_child_name = "reader";
                reader.show_file (new MimeMessage (data), f.get_basename ());
                sync_actions ();
            } catch (Error e) {
                show_toast (_("Could not open %s: %s").printf (f.get_basename (), e.message));
            }
        }

        private void launch (string uri) {
            if (uri.has_prefix ("mailto:")) {
                compose_to (uri);
                return;
            }
            new UriLauncher (uri).launch.begin (this, null, (o, res) => {
                try {
                    new UriLauncher (uri).launch.end (res);
                } catch (Error e) {
                }
            });
        }

        public void compose_to (string uri) {
            string to, subject, body;
            Special.mailto_parts (uri, out to, out subject, out body);
            if (app.accounts.accounts.size == 0) {
                add_account ();
                return;
            }
            if (composing) return;
            composer.start_new (current_account (), to, subject, body);
            enter_compose ();
        }

        public void compose_files (File[] files) {
            compose_new ();
            if (!composing) return;
            foreach (var f in files) composer.add_file.begin (f);
        }

        public void compose_text (string text) {
            compose_new ();
            if (!composing) return;
            composer.insert_body_text (text);
        }

        private void enter_compose () {
            composing = true;
            compose_serial++;
            stack.visible_child_name = "compose";
            set_sidebar_visible (false);
            sync_actions ();
        }

        private void leave_compose () {
            if (!composing) return;
            composing = false;
            stack.visible_child_name = app.accounts.accounts.size > 0 || file_view ? "mail" : "welcome";
            set_sidebar_visible (app.accounts.accounts.size > 0);
            sync_actions ();
        }

        private void compose_new (string to = "") {
            if (app.accounts.accounts.size == 0) {
                add_account ();
                return;
            }
            if (composing) return;
            composer.start_new (current_account (), to);
            enter_compose ();
            composer.focus_first ();
        }

        private void reply (bool all) {
            var m = reader.current;
            var mime = reader.mime;
            if (m == null || mime == null || composing) return;
            var a = app.accounts.find (m.account) ?? current_account ();
            if (a == null) return;
            composer.start_reply (a, m, mime, all);
            enter_compose ();
        }

        private void forward (bool as_attachment) {
            var m = reader.current;
            var mime = reader.mime;
            if (m == null || mime == null || composing) return;
            var a = app.accounts.find (m.account) ?? current_account ();
            if (a == null) return;
            composer.start_forward (a, m, mime, as_attachment, reader.current_raw ());
            enter_compose ();
        }

        private void redirect () {
            var m = reader.current;
            var raw = reader.current_raw ();
            if (m == null || raw == null) return;
            var a = app.accounts.find (m.account);
            if (a == null) return;
            ask_text (_("Redirect To"), "", _("Redirect"), (to) => {
                var list = Mime.parse_addresses (to);
                var rcpts = new Gee.ArrayList<string> ();
                foreach (var x in list) rcpts.add (x.email);
                if (rcpts.size == 0) return;
                app.queue_raw (a, Special.redirect (raw, a, list), rcpts, a.email, m.subject, null);
                show_toast (_("The message was redirected to %s").printf (to));
            });
        }

        private void edit_as_new () {
            var m = reader.current;
            var mime = reader.mime;
            if (m == null || mime == null || composing) return;
            var a = app.accounts.find (m.account) ?? current_account ();
            if (a == null) return;
            composer.start_draft (a, null, mime);
            enter_compose ();
            composer.mark_modified ();
        }

        private void edit_draft () {
            var m = reader.current;
            var mime = reader.mime;
            if (m == null || mime == null || composing || !lead_in ("drafts")) return;
            var a = app.accounts.find (m.account);
            if (a == null) return;
            composer.start_draft (a, m, mime);
            enter_compose ();
        }

        private void send_later () {
            if (!composing) return;
            var dlg = new WhenDialog (app, _("Send Later"), preset_time (1), _("Schedule"));
            dlg.transient_for = this;
            dlg.chosen.connect ((t) => send.begin (t));
            dlg.open_dialog ();
        }

        private async void send (int64 at) {
            string problem;
            if (!composer.has_recipients ()) {
                show_toast (_("Add at least one recipient"));
                composer.focus_first ();
                return;
            }
            var b = yield composer.build (out problem);
            if (b == null) {
                show_toast (problem);
                return;
            }
            var a = composer.account;
            var hook = new LettereApp.SentHook ();
            hook.account = a.id;
            hook.answered.add_all (composer.answering);
            hook.flag = composer.mode == ComposeMode.FORWARD ? MessageFlags.FORWARDED : MessageFlags.ANSWERED;
            hook.draft = composer.draft;
            int64 id = app.queue_message (a, b, hook, at);
            int serial = compose_serial;
            composer.mark_clean ();
            leave_compose ();
            if (at > 0) {
                show_toast (_("The message will be sent %s. It waits in the Outbox.").printf (format_full (at)), _("Outbox"), () => select_source ("outbox"));
                rebuild_sidebar ();
                return;
            }
            int delay = app.settings.get_int ("send-delay");
            if (delay <= 0) {
                show_toast (_("Sending…"));
                return;
            }
            show_toast (ngettext ("Sending in %d second", "Sending in %d seconds", delay).printf (delay), _("Undo"), () => {
                if (!app.cancel_outbox (id)) {
                    show_toast (_("Too late, the message is already on its way"));
                    return;
                }
                if (serial != compose_serial) composer.start_draft (a, hook.draft, new MimeMessage (b.build (true)));
                enter_compose ();
                compose_serial = serial;
                composer.mark_modified ();
            }, (uint) delay);
        }

        private async bool save_draft (bool quiet) {
            while (saving_draft) {
                ulong changed = 0;
                changed = notify["saving-draft"].connect (() => {
                    if (saving_draft) return;
                    disconnect (changed);
                    Idle.add (save_draft.callback);
                });
                yield;
            }
            if (!composing) return false;
            saving_draft = true;
            try {
                int serial = compose_serial;
                uint64 revision = composer.revision;
                string problem;
                var b = yield composer.build (out problem);
                var a = composer.account;
                if (serial != compose_serial || !composing) return false;
                if (b == null || a == null) {
                    if (!quiet) show_toast (problem);
                    return false;
                }
                var s = app.syncs[a.id];
                if (s == null) return false;
                var old = composer.draft;
                var folder = yield s.ensure_folder ("drafts", "Drafts");
                if (folder == null) throw new MailError.OFFLINE (_("offline"));
                b.message_id = "";
                b.date = null;
                string rid = yield s.append (folder, "\\Draft \\Seen", b.build (true));
                if (old != null) {
                    var list = new Gee.ArrayList<MessageInfo> ();
                    list.add (old);
                    yield s.destroy (list);
                }
                yield s.refresh_folder (folder);
                if (serial != compose_serial || !composing) return false;
                int64 id = rid != "" ? app.store.id_for_rid (folder.id, rid) : 0;
                composer.draft = id > 0 ? app.store.message (id) : null;
                if (revision == composer.revision) composer.mark_clean ();
                if (!quiet) show_toast (_("Draft saved in %s").printf (folder.display_name));
                return true;
            } catch (Error e) {
                if (!quiet) show_toast (_("Could not save the draft: %s").printf (e.message));
                return false;
            } finally {
                saving_draft = false;
            }
        }

        private void discard () {
            if (!composer.dirty) {
                leave_compose ();
                return;
            }
            var dlg = new ConfirmDialog (app, _("Discard Message?"), null, _("What you wrote will be lost."), _("Discard"), ConfirmDialog.ActionStyle.DESTRUCTIVE);
            dlg.transient_for = this;
            dlg.modal = true;
            dlg.set_secondary (_("Save Draft"), ConfirmDialog.ActionStyle.DEFAULT);
            dlg.response.connect ((r) => {
                if (r == ConfirmDialog.Response.PRIMARY) {
                    composer.mark_clean ();
                    leave_compose ();
                } else if (r == ConfirmDialog.Response.SECONDARY) {
                    save_draft.begin (false, (o, res) => {
                        save_draft.end (res);
                        if (!composer.dirty) leave_compose ();
                    });
                }
            });
            dlg.open_dialog ();
        }

        public void script (string cmd, string arg) {
            switch (cmd) {
                case "source":
                    if (arg.has_prefix ("role:") || arg.has_prefix ("name:")) {
                        foreach (var a in app.accounts.accounts) {
                            foreach (var f in app.store.folders (a.id)) {
                                if ((arg.has_prefix ("role:") && f.role == arg.substring (5)) || (arg.has_prefix ("name:") && f.name == arg.substring (5))) {
                                    select_source ("folder:" + f.id.to_string ());
                                    return;
                                }
                            }
                        }
                    }
                    select_source (arg);
                    break;
                case "select":
                    selection.select_item ((uint) int.parse (arg), true);
                    break;
                case "select-more":
                    selection.select_item ((uint) int.parse (arg), false);
                    break;
                case "select-subject":
                    for (uint i = 0; i < model.get_n_items (); i++) {
                        var m = (MessageInfo) model.get_item (i);
                        if (m.subject.contains (arg)) {
                            selection.select_item (i, true);
                            list.scroll_to (i, ListScrollFlags.NONE, null);
                            return;
                        }
                    }
                    break;
                case "search":
                    search.text = arg;
                    query = arg;
                    server_hits = null;
                    rebuild_list ();
                    break;
                case "row-menu": {
                    var row = list.get_first_child ();
                    if (row != null) row_menu (list, 180, 90 + int.parse (arg) * 60);
                    break;
                }
                case "popover":
                    switch (arg) {
                        case "snooze": mail_ribbon.active_context = "home"; popup_menu (snooze_item, (m) => fill_snooze (m)); break;
                        case "categories": mail_ribbon.active_context = "home"; popup_menu (category_item, (m) => fill_categories (m)); break;
                        case "steps": mail_ribbon.active_context = "home"; popup_menu (steps_item, (m) => fill_steps (m)); break;
                        case "move": mail_ribbon.active_context = "home"; popup_menu (move_item, (m) => fill_move (m, false)); break;
                        case "filter": mail_ribbon.active_context = "view"; filter_selector.button.clicked (); break;
                        case "sort": mail_ribbon.active_context = "view"; sort_selector.button.clicked (); break;
                    }
                    break;
                case "compose-to":
                    composer.script_set ("to", arg);
                    break;
                case "compose-subject":
                    composer.script_set ("subject", arg);
                    break;
                case "compose-body":
                    composer.editor.set_html (arg);
                    break;
                case "compose-cc":
                    composer.script_set ("cc", arg);
                    break;
                case "ribbon":
                    mail_ribbon.active_context = arg;
                    break;
                case "compose-toolbar":
                    composer.script_set ("toolbar", arg);
                    break;
                case "send":
                    send.begin (0);
                    break;
                case "folder-menu": {
                    Folder? f = null;
                    foreach (var a in app.accounts.accounts) foreach (var x in app.store.folders (a.id)) if (x.name == arg || x.role == arg) f = x;
                    var r = f != null ? rows["folder:" + f.id.to_string ()] : null;
                    if (r != null) folder_menu (r, f, 60, 10);
                    break;
                }
                case "account-menu": {
                    Widget? c = sidebar.box.get_first_child ();
                    while (c != null && !(c is SidebarSectionLabel && ((SidebarSectionLabel) c).get_first_child () != null && app.accounts.accounts.size > 0)) c = c.get_next_sibling ();
                    Account? acc = app.accounts.accounts.size > 0 ? app.accounts.accounts[0] : null;
                    foreach (var a in app.accounts.accounts) if (a.display_name == arg) acc = a;
                    if (c != null && acc != null) account_menu (c, acc, 60, 10);
                    break;
                }
                case "import": {
                    var files = new Gee.ArrayList<File> ();
                    foreach (string p in arg.split (" ")) files.add (File.new_for_path (p));
                    run_import.begin (files);
                    break;
                }
                case "open-file":
                    open_file.begin (File.new_for_path (arg));
                    break;
                case "snooze":
                    do_snooze (new DateTime.now_utc ().to_unix () + int.parse (arg));
                    break;
                case "flag-due":
                    flag_due (int.parse (arg));
                    break;
                case "open-window":
                    if (reader.current != null) open_in_window (reader.current);
                    break;
                case "popdown":
                    popdown_menus (mail_ribbon);
                    popdown_menus (list);
                    popdown_menus (compose_ribbon);
                    break;
                case "close-dialogs":
                    var open = new Gee.ArrayList<Gtk.Window> ();
                    foreach (var w in app.get_windows ()) if (w != this) open.add (w);
                    foreach (var w in open) w.close ();
                    break;
                case "dark":
                    Gtk.Settings.get_default ().gtk_application_prefer_dark_theme = arg == "on";
                    break;
            }
        }
    }

    public class MessageWindow : Singularity.Widgets.Window {
        private LettereApp app;
        private ReaderView reader;

        public MessageWindow (LettereApp app, MessageInfo m) {
            Object (application: app);
            this.app = app;
            set_title (m.subject != "" ? m.subject : _("(No Subject)"));
            set_default_size (860, 760);
            reader = new ReaderView (app);
            Singularity.Widgets.apply_view_edge (reader);
            set_content (reader);
            reader.open_uri.connect ((uri) => new UriLauncher (uri).launch.begin (this, null));
            reader.toast.connect ((t) => add_toast (new Singularity.Widgets.Toast (t)));
            reader.action_requested.connect ((action, msg) => {
                var w = app.main_window ();
                w.present ();
                w.show_message_id (msg.id);
            });
            add_bubble_icon ("mail-reply-sender-symbolic", _("Reply"), () => main_action ("win.reply"));
            add_bubble_icon ("mail-reply-all-symbolic", _("Reply All"), () => main_action ("win.reply-all"));
            add_bubble_icon ("mail-forward-symbolic", _("Forward"), () => main_action ("win.forward"));
            add_bubble_icon ("document-print-symbolic", _("Print"), () => reader.print (this));
            var one = new Gee.ArrayList<MessageInfo> ();
            one.add (m);
            reader.show_conversation (one, m, app.syncs[m.account]);
        }

        private void main_action (string name) {
            var w = app.main_window ();
            w.present ();
            if (reader.current != null) w.show_message_id (reader.current.id);
            Idle.add (() => {
                w.activate_action (name, null);
                return Source.REMOVE;
            });
            close ();
        }
    }
}
