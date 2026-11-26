using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Linq;
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
    /// Replaces an installation of the PowerShell versions before 2.0.0.
    /// </summary>
    internal static class Installer
    {
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true, EntryPoint = "DeleteFileW")]
        static extern bool DeleteStream(string path);

        /// <summary>--install: with the settings window, or --quiet for an update from the app</summary>
        public static int Install(bool quiet)
        {
            var isUpdate = File.Exists(AppPaths.SettingsPath);
            var settings = Settings.Load();
            var loaded = Settings.Load();
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
            if (!quiet) KeepNetworkAnswers(settings, loaded);
            try
            {
                CopyProgram();
                settings.Save();
                SetAutostart(autostart);
                CreateShortcut();
                WriteUninstallEntry();
            }
            catch (Exception exception)
            {
                // The running app was stopped above; after an update from the
                // app (--quiet) nothing else reports this any more. Show it and
                // start the installed program again (the previous version if
                // its file was not replaced).
                Log.Write("Installing failed: " + exception);
                try
                {
                    if (File.Exists(AppPaths.ExePath)) StartInstalled();
                }
                catch (Exception startError)
                {
                    Log.Write($"Cannot start {AppPaths.ExePath}: {startError.Message}");
                }
                Ui.Message(exception.Message, icon: MessageBoxIcon.Error, caption: Strings.Get("InstallTitle"));
                return 1;
            }

            if (addHosts && !RunElevated("--admin-hosts add " + new Uri(settings.WebhookUrl).Host))
            {
                Ui.Message(Strings.Format("AdminCancelled", Strings.Get("AdminHosts")), icon: MessageBoxIcon.Warning, caption: Strings.Get("InstallTitle"));
            }

            StartInstalled();
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
        /// <summary>
        /// Takes over the answers to "new network?" the running app saved while
        /// the installer window was open; saving the window would drop them
        /// </summary>
        static void KeepNetworkAnswers(Settings settings, Settings loaded)
        {
            var saved = Settings.Load();
            settings.HomeNetworks = HomeNetwork.Add(settings.HomeNetworks, AddedNetworks(loaded.HomeNetworks, saved.HomeNetworks));
            settings.IgnoredNetworks = HomeNetwork.Add(settings.IgnoredNetworks, AddedNetworks(loaded.IgnoredNetworks, saved.IgnoredNetworks));
            if (loaded.AskForNewNetworks && !saved.AskForNewNetworks) settings.AskForNewNetworks = false;
        }

        static string[] AddedNetworks(string before, string after)
        {
            var old = HomeNetwork.Split(before);
            return HomeNetwork.Split(after).Where(network => !old.Contains(network, StringComparer.OrdinalIgnoreCase)).ToArray();
        }

        static void CopyProgram()
        {
            var source = Path.GetFullPath(AppPaths.CurrentExe);
            var target = Path.GetFullPath(AppPaths.ExePath);
            Directory.CreateDirectory(AppPaths.ProgramDir);
            foreach (var entry in new DirectoryInfo(AppPaths.ProgramDir).GetFileSystemInfos())
            {
                // The program file is overwritten below (or is this one): if
                // copying fails, the previous version is still there
                if (string.Equals(entry.FullName, target, StringComparison.OrdinalIgnoreCase)) continue;
                FileRetry.Run(() =>
                {
                    if (entry is DirectoryInfo folder) DeleteFolder(folder.FullName);
                    else DeleteFileForce(entry.FullName);
                });
            }
            if (!string.Equals(source, target, StringComparison.OrdinalIgnoreCase))
            {
                FileRetry.Run(() =>
                {
                    // A read-only file cannot be overwritten
                    if (File.Exists(AppPaths.ExePath)) File.SetAttributes(AppPaths.ExePath, FileAttributes.Normal);
                    File.Copy(source, AppPaths.ExePath, true);
                });
                // Not from the internet any more: no SmartScreen prompt at every start
                DeleteStream(AppPaths.ExePath + ":Zone.Identifier");
            }
        }

        /// <summary>Deletes a file, also a read-only one; a missing file is fine</summary>
        static void DeleteFileForce(string path)
        {
            if (!File.Exists(path)) return;
            File.SetAttributes(path, FileAttributes.Normal);
            File.Delete(path);
        }

        /// <summary>Deletes a folder with its content, also read-only files</summary>
        static void DeleteFolder(string path)
        {
            if (!Directory.Exists(path)) return;
            foreach (var file in Directory.GetFiles(path, "*", SearchOption.AllDirectories))
                File.SetAttributes(file, FileAttributes.Normal);
            Directory.Delete(path, true);
        }

        /// <summary>Starts the installed program (the tray app)</summary>
        static void StartInstalled()
        {
            using (Process.Start(new ProcessStartInfo(AppPaths.ExePath) { UseShellExecute = false, WorkingDirectory = AppPaths.ProgramDir })) { }
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

            // Every step on its own, so one failing does not leave the rest
            var problems = new List<string>();
            void Step(Action action)
            {
                try { action(); }
                catch (Exception exception) { problems.Add(exception.Message); }
            }
            Step(() => SetAutostart(false));
            Step(() => DeleteFileForce(AppPaths.StartMenuShortcut));
            Step(() => Registry.CurrentUser.DeleteSubKeyTree(AppPaths.UninstallKey, false));
            // Out of the program folder: a process cannot delete its current
            // directory (e.g. when started from a PowerShell prompt there)
            Environment.CurrentDirectory = Path.GetTempPath();
            // The running file cannot be deleted, but moved out of the folder
            // (see Updater.UninstallFolder); Updater.CleanUp removes it on the
            // next installation, and Windows cleans up the temp folder by itself
            var current = Path.GetFullPath(AppPaths.CurrentExe);
            if (current.StartsWith(Path.GetFullPath(AppPaths.ProgramDir) + "\\", StringComparison.OrdinalIgnoreCase))
            {
                try { File.Move(current, Path.Combine(Updater.UninstallFolder(), Updater.UninstallPrefix + Guid.NewGuid().ToString("N") + ".exe")); }
                catch (Exception) { /* stays until the folder is removed by hand */ }
            }
            foreach (var folder in new[] { AppPaths.ProgramDir, AppPaths.DataDir })
            {
                Step(() => DeleteFolder(folder));
            }

            if (problems.Count > 0)
            {
                Ui.Message(Strings.Format("UninstallIncomplete", string.Join("\n", problems.Distinct())), icon: MessageBoxIcon.Warning);
                return 1;
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

        /// <summary>
        /// Stops a running instance (also of the PowerShell versions) and waits
        /// until it has exited. Throws if it is still running after 15 s.
        /// </summary>
        public static void StopRunning()
        {
            if (!SignalInstance(AppPaths.ExitEventName)) return;
            if (!Mutex.TryOpenExisting(AppPaths.InstanceMutexName, out var mutex)) return;
            using (mutex)
            {
                try
                {
                    if (mutex.WaitOne(15000))
                    {
                        mutex.ReleaseMutex();
                        return;
                    }
                }
                catch (AbandonedMutexException)
                {
                    mutex.ReleaseMutex();
                    return;
                }
            }
            // Still running: take the request back, so it does not exit later
            // with nothing started in its place (the update reports the failure)
            if (EventWaitHandle.TryOpenExisting(AppPaths.ExitEventName, out var exitEvent))
            {
                using (exitEvent) exitEvent.Reset();
            }
            throw new InvalidOperationException("Teams Busy Light did not stop. Exit it in the tray menu and try again.");
        }
    }
}
