namespace Singularity.Apps.Lettere {

    public class CryptoResult : Object {
        public MimeMessage message;
        public string kind = "";
        public bool is_signed;
        public bool encrypted;
        public bool ok = true;
        public string signer = "";
        public string problem = "";

        public string describe () {
            string tech = kind == "smime" ? "S/MIME" : "OpenPGP";
            if (encrypted && is_signed && ok) return _("Encrypted and signed by %s (%s). The signature is valid.").printf (signer, tech);
            if (encrypted && !is_signed && ok) return _("This message was encrypted with %s.").printf (tech);
            if (is_signed && ok) return _("Signed by %s (%s). The signature is valid and the message was not changed.").printf (signer, tech);
            if (encrypted && problem != "" && !is_signed) return _("This message is encrypted with %s and could not be decrypted: %s").printf (tech, problem);
            if (is_signed) return _("The %s signature could not be verified: %s").printf (tech, problem != "" ? problem : _("unknown signer"));
            return problem;
        }
    }

    public class GpgRun {
        public int status;
        public uint8[] output = {};
        public string status_lines = "";
        public string errors = "";

        public bool has (string code) {
            foreach (string l in status_lines.split ("\n")) if (l.has_prefix ("[GNUPG:] " + code)) return true;
            return false;
        }

        public string line (string code) {
            foreach (string l in status_lines.split ("\n")) if (l.has_prefix ("[GNUPG:] " + code)) return l.substring (9 + code.length).strip ();
            return "";
        }
    }

    namespace Crypto {
        private string? scratch_dir () {
            string dir = Path.build_filename (Environment.get_user_cache_dir (), "singularity-lettere", "crypto");
            DirUtils.create_with_parents (dir, 0700);
            return dir;
        }

        public bool have (string program) {
            return Environment.find_program_in_path (program) != null;
        }

        public async GpgRun run (string program, string[] args, uint8[]? input) throws Error {
            string[] argv = { program, "--batch", "--no-tty", "--status-fd", "2" };
            if (program == "gpg") {
                argv += "--pinentry-mode";
                argv += "loopback";
                argv += "--trust-model";
                argv += "always";
            }
            foreach (string a in args) argv += a;
            var proc = new Subprocess.newv (argv, SubprocessFlags.STDIN_PIPE | SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_PIPE);
            Bytes? out_bytes, err_bytes;
            yield proc.communicate_async (new Bytes (input ?? new uint8[0]), null, out out_bytes, out err_bytes);
            var r = new GpgRun ();
            r.status = proc.get_if_exited () ? proc.get_exit_status () : -1;
            if (out_bytes != null) r.output = out_bytes.get_data ();
            string err = err_bytes != null ? Mime.bytes_to_string (err_bytes.get_data ()) : "";
            var st = new StringBuilder ();
            var plain = new StringBuilder ();
            foreach (string l in err.split ("\n")) {
                if (l.has_prefix ("[GNUPG:]")) st.append (l + "\n");
                else if (l.strip () != "") plain.append (l.strip () + "\n");
            }
            r.status_lines = st.str;
            r.errors = plain.str.strip ();
            return r;
        }

        private string temp_file (uint8[] data, string suffix) throws Error {
            string path = Path.build_filename (scratch_dir (), Uuid.string_random () + suffix);
            FileUtils.set_data (path, data);
            FileUtils.chmod (path, 0600);
            return path;
        }

        public uint8[] canonical (uint8[] data) {
            string s = Mime.bytes_to_string (data);
            return s.replace ("\r\n", "\n").replace ("\n", "\r\n").data;
        }

        private uint8[]? raw_part (uint8[] data, int index) {
            var root = Mime.parse_part (data, "1", 0);
            string boundary = root.type_params["boundary"] ?? "";
            if (boundary == "") return null;
            string s = Mime.bytes_to_string (data);
            string delim = "--" + boundary;
            int pos = 0;
            var starts = new Gee.ArrayList<int> ();
            while ((pos = s.index_of (delim, pos)) >= 0) {
                if (pos == 0 || s[pos - 1] == '\n') starts.add (pos);
                pos += delim.length;
            }
            if (starts.size < index + 2) return null;
            int a = s.index_of ("\n", starts[index]) + 1;
            int b = starts[index + 1];
            if (b >= 2 && s[b - 1] == '\n') b--;
            if (b >= 1 && s[b - 1] == '\r') b--;
            return s.substring (a, b - a).data;
        }

