using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Linq;
using System.Net.Http;
using System.Reflection;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Forms;

namespace TeamsBusyLight
{
    /// <summary>
    /// The tray app: reads the status of the new Teams client from its log and
    /// sends it to the "Teams Busy Light" integration in Home Assistant via its
    /// webhook, as language-neutral states (e.g. "busy", "in_call") on every
    /// change and as keep-alive. The tray icon shows the status as a colored
    /// dot; its menu sets the status, pauses sending and opens the settings.
    /// </summary>
    internal sealed class TrayApp : ApplicationContext
    {
        static readonly Dictionary<string, Color> DotColors = new Dictionary<string, Color>
        {
            ["available"] = Color.FromArgb(92, 184, 92),
            ["busy"] = Color.FromArgb(212, 52, 70),
            ["away"] = Color.FromArgb(250, 176, 40),
            ["offline"] = Color.FromArgb(150, 150, 150),
        };
        static readonly Dictionary<string, string> StatusColorKey = new Dictionary<string, string>
        {
            ["available"] = "available",
            ["busy"] = "busy",
            ["in_a_call"] = "busy",
            ["in_a_meeting"] = "busy",
            ["presenting"] = "busy",
            ["focusing"] = "busy",
            ["do_not_disturb"] = "busy",
            ["be_right_back"] = "away",
            ["away"] = "away",
            ["offline"] = "offline",
        };

        readonly EventWaitHandle showSettingsEvent;
        readonly EventWaitHandle exitEvent;
        readonly HttpClient http = Sender.NewClient(10);
        readonly HttpClient updateHttp = Sender.NewClient(30);
        readonly System.Windows.Forms.Timer timer = new System.Windows.Forms.Timer { Interval = 500 };
        readonly Dictionary<string, Icon> iconCache = new Dictionary<string, Icon>();
        readonly Bitmap brandImage = Ui.BrandImage(64);

        Settings config = Settings.Load();

        // Current and last sent state
        string status;
        // Sent activity: the Teams one or, with DetectOtherCalls, in_call while any app uses the microphone
        string activity = "not_in_call";
        string teamsActivity = "not_in_call";
        // The microphone starts off, so the first check does not log "no longer in use"
        DeviceState devices = new DeviceState { Microphone = false };
        ManualStatus manual = Settings.LoadManualStatus();
        string language;
        string sentKey, loggedStatus, sendError;
        DateTime lastSent = DateTime.MinValue, lastPoll = DateTime.MinValue, retryAfter = DateTime.MinValue;
        DateTime lastNetworkCheck = DateTime.MinValue, lastUpdateCheck = DateTime.MinValue;
        bool sending, logMissing, settingsOpen, away, askingNetwork;
        // The send on its way, so "offline" for a pause is sent after it
        Task<string> pendingSend;
        DateTime? pausedUntil = Settings.LoadPause();

        // Updates: the offered version, its download (null = only the release page)
        string updateVersion, updateAssetUrl, updatePage;
        // The offered version is the latest release, replacing an installed pre-release
        bool updateDowngrade;
        // Channel of the last check (true = with pre-releases, null = none yet)
        bool? updatePreReleases;
        bool updateChecking, updating;
        Process updateInstaller;

        readonly NotifyIcon tray;
        readonly ToolStripMenuItem statusItem, activityItem, connectionItem, useTeamsItem, resumeItem, updateItem;

