#!/usr/bin/env python3
import base64, email, email.utils, json, re, sys, threading, time, uuid
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse, parse_qs, unquote

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 34800
TOKEN = "test-token"
LOCK = threading.RLock()

def mime(frm, to, subject, body, mid, when, extra="", irt=None, html=None):
    h = "From: %s\r\nTo: %s\r\nSubject: %s\r\nDate: %s\r\nMessage-ID: <%s>\r\nMIME-Version: 1.0\r\n" % (frm, to, subject, email.utils.formatdate(when, localtime=False), mid)
    if irt:
        h += "In-Reply-To: <%s>\r\nReferences: <%s>\r\n" % (irt, irt)
    h += extra
    if html:
        b = "=_b%d" % int(when)
        return (h + 'Content-Type: multipart/alternative; boundary="%s"\r\n\r\n--%s\r\nContent-Type: text/plain; charset=utf-8\r\n\r\n%s\r\n--%s\r\nContent-Type: text/html; charset=utf-8\r\n\r\n%s\r\n--%s--\r\n' % (b, b, body, b, html, b)).encode()
    return (h + "Content-Type: text/plain; charset=utf-8\r\n\r\n" + body + "\r\n").encode()

ICS = ("BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//Mock//EN\r\nMETHOD:REQUEST\r\nBEGIN:VEVENT\r\nUID:mock-event-1@example.com\r\n"
       "DTSTAMP:20260930T080000Z\r\nDTSTART:20261005T090000Z\r\nDTEND:20261005T100000Z\r\nSUMMARY:Quarterly planning\r\nLOCATION:Room 4\r\n"
       "ORGANIZER;CN=Giulia Rossi:mailto:giulia.rossi@example.com\r\nATTENDEE;CN=Alex Tester;PARTSTAT=NEEDS-ACTION;RSVP=TRUE:mailto:%s\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n")

def seed(user):
    now = time.time()
    msgs = [
        ("inbox", mime("Giulia Rossi <giulia.rossi@example.com>", user, "Launch plan", "Here is the plan for the launch.", "launch@example.com", now - 7200), False),
        ("inbox", mime("Marco Bianchi <marco.bianchi@example.org>", user, "Re: Launch plan", "Looks good to me.", "launch2@example.org", now - 3600, irt="launch@example.com"), False),
        ("inbox", mime("The Orbit Weekly <news@orbit-weekly.example>", user, "This week in orbit", "Newsletter body", "news1@orbit-weekly.example", now - 1800,
                       extra="List-Unsubscribe: <mailto:unsubscribe@orbit-weekly.example>, <https://orbit-weekly.example/u/1>\r\nList-Id: Orbit Weekly <weekly.orbit-weekly.example>\r\n",
                       html="<h1>Orbit</h1><p>Newsletter body</p>"), True),
        ("inbox", (mime("Giulia Rossi <giulia.rossi@example.com>", user, "Invitation: Quarterly planning", "You are invited.", "invite1@example.com", now - 900)[:-2].decode()
                   .replace("Content-Type: text/plain; charset=utf-8\r\n\r\nYou are invited.",
                            'Content-Type: multipart/mixed; boundary="inv"\r\n\r\n--inv\r\nContent-Type: text/plain; charset=utf-8\r\n\r\nYou are invited.\r\n--inv\r\nContent-Type: text/calendar; method=REQUEST; charset=utf-8\r\n\r\n'
                            + (ICS % user) + '--inv--') + "\r\n").encode(), False),
        ("sent", mime("Alex Tester <%s>" % user, "giulia.rossi@example.com", "Re: Launch plan", "Thanks!", "launch3@example.com", now - 3000, irt="launch2@example.org"), True),
        ("archive", mime("Ana Souza <ana.souza@example.net>", user, "Lisbon trip", "Pastries and trams.", "lisbon@example.net", now - 86400 * 3), True),
    ]
    return msgs

class Store:
    def __init__(self, user):
        self.user = user
        self.reset()

    def reset(self):
        self.folders = {}
        for fid, name, role in [("f-inbox", "Inbox", "inbox"), ("f-sent", "Sent Items", "sent"), ("f-drafts", "Drafts", "drafts"),
                                ("f-trash", "Deleted Items", "trash"), ("f-junk", "Junk Email", "junk"), ("f-archive", "Archive", "archive"),
                                ("f-projects", "Projects", "")]:
            self.folders[fid] = {"id": fid, "name": name, "role": role, "parent": ""}
        self.messages = {}
        self.sent = []
        self.rules = []
        self.vacation = {"enabled": False, "subject": "", "message": "", "start": 0, "end": 0}
        self.counter = 0
        self.state = 0
        for role, raw, read in seed(self.user):
            fid = [f for f in self.folders.values() if f["role"] == role][0]["id"]
            self.add(fid, raw, read)

    def add(self, fid, raw, read=False, keywords=None):
        self.counter += 1
        self.state += 1
        mid = "m%04d" % self.counter
        msg = email.message_from_bytes(raw)
        self.messages[mid] = {"id": mid, "folder": fid, "raw": raw, "read": read, "flag": "notFlagged", "categories": list(keywords or []),
                              "msg": msg, "received": email.utils.parsedate_to_datetime(msg["Date"]).timestamp() if msg["Date"] else time.time(),
                              "thread": None}
        return mid

    def in_folder(self, fid):
        return sorted([m for m in self.messages.values() if m["folder"] == fid], key=lambda m: -m["received"])

    def snapshot(self):
        out = {"folders": list(self.folders.values()), "messages": [], "sent": self.sent, "rules": self.rules, "vacation": self.vacation}
        for m in self.messages.values():
            out["messages"].append({"id": m["id"], "folder": m["folder"], "subject": m["msg"]["Subject"], "read": m["read"], "flag": m["flag"], "categories": m["categories"], "labels": sorted(m.get("labels", []))})
        return out

