namespace Singularity.Apps.Lettere {

    public class EwsBackend : MailBackend {
        private unowned AccountSync owner;
        private ApiClient api;
        private bool connected;

        private const string ENVELOPE = "<?xml version=\"1.0\" encoding=\"utf-8\"?><soap:Envelope xmlns:soap=\"http://schemas.xmlsoap.org/soap/envelope/\" xmlns:t=\"http://schemas.microsoft.com/exchange/services/2006/types\" xmlns:m=\"http://schemas.microsoft.com/exchange/services/2006/messages\"><soap:Header><t:RequestServerVersion Version=\"Exchange2013\"/></soap:Header><soap:Body>%s</soap:Body></soap:Envelope>";

        private const string PROPS = "<t:AdditionalProperties><t:FieldURI FieldURI=\"item:Subject\"/><t:FieldURI FieldURI=\"message:From\"/><t:FieldURI FieldURI=\"message:ToRecipients\"/><t:FieldURI FieldURI=\"message:CcRecipients\"/><t:FieldURI FieldURI=\"item:DateTimeReceived\"/><t:FieldURI FieldURI=\"message:InternetMessageId\"/><t:FieldURI FieldURI=\"item:ConversationId\"/><t:FieldURI FieldURI=\"message:IsRead\"/><t:FieldURI FieldURI=\"item:Flag\"/><t:FieldURI FieldURI=\"item:HasAttachments\"/><t:FieldURI FieldURI=\"item:Categories\"/><t:FieldURI FieldURI=\"item:Importance\"/><t:FieldURI FieldURI=\"item:Size\"/><t:FieldURI FieldURI=\"item:InReplyTo\"/><t:FieldURI FieldURI=\"message:References\"/></t:AdditionalProperties>";

        public EwsBackend (AccountSync owner) {
            this.owner = owner;
            this.account = owner.account;
            this.store = owner.store;
            api = new ApiClient (owner, owner.account.auth_mechanism == "ntlm");
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
            owned get { return "Exchange"; }
        }

        private string url {
            owned get { return account.api_url != "" ? account.api_url : "https://" + Autoconfig.domain_of (account.email) + "/EWS/Exchange.asmx"; }
        }

        private static string esc (string s) {
            return Markup.escape_text (s);
        }

        private async XmlNode soap (string body) throws Error {
            var headers = new Gee.HashMap<string, string> ();
            var reply = yield api.raw ("POST", url, "text/xml; charset=utf-8", new Bytes (ENVELOPE.printf (body).data), headers);
            var root = XmlNode.parse (Mime.bytes_to_string (reply.get_data ()));
            var fault = root.find ("Fault");
            if (fault != null) throw new MailError.SERVER (fault.find ("faultstring") != null ? fault.find ("faultstring").text.str : _("The Exchange server reported an error"));
            var messages = new Gee.ArrayList<XmlNode> ();
            root.find_all ("MessageText", messages);
            foreach (var n in root.children) {
                var errors = new Gee.ArrayList<XmlNode> ();
                n.find_all ("ResponseCode", errors);
                foreach (var e in errors) {
                    string code = e.text.str.strip ();
                    if (code != "NoError" && code != "ErrorItemNotFound" && code != "ErrorNameResolutionNoResults") {
                        throw new MailError.SERVER (messages.size > 0 ? messages[0].text.str : code);
                    }
                }
            }
            return root;
        }

        private static string folder_id (string path) {
            int bar = path.index_of_char ('|');
            string id = bar > 0 ? path.substring (bar + 1) : path;
            if (id.has_prefix ("dist:")) {
                string mailbox = bar > 0 ? "<t:Mailbox><t:EmailAddress>%s</t:EmailAddress></t:Mailbox>".printf (esc (path.substring (0, bar))) : "";
                return "<t:DistinguishedFolderId Id=\"%s\">%s</t:DistinguishedFolderId>".printf (id.substring (5), mailbox);
            }
            return "<t:FolderId Id=\"%s\"/>".printf (esc (id));
        }

        private static string item_ids (string ids) {
            var sb = new StringBuilder ();
            foreach (string id in ids.split (",")) if (id != "") sb.append ("<t:ItemId Id=\"%s\"/>".printf (esc (id)));
            return sb.str;
        }

