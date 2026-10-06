using Singularity.Apps.Lettere;

class TestCredentials : CredentialSource {
    public bool token;
    public int fetches;

    public TestCredentials (bool token) {
        this.token = token;
    }

    public override async MailLogin fetch (bool refresh) throws Error {
        fetches++;
        var l = new MailLogin ();
        l.user = "tester";
        l.secret = token ? "test-token" : "secret";
        if (token) l.xoauth2 = "x";
        return l;
    }

    public override void report_reauth () {
    }
}

string base_url;
int failures = 0;

void check (bool ok, string what) {
    if (ok) {
        stdout.printf ("ok - %s\n", what);
    } else {
        stdout.printf ("not ok - %s\n", what);
        failures++;
    }
}

async Json.Object state (string proto) throws Error {
    var session = new Soup.Session ();
    var msg = new Soup.Message ("GET", base_url + "/_state?p=" + proto);
    var bytes = yield session.send_and_read_async (msg, Priority.DEFAULT, null);
    var p = new Json.Parser ();
    p.load_from_data ((string) bytes.get_data ());
    return p.get_root ().get_object ();
}

Json.Object? mock_message (Json.Object st, string subject) {
    foreach (var n in st.get_array_member ("messages").get_elements ()) {
        var o = n.get_object ();
        if (o.get_string_member ("subject") == subject) return o;
    }
    return null;
}

