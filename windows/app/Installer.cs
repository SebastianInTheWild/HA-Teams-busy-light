using System;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows.Forms;
using Microsoft.Win32;

namespace TeamsBusyLight
{
    /// <summary>
    /// Installs Teams Busy Light for the signed-in Windows user: copies this
    /// executable to %LOCALAPPDATA%\Programs\TeamsBusyLight, adds it to the
    /// Start menu, the Windows sign-in and "Installed apps", and starts it. No
    /// administrator rights are needed; a UAC prompt only appears for the
    /// optional hosts file entry. Run again to update; the settings are kept.
    /// Replaces an installation of the PowerShell versions before 1.8.0.
    /// </summary>
    internal static class Installer
    {
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern bool DeleteFile(string path);

        /// <summary>--install: with the settings window, or --quiet for an update from the app</summary>
        public static int Install(bool quiet)
        {
            var isUpdate = File.Exists(AppPaths.SettingsPath);
            var settings = Settings.Load();
            var autostart = isUpdate ? GetAutostart() : true;
            var addHosts = false;
            if (quiet)
            {
                if (!isUpdate) throw new InvalidOperationException("Teams Busy Light is not installed yet; start TeamsBusyLight.exe without options.");
            }
            else
            {
                var result = SettingsForm.ShowDialog(settings, autostart, install: true);
                if (result == null) return 1;
                settings = result.Settings;
                autostart = result.Autostart;
                addHosts = result.AddHosts;
            }

            // Replace the program file of a running instance
            StopRunning();
            CopyProgram();
            settings.Save();
            SetAutostart(autostart);
            CreateShortcut();
            WriteUninstallEntry();

            if (addHosts && !RunElevated("--admin-hosts add " + new Uri(settings.WebhookUrl).Host))
            {
                Ui.Message(Strings.Format("AdminCancelled", Strings.Get("AdminHosts")), icon: MessageBoxIcon.Warning, caption: Strings.Get("InstallTitle"));
            }

            Process.Start(new ProcessStartInfo(AppPaths.ExePath) { UseShellExecute = false, WorkingDirectory = AppPaths.ProgramDir });
            if (quiet)
            {
                Log.Write("Updated to version " + AppPaths.Version);
                return 0;
            }
            Ui.Message(Strings.Get("InstallComplete"), caption: Strings.Get("CompleteTitle"));
            return 0;
        }

        /// <summary>
        /// Puts this executable into the program folder. Removes everything
        /// else there, e.g. the scripts of the PowerShell versions.
        /// </summary>
        static void CopyProgram()
        {
            var source = Path.GetFullPath(AppPaths.CurrentExe);
            var running = string.Equals(source, Path.GetFullPath(AppPaths.ExePath), StringComparison.OrdinalIgnoreCase);
            Directory.CreateDirectory(AppPaths.ProgramDir);
            foreach (var entry in new DirectoryInfo(AppPaths.ProgramDir).GetFileSystemInfos())
            {
                if (running && string.Equals(entry.FullName, source, StringComparison.OrdinalIgnoreCase)) continue;
                Retry(() =>
                {
                    if (entry is DirectoryInfo folder) folder.Delete(true);
                    else entry.Delete();
                });
            }
            if (!running)
            {
                Retry(() => File.Copy(source, AppPaths.ExePath, true));
                // Not from the internet any more: no SmartScreen prompt at every start
                DeleteFile(AppPaths.ExePath + ":Zone.Identifier");
            }
        }

        /// <summary>A file of an instance that just exited may still be locked for a moment</summary>
        static void Retry(Action action)
        {
            for (var attempt = 1; ; attempt++)
            {
                try
                {
                    action();
                    return;
                }
                catch (Exception exception) when ((exception is IOException || exception is UnauthorizedAccessException) && attempt < 20)
                {
                    Thread.Sleep(500);
                }
            }
        }

        static void CreateShortcut()
        {
            // Start menu entry; it opens the settings (and starts the app if needed)
            var shellType = Type.GetTypeFromProgID("WScript.Shell");
            var shell = Activator.CreateInstance(shellType);
            try
            {
                var shortcut = shellType.InvokeMember("CreateShortcut", BindingFlags.InvokeMethod, null, shell, new object[] { AppPaths.StartMenuShortcut });
                try
                {
                    var type = shortcut.GetType();
                    void Set(string name, object value) => type.InvokeMember(name, BindingFlags.SetProperty, null, shortcut, new[] { value });
                    Set("TargetPath", AppPaths.ExePath);
                    Set("Arguments", "--settings");
                    Set("WorkingDirectory", AppPaths.ProgramDir);
                    Set("IconLocation", AppPaths.ExePath + ",0");
                    Set("Description", Strings.Get("Subtitle"));
                    type.InvokeMember("Save", BindingFlags.InvokeMethod, null, shortcut, null);
                }
                finally { Marshal.ReleaseComObject(shortcut); }
            }
            finally { Marshal.ReleaseComObject(shell); }
        }