        public TrayApp(bool showSettings, EventWaitHandle showSettingsEvent, EventWaitHandle exitEvent)
        {
            this.showSettingsEvent = showSettingsEvent;
            this.exitEvent = exitEvent;

            tray = new NotifyIcon { Icon = StatusIcon("none"), Text = AppPaths.AppName };
            var menu = new ContextMenuStrip();
            statusItem = new ToolStripMenuItem { Enabled = false };
            activityItem = new ToolStripMenuItem { Enabled = false };
            connectionItem = new ToolStripMenuItem { Enabled = false };

            var setStatusItem = new ToolStripMenuItem(Strings.Get("MenuSetStatus"));
            foreach (var manualStatus in ManualStatus.Statuses)
            {
                var choice = new ToolStripMenuItem(Strings.Status(manualStatus));
                foreach (var (key, minutes) in new[] { ("Manual30m", 30), ("Manual1h", 60), ("Manual2h", 120), ("ManualAlways", 0) })
                {
                    choice.DropDownItems.Add(Strings.Get(key), null, (sender, args) =>
                        SetManual(manualStatus, minutes == 0 ? DateTime.MaxValue : DateTime.Now.AddMinutes(minutes)));
                }
                setStatusItem.DropDownItems.Add(choice);
            }
            useTeamsItem = new ToolStripMenuItem(Strings.Get("MenuUseTeamsStatus"), null, (sender, args) => ClearManual());

            var pauseItem = new ToolStripMenuItem(Strings.Get("MenuPause"));
            foreach (var (key, hours) in new[] { ("Pause1h", 1), ("Pause8h", 8), ("Pause1d", 24), ("PauseAlways", 0) })
            {
                pauseItem.DropDownItems.Add(Strings.Get(key), null, (sender, args) =>
                    Pause(hours == 0 ? DateTime.MaxValue : DateTime.Now.AddHours(hours)));
            }
            resumeItem = new ToolStripMenuItem(Strings.Get("MenuResume"), null, (sender, args) => Resume());

            var settingsItem = new ToolStripMenuItem(Strings.Get("MenuSettings"), null, (sender, args) => OpenSettings());
            settingsItem.Font = new Font(settingsItem.Font, FontStyle.Bold);
            var logItem = new ToolStripMenuItem(Strings.Get("MenuOpenLog"), null, (sender, args) =>
            {
                if (System.IO.File.Exists(AppPaths.LogPath)) Process.Start("notepad.exe", $"\"{AppPaths.LogPath}\"");
            });
            var checkUpdatesItem = new ToolStripMenuItem(Strings.Get("MenuCheckUpdates"), null, async (sender, args) => await CheckUpdatesFromMenu());
            updateItem = new ToolStripMenuItem { Visible = false };
            updateItem.Click += async (sender, args) => await UpdateAction();
            var exitItem = new ToolStripMenuItem(Strings.Get("MenuExit"), null, (sender, args) => Exit());

            menu.Items.AddRange(new ToolStripItem[]
            {
                statusItem, activityItem, connectionItem, new ToolStripSeparator(),
                setStatusItem, useTeamsItem, pauseItem, resumeItem, new ToolStripSeparator(),
                settingsItem, logItem, checkUpdatesItem, updateItem, new ToolStripSeparator(),
                exitItem,
            });
            tray.ContextMenuStrip = menu;
            tray.BalloonTipClicked += async (sender, args) => await UpdateAction();
            tray.DoubleClick += (sender, args) => OpenSettings();
            // Show the menu on a left click as well
            tray.MouseUp += (sender, args) =>
            {
                if (args.Button == MouseButtons.Left)
                    typeof(NotifyIcon).GetMethod("ShowContextMenu", BindingFlags.Instance | BindingFlags.NonPublic)?.Invoke(tray, null);
            };

            timer.Tick += (sender, args) => Tick();

            Log.Write(Strings.Format("LogStarted", Environment.MachineName, Environment.UserName));
            Updater.CleanUp();
            UpdateTrayDisplay();
            tray.Visible = true;
            timer.Start();
            if (showSettings || string.IsNullOrEmpty(config.WebhookUrl)) showSettingsEvent.Set();
        }

        // --- Tray icon -------------------------------------------------------

        /// <summary>Brand icon with a colored dot in the lower right corner</summary>
        Icon StatusIcon(string colorKey)
        {
            if (iconCache.TryGetValue(colorKey, out var cached)) return cached;
            const int size = 32;
            using (var bitmap = new Bitmap(size, size))
            {
                using (var graphics = Graphics.FromImage(bitmap))
                {
                    graphics.SmoothingMode = SmoothingMode.AntiAlias;
                    graphics.InterpolationMode = InterpolationMode.HighQualityBicubic;
                    graphics.DrawImage(brandImage, 0, 0, size, size);
                    if (DotColors.TryGetValue(colorKey, out var color))
                    {
                        const int dot = 16;
                        using (var ring = new SolidBrush(Color.White))
                        using (var fill = new SolidBrush(color))
                        {
                            graphics.FillEllipse(ring, size - dot, size - dot, dot, dot);
                            graphics.FillEllipse(fill, size - dot + 2, size - dot + 2, dot - 4, dot - 4);
                        }
                    }
                }
                var icon = Icon.FromHandle(bitmap.GetHicon());
                iconCache[colorKey] = icon;
                return icon;
            }
        }