STORES = {}
SHARED_MAILBOX = "team@outlook.test"

def store_for(proto):
    with LOCK:
        if proto not in STORES:
            STORES[proto] = Store({"graph": "tester@outlook.test", "gmail": "tester@gmail.test", "jmap": "tester@jmap.test", "ews": "exchuser@corp.test", "pop": "tester@pop.test", "graph-shared": SHARED_MAILBOX}[proto])
        return STORES[proto]

def addr_obj(v):
    name, a = email.utils.parseaddr(v or "")
    return {"emailAddress": {"name": name, "address": a}}

def addr_list(v):
    return [addr_obj("%s <%s>" % p) for p in email.utils.getaddresses([v or ""]) if p[1]]

def text_of(msg):
    if msg.is_multipart():
        for p in msg.walk():
            if p.get_content_type() == "text/plain":
                return p.get_payload(decode=True).decode("utf-8", "replace")
        return ""
    return msg.get_payload(decode=True).decode("utf-8", "replace") if msg.get_payload() else ""

def matches(m, q):
    q = q.lower().replace('"', "")
    hay = ((m["msg"]["Subject"] or "") + " " + (m["msg"]["From"] or "") + " " + text_of(m["msg"])).lower()
    for part in re.split(r"\s+and\s+|\s+", q):
        if not part:
            continue
        if ":" in part:
            k, v = part.split(":", 1)
            if k in ("from",) and v not in (m["msg"]["From"] or "").lower():
                return False
            if k == "subject" and v not in (m["msg"]["Subject"] or "").lower():
                return False
            if k in ("is", "isread") and v in ("unread", "false") and m["read"]:
                return False
            continue
        if part not in hay:
            return False
    return True

