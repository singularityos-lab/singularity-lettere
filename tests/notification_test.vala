using Singularity.Apps.Lettere;

[DBus (name = "org.freedesktop.Notifications")]
class NotificationServer : Object {
    public signal void action_invoked (uint id, string action);
    public signal void notification_closed (uint id, uint reason);
    [DBus (visible = false)]
    public bool silent;
    [DBus (visible = false)]
    public bool markup;
    [DBus (visible = false)]
    public string body;
    [DBus (visible = false)]
    public uint replacement;
    private uint next = 1;

    public string[] get_capabilities () throws Error {
        return markup ? new string[] { "body", "body-markup", "sound", "actions" } : new string[] { "body", "sound", "actions" };
    }

    public uint notify (string app, uint replaces, string icon, string title, string body, string[] actions, HashTable<string, Variant> hints, int timeout) throws Error {
        assert (app == "Lettere" && icon == "dev.sinty.lettere");
        assert (actions.length == 2 && actions[0] == "default");
        assert (hints["sound-name"].get_string () == "message");
        assert (hints["desktop-entry"].get_string () == "dev.sinty.lettere");
        assert (hints["category"].get_string () == "email.arrived");
        silent = hints["suppress-sound"].get_boolean ();
        this.body = body;
        replacement = replaces;
        return replaces > 0 ? replaces : next++;
    }
}

void drain () {
    var loop = new MainLoop ();
    Timeout.add (100, () => { loop.quit (); return Source.REMOVE; });
    loop.run ();
}

void deliver_notification (MailNotifications notifications, string account, int64 id) {
    var loop = new MainLoop ();
    uint timeout = Timeout.add_seconds (5, () => { assert_not_reached (); });
    notifications.send.begin (account, "Sender & Co", "Plan <draft> & review", id, (obj, result) => {
        notifications.send.end (result);
        loop.quit ();
    });
    loop.run ();
    Source.remove (timeout);
}

int main (string[] args) {
    Test.init (ref args);
    try {
        string schema_dir = DirUtils.make_tmp ("lettere-notifications-XXXXXX");
        string[] compile = { "glib-compile-schemas", "--strict", "--targetdir=" + schema_dir, args[1] };
        int status;
        Process.spawn_sync (null, compile, null, SpawnFlags.SEARCH_PATH, null, null, null, out status);
        Process.check_wait_status (status);
        var source = new SettingsSchemaSource.from_directory (schema_dir, SettingsSchemaSource.get_default (), false);
        var settings = new GLib.Settings.full (source.lookup ("dev.sinty.lettere", false), null, null);
        assert (settings.get_boolean ("notification-sound"));
        assert (settings.get_boolean ("startup-summary"));
        var bus = Bus.get_sync (BusType.SESSION);
        var server = new NotificationServer ();
        bus.register_object ("/org/freedesktop/Notifications", server);
        var reply = bus.call_sync ("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "RequestName",
            new Variant ("(su)", "org.freedesktop.Notifications", 0u), new VariantType ("(u)"), DBusCallFlags.NONE, 1000, null);
        assert (reply.get_child_value (0).get_uint32 () == 1);
        var app = new GLib.Application ("dev.sinty.lettere.tests", ApplicationFlags.NON_UNIQUE);
        app.register ();
        int64 opened = -1;
        var message = new SimpleAction ("show-message", VariantType.INT64);
        message.activate.connect ((v) => opened = v.get_int64 ());
        app.add_action (message);
        var inbox = new SimpleAction ("show-inbox", null);
        inbox.activate.connect (() => opened = 0);
        app.add_action (inbox);
        var notifications = new MailNotifications (app, settings);

        deliver_notification (notifications, "work", 42);
        assert (!server.silent && server.body == "Plan <draft> & review" && server.replacement == 0);
        server.action_invoked (1, "default");
        drain ();
        assert (opened == 42);
        settings.set_boolean ("notification-sound", false);
        deliver_notification (notifications, "work", 0);
        assert (server.silent && server.replacement == 1);
        server.action_invoked (1, "default");
        drain ();
        assert (opened == 0);
        server.notification_closed (1, 2);
        drain ();
        settings.set_boolean ("notification-sound", true);
        deliver_notification (notifications, "work", 43);
        assert (!server.silent && server.replacement == 0);
        server.action_invoked (1, "default");
        drain ();
        assert (opened == 0);
        notifications.stop ();
        server.markup = true;
        notifications = new MailNotifications (app, settings);
        deliver_notification (notifications, "personal", 99);
        assert (server.body == "Plan &lt;draft&gt; &amp; review");
        bus.call_sync ("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "ReleaseName",
            new Variant ("(s)", "org.freedesktop.Notifications"), null, DBusCallFlags.NONE, 1000, null);
        drain ();
        bus.call_sync ("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "RequestName",
            new Variant ("(su)", "org.freedesktop.Notifications", 0u), null, DBusCallFlags.NONE, 1000, null);
        drain ();
        server.markup = false;
        deliver_notification (notifications, "personal", 100);
        assert (server.replacement == 0 && server.body == "Plan <draft> & review");
        notifications.stop ();
        stdout.printf ("notification defaults, sound toggle, actions, replacement, close, markup and server restart: passed\n");
        bus.close_sync ();
        FileUtils.remove (Path.build_filename (schema_dir, "gschemas.compiled"));
        DirUtils.remove (schema_dir);
    } catch (Error e) {
        error (e.message);
    }
    return 0;
}
