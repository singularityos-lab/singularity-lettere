namespace Singularity.Apps.Lettere {

    public class TestScript : Object {
        private static bool started = false;
        private LettereApp app;
        private string[] lines;
        private int index = 0;

        public static void maybe_run (LettereApp app) {
            string? path = Environment.get_variable ("LETTERE_TEST_SCRIPT");
            if (path == null || started) return;
            started = true;
            string text;
            try {
                FileUtils.get_contents (path, out text);
            } catch (Error e) {
                printerr ("script: %s\n", e.message);
                return;
            }
            var s = new TestScript ();
            s.app = app;
            s.lines = text.split ("\n");
            s.ref ();
            Timeout.add (1500, () => {
                s.step ();
                return Source.REMOVE;
            });
        }

        private void step () {
            while (index < lines.length) {
                string line = lines[index++].strip ();
                if (line == "" || line.has_prefix ("#")) continue;
                uint wait = 600;
                try {
                    wait = run (line);
                } catch (Error e) {
                    printerr ("script: %s failed: %s\n", line, e.message);
                }
                printerr ("script: ok %s\n", line);
                Timeout.add (wait, () => {
                    step ();
                    return Source.REMOVE;
                });
                return;
            }
            printerr ("script: finished\n");
            unref ();
        }

        private Gtk.Window? top () {
            unowned List<Gtk.Window> list = app.get_windows ();
            return list.length () > 0 ? list.nth_data (0) : null;
        }

        private uint run (string line) throws Error {
            string[] a = line.split (" ", 2);
            string arg = a.length > 1 ? a[1] : "";
            var w = app.main_window ();
            switch (a[0]) {
                case "sleep":
                    return (uint) int.parse (arg);
                case "shot": {
                    string dir = Environment.get_variable ("LETTERE_SHOTS") ?? Environment.get_tmp_dir ();
                    Process.spawn_command_line_sync ("grim " + GLib.Shell.quote (Path.build_filename (dir, arg + ".png")));
                    return 300;
                }
                case "action": {
                    if (arg.has_prefix ("app.")) {
                        app.activate_action (arg.substring (4), null);
                        return 1200;
                    }
                    var act = w.lookup_action (arg.has_prefix ("win.") ? arg.substring (4) : arg);
                    if (act == null) printerr ("script: no action %s\n", arg);
                    else if (!act.enabled) printerr ("script: action %s is disabled\n", arg);
                    else act.activate (null);
                    return 1200;
                }
                case "action-string": {
                    string[] p = arg.split (" ", 2);
                    var sa = w.lookup_action (p[0].has_prefix ("win.") ? p[0].substring (4) : p[0]);
                    if (sa != null) sa.activate (new Variant.string (p.length > 1 ? p[1] : ""));
                    return 1200;
                }
                case "top-action":
                    var t = top ();
                    if (t != null) t.activate_action (arg, null);
                    return 1200;
                case "respond": {
                    var open = new Gee.ArrayList<Gtk.Window> ();
                    foreach (var win in app.get_windows ()) open.add (win);
                    foreach (var win in open) {
                        var d = win as Singularity.Widgets.ConfirmDialog;
                        if (d != null) d.response (arg == "primary" ? Singularity.Widgets.ConfirmDialog.Response.PRIMARY : Singularity.Widgets.ConfirmDialog.Response.CANCEL);
                    }
                    return 1200;
                }
                case "setting": {
                    string[] p = arg.split (" ", 2);
                    var v = app.settings.get_value (p[0]);
                    if (v.is_of_type (VariantType.BOOLEAN)) app.settings.set_boolean (p[0], p[1] == "true");
                    else if (v.is_of_type (VariantType.INT32)) app.settings.set_int (p[0], int.parse (p[1]));
                    else if (v.is_of_type (VariantType.STRING_ARRAY)) app.settings.set_strv (p[0], p[1].split ("|"));
                    else app.settings.set_string (p[0], p[1]);
                    return 1000;
                }
                default:
                    w.script (a[0], arg);
                    return 1500;
            }
        }
    }
}
