using Singularity.Apps.Lettere;

string fixtures;

uint8[] fixture (string name) {
    try {
        uint8[] data;
        FileUtils.get_data (Path.build_filename (fixtures, name), out data);
        return data;
    } catch (Error e) {
        error ("fixture %s: %s", name, e.message);
    }
}

void test_imap_fetch_literal () {
    try {
        var r = ImapResponse.parse (fixture ("fetch_literal.txt"));
        assert (r.tag == "*");
        assert (r.word (1) == "FETCH");
        var f = FetchItem.from (r);
        assert (f != null);
        assert (f.seq == 12);
        assert (f.uid == 34);
        assert (f.has ("\\Flagged"));
        assert (f.has ("\\seen"));
        assert (f.size == 4286);
        assert (f.modseq == 12121231000);
        assert (f.internaldate == "17-Jul-1996 02:44:25 -0700");
        assert (f.header != null);
        var part = Mime.parse_part (f.header, "1", 0);
        assert (part.decoded_header ("Subject") == "Ciao");
    } catch (Error e) {
        error (e.message);
    }
}

void test_imap_tricky_literal () {
    try {
        var r = ImapResponse.parse (fixture ("fetch_tricky.txt"));
        var f = FetchItem.from (r);
        assert (f != null);
        assert (f.uid == 9);
        assert (Mime.bytes_to_string (f.body) == "(a) \"b\" {1");
        assert (f.has ("\\Seen"));
    } catch (Error e) {
        error (e.message);
    }
}

void test_imap_list_and_codes () {
    try {
        var r = ImapResponse.parse (fixture ("list_sent.txt"));
        assert (r.word (0) == "LIST");
        assert (r.values[1].is_list);
        assert (r.values[2].str () == "/");
        assert (r.values[3].str () == "Sent Items");
        var info = new MailboxInfo ();
        info.name = r.values[3].str ();
        foreach (var a in r.values[1].items) info.attributes.add (a.text);
        assert (AccountSync.role_for (info) == "sent");

        var u = ImapResponse.parse (fixture ("list_utf7.txt"));
        string name = Utf7.decode (u.values[3].str ());
        assert (name == "Posta é inviata");
        assert (Utf7.encode (name) == "Posta &AOk- inviata");
        assert (Utf7.encode ("Tom & Jerry") == "Tom &- Jerry");
        assert (Utf7.decode (Utf7.encode ("日本語 😀")) == "日本語 😀");

        var ok = ImapResponse.parse (fixture ("ok_code.txt"));
        assert (ok.status == "OK");
        assert (ok.code_word == "UIDVALIDITY");
        assert (ok.code_arg == "3857529045");
        assert (ok.text == "UIDs valid");

        var s = ImapResponse.parse (fixture ("search.txt"));
        assert (s.word (0) == "SEARCH");
        assert (s.values.size == 4);
        assert (s.values[3].number () == 882);

        var tagged = ImapResponse.parse ("L0001 NO [AUTHENTICATIONFAILED] Invalid credentials\r\n".data);
        assert (tagged.tag == "L0001");
        assert (tagged.status == "NO");
        assert (tagged.code == "AUTHENTICATIONFAILED");

        var cont = ImapResponse.parse ("+ idling\r\n".data);
        assert (cont.tag == "+");

        var caps = ImapResponse.parse ("* CAPABILITY IMAP4rev1 IDLE AUTH=PLAIN\r\n".data);
        assert (caps.values.size == 4);
        assert (caps.values[3].text == "AUTH=PLAIN");

        var nil = ImapResponse.parse ("* 1 FETCH (UID 5 BODY[HEADER] NIL)\r\n".data);
        var nf = FetchItem.from (nil);
        assert (nf.uid == 5 && nf.header.length == 0);

        assert (ImapClient.literal_size ("* 1 FETCH (BODY[] {123}", 23) == 123);
        assert (ImapClient.literal_size ("A1 APPEND x {45+}", 17) == 45);
        assert (ImapClient.literal_size ("* OK done", 9) == -1);
        assert (ImapClient.quote ("a\"b\\c") == "\"a\\\"b\\\\c\"");
        assert (ImapClient.needs_literal ("pässword"));
        assert (!ImapClient.needs_literal ("plain"));
        string plain = ImapClient.sasl_plain ("u", "p");
        uint8[] dec = Base64.decode (plain);
        assert (dec.length == 4 && dec[0] == 0 && dec[1] == 'u' && dec[2] == 0 && dec[3] == 'p');
    } catch (Error e) {
        error (e.message);
    }
}

void test_imap_malformed () {
    bool thrown = false;
    try {
        ImapResponse.parse ("* 1 FETCH (UID 5 BODY[] {50}\r\nshort)\r\n".data);
    } catch (MailError e) {
        thrown = true;
    }
    assert (thrown);
    thrown = false;
    try {
        ImapResponse.parse ("* 1 FETCH (UID 5 FLAGS (\\Seen)\r\n".data);
    } catch (MailError e) {
        thrown = true;
    }
    assert (thrown);
}

void test_mime_mixed () {
    var m = new MimeMessage (fixture ("mixed.eml"));
    assert (m.subject == "Report trimestrale € e budget");
    assert (m.from.size == 1);
    assert (m.from[0].name == "Giulia Rossi");
    assert (m.from[0].email == "giulia@example.org");
    var to = m.to;
    assert (to.size == 2);
    assert (to[0].name == "Bianchi, Marco");
    assert (to[0].email == "marco@example.org");
    assert (to[1].name == "Ana Souza");
    assert (to[1].email == "ana@example.com");
    assert (m.cc.size == 0);
    assert (m.message_id == "abc123@example.org");
    assert (m.in_reply_to == "root1@example.org");
    assert (m.references == "root1@example.org mid2@example.org");
    assert (m.text_plain.has_prefix ("Ciao Marco, il caffè è pronto. Soft break."));
    assert (m.text_html.contains ("<b>Marco</b>"));
    assert (m.attachments.size == 1);
    assert (m.attachments[0].filename == "rapporto è.pdf");
    assert (m.attachments[0].content_type == "application/pdf");
    assert (Mime.bytes_to_string (m.attachments[0].data.get_data ()) == "%PDF-1.4 test");
    assert (m.inline_parts.has_key ("logo@x"));
    assert (m.has_remote_content ());
    var d = m.date;
    assert (d != null);
    assert (d.to_unix () == 1057049557);
    string doc = Html.document (m.text_html, m.inline_parts, false);
    assert (doc.contains ("data:image/png;base64,"));
    assert (!doc.contains ("cid:logo@x"));
    assert (doc.contains ("img-src data:;"));
    assert (doc.contains ("script-src 'none'"));
    assert (Html.document (m.text_html, m.inline_parts, true).contains ("img-src data: https: http:"));
}