        static string FormatTime(DateTime time) => time.Date == DateTime.Today ? time.ToString("t") : time.ToString("g");

        bool ManualActive => manual != null && manual.IsActive;

        /// <summary>Status that is sent: the one set from the menu, otherwise the Teams status</summary>
        string EffectiveStatus => ManualActive ? manual.Status : status;

        void UpdateTrayDisplay()
        {
            var effective = EffectiveStatus;
            var statusName = Strings.Status(effective);
            var activityName = Strings.Activity(activity);

            if (ManualActive)
            {
                statusItem.Text = manual.Until == DateTime.MaxValue
                    ? Strings.Format("MenuStatusManualAlways", statusName)
                    : Strings.Format("MenuStatusManual", statusName, FormatTime(manual.Until));
            }
            else
            {
                statusItem.Text = Strings.Format("MenuStatus", statusName);
            }
            if (activity == "in_call" && teamsActivity == "not_in_call")
            {
                var apps = devices.MicrophoneApps.Length > 0 ? string.Join(", ", devices.MicrophoneApps) : "?";
                activityItem.Text = Strings.Format("MenuActivityOther", apps);
            }
            else
            {
                activityItem.Text = Strings.Format("MenuActivity", activityName);
            }
            useTeamsItem.Visible = ManualActive;
            if (string.IsNullOrEmpty(config.WebhookUrl)) connectionItem.Text = Strings.Get("MenuNotConfigured");
            else if (pausedUntil != null)
                connectionItem.Text = pausedUntil == DateTime.MaxValue ? Strings.Get("MenuPausedAlways") : Strings.Format("MenuPausedUntil", FormatTime(pausedUntil.Value));
            else if (away) connectionItem.Text = Strings.Get("MenuAway");
            else if (sendError != null) connectionItem.Text = Strings.Get("MenuSendFailed");
            else connectionItem.Text = Strings.Format("MenuSentAt", lastSent != DateTime.MinValue ? lastSent.ToString("T") : "-");
            resumeItem.Visible = pausedUntil != null;

            var colorKey = effective != null && StatusColorKey.TryGetValue(effective, out var key) ? key : "none";
            if (activity != "not_in_call") colorKey = "busy";
            tray.Icon = StatusIcon(colorKey);

            var tooltip = "Teams Busy Light: " + statusName;
            if (activity != "not_in_call") tooltip += $" ({activityName})";
            if (pausedUntil != null) tooltip += " - " + Strings.Get("TooltipPaused");
            else if (string.IsNullOrEmpty(config.WebhookUrl) || sendError != null) tooltip += " - HA " + Strings.Get("TooltipError");
            // The tooltip of a NotifyIcon is limited to 63 characters
            tray.Text = tooltip.Length > 63 ? tooltip.Substring(0, 63) : tooltip;
        }

        // --- Timer -------------------------------------------------------------

        void Tick()
        {
            try
            {
                if (exitEvent.WaitOne(0))
                {
                    Exit();
                    return;
                }
                // Not while the network question is open; the request waits until it is answered
                if (!askingNetwork && showSettingsEvent.WaitOne(0)) OpenSettings();
                if (pausedUntil != null && pausedUntil != DateTime.MaxValue && DateTime.Now >= pausedUntil) Resume();
                if (manual != null && !manual.IsActive) ClearManual();
                if ((DateTime.Now - lastPoll).TotalSeconds >= config.PollSeconds)
                {
                    lastPoll = DateTime.Now;
                    UpdateState();
                }
                if (UpdateNetworkState()) AskForNewNetwork();
                Send();
                CheckForUpdates();
                if (updateInstaller != null && updateInstaller.HasExited)
                {
                    // Still running after the installer has finished: it failed
                    updateInstaller = null;
                    StopUpdate(Strings.Get("UpdateInstallerFailed"));
                }
            }
            catch (Exception exception)
            {
                Log.Write(exception.Message);
            }
        }