async void run_protocol (Store store, string proto, string url, bool token) {
    stdout.printf ("# %s\n", proto);
    var a = new Account ();
    a.id = "acc-" + proto;
    a.email = proto == "ews" ? "exchuser@corp.test" : "tester@%s.test".printf (proto == "graph" ? "outlook" : proto);
    a.full_name = "Alex Tester";
    a.protocol = proto;
    a.api_url = url;
    a.source = "online:test";
    a.online = new TestCredentials (token);
    var s = new AccountSync (a, store);
    yield s.sync_all ();
    check (s.state == SyncState.IDLE, "%s: first sync finished (%s)".printf (proto, s.error_text));
    var inbox = store.folder_by_role (a.id, "inbox");
    check (inbox != null, "%s: inbox found".printf (proto));
    if (inbox == null) return;
    var sent = store.folder_by_role (a.id, "sent");
    check (sent != null, "%s: sent folder has its role".printf (proto));
    var ids = new Gee.ArrayList<int64?> ();
    ids.add (inbox.id);
    var msgs = store.list (ids, false);
    check (msgs.size == 4, "%s: four inbox messages (got %d)".printf (proto, msgs.size));
    MessageInfo? launch = null;
    MessageInfo? news = null;
    foreach (var m in msgs) {
        if (m.subject == "Launch plan") launch = m;
        if (m.subject == "This week in orbit") news = m;
    }
    check (launch != null && launch.sender_email == "giulia.rossi@example.com", "%s: sender parsed".printf (proto));
    check (news != null && news.list_unsubscribe != "" || proto == "graph" || proto == "ews", "%s: List-Unsubscribe kept".printf (proto));
    if (launch == null) return;
    var threaded = store.list (ids, true);
    check (threaded.size == 3, "%s: conversation grouped into three threads (got %d)".printf (proto, threaded.size));
    uint8[]? body = null;
    try {
        body = yield s.load_body (launch);
    } catch (Error e) {
        stdout.printf ("# %s\n", e.message);
    }
    check (body != null && new MimeMessage (body).body_text ().contains ("plan for the launch"), "%s: body downloaded".printf (proto));
    var one = new Gee.ArrayList<MessageInfo> ();
    one.add (launch);
    yield s.set_flag (one, MessageFlags.SEEN, true);
    yield s.set_flag (one, MessageFlags.FLAGGED, true);
    yield s.set_categories (one, { "Work" }, {});
    try {
        var st = yield state (proto);
        var mm = mock_message (st, "Launch plan");
        check (mm != null && mm.get_boolean_member ("read"), "%s: read flag on the server".printf (proto));
        check (mm != null && mm.get_string_member ("flag") == "flagged", "%s: flag on the server".printf (proto));
        bool cat = false;
        if (mm != null) foreach (var c in mm.get_array_member ("categories").get_elements ()) if (c.get_string () == "Work") cat = true;
        check (cat, "%s: category on the server".printf (proto));
    } catch (Error e) {
        check (false, "%s: state %s".printf (proto, e.message));
    }
    var q = SearchQuery.parse ("orbit");
    try {
        var hits = yield s.search_server (inbox, q);
        check (hits.size == 1, "%s: server search finds one message (got %d)".printf (proto, hits.size));
    } catch (Error e) {
        check (false, "%s: search %s".printf (proto, e.message));
    }
    Folder? made = null;
    try {
        made = yield s.create_folder ("Reports", null);
        check (made != null, "%s: folder created".printf (proto));
    } catch (Error e) {
        check (false, "%s: create folder %s".printf (proto, e.message));
    }
    if (made != null) {
        yield s.move (one, made);
        try {
            var st = yield state (proto);
            var mm = mock_message (st, "Launch plan");
            bool moved = mm != null && mm.get_string_member ("folder") == made.path.substring (made.path.index_of_char ('|') + 1);
                if (proto == "gmail" && mm != null && mm.has_member ("labels")) {
                    foreach (var l in mm.get_array_member ("labels").get_elements ()) if (l.get_string () == made.path) moved = true;
                }
                check (moved, "%s: moved on the server".printf (proto));
        } catch (Error e) {
            check (false, "%s: state after move".printf (proto));
        }
    }
    var b = new MessageBuilder ();
    b.from = a.address ();
    b.to.add (new Address ("Giulia Rossi", "giulia.rossi@example.com"));
    b.subject = "Numbers for %s".printf (proto);
    b.text = "Here they are.";
    var item = new OutboxItem ();
    item.raw = b.build (false);
    item.recipients = "giulia.rossi@example.com";
    item.sender = a.email;
    try {
        yield s.send (item);
        var st = yield state (proto);
        bool found = false;
        foreach (var n in st.get_array_member ("sent").get_elements ()) if (n.get_string ().contains ("Numbers for " + proto)) found = true;
        check (found, "%s: message sent through the API".printf (proto));
    } catch (Error e) {
        check (false, "%s: send %s".printf (proto, e.message));
    }
    var drafts = store.folder_by_role (a.id, "drafts");
    if (drafts != null) {
        try {
            string rid = yield s.append (drafts, "\\Draft \\Seen", b.build (false));
            check (rid != "", "%s: draft stored".printf (proto));
        } catch (Error e) {
            check (false, "%s: append %s".printf (proto, e.message));
        }
    }
    if (s.backend.supports_auto_reply) {
        try {
            var r = new AutoReply ();
            r.enabled = true;
            r.subject = "Away";
            r.message = "Back on Monday";
            yield s.backend.set_auto_reply (r);
            var got = yield s.backend.get_auto_reply ();
            check (got.enabled && got.message.contains ("Back on Monday"), "%s: automatic reply saved and read back".printf (proto));
        } catch (Error e) {
            check (false, "%s: auto reply %s".printf (proto, e.message));
        }
    }
    if (s.backend.supports_rules) {
        var rules = new RuleStore (Path.build_filename (Environment.get_tmp_dir (), "lettere-rules-" + proto));
        var rule = new Rule ();
        rule.name = "Newsletters";
        rule.on_server = true;
        rule.conditions.add (new RuleCondition ("from", "contains", "orbit-weekly.example"));
        rule.actions.add (new RuleAction ("read", ""));
        rules.rules.add (rule);
        try {
            yield s.backend.upload_rules (rules);
            var st = yield state (proto);
            check (st.get_array_member ("rules").get_length () == 1, "%s: server rule created".printf (proto));
            yield s.backend.upload_rules (rules);
            st = yield state (proto);
            check (st.get_array_member ("rules").get_length () == 1, "%s: server rule replaced, not duplicated".printf (proto));
        } catch (Error e) {
            check (false, "%s: rules %s".printf (proto, e.message));
        }
    }
    var q2 = yield s.quota ();
    if (proto == "jmap") check (q2 != null && q2.limit == 10485760, "jmap: quota read");
    s.stop ();
}

