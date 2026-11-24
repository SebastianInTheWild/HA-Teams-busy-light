using System.Collections.Generic;
using System.Text;
using System.Web.Script.Serialization;

namespace TeamsBusyLight
{
    /// <summary>
    /// JSON with the serializer of the .NET Framework (no extra libraries).
    /// Objects become Dictionary&lt;string, object&gt;, arrays object[].
    /// </summary>
    internal static class Json
    {
        static JavaScriptSerializer NewSerializer() => new JavaScriptSerializer { MaxJsonLength = 16 * 1024 * 1024 };

        public static object Parse(string text) => NewSerializer().DeserializeObject(text);

        public static string Serialize(object value) => NewSerializer().Serialize(value);

        /// <summary>A flat object with one value per line, like settings.json of the PowerShell versions</summary>
        public static string SerializeIndented(IEnumerable<KeyValuePair<string, object>> values)
        {
            var serializer = NewSerializer();
            var text = new StringBuilder("{\r\n");
            var first = true;
            foreach (var pair in values)
            {
                if (!first) text.Append(",\r\n");
                first = false;
                text.Append("    ").Append(serializer.Serialize(pair.Key)).Append(": ").Append(serializer.Serialize(pair.Value));
            }
            return text.Append("\r\n}").ToString();
        }

        public static Dictionary<string, object> AsObject(object value) => value as Dictionary<string, object>;

        public static object[] AsArray(object value) => value as object[];

        public static string GetString(Dictionary<string, object> obj, string key) =>
            obj != null && obj.TryGetValue(key, out var value) && value != null ? value.ToString() : null;
    }
}
