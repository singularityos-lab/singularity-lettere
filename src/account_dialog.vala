using Gtk;
using Singularity.Widgets;

namespace Singularity.Apps.Lettere {

    public class ServerRows : Object {
        public ExpanderRow expander;
        public EntryRow host;
        public EntryRow port;
        public EntryRow user;
        public SelectionRow security;
        private string[] labels;

        public ServerRows (string title) {
            labels = { _("SSL/TLS"), _("STARTTLS"), _("None") };
            expander = new ExpanderRow (title, _("Found automatically when you sign in"));
            host = new EntryRow (_("Server"));
            port = new EntryRow (_("Port"));
            user = new EntryRow (_("User Name"));
            security = new SelectionRow (_("Security"), labels, labels[0]);
            security.selected.connect ((v) => {
                security.current_value = v;
                security.expanded = false;
                update_subtitle ();
            });
            host.entry_changed.connect (update_subtitle);
            port.entry_changed.connect (update_subtitle);
            expander.add_row (host);
            expander.add_row (port);
            expander.add_row (security);
            expander.add_row (user);
        }

        private void update_subtitle () {
            if (host.text.strip () == "") {
                expander.subtitle = _("Found automatically when you sign in");
                return;
            }
            expander.subtitle = "%s:%s, %s".printf (host.text.strip (), port.text.strip (), security.current_value);
        }

        public Security get_security () {
            if (security.current_value == labels[1]) return Security.STARTTLS;
            if (security.current_value == labels[2]) return Security.NONE;
            return Security.TLS;
        }

        public void set_values (string h, uint16 p, Security s, string u) {
            host.text = h;
            port.text = p > 0 ? p.to_string () : "";
            security.current_value = labels[(int) s];
            user.text = u;
            update_subtitle ();
        }

        public bool filled () {
            return host.text.strip () != "" && port.text.strip () != "";
        }

        public uint16 port_number () {
            uint64 v = 0;
            if (!uint64.try_parse (port.text.strip (), out v) || v == 0 || v > 65535) return 0;
            return (uint16) v;
        }
    }

    public class AccountDialog : ConfirmDialog {
        public signal void saved (Account account);
        public signal void removed (Account account);

        private LettereApp app;
        private Account? existing;
        private EntryRow name_row;
        private EmailRow email_row;
        private PasswordRow password_row;
        private EntryRow label_row;
        private ServerRows imap;
        private ServerRows smtp;
        private TextView signature;
        private Label hint;
        private Spinner spinner;
        private SelectionRow kind_row;
        private string fixed_protocol = "";
        private EntryRow api_row;
        private SwitchRow ntlm_row;
        private SwitchRow keep_row;
        private PreferencesGroup servers_group;
        private EntryRow identities_row;
        private EntryRow shared_row;
        private EntryRow sieve_row;
        private SelectionRow sig_new_row;
        private SelectionRow sig_reply_row;
        private SelectionRow smime_row;
        private SelectionRow pgp_row;
        private SwitchRow sign_row;
        private SwitchRow encrypt_row;
        private string[] kinds;
        private Gee.HashMap<string, string> key_ids = new Gee.HashMap<string, string> ();
        private Button trust_button;
        private CertificateTrust? pending_trust;
        private string pending_kind = "";
        private string trusted_imap = "";
        private string trusted_smtp = "";
        private bool hold;
        private bool busy;
        private bool servers_touched;
        private bool auto_filling;
        private Cancellable? cancel;

