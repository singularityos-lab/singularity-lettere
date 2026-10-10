namespace Singularity.Apps.Lettere {

    public class MailNotifications : Object {
        private unowned GLib.Application app;
        private GLib.Settings settings;
        private DBusConnection? bus;
        private uint subscription;
        private uint owner_subscription;
        private bool body_markup;
        private bool capabilities_loaded;
        private Gee.HashMap<string, uint> accounts = new Gee.HashMap<string, uint> ();
        private Gee.HashMap<uint, int64?> messages = new Gee.HashMap<uint, int64?> ();
        private Gst.Element? sound;
        private uint sound_timer;
        private uint sound_watch;

        public MailNotifications (GLib.Application app, GLib.Settings settings) {
            this.app = app;
            this.settings = settings;
        }

        public async void send (string account, string title, string body, int64 message) {
            try {
                var connection = yield Bus.get (BusType.SESSION);
                if (bus == null) {
                    bus = connection;
                    subscription = bus.signal_subscribe ("org.freedesktop.Notifications", "org.freedesktop.Notifications",
                        null, "/org/freedesktop/Notifications", null, DBusSignalFlags.NONE, on_signal);
                    owner_subscription = bus.signal_subscribe ("org.freedesktop.DBus", "org.freedesktop.DBus",
                        "NameOwnerChanged", "/org/freedesktop/DBus", "org.freedesktop.Notifications", DBusSignalFlags.NONE,
                        () => {
                            accounts.clear ();
                            messages.clear ();
                            capabilities_loaded = false;
                        });
                }
                if (!capabilities_loaded) {
                    var capabilities = yield bus.call ("org.freedesktop.Notifications", "/org/freedesktop/Notifications",
                        "org.freedesktop.Notifications", "GetCapabilities", null, new VariantType ("(as)"),
                        DBusCallFlags.NONE, 5000, null);
                    body_markup = "body-markup" in capabilities.get_child_value (0).dup_strv ();
                    capabilities_loaded = true;
                }
                var hints = new VariantBuilder (new VariantType ("a{sv}"));
                hints.add ("{sv}", "desktop-entry", new Variant.string ("dev.sinty.lettere"));
                hints.add ("{sv}", "category", new Variant.string ("email.arrived"));
                hints.add ("{sv}", "sound-name", new Variant.string ("message"));
                string? file = sound_file ();
                if (file != null) hints.add ("{sv}", "sound-file", new Variant.string (file));
                hints.add ("{sv}", "suppress-sound", new Variant.boolean (!settings.get_boolean ("notification-sound")));
                uint previous = accounts.has_key (account) ? accounts[account] : 0;
                var reply = yield bus.call ("org.freedesktop.Notifications", "/org/freedesktop/Notifications",
                    "org.freedesktop.Notifications", "Notify",
                    new Variant ("(susss^as@a{sv}i)", "Lettere", previous, "dev.sinty.lettere", title,
                        body_markup ? Markup.escape_text (body) : body, new string[] { "default", _("Open") }, hints.end (), -1),
                    new VariantType ("(u)"), DBusCallFlags.NONE, 5000, null);
                uint id = reply.get_child_value (0).get_uint32 ();
                accounts[account] = id;
                messages[id] = message;
            } catch (Error e) {
                warning ("lettere: notification: %s", e.message);
            }
        }

        private void on_signal (DBusConnection connection, string? sender, string path, string iface, string name, Variant args) {
            if (name != "ActionInvoked" && name != "NotificationClosed") return;
            uint id = args.get_child_value (0).get_uint32 ();
            if (!messages.has_key (id)) return;
            if (name == "ActionInvoked" && args.get_child_value (1).get_string () == "default") {
                int64 message = messages[id];
                if (message > 0) app.activate_action ("show-message", new Variant.int64 (message));
                else app.activate_action ("show-inbox", null);
            } else if (name == "NotificationClosed") {
                messages.unset (id);
                foreach (string account in accounts.keys.to_array ()) {
                    if (accounts[account] == id) accounts.unset (account);
                }
            }
        }

        public void play_summary_sound () {
            if (sound_timer != 0 || sound != null) return;
            sound_timer = Timeout.add (200, () => {
                sound_timer = 0;
                if (!settings.get_boolean ("notification-sound") || !summary_sound_allowed ()) return Source.REMOVE;
                string? file = sound_file ();
                if (file == null) return Source.REMOVE;
                unowned string[]? args = null;
                Gst.init (ref args);
                try {
                    var player = Gst.parse_launch ("playbin");
                    player.set ("uri", File.new_for_path (file).get_uri ());
                    sound = player;
                    sound_watch = player.get_bus ().add_watch (Priority.DEFAULT, (bus, message) => {
                        if (message.type != Gst.MessageType.EOS && message.type != Gst.MessageType.ERROR) return Source.CONTINUE;
                        player.set_state (Gst.State.NULL);
                        if (sound == player) sound = null;
                        sound_watch = 0;
                        return Source.REMOVE;
                    });
                    if (player.set_state (Gst.State.PLAYING) == Gst.StateChangeReturn.FAILURE) {
                        player.set_state (Gst.State.NULL);
                        sound = null;
                        Source.remove (sound_watch);
                        sound_watch = 0;
                    }
                } catch (Error e) {
                    debug ("lettere: summary sound: %s", e.message);
                }
                return Source.REMOVE;
            });
        }

        private bool summary_sound_allowed () {
            if (Singularity.FocusStatus.get_default ().active) return false;
            var source = SettingsSchemaSource.get_default ();
            if (source == null) return true;
            if (source.lookup ("dev.sinty.desktop", true) != null
                    && new GLib.Settings ("dev.sinty.desktop").get_boolean ("do-not-disturb")) return false;
            if (source.lookup ("dev.sinty.desktop.notifications", true) != null
                    && !new GLib.Settings ("dev.sinty.desktop.notifications").get_boolean ("sounds-enabled")) return false;
            if (source.lookup ("dev.sinty.desktop.notifications.application", true) != null) {
                var policy = new GLib.Settings.with_path ("dev.sinty.desktop.notifications.application",
                    "/dev/sinty/desktop/notifications/application/dev-sinty-lettere/");
                if (!policy.get_boolean ("enabled") || !policy.get_boolean ("sounds")) return false;
            }
            return true;
        }

        private static string? sound_file () {
            string[] themes = { "freedesktop" };
            var gtk = Gtk.Settings.get_default ();
            if (gtk != null && gtk.gtk_sound_theme_name != null && gtk.gtk_sound_theme_name != "") {
                themes = { gtk.gtk_sound_theme_name, "freedesktop" };
            }
            string[] dirs = { Environment.get_user_data_dir () };
            foreach (string dir in Environment.get_system_data_dirs ()) dirs += dir;
            foreach (string theme in themes) {
                foreach (string name in new string[] { "message", "message-new-instant" }) {
                    foreach (string dir in dirs) {
                        foreach (string extension in new string[] { ".oga", ".ogg", ".wav" }) {
                            string path = Path.build_filename (dir, "sounds", theme, "stereo", name + extension);
                            if (FileUtils.test (path, FileTest.IS_REGULAR)) return path;
                        }
                    }
                }
            }
            return null;
        }

        public void stop () {
            if (bus != null && subscription != 0) bus.signal_unsubscribe (subscription);
            if (bus != null && owner_subscription != 0) bus.signal_unsubscribe (owner_subscription);
            subscription = 0;
            owner_subscription = 0;
            bus = null;
            capabilities_loaded = false;
            if (sound_timer != 0) Source.remove (sound_timer);
            sound_timer = 0;
            if (sound_watch != 0) Source.remove (sound_watch);
            sound_watch = 0;
            if (sound != null) sound.set_state (Gst.State.NULL);
            sound = null;
        }

        ~MailNotifications () {
            stop ();
        }
    }
}
