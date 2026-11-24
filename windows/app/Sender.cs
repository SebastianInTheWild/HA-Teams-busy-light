using System;
using System.Collections.Generic;
using System.Net;
using System.Net.Http;
using System.Text;
using System.Threading.Tasks;

namespace TeamsBusyLight
{
    /// <summary>Sends status and activity to the webhook of the Home Assistant integration</summary>
    internal static class Sender
    {
        static Sender()
        {
            // The .NET Framework may not offer TLS 1.2 by default
            ServicePointManager.SecurityProtocol |= SecurityProtocolType.Tls12;
        }

        public static HttpClient NewClient(int timeoutSeconds)
        {
            var client = new HttpClient { Timeout = TimeSpan.FromSeconds(timeoutSeconds) };
            // The GitHub API needs a User-Agent
            client.DefaultRequestHeaders.UserAgent.ParseAdd("TeamsBusyLight/" + AppPaths.Version.Split('+')[0]);
            return client;
        }

        /// <summary>The message: computer, version and platform, then the values</summary>
        public static string Body(string status, string activity, string language, IDictionary<string, object> extra)
        {
            var body = new Dictionary<string, object>
            {
                ["computer"] = Environment.MachineName,
                ["app_version"] = AppPaths.Version,
                ["platform"] = "windows",
            };
            if (!string.IsNullOrEmpty(status)) body["status"] = status;
            if (!string.IsNullOrEmpty(activity)) body["activity"] = activity;
            if (!string.IsNullOrEmpty(language)) body["language"] = language;
            if (extra != null)
            {
                foreach (var pair in extra) body[pair.Key] = pair.Value;
            }
            return Json.Serialize(body);
        }

        /// <summary>Sends once; returns null or the reason it failed</summary>
        public static async Task<string> SendAsync(HttpClient client, string webhookUrl, string status, string activity,
            string language = null, IDictionary<string, object> extra = null)
        {
            try
            {
                using (var content = new StringContent(Body(status, activity, language, extra), Encoding.UTF8, "application/json"))
                using (var response = await client.PostAsync(webhookUrl, content).ConfigureAwait(true))
                {
                    return response.IsSuccessStatusCode ? null : $"HTTP {(int)response.StatusCode} {response.ReasonPhrase}";
                }
            }
            catch (TaskCanceledException)
            {
                return "Timeout";
            }
            catch (Exception exception)
            {
                while (exception.InnerException != null) exception = exception.InnerException;
                return exception.Message;
            }
        }

        /// <summary>Sends once with its own client and waits (e.g. when exiting)</summary>
        public static string Send(string webhookUrl, string status, string activity, IDictionary<string, object> extra = null, int timeoutSeconds = 10)
        {
            using (var client = NewClient(timeoutSeconds))
            {
                return Task.Run(() => SendAsync(client, webhookUrl, status, activity, null, extra)).GetAwaiter().GetResult();
            }
        }

        /// <summary>
        /// Camera and microphone are reported off together with offline (the
        /// app stops watching them). An unknown camera is left out, so it stays
        /// unknown in Home Assistant.
        /// </summary>
        public static Dictionary<string, object> OfflineExtra(bool? camera)
        {
            var extra = new Dictionary<string, object> { ["microphone"] = false, ["source"] = "teams" };
            if (camera != null) extra["camera"] = false;
            return extra;
        }
    }
}