void test_mime_charsets () {
    var m = new MimeMessage (fixture ("latin1_subject.eml"));
    assert (m.subject == "Café crème");
    assert (m.text_plain.strip () == "Prezzo: 5€ “quoted”");
    var lf = new MimeMessage (fixture ("plain_lf.eml"));
    assert (lf.subject == "no crlf");
    assert (lf.text_plain.has_prefix ("line one\n.dot line"));
    assert (Mime.decode_words ("=?utf-8?b?5pel5pys6Kqe?=") == "日本語");
    assert (Mime.decode_words ("=?UTF-8?Q?a?= =?UTF-8?Q?b?=") == "ab");
    assert (Mime.decode_words ("plain =?UTF-8?Q?x?= tail") == "plain x tail");
    assert (Mime.decode_words ("=?UTF-8?B?w6g=?==?UTF-8?B?w6g=?=") == "èè");
    assert (Mime.decode_words ("=?UTF-8?B?4oKs?=") == "€");
    assert (Mime.decode_words ("=?UTF-8?B?4g==?= =?UTF-8?B?gqw=?=") == "€");
    assert (Mime.decode_words ("=?iso-2022-jp?B?GyRCRnxLXDhsGyhC?=") == "日本語");
    assert (Mime.decode_words ("broken =?UTF-8?X?abc?= end") == "broken =?UTF-8?X?abc?= end");
    assert (Mime.to_utf8 ({ 0xe8 }, "iso-8859-1") == "è");
    assert (Mime.to_utf8 ({ 0xff, 0xfe }, "utf-8").validate ());
}

void test_mime_encoders () {
    string qp = Mime.encode_qp ("città = bella " + string.nfill (90, 'x') + "\nsecond line ");
    assert (!qp.contains ("città"));
    assert (qp.contains ("citt=C3=A0 =3D bella"));
    foreach (string line in qp.split ("\r\n")) assert (line.length <= 76);
    assert (qp.has_suffix ("line=20"));
    string back = Mime.to_utf8 (Mime.decode_qp (qp.data), "utf-8");
    assert (back == "città = bella " + string.nfill (90, 'x') + "\r\nsecond line ");
    string ew = Mime.encode_words ("Perché no? " + string.nfill (60, 'a'));
    foreach (string line in ew.split ("\r\n")) assert (line.strip ().length <= 76);
    assert (Mime.decode_words (ew) == "Perché no? " + string.nfill (60, 'a'));
    assert (Mime.encode_words ("ascii only") == "ascii only");
    assert (Mime.encode_phrase ("Rossi, Giulia") == "\"Rossi, Giulia\"");
}

void test_mime_builder_roundtrip () {
    var b = new MessageBuilder ();
    b.from = new Address ("Giulia Rössi", "giulia@example.org");
    b.to.add (new Address ("Marco", "marco@example.org"));
    b.cc.add (new Address ("", "ana@example.com"));
    b.bcc.add (new Address ("", "secret@example.com"));
    b.subject = "Re: Caffè alle 10?";
    b.text = "Ciao,\n.linea con punto\n\n> citazione";
    b.html = "<p>Ciao <b>Marco</b></p>";
    b.in_reply_to = "orig@example.org";
    b.references = "root@example.org orig@example.org";
    b.attachments.add (new OutgoingAttachment ("nota è.txt", "text/plain", new Bytes ("contenuto".data)));
    uint8[] raw = b.build ();
    string s = Mime.bytes_to_string (raw);
    assert (!s.contains ("secret@example.com"));
    assert (!s.contains ("\r\n\n"));
    var m = new MimeMessage (raw);
    assert (m.subject == "Re: Caffè alle 10?");
    assert (m.from[0].name == "Giulia Rössi");
    assert (m.to[0].email == "marco@example.org");
    assert (m.cc[0].email == "ana@example.com");
    assert (m.in_reply_to == "orig@example.org");
    assert (m.references == "root@example.org orig@example.org");
    assert (m.text_plain.replace ("\r\n", "\n") == "Ciao,\n.linea con punto\n\n> citazione\n" || m.text_plain.replace ("\r\n", "\n") == "Ciao,\n.linea con punto\n\n> citazione");
    assert (m.text_html.contains ("<b>Marco</b>"));
    assert (m.attachments.size == 1);
    assert (m.attachments[0].filename == "nota è.txt");
    assert (Mime.bytes_to_string (m.attachments[0].data.get_data ()) == "contenuto");
    assert (m.message_id.has_suffix ("@example.org"));
    assert (b.recipients ().size == 3);
    uint8[] with_bcc = b.build (true);
    assert (Mime.bytes_to_string (with_bcc).contains ("Bcc: secret@example.com"));
    string stripped = Mime.bytes_to_string (AccountSync.strip_bcc (with_bcc));
    assert (!stripped.contains ("secret@example.com"));
    assert (new MimeMessage (stripped.data).subject == "Re: Caffè alle 10?");
}

void test_service_outgoing () {
    uint8[] raw = ("From: Spoofed <spoof@example.org>\r\n" +
                   "To: visible@example.org\r\n" +
                   "Bcc: private@example.org\r\n" +
                   "Subject: Service message\r\n\r\nBody\r\n").data;
    var outgoing = new Outgoing (raw);
    assert (outgoing.recipients.size == 2);
    assert (outgoing.recipients.contains ("private@example.org"));
    var rewritten = Mime.bytes_to_string (outgoing.with_from (new Address ("Test Sender", "test@lettere.test")));
    assert (rewritten.contains ("From: Test Sender <test@lettere.test>\r\n"));
    assert (!rewritten.contains ("Spoofed <spoof@example.org>"));
    assert (!rewritten.contains ("Bcc:"));
    assert (!rewritten.contains ("private@example.org"));
    assert (rewritten.contains ("To: visible@example.org\r\n"));
    assert (rewritten.has_suffix ("Subject: Service message\r\n\r\nBody\r\n"));
    assert (!rewritten.contains ("\r\n\r\n\r\n"));

    uint8[] folded = ("From: Spoofed <spoof@example.org>\r\n" +
                      "To: visible@example.org\r\n" +
                      "Bcc: private@example.org,\r\n" +
                      " folded@example.org\r\n" +
                      "Subject: Folded Bcc\r\n\r\nBody\r\n").data;
    string folded_rewritten = Mime.bytes_to_string (new Outgoing (folded).with_from (new Address ("Test Sender", "test@lettere.test")));
    assert (!folded_rewritten.contains ("Bcc:"));
    assert (!folded_rewritten.contains ("private@example.org"));
    assert (!folded_rewritten.contains ("folded@example.org"));
}

