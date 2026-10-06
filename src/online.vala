using Singularity.Accounts;

namespace Singularity.Apps.Lettere {

    public class OnlineCredentials : CredentialSource {
        public Singularity.Accounts.Account origin;

        public OnlineCredentials (Singularity.Accounts.Account origin) {
            this.origin = origin;
        }

        public override async MailLogin fetch (bool refresh) throws Error {
            Singularity.Accounts.AccountCredentials c;
            if (origin.provider == "microsoft" && OnlineMail.protocol_of (origin) == "graph") {
                c = yield origin.get_graph_mail_credentials (refresh);
            } else {
                c = yield origin.get_credentials (Capability.MAIL, refresh);
            }
            var login = new MailLogin ();
            login.user = c.username;
            login.secret = c.secret;
            if (origin.get_endpoint ("mail-auth") == "xoauth2" || c.is_token) login.xoauth2 = c.xoauth2_response ();
            return login;
        }

        public override void report_reauth () {
            origin.report_problem.begin (Capability.MAIL, "reauth");
        }
    }

    public class OnlineMail : Object {
        private LettereApp app;
        private Manager manager;
        private Gee.HashSet<string> deferred = new Gee.HashSet<string> ();

        public OnlineMail (LettereApp app) {
            this.app = app;
            manager = Manager.get_default ();
            manager.account_added.connect ((a) => {
                apply (a);
                app.accounts.save ();
            });
            manager.account_changed.connect ((a) => {
                apply (a);
                app.accounts.save ();
            });
            manager.account_removed.connect ((a) => {
                var mirror = app.accounts.find_source (source_of (a));
                if (mirror != null) app.accounts.remove (mirror);
            });
            manager.reloaded.connect (reconcile);
        }

        public async void start () {
            yield manager.load ();
        }

        public static void open_settings () {
            try {
                Singularity.Shell.ShellService shell = Bus.get_proxy_sync (BusType.SESSION, "dev.sinty.desktop", "/dev/sinty/Shell");
                shell.open_settings ("accounts");
            } catch (Error e) {
                warning ("lettere: cannot open Settings: %s", e.message);
            }
        }

        private static string source_of (Singularity.Accounts.Account a) {
            return "online:" + a.id;
        }

        private static string endpoint (Singularity.Accounts.Account a, string key) {
            return a.get_endpoint (key) ?? "";
        }

        public static string protocol_of (Singularity.Accounts.Account a) {
            string api = endpoint (a, "mail-api");
            if (api == "gmail" || api == "graph" || api == "ews" || api == "jmap" || api == "imap") return api;
            if (a.provider == "google" && a.auth == "oauth2") return "gmail";
            if (a.provider == "exchange" && endpoint (a, "ews") != "" && endpoint (a, "imap-host") == "") return "ews";
            return "imap";
        }

        public static string api_url_of (Singularity.Accounts.Account a, string protocol) {
            switch (protocol) {
                case "gmail": return endpoint (a, "gmail-api") != "" ? endpoint (a, "gmail-api") : "https://gmail.googleapis.com/gmail/v1/users/me/";
                case "graph": return endpoint (a, "graph") != "" ? endpoint (a, "graph") : "https://graph.microsoft.com/v1.0/";
                case "ews": return endpoint (a, "ews");
                case "jmap": return endpoint (a, "jmap");
            }
            return "";
        }

        public static bool carries_mail (Singularity.Accounts.Account a) {
            if (!a.has_capability (Capability.MAIL)) return false;
            if (endpoint (a, "mail-address") == "" && !a.identity.contains ("@")) return false;
            string p = protocol_of (a);
            if (p != "imap") return api_url_of (a, p) != "";
            return endpoint (a, "imap-host") != "" && endpoint (a, "smtp-host") != "";
        }

        private static uint16 port (string v, uint16 fallback) {
            uint64 p;
            if (!uint64.try_parse (v, out p) || p == 0 || p > 65535) return fallback;
            return (uint16) p;
        }

        private void reconcile () {
            if (!manager.available) return;
            bool dirty = false;
            foreach (var a in manager.get_accounts ()) {
                if (apply (a)) dirty = true;
            }
            foreach (var mirror in app.accounts.accounts.to_array ()) {
                if (!mirror.managed) continue;
                var origin = manager.get_account (mirror.source.substring (7));
                if (origin == null) {
                    app.accounts.accounts.remove (mirror);
                    dirty = true;
                }
            }
            if (dirty) app.accounts.save ();
        }

