using System;
using System.IO;
using System.Reflection;

namespace TeamsBusyLight
{
    /// <summary>
    /// Places and names of Teams Busy Light. It runs per Windows user without
    /// administrator rights:
    ///   program   %LOCALAPPDATA%\Programs\TeamsBusyLight\TeamsBusyLight.exe
    ///   settings  %LOCALAPPDATA%\TeamsBusyLight\settings.json
    ///   log       %LOCALAPPDATA%\TeamsBusyLight\TeamsBusyLight.log
    /// The same as in the PowerShell versions before 1.8.0, so their settings
    /// are kept and autostart and Start menu entry point to the same file.
    /// </summary>
    internal static class AppPaths
    {
        public const string AppName = "Teams Busy Light";

        static readonly string LocalAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);

        public static readonly string ProgramDir = Path.Combine(LocalAppData, @"Programs\TeamsBusyLight");
        public static readonly string ExePath = Path.Combine(ProgramDir, "TeamsBusyLight.exe");
        public static readonly string DataDir = Path.Combine(LocalAppData, "TeamsBusyLight");
        public static readonly string SettingsPath = Path.Combine(DataDir, "settings.json");
        public static readonly string LogPath = Path.Combine(DataDir, "TeamsBusyLight.log");
        public static readonly string PausePath = Path.Combine(DataDir, "pause.txt");
        public static readonly string ManualStatusPath = Path.Combine(DataDir, "manual-status.txt");
        public static readonly string TeamsLogFolder = Path.Combine(LocalAppData, @"Packages\MSTeams_8wekyb3d8bbwe\LocalCache\Microsoft\MSTeams\Logs");
        public static readonly string StartMenuShortcut = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Programs), "Teams Busy Light.lnk");

        public const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
        public const string UninstallKey = @"Software\Microsoft\Windows\CurrentVersion\Uninstall\TeamsBusyLight";

        // Names of the objects used to talk to a running instance (also the
        // PowerShell versions, so an update stops them)
        public const string InstanceMutexName = @"Local\TeamsBusyLight";
        public const string ShowSettingsEventName = @"Local\TeamsBusyLight.ShowSettings";
        public const string ExitEventName = @"Local\TeamsBusyLight.Exit";

        public const string ProjectPage = "https://github.com/SebastianInTheWild/HA-Teams-busy-light";
        public const string ReleasesPage = ProjectPage + "/releases/latest";
        public const string ReleasesApi = "https://api.github.com/repos/SebastianInTheWild/HA-Teams-busy-light/releases/latest";
        // Update channel "Beta": the newest releases including pre-releases
        public const string ReleasesListApi = "https://api.github.com/repos/SebastianInTheWild/HA-Teams-busy-light/releases?per_page=30";
        public const string ReleaseAssetName = "TeamsBusyLight-Windows.zip";

        // The Windows download contains a list of the SHA-256 hashes of its
        // files, signed with our own certificate (windows/tools/
        // create-signing-certificate.ps1). Updates are installed only if the
        // list is signed with the certificate with this SHA-256 fingerprint.
        // Empty = no update button, only the hint.
        public const string ReleaseManifestName = "TeamsBusyLight.sha256.p7m";
        // Signed catalog of the same files, for the PowerShell versions before
        // 1.8.0, which update themselves to this version
        public const string ReleaseCatalogName = "TeamsBusyLight.cat";
        public const string SigningCertificateSha256 = "C490C7763D8BB1C4098F00D45BB87C7BC45A41282686F89D32C941EBDBABF48F";

        /// <summary>Version of this build, e.g. "1.8.0" or "1.8.0-beta.1"; "0.0.0" in a development build</summary>
        public static readonly string Version =
            typeof(AppPaths).Assembly.GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion ?? "0.0.0";

        /// <summary>Path of the running executable</summary>
        public static string CurrentExe => Assembly.GetEntryAssembly()?.Location ?? ExePath;

        /// <summary>True when this is the installed copy in the program folder</summary>
        public static bool IsInstalledCopy =>
            string.Equals(Path.GetFullPath(CurrentExe), Path.GetFullPath(ExePath), StringComparison.OrdinalIgnoreCase);

        public static void EnsureDataDir() => Directory.CreateDirectory(DataDir);
    }
}
