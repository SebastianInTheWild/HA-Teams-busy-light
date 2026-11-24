using System.Collections.Generic;

namespace TeamsBusyLight
{
    /// <summary>
    /// Patterns used to recognize the Teams availability status in the log.
    ///
    /// The new Teams client writes the status in the language of the Teams
    /// app. Every language maps the language-neutral state that is sent to
    /// Home Assistant (left) to one or more patterns found in the log line
    /// (right).
    ///
    /// - Patterns are .NET regular expressions, matched case-insensitive.
    /// - The order of the states matters: the first match wins, so more
    ///   specific states (e.g. "Be right back") come before generic ones
    ///   ("Away").
    /// - To add a language, copy a block, change the key (e.g. "fr") and
    ///   translate the patterns. In "auto" mode all languages are tried,
    ///   English last.
    /// </summary>
    internal static class StatusPatterns
    {
        public static readonly List<KeyValuePair<string, List<KeyValuePair<string, string[]>>>> Languages =
            new List<KeyValuePair<string, List<KeyValuePair<string, string[]>>>>
            {
                Language("de",
                    State("do_not_disturb", "Nicht stören"),
                    State("presenting", "Präsentier", "Präsentation"),
                    State("in_a_meeting", "In einer Besprechung", "In einem Meeting", "Im Meeting"),
                    State("in_a_call", "Am Telefon", "In einem Anruf", "Im Anruf", "Im Gespräch"),
                    State("focusing", "Konzentr", "Fokus"),
                    State("be_right_back", "Bin gleich zurück"),
                    State("away", "Abwesend"),
                    State("busy", "Beschäftigt"),
                    State("available", "Verfügbar"),
                    State("offline", "Offline")),
                Language("en",
                    State("do_not_disturb", "doNotDistrb", "Do not disturb", "DoNotDisturb"),
                    State("presenting", "presenting"),
                    State("in_a_meeting", "inameeting", "In a meeting"),
                    State("in_a_call", "On the phone", "OnThePhone", "In a call"),
                    State("focusing", "focusing"),
                    State("be_right_back", "Be right back", "BeRightBack"),
                    State("away", "away"),
                    State("busy", "busy"),
                    State("available", "available"),
                    State("offline", "offline")),
            };

        static KeyValuePair<string, List<KeyValuePair<string, string[]>>> Language(string code, params KeyValuePair<string, string[]>[] states) =>
            new KeyValuePair<string, List<KeyValuePair<string, string[]>>>(code, new List<KeyValuePair<string, string[]>>(states));

        static KeyValuePair<string, string[]> State(string state, params string[] patterns) =>
            new KeyValuePair<string, string[]>(state, patterns);
    }
}