        public AccountDialog (LettereApp app, Account? existing) {
            base (app, existing == null ? _("Add Account") : _("Account Settings"), existing == null ? "dev.sinty.lettere" : null,
                existing == null ? _("Sign in with your email address and password. Lettere looks up the server settings for you.") : null,
                existing == null ? _("Sign In") : _("Save"), ConfirmDialog.ActionStyle.SUGGESTED);
            this.app = app;
            this.existing = existing;
            bool managed = existing != null && existing.managed;
            set_default_size (460, -1);

            var form = new Box (Orientation.VERTICAL, 12);
            var form_scroll = new ScrolledWindow ();
            form_scroll.hscrollbar_policy = PolicyType.NEVER;
            form_scroll.propagate_natural_height = true;
            form_scroll.max_content_height = 430;
            form_scroll.child = form;
            custom_area.append (form_scroll);
            if (managed) form.append (build_managed ());
            var main = new PreferencesGroup (existing == null ? null : existing.email);
            kinds = { _("IMAP"), _("POP"), _("Exchange"), _("JMAP") };
            string current_kind = kinds[0];
            if (existing != null) current_kind = kind_label (existing.protocol);
            kind_row = new SelectionRow (_("Account Type"), kinds, current_kind);
            kind_row.selected.connect ((v) => {
                kind_row.current_value = v;
                kind_row.expanded = false;
                update_kind ();
                validate ();
            });
            api_row = new EntryRow (_("Server Address (optional)"));
            api_row.text = existing != null ? existing.api_url : "";
            ntlm_row = new SwitchRow (_("Windows Sign-In (NTLM)"), _("For Exchange servers that do not accept plain passwords"), existing != null && existing.auth_mechanism == "ntlm");
            keep_row = new SwitchRow (_("Leave Messages on the Server"), null, existing == null || existing.pop_keep);
            if (existing != null && (existing.protocol == "gmail" || existing.protocol == "graph")) fixed_protocol = existing.protocol;
            if (!managed && fixed_protocol == "") {
                main.add_row (kind_row);
            }
            name_row = new EntryRow (_("Your Name"));
            string real = Environment.get_real_name ();
            name_row.text = real != "Unknown" ? real : "";
            email_row = new EmailRow (_("Email Address"));
            password_row = new PasswordRow (existing == null ? _("Password") : _("New Password (optional)"));
            if (!managed) {
                main.add_row (name_row);
                main.add_row (email_row);
                main.add_row (password_row);
                main.add_row (api_row);
                main.add_row (ntlm_row);
                main.add_row (keep_row);
            }
            if (existing != null) {
                label_row = new EntryRow (_("Account Name in the Sidebar"));
                label_row.text = existing.label;
                main.add_row (label_row);
            }
            form.append (main);

            var servers = new PreferencesGroup (_("Servers"));
            servers_group = servers;
            imap = new ServerRows (_("Incoming Mail"));
            smtp = new ServerRows (_("Outgoing Mail (SMTP)"));
            servers.add_row (imap.expander);
            servers.add_row (smtp.expander);
            if (!managed) form.append (servers);

            if (existing != null) {
                var sig_group = new PreferencesGroup (_("Signature"));
                signature = new TextView ();
                signature.wrap_mode = WrapMode.WORD_CHAR;
                signature.top_margin = 10;
                signature.bottom_margin = 10;
                signature.left_margin = 12;
                signature.right_margin = 12;
                signature.set_size_request (-1, 90);
                signature.buffer.text = existing.signature;
                signature.update_property (AccessibleProperty.LABEL, _("Signature"), -1);
                var frame = new ListBoxRow ();
                frame.activatable = false;
                frame.child = signature;
                sig_group.add_row (frame);
                string[] sigs = { _("Account Signature") };
                foreach (var it in app.signatures.items) sigs += it.name;
                sig_new_row = new SelectionRow (_("For New Messages"), sigs, existing.sig_new != "" ? existing.sig_new : sigs[0]);
                sig_new_row.selected.connect ((v) => {
                    sig_new_row.current_value = v;
                    sig_new_row.expanded = false;
                });
                sig_group.add_row (sig_new_row);
                sig_reply_row = new SelectionRow (_("For Replies and Forwards"), sigs, existing.sig_reply != "" ? existing.sig_reply : sigs[0]);
                sig_reply_row.selected.connect ((v) => {
                    sig_reply_row.current_value = v;
                    sig_reply_row.expanded = false;
                });
                sig_group.add_row (sig_reply_row);
                form.append (sig_group);
                var more = new PreferencesGroup (_("Addresses and Mailboxes"));
                identities_row = new EntryRow (_("Other Addresses You Send From"));
                identities_row.text = existing.identities.replace ("\n", ", ");
                more.add_row (identities_row);
                shared_row = new EntryRow (_("Shared Mailboxes"));
                shared_row.text = string.joinv (", ", existing.shared_mailboxes ());
                more.add_row (shared_row);
                if (existing.protocol == "imap") {
                    sieve_row = new EntryRow (_("Rules Server (ManageSieve)"));
                    sieve_row.text = existing.sieve_host != "" ? "%s:%d".printf (existing.sieve_host, existing.sieve_port > 0 ? existing.sieve_port : 4190) : "";
                    more.add_row (sieve_row);
                }
                form.append (more);
                var sec = new PreferencesGroup (_("Signing and Encryption"), _("S/MIME certificates and OpenPGP keys come from the keyrings of GnuPG."));
                smime_row = new SelectionRow (_("S/MIME Certificate"), { _("None") }, _("None"));
                smime_row.selected.connect ((v) => {
                    smime_row.current_value = v;
                    smime_row.expanded = false;
                });
                sec.add_row (smime_row);
                pgp_row = new SelectionRow (_("OpenPGP Key"), { _("None") }, _("None"));
                pgp_row.selected.connect ((v) => {
                    pgp_row.current_value = v;
                    pgp_row.expanded = false;
                });
                sec.add_row (pgp_row);
                sign_row = new SwitchRow (_("Sign Every Message"), null, existing.sign_default);
                sec.add_row (sign_row);
                encrypt_row = new SwitchRow (_("Encrypt When Possible"), null, existing.encrypt_default);
                sec.add_row (encrypt_row);
                var import_row = new ActionRow (_("Import a Certificate or Key…"), _("A .p12, .pem, .crt or .asc file"), "document-open-symbolic");
                import_row.activatable = true;
                import_row.activated.connect (() => import_key ());
                sec.add_row (import_row);
                form.append (sec);
                load_keys.begin ();
                if (!managed) set_secondary (_("Remove Account"), ConfirmDialog.ActionStyle.DESTRUCTIVE);
            }

            var status = new Box (Orientation.VERTICAL, 8);
            status.halign = Align.CENTER;
            var line = new Box (Orientation.HORIZONTAL, 8);
            line.halign = Align.CENTER;
            spinner = new Spinner ();
            spinner.visible = false;
            line.append (spinner);
            hint = new Label ("");
            hint.wrap = true;
            hint.max_width_chars = 50;
            hint.justify = Justification.CENTER;
            hint.add_css_class ("caption");
            line.append (hint);
            status.append (line);
            trust_button = new Button.with_label (_("Trust This Certificate"));
            trust_button.add_css_class ("pill");
            trust_button.halign = Align.CENTER;
            trust_button.visible = false;
            trust_button.clicked.connect (() => {
                if (pending_trust == null) return;
                if (pending_kind == "smtp") trusted_smtp = pending_trust.fingerprint;
                else trusted_imap = pending_trust.fingerprint;
                pending_trust = null;
                trust_button.visible = false;
                start.begin ();
            });
            status.append (trust_button);
            custom_area.append (status);

            if (existing != null) {
                name_row.text = existing.full_name;
                email_row.text = existing.email;
                imap.set_values (existing.imap_host, existing.imap_port, existing.imap_security, existing.imap_user);
                smtp.set_values (existing.smtp_host, existing.smtp_port, existing.smtp_security, existing.smtp_user);
                trusted_imap = existing.trusted_imap;
                trusted_smtp = existing.trusted_smtp;
                servers_touched = true;
            }

            email_row.entry_changed.connect (() => {
                update_hint ();
                validate ();
            });
            password_row.entry_changed.connect (validate);
            foreach (var r in new EntryRow[] { imap.host, imap.port, imap.user, smtp.host, smtp.port, smtp.user }) {
                r.entry_changed.connect (() => {
                    if (!auto_filling) servers_touched = true;
                    validate ();
                });
            }
            password_row.entry_activated.connect (() => {
                if (primary_sensitive) {
                    response (ConfirmDialog.Response.PRIMARY);
                    close_dialog ();
                }
            });
            response.connect ((r) => {
                if (r == ConfirmDialog.Response.PRIMARY) {
                    hold = true;
                    start.begin ();
                } else if (r == ConfirmDialog.Response.SECONDARY && existing != null) {
                    hold = true;
                    confirm_remove ();
                } else if (cancel != null) {
                    cancel.cancel ();
                }
            });
            update_kind ();
            validate ();
        }

