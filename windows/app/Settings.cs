using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text;

namespace TeamsBusyLight
{
    /// <summary>
    /// Settings in settings.json (same names and limits as the PowerShell
    /// versions, so their settings are kept).
    /// </summary>
    internal sealed class Settings
    {
        public string WebhookUrl = "";
        public int HeartbeatSeconds = 60;
        public int PollSeconds = 2;
        public string TeamsLanguage = "auto";
        public bool CheckForUpdates = true;
        public bool PreReleases;
        public string HomeNetworks = "";
        public bool AskForNewNetworks = true;
        public string IgnoredNetworks = "";
        public bool DetectOtherCalls = true;

        static readonly Encoding Utf8NoBom = new UTF8Encoding(false);
        public static readonly string[] TeamsLanguages = { "auto", "de", "en" };

        public Settings Clone() => (Settings)MemberwiseClone();

        public static Settings Load()
        {
            if (!File.Exists(AppPaths.SettingsPath)) return new Settings();
            try
            {
                return Parse(File.ReadAllText(AppPaths.SettingsPath, Encoding.UTF8));
            }
            catch (Exception exception)
            {
                Log.Write($"Cannot read {AppPaths.SettingsPath}: {exception.Message}");
                return new Settings();
            }
        }

        /// <summary>Reads settings.json; missing or invalid values get their default</summary>
        public static Settings Parse(string json)
        {
            var result = new Settings();
            var saved = Json.AsObject(Json.Parse(json)) ?? new Dictionary<string, object>();
            string Text(string key, string fallback) => saved.TryGetValue(key, out var value) && value != null ? value.ToString() : fallback;
            bool Flag(string key, bool fallback) => saved.TryGetValue(key, out var value) && value is bool flag ? flag : fallback;
            int Number(string key, int fallback, int min, int max)
            {
                var number = fallback;
                if (saved.TryGetValue(key, out var value) && value != null)
                {
                    try { number = Convert.ToInt32(value, CultureInfo.InvariantCulture); }
                    catch (Exception) { number = fallback; }
                }
                return Math.Min(Math.Max(number, min), max);
            }

            result.WebhookUrl = Text("WebhookUrl", "").Trim();
            result.HeartbeatSeconds = Number("HeartbeatSeconds", 60, 10, 3600);
            result.PollSeconds = Number("PollSeconds", 2, 1, 60);
            result.TeamsLanguage = Text("TeamsLanguage", "auto");
            if (!TeamsLanguages.Contains(result.TeamsLanguage)) result.TeamsLanguage = "auto";
            result.CheckForUpdates = Flag("CheckForUpdates", true);
            result.PreReleases = Flag("PreReleases", false);
            result.HomeNetworks = Text("HomeNetworks", "").Trim();
            result.AskForNewNetworks = Flag("AskForNewNetworks", true);
            result.IgnoredNetworks = Text("IgnoredNetworks", "").Trim();
            result.DetectOtherCalls = Flag("DetectOtherCalls", true);
            return result;
        }

        public string ToJson() => Json.SerializeIndented(new[]
        {
            new KeyValuePair<string, object>("WebhookUrl", WebhookUrl),
            new KeyValuePair<string, object>("HeartbeatSeconds", HeartbeatSeconds),
            new KeyValuePair<string, object>("PollSeconds", PollSeconds),
            new KeyValuePair<string, object>("TeamsLanguage", TeamsLanguage),
            new KeyValuePair<string, object>("CheckForUpdates", CheckForUpdates),
            new KeyValuePair<string, object>("PreReleases", PreReleases),
            new KeyValuePair<string, object>("HomeNetworks", HomeNetworks),
            new KeyValuePair<string, object>("AskForNewNetworks", AskForNewNetworks),
            new KeyValuePair<string, object>("IgnoredNetworks", IgnoredNetworks),
            new KeyValuePair<string, object>("DetectOtherCalls", DetectOtherCalls),
        });

        public void Save()
        {
            AppPaths.EnsureDataDir();
            File.WriteAllText(AppPaths.SettingsPath, ToJson(), Utf8NoBom);
        }

        /// <summary>A HTTP(S) URL ending with /api/webhook/&lt;id&gt;</summary>
        public static bool IsValidWebhookUrl(string url)
        {
            if (string.IsNullOrEmpty(url) || !System.Text.RegularExpressions.Regex.IsMatch(url, "/api/webhook/[^/]+$")) return false;
            return Uri.TryCreate(url, UriKind.Absolute, out var uri) && (uri.Scheme == "http" || uri.Scheme == "https");
        }

        // --- Pause and manual status, kept over restarts ------------------------

        /// <summary>
        /// Sending paused from the tray menu: the end as UTC timestamp in
        /// pause.txt, DateTime.MaxValue = until resumed, null = not paused
        /// </summary>
        public static DateTime? LoadPause() =>
            File.Exists(AppPaths.PausePath) ? ParseEnd(File.ReadAllText(AppPaths.PausePath).Trim()) : null;

        public static void SavePause(DateTime? until)
        {
            if (until == null)
            {
                File.Delete(AppPaths.PausePath);
                return;
            }
            AppPaths.EnsureDataDir();
            File.WriteAllText(AppPaths.PausePath, FormatEnd(until.Value), Utf8NoBom);
        }

        /// <summary>Status set from the tray menu instead of the Teams status: "&lt;status&gt; &lt;end&gt;" in manual-status.txt</summary>
        public static ManualStatus LoadManualStatus() =>
            File.Exists(AppPaths.ManualStatusPath) ? ManualStatus.Parse(File.ReadAllText(AppPaths.ManualStatusPath)) : null;

        public static void SaveManualStatus(ManualStatus manual)
        {
            if (manual == null)
            {
                File.Delete(AppPaths.ManualStatusPath);
                return;
            }
            AppPaths.EnsureDataDir();
            File.WriteAllText(AppPaths.ManualStatusPath, manual.Status + " " + FormatEnd(manual.Until), Utf8NoBom);
        }

        /// <summary>"always" or a UTC round-trip timestamp, as local time</summary>
        public static DateTime? ParseEnd(string text)
        {
            if (text == "always") return DateTime.MaxValue;
            if (DateTime.TryParse(text, CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind, out var until))
                return until.ToLocalTime();
            return null;
        }

        public static string FormatEnd(DateTime until) =>
            until == DateTime.MaxValue ? "always" : until.ToUniversalTime().ToString("o", CultureInfo.InvariantCulture);
    }

    internal sealed class ManualStatus
    {
        /// <summary>Statuses offered under "Set status" in the tray menu</summary>
        public static readonly string[] Statuses = { "available", "busy", "do_not_disturb", "be_right_back", "away" };

        public string Status;
        public DateTime Until;

        public bool IsActive => DateTime.Now < Until;

        public static ManualStatus Parse(string text)
        {
            var parts = text.Trim().Split(new[] { ' ', '\t', '\r', '\n' }, 2, StringSplitOptions.RemoveEmptyEntries);
            if (parts.Length != 2 || !Statuses.Contains(parts[0])) return null;
            var until = Settings.ParseEnd(parts[1].Trim());
            return until == null ? null : new ManualStatus { Status = parts[0], Until = until.Value };
        }
    }
}