int main (string[] args) {
    if (args.length < 2) {
        stdout.printf ("1..0 # SKIP no mock server script\n");
        return 0;
    }
    int port = Random.int_range (35000, 35900);
    base_url = "http://127.0.0.1:%d".printf (port);
    Subprocess mock;
    try {
        mock = new Subprocess.newv ({ "python3", args[1], port.to_string () }, SubprocessFlags.STDERR_SILENCE | SubprocessFlags.STDOUT_SILENCE);
    } catch (Error e) {
        stdout.printf ("1..0 # SKIP %s\n", e.message);
        return 0;
    }
    Thread.usleep (1200000);
    string db = Path.build_filename (Environment.get_tmp_dir (), "lettere-backend-%s.db".printf (Uuid.string_random ().substring (0, 8)));
    Store store;
    try {
        store = new Store (db);
    } catch (Error e) {
        error (e.message);
    }
    var loop = new MainLoop ();
    run_all.begin (store, (o, r) => {
        run_all.end (r);
        loop.quit ();
    });
    loop.run ();
    mock.force_exit ();
    foreach (string suffix in new string[] { "", "-wal", "-shm" }) FileUtils.remove (db + suffix);
    stdout.printf ("%s\n", failures == 0 ? "# all passed" : "# %d failed".printf (failures));
    return failures == 0 ? 0 : 1;
}

async void run_pop (Store store, int port) {
    stdout.printf ("# pop3\n");
    var a = new Account ();
    a.id = "acc-pop";
    a.email = "tester@pop.test";
    a.protocol = "pop3";
    a.imap_host = "127.0.0.1";
    a.imap_port = (uint16) port;
    a.imap_security = Security.NONE;
    a.imap_user = "tester";
    a.pop_keep = true;
    a.source = "online:test";
    a.online = new TestCredentials (false);
    var s = new AccountSync (a, store);
    yield s.sync_all ();
    var inbox = store.folder_by_role (a.id, "inbox");
    check (inbox != null && store.folder_by_role (a.id, "sent") != null && store.folder_by_role (a.id, "trash") != null, "pop3: local folders created");
    if (inbox == null) return;
    var ids = new Gee.ArrayList<int64?> ();
    ids.add (inbox.id);
    var list = store.list (ids, false);
    check (list.size == 4, "pop3: four messages downloaded (got %d)".printf (list.size));
    check (list.size > 0 && list[0].has_body, "pop3: bodies stored for offline reading");
    yield s.sync_all ();
    check (store.list (ids, false).size == 4, "pop3: a second check downloads nothing twice");
    var trash = store.folder_by_role (a.id, "trash");
    var one = new Gee.ArrayList<MessageInfo> ();
    one.add (list[0]);
    yield s.move (one, trash);
    var tids = new Gee.ArrayList<int64?> ();
    tids.add (trash.id);
    check (store.list (tids, false).size == 1 && store.list (ids, false).size == 3, "pop3: local move keeps the message");
    s.stop ();
}

async void run_all (Store store) {
    yield run_graph_boundary (store);
    yield run_protocol (store, "graph", base_url + "/graph/v1.0/", true);
    yield run_graph_shared (store);
    yield run_protocol_switch (store);
    yield run_protocol (store, "gmail", base_url + "/gmail/v1/users/me/", true);
    yield run_protocol (store, "jmap", base_url + "/.well-known/jmap", false);
    yield run_protocol (store, "ews", base_url + "/EWS/Exchange.asmx", false);
    yield run_pop (store, int.parse (base_url.substring (base_url.last_index_of_char (':') + 1)) + 1);
}