        private string kind_label (string protocol) {
            switch (protocol) {
                case "pop3": return kinds[1];
                case "ews": return kinds[2];
                case "jmap": return kinds[3];
            }
            return kinds[0];
        }

        private string protocol () {
            if (fixed_protocol != "") return fixed_protocol;
            if (kind_row.current_value == kinds[1]) return "pop3";
            if (kind_row.current_value == kinds[2]) return "ews";
            if (kind_row.current_value == kinds[3]) return "jmap";
            return "imap";
        }

        private void update_kind () {
            string p = protocol ();
            bool api = p == "ews" || p == "jmap" || fixed_protocol != "";
            api_row.visible = api;
            ntlm_row.visible = p == "ews";
            keep_row.visible = p == "pop3";
            servers_group.visible = !api && !(existing != null && existing.managed);
            imap.expander.title = p == "pop3" ? _("Incoming Mail (POP)") : _("Incoming Mail (IMAP)");
            if (p == "pop3" && imap.port.text.strip () == "993") imap.port.text = "995";
            if (p == "imap" && imap.port.text.strip () == "995") imap.port.text = "993";
        }

        private async void load_keys () {
            var keys = yield Crypto.secret_keys ();
            string[] smime = { _("None") };
            string[] pgp = { _("None") };
            string smime_cur = _("None");
            string pgp_cur = _("None");
            foreach (var k in keys) {
                string label = "%s (%s)".printf (k.label, k.id.length > 8 ? k.id.substring (k.id.length - 8) : k.id);
                key_ids[label] = k.id;
                if (k.smime) {
                    smime += label;
                    if (existing.smime_cert == k.id) smime_cur = label;
                } else {
                    pgp += label;
                    if (existing.pgp_key == k.id) pgp_cur = label;
                }
            }
            smime_row.set_items (smime);
            smime_row.current_value = smime_cur;
            pgp_row.set_items (pgp);
            pgp_row.current_value = pgp_cur;
        }

