namespace Singularity.Apps.Lettere {

    internal class LettereIntents : Object {
        private static string text (Json.Object args, string key) {
            return args.has_member (key) ? args.get_string_member (key) : "";
        }

        private static Json.Node msg_node (MessageInfo m, bool full = false) {
            var b = new Json.Builder ();
            b.begin_object ();
            b.set_member_name ("id").add_int_value (m.id);
            b.set_member_name ("account").add_string_value (m.account);
            b.set_member_name ("folder").add_int_value (m.folder);
            b.set_member_name ("subject").add_string_value (m.subject);
            b.set_member_name ("from").add_string_value (m.sender_name != "" ? "%s <%s>".printf (m.sender_name, m.sender_email) : m.sender_email);
            b.set_member_name ("date").add_string_value (new DateTime.from_unix_local (m.date).format_iso8601 ());
            b.set_member_name ("unread").add_boolean_value ((m.flags & MessageFlags.SEEN) == 0);
            b.set_member_name ("flagged").add_boolean_value ((m.flags & MessageFlags.FLAGGED) != 0);
            b.set_member_name ("attachments").add_boolean_value (m.has_attachment);
            if (full) {
                b.set_member_name ("to").add_string_value (m.to_list);
                b.set_member_name ("cc").add_string_value (m.cc_list);
            } else {
                b.set_member_name ("preview").add_string_value (m.preview);
            }
            b.end_object ();
            return b.get_root ();
        }

        private static Gee.ArrayList<int64?> id_list (Json.Object args) throws Error {
            if (!args.has_member ("ids")) throw new IOError.INVALID_ARGUMENT ("ids is required");
            var arr = args.get_array_member ("ids");
            var out_ids = new Gee.ArrayList<int64?> ();
            for (uint i = 0; i < arr.get_length (); i++) out_ids.add (arr.get_int_element (i));
            return out_ids;
        }

        private static Folder? resolve_folder (LettereApp app, Json.Object args, string key) {
            if (args.has_member (key) && args.get_member (key).get_value_type () == typeof (int64)) return app.store.folder (args.get_int_member (key));
            string role = text (args, key) != "" ? text (args, key) : "inbox";
            foreach (var a in app.accounts.accounts) {
                if (text (args, "account") != "" && a.id != text (args, "account")) continue;
                var f = app.store.folder_by_role (a.id, role);
                if (f != null) return f;
            }
            return null;
        }

        private static Json.Node done (Json.Node n, bool ok) {
            n.get_object ().set_boolean_member ("verified", ok);
            return n;
        }

        private static async Json.Node trash_all (LettereApp app, Gee.HashMap<string, Gee.ArrayList<MessageInfo>> by_account) throws Error {
            int moved = 0, total = 0;
            var b = new Json.Builder ();
            b.begin_object ();
            b.set_member_name ("folders");
            b.begin_array ();
            foreach (var e in by_account.entries) {
                var sync = app.syncs[e.key];
                var trash = app.store.folder_by_role (e.key, "trash");
                if (trash == null) trash = yield sync.ensure_folder ("trash", _("Trash"));
                if (trash == null) throw new IOError.NOT_FOUND ("the account %s has no Trash folder".printf (e.key));
                var keys = new Gee.HashSet<string> ();
                foreach (var m in e.value) keys.add (m.subject + "|" + m.message_id);
                total += e.value.size;
                yield sync.move (e.value, trash);
                var tids = new Gee.ArrayList<int64?> ();
                tids.add (trash.id);
                foreach (var m in app.store.list (tids, false, null, 5000, null)) if (keys.contains (m.subject + "|" + m.message_id)) moved++;
                b.add_string_value (trash.path);
            }
            b.end_array ();
            b.set_member_name ("requested").add_int_value (total);
            b.set_member_name ("in_trash").add_int_value (moved);
            b.end_object ();
            return done (b.get_root (), moved >= total);
        }