async void run_graph_boundary (Store store) {
    stdout.printf ("# graph credential boundary\n");
    var trusted = new Soup.Server ("server-header", "trusted-fixture", null);
    var foreign = new Soup.Server ("server-header", "foreign-fixture", null);
    int foreign_requests = 0;
    int trusted_requests = 0;
    bool authorized = false;
    bool posted = false;
    bool query_kept = false;
    int refresh_requests = 0;
    string foreign_url = "";
    foreign.add_handler (null, (server, msg, path, query) => {
        foreign_requests++;
        msg.set_status (200, null);
        msg.set_response ("application/json", Soup.MemoryUse.COPY, "{\"value\":[]}".data);
    });
    trusted.add_handler (null, (server, msg, path, query) => {
        trusted_requests++;
        authorized = msg.get_request_headers ().get_one ("Authorization") == "Bearer test-token";
        if (path == "/v1.0/foreign") {
            msg.set_redirect (307, foreign_url + "sink");
        } else if (path == "/v1.0/relative") {
            msg.set_redirect (302, "ok");
        } else if (path == "/v1.0/relative-query") {
            msg.set_redirect (302, "query?value=a%26b%2Bc%3Dd");
        } else if (path == "/v1.0/query") {
            query_kept = query != null && query.lookup ("value") == "a&b+c=d";
            msg.set_status (200, null);
        } else if (path == "/v1.0/post") {
            msg.set_redirect (307, "posted");
        } else if (path == "/v1.0/posted") {
            posted = msg.get_method () == "POST" && Mime.bytes_to_string (msg.get_request_body ().data) == "private-message";
            msg.set_status (200, null);
        } else if (path == "/v1.0/ambiguous") {
            msg.set_redirect (302, "posted");
        } else if (path == "/v1.0/loop") {
            msg.set_redirect (307, "loop");
        } else if (path == "/v1.0/missing-location") {
            msg.set_status (307, null);
        } else if (path == "/v1.0/refresh" && refresh_requests++ == 0) {
            msg.set_status (401, null);
        } else {
            msg.set_status (200, null);
            string body = path == "/v1.0/me/mailFolders"
                ? "{\"value\":[],\"@odata.nextLink\":\"" + foreign_url + "sink\"}"
                : "{\"value\":[],\"id\":\"folder\"}";
            msg.set_response ("application/json", Soup.MemoryUse.COPY, body.data);
        }
    });
    try {
        trusted.listen_local (0, Soup.ServerListenOptions.IPV4_ONLY);
        foreign.listen_local (0, Soup.ServerListenOptions.IPV4_ONLY);
        string origin = trusted.get_uris ().data.to_string ();
        foreign_url = foreign.get_uris ().data.to_string ();
        var a = new Account ();
        a.id = "graph-boundary";
        a.protocol = "graph";
        a.api_url = origin + "v1.0/";
        a.source = "online:test";
        var credentials = new TestCredentials (true);
        a.online = credentials;
        var owner = new AccountSync (a, store);
        var api = new ApiClient (owner);
        string[] rejected = {
            foreign_url + "sink", origin + "v1.0evil/sink", origin + "v1.0/%2e%2e/sink",
            origin + "v1.0/ok#fragment", "http://tester@" + origin.substring (7) + "v1.0/ok",
            origin + "v1.0/%5c..%5csink", "not an absolute address"
        };
        foreach (string url in rejected) {
            int before = trusted_requests + foreign_requests;
            bool refused = false;
            try {
                yield api.raw ("GET", url);
            } catch (MailError.PROTOCOL e) {
                refused = true;
            }
            check (refused && before == trusted_requests + foreign_requests && credentials.fetches == 0,
                   "graph: invalid endpoint refused before credentials or network: " + url);
        }
        a.api_url = "http://graph.example.test/v1.0/";
        bool insecure_refused = false;
        try {
            yield api.raw ("GET", a.api_url + "me");
        } catch (MailError.PROTOCOL e) {
            insecure_refused = true;
        }
        check (insecure_refused && credentials.fetches == 0, "graph: non-loopback HTTP refused before credentials");
        a.api_url = origin + "v1.0/";
        yield api.raw ("GET", a.api_url + "relative");
        check (authorized && credentials.fetches == 1, "graph: relative redirect keeps the authorized endpoint");
        yield api.raw ("GET", a.api_url + "relative-query");
        check (query_kept, "graph: redirect preserves escaped paging query data");
        yield api.raw ("POST", a.api_url + "post", "text/plain", new Bytes ("private-message".data));
        check (posted && authorized, "graph: same-origin 307 preserves the method and body");
        foreach (string path in new string[] { "foreign", "ambiguous", "loop", "missing-location" }) {
            int before = foreign_requests;
            int before_trusted = trusted_requests;
            bool refused = false;
            posted = false;
            try {
                yield api.raw ("POST", a.api_url + path, "text/plain", new Bytes ("private-message".data));
            } catch (MailError.PROTOCOL e) {
                refused = true;
            }
            check (refused && foreign_requests == before && !posted,
                   "graph: unsafe or looping redirect refused: " + path);
            if (path == "loop") check (trusted_requests - before_trusted == 6, "graph: redirect loop has a fixed request limit");
        }
        yield api.raw ("GET", a.api_url + "refresh");
        check (refresh_requests == 2 && credentials.fetches == 2, "graph: 401 refresh still retries once");
        var backend = new GraphBackend (owner);
        bool refused = false;
        try {
            yield backend.list_folders ();
        } catch (MailError.PROTOCOL e) {
            refused = true;
        }
        check (refused && foreign_requests == 0, "graph: production folder pagination cannot contact a foreign origin");
        owner.stop ();
    } catch (Error e) {
        check (false, "graph boundary: " + e.message);
    }
    trusted.disconnect ();
    foreign.disconnect ();
}

