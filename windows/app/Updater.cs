using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Security.Cryptography;
using System.Security.Cryptography.Pkcs;
using System.Security.Cryptography.X509Certificates;
using System.Text;

namespace TeamsBusyLight
{
    /// <summary>
    /// Installs an update from the release download (TeamsBusyLight-Windows.zip).
    ///
    /// Only a download whose file list (TeamsBusyLight.sha256.p7m) is signed
    /// with the pinned certificate and whose files match the list is
    /// installed. Windows does not need to trust the self-signed certificate
    /// for this. The new version installs itself (--install --quiet): it stops
    /// this instance, replaces the program file and starts again.
    /// </summary>
    internal static class Updater
    {
        const long MaxBytes = 50L * 1024 * 1024;
        const string FolderPrefix = "TeamsBusyLight-Update-";

        /// <summary>Checks and unpacks the download, then starts its installer. Throws with the reason.</summary>
        public static Process Install(byte[] zip, string expectedVersion)
        {
            if (zip.LongLength > MaxBytes) throw new InvalidOperationException("the download is too large");
            var folder = Path.Combine(Path.GetTempPath(), FolderPrefix + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(folder);
            var zipPath = Path.Combine(folder, AppPaths.ReleaseAssetName);
            File.WriteAllBytes(zipPath, zip);
            var filesDir = Path.Combine(folder, "files");
            ExpandZip(zipPath, filesDir, MaxBytes);
            var sourceDir = Path.Combine(filesDir, "TeamsBusyLight-Windows");
            var exe = Path.Combine(sourceDir, "TeamsBusyLight.exe");
            if (!File.Exists(exe)) throw new InvalidOperationException("unexpected content of the download");
            var problem = CheckManifest(sourceDir, AppPaths.SigningCertificateSha256);
            if (problem != null) throw new InvalidOperationException("signature check failed: " + problem);
            // A correctly signed older release must not be installed instead
            var versionFile = Path.Combine(sourceDir, "version.txt");
            var version = File.Exists(versionFile) ? File.ReadAllText(versionFile).Trim() : "";
            if (version != expectedVersion) throw new InvalidOperationException($"the download contains version {version}");
            Log.Write($"Update {version} checked, starting the installer");
            // Working directory outside the program folder, which the installer replaces
            return Process.Start(new ProcessStartInfo(exe, "--install --quiet") { UseShellExecute = false, WorkingDirectory = sourceDir });
        }

        /// <summary>Name start of the program file moved away when uninstalling</summary>
        public const string UninstallPrefix = "TeamsBusyLight-Uninstall-";

        /// <summary>
        /// Where uninstalling moves the running program file: the temp folder
        /// if it is on the same drive as the program folder (otherwise moving
        /// copies, and the running original stays), else the folder that
        /// contains the program folder
        /// </summary>
        public static string UninstallFolder()
        {
            var temp = Path.GetFullPath(Path.GetTempPath());
            var programs = Path.GetDirectoryName(Path.GetFullPath(AppPaths.ProgramDir));
            return string.Equals(Path.GetPathRoot(temp), Path.GetPathRoot(programs), StringComparison.OrdinalIgnoreCase)
                ? temp
                : programs;
        }

        /// <summary>Removes update folders of earlier updates and program files left by uninstalling</summary>
        public static void CleanUp()
        {
            foreach (var folder in new[] { Path.GetFullPath(Path.GetTempPath()), UninstallFolder() }.Distinct(StringComparer.OrdinalIgnoreCase))
            {
                try
                {
                    foreach (var file in new DirectoryInfo(folder).GetFiles(UninstallPrefix + "*.exe"))
                    {
                        try { file.Delete(); } catch (Exception) { /* still running, next time */ }
                    }
                }
                catch (Exception)
                {
                    // Nothing to clean up
                }
            }
            try
            {
                foreach (var folder in new DirectoryInfo(Path.GetTempPath()).GetDirectories(FolderPrefix + "*"))
                {
                    if (folder.LastWriteTime < DateTime.Now.AddMinutes(-10))
                    {
                        try { folder.Delete(true); } catch (Exception) { /* in use, next time */ }
                    }
                }
            }
            catch (Exception)
            {
                // Nothing to clean up
            }
        }

        /// <summary>Unpacks a ZIP file; refuses entries outside the target folder and archives over maxBytes</summary>
        public static void ExpandZip(string zipPath, string destination, long maxBytes)
        {
            var root = Path.GetFullPath(destination).TrimEnd('\\') + "\\";
            using (var archive = ZipFile.OpenRead(zipPath))
            {
                long total = 0;
                foreach (var entry in archive.Entries)
                {
                    total += entry.Length;
                    if (total > maxBytes) throw new InvalidOperationException("The archive is too large.");
                    var target = Path.GetFullPath(Path.Combine(root, entry.FullName));
                    if (!target.StartsWith(root, StringComparison.OrdinalIgnoreCase))
                        throw new InvalidOperationException("The archive contains an invalid path: " + entry.FullName);
                    if (entry.FullName.EndsWith("/") || entry.FullName.EndsWith("\\"))
                    {
                        Directory.CreateDirectory(target);
                        continue;
                    }
                    Directory.CreateDirectory(Path.GetDirectoryName(target));
                    entry.ExtractToFile(target, false);
                }
            }
        }

        public static string CertificateSha256(X509Certificate2 certificate)
        {
            using (var sha = SHA256.Create()) return BitConverter.ToString(sha.ComputeHash(certificate.RawData)).Replace("-", "");
        }

        /// <summary>
        /// The text of the file list: "&lt;sha256&gt;  &lt;path&gt;" per file, paths
        /// relative with "/", sorted ordinally. Also written by
        /// tools/build-release.ps1.
        /// </summary>
        public static string ManifestText(string folder)
        {
            var lines = Files(folder)
                .Select(path => FileHash(Path.Combine(folder, path.Replace('/', '\\'))) + "  " + path)
                .ToList();
            return string.Join("\n", lines) + "\n";
        }

        /// <summary>Files of the folder (relative, with "/"), without the list and the catalog</summary>
        static IEnumerable<string> Files(string folder)
        {
            var root = Path.GetFullPath(folder).TrimEnd('\\') + "\\";
            return Directory.GetFiles(root, "*", SearchOption.AllDirectories)
                .Select(path => path.Substring(root.Length).Replace('\\', '/'))
                .Where(path => path != AppPaths.ReleaseManifestName && path != AppPaths.ReleaseCatalogName)
                .OrderBy(path => path, StringComparer.Ordinal);
        }

        static string FileHash(string path)
        {
            using (var sha = SHA256.Create())
            using (var stream = File.OpenRead(path))
            {
                return BitConverter.ToString(sha.ComputeHash(stream)).Replace("-", "").ToLowerInvariant();
            }
        }

        /// <summary>
        /// Checks an unpacked download: the file list must be signed with the
        /// pinned certificate and all files must match it (none changed, added
        /// or missing). Returns null if everything is fine, otherwise the reason.
        /// </summary>
        public static string CheckManifest(string folder, string fingerprint)
        {
            if (string.IsNullOrEmpty(fingerprint)) return "no signing certificate pinned";
            var path = Path.Combine(folder, AppPaths.ReleaseManifestName);
            if (!File.Exists(path)) return "not signed";
            var signed = new SignedCms();
            try
            {
                signed.Decode(File.ReadAllBytes(path));
                // Checks the signature itself, not whether Windows trusts the certificate
                signed.CheckSignature(true);
            }
            catch (CryptographicException exception)
            {
                return $"invalid signature ({exception.Message.Trim()})";
            }
            if (signed.SignerInfos.Count != 1 || signed.SignerInfos[0].Certificate == null) return "unexpected signers";
            if (!string.Equals(CertificateSha256(signed.SignerInfos[0].Certificate), fingerprint, StringComparison.OrdinalIgnoreCase))
                return "signed with another certificate";

            var expected = Encoding.UTF8.GetString(signed.ContentInfo.Content);
            var actual = ManifestText(folder);
            if (expected == actual) return null;
            var expectedLines = new HashSet<string>(expected.Split(new[] { '\n' }, StringSplitOptions.RemoveEmptyEntries));
            var differences = actual.Split(new[] { '\n' }, StringSplitOptions.RemoveEmptyEntries)
                .Where(line => !expectedLines.Remove(line))
                .Concat(expectedLines)
                .Select(line => line.Length > 66 ? line.Substring(66) : line)
                .Distinct();
            return "files do not match the list: " + string.Join(", ", differences);
        }
    }
}
