namespace Singularity.Apps.Lettere {

    public class Account : Object {
        public string id { get; set; default = ""; }
        public string full_name { get; set; default = ""; }
        public string email { get; set; default = ""; }
        public string label { get; set; default = ""; }
        public string imap_host { get; set; default = ""; }
        public uint16 imap_port { get; set; default = 993; }
        public Security imap_security { get; set; default = Security.TLS; }
        public string imap_user { get; set; default = ""; }
        public string smtp_host { get; set; default = ""; }
        public uint16 smtp_port { get; set; default = 465; }
        public Security smtp_security { get; set; default = Security.TLS; }
        public string smtp_user { get; set; default = ""; }
        public string trusted_imap { get; set; default = ""; }
        public string trusted_smtp { get; set; default = ""; }
        public string signature { get; set; default = ""; }
        public string source { get; set; default = "manual"; }
        public string protocol { get; set; default = "imap"; }
        public string api_url { get; set; default = ""; }
        public string sieve_host { get; set; default = ""; }
        public int sieve_port { get; set; default = 0; }
        public string shared { get; set; default = ""; }
        public string identities { get; set; default = ""; }
        public string sig_new { get; set; default = ""; }
        public string sig_reply { get; set; default = ""; }
        public bool pop_keep { get; set; default = true; }
        public string smime_cert { get; set; default = ""; }
        public string pgp_key { get; set; default = ""; }
        public bool sign_default { get; set; }
        public bool encrypt_default { get; set; }
        public string auth_mechanism { get; set; default = ""; }
        public CredentialSource? online;

        public string[] shared_mailboxes () {
            string[] outv = {};
            foreach (string s in shared.split ("\n")) if (s.strip () != "") outv += s.strip ();
            return outv;
        }

        public void add_shared_mailbox (string name) {
            foreach (string s in shared_mailboxes ()) if (s == name) return;
            shared = shared == "" ? name : shared + "\n" + name;
        }

        public Gee.ArrayList<Address> identity_list () {
            var list = new Gee.ArrayList<Address> ();
            list.add (address ());
            foreach (string line in identities.split ("\n")) {
                if (line.strip () == "") continue;
                foreach (var a in Mime.parse_addresses (line)) {
                    bool dup = false;
                    foreach (var b in list) if (b.email.down () == a.email.down ()) dup = true;
                    if (!dup) list.add (a);
                }
            }
            return list;
        }

        public bool uses_smtp {
            get { return protocol == "imap" || protocol == "pop3"; }
        }

        public bool managed {
            get { return source.has_prefix ("online:"); }
        }

        public string display_name {
            owned get { return label != "" ? label : email; }
        }

        public Address address () {
            return new Address (full_name, email);
        }

        public Json.Node to_json () {
            var b = new Json.Builder ();
            b.begin_object ();
            b.set_member_name ("id").add_string_value (id);
            b.set_member_name ("full-name").add_string_value (full_name);
            b.set_member_name ("email").add_string_value (email);
            b.set_member_name ("label").add_string_value (label);
            b.set_member_name ("imap-host").add_string_value (imap_host);
            b.set_member_name ("imap-port").add_int_value (imap_port);
            b.set_member_name ("imap-security").add_string_value (imap_security.to_id ());
            b.set_member_name ("imap-user").add_string_value (imap_user);
            b.set_member_name ("smtp-host").add_string_value (smtp_host);
            b.set_member_name ("smtp-port").add_int_value (smtp_port);
            b.set_member_name ("smtp-security").add_string_value (smtp_security.to_id ());
            b.set_member_name ("smtp-user").add_string_value (smtp_user);
            b.set_member_name ("trusted-imap").add_string_value (trusted_imap);
            b.set_member_name ("trusted-smtp").add_string_value (trusted_smtp);
            b.set_member_name ("signature").add_string_value (signature);
            b.set_member_name ("source").add_string_value (source);
            b.set_member_name ("protocol").add_string_value (protocol);
            b.set_member_name ("api-url").add_string_value (api_url);
            b.set_member_name ("sieve-host").add_string_value (sieve_host);
            b.set_member_name ("sieve-port").add_int_value (sieve_port);
            b.set_member_name ("shared").add_string_value (shared);
            b.set_member_name ("identities").add_string_value (identities);
            b.set_member_name ("sig-new").add_string_value (sig_new);
            b.set_member_name ("sig-reply").add_string_value (sig_reply);
            b.set_member_name ("pop-keep").add_boolean_value (pop_keep);
            b.set_member_name ("smime-cert").add_string_value (smime_cert);
            b.set_member_name ("pgp-key").add_string_value (pgp_key);
            b.set_member_name ("sign-default").add_boolean_value (sign_default);
            b.set_member_name ("encrypt-default").add_boolean_value (encrypt_default);
            b.set_member_name ("auth-mechanism").add_string_value (auth_mechanism);
            b.end_object ();
            return b.get_root ();
        }

        private static string str (Json.Object o, string key) {
            return o.has_member (key) ? o.get_string_member (key) : "";
        }

