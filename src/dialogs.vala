using Gtk;
using Singularity.Widgets;

namespace Singularity.Apps.Lettere {

    public class WhenDialog : ConfirmDialog {
        public signal void chosen (int64 when);

        private Gtk.Calendar date_picker;
        private SpinButton hour;
        private SpinButton minute;

        public WhenDialog (LettereApp app, string title, int64 initial, string action) {
            base (app, title, null, null, action, ConfirmDialog.ActionStyle.SUGGESTED);
            modal = true;
            var start = new DateTime.from_unix_local (initial > 0 ? initial : new DateTime.now_local ().to_unix ());
            date_picker = new Gtk.Calendar ();
            date_picker.year = start.get_year ();
            date_picker.month = start.get_month () - 1;
            date_picker.day = start.get_day_of_month ();
            custom_area.append (date_picker);
            var row = new Box (Orientation.HORIZONTAL, 6);
            row.halign = Align.CENTER;
            row.margin_top = 6;
            row.append (new Label (_("Time")));
            hour = new SpinButton.with_range (0, 23, 1);
            hour.value = start.get_hour ();
            hour.update_property (AccessibleProperty.LABEL, _("Hour"), -1);
            row.append (hour);
            row.append (new Label (":"));
            minute = new SpinButton.with_range (0, 59, 5);
            minute.value = start.get_minute ();
            minute.update_property (AccessibleProperty.LABEL, _("Minute"), -1);
            row.append (minute);
            custom_area.append (row);
            response.connect ((r) => {
                if (r != ConfirmDialog.Response.PRIMARY) return;
                var d = date_picker.get_date ();
                var t = new DateTime.local (d.get_year (), d.get_month (), d.get_day_of_month (), (int) hour.value, (int) minute.value, 0);
                chosen (t.to_unix ());
            });
        }
    }

    public class CategoriesDialog : AppDialog {
        private LettereApp app;
        private PreferencesGroup group;

        public CategoriesDialog (LettereApp app) {
            base (app, true);
            set_title (_("Categories"));
            this.app = app;
            set_default_size (460, 540);
            var box = new Box (Orientation.VERTICAL, 12);
            box.margin_start = 16;
            box.margin_end = 16;
            box.margin_bottom = 16;
            var add_group = new PreferencesGroup (_("New Category"));
            var name = new EntryRow (_("Name"));
            add_group.add_row (name);
            var add = new Button.with_label (_("Add"));
            add.add_css_class ("pill");
            add.halign = Align.END;
            add.clicked.connect (() => {
                string n = name.text.strip ();
                if (n == "") return;
                app.categories.ensure (n);
                name.text = "";
                fill ();
            });
            box.append (add_group);
            box.append (add);
            group = new PreferencesGroup (_("Your Categories"), _("Categories travel with the messages as server keywords or labels, so other devices see them too."));
            var scroll = new ScrolledWindow ();
            scroll.vexpand = true;
            scroll.hscrollbar_policy = PolicyType.NEVER;
            scroll.child = group;
            box.append (scroll);
            content_box.append (box);
            fill ();
        }

        private void fill () {
            group.clear ();
            foreach (var c in app.categories.items) {
                var row = new ActionRow (c.name, null, null);
                var color = new ColorPickerButton (parse (c.color));
                color.valign = Align.CENTER;
                color.tooltip_text = _("Color of %s").printf (c.name);
                var item = c;
                color.color_changed.connect ((rgba) => {
                    item.color = "#%02x%02x%02x".printf ((int) (rgba.red * 255), (int) (rgba.green * 255), (int) (rgba.blue * 255));
                    app.categories.save ();
                });
                row.add_suffix (color);
                var del = new Button.from_icon_name ("user-trash-symbolic");
                del.add_css_class ("flat");
                del.valign = Align.CENTER;
                del.tooltip_text = _("Delete %s").printf (c.name);
                del.clicked.connect (() => {
                    app.categories.remove (item.name);
                    fill ();
                });
                row.add_suffix (del);
                group.add_row (row);
            }
        }

        private static Gdk.RGBA parse (string hex) {
            var c = Gdk.RGBA ();
            if (!c.parse (hex)) c.parse ("#3584e4");
            return c;
        }
    }

    public class RulesDialog : AppDialog {
        private LettereApp app;
        private PreferencesGroup group;

        public RulesDialog (LettereApp app, MessageInfo? from_message) {
            base (app, true);
            set_title (_("Rules"));
            this.app = app;
            set_default_size (560, 600);
            var box = new Box (Orientation.VERTICAL, 12);
            box.margin_start = 16;
            box.margin_end = 16;
            box.margin_bottom = 16;
            group = new PreferencesGroup (null, _("Rules sort new mail as it arrives. Rules kept on the server keep working when Lettere is closed."));
            var scroll = new ScrolledWindow ();
            scroll.vexpand = true;
            scroll.hscrollbar_policy = PolicyType.NEVER;
            scroll.child = group;
            box.append (scroll);
            var add = new Button.with_label (_("New Rule…"));
            add.add_css_class ("pill");
            add.add_css_class ("suggested-action");
            add.halign = Align.END;
            add.clicked.connect (() => edit (null, null));
            box.append (add);
            content_box.append (box);
            fill ();
            if (from_message != null) Idle.add (() => {
                edit (null, from_message);
                return Source.REMOVE;
            });
        }