        private MimeMessage merge (MimePart outer, uint8[] inner) {
            var sb = new StringBuilder ();
            foreach (var h in outer.headers) {
                string n = h.name.down ();
                if (n == "content-type" || n == "content-transfer-encoding" || n == "content-disposition" || n == "mime-version") continue;
                sb.append (h.name + ": " + h.value + "\r\n");
            }
            sb.append ("MIME-Version: 1.0\r\n");
            var b = new ByteArray ();
            b.append (sb.str.data);
            b.append (inner);
            return new MimeMessage (b.data);
        }

        private string signer_of (GpgRun r) {
            string good = r.line ("GOODSIG");
            if (good != "") {
                int sp = good.index_of_char (' ');
                return sp > 0 ? good.substring (sp + 1) : good;
            }
            return "";
        }

        public async CryptoResult open (uint8[] raw, Object? app) {
            var result = new CryptoResult ();
            var msg = new MimeMessage (raw);
            result.message = msg;
            var root = msg.root;
            string ct = root.content_type;
            string proto = (root.type_params["protocol"] ?? "").down ();
            try {
                if (ct == "multipart/signed" && (proto == "application/pkcs7-signature" || proto == "application/x-pkcs7-signature" || proto == "application/pgp-signature")) {
                    bool smime = proto != "application/pgp-signature";
                    result.kind = smime ? "smime" : "pgp";
                    result.is_signed = true;
                    var data = raw_part (raw, 0);
                    if (data == null || root.children.size < 2) throw new MailError.PROTOCOL (_("the signed message is damaged"));
                    result.message = merge (root, data);
                    yield verify_detached (smime, data, root.children[1].decoded (), result);
                    import_autocrypt (root, app);
                    return result;
                }
                if (ct == "application/pkcs7-mime" || ct == "application/x-pkcs7-mime") {
                    result.kind = "smime";
                    string type = (root.type_params["smime-type"] ?? "enveloped-data").down ();
                    uint8[] der = root.decoded ();
                    if (type == "signed-data" || type == "opaque") {
                        result.is_signed = true;
                        var r = yield run ("gpgsm", { "--verify", "--output", "-" }, der);
                        result.ok = r.has ("GOODSIG") && !r.has ("BADSIG");
                        result.signer = signer_of (r);
                        if (!result.ok) result.problem = r.errors != "" ? r.errors : _("the signature does not match");
                        if (r.output.length > 0) result.message = merge (root, canonical (r.output));
                        return result;
                    }
                    result.encrypted = true;
                    var d = yield run ("gpgsm", { "--decrypt", "--output", "-" }, der);
                    if (d.output.length == 0 || d.status != 0) {
                        result.ok = false;
                        result.problem = d.errors != "" ? first_line (d.errors) : _("no private key for this message");
                        return result;
                    }
                    var inner = canonical (d.output);
                    var sub = yield open (merge_bytes (root, inner), app);
                    sub.encrypted = true;
                    sub.kind = "smime";
                    return sub;
                }
                if (ct == "multipart/encrypted" && proto == "application/pgp-encrypted") {
                    result.kind = "pgp";
                    result.encrypted = true;
                    if (root.children.size < 2) throw new MailError.PROTOCOL (_("the encrypted message is damaged"));
                    var d = yield run ("gpg", { "--decrypt" }, root.children[1].decoded ());
                    if (d.output.length == 0) {
                        result.ok = false;
                        result.problem = d.errors != "" ? first_line (d.errors) : _("no private key for this message");
                        return result;
                    }
                    var inner = canonical (d.output);
                    var sub = yield open (merge_bytes (root, inner), app);
                    sub.encrypted = true;
                    sub.kind = "pgp";
                    if (d.has ("GOODSIG")) {
                        sub.is_signed = true;
                        sub.signer = signer_of (d);
                    } else if (d.has ("BADSIG")) {
                        sub.is_signed = true;
                        sub.ok = false;
                        sub.problem = _("the signature does not match");
                    }
                    return sub;
                }
                if (msg.text_plain.contains ("-----BEGIN PGP MESSAGE-----")) {
                    result.kind = "pgp";
                    result.encrypted = true;
                    int a = msg.text_plain.index_of ("-----BEGIN PGP MESSAGE-----");
                    int b = msg.text_plain.index_of ("-----END PGP MESSAGE-----");
                    if (b > a) {
                        var d = yield run ("gpg", { "--decrypt" }, msg.text_plain.substring (a, b - a + 25).data);
                        if (d.output.length > 0) {
                            msg.text_plain = Mime.bytes_to_string (d.output);
                            if (d.has ("GOODSIG")) {
                                result.is_signed = true;
                                result.signer = signer_of (d);
                            }
                        } else {
                            result.ok = false;
                            result.problem = first_line (d.errors);
                        }
                    }
                    return result;
                }
                if (msg.text_plain.contains ("-----BEGIN PGP SIGNED MESSAGE-----")) {
                    result.kind = "pgp";
                    result.is_signed = true;
                    var r = yield run ("gpg", { "--verify" }, msg.text_plain.data);
                    result.ok = r.has ("GOODSIG");
                    result.signer = signer_of (r);
                    if (!result.ok) result.problem = first_line (r.errors);
                    return result;
                }
                import_autocrypt (root, app);
            } catch (Error e) {
                result.ok = false;
                result.problem = e.message;
            }
            return result;
        }