        void UpdateState()
        {
            var current = TeamsMonitor.Read(config.TeamsLanguage);
            if (current.Running && !current.LogFound)
            {
                if (!logMissing) Log.Write(Strings.Format("LogNoLogs", AppPaths.TeamsLogFolder));
                logMissing = true;
            }
            else
            {
                logMissing = false;
            }
            if (current.Language != null && current.Language != language)
            {
                Log.Write(Strings.Format("LogLanguage", current.Language));
                language = current.Language;
            }

            var changed = false;
            // Keep the previous value when the log does not contain one
            if (current.Status != null && current.Status != status)
            {
                status = current.Status;
                changed = true;
            }
            if (current.Activity != null) teamsActivity = current.Activity;

            var previous = devices;
            devices = DeviceUsage.Read();
            if (devices.Camera != previous.Camera)
            {
                if (devices.Camera == true)
                {
                    Log.Write(devices.CameraApps.Length > 0 ? Strings.Format("LogCameraOn", string.Join(", ", devices.CameraApps)) : Strings.Get("LogCameraOnNoApp"));
                }
                else if (previous.Camera == true)
                {
                    Log.Write(Strings.Get("LogCameraOff"));
                }
                changed = true;
            }
            var microphoneApps = string.Join(", ", devices.MicrophoneApps);
            if (devices.Microphone != previous.Microphone || (devices.Microphone == true && microphoneApps != string.Join(", ", previous.MicrophoneApps)))
            {
                if (devices.Microphone != null)
                    Log.Write(devices.Microphone == true ? Strings.Format("LogMicrophoneOn", microphoneApps) : Strings.Get("LogMicrophoneOff"));
                changed = true;
            }

            var newActivity = teamsActivity;
            if (newActivity == "not_in_call" && config.DetectOtherCalls && devices.Microphone == true) newActivity = "in_call";
            if (newActivity != activity)
            {
                activity = newActivity;
                changed = true;
            }
            if (changed)
            {
                // Only when status or activity changed, not for camera/microphone alone
                var line = Strings.Format("LogStatus", EffectiveStatus, activity);
                if (line != loggedStatus)
                {
                    Log.Write(line);
                    loggedStatus = line;
                }
                UpdateTrayDisplay();
            }
        }

        /// <summary>Resets the sending, so the current state is sent right away</summary>
        void SendNow()
        {
            sentKey = null;
            retryAfter = DateTime.MinValue;
        }

        async void Send()
        {
            var effective = EffectiveStatus;
            if (string.IsNullOrEmpty(config.WebhookUrl) || away || pausedUntil != null || sending || effective == null) return;
            var source = ManualActive ? "manual" : "teams";
            var key = $"{effective}|{activity}|{devices.Camera}|{devices.Microphone}|{source}";
            var now = DateTime.Now;
            var due = (now - lastSent).TotalSeconds >= config.HeartbeatSeconds;
            if ((key == sentKey && !due) || now < retryAfter) return;

            var extra = new Dictionary<string, object> { ["source"] = source };
            // Unknown values are left out, Home Assistant then keeps the sensor unknown
            if (devices.Camera != null) extra["camera"] = devices.Camera.Value;
            if (devices.Microphone != null) extra["microphone"] = devices.Microphone.Value;
            sending = true;
            string error;
            try
            {
                pendingSend = Sender.SendAsync(http, config.WebhookUrl, effective, activity, language, extra);
                error = await pendingSend;
            }
            finally
            {
                sending = false;
                pendingSend = null;
            }
            if (away || pausedUntil != null) return;
            if (error != null)
            {
                if (error != sendError) Log.Write(Strings.Format("LogSendFailed", error));
                sendError = error;
                retryAfter = DateTime.Now.AddSeconds(10);
            }
            else
            {
                if (sendError != null) Log.Write(Strings.Get("LogSendOk"));
                sendError = null;
                sentKey = key;
                lastSent = DateTime.Now;
            }
            UpdateTrayDisplay();
        }

        // --- Manual status and pause ---------------------------------------------

        void SetManual(string manualStatus, DateTime until)
        {
            manual = new ManualStatus { Status = manualStatus, Until = until };
            Settings.SaveManualStatus(manual);
            Log.Write(until == DateTime.MaxValue
                ? Strings.Format("LogManualStatusAlways", manualStatus)
                : Strings.Format("LogManualStatus", manualStatus, until.ToString("g")));
            SendNow();
            UpdateTrayDisplay();
        }

        void ClearManual()
        {
            if (manual == null) return;
            manual = null;
            Settings.SaveManualStatus(null);
            Log.Write(Strings.Get("LogManualEnded"));
            SendNow();
            UpdateTrayDisplay();
        }

