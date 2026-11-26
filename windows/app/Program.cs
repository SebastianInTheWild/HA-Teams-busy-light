using System;
using System.Linq;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows.Forms;

namespace TeamsBusyLight
{
    /// <summary>
    /// Start of Teams Busy Light. Without options: the tray app, or the
    /// installer when started from somewhere else than the program folder
    /// (e.g. from the unpacked release download).
    ///
    ///   --settings                     opens the settings (also of a running instance)
    ///   --install [--quiet]            installs or updates; --quiet: update from the app
    ///   --uninstall                    removes Teams Busy Light for this user
    ///   --set-status &lt;status&gt; [&lt;activity&gt;]  sends a status once and exits,
    ///                                  e.g. available, busy, away, offline
    ///   --admin-hosts add|remove &lt;host&gt;  hosts file entry (started with a UAC prompt)
    /// </summary>
    internal static class Program
    {
        [DllImport("kernel32.dll")]
        static extern bool AttachConsole(int processId);

        [STAThread]
        static int Main(string[] args)
        {
            // Options like the PowerShell versions accepted them too (-Settings)
            var options = args.Select(arg => arg.StartsWith("-") ? "--" + arg.TrimStart('-').ToLowerInvariant() : arg).ToArray();
            bool Has(string name) => options.Contains(name);
            string After(string name, int offset = 1)
            {
                var index = Array.IndexOf(options, name);
                return index >= 0 && index + offset < options.Length && !options[index + offset].StartsWith("--") ? options[index + offset] : null;
            }

            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            Strings.Load();

            try
            {
                if (Has("--set-status")) return SetStatus(After("--set-status"), After("--set-status", 2));
                if (Has("--admin-hosts")) return HostsFile.Run(args.Skip(Array.IndexOf(options, "--admin-hosts") + 1).ToArray());
                if (Has("--uninstall")) return Installer.Uninstall();
                if (Has("--install") || !AppPaths.IsInstalledCopy) return Installer.Install(Has("--quiet"));
                return RunTray(Has("--settings"));
            }
            catch (Exception exception)
            {
                Log.Write(exception.ToString());
                if (!Has("--quiet") && !Has("--set-status"))
                    Ui.Message(exception.Message, icon: MessageBoxIcon.Error);
                return 1;
            }
        }

        static int RunTray(bool showSettings)
        {
            // Only one instance per Windows user; starting it again opens the settings
            using (var mutex = new Mutex(true, AppPaths.InstanceMutexName, out var createdNew))
            {
                if (!createdNew)
                {
                    Installer.SignalInstance(AppPaths.ShowSettingsEventName);
                    return 0;
                }
                using (var showSettingsEvent = new EventWaitHandle(false, EventResetMode.AutoReset, AppPaths.ShowSettingsEventName))
                using (var exitEvent = new EventWaitHandle(false, EventResetMode.AutoReset, AppPaths.ExitEventName))
                using (var app = new TrayApp(showSettings, showSettingsEvent, exitEvent))
                {
                    Application.Run(app);
                }
                mutex.ReleaseMutex();
            }
            return 0;
        }

        /// <summary>--set-status: sends once; the output goes to the console it was started from</summary>
        static int SetStatus(string status, string activity)
        {
            AttachConsole(-1);
            var settings = Settings.Load();
            if (string.IsNullOrEmpty(settings.WebhookUrl))
            {
                Console.Error.WriteLine(Strings.Get("MissingWebhook"));
                return 1;
            }
            if (string.IsNullOrEmpty(status))
            {
                Console.Error.WriteLine("Usage: TeamsBusyLight.exe --set-status <status> [<activity>]");
                return 1;
            }
            Console.WriteLine(Strings.Format("StatusSet", status));
            var error = Sender.Send(settings.WebhookUrl, status, activity);
            if (error != null)
            {
                Console.Error.WriteLine(Strings.Format("LogSendFailed", error));
                return 1;
            }
            Console.WriteLine(Strings.Get("StatusSetSuccess"));
            return 0;
        }
    }
}