        public override async void connect () throws Error {
            yield soap ("<m:GetFolder><m:FolderShape><t:BaseShape>IdOnly</t:BaseShape></m:FolderShape><m:FolderIds><t:DistinguishedFolderId Id=\"inbox\"/></m:FolderIds></m:GetFolder>");
            connected = true;
        }

        public override void disconnect () {
            connected = false;
        }

        private async void collect (string root_id, string prefix, Gee.Map<string, string> roles, Gee.List<RemoteFolder> into, bool shared) throws Error {
            var res = yield soap ("<m:FindFolder Traversal=\"Deep\"><m:FolderShape><t:BaseShape>Default</t:BaseShape><t:AdditionalProperties><t:FieldURI FieldURI=\"folder:ParentFolderId\"/><t:FieldURI FieldURI=\"folder:FolderClass\"/></t:AdditionalProperties></m:FolderShape><m:ParentFolderIds>%s</m:ParentFolderIds></m:FindFolder>".printf (folder_id (root_id)));
            var folders = new Gee.ArrayList<XmlNode> ();
            res.find_all ("Folder", folders);
            string root_real = "";
            foreach (var f in folders) {
                string cls = f.value ("FolderClass");
                if (cls != "" && cls != "IPF.Note") continue;
                var idn = f.child ("FolderId");
                var pn = f.child ("ParentFolderId");
                if (idn == null) continue;
                string id = idn.attr ("Id");
                var r = new RemoteFolder ();
                r.path = prefix + id;
                r.name = f.value ("DisplayName");
                string parent = pn != null ? pn.attr ("Id") : "";
                r.parent = parent != "" && parent != root_real ? prefix + parent : "";
                r.role = shared ? "" : (roles[id] ?? "");
                r.shared = shared;
                into.add (r);
            }
            var ids = new Gee.HashSet<string> ();
            foreach (var r in into) ids.add (r.path);
            foreach (var r in into) if (!ids.contains (r.parent)) r.parent = "";
        }

        public override async Gee.List<RemoteFolder> list_folders () throws Error {
            var roles = new Gee.HashMap<string, string> ();
            string[,] known = { { "inbox", "inbox" }, { "sentitems", "sent" }, { "drafts", "drafts" }, { "deleteditems", "trash" }, { "junkemail", "junk" }, { "archiveinbox", "archive" } };
            for (int i = 0; i < known.length[0]; i++) {
                try {
                    var res = yield soap ("<m:GetFolder><m:FolderShape><t:BaseShape>IdOnly</t:BaseShape></m:FolderShape><m:FolderIds><t:DistinguishedFolderId Id=\"%s\"/></m:FolderIds></m:GetFolder>".printf (known[i, 0]));
                    var idn = res.find ("FolderId");
                    if (idn != null) roles[idn.attr ("Id")] = known[i, 1];
                } catch (MailError.SERVER e) {
                }
            }
            var list = new Gee.ArrayList<RemoteFolder> ();
            yield collect ("dist:msgfolderroot", "", roles, list, false);
            foreach (string mb in account.shared_mailboxes ()) {
                try {
                    yield collect (mb + "|dist:msgfolderroot", mb + "|", roles, list, true);
                } catch (Error e) {
                    try {
                        var inbox = new RemoteFolder ();
                        inbox.path = mb + "|dist:inbox";
                        inbox.name = mb;
                        inbox.shared = true;
                        yield soap ("<m:GetFolder><m:FolderShape><t:BaseShape>IdOnly</t:BaseShape></m:FolderShape><m:FolderIds>%s</m:FolderIds></m:GetFolder>".printf (folder_id (inbox.path)));
                        list.add (inbox);
                    } catch (Error e2) {
                        warning ("lettere: shared mailbox %s: %s", mb, e2.message);
                    }
                }
            }
            return list;
        }