Folder? folder_at (Store store, string account, string path) {
    foreach (var f in store.folders (account)) if (f.path == path) return f;
    return null;
}

async void run_graph_shared (Store store) {
    stdout.printf ("# graph shared mailbox\n");
    var a = new Account ();
    a.id = "acc-graph-shared";
    a.email = "tester@outlook.test";
    a.full_name = "Alex Tester";
    a.protocol = "graph";
    a.api_url = base_url + "/graph/v1.0/";
    a.source = "online:test";
    a.online = new TestCredentials (true);
    var s = new AccountSync (a, store);
    yield s.sync_all ();
    try {
        var opened = yield s.backend.open_shared ("team@outlook.test");
        bool all_shared = opened.size == 7;
        foreach (var r in opened) if (!r.shared || !r.path.has_prefix ("team@outlook.test|")) all_shared = false;
        check (all_shared, "graph: shared mailbox folders listed through users/{id}/mailFolders (got %d)".printf (opened.size));
    } catch (Error e) {
        check (false, "graph: open shared mailbox %s".printf (e.message));
    }
    check ("team@outlook.test" in a.shared_mailboxes (), "graph: shared mailbox remembered on the account");
    bool denied = false;
    try {
        yield s.backend.open_shared ("boss@outlook.test");
    } catch (Error e) {
        denied = true;
    }
    check (denied && !("boss@outlook.test" in a.shared_mailboxes ()), "graph: a mailbox without delegation is refused and not remembered");
    yield s.sync_all ();
    var inbox = folder_at (store, a.id, "team@outlook.test|f-inbox");
    check (inbox != null && inbox.shared, "graph: shared inbox kept after a full sync");
    check (store.folder_by_role (a.id, "inbox") != null && !store.folder_by_role (a.id, "inbox").shared, "graph: own inbox keeps its role");
    if (inbox == null) {
        s.stop ();
        return;
    }
    yield s.refresh_folder (inbox);
    var ids = new Gee.ArrayList<int64?> ();
    ids.add (inbox.id);
    var msgs = store.list (ids, false);
    check (msgs.size == 4, "graph: shared inbox messages synced (got %d)".printf (msgs.size));
    MessageInfo? launch = null;
    foreach (var m in msgs) if (m.subject == "Launch plan") launch = m;
    if (launch != null) {
        try {
            var body = yield s.load_body (launch);
            check (body != null && new MimeMessage (body).body_text ().contains ("plan for the launch"), "graph: shared message body downloaded");
        } catch (Error e) {
            check (false, "graph: shared body %s".printf (e.message));
        }
        var one = new Gee.ArrayList<MessageInfo> ();
        one.add (launch);
        yield s.set_flag (one, MessageFlags.SEEN, true);
    }
    var b = new MessageBuilder ();
    b.from = new Address ("Team", "team@outlook.test");
    b.to.add (new Address ("Giulia Rossi", "giulia.rossi@example.com"));
    b.subject = "Sent for the team";
    b.text = "From the shared mailbox.";
    var item = new OutboxItem ();
    item.raw = b.build (false);
    item.recipients = "giulia.rossi@example.com";
    item.sender = "team@outlook.test";
    try {
        yield s.send (item);
        var st = yield state ("graph-shared");
        bool sent = false;
        foreach (var n in st.get_array_member ("sent").get_elements ()) if (n.get_string ().contains ("Sent for the team")) sent = true;
        check (sent, "graph: mail sent as the shared mailbox through users/{id}/sendMail");
        var mm = mock_message (st, "Launch plan");
        check (mm != null && mm.get_boolean_member ("read"), "graph: read flag set in the shared mailbox");
        var own = yield state ("graph");
        bool leaked = false;
        foreach (var n in own.get_array_member ("sent").get_elements ()) if (n.get_string ().contains ("Sent for the team")) leaked = true;
        check (!leaked, "graph: shared send does not go through the own mailbox");
    } catch (Error e) {
        check (false, "graph: shared send %s".printf (e.message));
    }
    s.stop ();
}

