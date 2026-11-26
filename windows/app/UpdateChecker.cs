using System;
using System.Linq;

namespace TeamsBusyLight
{
    /// <summary>A published release from the GitHub API</summary>
    internal sealed class Release
    {
        public string Version;
        public string Page;
        /// <summary>Download of the Windows app, null when missing</summary>
        public string AssetUrl;
    }

    /// <summary>Versions and releases (update channels Release and Beta)</summary>
    internal static class UpdateChecker
    {
        /// <summary>
        /// First version with the signed file list (Windows program instead of
        /// PowerShell); older ones are only offered as release page
        /// </summary>
        public const string FirstInstallableVersion = "1.8.0-beta.1";

        public static bool CanInstall(string version) => Compare(version, FirstInstallableVersion) >= 0;

        /// <summary>
        /// Compares two versions like SemVer: 1 if a is newer, -1 if older, 0
        /// if equal. "1.10.0" &gt; "1.9.2", and a pre-release comes before its
        /// version: "1.6.0-beta.2" &lt; "1.6.0-beta.10" &lt; "1.6.0".
        /// </summary>
        public static int Compare(string first, string second)
        {
            var partsA = Clean(first).Split(new[] { '-' }, 2);
            var partsB = Clean(second).Split(new[] { '-' }, 2);
            var a = Numbers(partsA[0]);
            var b = Numbers(partsB[0]);
            for (var index = 0; index < Math.Max(a.Length, b.Length); index++)
            {
                var x = index < a.Length ? a[index] : 0;
                var y = index < b.Length ? b[index] : 0;
                if (x != y) return x > y ? 1 : -1;
            }

            var preA = partsA.Length > 1 ? partsA[1] : "";
            var preB = partsB.Length > 1 ? partsB[1] : "";
            if (preA == preB) return 0;
            if (preA.Length == 0) return 1;
            if (preB.Length == 0) return -1;
            var idsA = preA.Split('.');
            var idsB = preB.Split('.');
            for (var index = 0; index < Math.Max(idsA.Length, idsB.Length); index++)
            {
                if (index >= idsA.Length) return -1;
                if (index >= idsB.Length) return 1;
                var isNumberA = int.TryParse(idsA[index], out var numberA);
                var isNumberB = int.TryParse(idsB[index], out var numberB);
                if (isNumberA && isNumberB)
                {
                    if (numberA != numberB) return numberA > numberB ? 1 : -1;
                }
                else if (isNumberA != isNumberB)
                {
                    // Numbers come before words
                    return isNumberA ? -1 : 1;
                }
                else
                {
                    var order = string.CompareOrdinal(idsA[index], idsB[index]);
                    if (order != 0) return order > 0 ? 1 : -1;
                }
            }
            return 0;
        }

        /// <summary>Without "v" and build metadata ("+...")</summary>
        static string Clean(string version) => (version ?? "").Trim().TrimStart('v').Split('+')[0];

        static int[] Numbers(string text) =>
            text.Split('.').Select(part => int.TryParse(new string(part.Select(c => char.IsDigit(c) ? c : '0').ToArray()), out var n) ? n : 0).ToArray();

        public static bool IsNewer(string candidate, string current) => Compare(candidate, current) > 0;

        /// <summary>
        /// What to offer for the latest version of the channel: "update" if it
        /// is newer, "downgrade" if a pre-release is installed on the release
        /// channel (back to the latest release, even if older), otherwise null
        /// </summary>
        public static string Offer(string latest, string current, bool preReleases)
        {
            if (IsNewer(latest, current)) return "update";
            if (!preReleases && Clean(current).Contains("-") && Compare(latest, current) != 0) return "downgrade";
            return null;
        }

        /// <summary>
        /// The newest published release from an answer of the GitHub API: one
        /// release (releases/latest) or a list (releases, with pre-releases)
        /// </summary>
        public static Release SelectNewest(string json)
        {
            var parsed = Json.Parse(json);
            var releases = Json.AsArray(parsed) ?? new[] { parsed };
            Release newest = null;
            foreach (var item in releases)
            {
                var release = Json.AsObject(item);
                if (release == null || (release.TryGetValue("draft", out var draft) && draft is bool isDraft && isDraft)) continue;
                var version = (Json.GetString(release, "tag_name") ?? "").TrimStart('v');
                if (version.Length == 0) continue;
                if (newest != null && !IsNewer(version, newest.Version)) continue;

                var page = Json.GetString(release, "html_url");
                string assetUrl = null;
                foreach (var assetItem in Json.AsArray(release.TryGetValue("assets", out var assets) ? assets : null) ?? new object[0])
                {
                    var asset = Json.AsObject(assetItem);
                    if (Json.GetString(asset, "name") == AppPaths.ReleaseAssetName)
                    {
                        assetUrl = Json.GetString(asset, "browser_download_url");
                        break;
                    }
                }
                newest = new Release
                {
                    Version = version,
                    Page = page != null && page.StartsWith("https://github.com/", StringComparison.Ordinal) ? page : null,
                    AssetUrl = assetUrl != null && assetUrl.StartsWith("https://", StringComparison.Ordinal) ? assetUrl : null,
                };
            }
            return newest;
        }
    }
}