        private void import_key () {
            var fd = new FileDialog ();
            fd.title = _("Import a Certificate or Key");
            fd.open.begin (this, null, (o, r) => {
                try {
                    var f = fd.open.end (r);
                    if (f == null) return;
                    uint8[] data;
                    string etag;
                    f.load_contents (null, out data, out etag);
                    Crypto.import_key.begin (data, (o2, r2) => {
                        try {
                            bool ok = Crypto.import_key.end (r2);
                            show_hint (ok ? _("Imported %s").printf (f.get_basename ()) : _("%s could not be imported").printf (f.get_basename ()), false, !ok);
                            load_keys.begin ();
                        } catch (Error e) {
                            show_hint (e.message, false, true);
                        }
                    });
                } catch (Error e) {
                }
            });
        }

        private void save_advanced (Account a) {
            if (sig_new_row != null) a.sig_new = sig_new_row.current_value == _("Account Signature") ? "" : sig_new_row.current_value;
            if (sig_reply_row != null) a.sig_reply = sig_reply_row.current_value == _("Account Signature") ? "" : sig_reply_row.current_value;
            if (identities_row != null) {
                var parts = new Gee.ArrayList<string> ();
                foreach (var ad in Mime.parse_addresses (identities_row.text)) parts.add (ad.to_string ());
                a.identities = string.joinv ("\n", parts.to_array ());
            }
            if (shared_row != null) {
                var parts = new Gee.ArrayList<string> ();
                foreach (string x in shared_row.text.split (",")) if (x.strip () != "") parts.add (x.strip ());
                a.shared = string.joinv ("\n", parts.to_array ());
            }
            if (sieve_row != null) {
                string v = sieve_row.text.strip ();
                int colon = v.last_index_of_char (':');
                a.sieve_host = colon > 0 ? v.substring (0, colon) : v;
                a.sieve_port = colon > 0 ? int.parse (v.substring (colon + 1)) : 0;
            }
            if (smime_row != null) a.smime_cert = key_ids[smime_row.current_value] ?? "";
            if (pgp_row != null) a.pgp_key = key_ids[pgp_row.current_value] ?? "";
            if (sign_row != null) a.sign_default = sign_row.active;
            if (encrypt_row != null) a.encrypt_default = encrypt_row.active;
        }

