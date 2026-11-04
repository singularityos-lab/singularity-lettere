namespace Singularity.Apps.Lettere {

    internal class LettereIntents : Object {
        private static string text (Json.Object args, string key) {
            return args.has_member (key) ? args.get_string_member (key) : "";
        }

        internal static void install (LettereApp app) {
            app.agent.add_intent ("mail_prepare", "Prepare a message without sending it. The person reads it, edits it if needed and sends it from the card shown with the answer.",
                "{\"type\":\"object\",\"properties\":{\"to\":{\"type\":\"string\"},\"cc\":{\"type\":\"string\"},\"subject\":{\"type\":\"string\"},\"body\":{\"type\":\"string\"},\"account\":{\"type\":\"string\"}},\"required\":[\"to\"]}",
                Singularity.AppIntentRisk.READ, (args) => {
                    if (app.mail_service == null) throw new IOError.NOT_CONNECTED ("mail service unavailable");
                    var a = app.mail_service.sending_account (text (args, "account"));
                    if (a == null) throw new IOError.NOT_FOUND ("no mail account can send messages");
                    var from = a.address ();
                    var b = new Json.Builder ();
                    b.begin_object ();
                    b.set_member_name ("private").begin_object ();
                    b.set_member_name ("token").add_string_value (app.mail_service.prepare (a));
                    b.end_object ();
                    b.set_member_name ("account").add_string_value (a.id);
                    b.set_member_name ("from").add_string_value (from.to_string ());
                    b.set_member_name ("to").add_string_value (text (args, "to"));
                    b.set_member_name ("cc").add_string_value (text (args, "cc"));
                    b.set_member_name ("subject").add_string_value (text (args, "subject"));
                    b.set_member_name ("body").add_string_value (text (args, "body"));
                    b.end_object ();
                    return b.get_root ();
                });
        }
    }
}