void test_addresses_and_dates () {
    var l = Mime.parse_addresses ("Team: a@x.org, \"B, C\" <b@x.org>;, =?UTF-8?Q?J=C3=BCrgen?= <j@x.de>, plain@x.org");
    assert (l.size == 4);
    assert (l[0].email == "a@x.org");
    assert (l[1].name == "B, C");
    assert (l[2].name == "Jürgen");
    assert (l[3].email == "plain@x.org" && l[3].name == "");
    assert (Mime.parse_addresses ("undisclosed-recipients:;").size == 0);
    var d1 = Mime.parse_date ("Fri, 21 Nov 1997 09:55:06 -0600");
    assert (d1 != null && d1.to_unix () == 880127706);
    var d2 = Mime.parse_date ("21 Nov 97 09:55:06 GMT (comment)");
    assert (d2 != null && d2.get_year () == 1997);
    var d3 = Mime.parse_date ("Mon, 3 Mar 2025 8:05 EST");
    assert (d3 != null && d3.to_utc ().get_hour () == 13);
    assert (Mime.parse_date ("garbage") == null);
    var now = new DateTime.now_local ();
    var back = Mime.parse_date (Mime.format_date (now));
    assert (back != null && back.to_unix () == now.to_unix ());
    assert (Mime.normalize_subject ("Re: RE: Fwd: Hello") == "Hello");
    assert (Mime.normalize_subject ("R: I: Ciao") == "Ciao");
    string[] ids = Mime.parse_ids ("<a@x> <b@x>\r\n <a@x>");
    assert (ids.length == 2 && ids[1] == "b@x");
}

void test_smtp () {
    string out1 = Mime.bytes_to_string (SmtpClient.dot_stuff ("a\n.b\r\n..c\r\nend".data));
    assert (out1 == "a\r\n..b\r\n...c\r\nend\r\n.\r\n");
    string out2 = Mime.bytes_to_string (SmtpClient.dot_stuff (".start\r\n".data));
    assert (out2 == "..start\r\n.\r\n");
    try {
        var multi = new Gee.ArrayList<string> ();
        multi.add ("250-mail.example.org");
        multi.add ("250-AUTH PLAIN LOGIN");
        multi.add ("250 STARTTLS");
        var r = SmtpClient.parse_reply (multi);
        assert (r.code == 250);
        assert (r.lines.size == 3);
        assert (r.lines[1] == "AUTH PLAIN LOGIN");
    } catch (Error e) {
        error (e.message);
    }
    bool thrown = false;
    try {
        var bad = new Gee.ArrayList<string> ();
        bad.add ("xx");
        SmtpClient.parse_reply (bad);
    } catch (Error e) {
        thrown = true;
    }
    assert (thrown);
}

void test_threading () {
    var list = new Gee.ArrayList<ThreadInput> ();
    list.add (new ThreadInput (1, "root@x", "", ""));
    list.add (new ThreadInput (2, "r1@x", "root@x", "root@x"));
    list.add (new ThreadInput (3, "r2@x", "r1@x", "root@x r1@x"));
    list.add (new ThreadInput (4, "other@x", "", ""));
    list.add (new ThreadInput (5, "late@x", "", "missing@x r2@x"));
    list.add (new ThreadInput (6, "orphan2@x", "missing@x", ""));
    list.add (new ThreadInput (7, "", "", ""));
    list.add (new ThreadInput (8, "r1@x", "root@x", "root@x"));
    var g = new Threader ().group (list);
    assert (g[1] == g[2]);
    assert (g[2] == g[3]);
    assert (g[3] == g[5]);
    assert (g[5] == g[6]);
    assert (g[8] == g[1]);
    assert (g[4] != g[1]);
    assert (g[7] != g[4] && g[7] != g[1]);
    var reversed = new Gee.ArrayList<ThreadInput> ();
    for (int i = list.size - 1; i >= 0; i--) reversed.add (list[i]);
    var g2 = new Threader ().group (reversed);
    assert (g2[1] == g[1]);
    assert (g2[4] == g[4]);
}

void test_autoconfig () {
    var xml = Mime.bytes_to_string (fixture ("autoconfig.xml"));
    var cfg = Autoconfig.parse (xml, "mario@example.org");
    assert (cfg != null);
    assert (cfg.provider == "Example Mail");
    assert (cfg.imap.host == "imap.example.org");
    assert (cfg.imap.port == 993);
    assert (cfg.imap.security == Security.TLS);
    assert (cfg.imap.username == "mario@example.org");
    assert (cfg.smtp.host == "smtp.example.org");
    assert (cfg.smtp.port == 587);
    assert (cfg.smtp.security == Security.STARTTLS);
    var oauth = Autoconfig.parse (Mime.bytes_to_string (fixture ("autoconfig_oauth.xml")), "x@big.example");
    assert (oauth != null && oauth.oauth_only);
    assert (Autoconfig.parse ("<not xml", "a@b.c") == null);
    var guess = Autoconfig.guess ("someone@domain.example");
    assert (guess.imap.host == "imap.domain.example" && guess.smtp.port == 465);
    assert (Autoconfig.needs_app_password ("x@gmail.com"));
    assert (!Autoconfig.needs_app_password ("x@lettere.test"));
}