        private Widget build_managed () {
            var group = new PreferencesGroup (_("Online Account"), _("Server settings and sign-in come from Settings. Here you can change only how the account looks in Lettere."));
            string provider = _("Online Account");
            string icon = "folder-remote-symbolic";
            var creds = existing.online as OnlineCredentials;
            if (creds != null) {
                provider = creds.origin.provider_name;
                icon = creds.origin.symbolic_icon_name;
            }
            var row = new ActionRow (provider, _("Managed in Settings, Online Accounts"), icon);
            row.add_suffix (new Image.from_icon_name ("go-next-symbolic"));
            row.activated.connect (() => OnlineMail.open_settings ());
            group.add_row (row);
            return group;
        }

        private void save_managed () {
            if (label_row != null) existing.label = label_row.text.strip ();
            if (signature != null) existing.signature = signature.buffer.text.strip ();
            save_advanced (existing);
            app.accounts.save ();
            busy = false;
            saved (existing);
            hold = false;
            base.close_dialog ();
        }

        public override void close_dialog () {
            if (hold) {
                hold = false;
                return;
            }
            if (cancel != null) cancel.cancel ();
            base.close_dialog ();
        }

        public void prefill (Account a, string password) {
            name_row.text = a.full_name;
            email_row.text = a.email;
            password_row.text = password;
            auto_filling = true;
            imap.set_values (a.imap_host, a.imap_port, a.imap_security, a.imap_user);
            smtp.set_values (a.smtp_host, a.smtp_port, a.smtp_security, a.smtp_user);
            auto_filling = false;
            servers_touched = true;
            trusted_imap = a.trusted_imap;
            trusted_smtp = a.trusted_smtp;
            validate ();
        }

        private void update_hint () {
            string email = email_row.text.strip ();
            if (Autoconfig.needs_app_password (email)) {
                show_hint (_("This provider needs an app password: create one in your account's security settings and use it here, or add the account in Settings, Online Accounts."), false, false);
            } else if (!busy) {
                show_hint ("", false, false);
            }
        }

        private bool valid_email () {
            string e = email_row.text.strip ();
            int at = e.index_of_char ('@');
            return at > 0 && at < e.length - 1 && !e.contains (" ");
        }

        private void validate () {
            bool ok = valid_email () && !busy;
            if (existing == null) ok = ok && password_row.text != "";
            bool api = kind_row != null && (protocol () == "ews" || protocol () == "jmap" || fixed_protocol != "");
            if (servers_touched && !api) ok = ok && imap.filled () && (protocol () == "pop3" || smtp.filled ());
            primary_sensitive = ok;
        }

        private void show_hint (string text, bool working, bool error) {
            hint.label = text;
            spinner.visible = working;
            spinner.spinning = working;
            if (error) hint.add_css_class ("error");
            else hint.remove_css_class ("error");
        }

        private void fill (MailConfig cfg) {
            auto_filling = true;
            imap.set_values (cfg.imap.host, cfg.imap.port, cfg.imap.security, cfg.imap.username);
            smtp.set_values (cfg.smtp.host, cfg.smtp.port, cfg.smtp.security, cfg.smtp.username);
            auto_filling = false;
        }

        private Account collect () {
            var a = new Account ();
            if (existing != null) {
                a.id = existing.id;
                a.source = existing.source;
                a.signature = existing.signature;
                a.label = existing.label;
            }
            a.full_name = name_row.text.strip ();
            a.email = email_row.text.strip ();
            a.imap_host = imap.host.text.strip ();
            a.imap_port = imap.port_number ();
            a.imap_security = imap.get_security ();
            a.imap_user = imap.user.text.strip () != "" ? imap.user.text.strip () : a.email;
            a.smtp_host = smtp.host.text.strip ();
            a.smtp_port = smtp.port_number ();
            a.smtp_security = smtp.get_security ();
            a.smtp_user = smtp.user.text.strip () != "" ? smtp.user.text.strip () : a.imap_user;
            a.trusted_imap = trusted_imap;
            a.trusted_smtp = trusted_smtp;
            a.protocol = protocol ();
            a.api_url = api_row.text.strip ();
            a.auth_mechanism = ntlm_row.active ? "ntlm" : "";
            a.pop_keep = keep_row.active;
            if (signature != null) a.signature = signature.buffer.text.strip ();
            if (label_row != null) a.label = label_row.text.strip ();
            return a;
        }