        private void fill () {
            group.clear ();
            if (app.rules.rules.size == 0) {
                var row = new ActionRow (_("No rules yet"), _("Create one to move, flag, categorize or forward messages automatically"), null);
                group.add_row (row);
                return;
            }
            foreach (var r in app.rules.rules) {
                var rule = r;
                var row = new SwitchRow (r.name != "" ? r.name : _("Rule"), r.describe () + (r.on_server ? "  " + _("(on the server)") : ""), r.enabled);
                row.notify["active"].connect (() => {
                    rule.enabled = row.active;
                    app.rules.save ();
                });
                var editb = new Button.from_icon_name ("document-edit-symbolic");
                editb.add_css_class ("flat");
                editb.valign = Align.CENTER;
                editb.tooltip_text = _("Edit %s").printf (row.title);
                editb.clicked.connect (() => edit (rule, null));
                row.add_suffix (editb);
                var del = new Button.from_icon_name ("user-trash-symbolic");
                del.add_css_class ("flat");
                del.valign = Align.CENTER;
                del.tooltip_text = _("Delete %s").printf (row.title);
                del.clicked.connect (() => {
                    app.rules.remove (rule);
                    fill ();
                });
                row.add_suffix (del);
                group.add_row (row);
            }
        }

        private void edit (Rule? rule, MessageInfo? m) {
            var dlg = new RuleEditor (app, rule, m);
            dlg.transient_for = this;
            dlg.saved.connect (() => fill ());
            dlg.open_dialog ();
        }
    }

    public class RuleEditor : ConfirmDialog {
        public signal void saved ();

        private LettereApp app;
        private Rule rule;
        private bool fresh;
        private EntryRow name_row;
        private Box conditions_box;
        private Box actions_box;
        private SwitchRow all_row;
        private SwitchRow stop_row;
        private SwitchRow server_row;
        private SelectionRow account_row;
        private string[] account_labels;

        public RuleEditor (LettereApp app, Rule? existing, MessageInfo? m) {
            base (app, existing == null ? _("New Rule") : _("Edit Rule"), null, null, _("Save"), ConfirmDialog.ActionStyle.SUGGESTED);
            this.app = app;
            modal = true;
            set_default_size (560, -1);
            fresh = existing == null;
            rule = existing ?? new Rule ();
            if (fresh && m != null) {
                rule.name = _("From %s").printf (m.sender_display);
                rule.conditions.add (new RuleCondition ("from", "contains", m.sender_email));
                rule.account = m.account;
                var f = app.store.folder (m.folder);
                rule.actions.add (new RuleAction ("move", f != null && f.role != "inbox" ? f.path : ""));
            } else if (fresh) {
                rule.conditions.add (new RuleCondition ("from", "contains", ""));
                rule.actions.add (new RuleAction ("move", ""));
            }
            var scroll = new ScrolledWindow ();
            scroll.hscrollbar_policy = PolicyType.NEVER;
            scroll.propagate_natural_height = true;
            scroll.max_content_height = 520;
            scroll.min_content_width = 520;
            var box = new Box (Orientation.VERTICAL, 12);
            var g1 = new PreferencesGroup ();
            name_row = new EntryRow (_("Name"));
            name_row.text = rule.name;
            g1.add_row (name_row);
            account_labels = { _("All Accounts") };
            foreach (var a in app.accounts.accounts) account_labels += a.display_name;
            string current = _("All Accounts");
            foreach (var a in app.accounts.accounts) if (a.id == rule.account) current = a.display_name;
            account_row = new SelectionRow (_("Account"), account_labels, current);
            account_row.selected.connect ((v) => {
                account_row.current_value = v;
                account_row.expanded = false;
                rule.account = "";
                foreach (var a in app.accounts.accounts) if (a.display_name == v) rule.account = a.id;
                foreach (var ac in rule.actions) if (ac.kind == "move" || ac.kind == "copy") ac.value = "";
                fill_actions ();
            });
            g1.add_row (account_row);
            box.append (g1);
            var g2 = new PreferencesGroup (_("When a Message Arrives"));
            all_row = new SwitchRow (_("Match Every Condition"), _("Off matches any of them"), rule.match_all);
            g2.add_row (all_row);
            box.append (g2);
            conditions_box = new Box (Orientation.VERTICAL, 6);
            box.append (conditions_box);
            var add_cond = new Button.with_label (_("Add Condition"));
            add_cond.add_css_class ("flat");
            add_cond.halign = Align.START;
            add_cond.clicked.connect (() => {
                rule.conditions.add (new RuleCondition ("subject", "contains", ""));
                fill_conditions ();
            });
            box.append (add_cond);
            var g3 = new PreferencesGroup (_("Do This"));
            box.append (g3);
            actions_box = new Box (Orientation.VERTICAL, 6);
            box.append (actions_box);
            var add_act = new Button.with_label (_("Add Action"));
            add_act.add_css_class ("flat");
            add_act.halign = Align.START;
            add_act.clicked.connect (() => {
                rule.actions.add (new RuleAction ("flag", ""));
                fill_actions ();
            });
            box.append (add_act);
            var g4 = new PreferencesGroup ();
            stop_row = new SwitchRow (_("Stop Processing More Rules"), null, rule.stop);
            g4.add_row (stop_row);
            server_row = new SwitchRow (_("Run on the Server"), _("Works when Lettere is closed, where the account supports it"), rule.on_server);
            g4.add_row (server_row);
            box.append (g4);
            scroll.child = box;
            custom_area.append (scroll);
            fill_conditions ();
            fill_actions ();
            response.connect ((r) => {
                if (r != ConfirmDialog.Response.PRIMARY) return;
                rule.name = name_row.text.strip ();
                rule.match_all = all_row.active;
                rule.stop = stop_row.active;
                rule.on_server = server_row.active;
                rule.account = "";
                foreach (var a in app.accounts.accounts) if (a.display_name == account_row.current_value) rule.account = a.id;
                var keep = new Gee.ArrayList<RuleCondition> ();
                foreach (var c in rule.conditions) if (c.value.strip () != "" || c.field == "has-attachment" || c.field == "all") keep.add (c);
                rule.conditions = keep;
                if (fresh) app.rules.add (rule);
                else app.rules.save ();
                saved ();
            });
        }