void test_html () {
    string t = Html.to_text ("<html><head><style>p{}</style></head><body><p>Hello&nbsp;<b>you</b> &amp; me</p><ul><li>one</li><li>two</li></ul><script>x()</script>&#8364;&#x41;</body></html>");
    assert (t.contains ("Hello you & me"));
    assert (t.contains ("• one"));
    assert (!t.contains ("x()"));
    assert (!t.contains ("p{}"));
    assert (t.contains ("€A"));
    assert (Html.has_remote ("<img src=\"https://a/b.png\">"));
    assert (Html.has_remote ("<div style=\"background:url(http://x/y)\">"));
    assert (Html.has_remote ("<link rel=stylesheet href='https://x/s.css'>"));
    assert (!Html.has_remote ("<a href=\"https://example.org\">link</a><img src=\"data:image/png;base64,AA\">"));
    assert (Html.escape ("<a&b>") == "&lt;a&amp;b&gt;");
}

void test_contacts () {
    var list = ContactBook.parse_vcards (Mime.bytes_to_string (fixture ("contact.vcf")));
    assert (list.size == 3);
    assert (list[0].name == "Giulia Rossi" && list[0].email == "giulia@example.org");
    assert (list[1].email == "g.rossi@example.net");
    assert (list[2].name == "Ana Souza");
    var book = new ContactBook.with_dirs ({ fixtures });
    assert (book.match ("sou", 5).size == 1);
    assert (book.match ("g", 5).size == 2);
}

void test_store () {
    try {
        string db = Path.build_filename (Environment.get_tmp_dir (), "lettere-test-%s.db".printf (Uuid.string_random ().substring (0, 8)));
        var store = new Store (db);
        var inbox = store.upsert_folder ("acc", "INBOX", "INBOX", "inbox", "/");
        var sent = store.upsert_folder ("acc", "Sent", "Sent", "sent", "/");
        var trash = store.upsert_folder ("acc", "Trash", "Trash", "trash", "/");
        int64 a = store.insert_message (inbox, 1, 0, 100, "From: Giulia <g@x.org>\r\nSubject: Piano di lancio\r\nMessage-ID: <root@x>\r\nDate: Mon, 1 Sep 2025 10:00:00 +0000\r\n\r\n".data, 0);
        int64 b = store.insert_message (sent, 1, MessageFlags.SEEN, 100, "From: Me <me@x.org>\r\nTo: Giulia <g@x.org>\r\nSubject: Re: Piano di lancio\r\nMessage-ID: <reply@x>\r\nIn-Reply-To: <root@x>\r\nDate: Mon, 1 Sep 2025 11:00:00 +0000\r\n\r\n".data, 0);
        int64 c = store.insert_message (inbox, 2, MessageFlags.SEEN | MessageFlags.FLAGGED, 100, "From: Ana <ana@x.org>\r\nSubject: Lisboa\r\nMessage-ID: <lis@x>\r\nDate: Tue, 2 Sep 2025 10:00:00 +0000\r\n\r\n".data, 0);
        int64 d = store.insert_message (inbox, 3, MessageFlags.SEEN, 100, "From: Giulia <g@x.org>\r\nSubject: Re: Piano di lancio\r\nMessage-ID: <third@x>\r\nReferences: <root@x> <reply@x>\r\nDate: Wed, 3 Sep 2025 10:00:00 +0000\r\n\r\n".data, 0);
        store.insert_message (trash, 1, MessageFlags.SEEN, 100, "From: Spam <s@x.org>\r\nSubject: Old\r\nMessage-ID: <old@x>\r\nIn-Reply-To: <root@x>\r\nDate: Wed, 3 Sep 2025 09:00:00 +0000\r\n\r\n".data, 0);
        store.rethread ("acc");
        assert (store.message (a).thread == store.message (b).thread);
        assert (store.message (a).thread == store.message (d).thread);
        assert (store.message (a).thread != store.message (c).thread);
        var folders = new Gee.ArrayList<int64?> ();
        folders.add (inbox.id);
        var threads = store.list (folders, true);
        assert (threads.size == 2);
        assert (threads[0].id == d);
        assert (threads[0].thread_count == 3);
        assert (threads[0].thread_unread);
        assert (threads[1].thread_flagged);
        var flat = store.list (folders, false);
        assert (flat.size == 3);
        var conv = store.conversation ("acc", store.message (a).thread, false);
        assert (conv.size == 3);
        assert (conv[0].id == a && conv[2].id == d);
        store.set_body (c, "From: Ana <ana@x.org>\r\nSubject: Lisboa\r\nContent-Type: text/plain; charset=utf-8\r\n\r\nFim de semana em Lisboa com pastéis de nata\r\n".data);
        var hits = store.search ("pasteis");
        assert (hits.contains (c));
        assert (store.search ("Giu").contains (a));
        assert (store.search ("lanc").size == 3);
        assert (store.search ("\"*").size == 0);
        assert (store.message (c).preview.has_prefix ("Fim de semana"));
        assert (store.body (c) != null);
        assert (store.body (a) == null);
        store.set_flags (inbox.id, 1, MessageFlags.SEEN);
        store.count_folder (inbox);
        assert (inbox.unread == 0 && inbox.total == 3);
        var sugg = store.suggest ("giu", 5);
        assert (sugg.size == 1 && sugg[0].email == "g@x.org");
        store.delete_uid (inbox.id, 2);
        assert (store.search ("pasteis").size == 0);
        assert (store.missing_bodies (inbox.id, 1000, 10).size == 2);
        int64 ob = store.add_outbox ("acc", "raw".data, "a@x", "me@x", 10);
        assert (store.outbox ().size == 1 && store.outbox ()[0].id == ob);
        store.remove_outbox (ob);
        assert (store.outbox ().size == 0);
        store.add_op ("acc", "flag", "INBOX", "1,2", "+FLAGS \\Seen");
        assert (store.ops ("acc").size == 1);
        store.remove_account ("acc");
        assert (store.folders ("acc").size == 0);
        assert (store.ops ("acc").size == 0);
        assert (Store.fts_query ("foo  \"bar") == "\"foo\"* \"bar\"*");
        store = null;
        foreach (string suffix in new string[] { "", "-wal", "-shm" }) FileUtils.remove (db + suffix);
    } catch (Error e) {
        error (e.message);
    }
}