        private bool servers_changed (Account a) {
            if (existing == null) return true;
            return a.imap_host != existing.imap_host || a.imap_port != existing.imap_port || a.imap_security != existing.imap_security
                || a.imap_user != existing.imap_user || a.smtp_host != existing.smtp_host || a.smtp_port != existing.smtp_port
                || a.smtp_security != existing.smtp_security || a.smtp_user != existing.smtp_user || a.email != existing.email;
        }

        private async void start () {
            if (busy) return;
            busy = true;
            validate ();
            if (existing != null && existing.managed) {
                save_managed ();
                return;
            }
            cancel = new Cancellable ();
            string email = email_row.text.strip ();
            bool api = protocol () == "ews" || protocol () == "jmap";
            if (!servers_touched && !api) {
                show_hint (_("Looking up the settings for %s…").printf (Autoconfig.domain_of (email)), true, false);
                var cfg = yield Autoconfig.lookup (email, cancel);
                if (cancel.is_cancelled ()) return;
                if (cfg != null && cfg.oauth_only) {
                    busy = false;
                    validate ();
                    show_hint (_("This provider only allows signing in through the browser. Add the account in Settings, Online Accounts, and it appears in Lettere by itself."), false, true);
                    imap.expander.expanded = true;
                    servers_touched = true;
                    return;
                }
                fill (cfg ?? Autoconfig.guess (email));
            }
            var a = collect ();
            if (!api && (a.imap_port == 0 || a.smtp_port == 0)) {
                busy = false;
                validate ();
                show_hint (_("The ports must be numbers between 1 and 65535."), false, true);
                return;
            }
            string password = password_row.text;
            bool need_test = servers_changed (a) || password != "" || a.trusted_imap != (existing != null ? existing.trusted_imap : "") || a.trusted_smtp != (existing != null ? existing.trusted_smtp : "");
            if (need_test) {
                if (password == "" && existing != null) {
                    try {
                        password = (yield Secrets.lookup (existing, "imap")) ?? "";
                    } catch (Error e) {
                        password = "";
                    }
                }
                string? problem = yield test (a, password);
                if (cancel.is_cancelled ()) return;
                if (problem != null) {
                    busy = false;
                    validate ();
                    show_hint (problem, false, true);
                    return;
                }
            }
            try {
                if (existing == null) {
                    app.accounts.add (a);
                } else {
                    existing.full_name = a.full_name;
                    existing.email = a.email;
                    existing.label = a.label;
                    existing.signature = a.signature;
                    existing.imap_host = a.imap_host;
                    existing.imap_port = a.imap_port;
                    existing.imap_security = a.imap_security;
                    existing.imap_user = a.imap_user;
                    existing.smtp_host = a.smtp_host;
                    existing.smtp_port = a.smtp_port;
                    existing.smtp_security = a.smtp_security;
                    existing.smtp_user = a.smtp_user;
                    existing.trusted_imap = a.trusted_imap;
                    existing.trusted_smtp = a.trusted_smtp;
                    existing.protocol = a.protocol;
                    existing.api_url = a.api_url;
                    existing.auth_mechanism = a.auth_mechanism;
                    existing.pop_keep = a.pop_keep;
                    save_advanced (existing);
                    a = existing;
                }
                if (password_row.text != "") {
                    yield Secrets.store (a, "imap", password_row.text);
                    yield Secrets.store (a, "smtp", password_row.text);
                }
                app.accounts.save ();
                if (existing != null) {
                    var s = app.syncs[a.id];
                    if (s != null && need_test) s.credentials_updated ();
                }
            } catch (Error e) {
                busy = false;
                validate ();
                show_hint (_("Could not save the password in the keyring: %s").printf (e.message), false, true);
                return;
            }
            busy = false;
            saved (a);
            hold = false;
            base.close_dialog ();
        }