        private string first_line (string s) {
            int nl = s.index_of_char ('\n');
            return nl > 0 ? s.substring (0, nl) : s;
        }

        private uint8[] merge_bytes (MimePart outer, uint8[] inner) {
            var sb = new StringBuilder ();
            foreach (var h in outer.headers) {
                string n = h.name.down ();
                if (n == "content-type" || n == "content-transfer-encoding" || n == "content-disposition" || n == "mime-version") continue;
                sb.append (h.name + ": " + h.value + "\r\n");
            }
            sb.append ("MIME-Version: 1.0\r\n");
            var b = new ByteArray ();
            b.append (sb.str.data);
            b.append (inner);
            return b.steal ();
        }

        private async void verify_detached (bool smime, uint8[] data, uint8[] signature, CryptoResult result) throws Error {
            string sig_path = temp_file (signature, smime ? ".p7s" : ".asc");
            string data_path = temp_file (canonical (data), ".eml");
            try {
                var r = smime ? yield run ("gpgsm", { "--verify", sig_path, data_path }, null) : yield run ("gpg", { "--verify", sig_path, data_path }, null);
                result.ok = r.has ("GOODSIG") && !r.has ("BADSIG");
                result.signer = signer_of (r);
                if (result.signer == "" && r.has ("VALIDSIG")) result.signer = r.line ("VALIDSIG").split (" ")[0];
                if (!result.ok) {
                    if (r.has ("BADSIG")) result.problem = _("the message was changed after it was signed");
                    else if (r.has ("NO_PUBKEY") || r.has ("ERRSIG")) result.problem = _("the signer's key or certificate is missing");
                    else result.problem = r.errors != "" ? first_line (r.errors) : _("unknown signer");
                }
            } finally {
                FileUtils.unlink (sig_path);
                FileUtils.unlink (data_path);
            }
        }

        private void import_autocrypt (MimePart root, Object? app) {
            string? ac = root.header ("Autocrypt");
            if (ac == null || !have ("gpg")) return;
            string v = Mime.unfold (ac);
            int k = v.index_of ("keydata=");
            if (k < 0) return;
            string b64 = v.substring (k + 8).replace (" ", "").replace ("\t", "").replace ("\r", "").replace ("\n", "");
            int semi = b64.index_of_char (';');
            if (semi >= 0) b64 = b64.substring (0, semi);
            var key = Base64.decode (b64);
            if (key.length < 32) return;
            run.begin ("gpg", { "--import" }, key, (o, r) => {
                try {
                    run.end (r);
                } catch (Error e) {
                }
            });
        }

