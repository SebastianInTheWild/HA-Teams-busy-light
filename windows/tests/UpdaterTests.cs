using System;
using System.IO;
using System.IO.Compression;
using System.Security.Cryptography;
using System.Security.Cryptography.Pkcs;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using Xunit;

namespace TeamsBusyLight.Tests
{
    /// <summary>The signed file list of the download, as tools/build-release.ps1 writes it</summary>
    public sealed class UpdaterTests : IDisposable
    {
        readonly string folder = Path.Combine(Path.GetTempPath(), "TeamsBusyLight-Test-" + Guid.NewGuid().ToString("N"));
        readonly X509Certificate2 certificate = NewCertificate();

        public UpdaterTests()
        {
            Directory.CreateDirectory(Path.Combine(folder, "sub"));
            File.WriteAllText(Path.Combine(folder, "TeamsBusyLight.exe"), "program");
            File.WriteAllText(Path.Combine(folder, "version.txt"), "1.8.0");
            File.WriteAllText(Path.Combine(folder, "sub", "README.md"), "read me");
        }

        public void Dispose()
        {
            Directory.Delete(folder, true);
            certificate.Dispose();
        }

        static X509Certificate2 NewCertificate()
        {
            using (var key = RSA.Create(2048))
            {
                var request = new CertificateRequest("CN=Teams Busy Light Test", key, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
                using (var created = request.CreateSelfSigned(DateTimeOffset.Now.AddDays(-1), DateTimeOffset.Now.AddDays(1)))
                {
                    // With an exportable private key, which SignedCms needs on the .NET Framework
                    return new X509Certificate2(created.Export(X509ContentType.Pfx, "x"), "x", X509KeyStorageFlags.Exportable);
                }
            }
        }

        void Sign(string text)
        {
            var signed = new SignedCms(new ContentInfo(Encoding.UTF8.GetBytes(text)), false);
            signed.ComputeSignature(new CmsSigner(certificate));
            File.WriteAllBytes(Path.Combine(folder, AppPaths.ReleaseManifestName), signed.Encode());
        }

        string Fingerprint => Updater.CertificateSha256(certificate);

        [Fact]
        public void ValidList()
        {
            Sign(Updater.ManifestText(folder));
            // The catalog for the PowerShell versions is not part of the list
            File.WriteAllText(Path.Combine(folder, AppPaths.ReleaseCatalogName), "catalog");
            Assert.Null(Updater.CheckManifest(folder, Fingerprint));
        }

        [Fact]
        public void ListFormat()
        {
            var lines = Updater.ManifestText(folder).TrimEnd('\n').Split('\n');
            Assert.Equal(3, lines.Length);
            Assert.EndsWith("  TeamsBusyLight.exe", lines[0]);
            Assert.EndsWith("  sub/README.md", lines[1]);
            Assert.Equal(66, lines[0].IndexOf("TeamsBusyLight.exe", StringComparison.Ordinal));
        }

        [Fact]
        public void ChangedFile()
        {
            Sign(Updater.ManifestText(folder));
            File.WriteAllText(Path.Combine(folder, "TeamsBusyLight.exe"), "changed");
            Assert.Contains("TeamsBusyLight.exe", Updater.CheckManifest(folder, Fingerprint));
        }

        [Fact]
        public void AddedFile()
        {
            Sign(Updater.ManifestText(folder));
            File.WriteAllText(Path.Combine(folder, "extra.dll"), "x");
            Assert.Contains("extra.dll", Updater.CheckManifest(folder, Fingerprint));
        }

        [Fact]
        public void OtherCertificate()
        {
            Sign(Updater.ManifestText(folder));
            Assert.Equal("signed with another certificate", Updater.CheckManifest(folder, new string('A', 64)));
        }

        [Fact]
        public void NotSigned() => Assert.Equal("not signed", Updater.CheckManifest(folder, Fingerprint));

        [Fact]
        public void BrokenSignature()
        {
            File.WriteAllBytes(Path.Combine(folder, AppPaths.ReleaseManifestName), new byte[] { 1, 2, 3 });
            Assert.StartsWith("invalid signature", Updater.CheckManifest(folder, Fingerprint));
        }

        [Fact]
        public void ZipWithPathOutsideIsRefused()
        {
            var zip = Path.Combine(folder, "evil.zip");
            using (var archive = ZipFile.Open(zip, ZipArchiveMode.Create))
            {
                using (var writer = new StreamWriter(archive.CreateEntry("../outside.txt").Open())) writer.Write("x");
            }
            var target = Path.Combine(folder, "out");
            var error = Assert.Throws<InvalidOperationException>(() => Updater.ExpandZip(zip, target, 1024 * 1024));
            Assert.Contains("invalid path", error.Message);
            Assert.False(File.Exists(Path.Combine(folder, "outside.txt")));
        }
    }
}