void test_search_query () {
    var q = SearchQuery.parse ("from:giulia subject:\"launch plan\" has:attachment is:unread -in:trash before:2026-10-01 larger:1m budget");
    assert (q.terms.size == 8);
    assert (q.terms[0].key == "from" && q.terms[0].value == "giulia");
    assert (q.terms[1].key == "subject" && q.terms[1].value == "launch plan");
    assert (q.terms[4].negated && q.terms[4].key == "in");
    string imap = q.to_imap ();
    assert ("FROM \"giulia\"" in imap);
    assert ("SUBJECT \"launch plan\"" in imap);
    assert ("UNSEEN" in imap);
    assert ("BEFORE 1-Oct-2026" in imap);
    assert ("LARGER 1048576" in imap);
    assert ("TEXT \"budget\"" in imap);
    assert ("from:giulia" in q.to_gmail () && "has:attachment" in q.to_gmail () && "is:unread" in q.to_gmail ());
    assert ("from:\"giulia\"" in q.to_kql () && "hasattachments:true" in q.to_kql ());
    var binds = new Gee.ArrayList<string> ();
    string sql = q.to_sql (binds);
    assert ("m.has_attach = 1" in sql && "(m.flags & 1) = 0" in sql && "NOT (lower(f.name)" in sql);
    assert (SearchQuery.parse ("da:marco oggetto:piano").terms[0].key == "from");
    assert (SearchQuery.parse_size ("10k") == 10240);
    assert (SearchQuery.parse_day ("2026-02-30", false) == -1 || SearchQuery.parse_day ("2026-02-30", false) > 0);
    assert (SearchQuery.parse ("in:all hello").all_folders);
}

void test_store_query () {
    try {
        string db = Path.build_filename (Environment.get_tmp_dir (), "lettere-q-%s.db".printf (Uuid.string_random ().substring (0, 8)));
        var store = new Store (db);
        var inbox = store.upsert_folder ("acc", "INBOX", "INBOX", "inbox", "/");
        int64 a = store.insert_message (inbox, 1, 0, 5000000, "From: Giulia <g@x.org>\r\nSubject: Budget\r\nContent-Type: multipart/mixed; boundary=x\r\nMessage-ID: <a@x>\r\nList-Unsubscribe: <mailto:u@x.org>\r\nImportance: high\r\nDate: Mon, 1 Sep 2025 10:00:00 +0000\r\n\r\n".data, 0, "", "", "Work");
        int64 b = store.insert_message (inbox, 2, MessageFlags.SEEN, 100, "From: Ana <ana@x.org>\r\nSubject: Lisboa\r\nMessage-ID: <b@x>\r\nDate: Tue, 2 Sep 2025 10:00:00 +0000\r\n\r\n".data, 0);
        var ma = store.message (a);
        assert (ma.importance == 1 && ma.list_unsubscribe == "<mailto:u@x.org>" && ma.has_category ("work"));
        assert (ma.focus == 0);
        assert (store.message (b).focus == 1);
        assert (store.query (SearchQuery.parse ("from:giulia"), null).size == 1);
        assert (store.query (SearchQuery.parse ("is:unread has:attachment larger:1m"), null).size == 1);
        assert (store.query (SearchQuery.parse ("category:work"), null)[0].id == a);
        assert (store.query (SearchQuery.parse ("-from:giulia"), null)[0].id == b);
        assert (store.query (SearchQuery.parse ("after:2025-09-02"), null).size == 1);
        var o = new ListOptions ();
        o.sort = SortKey.SUBJECT;
        o.ascending = true;
        var ids = new Gee.ArrayList<int64?> ();
        ids.add (inbox.id);
        assert (store.list (ids, false, null, 100, o)[0].subject == "Budget");
        o.filter = ListFilter.UNREAD;
        assert (store.list (ids, false, null, 100, o).size == 1);
        o.filter = ListFilter.OTHER;
        assert (store.list (ids, false, null, 100, o)[0].id == a);
        store.set_flags_by_id (b, MessageFlags.SEEN | MessageFlags.PINNED);
        o.filter = ListFilter.ALL;
        o.sort = SortKey.DATE;
        o.ascending = false;
        assert (store.list (ids, false, null, 100, o)[0].id == b);
        store.set_sender_focus ("g@x.org", 1);
        assert (store.message (a).focus == 1);
        store.add_snooze ("acc", "a@x", 10, "INBOX", "Budget");
        assert (store.snoozes ().size == 1);
        store.set_value ("acc", "k", "v");
        assert (store.get_value ("acc", "k") == "v");
        assert (Keywords.to_category (Keywords.to_keyword ("Work Items")) == "Work Items");
        assert (Keywords.to_category (Keywords.to_keyword ("Città")) == "Città");
        var tlist = new Gee.ArrayList<string> ();
        tlist.add ("\\Seen");
        tlist.add ("Work_Items");
        tlist.add ("$Pinned");
        assert (Store.keywords_from (tlist) == "Work Items");
        assert ((Store.flags_from (tlist) & MessageFlags.PINNED) != 0);
        store = null;
        foreach (string suffix in new string[] { "", "-wal", "-shm" }) FileUtils.remove (db + suffix);
    } catch (Error e) {
        error (e.message);
    }
}

void test_conversation_ids () {
    var list = new Gee.ArrayList<ThreadInput> ();
    var a = new ThreadInput (1, "a@x", "", "");
    a.conv = "C1";
    var b = new ThreadInput (2, "b@x", "", "");
    b.conv = "C1";
    list.add (a);
    list.add (b);
    list.add (new ThreadInput (3, "c@x", "", ""));
    var g = new Threader ().group (list);
    assert (g[1] == g[2] && g[1] != g[3]);
}