        public override async Gee.List<RemoteFolder> open_shared (string mailbox) throws Error {
            var list = new Gee.ArrayList<RemoteFolder> ();
            var roles = new Gee.HashMap<string, string> ();
            try {
                yield collect (mailbox + "|dist:msgfolderroot", mailbox + "|", roles, list, true);
            } catch (Error e) {
                var inbox = new RemoteFolder ();
                inbox.path = mailbox + "|dist:inbox";
                inbox.name = mailbox;
                inbox.shared = true;
                yield soap ("<m:GetFolder><m:FolderShape><t:BaseShape>IdOnly</t:BaseShape></m:FolderShape><m:FolderIds>%s</m:FolderIds></m:GetFolder>".printf (folder_id (inbox.path)));
                list.add (inbox);
            }
            account.add_shared_mailbox (mailbox);
            return list;
        }

        private static string mailbox_text (XmlNode? mb) {
            if (mb == null) return "";
            return new Address (mb.value ("Name"), mb.value ("EmailAddress")).to_header ();
        }

        private static string mailboxes (XmlNode? list) {
            if (list == null) return "";
            var parts = new Gee.ArrayList<string> ();
            foreach (var mb in list.all ("Mailbox")) parts.add (mailbox_text (mb));
            return string.joinv (", ", parts.to_array ());
        }

        public static int flags_of (XmlNode item) {
            int flags = 0;
            if (item.value ("IsRead") == "true") flags |= MessageFlags.SEEN;
            var flag = item.child ("Flag");
            if (flag != null) {
                string st = flag.value ("FlagStatus");
                if (st == "Flagged") flags |= MessageFlags.FLAGGED;
                if (st == "Complete") flags |= MessageFlags.FLAGGED | MessageFlags.COMPLETED;
            }
            return flags;
        }

        public static string categories_of (XmlNode item) {
            var c = item.child ("Categories");
            if (c == null) return "";
            var parts = new Gee.ArrayList<string> ();
            foreach (var s in c.all ("String")) parts.add (s.text.str);
            return string.joinv ("\x1f", parts.to_array ());
        }

        private static string header_of (XmlNode item) {
            string imp = item.value ("Importance");
            string extra = imp == "High" ? "Importance: high\r\n" : (imp == "Low" ? "Importance: low\r\n" : "");
            if (item.value ("HasAttachments") == "true") extra += "Content-Type: multipart/mixed\r\n";
            var from = item.child ("From");
            return synth_header (from != null ? mailbox_text (from.child ("Mailbox")) : "", mailboxes (item.child ("ToRecipients")), mailboxes (item.child ("CcRecipients")),
                item.value ("Subject"), Js.iso_time (item.value ("DateTimeReceived")), item.value ("InternetMessageId"), item.value ("InReplyTo"), item.value ("References"), extra);
        }

        public override async void sync_folder (Folder f, bool notify, Gee.List<MessageInfo> fresh) throws Error {
            bool initial = f.sync_state == "";
            for (int round = 0; round < 40; round++) {
                string state = f.sync_state != "" ? "<m:SyncState>%s</m:SyncState>".printf (esc (f.sync_state)) : "";
                var res = yield soap ("<m:SyncFolderItems><m:ItemShape><t:BaseShape>IdOnly</t:BaseShape>%s</m:ItemShape><m:SyncFolderId>%s</m:SyncFolderId>%s<m:MaxChangesReturned>200</m:MaxChangesReturned><m:SyncScope>NormalItems</m:SyncScope></m:SyncFolderItems>".printf (PROPS, folder_id (f.path), state));
                var changes = res.find ("Changes");
                store.begin ();
                if (changes != null) {
                    foreach (var c in changes.children) {
                        XmlNode? item = null;
                        foreach (var k in c.children) if (k.name == "Message" || k.name == "Item" || k.name == "MeetingRequest" || k.name == "MeetingResponse" || k.name == "MeetingCancellation") item = k;
                        var idn = item != null ? item.child ("ItemId") : c.child ("ItemId");
                        if (idn == null) continue;
                        string id = idn.attr ("Id");
                        int64 local = store.id_for_rid (f.id, id);
                        switch (c.name) {
                            case "Delete":
                                if (local != 0) store.delete_message (local);
                                break;
                            case "ReadFlagChange":
                                if (local != 0) {
                                    var m = store.message (local);
                                    if (m != null) store.set_flags_by_id (local, c.value ("IsRead") == "true" ? (m.flags | MessageFlags.SEEN) : (m.flags & ~MessageFlags.SEEN));
                                }
                                break;
                            case "Update":
                            case "Create":
                                if (item == null) break;
                                int flags = flags_of (item);
                                string cats = categories_of (item);
                                if (local != 0) {
                                    var m = store.message (local);
                                    int keep = m != null ? (m.flags & (MessageFlags.PINNED | MessageFlags.ANSWERED | MessageFlags.FORWARDED)) : 0;
                                    store.set_state (local, flags | keep, cats);
                                    break;
                                }
                                var conv = item.child ("ConversationId");
                                int64 nid = store.insert_message (f, store.max_uid (f.id) + 1, flags, int64.parse (item.value ("Size")), header_of (item).data,
                                    Js.iso_time (item.value ("DateTimeReceived")), id, conv != null ? conv.attr ("Id") : "", cats);
                                if (notify && !initial && (flags & MessageFlags.SEEN) == 0) {
                                    var m = store.message (nid);
                                    if (m != null) fresh.add (m);
                                }
                                break;
                        }
                    }
                }
                store.commit ();
                var sn = res.find ("SyncState");
                if (sn != null) f.sync_state = sn.text.str.strip ();
                store.set_folder_state (f);
                var last = res.find ("IncludesLastItemInRange");
                if (last == null || last.text.str.strip () == "true") break;
            }
        }