        private DropDown drop (string[] ids, string[] labels, string current, owned ChangedValue cb) {
            var d = new DropDown (new StringList (labels), null);
            for (int i = 0; i < ids.length; i++) if (ids[i] == current) d.selected = i;
            d.notify["selected"].connect (() => cb (ids[(int) d.selected]));
            return d;
        }

        private delegate void ChangedValue (string v);

        private void fill_conditions () {
            Widget? c;
            while ((c = conditions_box.get_first_child ()) != null) conditions_box.remove (c);
            string[] fids = RuleStore.field_ids ();
            string[] flabels = {};
            foreach (string f in fids) flabels += RuleStore.field_label (f);
            string[] ops = { "contains", "not-contains", "is", "starts", "ends", "regex" };
            string[] op_labels = { _("contains"), _("does not contain"), _("is"), _("starts with"), _("ends with"), _("matches pattern") };
            foreach (var cond in rule.conditions) {
                var cd = cond;
                var item = new Box (Orientation.VERTICAL, 6);
                var row = new Box (Orientation.HORIZONTAL, 6);
                var field = drop (fids, flabels, cd.field, (v) => cd.field = v);
                field.hexpand = true;
                row.append (field);
                var op = drop (ops, op_labels, cd.op, (v) => cd.op = v);
                op.hexpand = true;
                row.append (op);
                var e = new Entry ();
                e.hexpand = true;
                e.text = cd.value;
                e.placeholder_text = _("Value");
                e.update_property (AccessibleProperty.LABEL, _("Value"), -1);
                e.changed.connect (() => cd.value = e.text);
                var del = new Button.from_icon_name ("list-remove-symbolic");
                del.add_css_class ("flat");
                del.tooltip_text = _("Remove Condition");
                del.clicked.connect (() => {
                    rule.conditions.remove (cd);
                    fill_conditions ();
                });
                row.append (del);
                item.append (row);
                item.append (e);
                conditions_box.append (item);
            }
        }

        private void fill_actions () {
            Widget? c;
            while ((c = actions_box.get_first_child ()) != null) actions_box.remove (c);
            string[] aids = RuleStore.action_ids ();
            string[] alabels = {};
            foreach (string a in aids) alabels += RuleStore.action_label (a);
            foreach (var act in rule.actions) {
                var ac = act;
                var row = new Box (Orientation.HORIZONTAL, 6);
                var value_box = new Box (Orientation.HORIZONTAL, 0);
                value_box.hexpand = true;
                row.append (drop (aids, alabels, ac.kind, (v) => {
                    ac.kind = v;
                    fill_value (value_box, ac);
                }));
                fill_value (value_box, ac);
                row.append (value_box);
                var del = new Button.from_icon_name ("list-remove-symbolic");
                del.add_css_class ("flat");
                del.tooltip_text = _("Remove Action");
                del.clicked.connect (() => {
                    rule.actions.remove (ac);
                    fill_actions ();
                });
                row.append (del);
                actions_box.append (row);
            }
        }

