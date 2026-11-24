using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;

namespace TeamsBusyLight
{
    /// <summary>Text for "Copy diagnostics" in the settings window, without the webhook ID</summary>
    internal static class Diagnostics
    {
        public static string Text(TrayApp app)
        {
            var state = app.TakeSnapshot();
            var config = state.Config;
            string YesNo(bool value) => value ? "yes" : "no";

            var webhook = "(not set)";
            if (!string.IsNullOrEmpty(config.WebhookUrl))
            {
                webhook = Uri.TryCreate(config.WebhookUrl, UriKind.Absolute, out var uri)
                    ? $"{uri.Scheme}://{uri.Authority}/api/webhook/<hidden>"
                    : "(invalid)";
            }
            var manual = state.Manual == null ? "no"
                : state.Manual.Status + (state.Manual.Until == DateTime.MaxValue ? " (until reset)" : " until " + state.Manual.Until.ToString("s"));
            var pause = state.PausedUntil == null ? "no"
                : state.PausedUntil == DateTime.MaxValue ? "until resumed" : "until " + state.PausedUntil.Value.ToString("s");
            string teams;
            using (var process = TeamsMonitor.FindTeamsProcess())
            {
                teams = process == null ? "no" : "yes, version " + SafeFileVersion(process);
            }
            var devices = state.Devices;
            var camera = devices.Camera == null ? "unknown (not reported by this Windows version)"
                : devices.Camera == true ? "yes" + (devices.CameraApps.Length > 0 ? ", by " + string.Join(", ", devices.CameraApps) : "")
                : "no";
            var microphone = devices.Microphone == null ? "unknown"
                : devices.Microphone == true ? "in use by " + string.Join(", ", devices.MicrophoneApps)
                : "not in use";

            var lines = new List<string>
            {
                $"Teams Busy Light {AppPaths.Version} (Windows tray app)",
                $"Windows:          {Environment.OSVersion.Version}, {System.Runtime.InteropServices.RuntimeInformation.FrameworkDescription},{System.Globalization.CultureInfo.CurrentUICulture.Name}",
                $"Signature pin:    {(AppPaths.SigningCertificateSha256.Length > 0 ? "set (in-app updates)" : "none")}",
                $"Update channel:   {(config.PreReleases ? "beta (pre-releases)" : "release")}",
                $"Update available: {state.UpdateVersion ?? "no"}",
                "",
                $"Teams running:    {teams}",
                $"Teams log:        {(state.LogMissing ? "MISSING in " + AppPaths.TeamsLogFolder : "ok")}",
                $"Teams language:   {state.Language ?? "-"} (setting {config.TeamsLanguage})",
                $"Teams status:     {state.Status ?? "-"}",
                $"Teams activity:   {state.TeamsActivity}",
                $"Manual status:    {manual}",
                $"Camera in use:    {camera} (from {devices.CameraSource})",
                $"Microphone:       {microphone} (from {devices.MicrophoneSource})",
                $"Other calls:      {(config.DetectOtherCalls ? "on" : "off")}",
                $"Effective:        status {state.EffectiveStatus}, activity {state.Activity}",
                "",
                $"Webhook:          {webhook}",
                $"Home networks:    {(config.HomeNetworks.Length > 0 ? config.HomeNetworks : "(everywhere)")}",
                $"Current networks: {string.Join(", ", HomeNetwork.Current())}",
                $"In home network:  {YesNo(!state.Away)}",
                $"Paused:           {pause}",
                $"Last sent:        {(state.LastSent != DateTime.MinValue ? state.LastSent.ToString("s") : "-")}",
                $"Last error:       {state.SendError ?? "-"}",
                $"Intervals:        check {config.PollSeconds} s, keep-alive {config.HeartbeatSeconds} s",
                $"Autostart:        {YesNo(Installer.GetAutostart())}",
            };
            var cameras = DeviceUsage.CameraMonitorDetails();
            if (cameras.Length > 0)
            {
                lines.Add("");
                lines.Add("Cameras (sensor activity monitor):");
                lines.AddRange(cameras.Split(new[] { Environment.NewLine }, StringSplitOptions.RemoveEmptyEntries));
            }
            lines.Add("");
            lines.Add("Last log lines:");
            lines.AddRange(LastLogLines(40).Select(HideWebhookId));
            return string.Join("\r\n", lines) + "\r\n";
        }

        static string SafeFileVersion(System.Diagnostics.Process process)
        {
            try { return process.MainModule?.FileVersionInfo.FileVersion ?? "?"; }
            catch (Exception) { return "?"; }
        }

        public static string HideWebhookId(string line) => Regex.Replace(line, "/api/webhook/[^\\s\"']+", "/api/webhook/<hidden>");

        static IEnumerable<string> LastLogLines(int count)
        {
            try
            {
                if (!File.Exists(AppPaths.LogPath)) return new string[0];
                using (var stream = new FileStream(AppPaths.LogPath, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
                using (var reader = new StreamReader(stream, Encoding.UTF8))
                {
                    var lines = new List<string>();
                    string line;
                    while ((line = reader.ReadLine()) != null) lines.Add(line);
                    return lines.Skip(Math.Max(0, lines.Count - count)).ToList();
                }
            }
            catch (Exception)
            {
                return new string[0];
            }
        }
    }
}
