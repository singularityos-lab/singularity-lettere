using Gtk;
using Singularity.Widgets;

namespace Singularity.Apps.Lettere {

    [DBus (name = "dev.sinty.Lettere.Mail.Error")]
    public errordomain MailServiceError {
        DENIED,
        NO_ACCOUNT,
        INVALID
    }

    public struct MessageState {
        public int64 id;
        public string state;
        public string error;
    }

    [DBus (name = "dev.sinty.Lettere.Mail")]
    public class MailService : Object {
        private const int MAX_MESSAGES = 1000;
        private const int MAX_SIZE = 50 * 1024 * 1024;

        public signal void message_sent (int64 id);
        public signal void message_failed (int64 id, string error);

        private LettereApp app;
        private uint registration;
        private DBusConnection? connection;
        private string path = "";
        private Gee.HashMap<int64?, string> owners = new Gee.HashMap<int64?, string> ((v) => int64_hash (v), (a, b) => a == b);
        private Gee.HashSet<int64?> sent = new Gee.HashSet<int64?> ((v) => int64_hash (v), (a, b) => a == b);

        [DBus (visible = false)]
        public MailService (LettereApp app) {
            this.app = app;
            app.outbox_result.connect (on_result);
        }

        [DBus (visible = false)]
        public void register (DBusConnection c, string object_path) throws IOError {
            connection = c;
            path = object_path;
            registration = c.register_object (object_path, this);
        }

        [DBus (visible = false)]
        public void unregister (DBusConnection c) {
            if (registration != 0) c.unregister_object (registration);
            registration = 0;
            connection = null;
        }

        public HashTable<string, Variant>[] accounts () throws DBusError, IOError {
            HashTable<string, Variant>[] list = {};
            foreach (var a in sending_accounts ()) {
                var d = new HashTable<string, Variant> (str_hash, str_equal);
                d["id"] = new Variant.string (a.id);
                d["name"] = new Variant.string (a.display_name);
                d["address"] = new Variant.string (a.email);
                d["full-name"] = new Variant.string (a.full_name);
                list += d;
            }
            return list;
        }

        public async int64[] queue_messages (string account, [DBus (signature = "aay")] Variant messages, [DBus (signature = "a{sv}")] Variant options, BusName sender) throws MailServiceError, DBusError, IOError {
            var list = new Gee.ArrayList<Bytes> ();
            for (size_t i = 0; i < messages.n_children (); i++) list.add (messages.get_child_value (i).get_data_as_bytes ());
            return yield queue (sender, account, list, options);
        }

        public async int64[] queue_files (string account, string[] paths, [DBus (signature = "a{sv}")] Variant options, BusName sender) throws MailServiceError, DBusError, IOError {
            var list = new Gee.ArrayList<Bytes> ();
            foreach (string p in paths) {
                try {
                    uint8[] data;
                    FileUtils.get_data (p, out data);
                    list.add (new Bytes (data));
                } catch (Error e) {
                    throw new MailServiceError.INVALID ("%s: %s", p, e.message);
                }
            }
            return yield queue (sender, account, list, options);
        }

        public MessageState[] status (int64[] ids, BusName sender) throws DBusError, IOError {
            var queued = new Gee.HashMap<int64?, OutboxItem> ((v) => int64_hash (v), (a, b) => a == b);
            foreach (var o in app.store.outbox ()) queued[o.id] = o;
            MessageState[] result = {};
            foreach (var id in ids) {
                var st = MessageState () { id = id, state = "unknown", error = "" };
                if (owners[id] == (string) sender) {
                    var o = queued[id];
                    if (o != null) {
                        st.error = o.error;
                        st.state = app.is_sending (id) ? "sending" : (o.error != "" ? "retrying" : "queued");
                    } else if (sent.contains (id)) {
                        st.state = "sent";
                    }
                }
                result += st;
            }
            return result;
        }

        public int64[] cancel (int64[] ids, BusName sender) throws DBusError, IOError {
            int64[] done = {};
            foreach (var id in ids) {
                if (owners[id] != (string) sender) continue;
                if (app.cancel_outbox (id)) {
                    owners.unset (id);
                    done += id;
                }
            }
            return done;
        }

        private Gee.ArrayList<Account> sending_accounts () {
            var list = new Gee.ArrayList<Account> ();
            foreach (var a in app.accounts.accounts) {
                var s = app.syncs[a.id];
                if (s == null || s.backend.local_only) continue;
                list.add (a);
            }
            return list;
        }

        private void on_result (int64 id, string error) {
            string? owner = owners[id];
            if (owner == null || connection == null) return;
            if (error == "") sent.add (id);
            try {
                if (error == "") connection.emit_signal (owner, path, "dev.sinty.Lettere.Mail", "MessageSent", new Variant ("(x)", id));
                else connection.emit_signal (owner, path, "dev.sinty.Lettere.Mail", "MessageFailed", new Variant ("(xs)", id, error));
            } catch (Error e) {
            }
        }