class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *a):
        sys.stderr.write("%s %s\n" % (self.command, self.path))

    def body(self):
        n = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(n) if n else b""

    def reply(self, code, obj=None, ctype="application/json", raw=None):
        data = raw if raw is not None else (json.dumps(obj).encode() if obj is not None else b"")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def authorized(self):
        a = self.headers.get("Authorization") or ""
        if a == "Bearer " + TOKEN:
            return True
        if a.startswith("Basic "):
            u, _, p = base64.b64decode(a[6:]).decode().partition(":")
            return p == "secret"
        return False

    def route(self):
        u = urlparse(self.path)
        path = unquote(u.path)
        qs = parse_qs(u.query)
        if path == "/_state":
            proto = qs.get("p", ["graph"])[0]
            return self.reply(200, store_for(proto).snapshot())
        if path == "/_reset":
            with LOCK:
                STORES.clear()
            return self.reply(200, {})
        if path == "/_deliver":
            proto = qs.get("p", ["graph"])[0]
            s = store_for(proto)
            with LOCK:
                fid = [f for f in s.folders.values() if f["role"] == "inbox"][0]["id"]
                s.add(fid, self.body())
            return self.reply(200, {})
        if not self.authorized():
            self.send_response(401)
            self.send_header("WWW-Authenticate", 'Basic realm="mock"')
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        with LOCK:
            if path.startswith("/graph/v1.0/"):
                return self.graph(path[len("/graph/v1.0/"):], qs)
            if path.startswith("/gmail/v1/users/me/") or path.startswith("/upload/gmail/v1/users/me/"):
                return self.gmail(path.split("/users/me/", 1)[1], qs)
            if path == "/.well-known/jmap":
                return self.jmap_session()
            if path.startswith("/jmap/"):
                return self.jmap(path[6:], qs)
            if path == "/EWS/Exchange.asmx":
                return self.ews()
        self.reply(404, {"error": {"message": "no route"}})

    do_GET = do_POST = do_PATCH = do_DELETE = do_PUT = route

    # ---------------- Graph ----------------
    def graph(self, p, qs):
        wk = {"inbox": "inbox", "sentitems": "sent", "drafts": "drafts", "deleteditems": "trash", "junkemail": "junk", "archive": "archive"}
        parts = p.split("/")
        if parts[0] == "users" and len(parts) > 2:
            if parts[1].lower() != SHARED_MAILBOX:
                return self.reply(403, {"error": {"code": "ErrorAccessDenied", "message": "Access is denied."}})
            s = store_for("graph-shared")
            owner = "users/" + parts[1]
            parts = parts[2:]
        elif parts[0] == "me":
            s = store_for("graph")
            owner = "me"
            parts = parts[1:]
        else:
            return self.reply(404, {"error": {"message": "only me or a shared mailbox"}})
        if parts[:1] == ["mailFolders"]:
            if len(parts) == 1:
                if self.command == "POST":
                    b = json.loads(self.body())
                    fid = "f-" + uuid.uuid4().hex[:6]
                    s.folders[fid] = {"id": fid, "name": b["displayName"], "role": "", "parent": ""}
                    return self.reply(201, {"id": fid, "displayName": b["displayName"]})
                vals = [{"id": f["id"], "displayName": f["name"], "childFolderCount": sum(1 for c in s.folders.values() if c["parent"] == f["id"])} for f in s.folders.values() if f["parent"] == ""]
                return self.reply(200, {"value": vals})
            fid = parts[1]
            if fid in wk:
                f = [x for x in s.folders.values() if x["role"] == wk[fid]]
                if not f:
                    return self.reply(404, {"error": {"message": "none"}})
                fid = f[0]["id"]
            if fid not in s.folders:
                return self.reply(404, {"error": {"message": "no folder"}})
            if len(parts) == 2:
                if self.command == "PATCH":
                    s.folders[fid]["name"] = json.loads(self.body())["displayName"]
                    return self.reply(200, {"id": fid})
                if self.command == "DELETE":
                    del s.folders[fid]
                    return self.reply(204)
                return self.reply(200, {"id": fid, "displayName": s.folders[fid]["name"]})
            if parts[2] == "childFolders":
                if self.command == "POST":
                    b = json.loads(self.body())
                    nid = "f-" + uuid.uuid4().hex[:6]
                    s.folders[nid] = {"id": nid, "name": b["displayName"], "role": "", "parent": fid}
                    return self.reply(201, {"id": nid})
                return self.reply(200, {"value": [{"id": f["id"], "displayName": f["name"], "childFolderCount": 0} for f in s.folders.values() if f["parent"] == fid]})
            if parts[2] == "messages" and len(parts) == 3:
                if self.command == "POST":
                    raw = base64.b64decode(self.body())
                    mid = s.add(fid, raw)
                    return self.reply(201, {"id": mid})
                q = qs.get("$search", [""])[0]
                vals = [{"id": m["id"]} for m in s.in_folder(fid) if matches(m, q)]
                return self.reply(200, {"value": vals})
            if parts[2:4] == ["messages", "delta"]:
                return self.reply(200, {"value": [self.graph_msg(m) for m in s.in_folder(fid)], "@odata.deltaLink": "http://127.0.0.1:%d/graph/v1.0/%s/mailFolders/%s/messages/delta?token=%d" % (PORT, owner, fid, s.state)})
            if parts[2] == "messageRules":
                if self.command == "POST":
                    b = json.loads(self.body())
                    b["id"] = "r" + uuid.uuid4().hex[:6]
                    s.rules.append(b)
                    return self.reply(201, b)
                if self.command == "DELETE":
                    s.rules = [r for r in s.rules if r["id"] != parts[3]]
                    return self.reply(204)
                return self.reply(200, {"value": s.rules})
        if parts[:1] == ["messages"]:
            mid = parts[1]
            m = s.messages.get(mid)
            if m is None:
                return self.reply(404, {"error": {"message": "no message"}})
            if len(parts) == 3 and parts[2] == "$value":
                return self.reply(200, raw=m["raw"], ctype="message/rfc822")
            if len(parts) == 3 and parts[2] in ("move", "copy"):
                dest = json.loads(self.body())["destinationId"]
                if parts[2] == "move":
                    m["folder"] = dest
                    s.state += 1
                    return self.reply(201, {"id": mid})
                nid = s.add(dest, m["raw"], m["read"])
                return self.reply(201, {"id": nid})
            if len(parts) == 3 and parts[2] == "permanentDelete":
                del s.messages[mid]
                return self.reply(204)
            if self.command == "PATCH":
                b = json.loads(self.body())
                if "isRead" in b:
                    m["read"] = b["isRead"]
                if "flag" in b:
                    m["flag"] = b["flag"]["flagStatus"]
                if "categories" in b:
                    m["categories"] = b["categories"]
                s.state += 1
                return self.reply(200, self.graph_msg(m))
            if self.command == "DELETE":
                m["folder"] = [f for f in s.folders.values() if f["role"] == "trash"][0]["id"]
                return self.reply(204)
        if parts == ["sendMail"]:
            raw = base64.b64decode(self.body())
            s.sent.append(raw.decode("utf-8", "replace"))
            s.add([f for f in s.folders.values() if f["role"] == "sent"][0]["id"], raw, True)
            return self.reply(202)
        if parts[:1] == ["mailboxSettings"]:
            if self.command == "PATCH":
                a = json.loads(self.body())["automaticRepliesSetting"]
                s.vacation = {"enabled": a["status"] != "disabled", "subject": "", "message": a.get("internalReplyMessage", ""), "start": 0, "end": 0}
                return self.reply(200, {})
            st = "alwaysEnabled" if s.vacation["enabled"] else "disabled"
            return self.reply(200, {"status": st, "externalAudience": "all", "internalReplyMessage": s.vacation["message"], "externalReplyMessage": s.vacation["message"]})
        return self.reply(404, {"error": {"message": "graph route " + p}})

    def graph_msg(self, m):
        msg = m["msg"]
        return {"id": m["id"], "subject": msg["Subject"], "from": addr_obj(msg["From"]), "toRecipients": addr_list(msg["To"]), "ccRecipients": addr_list(msg["Cc"]),
                "receivedDateTime": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(m["received"])), "internetMessageId": msg["Message-ID"],
                "conversationId": "c-" + (msg["In-Reply-To"] or msg["Message-ID"] or "").strip("<>"), "isRead": m["read"], "flag": {"flagStatus": m["flag"]},
                "hasAttachments": msg.is_multipart() and msg.get_content_type() == "multipart/mixed", "categories": m["categories"], "importance": "normal",
                "inferenceClassification": "other" if msg["List-Id"] else "focused", "isDraft": False}

    # ---------------- Gmail ----------------
    def gmail(self, p, qs):
        s = store_for("gmail")
        role_label = {"inbox": "INBOX", "sent": "SENT", "drafts": "DRAFT", "trash": "TRASH", "junk": "SPAM", "archive": None, "": None}
        if not hasattr(s, "labels"):
            s.labels = {"Label_1": "Projects"}
            for m in s.messages.values():
                m["labels"] = set()
                r = s.folders[m["folder"]]["role"]
                if role_label.get(r):
                    m["labels"].add(role_label[r])
                if not m["read"]:
                    m["labels"].add("UNREAD")
                if s.folders[m["folder"]]["name"] == "Projects":
                    m["labels"].add("Label_1")
                m["labels"].add("CATEGORY_PROMOTIONS" if m["msg"]["List-Id"] else "CATEGORY_PERSONAL")
        def lab(m):
            return sorted(m["labels"])
        if p == "profile":
            return self.reply(200, {"emailAddress": s.user, "historyId": str(s.state)})
        if p == "labels":
            if self.command == "POST":
                b = json.loads(self.body())
                lid = "Label_%d" % (len(s.labels) + 1)
                s.labels[lid] = b["name"]
                return self.reply(200, {"id": lid, "name": b["name"]})
            sys_labels = [{"id": x, "name": x, "type": "system"} for x in ("INBOX", "SENT", "DRAFT", "TRASH", "SPAM", "STARRED", "UNREAD", "CATEGORY_PERSONAL")]
            return self.reply(200, {"labels": sys_labels + [{"id": k, "name": v, "type": "user"} for k, v in s.labels.items()]})
        if p.startswith("labels/"):
            lid = p[7:]
            if self.command == "DELETE":
                s.labels.pop(lid, None)
                return self.reply(204)
            s.labels[lid] = json.loads(self.body())["name"]
            return self.reply(200, {"id": lid})
        if p == "history":
            return self.reply(200, {"historyId": str(s.state)})
        if p == "messages" and self.command == "GET":
            want = qs.get("labelIds", [None])[0]
            q = qs.get("q", [""])[0]
            out = []
            for m in sorted(s.messages.values(), key=lambda m: -m["received"]):
                if want and want not in m["labels"]:
                    continue
                if not want and ("TRASH" in m["labels"] or "SPAM" in m["labels"]):
                    continue
                if q and not matches(m, q):
                    continue
                out.append({"id": m["id"], "threadId": "t-" + (m["msg"]["In-Reply-To"] or m["msg"]["Message-ID"] or "").strip("<>")})
            return self.reply(200, {"messages": out, "resultSizeEstimate": len(out)})
        if p == "messages" and self.command == "POST":
            b = json.loads(self.body())
            raw = base64.urlsafe_b64decode(b["raw"] + "==")
            mid = s.add("f-inbox", raw, "UNREAD" not in b.get("labelIds", []))
            s.messages[mid]["labels"] = set(b.get("labelIds", []))
            return self.reply(200, {"id": mid})
        if p == "messages/send":
            b = json.loads(self.body())
            raw = base64.urlsafe_b64decode(b["raw"] + "==")
            s.sent.append(raw.decode("utf-8", "replace"))
            mid = s.add("f-sent", raw, True)
            s.messages[mid]["labels"] = {"SENT"}
            return self.reply(200, {"id": mid})
        if p == "drafts":
            b = json.loads(self.body())
            raw = base64.urlsafe_b64decode(b["message"]["raw"] + "==")
            mid = s.add("f-drafts", raw, True)
            s.messages[mid]["labels"] = {"DRAFT"}
            return self.reply(200, {"id": "d" + mid, "message": {"id": mid}})
        if p == "messages/batchModify":
            b = json.loads(self.body())
            for mid in b["ids"]:
                m = s.messages[mid]
                m["labels"] |= set(b.get("addLabelIds", []))
                m["labels"] -= set(b.get("removeLabelIds", []))
                m["read"] = "UNREAD" not in m["labels"]
                m["flag"] = "flagged" if "STARRED" in m["labels"] else "notFlagged"
                m["categories"] = [s.labels[l] for l in m["labels"] if l in s.labels]
            s.state += 1
            return self.reply(204)
        if p.startswith("messages/"):
            rest = p[9:].split("/")
            m = s.messages.get(rest[0])
            if m is None:
                return self.reply(404, {"error": {"message": "no message"}})
            if len(rest) == 2 and rest[1] == "trash":
                m["labels"] = (m["labels"] - {"INBOX"}) | {"TRASH"}
                return self.reply(200, {"id": m["id"]})
            if len(rest) == 2 and rest[1] == "untrash":
                m["labels"] -= {"TRASH"}
                return self.reply(200, {"id": m["id"]})
            if self.command == "DELETE":
                del s.messages[rest[0]]
                return self.reply(204)
            fmt = qs.get("format", ["full"])[0]
            if fmt == "raw":
                return self.reply(200, {"id": m["id"], "raw": base64.urlsafe_b64encode(m["raw"]).decode()})
            names = qs.get("metadataHeaders", [])
            hdrs = [{"name": k, "value": v} for k, v in m["msg"].items() if not names or k in names]
            return self.reply(200, {"id": m["id"], "threadId": "t-" + (m["msg"]["In-Reply-To"] or m["msg"]["Message-ID"] or "").strip("<>"), "labelIds": lab(m), "sizeEstimate": len(m["raw"]), "internalDate": str(int(m["received"] * 1000)), "payload": {"headers": hdrs}})
        if p == "settings/vacation":
            if self.command == "PUT":
                b = json.loads(self.body())
                s.vacation = {"enabled": b["enableAutoReply"], "subject": b.get("responseSubject", ""), "message": b.get("responseBodyPlainText", ""), "start": b.get("startTime", 0), "end": b.get("endTime", 0)}
                return self.reply(200, b)
            v = s.vacation
            return self.reply(200, {"enableAutoReply": v["enabled"], "responseSubject": v["subject"], "responseBodyPlainText": v["message"]})
        if p.startswith("settings/filters"):
            if self.command == "POST":
                b = json.loads(self.body())
                b["id"] = "flt" + uuid.uuid4().hex[:6]
                s.rules.append(b)
                return self.reply(200, b)
            if self.command == "DELETE":
                s.rules = [r for r in s.rules if r["id"] != p.split("/")[-1]]
                return self.reply(204)
            return self.reply(200, {"filter": s.rules})
        return self.reply(404, {"error": {"message": "gmail route " + p}})

    # ---------------- JMAP ----------------
    def jmap_session(self):
        base = "http://127.0.0.1:%d" % PORT
        return self.reply(200, {"capabilities": {"urn:ietf:params:jmap:core": {}, "urn:ietf:params:jmap:mail": {}, "urn:ietf:params:jmap:submission": {}, "urn:ietf:params:jmap:vacationresponse": {}, "urn:ietf:params:jmap:quota": {}},
                                "accounts": {"A1": {"name": "tester@jmap.test"}}, "primaryAccounts": {"urn:ietf:params:jmap:mail": "A1"},
                                "apiUrl": base + "/jmap/api", "downloadUrl": base + "/jmap/download/{accountId}/{blobId}/{name}?type={type}", "uploadUrl": base + "/jmap/upload/{accountId}", "state": "1"})

    def jmap(self, p, qs):
        s = store_for("jmap")
        if not hasattr(s, "blobs"):
            s.blobs = {}
        if p.startswith("upload/"):
            bid = "B" + uuid.uuid4().hex[:8]
            s.blobs[bid] = self.body()
            return self.reply(201, {"accountId": "A1", "blobId": bid, "type": "message/rfc822", "size": len(s.blobs[bid])})
        if p.startswith("download/"):
            bid = p.split("/")[2]
            if bid.startswith("blob-"):
                return self.reply(200, raw=s.messages[bid[5:]]["raw"], ctype="message/rfc822")
            return self.reply(200, raw=s.blobs.get(bid, b""), ctype="message/rfc822")
        req = json.loads(self.body())
        out = []
        for name, args, cid in req["methodCalls"]:
            out.append([name, self.jmap_call(s, name, args), cid])
        return self.reply(200, {"methodResponses": out, "sessionState": "1"})

    def jmap_email(self, s, m):
        msg = m["msg"]
        def al(v):
            return [{"name": n, "email": a} for n, a in email.utils.getaddresses([v or ""]) if a]
        kw = {}
        if m["read"]:
            kw["$seen"] = True
        if m["flag"] == "flagged":
            kw["$flagged"] = True
        for c in m["categories"]:
            kw[c.replace(" ", "_")] = True
        return {"id": m["id"], "blobId": "blob-" + m["id"], "threadId": "T" + (msg["In-Reply-To"] or msg["Message-ID"] or "").strip("<>"), "mailboxIds": {m["folder"]: True}, "keywords": kw,
                "size": len(m["raw"]), "receivedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(m["received"])), "messageId": [(msg["Message-ID"] or "").strip("<>")],
                "inReplyTo": [msg["In-Reply-To"].strip("<>")] if msg["In-Reply-To"] else None, "references": None, "from": al(msg["From"]), "to": al(msg["To"]), "cc": al(msg["Cc"]),
                "subject": msg["Subject"], "hasAttachment": msg.get_content_type() == "multipart/mixed", "header:List-Unsubscribe:asText": msg["List-Unsubscribe"], "header:List-Id:asText": msg["List-Id"]}

    def jmap_call(self, s, name, a):
        if name == "Mailbox/get":
            return {"accountId": "A1", "state": str(s.state), "list": [{"id": f["id"], "name": f["name"], "role": f["role"] or None, "parentId": f["parent"] or None} for f in s.folders.values()]}
        if name == "Mailbox/set":
            created = {}
            for k, v in (a.get("create") or {}).items():
                fid = "f-" + uuid.uuid4().hex[:6]
                s.folders[fid] = {"id": fid, "name": v["name"], "role": "", "parent": v.get("parentId") or ""}
                created[k] = {"id": fid}
            for k, v in (a.get("update") or {}).items():
                s.folders[k]["name"] = v["name"]
            for k in a.get("destroy") or []:
                s.folders.pop(k, None)
            return {"accountId": "A1", "created": created}
        if name == "Email/query":
            f = a.get("filter", {})
            conds = f.get("conditions", [f]) if "operator" in f else [f]
            res = []
            for m in sorted(s.messages.values(), key=lambda m: -m["received"]):
                ok = True
                for c in conds:
                    if "inMailbox" in c and m["folder"] != c["inMailbox"]:
                        ok = False
                    if "text" in c and not matches(m, c["text"]):
                        ok = False
                    if "subject" in c and c["subject"].lower() not in (m["msg"]["Subject"] or "").lower():
                        ok = False
                    if "from" in c and c["from"].lower() not in (m["msg"]["From"] or "").lower():
                        ok = False
                if ok:
                    res.append(m["id"])
            return {"accountId": "A1", "ids": res, "queryState": str(s.state), "position": 0}
        if name == "Email/get":
            return {"accountId": "A1", "state": str(s.state), "list": [self.jmap_email(s, s.messages[i]) for i in a["ids"] if i in s.messages]}
        if name == "Email/set":
            for mid, patch in (a.get("update") or {}).items():
                m = s.messages[mid]
                for k, v in patch.items():
                    if k == "keywords/$seen":
                        m["read"] = bool(v)
                    elif k == "keywords/$flagged":
                        m["flag"] = "flagged" if v else "notFlagged"
                    elif k.startswith("keywords/"):
                        c = k[9:].replace("_", " ")
                        if v and c not in m["categories"]:
                            m["categories"].append(c)
                        if not v and c in m["categories"]:
                            m["categories"].remove(c)
                    elif k.startswith("mailboxIds/"):
                        if v:
                            if m["folder"] != k[11:] and patch.get("mailboxIds/" + m["folder"], True) is not None:
                                s.add(k[11:], m["raw"], m["read"])
                            else:
                                m["folder"] = k[11:]
            for mid in a.get("destroy") or []:
                s.messages.pop(mid, None)
            s.state += 1
            return {"accountId": "A1", "updated": {k: None for k in (a.get("update") or {})}}
        if name == "Email/import":
            created = {}
            for k, v in a["emails"].items():
                mid = s.add(list(v["mailboxIds"].keys())[0], s.blobs[v["blobId"]], bool(v.get("keywords", {}).get("$seen")))
                created[k] = {"id": mid}
            return {"accountId": "A1", "created": created}
        if name == "Identity/get":
            return {"accountId": "A1", "list": [{"id": "I1", "email": s.user, "name": "Alex Tester"}]}
        if name == "EmailSubmission/set":
            created = {}
            for k, v in a["create"].items():
                s.sent.append(s.messages[v["emailId"]]["raw"].decode("utf-8", "replace"))
                created[k] = {"id": "S" + k}
            return {"accountId": "A1", "created": created}
        if name == "VacationResponse/get":
            v = s.vacation
            return {"accountId": "A1", "list": [{"id": "singleton", "isEnabled": v["enabled"], "subject": v["subject"], "textBody": v["message"]}]}
        if name == "VacationResponse/set":
            u = a["update"]["singleton"]
            s.vacation = {"enabled": u["isEnabled"], "subject": u.get("subject", ""), "message": u.get("textBody", ""), "start": u.get("fromDate"), "end": u.get("toDate")}
            return {"accountId": "A1", "updated": {"singleton": None}}
        if name == "Quota/get":
            return {"accountId": "A1", "list": [{"id": "Q1", "resourceType": "octets", "used": 1048576, "hardLimit": 10485760}]}
        return {"type": "unknownMethod"}

    # ---------------- EWS ----------------
    def ews(self):
        s = store_for("ews")
        body = self.body().decode("utf-8", "replace")
        roles = {"inbox": "inbox", "sentitems": "sent", "drafts": "drafts", "deleteditems": "trash", "junkemail": "junk", "archiveinbox": "archive"}
        def resp(inner):
            x = ('<?xml version="1.0" encoding="utf-8"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body>'
                 '<m:Resp xmlns:m="http://schemas.microsoft.com/exchange/services/2006/messages" xmlns:t="http://schemas.microsoft.com/exchange/services/2006/types">'
                 + inner + '</m:Resp></s:Body></s:Envelope>')
            return self.reply(200, raw=x.encode(), ctype="text/xml; charset=utf-8")
        def esc(v):
            return (v or "").replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace('"', "&quot;")
        def fid_of(xml):
            m = re.search(r'DistinguishedFolderId Id="([^"]+)"', xml)
            if m:
                r = roles.get(m.group(1))
                if m.group(1) == "msgfolderroot":
                    return "root"
                f = [x for x in s.folders.values() if x["role"] == r]
                return f[0]["id"] if f else None
            m = re.search(r'FolderId Id="([^"]+)"', xml)
            return m.group(1) if m else None
        def item_xml(m):
            msg = m["msg"]
            def mb(v):
                n, a = email.utils.parseaddr(v or "")
                return "<t:Mailbox><t:Name>%s</t:Name><t:EmailAddress>%s</t:EmailAddress></t:Mailbox>" % (esc(n), esc(a))
            def mbs(v):
                return "".join(mb("%s <%s>" % p) for p in email.utils.getaddresses([v or ""]) if p[1])
            cats = "".join("<t:String>%s</t:String>" % esc(c) for c in m["categories"])
            return ('<t:Message><t:ItemId Id="%s" ChangeKey="ck"/><t:Subject>%s</t:Subject><t:From>%s</t:From><t:ToRecipients>%s</t:ToRecipients>'
                    '<t:DateTimeReceived>%s</t:DateTimeReceived><t:InternetMessageId>%s</t:InternetMessageId><t:ConversationId Id="c-%s"/>'
                    '<t:IsRead>%s</t:IsRead><t:Flag><t:FlagStatus>%s</t:FlagStatus></t:Flag><t:HasAttachments>false</t:HasAttachments><t:Categories>%s</t:Categories>'
                    '<t:Importance>Normal</t:Importance><t:Size>%d</t:Size></t:Message>') % (m["id"], esc(msg["Subject"]), mb(msg["From"]), mbs(msg["To"]),
                    time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(m["received"])), esc(msg["Message-ID"]), esc((msg["In-Reply-To"] or msg["Message-ID"] or "").strip("<>")),
                    "true" if m["read"] else "false", {"flagged": "Flagged", "complete": "Complete"}.get(m["flag"], "NotFlagged"), cats, len(m["raw"]))
        op = re.search(r"<soap:Body><m:(\w+)", body) or re.search(r"<m:(\w+)", body)
        op = op.group(1) if op else ""
        ok = "<m:ResponseCode>NoError</m:ResponseCode>"
        if op == "GetFolder":
            f = fid_of(body)
            if not f:
                return resp("<m:ResponseCode>ErrorFolderNotFound</m:ResponseCode><m:MessageText>not found</m:MessageText>")
            return resp(ok + '<t:Folder><t:FolderId Id="%s"/></t:Folder>' % f)
        if op == "FindFolder":
            return resp(ok + "".join('<t:Folder><t:FolderId Id="%s"/><t:ParentFolderId Id="%s"/><t:FolderClass>IPF.Note</t:FolderClass><t:DisplayName>%s</t:DisplayName></t:Folder>' % (f["id"], f["parent"] or "root", esc(f["name"])) for f in s.folders.values()))
        if op == "SyncFolderItems":
            f = fid_of(body)
            had = re.search(r"<m:SyncState>([^<]*)</m:SyncState>", body)
            items = "" if had and had.group(1) == str(s.state) else "".join("<t:Create>%s</t:Create>" % item_xml(m) for m in s.in_folder(f))
            return resp(ok + "<m:SyncState>%d</m:SyncState><m:IncludesLastItemInRange>true</m:IncludesLastItemInRange><m:Changes>%s</m:Changes>" % (s.state, items))
        if op == "GetItem":
            ids = re.findall(r'ItemId Id="([^"]+)"', body)
            return resp(ok + "".join('<t:Message><t:ItemId Id="%s"/><t:MimeContent CharacterSet="UTF-8">%s</t:MimeContent></t:Message>' % (i, base64.b64encode(s.messages[i]["raw"]).decode()) for i in ids if i in s.messages))
        if op == "UpdateItem":
            for i, rest in re.findall(r'<t:ItemChange><t:ItemId Id="([^"]+)"/>(.*?)</t:ItemChange>', body):
                m = s.messages[i]
                r = re.search(r"<t:IsRead>(\w+)</t:IsRead>", rest)
                if r:
                    m["read"] = r.group(1) == "true"
                r = re.search(r"<t:FlagStatus>(\w+)</t:FlagStatus>", rest)
                if r:
                    m["flag"] = {"Flagged": "flagged", "Complete": "complete"}.get(r.group(1), "notFlagged")
                if "item:Categories" in rest:
                    m["categories"] = re.findall(r"<t:String>([^<]*)</t:String>", rest)
            s.state += 1
            return resp(ok)
        if op in ("MoveItem", "CopyItem"):
            to = fid_of(body.split("<m:ItemIds>")[0])
            for i in re.findall(r'ItemId Id="([^"]+)"', body):
                if op == "MoveItem":
                    s.messages[i]["folder"] = to
                else:
                    s.add(to, s.messages[i]["raw"], s.messages[i]["read"])
            s.state += 1
            return resp(ok)
        if op == "DeleteItem":
            for i in re.findall(r'ItemId Id="([^"]+)"', body):
                if "HardDelete" in body:
                    s.messages.pop(i, None)
                else:
                    s.messages[i]["folder"] = [f for f in s.folders.values() if f["role"] == "trash"][0]["id"]
            s.state += 1
            return resp(ok)
        if op == "CreateItem":
            raw = base64.b64decode(re.search(r"<t:MimeContent[^>]*>([^<]*)</t:MimeContent>", body).group(1))
            if "SendAndSaveCopy" in body:
                s.sent.append(raw.decode("utf-8", "replace"))
                mid = s.add([f for f in s.folders.values() if f["role"] == "sent"][0]["id"], raw, True)
            else:
                mid = s.add(fid_of(body.split("<m:Items>")[0]), raw, "<t:IsRead>true" in body)
            return resp(ok + '<t:Message><t:ItemId Id="%s"/></t:Message>' % mid)
        if op == "CreateFolder":
            parent = fid_of(body.split("<m:Folders>")[0])
            name = re.search(r"<t:DisplayName>([^<]*)</t:DisplayName>", body).group(1)
            fid = "f-" + uuid.uuid4().hex[:6]
            s.folders[fid] = {"id": fid, "name": name, "role": "", "parent": "" if parent == "root" else parent}
            return resp(ok + '<t:Folder><t:FolderId Id="%s"/></t:Folder>' % fid)
        if op == "UpdateFolder":
            s.folders[fid_of(body)]["name"] = re.search(r"<t:DisplayName>([^<]*)</t:DisplayName>", body).group(1)
            return resp(ok)
        if op == "DeleteFolder":
            s.folders.pop(fid_of(body), None)
            return resp(ok)
        if op == "FindItem":
            f = fid_of(body)
            q = re.search(r"<m:QueryString>([^<]*)</m:QueryString>", body)
            q = q.group(1) if q else ""
            return resp(ok + "".join('<t:Message><t:ItemId Id="%s"/></t:Message>' % m["id"] for m in s.in_folder(f) if matches(m, q)))
        if op == "GetUserOofSettingsRequest":
            v = s.vacation
            return resp(ok + "<t:OofSettings><t:OofState>%s</t:OofState><t:ExternalAudience>All</t:ExternalAudience><t:InternalReply><t:Message>%s</t:Message></t:InternalReply><t:ExternalReply><t:Message>%s</t:Message></t:ExternalReply></t:OofSettings>" % ("Enabled" if v["enabled"] else "Disabled", esc(v["message"]), esc(v["message"])))
        if op == "SetUserOofSettingsRequest":
            st = re.search(r"<t:OofState>(\w+)</t:OofState>", body).group(1)
            msg = re.search(r"<t:InternalReply><t:Message>([^<]*)</t:Message>", body)
            s.vacation = {"enabled": st != "Disabled", "subject": "", "message": msg.group(1) if msg else "", "start": 0, "end": 0}
            return resp(ok)
        if op == "GetInboxRules":
            return resp(ok + "<m:InboxRules>" + "".join("<t:Rule><t:RuleId>%s</t:RuleId><t:DisplayName>%s</t:DisplayName></t:Rule>" % (r["id"], esc(r["name"])) for r in s.rules) + "</m:InboxRules>")
        if op == "UpdateInboxRules":
            for rid in re.findall(r"<t:DeleteRuleOperation><t:RuleId>([^<]*)</t:RuleId>", body):
                s.rules = [r for r in s.rules if r["id"] != rid]
            for name in re.findall(r"<t:CreateRuleOperation><t:Rule><t:DisplayName>([^<]*)</t:DisplayName>", body):
                s.rules.append({"id": "R" + uuid.uuid4().hex[:6], "name": name})
            return resp(ok)
        return resp("<m:ResponseCode>ErrorInvalidOperation</m:ResponseCode><m:MessageText>%s</m:MessageText>" % op)

