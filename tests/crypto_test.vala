using Singularity.Apps.Lettere;

int failures = 0;

void check (bool ok, string what) {
    stdout.printf ("%s - %s\n", ok ? "ok" : "not ok", what);
    if (!ok) failures++;
}

bool sh (string cmd) {
    try {
        int status;
        string o, e;
        Process.spawn_command_line_sync ("sh -c '" + cmd.replace ("'", "'\\''") + "'", out o, out e, out status);
        if (status != 0) stderr.printf ("%s\n%s\n", cmd, e);
        return status == 0;
    } catch (Error e) {
        return false;
    }
}

async void run (string home) {
    var a = new Account ();
    a.email = "alex@lettere.test";
    a.full_name = "Alex Tester";
    a.pgp_key = "alex@lettere.test";
    a.smime_cert = "alex@lettere.test";
    foreach (bool smime in new bool[] { false, true }) {
        string tech = smime ? "S/MIME" : "OpenPGP";
        var b = new MessageBuilder ();
        b.from = a.address ();
        b.to.add (new Address ("Alex Tester", "alex@lettere.test"));
        b.subject = "Secret plan";
        b.text = "Meet at noon.";
        b.html = "<p>Meet at <b>noon</b>.</p>";
        try {
            b.body_override = yield Crypto.protect (b, a, true, false, smime);
            var signed = yield Crypto.open (b.build (), null);
            check (signed.is_signed && signed.ok, "%s: signature verifies (%s)".printf (tech, signed.problem));
            check (signed.message.body_text ().contains ("Meet at noon"), "%s: signed body readable".printf (tech));
            string tampered = Mime.bytes_to_string (b.build ()).replace ("Meet at noon.", "Meet at five.");
            var bad = yield Crypto.open (tampered.data, null);
            check (bad.is_signed && !bad.ok, "%s: tampering is detected".printf (tech));
            b.body_override = null;
            b.body_override = yield Crypto.protect (b, a, true, true, smime);
            string wire = Mime.bytes_to_string (b.build ());
            check (!wire.contains ("Meet at noon"), "%s: body is not readable on the wire".printf (tech));
            var opened = yield Crypto.open (b.build (), null);
            check (opened.encrypted && opened.ok, "%s: decrypted (%s)".printf (tech, opened.problem));
            check (opened.is_signed, "%s: signature inside the encryption verified".printf (tech));
            check (opened.message.text_html.contains ("<b>noon</b>"), "%s: html restored".printf (tech));
        } catch (Error e) {
            check (false, "%s: %s".printf (tech, e.message));
        }
    }
}

int main (string[] args) {
    if (!Crypto.have ("gpg") || !Crypto.have ("gpgsm") || Environment.find_program_in_path ("openssl") == null) {
        stdout.printf ("1..0 # SKIP gpg, gpgsm or openssl missing\n");
        return 0;
    }
    string home = DirUtils.make_tmp ("lettere-gpg-XXXXXX");
    Environment.set_variable ("GNUPGHOME", home, true);
    Environment.set_variable ("XDG_CACHE_HOME", home, true);
    bool ok = sh ("gpg --batch --pinentry-mode loopback --passphrase '' --quick-gen-key 'Alex Tester <alex@lettere.test>' default default never")
        && sh ("cd " + home + " && openssl req -x509 -newkey rsa:2048 -nodes -keyout key.pem -out cert.pem -days 3 -subj '/CN=Alex Tester/emailAddress=alex@lettere.test' -addext 'keyUsage=digitalSignature,keyEncipherment' -addext 'subjectAltName=email:alex@lettere.test' 2>/dev/null")
        && sh ("cd " + home + " && openssl pkcs12 -export -inkey key.pem -in cert.pem -out id.p12 -passout pass: 2>/dev/null")
        && sh ("echo disable-crl-checks > " + home + "/gpgsm.conf && echo allow-loopback-pinentry > " + home + "/gpg-agent.conf")
        && sh ("gpgsm --batch --pinentry-mode loopback --passphrase '' --import " + home + "/id.p12")
        && sh ("gpgsm --with-colons --list-keys alex@lettere.test | awk -F: '/^fpr/ {print $10 \" S relax\"; exit}' >> " + home + "/trustlist.txt && gpgconf --reload gpg-agent");
    if (!ok) {
        stdout.printf ("1..0 # SKIP could not prepare test keys\n");
        return 0;
    }
    var loop = new MainLoop ();
    run.begin (home, (o, r) => {
        run.end (r);
        loop.quit ();
    });
    loop.run ();
    sh ("gpgconf --kill all");
    sh ("rm -rf -- '" + home + "'");
    stdout.printf ("# %s\n", failures == 0 ? "all passed" : "%d failed".printf (failures));
    return failures == 0 ? 0 : 1;
}