        /// <summary>Pauses sending from the tray menu; Home Assistant gets "offline" once</summary>
        void Pause(DateTime until)
        {
            var tellHomeAssistant = !string.IsNullOrEmpty(config.WebhookUrl) && !away && pausedUntil == null;
            pausedUntil = until;
            Settings.SavePause(until);
            Log.Write(until == DateTime.MaxValue ? Strings.Get("LogPausedAlways") : Strings.Format("LogPaused", until.ToString("g")));
            if (tellHomeAssistant)
            {
                // Not awaited; the result is not needed
                _ = SendOfflineAfter(pendingSend, config.WebhookUrl);
            }
            sendError = null;
            UpdateTrayDisplay();
        }

        /// <summary>
        /// Sends "offline" for a pause once the send on its way has finished,
        /// so the older status cannot arrive after it
        /// </summary>
        async Task SendOfflineAfter(Task<string> previous, string webhookUrl)
        {
            try
            {
                if (previous != null) await previous;
            }
            catch (Exception)
            {
                // Its result does not matter here
            }
            // Resumed in the meantime: the current status is sent instead
            if (pausedUntil == null) return;
            try
            {
                await Sender.SendAsync(http, webhookUrl, "offline", "not_in_call", null, Sender.OfflineExtra(devices.Camera));
            }
            catch (Exception exception)
            {
                Log.Write(exception.Message);
            }
        }

        void Resume()
        {
            pausedUntil = null;
            Settings.SavePause(null);
            Log.Write(Strings.Get("LogResumed"));
            SendNow();
            UpdateTrayDisplay();
        }

        // --- Networks ------------------------------------------------------------

        /// <summary>
        /// Pauses sending outside the networks set under "Send only in these
        /// networks"; Home Assistant then sets Teams offline after its timeout.
        /// Checks at most every 5 seconds; true when it checked.
        /// </summary>
        bool UpdateNetworkState()
        {
            if ((DateTime.Now - lastNetworkCheck).TotalSeconds < 5) return false;
            lastNetworkCheck = DateTime.Now;
            var isAway = !HomeNetwork.IsHome(config.HomeNetworks);
            if (isAway == away) return true;
            away = isAway;
            if (away)
            {
                Log.Write(Strings.Get("LogAway"));
                sendError = null;
            }
            else
            {
                Log.Write(Strings.Get("LogHome"));
                SendNow();
            }
            UpdateTrayDisplay();
            return true;
        }

        /// <summary>
        /// Asks whether to add a network the PC is in that is not a home network
        /// yet. "No" remembers the network, so it is asked only once.
        /// </summary>
        void AskForNewNetwork()
        {
            if (!away || !config.AskForNewNetworks || askingNetwork || settingsOpen) return;
            var network = HomeNetwork.New(config.HomeNetworks, config.IgnoredNetworks).FirstOrDefault();
            if (network == null) return;
            askingNetwork = true;
            try
            {
                switch (Ui.Message(Strings.Format("NewNetworkText", network), MessageBoxButtons.YesNoCancel, MessageBoxIcon.Question))
                {
                    case DialogResult.Yes:
                        config.HomeNetworks = HomeNetwork.Add(config.HomeNetworks, new[] { network });
                        Log.Write(Strings.Format("LogNetworkAdded", network));
                        break;
                    case DialogResult.No:
                        config.IgnoredNetworks = HomeNetwork.Add(config.IgnoredNetworks, new[] { network });
                        Log.Write(Strings.Format("LogNetworkIgnored", network));
                        break;
                    default:
                        config.AskForNewNetworks = false;
                        Log.Write(Strings.Get("LogNetworkAskOff"));
                        break;
                }
                config.Save();
                lastNetworkCheck = DateTime.MinValue;
            }
            finally
            {
                askingNetwork = false;
            }
        }

        // --- Settings ------------------------------------------------------------