        private void fill_value (Box box, RuleAction ac) {
            Widget? c;
            while ((c = box.get_first_child ()) != null) box.remove (c);
            if (ac.kind == "move" || ac.kind == "copy") {
                string[] ids = {};
                string[] labels = {};
                string preferred = "";
                var seen = new Gee.HashSet<string> ();
                foreach (var a in app.accounts.accounts) {
                    if (rule.account != "" && a.id != rule.account) continue;
                    foreach (var f in app.store.folders (a.id)) {
                        if (!seen.add (f.path)) continue;
                        ids += f.path;
                        labels += f.display_name;
                        if (f.role == "archive" && preferred == "") preferred = f.path;
                    }
                }
                if (ids.length == 0) return;
                if (ac.value == "") ac.value = preferred != "" ? preferred : ids[0];
                var d = drop (ids, labels, ac.value, (v) => ac.value = v);
                d.hexpand = true;
                box.append (d);
                return;
            }
            if (ac.kind == "category") {
                string[] names = {};
                foreach (var cat in app.categories.items) names += cat.name;
                if (names.length == 0) return;
                if (ac.value == "") ac.value = names[0];
                var d = drop (names, names, ac.value, (v) => ac.value = v);
                d.hexpand = true;
                box.append (d);
                return;
            }
            if (ac.kind == "reply") {
                string[] names = {};
                foreach (var t in app.templates.items) names += t.name;
                if (names.length == 0) {
                    var l = new Label (_("Save a template first"));
                    l.add_css_class ("dim-label");
                    box.append (l);
                    return;
                }
                if (ac.value == "") ac.value = names[0];
                var d = drop (names, names, ac.value, (v) => ac.value = v);
                d.hexpand = true;
                box.append (d);
                return;
            }
            if (ac.kind == "forward" || ac.kind == "redirect") {
                var e = new Entry ();
                e.hexpand = true;
                e.text = ac.value;
                e.placeholder_text = _("Email address");
                e.input_purpose = InputPurpose.EMAIL;
                e.changed.connect (() => ac.value = e.text.strip ());
                box.append (e);
            }
        }
    }

    public class QuickStepsDialog : AppDialog {
        private LettereApp app;
        private PreferencesGroup group;

        public QuickStepsDialog (LettereApp app) {
            base (app, true);
            set_title (_("Quick Steps"));
            this.app = app;
            set_default_size (520, 520);
            var box = new Box (Orientation.VERTICAL, 12);
            box.margin_start = 16;
            box.margin_end = 16;
            box.margin_bottom = 16;
            group = new PreferencesGroup (null, _("A Quick Step does several things to the selected messages with one click."));
            var scroll = new ScrolledWindow ();
            scroll.vexpand = true;
            scroll.hscrollbar_policy = PolicyType.NEVER;
            scroll.child = group;
            box.append (scroll);
            var add = new Button.with_label (_("New Quick Step…"));
            add.add_css_class ("pill");
            add.add_css_class ("suggested-action");
            add.halign = Align.END;
            add.clicked.connect (() => edit (null));
            box.append (add);
            content_box.append (box);
            fill ();
        }

        private void fill () {
            group.clear ();
            foreach (var s in app.rules.steps) {
                var step = s;
                var labels = new Gee.ArrayList<string> ();
                foreach (var a in s.actions) labels.add (RuleStore.action_label (a.kind) + (a.value != "" ? " " + a.value : ""));
                var row = new ActionRow (s.name, string.joinv (", ", labels.to_array ()), null);
                var editb = new Button.from_icon_name ("document-edit-symbolic");
                editb.add_css_class ("flat");
                editb.valign = Align.CENTER;
                editb.tooltip_text = _("Edit %s").printf (s.name);
                editb.clicked.connect (() => edit (step));
                row.add_suffix (editb);
                var del = new Button.from_icon_name ("user-trash-symbolic");
                del.add_css_class ("flat");
                del.valign = Align.CENTER;
                del.tooltip_text = _("Delete %s").printf (s.name);
                del.clicked.connect (() => {
                    app.rules.steps.remove (step);
                    app.rules.save ();
                    fill ();
                });
                row.add_suffix (del);
                group.add_row (row);
            }
        }

        private void edit (QuickStep? existing) {
            var rule = new Rule ();
            rule.name = existing != null ? existing.name : _("My Quick Step");
            if (existing != null) rule.actions.add_all (existing.actions);
            else rule.actions.add (new RuleAction ("read", ""));
            var dlg = new StepEditor (app, rule);
            dlg.transient_for = this;
            dlg.done.connect (() => {
                var step = existing ?? new QuickStep ();
                if (existing == null) {
                    step.id = Uuid.string_random ().substring (0, 8);
                    app.rules.steps.add (step);
                }
                step.name = rule.name;
                step.actions.clear ();
                step.actions.add_all (rule.actions);
                app.rules.save ();
                fill ();
            });
            dlg.open_dialog ();
        }
    }

    public class StepEditor : ConfirmDialog {
        public signal void done ();