        public override async void prefetch (Folder f, int limit) throws Error {
            var list = store.missing_body_messages (f.id, max_body_size, limit);
            for (int i = 0; i < list.size; i += 10) {
                var ids = new Gee.ArrayList<string> ();
                for (int k = i; k < int.min (i + 10, list.size); k++) ids.add (list[k].ident);
                var res = yield soap ("<m:GetItem><m:ItemShape><t:BaseShape>IdOnly</t:BaseShape><t:IncludeMimeContent>true</t:IncludeMimeContent></m:ItemShape><m:ItemIds>%s</m:ItemIds></m:GetItem>".printf (item_ids (string.joinv (",", ids.to_array ()))));
                var mimes = new Gee.ArrayList<XmlNode> ();
                res.find_all ("Message", mimes);
                store.begin ();
                foreach (var node in mimes) {
                    var idn = node.child ("ItemId");
                    var mc = node.child ("MimeContent");
                    if (idn == null || mc == null) continue;
                    int64 lid = store.id_for_rid (f.id, idn.attr ("Id"));
                    if (lid != 0) store.set_body (lid, Base64.decode (mc.text.str.strip ()));
                }
                store.commit ();
            }
        }

        public override async uint8[]? fetch_body (Folder f, MessageInfo m) throws Error {
            var res = yield soap ("<m:GetItem><m:ItemShape><t:BaseShape>IdOnly</t:BaseShape><t:IncludeMimeContent>true</t:IncludeMimeContent></m:ItemShape><m:ItemIds>%s</m:ItemIds></m:GetItem>".printf (item_ids (m.ident)));
            var mc = res.find ("MimeContent");
            if (mc == null) return null;
            return Base64.decode (mc.text.str.strip ());
        }

        private async void update_items (string ids, string field_uri, string item_xml) throws Error {
            var sb = new StringBuilder ();
            foreach (string id in ids.split (",")) {
                if (id == "") continue;
                sb.append ("<t:ItemChange><t:ItemId Id=\"%s\"/><t:Updates><t:SetItemField><t:FieldURI FieldURI=\"%s\"/><t:Message>%s</t:Message></t:SetItemField></t:Updates></t:ItemChange>".printf (esc (id), field_uri, item_xml));
            }
            yield soap ("<m:UpdateItem MessageDisposition=\"SaveOnly\" ConflictResolution=\"AlwaysOverwrite\"><m:ItemChanges>%s</m:ItemChanges></m:UpdateItem>".printf (sb.str));
        }

        public override async void set_flags (Folder f, string ids, int flag, bool on) throws Error {
            switch (flag) {
                case MessageFlags.SEEN:
                    yield update_items (ids, "message:IsRead", "<t:IsRead>%s</t:IsRead>".printf (on ? "true" : "false"));
                    break;
                case MessageFlags.FLAGGED:
                case MessageFlags.COMPLETED:
                    string st = on ? (flag == MessageFlags.COMPLETED ? "Complete" : "Flagged") : (flag == MessageFlags.COMPLETED ? "Flagged" : "NotFlagged");
                    yield update_items (ids, "item:Flag", "<t:Flag><t:FlagStatus>%s</t:FlagStatus></t:Flag>".printf (st));
                    break;
            }
        }

