using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;

namespace TeamsBusyLight
{
    /// <summary>Teams status of the current Windows user</summary>
    internal sealed class TeamsState
    {
        public bool Running;
        public bool LogFound;
        /// <summary>Language-neutral status, e.g. "busy"; null when the log has none (yet)</summary>
        public string Status;
        /// <summary>not_in_call, in_call, incoming_call or outgoing_call; null when the log has none</summary>
        public string Activity;
        /// <summary>Language of the status line, e.g. "de"</summary>
        public string Language;
    }

    /// <summary>
    /// Reads the status of the new Teams client from its log: the availability
    /// from the taskbar icon overlay (logged in the language of the app, see
    /// StatusPatterns) and the call state from the call events.
    /// </summary>
    internal static class TeamsMonitor
    {
        const int TailLines = 1000;
        const int TailBytes = 4 * 1024 * 1024;

        static readonly string[] StatusMarkers = { "SetBadge Setting badge:", "SetTaskbarIconOverlay" };
        static readonly string[] ActivityMarkers = { "NotifyCallActive", "NotifyCallAccepted", "NotifyCallEnded", "reportIncomingCall", "RequestNewOutgoingCallWithOptions" };

        public static TeamsState Read(string teamsLanguage)
        {
            var state = new TeamsState();
            using (var teams = FindTeamsProcess())
            {
                if (teams == null)
                {
                    state.Status = "offline";
                    state.Activity = "not_in_call";
                    return state;
                }
            }
            state.Running = true;

            var log = LatestLog();
            if (log == null) return state;
            state.LogFound = true;

            Apply(state, ReadTail(log.FullName), teamsLanguage);
            return state;
        }

        /// <summary>The Teams process of this Windows session, or null</summary>
        public static Process FindTeamsProcess()
        {
            var session = Process.GetCurrentProcess().SessionId;
            Process found = null;
            foreach (var process in Process.GetProcessesByName("ms-teams"))
            {
                if (found == null && process.SessionId == session) found = process;
                else process.Dispose();
            }
            return found;
        }

        static FileInfo LatestLog()
        {
            try
            {
                var folder = new DirectoryInfo(AppPaths.TeamsLogFolder);
                if (!folder.Exists) return null;
                return folder.GetFiles("MSTeams_*.log").OrderByDescending(file => file.LastWriteTimeUtc).FirstOrDefault();
            }
            catch (Exception)
            {
                return null;
            }
        }

        /// <summary>The last lines of a log that Teams keeps writing</summary>
        static IList<string> ReadTail(string path)
        {
            try
            {
                using (var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
                {
                    var start = Math.Max(0, stream.Length - TailBytes);
                    stream.Seek(start, SeekOrigin.Begin);
                    using (var reader = new StreamReader(stream, Encoding.UTF8))
                    {
                        var lines = new List<string>();
                        string line;
                        while ((line = reader.ReadLine()) != null) lines.Add(line);
                        // The first line may start in the middle
                        if (start > 0 && lines.Count > 0) lines.RemoveAt(0);
                        return lines.Count > TailLines ? lines.GetRange(lines.Count - TailLines, TailLines) : lines;
                    }
                }
            }
            catch (Exception)
            {
                return new List<string>();
            }
        }

        /// <summary>Takes status and activity from the last matching lines</summary>
        public static void Apply(TeamsState state, IList<string> lines, string teamsLanguage)
        {
            var statusLine = lines.LastOrDefault(line => ContainsAny(line, StatusMarkers));
            var activityLine = lines.LastOrDefault(line => ContainsAny(line, ActivityMarkers));

            if (statusLine != null)
            {
                var result = StatusFromLine(statusLine, teamsLanguage);
                if (result != null)
                {
                    state.Status = result.Value.Status;
                    state.Language = result.Value.Language;
                }
            }
            if (activityLine != null) state.Activity = ActivityFromLine(activityLine);
        }

        public static string ActivityFromLine(string line)
        {
            if (Contains(line, "reportIncomingCall")) return "incoming_call";
            if (Contains(line, "RequestNewOutgoingCallWithOptions")) return "outgoing_call";
            if (Contains(line, "NotifyCallActive") || Contains(line, "NotifyCallAccepted")) return "in_call";
            return "not_in_call";
        }

        /// <summary>Language-neutral status and language of a status line, or null</summary>
        public static (string Status, string Language)? StatusFromLine(string line, string language)
        {
            IEnumerable<KeyValuePair<string, List<KeyValuePair<string, string[]>>>> languages;
            if (!string.IsNullOrEmpty(language) && language != "auto")
            {
                languages = StatusPatterns.Languages.Where(entry => entry.Key == language);
            }
            else
            {
                // Localized words are checked first, as a localized line may
                // also contain English technical terms
                languages = StatusPatterns.Languages.Where(entry => entry.Key != "en")
                    .Concat(StatusPatterns.Languages.Where(entry => entry.Key == "en"));
            }
            foreach (var table in languages)
            {
                foreach (var state in table.Value)
                {
                    foreach (var pattern in state.Value)
                    {
                        if (Regex.IsMatch(line, pattern, RegexOptions.IgnoreCase | RegexOptions.CultureInvariant))
                            return (state.Key, table.Key);
                    }
                }
            }
            return null;
        }

        static bool Contains(string line, string marker) => line.IndexOf(marker, StringComparison.OrdinalIgnoreCase) >= 0;

        static bool ContainsAny(string line, string[] markers) => markers.Any(marker => Contains(line, marker));
    }
}