        public StepEditor (LettereApp app, Rule rule) {
            base (app, _("Quick Step"), null, null, _("Save"), ConfirmDialog.ActionStyle.SUGGESTED);
            modal = true;
            var g = new PreferencesGroup ();
            var name = new EntryRow (_("Name"));
            name.text = rule.name;
            g.add_row (name);
            custom_area.append (g);
            var box = new Box (Orientation.VERTICAL, 6);
            custom_area.append (box);
            var add = new Button.with_label (_("Add Action"));
            add.add_css_class ("flat");
            add.halign = Align.START;
            custom_area.append (add);
            string[] aids = RuleStore.action_ids ();
            string[] alabels = {};
            foreach (string a in aids) alabels += RuleStore.action_label (a);
            FillFn fill = null;
            fill = () => {
                Widget? c;
                while ((c = box.get_first_child ()) != null) box.remove (c);
                foreach (var act in rule.actions) {
                    var ac = act;
                    var row = new Box (Orientation.HORIZONTAL, 6);
                    var d = new DropDown (new StringList (alabels), null);
                    for (int i = 0; i < aids.length; i++) if (aids[i] == ac.kind) d.selected = i;
                    d.notify["selected"].connect (() => ac.kind = aids[(int) d.selected]);
                    row.append (d);
                    var e = new Entry ();
                    e.hexpand = true;
                    e.text = ac.value;
                    e.placeholder_text = _("Folder, category or address when needed");
                    e.changed.connect (() => ac.value = e.text.strip ());
                    row.append (e);
                    var del = new Button.from_icon_name ("list-remove-symbolic");
                    del.add_css_class ("flat");
                    del.tooltip_text = _("Remove Action");
                    del.clicked.connect (() => {
                        rule.actions.remove (ac);
                        fill ();
                    });
                    row.append (del);
                    box.append (row);
                }
            };
            add.clicked.connect (() => {
                rule.actions.add (new RuleAction ("read", ""));
                fill ();
            });
            fill ();
            response.connect ((r) => {
                if (r != ConfirmDialog.Response.PRIMARY) return;
                rule.name = name.text.strip () != "" ? name.text.strip () : _("Quick Step");
                done ();
            });
        }

        private delegate void FillFn ();
    }

    public class TextItemsDialog : AppDialog {
        private LettereApp app;
        private ItemStore store;
        private PreferencesGroup group;
        private bool template;

        public TextItemsDialog (LettereApp app, ItemStore store, string title, bool template) {
            base (app, true);
            set_title (title);
            this.app = app;
            this.store = store;
            this.template = template;
            set_default_size (560, 560);
            var box = new Box (Orientation.VERTICAL, 12);
            box.margin_start = 16;
            box.margin_end = 16;
            box.margin_bottom = 16;
            group = new PreferencesGroup (null, template ? _("Templates start a message with prepared text. Save one from the composer with Insert, Save as Template.") : _("Choose which signature each account uses in its account settings."));
            var scroll = new ScrolledWindow ();
            scroll.vexpand = true;
            scroll.hscrollbar_policy = PolicyType.NEVER;
            scroll.child = group;
            box.append (scroll);
            var add = new Button.with_label (template ? _("New Template…") : _("New Signature…"));
            add.add_css_class ("pill");
            add.add_css_class ("suggested-action");
            add.halign = Align.END;
            add.clicked.connect (() => edit (null));
            box.append (add);
            content_box.append (box);
            fill ();
        }

        private void fill () {
            group.clear ();
            foreach (var it in store.items) {
                var item = it;
                var row = new ActionRow (it.name, Html.to_text (it.html).replace ("\n", " ").strip (), null);
                var editb = new Button.from_icon_name ("document-edit-symbolic");
                editb.add_css_class ("flat");
                editb.valign = Align.CENTER;
                editb.tooltip_text = _("Edit %s").printf (it.name);
                editb.clicked.connect (() => edit (item));
                row.add_suffix (editb);
                var del = new Button.from_icon_name ("user-trash-symbolic");
                del.add_css_class ("flat");
                del.valign = Align.CENTER;
                del.tooltip_text = _("Delete %s").printf (it.name);
                del.clicked.connect (() => {
                    store.remove (item.name);
                    fill ();
                });
                row.add_suffix (del);
                group.add_row (row);
            }
        }

        private void edit (NamedItem? existing) {
            var dlg = new ConfirmDialog (app, existing == null ? (template ? _("New Template") : _("New Signature")) : existing.name, null, null, _("Save"), ConfirmDialog.ActionStyle.SUGGESTED);
            dlg.transient_for = this;
            dlg.modal = true;
            var g = new PreferencesGroup ();
            var name = new EntryRow (_("Name"));
            name.text = existing != null ? existing.name : "";
            g.add_row (name);
            EntryRow? subj = null;
            if (template) {
                subj = new EntryRow (_("Subject"));
                subj.text = existing != null ? existing.subject : "";
                g.add_row (subj);
            }
            dlg.custom_area.append (g);
            var editor = new HtmlEditor (app);
            editor.set_size_request (480, 240);
            if (existing != null) editor.set_html (existing.html);
            var frame = new Box (Orientation.VERTICAL, 0);
            frame.add_css_class ("lettere-compose-card");
            frame.overflow = Overflow.HIDDEN;
            var bar = new Box (Orientation.HORIZONTAL, 2);
            string[,] tools = { { "format-text-bold-symbolic", "Bold", _("Bold") }, { "format-text-italic-symbolic", "Italic", _("Italic") }, { "format-text-underline-symbolic", "Underline", _("Underline") }, { "insert-link-symbolic", "CreateLink", _("Link") } };
            for (int i = 0; i < tools.length[0]; i++) {
                string cmd = tools[i, 1];
                var b = new Button.from_icon_name (tools[i, 0]);
                b.add_css_class ("flat");
                b.tooltip_text = tools[i, 2];
                b.clicked.connect (() => {
                    if (cmd == "CreateLink") editor.command (cmd, "https://");
                    else editor.command (cmd);
                });
                bar.append (b);
            }
            var img = new Button.from_icon_name ("insert-image-symbolic");
            img.add_css_class ("flat");
            img.tooltip_text = _("Insert Picture");
            img.clicked.connect (() => {
                var fd = new FileDialog ();
                fd.open.begin (dlg, null, (o, r) => {
                    try {
                        var f = fd.open.end (r);
                        if (f != null) editor.insert_image.begin (f);
                    } catch (Error e) {
                    }
                });
            });
            bar.append (img);
            frame.append (bar);
            frame.append (editor);
            dlg.custom_area.append (frame);
            dlg.response.connect ((r) => {
                if (r != ConfirmDialog.Response.PRIMARY || name.text.strip () == "") return;
                editor.get_html.begin ((o, res) => {
                    string html = editor.get_html.end (res);
                    if (existing != null && existing.name != name.text.strip ()) store.items.remove (existing);
                    var it = store.put (name.text.strip ());
                    it.html = html;
                    if (subj != null) it.subject = subj.text;
                    store.save ();
                    fill ();
                });
            });
            dlg.open_dialog ();
        }
    }