        public override async void set_keywords (Folder f, string ids, string[] add, string[] remove) throws Error {
            foreach (string id in ids.split (",")) {
                if (id == "") continue;
                int64 lid = store.id_for_rid (f.id, id);
                var m = lid != 0 ? store.message (lid) : null;
                var sb = new StringBuilder ("<t:Categories>");
                if (m != null) foreach (string c in m.categories ()) sb.append ("<t:String>%s</t:String>".printf (esc (c)));
                sb.append ("</t:Categories>");
                yield update_items (id, "item:Categories", sb.str);
            }
        }

        public override async void move (Folder f, string ids, Folder dest) throws Error {
            yield soap ("<m:MoveItem><m:ToFolderId>%s</m:ToFolderId><m:ItemIds>%s</m:ItemIds></m:MoveItem>".printf (folder_id (dest.path), item_ids (ids)));
        }

        public override async void copy (Folder f, string ids, Folder dest) throws Error {
            yield soap ("<m:CopyItem><m:ToFolderId>%s</m:ToFolderId><m:ItemIds>%s</m:ItemIds></m:CopyItem>".printf (folder_id (dest.path), item_ids (ids)));
        }

        public override async void expunge (Folder f, string ids) throws Error {
            yield soap ("<m:DeleteItem DeleteType=\"%s\"><m:ItemIds>%s</m:ItemIds></m:DeleteItem>".printf (f.role == "trash" ? "HardDelete" : "MoveToDeletedItems", item_ids (ids)));
        }

        public override async string append (Folder f, string flags, uint8[] raw) throws Error {
            string read = flags.contains ("\\Seen") ? "<t:IsRead>true</t:IsRead>" : "<t:IsRead>false</t:IsRead>";
            string ext = flags.contains ("\\Draft") ? "" : "<t:ExtendedProperty><t:ExtendedFieldURI PropertyTag=\"3591\" PropertyType=\"Integer\"/><t:Value>1</t:Value></t:ExtendedProperty>";
            var res = yield soap ("<m:CreateItem MessageDisposition=\"SaveOnly\"><m:SavedItemFolderId>%s</m:SavedItemFolderId><m:Items><t:Message><t:MimeContent CharacterSet=\"UTF-8\">%s</t:MimeContent>%s%s</t:Message></m:Items></m:CreateItem>".printf (folder_id (f.path), Base64.encode (raw), ext, read));
            var idn = res.find ("ItemId");
            return idn != null ? idn.attr ("Id") : "";
        }

        public override async RemoteFolder create_folder (string name, Folder? parent) throws Error {
            var res = yield soap ("<m:CreateFolder><m:ParentFolderId>%s</m:ParentFolderId><m:Folders><t:Folder><t:DisplayName>%s</t:DisplayName></t:Folder></m:Folders></m:CreateFolder>".printf (parent != null ? folder_id (parent.path) : folder_id ("dist:msgfolderroot"), esc (name)));
            var idn = res.find ("FolderId");
            if (idn == null) throw new MailError.SERVER (_("The server did not create the folder"));
            var r = new RemoteFolder ();
            string prefix = parent != null && parent.path.contains ("|") ? parent.path.substring (0, parent.path.index_of_char ('|') + 1) : "";
            r.path = prefix + idn.attr ("Id");
            r.name = name;
            r.parent = parent != null ? parent.path : "";
            return r;
        }

        public override async void rename_folder (Folder f, string name) throws Error {
            yield soap ("<m:UpdateFolder><m:FolderChanges><t:FolderChange>%s<t:Updates><t:SetFolderField><t:FieldURI FieldURI=\"folder:DisplayName\"/><t:Folder><t:DisplayName>%s</t:DisplayName></t:Folder></t:SetFolderField></t:Updates></t:FolderChange></m:FolderChanges></m:UpdateFolder>".printf (folder_id (f.path), esc (name)));
        }

        public override async void delete_folder (Folder f) throws Error {
            yield soap ("<m:DeleteFolder DeleteType=\"HardDelete\"><m:FolderIds>%s</m:FolderIds></m:DeleteFolder>".printf (folder_id (f.path)));
        }