        internal static void install (LettereApp app) {
            app.agent.add_intent ("mail_folders", "List the mail accounts and their folders with id, path, role, unread and total counts.",
                "{\"type\":\"object\",\"properties\":{}}", Singularity.AppIntentRisk.READ, (args) => {
                    var b = new Json.Builder ();
                    b.begin_array ();
                    foreach (var a in app.accounts.accounts) {
                        b.begin_object ();
                        b.set_member_name ("account").add_string_value (a.id);
                        b.set_member_name ("address").add_string_value (a.address ().to_string ());
                        b.set_member_name ("folders");
                        b.begin_array ();
                        foreach (var f in app.store.folders (a.id)) {
                            app.store.count_folder (f);
                            b.begin_object ();
                            b.set_member_name ("id").add_int_value (f.id);
                            b.set_member_name ("path").add_string_value (f.path);
                            b.set_member_name ("name").add_string_value (f.name);
                            b.set_member_name ("role").add_string_value (f.role);
                            b.set_member_name ("unread").add_int_value (f.unread);
                            b.set_member_name ("total").add_int_value (f.total);
                            b.end_object ();
                        }
                        b.end_array ();
                        b.end_object ();
                    }
                    b.end_array ();
                    return b.get_root ();
                });
            app.agent.add_intent ("mail_list", "List the newest messages of a folder (a folder id from mail_folders, or a role such as inbox, sent, archive), newest first.",
                "{\"type\":\"object\",\"properties\":{\"folder\":{},\"account\":{\"type\":\"string\"},\"limit\":{\"type\":\"integer\"},\"unread_only\":{\"type\":\"boolean\"}}}",
                Singularity.AppIntentRisk.READ, (args) => {
                    var f = resolve_folder (app, args, "folder");
                    if (f == null) throw new IOError.NOT_FOUND ("no such folder; list them with mail_folders");
                    int limit = args.has_member ("limit") ? (int) args.get_int_member ("limit").clamp (1, 500) : 50;
                    var ids = new Gee.ArrayList<int64?> ();
                    ids.add (f.id);
                    var opts = new ListOptions ();
                    opts.limit = limit;
                    if (args.has_member ("unread_only") && args.get_boolean_member ("unread_only")) opts.filter = ListFilter.from_id ("unread");
                    var arr = new Json.Array ();
                    foreach (var m in app.store.list (ids, false, null, limit, opts)) arr.add_element (msg_node (m));
                    var b = new Json.Builder ();
                    b.begin_object ();
                    b.set_member_name ("folder").add_string_value (f.path);
                    b.end_object ();
                    var n = b.get_root ();
                    n.get_object ().set_array_member ("messages", arr);
                    return n;
                });
            app.agent.add_intent ("mail_read", "Read one message: headers, text and attachment names.",
                "{\"type\":\"object\",\"properties\":{\"id\":{\"type\":\"integer\"}},\"required\":[\"id\"]}",
                Singularity.AppIntentRisk.READ, (args) => {
                    var m = app.store.message (args.get_int_member ("id"));
                    if (m == null) throw new IOError.NOT_FOUND ("no message %lld".printf (args.get_int_member ("id")));
                    var n = msg_node (m, true);
                    var raw = app.store.body (m.id);
                    if (raw == null) {
                        n.get_object ().set_string_member ("text", m.preview);
                        n.get_object ().set_boolean_member ("downloaded", false);
                        return n;
                    }
                    var mime = new MimeMessage (raw);
                    string body = mime.body_text ();
                    if (body.length > 20000) body = body.substring (0, 20000);
                    n.get_object ().set_string_member ("text", body);
                    var att = new Json.Array ();
                    foreach (var a in mime.attachments) att.add_string_element (a.filename);
                    n.get_object ().set_array_member ("attachment_names", att);
                    return n;
                });
            app.agent.add_intent ("mail_search", "Search every downloaded message by words, sender or subject.",
                "{\"type\":\"object\",\"properties\":{\"query\":{\"type\":\"string\"},\"limit\":{\"type\":\"integer\"}},\"required\":[\"query\"]}",
                Singularity.AppIntentRisk.READ, (args) => {
                    int limit = args.has_member ("limit") ? (int) args.get_int_member ("limit").clamp (1, 200) : 30;
                    var hits = app.store.search (text (args, "query"));
                    var list = new Gee.ArrayList<MessageInfo> ();
                    foreach (var id in hits) {
                        var m = app.store.message (id);
                        if (m != null) list.add (m);
                    }
                    list.sort ((a, b) => a.date > b.date ? -1 : (a.date < b.date ? 1 : 0));
                    var arr = new Json.Array ();
                    for (int i = 0; i < list.size && i < limit; i++) arr.add_element (msg_node (list[i]));
                    var b = new Json.Builder ();
                    b.begin_object ();
                    b.set_member_name ("found").add_int_value (hits.size);
                    b.end_object ();
                    var n = b.get_root ();
                    n.get_object ().set_array_member ("messages", arr);
                    return n;
                });
            app.agent.add_intent ("mail_senders", "Summarise a folder: who writes most, by sender and by domain, with counts, unread counts and the message ids, so a whole folder can be read without listing every message.",
                "{\"type\":\"object\",\"properties\":{\"folder\":{},\"account\":{\"type\":\"string\"},\"scan\":{\"type\":\"integer\"}}}",
                Singularity.AppIntentRisk.READ, (args) => {
                    var f = resolve_folder (app, args, "folder");
                    if (f == null) throw new IOError.NOT_FOUND ("no such folder; list them with mail_folders");
                    int scan = args.has_member ("scan") ? (int) args.get_int_member ("scan").clamp (50, 5000) : 1500;
                    var ids = new Gee.ArrayList<int64?> ();
                    ids.add (f.id);
                    var opts = new ListOptions ();
                    opts.limit = scan;
                    var by_sender = new Gee.HashMap<string, Gee.ArrayList<MessageInfo>> ();
                    var by_domain = new Gee.HashMap<string, int> ();
                    int total = 0;
                    foreach (var m in app.store.list (ids, false, null, scan, opts)) {
                        total++;
                        string key = m.sender_email.down ();
                        if (!by_sender.has_key (key)) by_sender[key] = new Gee.ArrayList<MessageInfo> ();
                        by_sender[key].add (m);
                        int at = key.index_of_char ('@');
                        string dom = at >= 0 ? key.substring (at + 1) : key;
                        by_domain[dom] = (by_domain.has_key (dom) ? by_domain[dom] : 0) + 1;
                    }
                    var senders = new Gee.ArrayList<string> ();
                    senders.add_all (by_sender.keys);
                    senders.sort ((a, b) => by_sender[b].size - by_sender[a].size);
                    var b = new Json.Builder ();
                    b.begin_object ();
                    b.set_member_name ("folder").add_string_value (f.path);
                    b.set_member_name ("scanned").add_int_value (total);
                    b.set_member_name ("senders");
                    b.begin_array ();
                    for (int i = 0; i < senders.size && i < 80; i++) {
                        var list = by_sender[senders[i]];
                        int unread = 0;
                        foreach (var m in list) if ((m.flags & MessageFlags.SEEN) == 0) unread++;
                        b.begin_object ();
                        b.set_member_name ("sender").add_string_value (senders[i]);
                        b.set_member_name ("name").add_string_value (list[0].sender_name);
                        b.set_member_name ("count").add_int_value (list.size);
                        b.set_member_name ("unread").add_int_value (unread);
                        b.set_member_name ("example_subject").add_string_value (list[0].subject);
                        b.set_member_name ("ids");
                        b.begin_array ();
                        foreach (var m in list) b.add_int_value (m.id);
                        b.end_array ();
                        b.end_object ();
                    }
                    b.end_array ();
                    var domains = new Gee.ArrayList<string> ();
                    domains.add_all (by_domain.keys);
                    domains.sort ((a, c) => by_domain[c] - by_domain[a]);
                    b.set_member_name ("domains");
                    b.begin_object ();
                    for (int i = 0; i < domains.size && i < 40; i++) b.set_member_name (domains[i]).add_int_value (by_domain[domains[i]]);
                    b.end_object ();
                    b.end_object ();
                    return b.get_root ();
                });
            app.agent.add_async_intent ("mail_folder_create", "Create a folder in an account, optionally inside another folder (parent id). Answers with the new folder id.",
                "{\"type\":\"object\",\"properties\":{\"account\":{\"type\":\"string\"},\"name\":{\"type\":\"string\"},\"parent\":{\"type\":\"integer\"}},\"required\":[\"name\"]}",
                Singularity.AppIntentRisk.UNDOABLE, (args, reply) => {
                    string acc = text (args, "account");
                    if (acc == "" && app.accounts.accounts.size > 0) acc = app.accounts.accounts[0].id;
                    if (!app.syncs.has_key (acc)) {
                        reply (null, new IOError.NOT_FOUND ("no account %s".printf (acc)));
                        return;
                    }
                    Folder? parent = args.has_member ("parent") ? app.store.folder (args.get_int_member ("parent")) : null;
                    app.syncs[acc].create_folder.begin (text (args, "name"), parent, (o, r) => {
                        try {
                            var f = app.syncs[acc].create_folder.end (r);
                            if (f == null) throw new IOError.FAILED ("the server did not create the folder");
                            var b = new Json.Builder ();
                            b.begin_object ();
                            b.set_member_name ("id").add_int_value (f.id);
                            b.set_member_name ("path").add_string_value (f.path);
                            b.end_object ();
                            reply (done (b.get_root (), app.store.folder (f.id) != null), null);
                        } catch (Error e) {
                            reply (null, e);
                        }
                    });
                });
            app.agent.add_async_intent ("mail_move", "Move messages by id into a folder (folder id). Moving is undone by moving them back.",
                "{\"type\":\"object\",\"properties\":{\"ids\":{\"type\":\"array\",\"items\":{\"type\":\"integer\"}},\"folder\":{\"type\":\"integer\"}},\"required\":[\"ids\",\"folder\"]}",
                Singularity.AppIntentRisk.UNDOABLE, (args, reply) => {
                    try {
                        var ids = id_list (args);
                        var dest = app.store.folder (args.get_int_member ("folder"));
                        if (dest == null) throw new IOError.NOT_FOUND ("no folder %lld".printf (args.get_int_member ("folder")));
                        if (!app.syncs.has_key (dest.account)) throw new IOError.NOT_FOUND ("the account of that folder is not running");
                        var list = new Gee.ArrayList<MessageInfo> ();
                        foreach (var id in ids) {
                            var m = app.store.message (id);
                            if (m != null && m.account == dest.account) list.add (m);
                        }
                        if (list.size == 0) throw new IOError.NOT_FOUND ("none of these messages belongs to the account of that folder");
                        var subjects = new Gee.ArrayList<string> ();
                        foreach (var m in list) subjects.add (m.subject + "|" + m.message_id);
                        app.syncs[dest.account].move.begin (list, dest, (o, r) => {
                            app.syncs[dest.account].move.end (r);
                            int there = 0;
                            var dids = new Gee.ArrayList<int64?> ();
                            dids.add (dest.id);
                            foreach (var m in app.store.list (dids, false, null, 5000, null)) if (subjects.contains (m.subject + "|" + m.message_id)) there++;
                            var b = new Json.Builder ();
                            b.begin_object ();
                            b.set_member_name ("requested").add_int_value (list.size);
                            b.set_member_name ("in_folder").add_int_value (there);
                            b.set_member_name ("folder").add_string_value (dest.path);
                            b.end_object ();
                            reply (done (b.get_root (), there >= list.size), null);
                        });
                    } catch (Error e) {
                        reply (null, e);
                    }
                });
            app.agent.add_async_intent ("mail_delete", "Move messages by id to the Trash of their account. Undo by moving them back with mail_move.",
                "{\"type\":\"object\",\"properties\":{\"ids\":{\"type\":\"array\",\"items\":{\"type\":\"integer\"}}},\"required\":[\"ids\"]}",
                Singularity.AppIntentRisk.UNDOABLE, (args, reply) => {
                    try {
                        var by_account = new Gee.HashMap<string, Gee.ArrayList<MessageInfo>> ();
                        foreach (var id in id_list (args)) {
                            int64 mid = id;
                            var m = app.store.message (mid);
                            if (m == null) throw new IOError.NOT_FOUND ("no message %s".printf (mid.to_string ()));
                            if (!app.syncs.has_key (m.account)) throw new IOError.NOT_FOUND ("the account of message %s is not running".printf (mid.to_string ()));
                            if (!by_account.has_key (m.account)) by_account[m.account] = new Gee.ArrayList<MessageInfo> ();
                            by_account[m.account].add (m);
                        }
                        trash_all.begin (app, by_account, (o, r) => {
                            try {
                                reply (trash_all.end (r), null);
                            } catch (Error e) {
                                reply (null, e);
                            }
                        });
                    } catch (Error e) {
                        reply (null, e);
                    }
                });
            app.agent.add_intent ("mail_rule_create", "Create a mail rule. conditions are {field, op, value} with field from, to, cc, recipients, subject, body, list-id, has-attachment, importance, size-larger, size-smaller or all, and op contains, not-contains, is, starts, ends or regex. actions are {kind, value} with kind move, copy (value is a folder id or path), read, unread, flag, category, delete, junk, archive, forward or redirect (value is an address). It runs on new mail; run_now applies it to the inbox at once.",
                "{\"type\":\"object\",\"properties\":{\"name\":{\"type\":\"string\"},\"account\":{\"type\":\"string\"},\"match_all\":{\"type\":\"boolean\"},\"stop\":{\"type\":\"boolean\"},\"conditions\":{\"type\":\"array\",\"items\":{\"type\":\"object\"}},\"actions\":{\"type\":\"array\",\"items\":{\"type\":\"object\"}},\"run_now\":{\"type\":\"boolean\"}},\"required\":[\"name\",\"conditions\",\"actions\"]}",
                Singularity.AppIntentRisk.UNDOABLE, (args) => {
                    string[] fields = { "from", "to", "cc", "recipients", "subject", "body", "list-id", "has-attachment", "importance", "size-larger", "size-smaller", "all" };
                    string[] ops = { "contains", "not-contains", "is", "starts", "ends", "regex" };
                    string[] kinds = { "move", "copy", "read", "unread", "flag", "category", "delete", "junk", "archive", "forward", "redirect", "pin" };
                    var rule = new Rule ();
                    rule.name = text (args, "name");
                    rule.account = text (args, "account");
                    rule.match_all = !args.has_member ("match_all") || args.get_boolean_member ("match_all");
                    rule.stop = args.has_member ("stop") && args.get_boolean_member ("stop");
                    foreach (var node in args.get_array_member ("conditions").get_elements ()) {
                        var c = node.get_object ();
                        string field = text (c, "field"), op = text (c, "op") != "" ? text (c, "op") : "contains";
                        if (!(field in fields)) throw new IOError.INVALID_ARGUMENT ("unknown condition field %s".printf (field));
                        if (!(op in ops)) throw new IOError.INVALID_ARGUMENT ("unknown condition op %s".printf (op));
                        rule.conditions.add (new RuleCondition (field, op, text (c, "value")));
                    }
                    foreach (var node in args.get_array_member ("actions").get_elements ()) {
                        var a = node.get_object ();
                        string kind = text (a, "kind");
                        if (!(kind in kinds)) throw new IOError.INVALID_ARGUMENT ("unknown action %s".printf (kind));
                        string value = "";
                        if (a.has_member ("value")) {
                            var v = a.get_member ("value");
                            if (v.get_value_type () == typeof (int64)) {
                                var f = app.store.folder (v.get_int ());
                                if (f == null) throw new IOError.NOT_FOUND ("no folder %lld".printf (v.get_int ()));
                                value = f.path;
                                if (rule.account == "") rule.account = f.account;
                            } else {
                                value = v.get_string ();
                            }
                        }
                        if ((kind == "move" || kind == "copy" || kind == "forward" || kind == "redirect") && value == "") throw new IOError.INVALID_ARGUMENT ("%s needs a value".printf (kind));
                        rule.actions.add (new RuleAction (kind, value));
                    }
                    if (rule.conditions.size == 0 || rule.actions.size == 0) throw new IOError.INVALID_ARGUMENT ("a rule needs at least one condition and one action");
                    app.rules.add (rule);
                    if (args.has_member ("run_now") && args.get_boolean_member ("run_now")) {
                        foreach (var acc in app.accounts.accounts) {
                            if (rule.account != "" && acc.id != rule.account) continue;
                            var inbox = app.store.folder_by_role (acc.id, "inbox");
                            if (inbox != null) app.run_rules_now.begin (inbox);
                        }
                    }
                    var node = rule.to_json ();
                    node.get_object ().set_string_member ("summary", rule.describe ());
                    return done (node, app.rules.find (rule.id) != null);
                });
            app.agent.add_async_intent ("mail_flag", "Mark messages by id as read or unread (flag seen) or flagged for follow-up (flag flagged).",
                "{\"type\":\"object\",\"properties\":{\"ids\":{\"type\":\"array\",\"items\":{\"type\":\"integer\"}},\"flag\":{\"type\":\"string\",\"enum\":[\"seen\",\"flagged\"]},\"on\":{\"type\":\"boolean\"}},\"required\":[\"ids\",\"flag\"]}",
                Singularity.AppIntentRisk.UNDOABLE, (args, reply) => {
                    try {
                        var ids = id_list (args);
                        int flag = text (args, "flag") == "flagged" ? MessageFlags.FLAGGED : MessageFlags.SEEN;
                        bool on = !args.has_member ("on") || args.get_boolean_member ("on");
                        var by_acc = new Gee.HashMap<string, Gee.ArrayList<MessageInfo>> ();
                        foreach (var id in ids) {
                            var m = app.store.message (id);
                            if (m == null || !app.syncs.has_key (m.account)) continue;
                            if (!by_acc.has_key (m.account)) by_acc[m.account] = new Gee.ArrayList<MessageInfo> ();
                            by_acc[m.account].add (m);
                        }
                        if (by_acc.size == 0) throw new IOError.NOT_FOUND ("no such messages");
                        int pending = by_acc.size;
                        foreach (var acc in by_acc.keys) {
                            app.syncs[acc].set_flag.begin (by_acc[acc], flag, on, (o, r) => {
                                app.syncs[acc].set_flag.end (r);
                                if (--pending > 0) return;
                                int ok = 0;
                                foreach (var id in ids) {
                                    var m = app.store.message (id);
                                    if (m != null && (((m.flags & flag) != 0) == on)) ok++;
                                }
                                var b = new Json.Builder ();
                                b.begin_object ();
                                b.set_member_name ("changed").add_int_value (ok);
                                b.end_object ();
                                reply (done (b.get_root (), ok == ids.size), null);
                            });
                        }
                    } catch (Error e) {
                        reply (null, e);
                    }
                });
            app.agent.add_intent ("mail_prepare", "Prepare a message without sending it. The person reads it, edits it if needed and sends it from the card shown with the answer.",
                "{\"type\":\"object\",\"properties\":{\"to\":{\"type\":\"string\"},\"cc\":{\"type\":\"string\"},\"subject\":{\"type\":\"string\"},\"body\":{\"type\":\"string\"},\"account\":{\"type\":\"string\"}},\"required\":[\"to\"]}",
                Singularity.AppIntentRisk.READ, (args) => {
                    if (app.mail_service == null) throw new IOError.NOT_CONNECTED ("mail service unavailable");
                    var a = app.mail_service.sending_account (text (args, "account"));
                    if (a == null) throw new IOError.NOT_FOUND ("no mail account can send messages");
                    var from = a.address ();
                    var b = new Json.Builder ();
                    b.begin_object ();
                    b.set_member_name ("private").begin_object ();
                    b.set_member_name ("token").add_string_value (app.mail_service.prepare (a));
                    b.end_object ();
                    b.set_member_name ("account").add_string_value (a.id);
                    b.set_member_name ("from").add_string_value (from.to_string ());
                    b.set_member_name ("to").add_string_value (text (args, "to"));
                    b.set_member_name ("cc").add_string_value (text (args, "cc"));
                    b.set_member_name ("subject").add_string_value (text (args, "subject"));
                    b.set_member_name ("body").add_string_value (text (args, "body"));
                    b.end_object ();
                    return b.get_root ();
                });
        }
    }
}