    public class PickItemDialog : AppDialog {
        public signal void picked (NamedItem item);

        public PickItemDialog (LettereApp app, ItemStore store, string title) {
            base (app, true);
            set_title (title);
            set_default_size (420, 420);
            var group = new PreferencesGroup ();
            foreach (var it in store.items) {
                var item = it;
                var row = new ActionRow (it.name, it.subject, null);
                row.activatable = true;
                row.activated.connect (() => {
                    picked (item);
                    close_dialog ();
                });
                group.add_row (row);
            }
            var scroll = new ScrolledWindow ();
            scroll.vexpand = true;
            scroll.child = group;
            scroll.margin_start = 16;
            scroll.margin_end = 16;
            scroll.margin_bottom = 16;
            content_box.append (scroll);
        }
    }

    public class SweepDialog : ConfirmDialog {
        public signal void done (int count);

        public SweepDialog (LettereApp app, MessageInfo m) {
            base (app, _("Sweep Messages from %s").printf (m.sender_display), null, _("Clean up everything this sender left in the folder."), _("Sweep"), ConfirmDialog.ActionStyle.DESTRUCTIVE);
            modal = true;
            var f = app.store.folder (m.folder);
            var all = f != null ? app.store.by_sender (m.account, f.id, m.sender_email) : new Gee.ArrayList<MessageInfo> ();
            string[] choices = { _("Delete all of them"), _("Keep only the latest, delete the rest"), _("Delete those older than 10 days"), _("Archive all of them") };
            var sel = new SelectionRow (_("What to Do"), choices, choices[0]);
            sel.selected.connect ((v) => {
                sel.current_value = v;
                sel.expanded = false;
            });
            var always = new SwitchRow (_("Do This for New Messages Too"), _("Creates a rule for this sender"), false);
            var count = new ActionRow (ngettext ("%d message from this sender here", "%d messages from this sender here", all.size).printf (all.size), null, null);
            var g = new PreferencesGroup ();
            g.add_row (count);
            g.add_row (sel);
            g.add_row (always);
            custom_area.append (g);
            response.connect ((r) => {
                if (r != ConfirmDialog.Response.PRIMARY) return;
                var s = app.syncs[m.account];
                if (s == null || all.size == 0) return;
                var targets = new Gee.ArrayList<MessageInfo> ();
                int idx = 0;
                for (int i = 0; i < choices.length; i++) if (choices[i] == sel.current_value) idx = i;
                int64 cutoff = new DateTime.now_utc ().to_unix () - 10 * 86400;
                for (int i = 0; i < all.size; i++) {
                    if (idx == 1 && i == 0) continue;
                    if (idx == 2 && all[i].date >= cutoff) continue;
                    targets.add (all[i]);
                }
                if (always.active) {
                    var rule = new Rule ();
                    rule.name = _("Sweep %s").printf (m.sender_display);
                    rule.account = m.account;
                    rule.conditions.add (new RuleCondition ("from", "contains", m.sender_email));
                    rule.actions.add (new RuleAction (idx == 3 ? "archive" : "delete", ""));
                    app.rules.add (rule);
                }
                var actions = new Gee.ArrayList<RuleAction> ();
                actions.add (new RuleAction (idx == 3 ? "archive" : "delete", ""));
                app.execute.begin (s, targets, actions);
                done (targets.size);
            });
        }
    }

    public class SourceDialog : AppDialog {
        public SourceDialog (LettereApp app, uint8[] raw, string subject) {
            base (app, true);
            set_title (_("Source of %s").printf (subject != "" ? subject : _("(No Subject)")));
            set_default_size (800, 640);
            var tv = new TextView ();
            tv.editable = false;
            tv.monospace = true;
            tv.wrap_mode = WrapMode.CHAR;
            tv.buffer.text = Mime.bytes_to_string (raw);
            tv.update_property (AccessibleProperty.LABEL, _("Message Source"), -1);
            var scroll = new ScrolledWindow ();
            scroll.vexpand = true;
            scroll.child = tv;
            scroll.margin_start = 16;
            scroll.margin_end = 16;
            scroll.margin_bottom = 16;
            content_box.append (scroll);
        }
    }