        static void WriteUninstallEntry()
        {
            // Entry under Settings > Apps > Installed apps
            using (var key = Registry.CurrentUser.CreateSubKey(AppPaths.UninstallKey))
            {
                key.SetValue("DisplayName", AppPaths.AppName);
                key.SetValue("DisplayVersion", AppPaths.Version);
                key.SetValue("DisplayIcon", AppPaths.ExePath + ",0");
                key.SetValue("Publisher", "SebastianInTheWild");
                key.SetValue("URLInfoAbout", AppPaths.ProjectPage);
                key.SetValue("InstallLocation", AppPaths.ProgramDir);
                key.SetValue("UninstallString", $"\"{AppPaths.ExePath}\" --uninstall");
                key.SetValue("NoModify", 1, RegistryValueKind.DWord);
                key.SetValue("NoRepair", 1, RegistryValueKind.DWord);
                key.SetValue("EstimatedSize", (int)(new FileInfo(AppPaths.ExePath).Length / 1024), RegistryValueKind.DWord);
            }
        }

        /// <summary>
        /// --uninstall: removes Teams Busy Light from the Windows sign-in, the
        /// Start menu and "Installed apps", and deletes its program file,
        /// settings and log. Optionally removes its hosts file entries (UAC
        /// prompt). The Home Assistant integration entry is not changed.
        /// </summary>
        public static int Uninstall()
        {
            if (Ui.Message(Strings.Get("ConfirmUninstall"), MessageBoxButtons.YesNo, MessageBoxIcon.Question) != DialogResult.Yes) return 1;

            var settings = Settings.Load();
            StopRunning();

            if (Uri.TryCreate(settings.WebhookUrl, UriKind.Absolute, out var webhook) && HostsFile.HasEntry(webhook.Host) &&
                Ui.Message(Strings.Get("UninstallHosts"), MessageBoxButtons.YesNo, MessageBoxIcon.Question) == DialogResult.Yes)
            {
                RunElevated("--admin-hosts remove " + webhook.Host);
            }

            SetAutostart(false);
            File.Delete(AppPaths.StartMenuShortcut);
            Registry.CurrentUser.DeleteSubKeyTree(AppPaths.UninstallKey, false);
            // The running file cannot be deleted, but moved out of the folder
            var current = Path.GetFullPath(AppPaths.CurrentExe);
            if (current.StartsWith(Path.GetFullPath(AppPaths.ProgramDir) + "\\", StringComparison.OrdinalIgnoreCase))
            {
                try { File.Move(current, Path.Combine(Path.GetTempPath(), "TeamsBusyLight-Uninstall-" + Guid.NewGuid().ToString("N") + ".exe")); }
                catch (Exception) { /* stays until the folder is removed by hand */ }
            }
            foreach (var folder in new[] { AppPaths.ProgramDir, AppPaths.DataDir })
            {
                try { if (Directory.Exists(folder)) Directory.Delete(folder, true); }
                catch (Exception exception) { Debug.WriteLine(exception.Message); }
            }

            Ui.Message(Strings.Get("UninstallComplete"));
            return 0;
        }

        /// <summary>Starts this executable with administrator rights (UAC prompt) and waits; false if declined</summary>
        static bool RunElevated(string arguments)
        {
            var exe = File.Exists(AppPaths.ExePath) ? AppPaths.ExePath : AppPaths.CurrentExe;
            try
            {
                using (var process = Process.Start(new ProcessStartInfo(exe, arguments) { UseShellExecute = true, Verb = "runas" }))
                {
                    process?.WaitForExit();
                    return true;
                }
            }
            catch (Win32Exception)
            {
                // The UAC prompt was declined
                return false;
            }
        }

        public static bool GetAutostart()
        {
            using (var key = Registry.CurrentUser.OpenSubKey(AppPaths.RunKey)) return key?.GetValue(AppPaths.AppName) != null;
        }

        public static void SetAutostart(bool enabled)
        {
            using (var key = Registry.CurrentUser.CreateSubKey(AppPaths.RunKey))
            {
                if (enabled) key.SetValue(AppPaths.AppName, $"\"{AppPaths.ExePath}\"");
                else key.DeleteValue(AppPaths.AppName, false);
            }
        }

        /// <summary>Asks a running instance to show its settings or to exit. False if none is running.</summary>
        public static bool SignalInstance(string eventName)
        {
            if (!EventWaitHandle.TryOpenExisting(eventName, out var handle)) return false;
            using (handle) handle.Set();
            return true;
        }

        /// <summary>Stops a running instance (also of the PowerShell versions) and waits until it has exited</summary>
        public static void StopRunning()
        {
            if (!SignalInstance(AppPaths.ExitEventName)) return;
            if (!Mutex.TryOpenExisting(AppPaths.InstanceMutexName, out var mutex)) return;
            using (mutex)
            {
                try
                {
                    if (mutex.WaitOne(15000)) mutex.ReleaseMutex();
                }
                catch (AbandonedMutexException)
                {
                    mutex.ReleaseMutex();
                }
            }
        }
    }
}