        private bool defer_switch (Singularity.Accounts.Account a, Account mirror) {
            if (app.store.ops (mirror.id).size == 0) return false;
            var s = app.syncs[mirror.id];
            if (s != null) s.sync_all.begin ();
            string id = a.id;
            if (deferred.add (id)) {
                Timeout.add_seconds (30, () => {
                    deferred.remove (id);
                    var origin = manager.get_account (id);
                    if (origin != null && apply (origin)) app.accounts.save ();
                    return Source.REMOVE;
                });
            }
            return true;
        }

        private bool apply (Singularity.Accounts.Account a) {
            string source = source_of (a);
            var mirror = app.accounts.find_source (source);
            if (!carries_mail (a)) {
                if (mirror == null) return false;
                app.accounts.accounts.remove (mirror);
                return true;
            }
            bool fresh = mirror == null;
            if (!fresh && mirror.protocol != protocol_of (a) && defer_switch (a, mirror)) return false;
            if (fresh) {
                mirror = new Account ();
                mirror.id = "online-" + a.id;
                mirror.source = source;
            }
            string email = endpoint (a, "mail-address");
            if (email == "") email = a.identity;
            string name = endpoint (a, "mail-name");
            bool invalid_ok = endpoint (a, "tls-accept-invalid") == "true";
            string imap_user = endpoint (a, "imap-user");
            string smtp_user = endpoint (a, "smtp-user");
            var imap_security = Security.from_id (endpoint (a, "imap-security"));
            var smtp_security = Security.from_id (endpoint (a, "smtp-security"));
            uint16 imap_port = port (endpoint (a, "imap-port"), imap_security == Security.TLS ? 993 : 143);
            uint16 smtp_port = port (endpoint (a, "smtp-port"), smtp_security == Security.TLS ? 465 : 587);
            string protocol = protocol_of (a);
            string old_protocol = fresh ? protocol : mirror.protocol;
            string api_url = api_url_of (a, protocol);
            bool servers = fresh || mirror.protocol != protocol || mirror.api_url != api_url || mirror.email != email || mirror.imap_host != endpoint (a, "imap-host") || mirror.imap_port != imap_port
                || mirror.imap_security != imap_security || mirror.imap_user != imap_user || mirror.smtp_host != endpoint (a, "smtp-host")
                || mirror.smtp_port != smtp_port || mirror.smtp_security != smtp_security || mirror.smtp_user != smtp_user
                || (mirror.trusted_imap == "*") != invalid_ok;
            mirror.email = email;
            if (name == "" && a.display_name != email && a.display_name != a.identity) name = a.display_name;
            mirror.full_name = name;
            mirror.imap_host = endpoint (a, "imap-host");
            mirror.imap_port = imap_port;
            mirror.imap_security = imap_security;
            mirror.imap_user = imap_user != "" ? imap_user : email;
            mirror.smtp_host = endpoint (a, "smtp-host");
            mirror.smtp_port = smtp_port;
            mirror.smtp_security = smtp_security;
            mirror.smtp_user = smtp_user != "" ? smtp_user : mirror.imap_user;
            mirror.protocol = protocol;
            mirror.api_url = api_url;
            mirror.auth_mechanism = endpoint (a, "mail-auth") == "ntlm" ? "ntlm" : "";
            mirror.trusted_imap = invalid_ok ? "*" : "";
            mirror.trusted_smtp = invalid_ok ? "*" : "";
            var creds = mirror.online as OnlineCredentials;
            bool attached = creds != null && creds.origin == a;
            if (!attached) mirror.online = new OnlineCredentials (a);
            if (fresh) {
                app.accounts.accounts.add (mirror);
                return true;
            }
            var s = app.syncs[mirror.id];
            if (s != null && servers) {
                s.stop ();
                app.syncs.unset (mirror.id);
            } else if (s != null && (!attached || (s.state == SyncState.AUTH_FAILED && a.healthy))) {
                s.credentials_updated ();
            }
            if (old_protocol != protocol) app.store.begin_protocol_switch (mirror.id);
            return servers;
        }
    }
}