    public class AutoReplyDialog : ConfirmDialog {
        private AccountSync sync;
        private SwitchRow enabled;
        private EntryRow subject;
        private TextView message;
        private TextView external;
        private SwitchRow outside;
        private SwitchRow scheduled;
        private int64 start;
        private int64 end;
        private ActionRow start_row;
        private ActionRow end_row;
        private LettereApp app;

        public AutoReplyDialog (LettereApp app, AccountSync sync) {
            base (app, _("Automatic Replies"), null, _("Answers people who write to %s while you are away.").printf (sync.account.email), _("Save"), ConfirmDialog.ActionStyle.SUGGESTED);
            this.app = app;
            this.sync = sync;
            modal = true;
            var g = new PreferencesGroup ();
            enabled = new SwitchRow (_("Send Automatic Replies"), null, false);
            g.add_row (enabled);
            scheduled = new SwitchRow (_("Only During This Time"), null, false);
            g.add_row (scheduled);
            start_row = new ActionRow (_("From"), "", null);
            start_row.activatable = true;
            start_row.activated.connect (() => pick (true));
            g.add_row (start_row);
            end_row = new ActionRow (_("Until"), "", null);
            end_row.activatable = true;
            end_row.activated.connect (() => pick (false));
            g.add_row (end_row);
            subject = new EntryRow (_("Subject"));
            g.add_row (subject);
            outside = new SwitchRow (_("Also Reply to People Outside Your Organization"), null, true);
            g.add_row (outside);
            custom_area.append (g);
            message = text_box (_("Reply"));
            external = text_box (_("Reply to People Outside Your Organization"));
            scheduled.bind_property ("active", start_row, "sensitive", BindingFlags.SYNC_CREATE);
            scheduled.bind_property ("active", end_row, "sensitive", BindingFlags.SYNC_CREATE);
            var now = new DateTime.now_local ();
            start = now.to_unix ();
            end = now.add_days (7).to_unix ();
            show_times ();
            primary_sensitive = false;
            load.begin ();
            response.connect ((r) => {
                if (r == ConfirmDialog.Response.PRIMARY) save.begin ();
            });
        }

        private TextView text_box (string label) {
            var l = new Label (label);
            l.xalign = 0;
            l.add_css_class ("heading");
            l.margin_top = 8;
            custom_area.append (l);
            var tv = new TextView ();
            tv.wrap_mode = WrapMode.WORD_CHAR;
            tv.top_margin = 8;
            tv.left_margin = 8;
            tv.right_margin = 8;
            tv.add_css_class ("lettere-compose-body");
            tv.update_property (AccessibleProperty.LABEL, label, -1);
            var sc = new ScrolledWindow ();
            sc.min_content_height = 90;
            sc.child = tv;
            sc.add_css_class ("lettere-compose-card");
            custom_area.append (sc);
            return tv;
        }

        private void show_times () {
            start_row.subtitle = format_full (start);
            end_row.subtitle = format_full (end);
        }

        private void pick (bool is_start) {
            var dlg = new WhenDialog (app, is_start ? _("From") : _("Until"), is_start ? start : end, _("Choose"));
            dlg.transient_for = this;
            dlg.chosen.connect ((t) => {
                if (is_start) start = t;
                else end = t;
                show_times ();
            });
            dlg.open_dialog ();
        }

        private async void load () {
            try {
                yield sync.ensure ();
                var r = yield sync.backend.get_auto_reply ();
                enabled.active = r.enabled;
                subject.text = r.subject;
                message.buffer.text = r.message;
                external.buffer.text = r.external_message;
                outside.active = r.external;
                if (r.start > 0 && r.end > 0) {
                    scheduled.active = true;
                    start = r.start;
                    end = r.end;
                    show_times ();
                }
                primary_sensitive = true;
            } catch (Error e) {
                message.buffer.text = "";
                primary_sensitive = true;
                app.toast (_("Could not read the automatic replies: %s").printf (e.message), null, null);
            }
        }

        private async void save () {
            var r = new AutoReply ();
            r.enabled = enabled.active;
            r.subject = subject.text;
            r.message = message.buffer.text;
            r.external_message = external.buffer.text;
            r.external = outside.active;
            if (scheduled.active) {
                r.start = start;
                r.end = end;
            }
            try {
                yield sync.ensure ();
                yield sync.backend.set_auto_reply (r);
                app.toast (r.enabled ? _("Automatic replies are on") : _("Automatic replies are off"), null, null);
            } catch (Error e) {
                app.toast (_("Could not save the automatic replies: %s").printf (e.message), null, null);
            }
        }
    }

    public class MergeDialog : ConfirmDialog {
        private LettereApp app;
        private Account account;
        private MergeTable? table;
        private Label info;
        private EntryRow subject;
        private HtmlEditor editor;
        private Label preview;
        private SwitchRow spread;

