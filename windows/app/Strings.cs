using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Text;

namespace TeamsBusyLight
{
    /// <summary>
    /// UI texts from Translations\&lt;language&gt;.json (embedded), in the
    /// language of Windows; English when there is no translation.
    /// </summary>
    internal static class Strings
    {
        static Dictionary<string, object> table = new Dictionary<string, object>();
        static Dictionary<string, object> english = new Dictionary<string, object>();

        public static void Load(string language = null)
        {
            english = Read("en") ?? new Dictionary<string, object>();
            var code = string.IsNullOrWhiteSpace(language) ? CultureInfo.CurrentUICulture.TwoLetterISOLanguageName : language;
            code = code.ToLowerInvariant().Split('-')[0];
            table = Read(code) ?? english;
        }

        static Dictionary<string, object> Read(string code)
        {
            using (var stream = typeof(Strings).Assembly.GetManifestResourceStream("Translations." + code + ".json"))
            {
                if (stream == null) return null;
                using (var reader = new StreamReader(stream, Encoding.UTF8))
                {
                    return Json.AsObject(Json.Parse(reader.ReadToEnd()));
                }
            }
        }

        public static string Get(string key) =>
            Json.GetString(table, key) ?? Json.GetString(english, key) ?? key;

        public static string Format(string key, params object[] args)
        {
            try
            {
                return string.Format(CultureInfo.CurrentCulture, Get(key), args);
            }
            catch (FormatException)
            {
                return Get(key);
            }
        }

        static string Nested(string group, string key) =>
            Json.GetString(Json.AsObject(table.TryGetValue(group, out var value) ? value : null), key)
            ?? Json.GetString(Json.AsObject(english.TryGetValue(group, out var fallback) ? fallback : null), key)
            ?? key;

        /// <summary>Name of a status, e.g. "busy" -> "Busy"; null -> "Unknown"</summary>
        public static string Status(string key) => Nested("StatusNames", key ?? "unknown");

        /// <summary>Name of a call activity, e.g. "in_call" -> "In a call"</summary>
        public static string Activity(string key) => Nested("ActivityNames", key ?? "not_in_call");
    }
}
