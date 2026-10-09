namespace Singularity.Apps.Lettere {

    public class GraphBackend : MailBackend {
        public override bool concurrent_bodies {
            get { return true; }
        }
        private unowned AccountSync owner;
        private ApiClient api;
        private bool connected;

        private const string SELECT = "id,subject,from,toRecipients,ccRecipients,receivedDateTime,internetMessageId,conversationId,isRead,flag,hasAttachments,categories,importance,inferenceClassification,isDraft,parentFolderId";

        public GraphBackend (AccountSync owner) {
            this.owner = owner;
            this.account = owner.account;
            this.store = owner.store;
            api = new ApiClient (owner);
        }

        public override bool online {
            get { return connected; }
        }

        public override bool sends_mail {
            get { return true; }
        }

        public override bool saves_sent {
            get { return true; }
        }

        public override bool supports_rules {
            get { return true; }
        }

        public override bool supports_auto_reply {
            get { return true; }
        }

        public override string protocol_name {
            owned get { return "Microsoft Graph"; }
        }

        private string root {
            owned get {
                string u = account.api_url != "" ? account.api_url : "https://graph.microsoft.com/v1.0/";
                return u.has_suffix ("/") ? u : u + "/";
            }
        }

        private static string owner_of (string path) {
            int bar = path.index_of_char ('|');
            return bar > 0 ? "users/" + Uri.escape_string (path.substring (0, bar), "@", false) + "/" : "me/";
        }

        private static string id_of (string path) {
            int bar = path.index_of_char ('|');
            return bar > 0 ? path.substring (bar + 1) : path;
        }

        private string folder_url (Folder f) {
            return root + owner_of (f.path) + "mailFolders/" + Uri.escape_string (id_of (f.path), null, false);
        }

        private string message_url (Folder f, string id) {
            return root + owner_of (f.path) + "messages/" + Uri.escape_string (id, null, false);
        }

        public override async void connect () throws Error {
            yield api.json ("GET", root + "me/mailFolders/inbox?$select=id");
            connected = true;
        }

        public override void disconnect () {
            connected = false;
        }

        private async void collect_folders (string url, string owner_prefix, string parent, Gee.Map<string, string> roles, Gee.List<RemoteFolder> into, bool shared) throws Error {
            string? next = url;
            while (next != null) {
                var node = yield api.json ("GET", next);
                var o = node.get_object ();
                next = Js.str (o, "@odata.nextLink") != "" ? Js.str (o, "@odata.nextLink") : null;
                var values = Js.arr (o, "value");
                if (values == null) break;
                foreach (var n in values.get_elements ()) {
                    var fo = n.get_object ();
                    string id = Js.str (fo, "id");
                    var r = new RemoteFolder ();
                    r.path = owner_prefix + id;
                    r.name = Js.str (fo, "displayName");
                    r.parent = parent;
                    r.role = shared ? "" : (roles[id] ?? "");
                    r.shared = shared;
                    into.add (r);
                    if (Js.num (fo, "childFolderCount") > 0) {
                        string base_url = root + (owner_prefix != "" ? "users/" + Uri.escape_string (owner_prefix.substring (0, owner_prefix.length - 1), "@", false) + "/" : "me/");
                        yield collect_folders (base_url + "mailFolders/" + Uri.escape_string (id, null, false) + "/childFolders?$top=100", owner_prefix, r.path, roles, into, shared);
                    }
                }
            }
        }

        public override async Gee.List<RemoteFolder> list_folders () throws Error {
            var roles = new Gee.HashMap<string, string> ();
            string[,] wellknown = { { "inbox", "inbox" }, { "sentitems", "sent" }, { "drafts", "drafts" }, { "deleteditems", "trash" }, { "junkemail", "junk" }, { "archive", "archive" } };
            for (int i = 0; i < wellknown.length[0]; i++) {
                try {
                    var n = yield api.json ("GET", root + "me/mailFolders/" + wellknown[i, 0] + "?$select=id");
                    roles[Js.str (n.get_object (), "id")] = wellknown[i, 1];
                } catch (MailError.SERVER e) {
                }
            }
            var list = new Gee.ArrayList<RemoteFolder> ();
            yield collect_folders (root + "me/mailFolders?$top=100", "", "", roles, list, false);
            foreach (string mb in account.shared_mailboxes ()) {
                try {
                    yield collect_folders (root + "users/" + Uri.escape_string (mb, "@", false) + "/mailFolders?$top=100", mb + "|", "", roles, list, true);
                } catch (Error e) {
                    warning ("lettere: shared mailbox %s: %s", mb, e.message);
                }
            }
            return list;
        }

        public override async Gee.List<RemoteFolder> open_shared (string mailbox) throws Error {
            var list = new Gee.ArrayList<RemoteFolder> ();
            var roles = new Gee.HashMap<string, string> ();
            yield collect_folders (root + "users/" + Uri.escape_string (mailbox, "@", false) + "/mailFolders?$top=100", mailbox + "|", "", roles, list, true);
            account.add_shared_mailbox (mailbox);
            return list;
        }

        private static string addr (Json.Object? recipient) {
            var ea = Js.obj (recipient, "emailAddress");
            if (ea == null) return "";
            return new Address (Js.str (ea, "name"), Js.str (ea, "address")).to_header ();
        }

        private static string addrs (Json.Array? list) {
            if (list == null) return "";
            var parts = new Gee.ArrayList<string> ();
            foreach (var n in list.get_elements ()) {
                string a = addr (n.get_object ());
                if (a != "") parts.add (a);
            }
            return string.joinv (", ", parts.to_array ());
        }

        public static int flags_of (Json.Object o) {
            int flags = 0;
            if (Js.flag (o, "isRead")) flags |= MessageFlags.SEEN;
            if (Js.flag (o, "isDraft")) flags |= MessageFlags.DRAFT;
            string st = Js.str (Js.obj (o, "flag"), "flagStatus");
            if (st == "flagged") flags |= MessageFlags.FLAGGED;
            if (st == "complete") flags |= MessageFlags.FLAGGED | MessageFlags.COMPLETED;
            return flags;
        }

        public static string categories_of (Json.Object o) {
            var parts = new Gee.ArrayList<string> ();
            var a = Js.arr (o, "categories");
            if (a != null) foreach (var n in a.get_elements ()) parts.add (n.get_string ());
            return string.joinv ("\x1f", parts.to_array ());
        }

        public static string header_of (Json.Object o) {
            string imp = Js.str (o, "importance");
            string extra = imp == "high" ? "Importance: high\r\n" : (imp == "low" ? "Importance: low\r\n" : "");
            if (Js.flag (o, "hasAttachments")) extra += "Content-Type: multipart/mixed\r\n";
            return synth_header (addr (Js.obj (o, "from")), addrs (Js.arr (o, "toRecipients")), addrs (Js.arr (o, "ccRecipients")),
                Js.str (o, "subject"), Js.iso_time (Js.str (o, "receivedDateTime")), Js.str (o, "internetMessageId"), "", "", extra);
        }

        private void apply_item (Folder f, Json.Object o, bool notify, Gee.List<MessageInfo> fresh) {
            string id = Js.str (o, "id");
            if (o.has_member ("@removed")) {
                int64 lid = store.id_for_rid (f.id, id);
                if (lid != 0) store.delete_message (lid);
                return;
            }
            int64 existing = store.id_for_rid (f.id, id);
            int flags = flags_of (o);
            string cats = categories_of (o);
            if (existing != 0) {
                var m = store.message (existing);
                int keep = m != null ? (m.flags & (MessageFlags.PINNED | MessageFlags.ANSWERED | MessageFlags.FORWARDED)) : 0;
                store.set_state (existing, flags | keep, cats);
                return;
            }
            if (!o.has_member ("subject") && !o.has_member ("from")) return;
            int64 nid = store.insert_message (f, store.max_uid (f.id) + 1, flags, 0, header_of (o).data, Js.iso_time (Js.str (o, "receivedDateTime")), id, Js.str (o, "conversationId"), cats);
            string inference = Js.str (o, "inferenceClassification");
            if (f.role == "inbox" && inference != "") store.set_focus (nid, inference == "focused" ? 1 : 0);
            if (notify && (flags & MessageFlags.SEEN) == 0) {
                var m = store.message (nid);
                if (m != null) fresh.add (m);
            }
        }

        public override async void sync_folder (Folder f, bool notify, Gee.List<MessageInfo> fresh) throws Error {
            string url = f.sync_state != "" ? f.sync_state : folder_url (f) + "/messages/delta?$select=" + SELECT;
            bool initial = f.sync_state == "";
            var headers = new Gee.HashMap<string, string> ();
            headers["Prefer"] = "odata.maxpagesize=200";
            int pages = 0;
            while (true) {
                Json.Node node;
                try {
                    node = yield api.json ("GET", url, null, headers);
                } catch (MailError.SERVER e) {
                    if (!initial && e.message.contains ("Not found")) {
                        store.clear_folder (f.id);
                        f.sync_state = "";
                        store.set_folder_state (f);
                        return;
                    }
                    throw e;
                }
                var o = node.get_object ();
                var values = Js.arr (o, "value");
                store.begin ();
                if (values != null) foreach (var n in values.get_elements ()) apply_item (f, n.get_object (), notify && !initial, fresh);
                store.commit ();
                string next = Js.str (o, "@odata.nextLink");
                string delta = Js.str (o, "@odata.deltaLink");
                if (delta != "") {
                    f.sync_state = delta;
                    store.set_folder_state (f);
                    break;
                }
                if (next == "" || ++pages > 50) break;
                url = next;
            }
        }

        public override async void prefetch (Folder f, int limit) throws Error {
            foreach (var m in store.missing_body_messages (f.id, max_body_size, limit)) {
                try {
                    var data = yield fetch_body (f, m);
                    if (data != null) store.set_body (m.id, data);
                } catch (MailError.SERVER e) {
                }
            }
        }

        public override async uint8[]? fetch_body (Folder f, MessageInfo m) throws Error {
            var bytes = yield api.raw ("GET", message_url (f, m.ident) + "/$value");
            return bytes.get_data ();
        }

        private async void patch_each (Folder f, string ids, Json.Node body) throws Error {
            foreach (string id in ids.split (",")) {
                if (id == "") continue;
                yield api.json ("PATCH", message_url (f, id), body);
            }
        }

        public override async void set_flags (Folder f, string ids, int flag, bool on) throws Error {
            var b = new Json.Builder ();
            b.begin_object ();
            switch (flag) {
                case MessageFlags.SEEN:
                    b.set_member_name ("isRead").add_boolean_value (on);
                    break;
                case MessageFlags.FLAGGED:
                case MessageFlags.COMPLETED:
                    b.set_member_name ("flag").begin_object ();
                    b.set_member_name ("flagStatus").add_string_value (on ? (flag == MessageFlags.COMPLETED ? "complete" : "flagged") : (flag == MessageFlags.COMPLETED ? "flagged" : "notFlagged"));
                    b.end_object ();
                    break;
                default:
                    b.end_object ();
                    return;
            }
            b.end_object ();
            yield patch_each (f, ids, b.get_root ());
        }

        public override async void set_keywords (Folder f, string ids, string[] add, string[] remove) throws Error {
            foreach (string id in ids.split (",")) {
                if (id == "") continue;
                int64 lid = store.id_for_rid (f.id, id);
                var m = lid != 0 ? store.message (lid) : null;
                var b = new Json.Builder ();
                b.begin_object ();
                b.set_member_name ("categories").begin_array ();
                if (m != null) foreach (string c in m.categories ()) b.add_string_value (c);
                b.end_array ();
                b.end_object ();
                yield api.json ("PATCH", message_url (f, id), b.get_root ());
            }
        }

        private async void transfer (Folder f, string ids, Folder dest, string action) throws Error {
            foreach (string id in ids.split (",")) {
                if (id == "") continue;
                var b = new Json.Builder ();
                b.begin_object ();
                b.set_member_name ("destinationId").add_string_value (id_of (dest.path));
                b.end_object ();
                yield api.json ("POST", message_url (f, id) + "/" + action, b.get_root ());
            }
        }

        public override async void move (Folder f, string ids, Folder dest) throws Error {
            yield transfer (f, ids, dest, "move");
        }

        public override async void copy (Folder f, string ids, Folder dest) throws Error {
            yield transfer (f, ids, dest, "copy");
        }

        public override async void expunge (Folder f, string ids) throws Error {
            foreach (string id in ids.split (",")) {
                if (id == "") continue;
                if (f.role == "trash") yield api.json ("POST", message_url (f, id) + "/permanentDelete");
                else yield api.raw ("DELETE", message_url (f, id));
            }
        }

        public override async string append (Folder f, string flags, uint8[] raw) throws Error {
            var reply = yield api.raw ("POST", root + owner_of (f.path) + "mailFolders/" + Uri.escape_string (id_of (f.path), null, false) + "/messages", "text/plain", new Bytes (Base64.encode (raw).data));
            var o = Js.parse (Mime.bytes_to_string (reply.get_data ())).get_object ();
            string id = Js.str (o, "id");
            if (flags.contains ("\\Seen") && id != "") {
                try {
                    yield set_flags (f, id, MessageFlags.SEEN, true);
                } catch (Error e) {
                }
            }
            return id;
        }

        public override async RemoteFolder create_folder (string name, Folder? parent) throws Error {
            var b = new Json.Builder ();
            b.begin_object ();
            b.set_member_name ("displayName").add_string_value (name);
            b.end_object ();
            string url = parent != null ? folder_url (parent) + "/childFolders" : root + "me/mailFolders";
            var node = yield api.json ("POST", url, b.get_root ());
            var r = new RemoteFolder ();
            string prefix = parent != null && parent.path.contains ("|") ? parent.path.substring (0, parent.path.index_of_char ('|') + 1) : "";
            r.path = prefix + Js.str (node.get_object (), "id");
            r.name = name;
            r.parent = parent != null ? parent.path : "";
            return r;
        }

        public override async void rename_folder (Folder f, string name) throws Error {
            var b = new Json.Builder ();
            b.begin_object ();
            b.set_member_name ("displayName").add_string_value (name);
            b.end_object ();
            yield api.json ("PATCH", folder_url (f), b.get_root ());
        }

        public override async void delete_folder (Folder f) throws Error {
            yield api.raw ("DELETE", folder_url (f));
        }

        public override async Gee.List<string> search (Folder f, SearchQuery q) throws Error {
            var list = new Gee.ArrayList<string> ();
            string kql = q.to_kql ();
            if (kql == "") return list;
            var headers = new Gee.HashMap<string, string> ();
            headers["ConsistencyLevel"] = "eventual";
            var node = yield api.json ("GET", folder_url (f) + "/messages?$select=id&$top=100&$search=" + Uri.escape_string ("\"" + kql.replace ("\"", "'") + "\"", null, false), null, headers);
            var values = Js.arr (node.get_object (), "value");
            if (values != null) foreach (var n in values.get_elements ()) list.add (Js.str (n.get_object (), "id"));
            return list;
        }

        public override async bool wait_changes (Cancellable stop) throws Error {
            return false;
        }

        public override async void send (uint8[] raw, string sender, Gee.List<string> recipients) throws Error {
            string url = root + "me/sendMail";
            string from = sender.down ();
            foreach (string mb in account.shared_mailboxes ()) {
                if (mb.down () == from) url = root + "users/" + Uri.escape_string (mb, "@", false) + "/sendMail";
            }
            yield api.raw ("POST", url, "text/plain", new Bytes (Base64.encode (raw).data));
        }

        public override async AutoReply get_auto_reply () throws Error {
            var node = yield api.json ("GET", root + "me/mailboxSettings/automaticRepliesSetting");
            var o = node.get_object ();
            var r = new AutoReply ();
            string status = Js.str (o, "status");
            r.enabled = status != "disabled" && status != "";
            r.message = Html.to_text (Js.str (o, "internalReplyMessage"));
            r.external_message = Html.to_text (Js.str (o, "externalReplyMessage"));
            r.external = Js.str (o, "externalAudience") != "none";
            if (status == "scheduled") {
                r.start = Js.iso_time (Js.str (Js.obj (o, "scheduledStartDateTime"), "dateTime") + "Z");
                r.end = Js.iso_time (Js.str (Js.obj (o, "scheduledEndDateTime"), "dateTime") + "Z");
            }
            return r;
        }

        public override async void set_auto_reply (AutoReply r) throws Error {
            var b = new Json.Builder ();
            b.begin_object ();
            b.set_member_name ("automaticRepliesSetting").begin_object ();
            b.set_member_name ("status").add_string_value (!r.enabled ? "disabled" : (r.start > 0 && r.end > 0 ? "scheduled" : "alwaysEnabled"));
            b.set_member_name ("externalAudience").add_string_value (r.external ? "all" : "none");
            b.set_member_name ("internalReplyMessage").add_string_value (Html.from_text (r.message));
            b.set_member_name ("externalReplyMessage").add_string_value (Html.from_text (r.external_message != "" ? r.external_message : r.message));
            if (r.start > 0 && r.end > 0) {
                b.set_member_name ("scheduledStartDateTime").begin_object ();
                b.set_member_name ("dateTime").add_string_value (new DateTime.from_unix_utc (r.start).format ("%Y-%m-%dT%H:%M:%S"));
                b.set_member_name ("timeZone").add_string_value ("UTC");
                b.end_object ();
                b.set_member_name ("scheduledEndDateTime").begin_object ();
                b.set_member_name ("dateTime").add_string_value (new DateTime.from_unix_utc (r.end).format ("%Y-%m-%dT%H:%M:%S"));
                b.set_member_name ("timeZone").add_string_value ("UTC");
                b.end_object ();
            }
            b.end_object ();
            b.end_object ();
            yield api.json ("PATCH", root + "me/mailboxSettings", b.get_root ());
        }

        public override async void upload_rules (RuleStore rules) throws Error {
            string base_url = root + "me/mailFolders/inbox/messageRules";
            string known = store.get_value (account.id, "graph-rules") ?? "";
            foreach (string id in known.split ("\n")) {
                if (id == "") continue;
                try {
                    yield api.raw ("DELETE", base_url + "/" + Uri.escape_string (id, null, false));
                } catch (Error e) {
                }
            }
            var made = new Gee.ArrayList<string> ();
            int seq = 1;
            foreach (var r in rules.rules) {
                if (!r.enabled || !r.on_server || (r.account != "" && r.account != account.id)) continue;
                var node = yield api.json ("POST", base_url, rule_json (r, seq++));
                made.add (Js.str (node.get_object (), "id"));
            }
            store.set_value (account.id, "graph-rules", string.joinv ("\n", made.to_array ()));
        }

        private Json.Node rule_json (Rule r, int seq) {
            var b = new Json.Builder ();
            b.begin_object ();
            b.set_member_name ("displayName").add_string_value (r.name != "" ? r.name : _("Rule %d").printf (seq));
            b.set_member_name ("sequence").add_int_value (seq);
            b.set_member_name ("isEnabled").add_boolean_value (true);
            b.set_member_name ("conditions").begin_object ();
            foreach (var c in r.conditions) {
                switch (c.field) {
                    case "from":
                        b.set_member_name ("senderContains").begin_array ().add_string_value (c.value).end_array ();
                        break;
                    case "to":
                    case "recipients":
                        b.set_member_name ("recipientContains").begin_array ().add_string_value (c.value).end_array ();
                        break;
                    case "subject":
                        b.set_member_name ("subjectContains").begin_array ().add_string_value (c.value).end_array ();
                        break;
                    case "body":
                        b.set_member_name ("bodyContains").begin_array ().add_string_value (c.value).end_array ();
                        break;
                    case "has-attachment":
                        b.set_member_name ("hasAttachments").add_boolean_value (true);
                        break;
                    case "importance":
                        b.set_member_name ("importance").add_string_value (c.value);
                        break;
                    case "list-id":
                        b.set_member_name ("headerContains").begin_array ().add_string_value (c.value).end_array ();
                        break;
                }
            }
            b.end_object ();
            b.set_member_name ("actions").begin_object ();
            foreach (var a in r.actions) {
                switch (a.kind) {
                    case "move": {
                        var dest = store.folder_by_path (account.id, a.value);
                        if (dest != null) b.set_member_name ("moveToFolder").add_string_value (id_of (dest.path));
                        break;
                    }
                    case "copy": {
                        var dest = store.folder_by_path (account.id, a.value);
                        if (dest != null) b.set_member_name ("copyToFolder").add_string_value (id_of (dest.path));
                        break;
                    }
                    case "read":
                        b.set_member_name ("markAsRead").add_boolean_value (true);
                        break;
                    case "delete":
                        b.set_member_name ("delete").add_boolean_value (true);
                        break;
                    case "category":
                        b.set_member_name ("assignCategories").begin_array ().add_string_value (a.value).end_array ();
                        break;
                    case "forward":
                    case "redirect":
                        b.set_member_name (a.kind == "forward" ? "forwardTo" : "redirectTo").begin_array ();
                        b.begin_object ().set_member_name ("emailAddress").begin_object ().set_member_name ("address").add_string_value (a.value).end_object ().end_object ();
                        b.end_array ();
                        break;
                }
            }
            if (r.stop) b.set_member_name ("stopProcessingRules").add_boolean_value (true);
            b.end_object ();
            b.end_object ();
            return b.get_root ();
        }
    }
}