        public MergeDialog (LettereApp app, Account account) {
            base (app, _("Mail Merge"), null, _("Send one personal message to each person in a list. Write {{Name}} or any column name where the value goes."), _("Send"), ConfirmDialog.ActionStyle.SUGGESTED);
            this.app = app;
            this.account = account;
            modal = true;
            var g = new PreferencesGroup ();
            var pick = new ActionRow (_("Recipients"), _("A CSV file or a group from Contacts"), null);
            var csv = new Button.with_label (_("Choose File…"));
            csv.valign = Align.CENTER;
            csv.clicked.connect (() => choose_csv ());
            pick.add_suffix (csv);
            var group_btn = new Button.with_label (_("Contacts Group…"));
            group_btn.valign = Align.CENTER;
            group_btn.clicked.connect (() => choose_group ());
            pick.add_suffix (group_btn);
            g.add_row (pick);
            subject = new EntryRow (_("Subject"));
            g.add_row (subject);
            spread = new SwitchRow (_("Send One Every Few Seconds"), _("Gentler on servers that limit how fast you send"), true);
            g.add_row (spread);
            custom_area.append (g);
            info = new Label (_("No recipients yet"));
            info.xalign = 0;
            info.add_css_class ("dim-label");
            custom_area.append (info);
            editor = new HtmlEditor (app);
            editor.set_size_request (520, 220);
            editor.set_html ("<p>" + Html.escape (_("Dear {{Name}},")) + "</p><p><br></p>");
            editor.changed.connect (() => update_preview.begin ());
            var frame = new Box (Orientation.VERTICAL, 0);
            frame.add_css_class ("lettere-compose-card");
            frame.overflow = Overflow.HIDDEN;
            frame.append (editor);
            custom_area.append (frame);
            preview = new Label ("");
            preview.xalign = 0;
            preview.wrap = true;
            preview.add_css_class ("caption");
            custom_area.append (preview);
            primary_sensitive = false;
            response.connect ((r) => {
                if (r == ConfirmDialog.Response.PRIMARY) send.begin ();
            });
        }

        private void set_table (MergeTable t) {
            table = t;
            string col = t.email_column ();
            info.label = col == "" ? _("The list has no email column") : ngettext ("%d recipient, fields: %s", "%d recipients, fields: %s", t.rows.size).printf (t.rows.size, string.joinv (", ", t.columns.to_array ()));
            primary_sensitive = col != "" && t.rows.size > 0;
            update_preview.begin ();
        }

        private void choose_csv () {
            var fd = new FileDialog ();
            fd.title = _("Choose the Recipients");
            fd.open.begin (this, null, (o, r) => {
                try {
                    var f = fd.open.end (r);
                    if (f == null) return;
                    uint8[] data;
                    string etag;
                    f.load_contents (null, out data, out etag);
                    set_table (MergeTable.from_csv (Mime.bytes_to_string (data)));
                } catch (Error e) {
                }
            });
        }

        private void choose_group () {
            app.contacts.load ();
            if (app.contacts.groups.size == 0) {
                app.toast (_("Contacts has no groups. Give some contacts a category in Contacts first."), null, null);
                return;
            }
            var pop = new Popover ();
            var box = new Box (Orientation.VERTICAL, 0);
            foreach (var g in app.contacts.groups) {
                var grp = g;
                var b = new Button.with_label ("%s (%d)".printf (g.name, g.members.size));
                b.add_css_class ("flat");
                b.clicked.connect (() => {
                    pop.popdown ();
                    var t = new MergeTable ();
                    t.columns.add ("Name");
                    t.columns.add ("Email");
                    foreach (var m in grp.members) {
                        var row = new Gee.HashMap<string, string> ();
                        row["name"] = m.name;
                        row["email"] = m.email;
                        t.rows.add (row);
                    }
                    set_table (t);
                });
                box.append (b);
            }
            pop.child = box;
            pop.set_parent (info);
            pop.popup ();
        }

        private async void update_preview () {
            if (table == null || table.rows.size == 0) return;
            string html = yield editor.get_html ();
            var first = table.rows[0];
            preview.label = _("Preview for %s: %s").printf (first[table.email_column ()] ?? "", Html.to_text (MergeTable.fill (html, first, true)).replace ("\n", " ").strip ());
        }

        private async void send () {
            if (table == null) return;
            string html = yield editor.get_html ();
            string col = table.email_column ();
            int64 at = new DateTime.now_utc ().to_unix () + app.settings.get_int ("send-delay");
            int n = 0;
            foreach (var row in table.rows) {
                string email = row[col] ?? "";
                if (!email.contains ("@")) continue;
                var b = new MessageBuilder ();
                b.from = account.address ();
                b.to.add (new Address (row["name"] ?? "", email));
                b.subject = MergeTable.fill (subject.text, row, false);
                string body = MergeTable.fill (html, row, true);
                string cleaned;
                HtmlEditor.extract_images (body, out cleaned, b.inline_images, "lettere");
                b.html = HtmlEditor.wrap_document (cleaned);
                b.text = Html.to_text (cleaned);
                app.queue_message (account, b, null, at);
                if (spread.active) at += 5;
                n++;
            }
            app.toast (ngettext ("%d message queued in the Outbox", "%d messages queued in the Outbox", n).printf (n), null, null);
        }
    }
}