        void OpenSettings()
        {
            // Not while the network question is open: saving would drop its answer
            if (settingsOpen || askingNetwork) return;
            settingsOpen = true;
            try
            {
                var result = SettingsForm.ShowDialog(config, Installer.GetAutostart(), diagnostics: () => Diagnostics.Text(this),
                    checkUpdates: preReleases => CheckUpdatesNow(preReleases));
                if (result == null) return;
                result.Settings.Save();
                Installer.SetAutostart(result.Autostart);
                config = Settings.Load();
                // Send right away to the (possibly new) webhook
                SendNow();
                sendError = null;
                lastPoll = DateTime.MinValue;
                lastNetworkCheck = DateTime.MinValue;
                UpdateTrayDisplay();
            }
            finally
            {
                settingsOpen = false;
            }
        }

        // --- Updates -------------------------------------------------------------
        // Checks the latest GitHub release once a day. If its Windows download
        // can be checked (pinned certificate), the menu offers to install it;
        // otherwise it only links to the release page. Nothing is installed
        // without confirmation.

        void SetUpdateItem()
        {
            if (updating) updateItem.Text = Strings.Format("MenuUpdating", updateVersion);
            else if (updateDowngrade) updateItem.Text = Strings.Format("MenuDowngrade", updateVersion);
            else if (updateAssetUrl != null) updateItem.Text = Strings.Format("MenuInstallUpdate", updateVersion);
            else updateItem.Text = Strings.Format("MenuUpdate", updateVersion);
            updateItem.Enabled = !updating;
            updateItem.Visible = updateVersion != null;
        }

        static string ReleasesApi(bool preReleases) => preReleases ? AppPaths.ReleasesListApi : AppPaths.ReleasesApi;

        /// <summary>
        /// Applies the answer of the GitHub API. Returns the latest version; a
        /// newer one is offered in the menu, with a notification unless quiet
        /// (the user asked and gets an answer anyway). Evaluated on every check,
        /// so a download added to the release later (or a switch of the
        /// channel) is picked up.
        /// </summary>
        string ApplyLatestRelease(string json, bool preReleases, bool quiet)
        {
            var release = UpdateChecker.SelectNewest(json) ?? throw new InvalidOperationException("no version in the answer of GitHub");
            updatePreReleases = preReleases;
            if (updating) return release.Version;
            var offer = UpdateChecker.Offer(release.Version, AppPaths.Version, preReleases);
            var version = offer != null ? release.Version : null;
            // Install from the app only if the download can be checked
            var assetUrl = offer != null && AppPaths.SigningCertificateSha256.Length > 0 && UpdateChecker.CanInstall(release.Version)
                ? release.AssetUrl : null;
            var downgrade = offer == "downgrade";
            if (version != updateVersion || assetUrl != updateAssetUrl || downgrade != updateDowngrade)
            {
                updateVersion = version;
                updateAssetUrl = assetUrl;
                updatePage = offer != null ? release.Page : null;
                updateDowngrade = downgrade;
                SetUpdateItem();
                if (version != null)
                {
                    Log.Write($"{(downgrade ? "Back to the release" : "Update available")}: {version}{(assetUrl != null ? " (can be installed from the app)" : "")}");
                    // No notification for going back: the user switched the channel
                    if (!quiet && !downgrade)
                    {
                        tray.ShowBalloonTip(10000, AppPaths.AppName,
                            Strings.Format(assetUrl != null ? "UpdateBalloonInstall" : "UpdateBalloon", version), ToolTipIcon.Info);
                    }
                }
            }
            return release.Version;
        }

        /// <summary>"Check for updates" in the menu and the settings: asks GitHub right away (also when the daily check is off)</summary>
        async Task<UpdateCheckResult> CheckUpdatesNow(bool preReleases)
        {
            var result = new UpdateCheckResult();
            try
            {
                var json = await updateHttp.GetStringAsync(ReleasesApi(preReleases));
                result.Latest = ApplyLatestRelease(json, preReleases, true);
                var offer = UpdateChecker.Offer(result.Latest, AppPaths.Version, preReleases);
                result.Newer = offer != null;
                result.Downgrade = offer == "downgrade";
                lastUpdateCheck = DateTime.Now;
            }
            catch (Exception exception)
            {
                result.Error = exception.GetBaseException().Message;
                Log.Write("Update check failed: " + result.Error);
            }
            return result;
        }

        async Task CheckUpdatesFromMenu()
        {
            var result = await CheckUpdatesNow(config.PreReleases);
            if (result.Error != null) Ui.Message(Strings.Format("UpdateCheckFailed", result.Error), icon: MessageBoxIcon.Warning);
            // Asks whether to install it, or opens the release page
            else if (result.Newer) await UpdateAction();
            else Ui.Message(Strings.Format("UpdateCheckLatest", AppPaths.Version));
        }