        public override async Gee.List<string> search (Folder f, SearchQuery q) throws Error {
            var list = new Gee.ArrayList<string> ();
            string aqs = q.to_aqs ();
            if (aqs == "") return list;
            var res = yield soap ("<m:FindItem Traversal=\"Shallow\"><m:ItemShape><t:BaseShape>IdOnly</t:BaseShape></m:ItemShape><m:IndexedPageItemView MaxEntriesReturned=\"200\" Offset=\"0\" BasePoint=\"Beginning\"/><m:ParentFolderIds>%s</m:ParentFolderIds><m:QueryString>%s</m:QueryString></m:FindItem>".printf (folder_id (f.path), esc (aqs)));
            var ids = new Gee.ArrayList<XmlNode> ();
            res.find_all ("ItemId", ids);
            foreach (var n in ids) list.add (n.attr ("Id"));
            return list;
        }

        public override async bool wait_changes (Cancellable stop) throws Error {
            return false;
        }

        public override async void send (uint8[] raw, string sender, Gee.List<string> recipients) throws Error {
            yield soap ("<m:CreateItem MessageDisposition=\"SendAndSaveCopy\"><m:SavedItemFolderId><t:DistinguishedFolderId Id=\"sentitems\"/></m:SavedItemFolderId><m:Items><t:Message><t:MimeContent CharacterSet=\"UTF-8\">%s</t:MimeContent></t:Message></m:Items></m:CreateItem>".printf (Base64.encode (raw)));
        }

        public override async AutoReply get_auto_reply () throws Error {
            var res = yield soap ("<m:GetUserOofSettingsRequest><t:Mailbox><t:Address>%s</t:Address></t:Mailbox></m:GetUserOofSettingsRequest>".printf (esc (account.email)));
            var r = new AutoReply ();
            string state = res.find ("OofState") != null ? res.find ("OofState").text.str.strip () : "Disabled";
            r.enabled = state != "Disabled";
            var internal_reply = res.find ("InternalReply");
            var external_reply = res.find ("ExternalReply");
            if (internal_reply != null) r.message = Html.to_text (internal_reply.value ("Message"));
            if (external_reply != null) r.external_message = Html.to_text (external_reply.value ("Message"));
            var aud = res.find ("ExternalAudience");
            r.external = aud == null || aud.text.str.strip () != "None";
            if (state == "Scheduled") {
                var d = res.find ("Duration");
                if (d != null) {
                    r.start = Js.iso_time (d.value ("StartTime"));
                    r.end = Js.iso_time (d.value ("EndTime"));
                }
            }
            return r;
        }

        public override async void set_auto_reply (AutoReply r) throws Error {
            string state = !r.enabled ? "Disabled" : (r.start > 0 && r.end > 0 ? "Scheduled" : "Enabled");
            string duration = r.start > 0 && r.end > 0 ? "<t:Duration><t:StartTime>%s</t:StartTime><t:EndTime>%s</t:EndTime></t:Duration>".printf (Js.iso (r.start), Js.iso (r.end)) : "";
            yield soap ("<m:SetUserOofSettingsRequest><t:Mailbox><t:Address>%s</t:Address></t:Mailbox><t:UserOofSettings><t:OofState>%s</t:OofState><t:ExternalAudience>%s</t:ExternalAudience>%s<t:InternalReply><t:Message>%s</t:Message></t:InternalReply><t:ExternalReply><t:Message>%s</t:Message></t:ExternalReply></t:UserOofSettings></m:SetUserOofSettingsRequest>".printf (
                esc (account.email), state, r.external ? "All" : "None", duration, esc (Html.from_text (r.message)), esc (Html.from_text (r.external_message != "" ? r.external_message : r.message))));
        }

