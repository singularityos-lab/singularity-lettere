namespace Singularity.Apps.Lettere {

    public class GmailBackend : MailBackend {
        public override bool concurrent_bodies {
            get { return true; }
        }
        private unowned AccountSync owner;
        private ApiClient api;
        private bool connected;
        private Gee.HashMap<string, string> label_names = new Gee.HashMap<string, string> ();
        private Gee.HashMap<string, string> label_ids = new Gee.HashMap<string, string> ();

        private const string METADATA = "metadataHeaders=From&metadataHeaders=To&metadataHeaders=Cc&metadataHeaders=Subject&metadataHeaders=Date&metadataHeaders=Message-ID&metadataHeaders=In-Reply-To&metadataHeaders=References&metadataHeaders=Content-Type&metadataHeaders=List-Unsubscribe&metadataHeaders=List-Unsubscribe-Post&metadataHeaders=List-Id&metadataHeaders=Importance&metadataHeaders=X-Priority&metadataHeaders=Disposition-Notification-To&metadataHeaders=Reply-To&metadataHeaders=Precedence";

        public GmailBackend (AccountSync owner) {
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
            owned get { return "Gmail"; }
        }

        private string root {
            owned get {
                string u = account.api_url != "" ? account.api_url : "https://gmail.googleapis.com/gmail/v1/users/me/";
                return u.has_suffix ("/") ? u : u + "/";
            }
        }

        private string upload_root {
            owned get {
                return root.replace ("/gmail/v1/", "/upload/gmail/v1/");
            }
        }

        public override async void connect () throws Error {
            var node = yield api.json ("GET", root + "profile");
            if (store.get_value (account.id, "gmail-history") == null) store.set_value (account.id, "gmail-history", Js.str (node.get_object (), "historyId"));
            connected = true;
        }

        public override void disconnect () {
            connected = false;
        }

        public static string role_of (string id) {
            switch (id) {
                case "INBOX": return "inbox";
                case "SENT": return "sent";
                case "DRAFT": return "drafts";
                case "TRASH": return "trash";
                case "SPAM": return "junk";
                case "ALL": return "archive";
            }
            return "";
        }

        public override async Gee.List<RemoteFolder> list_folders () throws Error {
            var node = yield api.json ("GET", root + "labels");
            var list = new Gee.ArrayList<RemoteFolder> ();
            label_names.clear ();
            label_ids.clear ();
            var labels = Js.arr (node.get_object (), "labels");
            var all = new RemoteFolder ();
            all.path = "ALL";
            all.name = _("All Mail");
            all.role = "archive";
            list.add (all);
            if (labels != null) {
                foreach (var n in labels.get_elements ()) {
                    var o = n.get_object ();
                    string id = Js.str (o, "id");
                    string name = Js.str (o, "name");
                    label_names[id] = name;
                    label_ids[name.down ()] = id;
                    string type = Js.str (o, "type");
                    if (type == "system" && role_of (id) == "") continue;
                    var r = new RemoteFolder ();
                    r.path = id;
                    r.delimiter = "/";
                    r.name = name.contains ("/") ? name.substring (name.last_index_of_char ('/') + 1) : name;
                    if (name.contains ("/")) {
                        string parent_name = name.substring (0, name.last_index_of_char ('/'));
                        foreach (var p in labels.get_elements ()) {
                            if (Js.str (p.get_object (), "name") == parent_name) r.parent = Js.str (p.get_object (), "id");
                        }
                    }
                    r.role = role_of (id);
                    list.add (r);
                }
            }
            return list;
        }

        private string label_query (Folder f) {
            if (f.path == "ALL") return "";
            return "labelIds=" + Uri.escape_string (f.path, null, false) + "&";
        }

        private async Gee.List<string> list_ids (Folder f, string query, int cap) throws Error {
            var ids = new Gee.ArrayList<string> ();
            string token = "";
            while (ids.size < cap) {
                string url = root + "messages?" + label_query (f) + "maxResults=500" + (query != "" ? "&q=" + Uri.escape_string (query, null, false) : "") + (token != "" ? "&pageToken=" + token : "") + (f.path == "TRASH" || f.path == "SPAM" ? "&includeSpamTrash=true" : "");
                var node = yield api.json ("GET", url);
                var o = node.get_object ();
                var msgs = Js.arr (o, "messages");
                if (msgs != null) foreach (var n in msgs.get_elements ()) ids.add (Js.str (n.get_object (), "id"));
                token = Js.str (o, "nextPageToken");
                if (token == "") break;
            }
            return ids;
        }

        public int flags_of (Json.Array? labels) {
            int flags = MessageFlags.SEEN;
            if (labels == null) return flags;
            foreach (var n in labels.get_elements ()) {
                switch (n.get_string ()) {
                    case "UNREAD": flags &= ~MessageFlags.SEEN; break;
                    case "STARRED": flags |= MessageFlags.FLAGGED; break;
                    case "DRAFT": flags |= MessageFlags.DRAFT; break;
                }
            }
            return flags;
        }

        public string categories_of (Json.Array? labels) {
            var parts = new Gee.ArrayList<string> ();
            if (labels == null) return "";
            foreach (var n in labels.get_elements ()) {
                string id = n.get_string ();
                if (!id.has_prefix ("Label_")) continue;
                string? name = label_names[id];
                if (name != null) parts.add (name);
            }
            return string.joinv ("\x1f", parts.to_array ());
        }

        private static int focus_of (Json.Array? labels) {
            if (labels == null) return -1;
            foreach (var n in labels.get_elements ()) {
                switch (n.get_string ()) {
                    case "CATEGORY_PERSONAL": return 1;
                    case "CATEGORY_PROMOTIONS":
                    case "CATEGORY_SOCIAL":
                    case "CATEGORY_UPDATES":
                    case "CATEGORY_FORUMS": return 0;
                }
            }
            return -1;
        }

        public static string header_of (Json.Object msg) {
            var sb = new StringBuilder ();
            var payload = Js.obj (msg, "payload");
            var headers = Js.arr (payload, "headers");
            if (headers != null) {
                foreach (var n in headers.get_elements ()) {
                    var h = n.get_object ();
                    sb.append (Js.str (h, "name") + ": " + Js.str (h, "value").replace ("\r\n", " ").replace ("\n", " ") + "\r\n");
                }
            }
            sb.append ("\r\n");
            return sb.str;
        }

        public override async void sync_folder (Folder f, bool notify, Gee.List<MessageInfo> fresh) throws Error {
            bool initial = f.sync_state == "";
            yield apply_history ();
            var ids = yield list_ids (f, "", 2000);
            var present = new Gee.HashSet<string> ();
            present.add_all (ids);
            var local = store.rid_map (f.id);
            store.begin ();
            foreach (var e in local.entries) {
                if (!present.contains (e.key)) store.delete_message (e.value);
            }
            store.commit ();
            foreach (string id in ids) {
                if (local.has_key (id)) continue;
                var node = yield api.json ("GET", root + "messages/" + id + "?format=metadata&" + METADATA);
                var o = node.get_object ();
                var labels = Js.arr (o, "labelIds");
                int flags = flags_of (labels);
                int64 date = Js.num (o, "internalDate") / 1000;
                int64 nid = store.insert_message (f, store.max_uid (f.id) + 1, flags, Js.num (o, "sizeEstimate"), header_of (o).data, date, id, Js.str (o, "threadId"), categories_of (labels));
                int focus = focus_of (labels);
                if (f.role == "inbox" && focus >= 0) store.set_focus (nid, focus);
                if (notify && !initial && (flags & MessageFlags.SEEN) == 0) {
                    var m = store.message (nid);
                    if (m != null) fresh.add (m);
                }
            }
            f.sync_state = "listed";
            store.set_folder_state (f);
        }

        private async void apply_history () throws Error {
            string? start = store.get_value (account.id, "gmail-history");
            if (start == null || start == "") return;
            string token = "";
            string latest = start;
            while (true) {
                Json.Node node;
                try {
                    node = yield api.json ("GET", root + "history?startHistoryId=" + start + (token != "" ? "&pageToken=" + token : ""));
                } catch (MailError.SERVER e) {
                    var profile = yield api.json ("GET", root + "profile");
                    store.set_value (account.id, "gmail-history", Js.str (profile.get_object (), "historyId"));
                    return;
                }
                var o = node.get_object ();
                latest = Js.str (o, "historyId", latest);
                var history = Js.arr (o, "history");
                if (history != null) {
                    foreach (var h in history.get_elements ()) {
                        var ho = h.get_object ();
                        foreach (string key in new string[] { "labelsAdded", "labelsRemoved" }) {
                            var changes = Js.arr (ho, key);
                            if (changes == null) continue;
                            foreach (var c in changes.get_elements ()) {
                                var msg = Js.obj (c.get_object (), "message");
                                update_labels (Js.str (msg, "id"), Js.arr (msg, "labelIds"));
                            }
                        }
                        var deleted = Js.arr (ho, "messagesDeleted");
                        if (deleted != null) {
                            foreach (var c in deleted.get_elements ()) {
                                string id = Js.str (Js.obj (c.get_object (), "message"), "id");
                                foreach (var f in store.folders (account.id)) {
                                    int64 lid = store.id_for_rid (f.id, id);
                                    if (lid != 0) store.delete_message (lid);
                                }
                            }
                        }
                    }
                }
                token = Js.str (o, "nextPageToken");
                if (token == "") break;
            }
            store.set_value (account.id, "gmail-history", latest);
        }

        private void update_labels (string id, Json.Array? labels) {
            if (id == "" || labels == null) return;
            int flags = flags_of (labels);
            string cats = categories_of (labels);
            foreach (var f in store.folders (account.id)) {
                int64 lid = store.id_for_rid (f.id, id);
                if (lid == 0) continue;
                var m = store.message (lid);
                int keep = m != null ? (m.flags & (MessageFlags.PINNED | MessageFlags.ANSWERED | MessageFlags.FORWARDED | MessageFlags.COMPLETED)) : 0;
                store.set_state (lid, flags | keep, cats);
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
            var node = yield api.json ("GET", root + "messages/" + m.ident + "?format=raw");
            return Js.from_b64url (Js.str (node.get_object (), "raw"));
        }

        private async void modify (string ids, string[] add, string[] remove) throws Error {
            var b = new Json.Builder ();
            b.begin_object ();
            b.set_member_name ("ids").begin_array ();
            foreach (string id in ids.split (",")) if (id != "") b.add_string_value (id);
            b.end_array ();
            b.set_member_name ("addLabelIds").begin_array ();
            foreach (string a in add) b.add_string_value (a);
            b.end_array ();
            b.set_member_name ("removeLabelIds").begin_array ();
            foreach (string r in remove) b.add_string_value (r);
            b.end_array ();
            b.end_object ();
            yield api.json ("POST", root + "messages/batchModify", b.get_root ());
        }

        public override async void set_flags (Folder f, string ids, int flag, bool on) throws Error {
            switch (flag) {
                case MessageFlags.SEEN:
                    if (on) yield modify (ids, {}, { "UNREAD" });
                    else yield modify (ids, { "UNREAD" }, {});
                    break;
                case MessageFlags.FLAGGED:
                    if (on) yield modify (ids, { "STARRED" }, {});
                    else yield modify (ids, {}, { "STARRED" });
                    break;
                case MessageFlags.JUNK:
                    if (on) yield modify (ids, { "SPAM" }, { "INBOX" });
                    break;
            }
        }

        private async string ensure_label (string name) throws Error {
            string? id = label_ids[name.down ()];
            if (id != null) return id;
            var b = new Json.Builder ();
            b.begin_object ();
            b.set_member_name ("name").add_string_value (name);
            b.set_member_name ("labelListVisibility").add_string_value ("labelShow");
            b.set_member_name ("messageListVisibility").add_string_value ("show");
            b.end_object ();
            var node = yield api.json ("POST", root + "labels", b.get_root ());
            string made = Js.str (node.get_object (), "id");
            label_ids[name.down ()] = made;
            label_names[made] = name;
            return made;
        }

        public override async void set_keywords (Folder f, string ids, string[] add, string[] remove) throws Error {
            string[] a = {};
            foreach (string n in add) a += yield ensure_label (n);
            string[] r = {};
            foreach (string n in remove) {
                string? id = label_ids[n.down ()];
                if (id != null) r += id;
            }
            yield modify (ids, a, r);
        }

        public override async void move (Folder f, string ids, Folder dest) throws Error {
            if (dest.path == "TRASH") {
                foreach (string id in ids.split (",")) if (id != "") yield api.json ("POST", root + "messages/" + id + "/trash");
                return;
            }
            string[] add = {};
            if (dest.path != "ALL") add += dest.path;
            string[] remove = {};
            if (f.path != "ALL") remove += f.path;
            if (f.path == "TRASH") {
                foreach (string id in ids.split (",")) if (id != "") yield api.json ("POST", root + "messages/" + id + "/untrash");
            }
            if (dest.path == "SPAM") remove += "INBOX";
            yield modify (ids, add, remove);
        }

        public override async void copy (Folder f, string ids, Folder dest) throws Error {
            if (dest.path == "ALL") return;
            yield modify (ids, { dest.path }, {});
        }

        public override async void expunge (Folder f, string ids) throws Error {
            foreach (string id in ids.split (",")) {
                if (id == "") continue;
                yield api.raw ("DELETE", root + "messages/" + id);
            }
        }

        public override async string append (Folder f, string flags, uint8[] raw) throws Error {
            var b = new Json.Builder ();
            b.begin_object ();
            b.set_member_name ("raw").add_string_value (Js.b64url (raw));
            b.set_member_name ("labelIds").begin_array ();
            if (f.path != "ALL") b.add_string_value (f.path);
            if (!flags.contains ("\\Seen")) b.add_string_value ("UNREAD");
            b.end_array ();
            b.end_object ();
            if (f.path == "DRAFT") {
                var db = new Json.Builder ();
                db.begin_object ();
                db.set_member_name ("message").begin_object ().set_member_name ("raw").add_string_value (Js.b64url (raw)).end_object ();
                db.end_object ();
                var dn = yield api.json ("POST", root + "drafts", db.get_root ());
                return Js.str (Js.obj (dn.get_object (), "message"), "id");
            }
            var node = yield api.json ("POST", root + "messages?internalDateSource=dateHeader", b.get_root ());
            return Js.str (node.get_object (), "id");
        }

        public override async RemoteFolder create_folder (string name, Folder? parent) throws Error {
            string full = parent != null && parent.path != "ALL" && label_names.has_key (parent.path) ? label_names[parent.path] + "/" + name : name;
            string id = yield ensure_label (full);
            var r = new RemoteFolder ();
            r.path = id;
            r.name = name;
            r.parent = parent != null ? parent.path : "";
            return r;
        }

        public override async void rename_folder (Folder f, string name) throws Error {
            string old = label_names[f.path] ?? f.name;
            string full = old.contains ("/") ? old.substring (0, old.last_index_of_char ('/') + 1) + name : name;
            var b = new Json.Builder ();
            b.begin_object ();
            b.set_member_name ("name").add_string_value (full);
            b.end_object ();
            yield api.json ("PATCH", root + "labels/" + f.path, b.get_root ());
        }

        public override async void delete_folder (Folder f) throws Error {
            yield api.raw ("DELETE", root + "labels/" + f.path);
        }

        public override async Gee.List<string> search (Folder f, SearchQuery q) throws Error {
            string gq = q.to_gmail ();
            if (gq == "") return new Gee.ArrayList<string> ();
            return yield list_ids (f, gq, 500);
        }

        public override async bool wait_changes (Cancellable stop) throws Error {
            return false;
        }

        public override async void send (uint8[] raw, string sender, Gee.List<string> recipients) throws Error {
            var b = new Json.Builder ();
            b.begin_object ();
            b.set_member_name ("raw").add_string_value (Js.b64url (raw));
            b.end_object ();
            yield api.json ("POST", root + "messages/send", b.get_root ());
        }

        public override async AutoReply get_auto_reply () throws Error {
            var node = yield api.json ("GET", root + "settings/vacation");
            var o = node.get_object ();
            var r = new AutoReply ();
            r.enabled = Js.flag (o, "enableAutoReply");
            r.subject = Js.str (o, "responseSubject");
            r.message = Js.str (o, "responseBodyPlainText");
            if (r.message == "") r.message = Html.to_text (Js.str (o, "responseBodyHtml"));
            r.external = !Js.flag (o, "restrictToContacts");
            r.start = Js.num (o, "startTime") / 1000;
            r.end = Js.num (o, "endTime") / 1000;
            return r;
        }

        public override async void set_auto_reply (AutoReply r) throws Error {
            var b = new Json.Builder ();
            b.begin_object ();
            b.set_member_name ("enableAutoReply").add_boolean_value (r.enabled);
            b.set_member_name ("responseSubject").add_string_value (r.subject);
            b.set_member_name ("responseBodyPlainText").add_string_value (r.message);
            b.set_member_name ("restrictToContacts").add_boolean_value (!r.external);
            if (r.start > 0) b.set_member_name ("startTime").add_int_value (r.start * 1000);
            if (r.end > 0) b.set_member_name ("endTime").add_int_value (r.end * 1000);
            b.end_object ();
            yield api.json ("PUT", root + "settings/vacation", b.get_root ());
        }

        public override async void upload_rules (RuleStore rules) throws Error {
            string known = store.get_value (account.id, "gmail-filters") ?? "";
            foreach (string id in known.split ("\n")) {
                if (id == "") continue;
                try {
                    yield api.raw ("DELETE", root + "settings/filters/" + id);
                } catch (Error e) {
                }
            }
            var made = new Gee.ArrayList<string> ();
            foreach (var r in rules.rules) {
                if (!r.enabled || !r.on_server || (r.account != "" && r.account != account.id)) continue;
                var b = new Json.Builder ();
                b.begin_object ();
                b.set_member_name ("criteria").begin_object ();
                var extra = new Gee.ArrayList<string> ();
                foreach (var c in r.conditions) {
                    switch (c.field) {
                        case "from": b.set_member_name ("from").add_string_value (c.value); break;
                        case "to":
                        case "recipients": b.set_member_name ("to").add_string_value (c.value); break;
                        case "subject": b.set_member_name ("subject").add_string_value (c.value); break;
                        case "body": extra.add ("\"" + c.value + "\""); break;
                        case "list-id": extra.add ("list:" + c.value); break;
                        case "has-attachment": b.set_member_name ("hasAttachment").add_boolean_value (true); break;
                        case "size-larger":
                            b.set_member_name ("size").add_int_value (SearchQuery.parse_size (c.value));
                            b.set_member_name ("sizeComparison").add_string_value ("larger");
                            break;
                    }
                }
                if (extra.size > 0) b.set_member_name ("query").add_string_value (string.joinv (" ", extra.to_array ()));
                b.end_object ();
                b.set_member_name ("action").begin_object ();
                var add = new Gee.ArrayList<string> ();
                var remove = new Gee.ArrayList<string> ();
                string forward = "";
                foreach (var a in r.actions) {
                    switch (a.kind) {
                        case "move":
                            add.add (a.value);
                            remove.add ("INBOX");
                            break;
                        case "copy": add.add (a.value); break;
                        case "archive": remove.add ("INBOX"); break;
                        case "read": remove.add ("UNREAD"); break;
                        case "flag": add.add ("STARRED"); break;
                        case "delete": add.add ("TRASH"); break;
                        case "junk": add.add ("SPAM"); break;
                        case "category": add.add (yield ensure_label (a.value)); break;
                        case "forward": forward = a.value; break;
                    }
                }
                b.set_member_name ("addLabelIds").begin_array ();
                foreach (string s in add) b.add_string_value (s);
                b.end_array ();
                b.set_member_name ("removeLabelIds").begin_array ();
                foreach (string s in remove) b.add_string_value (s);
                b.end_array ();
                if (forward != "") b.set_member_name ("forward").add_string_value (forward);
                b.end_object ();
                b.end_object ();
                var node = yield api.json ("POST", root + "settings/filters", b.get_root ());
                made.add (Js.str (node.get_object (), "id"));
            }
            store.set_value (account.id, "gmail-filters", string.joinv ("\n", made.to_array ()));
        }
    }
}