        public static Account from_json (Json.Object o) {
            var a = new Account ();
            a.id = str (o, "id");
            a.full_name = str (o, "full-name");
            a.email = str (o, "email");
            a.label = str (o, "label");
            a.imap_host = str (o, "imap-host");
            a.imap_port = (uint16) (o.has_member ("imap-port") ? o.get_int_member ("imap-port") : 993);
            a.imap_security = Security.from_id (str (o, "imap-security"));
            a.imap_user = str (o, "imap-user");
            a.smtp_host = str (o, "smtp-host");
            a.smtp_port = (uint16) (o.has_member ("smtp-port") ? o.get_int_member ("smtp-port") : 465);
            a.smtp_security = Security.from_id (str (o, "smtp-security"));
            a.smtp_user = str (o, "smtp-user");
            a.trusted_imap = str (o, "trusted-imap");
            a.trusted_smtp = str (o, "trusted-smtp");
            a.signature = str (o, "signature");
            a.source = str (o, "source");
            if (a.source == "") a.source = "manual";
            a.protocol = str (o, "protocol");
            if (a.protocol == "") a.protocol = "imap";
            a.api_url = str (o, "api-url");
            a.sieve_host = str (o, "sieve-host");
            a.sieve_port = o.has_member ("sieve-port") ? (int) o.get_int_member ("sieve-port") : 0;
            a.shared = str (o, "shared");
            a.identities = str (o, "identities");
            a.sig_new = str (o, "sig-new");
            a.sig_reply = str (o, "sig-reply");
            a.pop_keep = o.has_member ("pop-keep") ? o.get_boolean_member ("pop-keep") : true;
            a.smime_cert = str (o, "smime-cert");
            a.pgp_key = str (o, "pgp-key");
            a.sign_default = o.has_member ("sign-default") && o.get_boolean_member ("sign-default");
            a.encrypt_default = o.has_member ("encrypt-default") && o.get_boolean_member ("encrypt-default");
            a.auth_mechanism = str (o, "auth-mechanism");
            return a;
        }
    }

    public class MailLogin : Object {
        public string user = "";
        public string secret = "";
        public string xoauth2 = "";

        public bool is_token {
            get { return xoauth2 != ""; }
        }
    }

    public abstract class CredentialSource : Object {
        public abstract async MailLogin fetch (bool refresh) throws Error;
        public abstract void report_reauth ();
    }

    public class StaticCredentials : CredentialSource {
        private string user;
        private string secret;
        private bool token;

        public StaticCredentials (string user, string secret, bool token) {
            this.user = user;
            this.secret = secret;
            this.token = token;
        }

        public override async MailLogin fetch (bool refresh) throws Error {
            var l = new MailLogin ();
            l.user = user;
            l.secret = secret;
            if (token) l.xoauth2 = secret;
            return l;
        }

        public override void report_reauth () {
        }
    }

    public class AccountStore : Object {
        public signal void changed ();

        public Gee.ArrayList<Account> accounts = new Gee.ArrayList<Account> ();
        private string path;

        public AccountStore (string dir) {
            path = Path.build_filename (dir, "accounts.json");
            load ();
        }

        private void load () {
            accounts.clear ();
            if (!FileUtils.test (path, FileTest.EXISTS)) return;
            try {
                var p = new Json.Parser ();
                p.load_from_file (path);
                var root = p.get_root ();
                if (root == null || root.get_node_type () != Json.NodeType.ARRAY) return;
                foreach (var n in root.get_array ().get_elements ()) {
                    if (n.get_node_type () != Json.NodeType.OBJECT) continue;
                    var a = Account.from_json (n.get_object ());
                    if (a.id != "" && a.email != "") accounts.add (a);
                }
            } catch (Error e) {
                warning ("lettere: %s", e.message);
            }
        }

        public void save () {
            var arr = new Json.Array ();
            foreach (var a in accounts) arr.add_element (a.to_json ());
            var root = new Json.Node (Json.NodeType.ARRAY);
            root.set_array (arr);
            var g = new Json.Generator ();
            g.pretty = true;
            g.set_root (root);
            try {
                DirUtils.create_with_parents (Path.get_dirname (path), 0700);
                FileUtils.set_contents (path, g.to_data (null));
                FileUtils.chmod (path, 0600);
            } catch (Error e) {
                warning ("lettere: %s", e.message);
            }
            changed ();
        }

        public Account? find (string id) {
            foreach (var a in accounts) if (a.id == id) return a;
            return null;
        }

        public Account? find_source (string source) {
            foreach (var a in accounts) if (a.source == source) return a;
            return null;
        }

        public void add (Account a) {
            if (a.id == "") a.id = Uuid.string_random ().substring (0, 8);
            accounts.add (a);
            save ();
        }

        public void remove (Account a) {
            accounts.remove (a);
            save ();
        }
    }

    namespace Secrets {
        private Secret.Schema? schema_instance;

        private Secret.Schema schema () {
            if (schema_instance == null) {
                schema_instance = new Secret.Schema ("dev.sinty.lettere", Secret.SchemaFlags.NONE,
                    "account", Secret.SchemaAttributeType.STRING,
                    "kind", Secret.SchemaAttributeType.STRING);
            }
            return schema_instance;
        }

        public async void store (Account a, string kind, string password) throws Error {
            yield Secret.password_store (schema (), Secret.COLLECTION_DEFAULT, "Lettere: %s (%s)".printf (a.email, kind.up ()), password, null, "account", a.id, "kind", kind);
        }

        public async string? lookup (Account a, string kind) throws Error {
            string? p = yield Secret.password_lookup (schema (), null, "account", a.id, "kind", kind);
            if (p == null && kind == "smtp") p = yield Secret.password_lookup (schema (), null, "account", a.id, "kind", "imap");
            return p;
        }

        public async void clear (Account a) {
            try {
                yield Secret.password_clear (schema (), null, "account", a.id, "kind", "imap");
                yield Secret.password_clear (schema (), null, "account", a.id, "kind", "smtp");
            } catch (Error e) {
            }
        }
    }
}