void test_sieve () {
    var r = new AutoReply ();
    r.enabled = true;
    r.subject = "Away \"now\"";
    r.message = "Back Monday.\n.hidden line";
    r.start = 1790000000;
    r.end = 1790600000;
    string s = SieveScript.with_vacation ("", r, "me@x.org");
    assert ("require [\"date\", \"relational\", \"vacation\"];" in s);
    var back = SieveScript.parse_vacation (s);
    assert (back.enabled && back.subject == "Away \"now\"" && back.message == "Back Monday.\n.hidden line");
    assert (back.start == 1790000000 && back.end == 1790600000);
    var rules = new RuleStore (Path.build_filename (Environment.get_tmp_dir (), "lettere-sieve-%s".printf (Uuid.string_random ().substring (0, 6))));
    var rule = new Rule ();
    rule.on_server = true;
    rule.conditions.add (new RuleCondition ("from", "contains", "news@"));
    rule.conditions.add (new RuleCondition ("subject", "starts", "[list]"));
    rule.actions.add (new RuleAction ("move", "Lists"));
    rule.actions.add (new RuleAction ("read", ""));
    rules.rules.add (rule);
    var paths = new Gee.HashMap<string, string> ();
    paths["Lists"] = "INBOX.Lists";
    string script = rules.to_sieve ("acc", paths);
    assert ("fileinto \"INBOX.Lists\";" in script);
    assert ("address :contains \"from\" \"news@\"" in script);
    assert ("header :matches \"subject\" \"[list]*\"" in script);
    assert ("addflag \"\\\\Seen\";" in script);
    string both = SieveScript.with_rules (s, script);
    assert (SieveScript.parse_vacation (both).enabled);
    assert ("fileinto" in both && "vacation" in both);
    var off = new AutoReply ();
    string without = SieveScript.with_vacation (both, off, "me@x.org");
    assert (!("vacation :days" in without) && "fileinto" in without);
    assert (SieveClient.literal_of ("{12}") == 12 && SieveClient.literal_of ("OK") == -1);
}

void test_rules () {
    string dir = Path.build_filename (Environment.get_tmp_dir (), "lettere-rules-%s".printf (Uuid.string_random ().substring (0, 6)));
    var store = new RuleStore (dir);
    var r1 = new Rule ();
    r1.name = "Boss";
    r1.conditions.add (new RuleCondition ("from", "contains", "boss@"));
    r1.actions.add (new RuleAction ("flag", ""));
    r1.actions.add (new RuleAction ("category", "Urgent"));
    store.add (r1);
    var r2 = new Rule ();
    r2.match_all = false;
    r2.conditions.add (new RuleCondition ("subject", "regex", "^invoice [0-9]+$"));
    r2.conditions.add (new RuleCondition ("has-attachment", "is", "true"));
    r2.actions.add (new RuleAction ("move", "Bills"));
    store.add (r2);
    var m = new MessageInfo ();
    m.sender_email = "boss@corp.example";
    m.subject = "Invoice 42";
    assert (store.evaluate (m, null, true).size == 3);
    r1.stop = true;
    assert (store.evaluate (m, null, true).size == 2);
    m.sender_email = "x@y";
    assert (store.evaluate (m, null, true)[0].value == "Bills");
    r2.enabled = false;
    assert (store.evaluate (m, null, true).size == 0);
    store.save ();
    var reloaded = new RuleStore (dir);
    assert (reloaded.rules.size == 2 && reloaded.rules[1].conditions[0].op == "regex" && !reloaded.rules[1].enabled);
    assert (reloaded.steps.size >= 2);
}

void test_junk () {
    try {
        string db = Path.build_filename (Environment.get_tmp_dir (), "lettere-j-%s.db".printf (Uuid.string_random ().substring (0, 8)));
        var store = new Store (db);
        var j = new JunkFilter (store);
        for (int i = 0; i < 5; i++) {
            var spam = new MessageInfo ();
            spam.sender_email = "win%d@lottery.example".printf (i);
            spam.subject = "You won a prize! Claim your money now";
            j.train (spam, "claim your prize money free winner casino bonus click now", true);
            var ham = new MessageInfo ();
            ham.sender_email = "colleague%d@work.example".printf (i);
            ham.subject = "Minutes of the project meeting";
            j.train (ham, "attached the minutes of our project meeting and the next steps for the release", false);
        }
        assert (j.trained);
        var s = new MessageInfo ();
        s.sender_email = "promo@lottery.example";
        s.subject = "Claim your free prize";
        var h = new MessageInfo ();
        h.sender_email = "boss@work.example";
        h.subject = "Project meeting";
        assert (j.score (s, "free money bonus winner click") > 0.9);
        assert (j.score (h, "the release steps from the meeting") < 0.1);
        store = null;
        foreach (string suffix in new string[] { "", "-wal", "-shm" }) FileUtils.remove (db + suffix);
    } catch (Error e) {
        error (e.message);
    }
}

void test_mbox () {
    string box = "From a@x Mon Sep  1 10:00:00 2025\nFrom: A <a@x>\nSubject: One\nStatus: RO\n\nHello\n>From the start\n\nFrom b@x Mon Sep  1 11:00:00 2025\nFrom: B <b@x>\nSubject: Two\nX-Mozilla-Status: 0005\n\nSecond\n";
    var msgs = Mbox.split (box.data);
    assert (msgs.size == 2);
    var one = new MimeMessage (msgs[0].get_data ());
    assert (one.subject == "One" && one.text_plain.contains ("From the start") && !one.text_plain.contains (">From"));
    assert ((Mbox.flags_of (msgs[0].get_data ()) & MessageFlags.SEEN) != 0);
    int f2 = Mbox.flags_of (msgs[1].get_data ());
    assert ((f2 & MessageFlags.SEEN) != 0 && (f2 & MessageFlags.FLAGGED) != 0);
    string escaped = Mbox.escape ("Subject: Hi\r\n\r\nFrom here\r\n>From there\r\n".data, "me@x", 1756720800);
    assert (escaped.has_prefix ("From me@x "));
    assert ("\n>From here\n" in escaped && "\n>>From there\n" in escaped);
    var round = Mbox.split (escaped.data);
    assert (round.size == 1 && new MimeMessage (round[0].get_data ()).text_plain.contains ("From here"));
}

void test_merge () {
    var t = MergeTable.from_csv ("Name;Email;City\n\"Rossi, Giulia\";giulia@x.org;Roma\nMarco;marco@x.org;\"Milano\"\"s\"\n\n");
    assert (t.columns.size == 3 && t.rows.size == 2);
    assert (t.email_column () == "email");
    assert (t.rows[0]["name"] == "Rossi, Giulia");
    assert (t.rows[1]["city"] == "Milano\"s");
    assert (MergeTable.fill ("Dear {{Name}} from {{ city }}{{missing}}", t.rows[0], false) == "Dear Rossi, Giulia from Roma");
    assert (MergeTable.fill ("<p>{{Name}}</p>", t.rows[1], true) == "<p>Marco</p>");
}