        public override async void upload_rules (RuleStore rules) throws Error {
            var existing = yield soap ("<m:GetInboxRules><m:MailboxSmtpAddress>%s</m:MailboxSmtpAddress></m:GetInboxRules>".printf (esc (account.email)));
            var ops = new StringBuilder ();
            string known = store.get_value (account.id, "ews-rules") ?? "";
            var ours = new Gee.HashSet<string> ();
            foreach (string s in known.split ("\n")) if (s != "") ours.add (s);
            var rule_nodes = new Gee.ArrayList<XmlNode> ();
            existing.find_all ("Rule", rule_nodes);
            foreach (var rn in rule_nodes) {
                string rid = rn.value ("RuleId");
                if (ours.contains (rn.value ("DisplayName"))) ops.append ("<t:DeleteRuleOperation><t:RuleId>%s</t:RuleId></t:DeleteRuleOperation>".printf (esc (rid)));
            }
            var names = new Gee.ArrayList<string> ();
            int priority = 1;
            foreach (var r in rules.rules) {
                if (!r.enabled || !r.on_server || (r.account != "" && r.account != account.id)) continue;
                string name = r.name != "" ? r.name : _("Rule %d").printf (priority);
                names.add (name);
                var cond = new StringBuilder ();
                foreach (var c in r.conditions) {
                    switch (c.field) {
                        case "from": cond.append ("<t:FromAddresses><t:Address><t:EmailAddress>%s</t:EmailAddress></t:Address></t:FromAddresses>".printf (esc (c.value))); break;
                        case "subject": cond.append ("<t:ContainsSubjectStrings><t:String>%s</t:String></t:ContainsSubjectStrings>".printf (esc (c.value))); break;
                        case "body": cond.append ("<t:ContainsBodyStrings><t:String>%s</t:String></t:ContainsBodyStrings>".printf (esc (c.value))); break;
                        case "to":
                        case "recipients": cond.append ("<t:ContainsRecipientStrings><t:String>%s</t:String></t:ContainsRecipientStrings>".printf (esc (c.value))); break;
                        case "has-attachment": cond.append ("<t:HasAttachments>true</t:HasAttachments>"); break;
                        case "importance": cond.append ("<t:Importance>%s</t:Importance>".printf (c.value == "high" ? "High" : (c.value == "low" ? "Low" : "Normal"))); break;
                    }
                }
                var act = new StringBuilder ();
                foreach (var a in r.actions) {
                    switch (a.kind) {
                        case "move":
                        case "copy": {
                            var dest = store.folder_by_path (account.id, a.value);
                            if (dest != null) act.append ("<t:%s>%s</t:%s>".printf (a.kind == "move" ? "MoveToFolder" : "CopyToFolder", folder_id (dest.path), a.kind == "move" ? "MoveToFolder" : "CopyToFolder"));
                            break;
                        }
                        case "read": act.append ("<t:MarkAsRead>true</t:MarkAsRead>"); break;
                        case "delete": act.append ("<t:Delete>true</t:Delete>"); break;
                        case "category": act.append ("<t:AssignCategories><t:String>%s</t:String></t:AssignCategories>".printf (esc (a.value))); break;
                        case "flag": act.append ("<t:FlagMessage>true</t:FlagMessage>"); break;
                        case "forward": act.append ("<t:ForwardToRecipients><t:Address><t:EmailAddress>%s</t:EmailAddress></t:Address></t:ForwardToRecipients>".printf (esc (a.value))); break;
                        case "redirect": act.append ("<t:RedirectToRecipients><t:Address><t:EmailAddress>%s</t:EmailAddress></t:Address></t:RedirectToRecipients>".printf (esc (a.value))); break;
                    }
                }
                if (r.stop) act.append ("<t:StopProcessingRules>true</t:StopProcessingRules>");
                ops.append ("<t:CreateRuleOperation><t:Rule><t:DisplayName>%s</t:DisplayName><t:Priority>%d</t:Priority><t:IsEnabled>true</t:IsEnabled><t:Conditions>%s</t:Conditions><t:Exceptions/><t:Actions>%s</t:Actions></t:Rule></t:CreateRuleOperation>".printf (esc (name), priority++, cond.str, act.str));
            }
            if (ops.len > 0) yield soap ("<m:UpdateInboxRules><m:MailboxSmtpAddress>%s</m:MailboxSmtpAddress><m:RemoveOutlookRuleBlob>true</m:RemoveOutlookRuleBlob><m:Operations>%s</m:Operations></m:UpdateInboxRules>".printf (esc (account.email), ops.str));
            store.set_value (account.id, "ews-rules", string.joinv ("\n", names.to_array ()));
        }
    }
}