        public async bool import_key (uint8[] data) throws Error {
            bool pem = Mime.bytes_to_string (data).contains ("BEGIN CERTIFICATE") || (data.length > 1 && data[0] == 0x30);
            GpgRun r;
            if (pem && have ("gpgsm")) r = yield run ("gpgsm", { "--import" }, data);
            else r = yield run ("gpg", { "--import" }, data);
            return r.has ("IMPORT_OK") || r.has ("IMPORTED") || r.status == 0;
        }

        public class KeyInfo {
            public string id = "";
            public string label = "";
            public bool smime;
        }

        public async Gee.List<KeyInfo> secret_keys () {
            var list = new Gee.ArrayList<KeyInfo> ();
            foreach (string program in new string[] { "gpg", "gpgsm" }) {
                if (!have (program)) continue;
                try {
                    var r = yield run (program, { "--with-colons", "--list-secret-keys" }, null);
                    string last_id = "";
                    foreach (string l in Mime.bytes_to_string (r.output).split ("\n")) {
                        string[] f = l.split (":");
                        if (f.length < 10) continue;
                        if (f[0] == "sec" || f[0] == "crs") last_id = f[4];
                        if (f[0] == "fpr" && program == "gpgsm" && last_id != "") last_id = f[9];
                        if (f[0] == "uid" && last_id != "") {
                            var k = new KeyInfo ();
                            k.id = last_id;
                            k.label = Mime.decode_words (f[9].replace ("\\x3a", ":"));
                            k.smime = program == "gpgsm";
                            list.add (k);
                            last_id = "";
                        }
                    }
                } catch (Error e) {
                }
            }
            return list;
        }

        public async bool has_public_key (bool smime, string email) {
            string program = smime ? "gpgsm" : "gpg";
            if (!have (program)) return false;
            try {
                var r = yield run (program, { "--with-colons", "--list-keys", smime ? email : "<" + email + ">" }, null);
                foreach (string l in Mime.bytes_to_string (r.output).split ("\n")) {
                    if (l.has_prefix ("pub:") || l.has_prefix ("crt:")) return true;
                }
            } catch (Error e) {
            }
            return false;
        }