void test_special () {
    var u = Special.unsubscribe_of ("<mailto:leave@list.example?subject=unsub>, <https://list.example/u/1>\x1fList-Unsubscribe=One-Click");
    assert (u.mailto == "mailto:leave@list.example?subject=unsub" && u.url == "https://list.example/u/1" && u.one_click);
    string to, subject, body;
    Special.mailto_parts ("mailto:a%40x.org?subject=Hi%20there&body=x+y&cc=c@x", out to, out subject, out body);
    assert (to == "a@x.org" && subject == "Hi there" && body == "x y");
    var a = new Account ();
    a.email = "me@x.org";
    a.full_name = "Me";
    var m = new MessageInfo ();
    m.subject = "Plan";
    m.message_id = "orig@x";
    m.receipt_to = "boss@x.org";
    m.date = 1756720800;
    var mdn = new MimeMessage (Special.mdn (a, m, "Read:"));
    assert (mdn.root.content_type == "multipart/report");
    assert (mdn.subject == "Read: Plan");
    var redirected = (string) Special.redirect ("Subject: X\r\n\r\nbody\r\n".data, a, Mime.parse_addresses ("n@x.org"));
    assert (redirected.has_prefix ("Resent-From: Me <me@x.org>"));
}

void test_rtf () {
    string rtf = "{\\rtf1\\ansi\\fromhtml1 {\\*\\htmltag64 <html>}{\\*\\htmltag80 <body>}\\htmlrtf {\\htmlrtf0 Hello \\'e8 {\\*\\htmltag84 <b>}bold{\\*\\htmltag92 </b>}\\par}{\\*\\htmltag72 </body></html>}}";
    string html = Rtf.html_of (rtf);
    assert ("<html>" in html && "<b>bold</b>" in html && "Hello è" in html);
    assert (Rtf.text_of ("{\\rtf1{\\fonttbl{\\f0 Arial;}}Line one\\par Line \\u8364?two}") == "Line one\nLine €two");
    uint8[] raw = "{\\rtf1 plain}".data;
    var packed = new ByteArray ();
    uint8[] head = new uint8[16];
    uint32 comp = raw.length + 12;
    head[0] = (uint8) comp;
    head[4] = (uint8) raw.length;
    head[8] = 0x4D;
    head[9] = 0x45;
    head[10] = 0x4C;
    head[11] = 0x41;
    packed.append (head);
    packed.append (raw);
    assert (Rtf.decompress (packed.data) == "{\\rtf1 plain}");
}

void test_builder_extras () {
    var b = new MessageBuilder ();
    b.from = new Address ("Me", "me@x.org");
    b.to.add (new Address ("", "you@x.org"));
    b.subject = "Pic";
    b.text = "see";
    b.html = "<p><img src=\"cid:img1@x\"></p>";
    b.importance = 1;
    b.request_receipt = true;
    var img = new OutgoingAttachment ("a.png", "image/png", new Bytes ({ 1, 2, 3 }));
    img.content_id = "img1@x";
    b.inline_images.add (img);
    b.attachments.add (new OutgoingAttachment ("inner.eml", "message/rfc822", new Bytes ("Subject: Inner\r\n\r\nHi\r\n".data)));
    var m = new MimeMessage (b.build ());
    assert (m.root.header ("Importance") == "high");
    assert (m.root.header ("Disposition-Notification-To") != null);
    assert (m.inline_parts.has_key ("img1@x"));
    bool inner = false;
    foreach (var a in m.attachments) if (a.content_type == "message/rfc822") inner = true;
    assert (inner);
    assert (Mime.importance_of (m.root) == 1);
}


uint8[] sample_message (string subject, bool attach) {
    var b = new MessageBuilder ();
    b.from = new Address ("Giulia Rossi", "giulia@example.com");
    b.to.add (new Address ("Alex Tester", "alex@example.com"));
    b.cc.add (new Address ("", "marco@example.org"));
    b.subject = subject;
    b.text = "Città e caffè, riga uno.\nRiga due.";
    b.html = "<p>Città e <b>caffè</b></p>";
    b.message_id = subject.replace (" ", "") + "@example.com";
    b.date = new DateTime.utc (2026, 9, 1, 10, 0, 0);
    if (attach) b.attachments.add (new OutgoingAttachment ("numeri.csv", "text/csv", new Bytes ("a,b\n1,2\n".data)));
    return b.build ();
}

void test_msg_roundtrip () {
    try {
        var msg = MsgWriter.from_mime (sample_message ("Offerta finale", true));
        assert (MsgFile.is_msg (msg));
        var back = new MimeMessage (MsgFile.to_mime (msg));
        assert (back.subject == "Offerta finale");
        assert (back.from[0].email == "giulia@example.com");
        assert (back.to.size == 1 && back.cc.size == 1);
        assert (back.text_html.contains ("<b>caffè</b>"));
        assert (back.body_text ().contains ("Città"));
        assert (back.attachments.size == 1 && back.attachments[0].filename == "numeri.csv" && Mime.bytes_to_string (back.attachments[0].data.get_data ()) == "a,b\n1,2\n");
        assert (back.message_id == "Offertafinale@example.com");
        var nested = new MessageBuilder ();
        nested.from = new Address ("", "a@x.org");
        nested.subject = "Wrapper";
        nested.text = "see inner";
        nested.attachments.add (new OutgoingAttachment ("inner.eml", "message/rfc822", new Bytes (sample_message ("Inner one", false))));
        var wrapped = new MimeMessage (MsgFile.to_mime (MsgWriter.from_mime (nested.build ())));
        bool inner = false;
        foreach (var a in wrapped.attachments) if (a.content_type == "message/rfc822" && new MimeMessage (a.data.get_data ()).subject == "Inner one") inner = true;
        assert (inner);
    } catch (Error e) {
        error (e.message);
    }
}