        private async string? test (Account a, string password) {
            if (a.protocol == "ews" || a.protocol == "jmap") {
                var probe = new Account ();
                probe.id = "probe";
                probe.email = a.email;
                probe.protocol = a.protocol;
                probe.api_url = a.api_url;
                probe.auth_mechanism = a.auth_mechanism;
                probe.source = "online:probe";
                probe.imap_user = a.imap_user;
                probe.online = new StaticCredentials (a.imap_user != "" ? a.imap_user : a.email, password, false);
                show_hint (_("Connecting to %s…").printf (a.api_url != "" ? a.api_url : Autoconfig.domain_of (a.email)), true, false);
                try {
                    var store = app.store;
                    var sync = new AccountSync (probe, store);
                    yield sync.backend.connect ();
                } catch (Error e) {
                    return explain (e, null, "imap", a.api_url != "" ? a.api_url : Autoconfig.domain_of (a.email));
                }
                show_hint ("", false, false);
                return null;
            }
            if (a.protocol == "pop3") {
                show_hint (_("Connecting to %s…").printf (a.imap_host), true, false);
                var p = new Pop3Client ();
                try {
                    yield p.open (a.imap_host, a.imap_port, a.imap_security, a.trusted_imap);
                    yield p.login (a.imap_user, password);
                    yield p.quit ();
                } catch (Error e) {
                    return explain (e, p.tls_failure, "imap", a.imap_host);
                }
            } else {
                string? problem = yield test_imap (a, password);
                if (problem != null) return problem;
            }
            return yield test_smtp (a, password);
        }

        private async string? test_imap (Account a, string password) {
            show_hint (_("Connecting to %s…").printf (a.imap_host), true, false);
            var c = new ImapClient ();
            try {
                yield c.open (a.imap_host, a.imap_port, a.imap_security, a.trusted_imap, 20);
                yield c.login (a.imap_user, password);
                yield c.logout ();
            } catch (Error e) {
                c.close ();
                return explain (e, c.tls_failure, "imap", a.imap_host);
            }
            return null;
        }

        private async string? test_smtp (Account a, string password) {
            show_hint (_("Connecting to %s…").printf (a.smtp_host), true, false);
            var s = new SmtpClient ();
            try {
                yield s.open (a.smtp_host, a.smtp_port, a.smtp_security, a.trusted_smtp);
                yield s.login (a.smtp_user, password);
                yield s.quit ();
            } catch (Error e) {
                return explain (e, s.tls_failure, "smtp", a.smtp_host);
            }
            show_hint ("", false, false);
            return null;
        }

        private string explain (Error e, CertificateTrust? trust, string kind, string host) {
            if (e is MailError.AUTH) {
                if (Autoconfig.needs_app_password (email_row.text)) return _("The server refused the password. This provider needs an app password instead of your usual password.");
                return _("The server refused the user name or password (%s).").printf (e.message);
            }
            if (e is MailError.TLS) {
                if (trust != null) {
                    pending_trust = trust;
                    pending_kind = kind;
                    trust_button.visible = true;
                    string which = kind == "smtp" ? _("the outgoing server %s").printf (host) : _("the incoming server %s").printf (host);
                    return _("The certificate of %s is not trusted because %s. Trust it only if you know this server, for example your own. Fingerprint: %s").printf (which, trust.problem, trust.fingerprint.substring (0, 32));
                }
                return e.message;
            }
            if (e is MailError.OFFLINE) {
                if (kind == "imap") imap.expander.expanded = true;
                else smtp.expander.expanded = true;
                servers_touched = true;
                return _("%s could not be reached. Check the server name and port, and that you are online.").printf (host);
            }
            return _("The server answered with an error: %s").printf (e.message);
        }

        private void confirm_remove () {
            var dlg = new ConfirmDialog (app, _("Remove Account?"), "dev.sinty.lettere",
                _("The messages of %s saved on this computer and its password will be removed. Nothing is deleted on the server.").printf (existing.email),
                _("Remove"), ConfirmDialog.ActionStyle.DESTRUCTIVE);
            dlg.transient_for = this;
            dlg.modal = true;
            dlg.response.connect ((r) => {
                if (r != ConfirmDialog.Response.PRIMARY) return;
                Secrets.clear.begin (existing);
                removed (existing);
                app.accounts.remove (existing);
                hold = false;
                base.close_dialog ();
            });
            dlg.open_dialog ();
        }
    }
}
