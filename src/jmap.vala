namespace Singularity.Apps.Lettere {

    public class JmapBackend : MailBackend {
        private unowned AccountSync owner;
        private ApiClient api;
        private bool connected;
        private string api_url = "";
        private string download_url = "";
        private string upload_url = "";
        private string account_id = "";
        private string identity_id = "";
        private Gee.HashSet<string> capabilities = new Gee.HashSet<string> ();

        private const string CORE = "urn:ietf:params:jmap:core";
        private const string MAIL = "urn:ietf:params:jmap:mail";
        private const string SUBMISSION = "urn:ietf:params:jmap:submission";
        private const string VACATION = "urn:ietf:params:jmap:vacationresponse";
        private const string QUOTA = "urn:ietf:params:jmap:quota";

        public JmapBackend (AccountSync owner) {
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

        public override bool supports_auto_reply {
            get { return capabilities.contains (VACATION); }
        }

        public override string protocol_name {
            owned get { return "JMAP"; }
        }

        private string session_url {
            owned get {
                string u = account.api_url;
                if (u == "") u = "https://" + Autoconfig.domain_of (account.email) + "/.well-known/jmap";
                return u;
            }
        }

        private string resolve (string url) {
            if (url.has_prefix ("http")) return url;
            try {
                return Uri.resolve_relative (session_url, url, UriFlags.NONE);
            } catch (Error e) {
                return url;
            }
        }

        public override async void connect () throws Error {
            var node = yield api.json ("GET", session_url);
            var o = node.get_object ();
            api_url = resolve (Js.str (o, "apiUrl"));
            download_url = resolve (Js.str (o, "downloadUrl"));
            upload_url = resolve (Js.str (o, "uploadUrl"));
            var primary = Js.obj (o, "primaryAccounts");
            account_id = Js.str (primary, MAIL);
            capabilities.clear ();
            var caps = Js.obj (o, "capabilities");
            if (caps != null) foreach (string k in caps.get_members ()) capabilities.add (k);
            if (account_id == "") throw new MailError.PROTOCOL (_("The server offers no mail account over JMAP"));
            connected = true;
            try {
                var res = yield call (SUBMISSION, "Identity/get", args_with (null));
                var list = Js.arr (res.get_object (), "list");
                if (list != null) {
                    foreach (var n in list.get_elements ()) {
                        var io = n.get_object ();
                        if (identity_id == "" || Js.str (io, "email").down () == account.email.down ()) identity_id = Js.str (io, "id");
                    }
                }
            } catch (Error e) {
            }
        }

        public override void disconnect () {
            connected = false;
        }

        private Json.Builder args_with (Json.Builder? unused) {
            var b = new Json.Builder ();
            b.begin_object ();
            b.set_member_name ("accountId").add_string_value (account_id);
            return b;
        }

        private async Json.Node call (string capability, string method, Json.Builder args) throws Error {
            args.end_object ();
            var list = yield batch (capability, { method }, { args.get_root () });
            return list[0];
        }

        private async Gee.List<Json.Node> batch (string capability, string[] methods, Json.Node[] args) throws Error {
            var b = new Json.Builder ();
            b.begin_object ();
            b.set_member_name ("using").begin_array ().add_string_value (CORE).add_string_value (MAIL);
            if (capability != MAIL && capability != CORE) b.add_string_value (capability);
            b.end_array ();
            b.set_member_name ("methodCalls").begin_array ();
            for (int i = 0; i < methods.length; i++) {
                b.begin_array ();
                b.add_string_value (methods[i]);
                b.add_value (args[i]);
                b.add_string_value ("c%d".printf (i));
                b.end_array ();
            }
            b.end_array ();
            b.end_object ();
            var node = yield api.json ("POST", api_url, b.get_root ());
            var responses = Js.arr (node.get_object (), "methodResponses");
            var outb = new Gee.ArrayList<Json.Node> ();
            if (responses == null) throw new MailError.PROTOCOL (_("The server gave no answer"));
            foreach (var r in responses.get_elements ()) {
                var a = r.get_array ();
                if (a.get_string_element (0) == "error") {
                    var e = a.get_object_element (1);
                    throw new MailError.SERVER ("%s %s".printf (Js.str (e, "type"), Js.str (e, "description")).strip ());
                }
                outb.add (a.get_element (1));
            }
            return outb;
        }

        public override async Gee.List<RemoteFolder> list_folders () throws Error {
            var res = yield call (MAIL, "Mailbox/get", args_with (null));
            var list = new Gee.ArrayList<RemoteFolder> ();
            var mbs = Js.arr (res.get_object (), "list");
            if (mbs == null) return list;
            foreach (var n in mbs.get_elements ()) {
                var o = n.get_object ();
                var r = new RemoteFolder ();
                r.path = Js.str (o, "id");
                r.name = Js.str (o, "name");
                r.parent = Js.str (o, "parentId");
                string role = Js.str (o, "role");
                r.role = role == "inbox" || role == "sent" || role == "drafts" || role == "trash" || role == "junk" || role == "archive" ? role : "";
                list.add (r);
            }
            return list;
        }

        private static string addr_list (Json.Array? a) {
            if (a == null) return "";
            var parts = new Gee.ArrayList<string> ();
            foreach (var n in a.get_elements ()) {
                var o = n.get_object ();
                parts.add (new Address (Js.str (o, "name"), Js.str (o, "email")).to_header ());
            }
            return string.joinv (", ", parts.to_array ());
        }

        private static string ids_of (Json.Array? a) {
            if (a == null) return "";
            var parts = new Gee.ArrayList<string> ();
            foreach (var n in a.get_elements ()) parts.add ("<" + n.get_string () + ">");
            return string.joinv (" ", parts.to_array ());
        }

        public static int flags_of (Json.Object? kw) {
            int flags = 0;
            if (kw == null) return flags;
            foreach (string k in kw.get_members ()) {
                switch (k.down ()) {
                    case "$seen": flags |= MessageFlags.SEEN; break;
                    case "$flagged": flags |= MessageFlags.FLAGGED; break;
                    case "$answered": flags |= MessageFlags.ANSWERED; break;
                    case "$draft": flags |= MessageFlags.DRAFT; break;
                    case "$forwarded": flags |= MessageFlags.FORWARDED; break;
                    case "$completed": flags |= MessageFlags.COMPLETED; break;
                    case "$pinned": flags |= MessageFlags.PINNED; break;
                    case "$junk": flags |= MessageFlags.JUNK; break;
                }
            }
            return flags;
        }

        public static string categories_of (Json.Object? kw) {
            var parts = new Gee.ArrayList<string> ();
            if (kw == null) return "";
            foreach (string k in kw.get_members ()) {
                if (k.has_prefix ("$")) continue;
                parts.add (Keywords.to_category (k));
            }
            return string.joinv ("\x1f", parts.to_array ());
        }

        private const string PROPS = "[\"id\",\"threadId\",\"mailboxIds\",\"keywords\",\"size\",\"receivedAt\",\"messageId\",\"inReplyTo\",\"references\",\"from\",\"to\",\"cc\",\"subject\",\"hasAttachment\",\"header:List-Unsubscribe:asText\",\"header:List-Id:asText\",\"header:Importance:asText\",\"header:Disposition-Notification-To:asText\"]";

        private string header_of (Json.Object o) {
            var extra = new StringBuilder ();
            string lu = Js.str (o, "header:List-Unsubscribe:asText");
            if (lu != "") extra.append ("List-Unsubscribe: " + lu + "\r\n");
            string li = Js.str (o, "header:List-Id:asText");
            if (li != "") extra.append ("List-Id: " + li + "\r\n");
            string imp = Js.str (o, "header:Importance:asText");
            if (imp != "") extra.append ("Importance: " + imp + "\r\n");
            string dn = Js.str (o, "header:Disposition-Notification-To:asText");
            if (dn != "") extra.append ("Disposition-Notification-To: " + dn + "\r\n");
            if (Js.flag (o, "hasAttachment")) extra.append ("Content-Type: multipart/mixed\r\n");
            var mid = Js.arr (o, "messageId");
            var irt = Js.arr (o, "inReplyTo");
            return synth_header (addr_list (Js.arr (o, "from")), addr_list (Js.arr (o, "to")), addr_list (Js.arr (o, "cc")), Js.str (o, "subject"),
                Js.iso_time (Js.str (o, "receivedAt")), mid != null && mid.get_length () > 0 ? mid.get_string_element (0) : "",
                irt != null && irt.get_length () > 0 ? irt.get_string_element (0) : "", ids_of (Js.arr (o, "references")), extra.str);
        }

        public override async void sync_folder (Folder f, bool notify, Gee.List<MessageInfo> fresh) throws Error {
            bool initial = f.sync_state == "";
            var q = args_with (null);
            q.set_member_name ("filter").begin_object ().set_member_name ("inMailbox").add_string_value (f.path).end_object ();
            q.set_member_name ("sort").begin_array ().begin_object ().set_member_name ("property").add_string_value ("receivedAt").set_member_name ("isAscending").add_boolean_value (false).end_object ().end_array ();
            q.set_member_name ("limit").add_int_value (2000);
            var res = yield call (MAIL, "Email/query", q);
            var ids = new Gee.ArrayList<string> ();
            var arr = Js.arr (res.get_object (), "ids");
            if (arr != null) foreach (var n in arr.get_elements ()) ids.add (n.get_string ());
            var present = new Gee.HashSet<string> ();
            present.add_all (ids);
            var local = store.rid_map (f.id);
            store.begin ();
            foreach (var e in local.entries) if (!present.contains (e.key)) store.delete_message (e.value);
            store.commit ();
            var want = new Gee.ArrayList<string> ();
            foreach (string id in ids) want.add (id);
            for (int i = 0; i < want.size; i += 200) {
                var g = args_with (null);
                g.set_member_name ("ids").begin_array ();
                for (int k = i; k < int.min (i + 200, want.size); k++) g.add_string_value (want[k]);
                g.end_array ();
                g.set_member_name ("properties");
                g.add_value (Js.parse (PROPS));
                var got = yield call (MAIL, "Email/get", g);
                var list = Js.arr (got.get_object (), "list");
                if (list == null) continue;
                store.begin ();
                foreach (var n in list.get_elements ()) {
                    var o = n.get_object ();
                    string id = Js.str (o, "id");
                    int flags = flags_of (Js.obj (o, "keywords"));
                    string cats = categories_of (Js.obj (o, "keywords"));
                    if (local.has_key (id)) {
                        store.set_state (local[id], flags, cats);
                        continue;
                    }
                    int64 nid = store.insert_message (f, store.max_uid (f.id) + 1, flags, Js.num (o, "size"), header_of (o).data, Js.iso_time (Js.str (o, "receivedAt")), id, Js.str (o, "threadId"), cats);
                    if (notify && !initial && (flags & MessageFlags.SEEN) == 0) {
                        var m = store.message (nid);
                        if (m != null) fresh.add (m);
                    }
                }
                store.commit ();
            }
            f.sync_state = Js.str (res.get_object (), "queryState", "listed");
            store.set_folder_state (f);
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
            var g = args_with (null);
            g.set_member_name ("ids").begin_array ().add_string_value (m.ident).end_array ();
            g.set_member_name ("properties").begin_array ().add_string_value ("blobId").end_array ();
            var res = yield call (MAIL, "Email/get", g);
            var list = Js.arr (res.get_object (), "list");
            if (list == null || list.get_length () == 0) return null;
            string blob = Js.str (list.get_object_element (0), "blobId");
            string url = download_url.replace ("{accountId}", Uri.escape_string (account_id, null, false)).replace ("{blobId}", Uri.escape_string (blob, null, false))
                .replace ("{type}", Uri.escape_string ("message/rfc822", null, false)).replace ("{name}", "message.eml");
            var bytes = yield api.raw ("GET", url);
            return bytes.get_data ();
        }

        private async void update (string ids, owned PatchFn fn) throws Error {
            var b = args_with (null);
            b.set_member_name ("update").begin_object ();
            foreach (string id in ids.split (",")) {
                if (id == "") continue;
                b.set_member_name (id).begin_object ();
                fn (b);
                b.end_object ();
            }
            b.end_object ();
            var res = yield call (MAIL, "Email/set", b);
            var not = Js.obj (res.get_object (), "notUpdated");
            if (not != null && not.get_size () > 0) throw new MailError.SERVER (_("The server refused the change"));
        }

        private delegate void PatchFn (Json.Builder b);

        public override async void set_flags (Folder f, string ids, int flag, bool on) throws Error {
            string kw = jmap_keyword (flag);
            yield update (ids, (b) => {
                b.set_member_name ("keywords/" + kw);
                if (on) b.add_boolean_value (true);
                else b.add_null_value ();
            });
        }

        public override async void set_keywords (Folder f, string ids, string[] add, string[] remove) throws Error {
            yield update (ids, (b) => {
                foreach (string a in add) b.set_member_name ("keywords/" + Keywords.to_keyword (a)).add_boolean_value (true);
                foreach (string r in remove) b.set_member_name ("keywords/" + Keywords.to_keyword (r)).add_null_value ();
            });
        }

        public override async void move (Folder f, string ids, Folder dest) throws Error {
            string src = f.path;
            string dst = dest.path;
            yield update (ids, (b) => {
                b.set_member_name ("mailboxIds/" + src).add_null_value ();
                b.set_member_name ("mailboxIds/" + dst).add_boolean_value (true);
            });
        }

        public override async void copy (Folder f, string ids, Folder dest) throws Error {
            string dst = dest.path;
            yield update (ids, (b) => {
                b.set_member_name ("mailboxIds/" + dst).add_boolean_value (true);
            });
        }

        public override async void expunge (Folder f, string ids) throws Error {
            var b = args_with (null);
            b.set_member_name ("destroy").begin_array ();
            foreach (string id in ids.split (",")) if (id != "") b.add_string_value (id);
            b.end_array ();
            yield call (MAIL, "Email/set", b);
        }

        private async string upload (uint8[] raw) throws Error {
            string url = upload_url.replace ("{accountId}", Uri.escape_string (account_id, null, false));
            var reply = yield api.raw ("POST", url, "message/rfc822", new Bytes (raw));
            return Js.str (Js.parse (Mime.bytes_to_string (reply.get_data ())).get_object (), "blobId");
        }

        private async string import (string blob, string mailbox, string flags) throws Error {
            var b = args_with (null);
            b.set_member_name ("emails").begin_object ();
            b.set_member_name ("e1").begin_object ();
            b.set_member_name ("blobId").add_string_value (blob);
            b.set_member_name ("mailboxIds").begin_object ().set_member_name (mailbox).add_boolean_value (true).end_object ();
            b.set_member_name ("keywords").begin_object ();
            if (flags.contains ("\\Seen")) b.set_member_name ("$seen").add_boolean_value (true);
            if (flags.contains ("\\Draft")) b.set_member_name ("$draft").add_boolean_value (true);
            b.end_object ();
            b.end_object ();
            b.end_object ();
            var res = yield call (MAIL, "Email/import", b);
            var created = Js.obj (Js.obj (res.get_object (), "created"), "e1");
            if (created == null) throw new MailError.SERVER (_("The server did not store the message"));
            return Js.str (created, "id");
        }

        public override async string append (Folder f, string flags, uint8[] raw) throws Error {
            string blob = yield upload (raw);
            return yield import (blob, f.path, flags);
        }

        public override async RemoteFolder create_folder (string name, Folder? parent) throws Error {
            var b = args_with (null);
            b.set_member_name ("create").begin_object ().set_member_name ("m1").begin_object ();
            b.set_member_name ("name").add_string_value (name);
            if (parent != null) b.set_member_name ("parentId").add_string_value (parent.path);
            b.end_object ().end_object ();
            var res = yield call (MAIL, "Mailbox/set", b);
            var created = Js.obj (Js.obj (res.get_object (), "created"), "m1");
            if (created == null) throw new MailError.SERVER (_("The server did not create the folder"));
            var r = new RemoteFolder ();
            r.path = Js.str (created, "id");
            r.name = name;
            r.parent = parent != null ? parent.path : "";
            return r;
        }

        public override async void rename_folder (Folder f, string name) throws Error {
            var b = args_with (null);
            b.set_member_name ("update").begin_object ().set_member_name (f.path).begin_object ();
            b.set_member_name ("name").add_string_value (name);
            b.end_object ().end_object ();
            yield call (MAIL, "Mailbox/set", b);
        }

        public override async void delete_folder (Folder f) throws Error {
            var b = args_with (null);
            b.set_member_name ("destroy").begin_array ().add_string_value (f.path).end_array ();
            b.set_member_name ("onDestroyRemoveEmails").add_boolean_value (true);
            yield call (MAIL, "Mailbox/set", b);
        }

        public override async Gee.List<string> search (Folder f, SearchQuery q) throws Error {
            var b = args_with (null);
            var filter = q.to_jmap_filter ();
            filter.get_object ().get_array_member ("conditions").add_object_element (new Json.Object ());
            var cond = filter.get_object ().get_array_member ("conditions");
            cond.get_object_element (cond.get_length () - 1).set_string_member ("inMailbox", f.path);
            b.set_member_name ("filter");
            b.add_value (filter);
            b.set_member_name ("limit").add_int_value (500);
            var res = yield call (MAIL, "Email/query", b);
            var list = new Gee.ArrayList<string> ();
            var ids = Js.arr (res.get_object (), "ids");
            if (ids != null) foreach (var n in ids.get_elements ()) list.add (n.get_string ());
            return list;
        }

        public override async bool wait_changes (Cancellable stop) throws Error {
            return false;
        }

        public override async void send (uint8[] raw, string sender, Gee.List<string> recipients) throws Error {
            var sent = store.folder_by_role (account.id, "sent");
            if (sent == null) throw new MailError.SERVER (_("The account has no Sent folder"));
            string blob = yield upload (raw);
            string email_id = yield import (blob, sent.path, "\\Seen");
            var b = args_with (null);
            b.set_member_name ("create").begin_object ().set_member_name ("s1").begin_object ();
            b.set_member_name ("identityId").add_string_value (identity_id);
            b.set_member_name ("emailId").add_string_value (email_id);
            b.set_member_name ("envelope").begin_object ();
            b.set_member_name ("mailFrom").begin_object ().set_member_name ("email").add_string_value (sender).end_object ();
            b.set_member_name ("rcptTo").begin_array ();
            foreach (string r in recipients) b.begin_object ().set_member_name ("email").add_string_value (r).end_object ();
            b.end_array ();
            b.end_object ();
            b.end_object ().end_object ();
            var res = yield call (SUBMISSION, "EmailSubmission/set", b);
            var not = Js.obj (res.get_object (), "notCreated");
            if (not != null && not.get_size () > 0) {
                var e = Js.obj (not, "s1");
                throw new MailError.SERVER (Js.str (e, "description", Js.str (e, "type")));
            }
        }

        public override async Quota? quota () throws Error {
            if (!capabilities.contains (QUOTA)) return null;
            var res = yield call (QUOTA, "Quota/get", args_with (null));
            var list = Js.arr (res.get_object (), "list");
            if (list == null) return null;
            foreach (var n in list.get_elements ()) {
                var o = n.get_object ();
                if (Js.str (o, "resourceType") != "octets") continue;
                var q = new Quota ();
                q.used = Js.num (o, "used");
                q.limit = Js.num (o, "hardLimit");
                return q;
            }
            return null;
        }

        public override async AutoReply get_auto_reply () throws Error {
            var b = args_with (null);
            b.set_member_name ("ids").begin_array ().add_string_value ("singleton").end_array ();
            var res = yield call (VACATION, "VacationResponse/get", b);
            var r = new AutoReply ();
            var list = Js.arr (res.get_object (), "list");
            if (list == null || list.get_length () == 0) return r;
            var o = list.get_object_element (0);
            r.enabled = Js.flag (o, "isEnabled");
            r.subject = Js.str (o, "subject");
            r.message = Js.str (o, "textBody");
            r.start = Js.iso_time (Js.str (o, "fromDate"));
            r.end = Js.iso_time (Js.str (o, "toDate"));
            return r;
        }

        public override async void set_auto_reply (AutoReply r) throws Error {
            var b = args_with (null);
            b.set_member_name ("update").begin_object ().set_member_name ("singleton").begin_object ();
            b.set_member_name ("isEnabled").add_boolean_value (r.enabled);
            b.set_member_name ("subject").add_string_value (r.subject);
            b.set_member_name ("textBody").add_string_value (r.message);
            b.set_member_name ("fromDate");
            if (r.start > 0) b.add_string_value (Js.iso (r.start));
            else b.add_null_value ();
            b.set_member_name ("toDate");
            if (r.end > 0) b.add_string_value (Js.iso (r.end));
            else b.add_null_value ();
            b.end_object ().end_object ();
            yield call (VACATION, "VacationResponse/set", b);
        }
    }
}