        public async uint8[] protect (MessageBuilder b, Account a, bool sign, bool encrypt, bool smime) throws Error {
            string entity = b.entity ();
            uint8[] body = canonical (entity.data);
            if (sign) {
                string key = smime ? a.smime_cert : a.pgp_key;
                if (key == "") throw new MailError.PROTOCOL (_("Choose a certificate or key for %s in the account settings first").printf (a.email));
                string boundary = "=_lettere_signed_" + Uuid.string_random ().replace ("-", "");
                GpgRun r;
                if (smime) r = yield run ("gpgsm", { "--detach-sign", "--base64", "-u", key, "--output", "-" }, body);
                else r = yield run ("gpg", { "--detach-sign", "--armor", "--digest-algo", "SHA256", "-u", key, "--output", "-" }, body);
                if (r.output.length == 0 || r.status != 0) throw new MailError.PROTOCOL (_("Could not sign the message: %s").printf (first_line (r.errors)));
                var sb = new StringBuilder ();
                if (smime) sb.append ("Content-Type: multipart/signed; protocol=\"application/pkcs7-signature\"; micalg=sha-256; boundary=\"%s\"\r\n\r\n".printf (boundary));
                else sb.append ("Content-Type: multipart/signed; protocol=\"application/pgp-signature\"; micalg=pgp-sha256; boundary=\"%s\"\r\n\r\n".printf (boundary));
                sb.append ("This is a cryptographically signed message in MIME format.\r\n\r\n");
                sb.append ("--" + boundary + "\r\n");
                var outb = new ByteArray ();
                outb.append (sb.str.data);
                outb.append (body);
                var tail = new StringBuilder ();
                tail.append ("\r\n--" + boundary + "\r\n");
                if (smime) {
                    tail.append ("Content-Type: application/pkcs7-signature; name=\"smime.p7s\"\r\nContent-Transfer-Encoding: base64\r\nContent-Disposition: attachment; filename=\"smime.p7s\"\r\n\r\n");
                    tail.append (Mime.bytes_to_string (r.output).replace ("\r\n", "\n").replace ("\n", "\r\n"));
                } else {
                    tail.append ("Content-Type: application/pgp-signature; name=\"signature.asc\"\r\nContent-Description: OpenPGP digital signature\r\nContent-Disposition: attachment; filename=\"signature.asc\"\r\n\r\n");
                    tail.append (Mime.bytes_to_string (r.output).replace ("\r\n", "\n").replace ("\n", "\r\n"));
                }
                if (!tail.str.has_suffix ("\r\n")) tail.append ("\r\n");
                tail.append ("--" + boundary + "--\r\n");
                outb.append (tail.str.data);
                body = outb.steal ();
            }
            if (encrypt) {
                string[] args = smime ? new string[] { "--encrypt", "--base64", "--output", "-" } : new string[] { "--encrypt", "--armor", "--output", "-" };
                var rcpts = b.recipients ();
                rcpts.add (a.email);
                foreach (string r in rcpts) {
                    if (!(yield has_public_key (smime, r))) throw new MailError.PROTOCOL (smime ? _("There is no certificate for %s. Ask them for a signed message first.").printf (r) : _("There is no OpenPGP key for %s. Import their key first.").printf (r));
                    args += "-r";
                    args += smime ? r : "<" + r + ">";
                }
                var e = yield run (smime ? "gpgsm" : "gpg", args, body);
                if (e.output.length == 0 || e.status != 0) throw new MailError.PROTOCOL (_("Could not encrypt the message: %s").printf (first_line (e.errors)));
                var sb = new StringBuilder ();
                if (smime) {
                    sb.append ("Content-Type: application/pkcs7-mime; smime-type=enveloped-data; name=\"smime.p7m\"\r\nContent-Transfer-Encoding: base64\r\nContent-Disposition: attachment; filename=\"smime.p7m\"\r\n\r\n");
                    sb.append (Mime.bytes_to_string (e.output).replace ("\r\n", "\n").replace ("\n", "\r\n"));
                } else {
                    string boundary = "=_lettere_encrypted_" + Uuid.string_random ().replace ("-", "");
                    sb.append ("Content-Type: multipart/encrypted; protocol=\"application/pgp-encrypted\"; boundary=\"%s\"\r\n\r\n".printf (boundary));
                    sb.append ("This is an OpenPGP/MIME encrypted message (RFC 4880 and 3156)\r\n");
                    sb.append ("--" + boundary + "\r\nContent-Type: application/pgp-encrypted\r\nContent-Description: PGP/MIME version identification\r\n\r\nVersion: 1\r\n\r\n");
                    sb.append ("--" + boundary + "\r\nContent-Type: application/octet-stream; name=\"encrypted.asc\"\r\nContent-Description: OpenPGP encrypted message\r\nContent-Disposition: inline; filename=\"encrypted.asc\"\r\n\r\n");
                    sb.append (Mime.bytes_to_string (e.output).replace ("\r\n", "\n").replace ("\n", "\r\n"));
                    sb.append ("\r\n--" + boundary + "--\r\n");
                }
                body = sb.str.data;
            }
            return body;
        }

        public async string? autocrypt_header (Account a) {
            if (a.pgp_key == "" || !have ("gpg")) return null;
            try {
                var r = yield run ("gpg", { "--export", "--export-options", "export-minimal", a.pgp_key }, null);
                if (r.output.length == 0) return null;
                string b64 = Base64.encode (r.output);
                var sb = new StringBuilder ("addr=%s; keydata=".printf (a.email));
                for (int i = 0; i < b64.length; i += 72) sb.append ("\r\n " + b64.substring (i, int.min (72, b64.length - i)));
                return sb.str;
            } catch (Error e) {
                return null;
            }
        }
    }
}