async void run_protocol_switch (Store store) {
    stdout.printf ("# imap to graph switch\n");
    try {
        var session = new Soup.Session ();
        yield session.send_and_read_async (new Soup.Message ("GET", base_url + "/_reset"), Priority.DEFAULT, null);
    } catch (Error e) {
        check (false, "switch: reset mock %s".printf (e.message));
    }
    string id = "acc-switch";
    var inbox = store.upsert_folder (id, "INBOX", "INBOX", "inbox", "/");
    store.upsert_folder (id, "Sent", "Sent", "sent", "/");
    var projects = store.upsert_folder (id, "Projects", "Projects", "", "/");
    store.set_favorite (projects.id, true);
    var keep = store.local_folder (id, "Local/Keep", "Keep", "");
    store.insert_message (keep, 1, 0, 0, MailBackend.synth_header ("Ana <ana.souza@example.net>", "tester@outlook.test", "", "Kept offline", 1700000000, "<kept@example.net>", "", "").data, 1700000000);
    int64 old = store.insert_message (inbox, 7, MessageFlags.SEEN | MessageFlags.PINNED, 0,
        MailBackend.synth_header ("Giulia Rossi <giulia.rossi@example.com>", "tester@outlook.test", "", "Launch plan", 1700000000, "<launch@example.com>", "", "").data, 1700000000);
    store.set_due (old, 1900000000);
    store.add_outbox (id, "Subject: Waiting\r\n\r\nbody\r\n".data, "giulia.rossi@example.com", "tester@outlook.test", 0, "Waiting");
    store.add_snooze (id, "<launch@example.com>", 1900000000, "Projects", "Launch plan");
    store.set_value (id, "custom", "kept");
    store.begin_protocol_switch (id);
    var left = store.folders (id);
    check (left.size == 1 && left[0].path == "Local/Keep", "switch: server folders dropped, local folder kept (%d left)".printf (left.size));
    var kids = new Gee.ArrayList<int64?> ();
    kids.add (left[0].id);
    check (store.list (kids, false).size == 1, "switch: messages in local folders kept");
    check (store.outbox (id).size == 1 && store.get_value (id, "custom") == "kept", "switch: outbox and account settings kept");
    var a = new Account ();
    a.id = id;
    a.email = "tester@outlook.test";
    a.protocol = "graph";
    a.api_url = base_url + "/graph/v1.0/";
    a.source = "online:test";
    a.online = new TestCredentials (true);
    var s = new AccountSync (a, store);
    Gee.Map<string, string>? moved = null;
    s.folders_remapped.connect ((m) => { moved = m; });
    yield s.sync_all ();
    check (s.state == SyncState.IDLE, "switch: first Graph sync finished (%s)".printf (s.error_text));
    check (moved != null && moved["INBOX"] == "f-inbox" && moved["Projects"] == "f-projects" && moved["Sent"] == "f-sent", "switch: old folders matched to Graph folders");
    var fp = folder_at (store, id, "f-projects");
    check (fp != null && fp.favorite, "switch: favorite folder kept");
    bool snooze_moved = false;
    foreach (var z in store.snoozes ()) if (z.account == id && z.origin == "f-projects") snooze_moved = true;
    check (snooze_moved, "switch: snoozed message returns to the matching Graph folder");
    var gin = folder_at (store, id, "f-inbox");
    MessageInfo? launch = null;
    if (gin != null) {
        var ids = new Gee.ArrayList<int64?> ();
        ids.add (gin.id);
        foreach (var m in store.list (ids, false)) if (m.subject == "Launch plan") launch = m;
    }
    check (launch != null && launch.pinned, "switch: pinned state carried to the Graph copy");
    check (launch != null && launch.due == 1900000000, "switch: follow-up date carried to the Graph copy");
    check (folder_at (store, id, "Local/Keep") != null && store.outbox (id).size == 1, "switch: local folder and outbox survive the Graph sync");
    string rules_dir = Path.build_filename (Environment.get_tmp_dir (), "lettere-switch-rules-" + Uuid.string_random ().substring (0, 8));
    DirUtils.create_with_parents (rules_dir, 0700);
    var rules = new RuleStore (rules_dir);
    var rule = new Rule ();
    rule.account = id;
    rule.actions.add (new RuleAction ("move", "Projects"));
    rules.rules.add (rule);
    check (moved != null && rules.remap_folders (id, moved) && rule.actions[0].value == "f-projects", "switch: rules follow the moved folder");
    FileUtils.remove (Path.build_filename (rules_dir, "rules.json"));
    DirUtils.remove (rules_dir);
    s.stop ();
}