        private Account? find_account (string hint, Gee.List<Account> list) {
            foreach (var a in list) {
                if (a.id == hint || a.email.down () == hint.down ()) return a;
            }
            return null;
        }

        private async int64[] queue (string sender, string hint, Gee.List<Bytes> messages, Variant options) throws MailServiceError {
            if (messages.size == 0 || messages.size > MAX_MESSAGES) throw new MailServiceError.INVALID ("Between 1 and %d messages are accepted", MAX_MESSAGES);
            var outgoing = new Gee.ArrayList<Outgoing> ();
            foreach (var data in messages) {
                if (data.get_size () > MAX_SIZE) throw new MailServiceError.INVALID ("A message is larger than 50 MB");
                var o = new Outgoing (Outgoing.normalize (data.get_data ()));
                if (o.recipients.size == 0) throw new MailServiceError.INVALID ("A message has no recipients");
                outgoing.add (o);
            }
            var accounts = sending_accounts ();
            if (accounts.size == 0) throw new MailServiceError.NO_ACCOUNT ("No mail account can send messages");
            string app_name = "";
            int64 send_at = 0;
            int interval = 0;
            if (options.is_of_type (new VariantType ("a{sv}"))) {
                var it = options.iterator ();
                string key;
                Variant val;
                while (it.next ("{sv}", out key, out val)) {
                    if (key == "app-name" && val.is_of_type (VariantType.STRING)) app_name = val.get_string ();
                    else if (key == "send-at" && val.is_of_type (VariantType.INT64)) send_at = val.get_int64 ();
                    else if (key == "interval" && val.is_of_type (VariantType.UINT32)) interval = (int) uint.min (val.get_uint32 (), 3600);
                }
            }
            var preferred = find_account (hint, accounts) ?? accounts[0];
            app.hold ();
            var chosen = yield confirm (app_name, outgoing, accounts, preferred);
            app.release ();
            if (chosen == null) throw new MailServiceError.DENIED ("The person did not allow sending");
            int64[] ids = {};
            int64 base_time = send_at > 0 ? send_at : (interval > 0 ? new DateTime.now_utc ().to_unix () : 0);
            for (int i = 0; i < outgoing.size; i++) {
                var o = outgoing[i];
                var from = o.pick_from (chosen);
                uint8[] raw = o.with_from (from);
                int64 at = base_time > 0 ? base_time + (int64) i * interval : 0;
                int64 id = app.queue_raw (chosen, raw, o.recipients, from.email, o.subject, null, at);
                owners[id] = sender;
                ids += id;
            }
            return ids;
        }

        private async Account? confirm (string app_name, Gee.List<Outgoing> outgoing, Gee.List<Account> accounts, Account preferred) {
            int count = outgoing.size;
            string who = app_name.strip () != "" ? app_name.strip () : _("An app");
            var first = new Gee.ArrayList<string> ();
            int total = 0;
            foreach (var o in outgoing) {
                foreach (string r in o.recipients) {
                    if (first.size < 3) first.add (r);
                    total++;
                }
            }
            string people = string.joinv (", ", first.to_array ());
            if (total > first.size) people += " " + ngettext ("and %d more", "and %d more", total - first.size).printf (total - first.size);
            var dialog = new ConfirmDialog (app,
                ngettext ("Send %d Message?", "Send %d Messages?", count).printf (count),
                "mail-send-symbolic",
                _("%s wants to send mail for you to %s. Lettere sends it from the account below and keeps a copy in Sent.").printf (who, people),
                ngettext ("Send", "Send All", count),
                ConfirmDialog.ActionStyle.SUGGESTED);
            dialog.modal = true;
            string[] labels = {};
            foreach (var a in accounts) labels += a.display_name;
            var chosen = preferred;
            var group = new PreferencesGroup ();
            var row = new SelectionRow (_("Send From"), labels, preferred.display_name);
            row.selected.connect ((v) => {
                row.current_value = v;
                row.expanded = false;
                foreach (var a in accounts) if (a.display_name == v) chosen = a;
            });
            group.add_row (row);
            dialog.custom_area.append (group);
            bool allowed = false;
            bool done = false;
            dialog.response.connect ((r) => {
                allowed = r == ConfirmDialog.Response.PRIMARY;
                if (!done) {
                    done = true;
                    Idle.add (confirm.callback);
                }
            });
            dialog.close_request.connect (() => {
                if (!done) {
                    done = true;
                    Idle.add (confirm.callback);
                }
                return false;
            });
            dialog.present ();
            yield;
            dialog.close ();
            return allowed ? chosen : null;
        }
    }

}