import socketserver

class Pop(socketserver.StreamRequestHandler):
    def send(self, line):
        self.wfile.write((line + "\r\n").encode())

    def handle(self):
        s = store_for("pop")
        self.send("+OK mock POP3 ready")
        authed = False
        while True:
            line = self.rfile.readline()
            if not line:
                return
            parts = line.decode().strip().split(" ")
            cmd = parts[0].upper()
            with LOCK:
                msgs = s.in_folder("f-inbox")
                if cmd == "CAPA":
                    self.send("+OK")
                    self.send("UIDL")
                    self.send("USER")
                    self.send(".")
                elif cmd == "USER":
                    self.send("+OK")
                elif cmd == "PASS":
                    authed = parts[1] == "secret" if len(parts) > 1 else False
                    self.send("+OK" if authed else "-ERR bad password")
                elif not authed and cmd != "QUIT":
                    self.send("-ERR sign in first")
                elif cmd == "UIDL":
                    self.send("+OK")
                    for i, m in enumerate(msgs):
                        self.send("%d %s" % (i + 1, m["id"]))
                    self.send(".")
                elif cmd == "RETR":
                    m = msgs[int(parts[1]) - 1]
                    self.send("+OK")
                    for l in m["raw"].decode("utf-8", "replace").replace("\r\n", "\n").split("\n"):
                        self.send(("." + l) if l.startswith(".") else l)
                    self.send(".")
                elif cmd == "DELE":
                    m = msgs[int(parts[1]) - 1]
                    s.messages.pop(m["id"], None)
                    self.send("+OK")
                elif cmd == "QUIT":
                    self.send("+OK bye")
                    return
                else:
                    self.send("-ERR unknown")

if __name__ == "__main__":
    class TPop(socketserver.ThreadingMixIn, socketserver.TCPServer):
        allow_reuse_address = True
        daemon_threads = True
    pop = TPop(("127.0.0.1", PORT + 1), Pop)
    threading.Thread(target=pop.serve_forever, daemon=True).start()
    srv = ThreadingHTTPServer(("127.0.0.1", PORT), H)
    print("api mock on", PORT, flush=True)
    srv.serve_forever()