        /// <summary>The daily check</summary>
        async void CheckForUpdates()
        {
            if (updateChecking) return;
            var preReleases = config.PreReleases;
            if (!config.CheckForUpdates || AppPaths.Version == "0.0.0")
            {
                // Without the daily check, an offer from the other channel is dropped
                if (updatePreReleases != null && updatePreReleases != preReleases && !updating)
                {
                    updatePreReleases = null;
                    updateVersion = null;
                    updateAssetUrl = null;
                    updateDowngrade = false;
                    SetUpdateItem();
                }
                return;
            }
            // Checks again right away when the channel was changed
            if ((DateTime.Now - lastUpdateCheck).TotalHours < 24 && updatePreReleases == preReleases) return;
            lastUpdateCheck = DateTime.Now;
            updatePreReleases = preReleases;
            updateChecking = true;
            try
            {
                ApplyLatestRelease(await updateHttp.GetStringAsync(ReleasesApi(preReleases)), preReleases, false);
            }
            catch (Exception exception)
            {
                Log.Write("Update check failed: " + exception.GetBaseException().Message);
            }
            finally
            {
                updateChecking = false;
            }
        }

        async Task UpdateAction()
        {
            if (updateVersion == null || updating) return;
            if (updateAssetUrl == null)
            {
                Process.Start(updatePage ?? AppPaths.ReleasesPage);
                return;
            }
            if (Ui.Message(Strings.Format("UpdateConfirm", updateVersion), MessageBoxButtons.YesNo, MessageBoxIcon.Question) != DialogResult.Yes) return;
            Log.Write($"Downloading update {updateVersion}");
            updating = true;
            SetUpdateItem();
            try
            {
                var bytes = await updateHttp.GetByteArrayAsync(updateAssetUrl);
                var version = updateVersion;
                updateInstaller = await Task.Run(() => Updater.Install(bytes, version));
            }
            catch (Exception exception)
            {
                StopUpdate(exception.GetBaseException().Message);
            }
        }

        void StopUpdate(string reason)
        {
            Log.Write($"Update to {updateVersion} failed: {reason}");
            updating = false;
            updateInstaller = null;
            SetUpdateItem();
            Ui.Message(Strings.Format("UpdateFailed", updateVersion, reason), icon: MessageBoxIcon.Warning);
        }

        // --- Diagnostics ---------------------------------------------------------

        internal sealed class Snapshot
        {
            public Settings Config;
            public string Status, TeamsActivity, Activity, Language, EffectiveStatus, SendError, UpdateVersion;
            public ManualStatus Manual;
            public DeviceState Devices;
            public bool LogMissing, Away;
            public DateTime? PausedUntil;
            public DateTime LastSent;
        }

        internal Snapshot TakeSnapshot() => new Snapshot
        {
            Config = config,
            Status = status,
            TeamsActivity = teamsActivity,
            Activity = activity,
            Language = language,
            EffectiveStatus = EffectiveStatus,
            SendError = sendError,
            UpdateVersion = updateVersion,
            Manual = ManualActive ? manual : null,
            Devices = devices,
            LogMissing = logMissing,
            Away = away,
            PausedUntil = pausedUntil,
            LastSent = lastSent,
        };

        // --- Exit ----------------------------------------------------------------

        void Exit()
        {
            timer.Stop();
            try
            {
                // Tell Home Assistant right away instead of waiting for the timeout;
                // not when stopped for an update, the new version sends right after starting
                if (!string.IsNullOrEmpty(config.WebhookUrl) && pausedUntil == null && !updating && HomeNetwork.IsHome(config.HomeNetworks))
                {
                    Sender.Send(config.WebhookUrl, "offline", "not_in_call", Sender.OfflineExtra(devices.Camera), 3);
                }
            }
            catch (Exception exception)
            {
                // Exit anyway, an update waits for this process to end
                Log.Write(exception.Message);
            }
            tray.Visible = false;
            ExitThread();
        }

        protected override void Dispose(bool disposing)
        {
            if (disposing)
            {
                timer.Dispose();
                tray.Dispose();
                http.Dispose();
                updateHttp.Dispose();
                brandImage.Dispose();
            }
            base.Dispose(disposing);
        }
    }
}