void test_pst_roundtrip () {
    try {
        var top = new PstExportFolder ("Archivio");
        var inbox = new PstExportFolder ("Inbox");
        var sub = new PstExportFolder ("Progetti");
        inbox.children.add (sub);
        top.children.add (inbox);
        for (int i = 0; i < 40; i++) inbox.add (sample_message ("Messaggio %d".printf (i), i % 5 == 0), i % 2 == 0 ? MessageFlags.SEEN : 0);
        sub.add (sample_message ("Nel sottofolder", true), MessageFlags.SEEN | MessageFlags.FLAGGED);
        var big = new MessageBuilder ();
        big.from = new Address ("", "big@example.com");
        big.subject = "Allegato grande";
        big.text = "x";
        var blob = new uint8[200000];
        for (int i = 0; i < blob.length; i++) blob[i] = (uint8) (i * 31 % 251);
        big.attachments.add (new OutgoingAttachment ("dati.bin", "application/octet-stream", new Bytes (blob)));
        sub.add (big.build (), 0);
        var data = new PstWriter ().build (top);
        var pst = new PstFile.from_data ((owned) data);
        var root = pst.folders ();
        PstFolder? in_f = null;
        foreach (var c in root.children) if (c.name == "Inbox") in_f = c;
        assert (in_f != null && in_f.messages.size == 40);
        assert (in_f.children.size == 1 && in_f.children[0].name == "Progetti" && in_f.children[0].messages.size == 2);
        int seen = 0;
        var subjects = new Gee.HashSet<string> ();
        foreach (uint32 nid in in_f.messages) {
            var bag = pst.bag (nid);
            var m = new MimeMessage (Mapi.to_mime (bag));
            subjects.add (m.subject);
            if ((Mapi.flags_of (bag) & MessageFlags.SEEN) != 0) seen++;
            assert (m.from[0].email == "giulia@example.com" && m.body_text ().contains ("Città"));
        }
        assert (subjects.size == 40 && subjects.contains ("Messaggio 39") && seen == 20);
        foreach (uint32 nid in in_f.children[0].messages) {
            var bag = pst.bag (nid);
            var m = new MimeMessage (Mapi.to_mime (bag));
            if (m.subject == "Allegato grande") {
                assert (m.attachments.size == 1 && m.attachments[0].data.get_size () == 200000);
                assert (m.attachments[0].data.get_data ()[199999] == (uint8) (199999 * 31 % 251));
            } else {
                assert ((Mapi.flags_of (bag) & MessageFlags.FLAGGED) != 0);
                assert (m.attachments.size == 1 && m.attachments[0].filename == "numeri.csv");
            }
        }
    } catch (Error e) {
        error (e.message);
    }
}


void test_contact_groups () {
    try {
        string dir = DirUtils.make_tmp ("lettere-contacts-XXXXXX");
        FileUtils.set_contents (Path.build_filename (dir, "a.vcf"), "BEGIN:VCARD\nVERSION:3.0\nUID:u1\nFN:Giulia Rossi\nEMAIL:giulia@x.org\nCATEGORIES:Team,Family\nEND:VCARD\nBEGIN:VCARD\nVERSION:3.0\nUID:u2\nFN:Marco Bianchi\nEMAIL:marco@x.org\nCATEGORIES:Team\nEND:VCARD\n");
        FileUtils.set_contents (Path.build_filename (dir, "g.vcf"), "BEGIN:VCARD\nVERSION:4.0\nKIND:group\nFN:Board\nMEMBER:urn:uuid:u1\nMEMBER:mailto:ext@y.org\nEND:VCARD\n");
        string acc = Path.build_filename (dir, "accounts", "A1", "contacts");
        DirUtils.create_with_parents (acc, 0700);
        FileUtils.set_contents (Path.build_filename (acc, "c.json"), "{\"items\":[{\"uid\":\"o1\",\"data\":\"BEGIN:VCARD\\nFN:Online Person\\nEMAIL:online@z.org\\nEND:VCARD\\n\",\"state\":\"synced\"},{\"uid\":\"o2\",\"data\":\"BEGIN:VCARD\\nFN:Gone\\nEMAIL:gone@z.org\\nEND:VCARD\\n\",\"state\":\"deleted\"}]}");
        var book = new ContactBook.with_dirs ({ dir });
        book.extra_dirs.add (Path.build_filename (dir, "accounts"));
        assert (book.match ("onl", 5).size == 1);
        assert (book.match ("gone", 5).size == 0);
        var team = book.group ("team");
        assert (team != null && team.members.size == 2);
        var board = book.group ("Board");
        assert (board != null && board.members.size == 2 && board.members[0].email == "giulia@x.org");
        assert (book.match_groups ("fam").size == 1);
        assert (book.knows ("MARCO@x.org"));
    } catch (Error e) {
        error (e.message);
    }
}

int main (string[] args) {
    Test.init (ref args);
    fixtures = args.length > 1 ? args[1] : "tests/fixtures";
    Test.add_func ("/imap/fetch-literal", test_imap_fetch_literal);
    Test.add_func ("/imap/tricky-literal", test_imap_tricky_literal);
    Test.add_func ("/imap/list-codes", test_imap_list_and_codes);
    Test.add_func ("/imap/malformed", test_imap_malformed);
    Test.add_func ("/mime/mixed", test_mime_mixed);
    Test.add_func ("/mime/charsets", test_mime_charsets);
    Test.add_func ("/mime/encoders", test_mime_encoders);
    Test.add_func ("/mime/builder", test_mime_builder_roundtrip);
    Test.add_func ("/service/outgoing", test_service_outgoing);
    Test.add_func ("/mime/addresses-dates", test_addresses_and_dates);
    Test.add_func ("/smtp/replies", test_smtp);
    Test.add_func ("/threading/union", test_threading);
    Test.add_func ("/autoconfig/parse", test_autoconfig);
    Test.add_func ("/html/text", test_html);
    Test.add_func ("/contacts/vcard", test_contacts);
    Test.add_func ("/store/sqlite", test_store);
    Test.add_func ("/search/query", test_search_query);
    Test.add_func ("/store/query", test_store_query);
    Test.add_func ("/threading/conversation-ids", test_conversation_ids);
    Test.add_func ("/sieve/scripts", test_sieve);
    Test.add_func ("/rules/evaluate", test_rules);
    Test.add_func ("/junk/bayes", test_junk);
    Test.add_func ("/mbox/roundtrip", test_mbox);
    Test.add_func ("/merge/csv", test_merge);
    Test.add_func ("/special/unsubscribe-mdn", test_special);
    Test.add_func ("/mapi/rtf", test_rtf);
    Test.add_func ("/mime/builder-extras", test_builder_extras);
    Test.add_func ("/mapi/msg-roundtrip", test_msg_roundtrip);
    Test.add_func ("/mapi/pst-roundtrip", test_pst_roundtrip);
    Test.add_func ("/contacts/groups-online", test_contact_groups);
    return Test.run ();
}
