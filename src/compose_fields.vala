using Gtk;

namespace Singularity.Apps.Lettere {

    public class ComposeFields : Object {
        public const string STYLE = """
.lettere-compose-fields {
    border-radius: 14px;
    padding: 6px 14px;
    background-color: alpha(@window_fg_color, 0.04);
}

.lettere-compose-fields entry,
.lettere-compose-fields dropdown > button {
    background: transparent;
    box-shadow: none;
    border: none;
}

.lettere-field-label {
    opacity: 0.6;
    font-weight: 600;
}

.lettere-compose-body,
.lettere-compose-body text {
    background: transparent;
    font-size: 15px;
}

.lettere-compose-card {
    border-radius: 14px;
    background-color: alpha(@window_fg_color, 0.04);
}
""";

        public static Label label (string text) {
            var l = new Label (text);
            l.xalign = 1;
            l.add_css_class ("lettere-field-label");
            return l;
        }

        public static TextView body () {
            var plain = new TextView ();
            plain.wrap_mode = WrapMode.WORD_CHAR;
            plain.top_margin = 14;
            plain.bottom_margin = 14;
            plain.left_margin = 16;
            plain.right_margin = 16;
            plain.add_css_class ("lettere-compose-body");
            plain.update_property (AccessibleProperty.LABEL, _("Message"), -1);
            Singularity.Text.SpellIntegration.attach (plain);
            return plain;
        }
    }
}
