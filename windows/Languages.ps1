# Patterns used to recognize the Teams availability status in the logfile.
#
# The new Teams client writes the status in the language of the Teams app.
# Every language below maps the language-neutral state that is sent to Home
# Assistant (left) to one or more patterns found in the log line (right).
#
# - Patterns are .NET regular expressions and are matched case-insensitive.
# - The order of the states matters: the first match wins, so more specific
#   states (e.g. "Be right back") must come before generic ones ("Away").
# - Non-ASCII characters are written as \uXXXX so this file works regardless
#   of the encoding Windows PowerShell 5.1 uses to read it
#   (\u00e4 = ae, \u00f6 = oe, \u00fc = ue, \u00df = ss).
# - To add a language, copy a block, change the key (e.g. "fr") and translate
#   the patterns. In "auto" mode all languages are tried, English last.

$StatusPatterns = [ordered]@{
    "de" = [ordered]@{
        "do_not_disturb" = @('Nicht st\u00f6ren')
        "presenting"     = @('Pr\u00e4sentier', 'Pr\u00e4sentation')
        "in_a_meeting"   = @('In einer Besprechung', 'In einem Meeting', 'Im Meeting')
        "in_a_call"      = @('Am Telefon', 'In einem Anruf', 'Im Anruf', 'Im Gespr\u00e4ch')
        "focusing"       = @('Konzentr', 'Fokus')
        "be_right_back"  = @('Bin gleich zur\u00fcck')
        "away"           = @('Abwesend')
        "busy"           = @('Besch\u00e4ftigt')
        "available"      = @('Verf\u00fcgbar')
        "offline"        = @('Offline')
    }
    "en" = [ordered]@{
        "do_not_disturb" = @('doNotDistrb', 'Do not disturb', 'DoNotDisturb')
        "presenting"     = @('presenting')
        "in_a_meeting"   = @('inameeting', 'In a meeting')
        "in_a_call"      = @('On the phone', 'OnThePhone', 'In a call')
        "focusing"       = @('focusing')
        "be_right_back"  = @('Be right back', 'BeRightBack')
        "away"           = @('away')
        "busy"           = @('busy')
        "available"      = @('available')
        "offline"        = @('offline')
    }
}
