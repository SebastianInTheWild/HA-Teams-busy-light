using System;
using System.Collections.Generic;
using System.Drawing;
using System.Linq;
using System.Threading.Tasks;
using System.Windows.Forms;

namespace TeamsBusyLight
{
    /// <summary>Result of the settings window</summary>
    internal sealed class SettingsResult
    {
        public Settings Settings;
        public bool Autostart;
        public bool AddHosts;
    }

    /// <summary>Result of "Check for updates"</summary>
    internal sealed class UpdateCheckResult
    {
        public string Latest;
        public bool Newer;
        public bool Downgrade;
        public string Error;
    }

    /// <summary>
    /// Settings window, also used as the installer window. Tabs like the macOS
    /// app: General, Detection, Networks. New settings go into the fitting tab,
    /// so the window keeps its height.
    /// </summary>
    internal sealed class SettingsForm : Form
    {
        const int FormWidth = 660;
        const int Margin_ = 24;
        const int InnerWidth = FormWidth - 2 * Margin_;
        const int PageMargin = 16;
        // A tab page is about 8 px narrower than the TabControl (border); the
        // DisplayRectangle is not reliable before the window is shown
        const int PageWidth = InnerWidth - 8 - 2 * PageMargin;
        const int ColumnWidth = (PageWidth - 16) / 2;
        const int SecondColumn = PageMargin + ColumnWidth + 16;

        static readonly Color TextColor = Color.FromArgb(45, 55, 72);
        static readonly Color HintColor = Color.FromArgb(105, 115, 130);
        static readonly Color ErrorColor = Color.FromArgb(170, 40, 40);
        static readonly Color SuccessColor = Color.FromArgb(30, 120, 60);
        static readonly Color LinkColor = Color.FromArgb(45, 80, 145);
        static readonly Color BorderColor = Color.FromArgb(205, 213, 224);

        readonly Settings settings;
        readonly bool install;
        readonly Func<string> diagnostics;
        readonly Func<bool, Task<UpdateCheckResult>> checkUpdates;

        TabControl tabs;
        TabPage generalPage, networksPage;
        TextBox webhookInput, networksInput;
        CheckBox autostartInput, updatesInput, hostsInput, otherCallsInput, askNetworksInput;
        ComboBox channelInput, languageInput;
        NumericUpDown heartbeatInput, pollInput;
        Button testButton, checkUpdatesButton, diagnosticsButton, networkButton;
        Label testResult, checkUpdatesResult, diagnosticsResult;
        int y;

        SettingsResult result;

        /// <summary>Shows the window; null when cancelled</summary>
        public static SettingsResult ShowDialog(Settings settings, bool autostart, bool install = false,
            Func<string> diagnostics = null, Func<bool, Task<UpdateCheckResult>> checkUpdates = null)
        {
            using (var form = new SettingsForm(settings, autostart, install, diagnostics, checkUpdates))
            {
                form.ShowDialog();
                return form.result;
            }
        }

        SettingsForm(Settings settings, bool autostart, bool install, Func<string> diagnostics, Func<bool, Task<UpdateCheckResult>> checkUpdates)
        {
            this.settings = settings;
            this.install = install;
            this.diagnostics = diagnostics;
            this.checkUpdates = checkUpdates;

            SuspendLayout();
            Text = Strings.Get(install ? "InstallTitle" : "SettingsTitle");
            StartPosition = FormStartPosition.CenterScreen;
            FormBorderStyle = FormBorderStyle.FixedDialog;
            MaximizeBox = false;
            MinimizeBox = false;
            ShowInTaskbar = true;
            TopMost = true;
            BackColor = Color.FromArgb(245, 247, 250);
            Font = Ui.NewFont(9);
            AutoScaleMode = AutoScaleMode.Dpi;
            AutoScaleDimensions = new SizeF(96F, 96F);
            Icon = Ui.AppIcon;

            BuildHeader();
            y = 104;
            if (install)
            {
                var card = AddCard(Strings.Get("InstallInfo"), Color.FromArgb(232, 240, 255), Color.FromArgb(40, 65, 105));
                y = card.Bottom + 16;
            }

            tabs = new TabControl { Location = new Point(Margin_, y), Size = new Size(InnerWidth, 400), Padding = new Point(16, 5) };
            Controls.Add(tabs);
            generalPage = NewPage("TabGeneral");
            var detectionPage = NewPage("TabDetection");
            networksPage = NewPage("TabNetworks");
            var heights = new List<int>
            {
                BuildGeneral(generalPage, autostart),
                BuildDetection(detectionPage),
                BuildNetworks(networksPage),
            };
            // As high as the tallest page, plus tab headers and border (ItemSize
            // is not known yet before the window is shown)
            tabs.Height = heights.Max() + 40;
            BuildButtons(tabs.Bottom + 20);
            ResumeLayout();

            Shown += (sender, args) =>
            {
                Activate();
                webhookInput.Focus();
            };
        }

        void BuildHeader()
        {
            var header = new Panel { Location = new Point(0, 0), Size = new Size(FormWidth, 88), BackColor = Color.FromArgb(25, 45, 70) };
            Controls.Add(header);
            header.Controls.Add(new PictureBox
            {
                Location = new Point(Margin_, 20),
                Size = new Size(48, 48),
                SizeMode = PictureBoxSizeMode.Zoom,
                Image = Ui.BrandImage(96),
            });
            header.Controls.Add(new Label
            {
                Location = new Point(88, 16),
                Size = new Size(540, 32),
                Text = Strings.Get("AppName"),
                Font = Ui.NewFont(16, true),
                ForeColor = Color.White,
            });
            header.Controls.Add(new Label
            {
                Location = new Point(90, 50),
                Size = new Size(540, 22),
                Text = Strings.Get("Subtitle"),
                ForeColor = Color.FromArgb(205, 216, 232),
            });
        }

        /// <summary>A text card (info or warning) over the full width</summary>
        Label AddCard(string text, Color back, Color fore)
        {
            var card = new Label
            {
                Location = new Point(Margin_, y),
                Padding = new Padding(12, 10, 12, 10),
                BackColor = back,
                ForeColor = fore,
                Text = text,
            };
            Controls.Add(card);
            // Full width, as high as the wrapped text needs
            var size = TextRenderer.MeasureText(text, card.Font, new Size(InnerWidth - 44, 0), TextFormatFlags.WordBreak);
            card.Size = new Size(InnerWidth, size.Height + 22);
            return card;
        }

        TabPage NewPage(string key)
        {
            var page = new TabPage(Strings.Get(key)) { UseVisualStyleBackColor = true };
            tabs.TabPages.Add(page);
            return page;
        }

        static Label AddLabel(Control parent, string text, int x, int top, int width, bool hint = false)
        {
            var label = new Label { Location = new Point(x, top), Text = text };
            if (hint)
            {
                label.ForeColor = HintColor;
                label.MaximumSize = new Size(width, 0);
                label.AutoSize = true;
            }
            else
            {
                label.Size = new Size(width, 20);
                label.Font = Ui.NewFont(9, true);
                label.ForeColor = TextColor;
            }
            parent.Controls.Add(label);
            return label;
        }

        static CheckBox AddCheckBox(Control parent, string text, int top, bool isChecked)
        {
            var box = new CheckBox { Location = new Point(PageMargin, top), Size = new Size(PageWidth, 24), Text = text, Checked = isChecked };
            parent.Controls.Add(box);
            return box;
        }

        static Button AddButton(Control parent, string text, int x, int top, int width)
        {
            var button = new Button
            {
                Location = new Point(x, top),
                Size = new Size(width, 32),
                Text = text,
                FlatStyle = FlatStyle.Flat,
                BackColor = Color.White,
                ForeColor = LinkColor,
            };
            button.FlatAppearance.BorderColor = BorderColor;
            parent.Controls.Add(button);
            return button;
        }

        static Label AddResult(Control parent, int x, int top)
        {
            var label = new Label
            {
                Location = new Point(x, top + 2),
                Size = new Size(PageMargin + PageWidth - x, 30),
                TextAlign = ContentAlignment.MiddleLeft,
                AutoEllipsis = true,
            };
            parent.Controls.Add(label);
            return label;
        }

        static NumericUpDown AddNumber(Control parent, int x, int top, int value, int minimum, int maximum)
        {
            var number = new NumericUpDown
            {
                Location = new Point(x, top),
                Size = new Size(90, 27),
                Minimum = minimum,
                Maximum = maximum,
                Value = Math.Min(Math.Max(value, minimum), maximum),
            };
            parent.Controls.Add(number);
            return number;
        }

        static TextBox AddTextBox(Control parent, int x, int top, int width, string text)
        {
            var box = new TextBox
            {
                Location = new Point(x, top),
                Size = new Size(width, 27),
                Font = Ui.NewFont(10),
                BorderStyle = BorderStyle.FixedSingle,
                Text = text,
            };
            parent.Controls.Add(box);
            return box;
        }

        static ComboBox AddComboBox(Control parent, int top, string[] items, int selected)
        {
            var box = new ComboBox { Location = new Point(PageMargin, top), Size = new Size(ColumnWidth, 27), DropDownStyle = ComboBoxStyle.DropDownList };
            box.Items.AddRange(items);
            box.SelectedIndex = selected;
            parent.Controls.Add(box);
            return box;
        }

        // --- General: webhook with test, autostart, updates (installer: hosts file)
        int BuildGeneral(TabPage page, bool autostart)
        {
            var top = 16;
            AddLabel(page, Strings.Get("Webhook"), PageMargin, top, PageWidth);
            top += 24;
            webhookInput = AddTextBox(page, PageMargin, top, PageWidth, settings.WebhookUrl);
            top = webhookInput.Bottom + 4;
            top = AddLabel(page, Strings.Get("WebhookHint"), PageMargin, top, PageWidth, true).Bottom + 10;
            testButton = AddButton(page, Strings.Get("Test"), PageMargin, top, 130);
            testResult = AddResult(page, PageMargin + 142, top);
            testButton.Click += async (sender, args) => await TestWebhook();
            top = testButton.Bottom + 18;

            autostartInput = AddCheckBox(page, Strings.Get("Autostart"), top, autostart);
            top = autostartInput.Bottom + 2;
            updatesInput = AddCheckBox(page, Strings.Get("CheckForUpdates"), top, settings.CheckForUpdates);
            top = updatesInput.Bottom + 10;
            // Update channel: 0 = release, 1 = beta (also pre-releases)
            AddLabel(page, Strings.Get("UpdateChannel"), PageMargin, top, PageWidth);
            top += 24;
            channelInput = AddComboBox(page, top, new[] { Strings.Get("UpdateChannelRelease"), Strings.Get("UpdateChannelBeta") }, settings.PreReleases ? 1 : 0);
            // A result of "Check for updates" belongs to the channel it was made with
            channelInput.SelectedIndexChanged += (sender, args) =>
            {
                if (checkUpdatesResult != null) checkUpdatesResult.Text = "";
            };
            top = channelInput.Bottom + 4;
            top = AddLabel(page, Strings.Get("UpdateChannelHint"), PageMargin, top, PageWidth, true).Bottom + 10;
            if (checkUpdates != null)
            {
                checkUpdatesButton = AddButton(page, Strings.Get("CheckUpdatesNow"), PageMargin, top, 170);
                checkUpdatesResult = AddResult(page, PageMargin + 182, top);
                checkUpdatesButton.Click += async (sender, args) => await CheckUpdates();
                top = checkUpdatesButton.Bottom + 6;
            }
            if (install)
            {
                hostsInput = AddCheckBox(page, Strings.Get("InstallHosts"), top, false);
                top = hostsInput.Bottom;
                top = AddLabel(page, Strings.Get("InstallHostsHint"), PageMargin + 18, top, PageWidth - 18, true).Bottom + 6;
            }
            return top + 10;
        }

        // --- Detection: other calls, intervals, Teams language, diagnostics
        int BuildDetection(TabPage page)
        {
            var top = 16;
            otherCallsInput = AddCheckBox(page, Strings.Get("DetectOtherCalls"), top, settings.DetectOtherCalls);
            top = otherCallsInput.Bottom;
            top = AddLabel(page, Strings.Get("DetectOtherCallsHint"), PageMargin + 18, top, PageWidth - 18, true).Bottom + 16;

            AddLabel(page, Strings.Get("Heartbeat"), PageMargin, top, ColumnWidth);
            AddLabel(page, Strings.Get("Poll"), SecondColumn, top, ColumnWidth);
            top += 24;
            heartbeatInput = AddNumber(page, PageMargin, top, settings.HeartbeatSeconds, 10, 3600);
            pollInput = AddNumber(page, SecondColumn, top, settings.PollSeconds, 1, 60);
            top = heartbeatInput.Bottom + 4;
            top = AddLabel(page, Strings.Get("HeartbeatHint"), PageMargin, top, PageWidth, true).Bottom + 16;

            AddLabel(page, Strings.Get("TeamsLanguage"), PageMargin, top, PageWidth);
            top += 24;
            languageInput = AddComboBox(page, top,
                new[] { Strings.Get("TeamsLanguageAuto"), Strings.Get("TeamsLanguageDe"), Strings.Get("TeamsLanguageEn") },
                Math.Max(Array.IndexOf(Settings.TeamsLanguages, settings.TeamsLanguage), 0));
            top = languageInput.Bottom + 16;

            if (diagnostics != null)
            {
                diagnosticsButton = AddButton(page, Strings.Get("CopyDiagnostics"), PageMargin, top, 170);
                diagnosticsResult = AddResult(page, PageMargin + 182, top);
                diagnosticsButton.Click += (sender, args) => CopyDiagnostics();
                top = diagnosticsButton.Bottom + 4;
                top = AddLabel(page, Strings.Get("DiagnosticsHint"), PageMargin, top, PageWidth, true).Bottom + 6;
            }
            return top + 10;
        }

        // --- Networks: send only in these networks
        int BuildNetworks(TabPage page)
        {
            var top = 16;
            AddLabel(page, Strings.Get("HomeNetworks"), PageMargin, top, PageWidth);
            top += 24;
            const int buttonWidth = 190;
            networksInput = AddTextBox(page, PageMargin, top, PageWidth - buttonWidth - 10, settings.HomeNetworks);
            networkButton = AddButton(page, Strings.Get("AddCurrentNetwork"), PageMargin + PageWidth - buttonWidth, top - 2, buttonWidth);
            networkButton.Click += (sender, args) =>
            {
                var current = HomeNetwork.Current();
                if (current.Length == 0)
                {
                    MessageBox.Show(this, Strings.Get("NoCurrentNetwork"), Strings.Get("AppName"));
                    return;
                }
                networksInput.Text = HomeNetwork.Add(networksInput.Text, current);
            };
            top = networksInput.Bottom + 4;
            top = AddLabel(page, Strings.Get("HomeNetworksHint"), PageMargin, top, PageWidth, true).Bottom + 8;
            askNetworksInput = AddCheckBox(page, Strings.Get("AskForNewNetworks"), top, settings.AskForNewNetworks);
            return askNetworksInput.Bottom + 10;
        }

        void BuildButtons(int top)
        {
            var okButton = new Button
            {
                Size = new Size(124, 36),
                Location = new Point(FormWidth - Margin_ - 124, top),
                Text = Strings.Get(install ? "Install" : "Save"),
                FlatStyle = FlatStyle.Flat,
                BackColor = Color.FromArgb(45, 100, 210),
                ForeColor = Color.White,
                Font = Ui.NewFont(9, true),
            };
            okButton.FlatAppearance.BorderSize = 0;
            okButton.Click += (sender, args) => Accept();
            Controls.Add(okButton);

            var cancelButton = new Button
            {
                Size = new Size(114, 36),
                Location = new Point(okButton.Left - 124, top),
                Text = Strings.Get("Cancel"),
                DialogResult = DialogResult.Cancel,
                FlatStyle = FlatStyle.Flat,
                BackColor = Color.White,
                ForeColor = Color.FromArgb(55, 65, 80),
            };
            cancelButton.FlatAppearance.BorderColor = BorderColor;
            Controls.Add(cancelButton);

            var version = AppPaths.Version;
            if (version != "0.0.0")
            {
                Controls.Add(new Label
                {
                    Location = new Point(Margin_, top + 9),
                    Size = new Size(200, 20),
                    Text = Strings.Format("Version", version),
                    ForeColor = HintColor,
                });
            }

            ClientSize = new Size(FormWidth, okButton.Bottom + Margin_);
            AcceptButton = okButton;
            CancelButton = cancelButton;
        }

        void ShowInvalid(string text) =>
            MessageBox.Show(this, text, Strings.Get("InvalidTitle"), MessageBoxButtons.OK, MessageBoxIcon.Warning);

        void Accept()
        {
            var url = webhookInput.Text.Trim();
            if (!Settings.IsValidWebhookUrl(url))
            {
                tabs.SelectedTab = generalPage;
                ShowInvalid(Strings.Get("InvalidWebhook"));
                return;
            }
            var networks = networksInput.Text.Trim();
            var invalid = HomeNetwork.FindInvalid(networks);
            if (invalid != null)
            {
                tabs.SelectedTab = networksPage;
                ShowInvalid(Strings.Format("InvalidNetwork", invalid));
                return;
            }
            var saved = settings.Clone();
            saved.WebhookUrl = url;
            saved.HeartbeatSeconds = (int)heartbeatInput.Value;
            saved.PollSeconds = (int)pollInput.Value;
            saved.TeamsLanguage = Settings.TeamsLanguages[languageInput.SelectedIndex];
            saved.CheckForUpdates = updatesInput.Checked;
            saved.PreReleases = channelInput.SelectedIndex == 1;
            saved.HomeNetworks = networks;
            saved.AskForNewNetworks = askNetworksInput.Checked;
            saved.DetectOtherCalls = otherCallsInput.Checked;
            result = new SettingsResult { Settings = saved, Autostart = autostartInput.Checked, AddHosts = hostsInput != null && hostsInput.Checked };
            DialogResult = DialogResult.OK;
            Close();
        }

        async Task TestWebhook()
        {
            var url = webhookInput.Text.Trim();
            if (!Settings.IsValidWebhookUrl(url))
            {
                ShowInvalid(Strings.Get("InvalidWebhook"));
                return;
            }
            testButton.Enabled = false;
            testResult.ForeColor = HintColor;
            testResult.Text = Strings.Get("Testing");
            UseWaitCursor = true;
            try
            {
                var language = Settings.TeamsLanguages[languageInput.SelectedIndex];
                var current = await Task.Run(() => TeamsMonitor.Read(language));
                string error;
                using (var client = Sender.NewClient(10))
                {
                    error = await Sender.SendAsync(client, url, current.Status, current.Activity ?? "not_in_call", current.Language);
                }
                if (IsDisposed) return;
                if (error != null)
                {
                    testResult.ForeColor = ErrorColor;
                    testResult.Text = Strings.Format("TestFailed", error);
                }
                else
                {
                    testResult.ForeColor = SuccessColor;
                    testResult.Text = Strings.Format("TestOk", Strings.Status(current.Status));
                }
            }
            finally
            {
                if (!IsDisposed)
                {
                    UseWaitCursor = false;
                    testButton.Enabled = true;
                }
            }
        }

        async Task CheckUpdates()
        {
            checkUpdatesButton.Enabled = false;
            checkUpdatesResult.ForeColor = HintColor;
            checkUpdatesResult.Text = Strings.Get("UpdateChecking");
            UseWaitCursor = true;
            try
            {
                // With the channel as chosen in the window, also before saving
                var check = await checkUpdates(channelInput.SelectedIndex == 1);
                if (IsDisposed) return;
                if (check.Error != null)
                {
                    checkUpdatesResult.ForeColor = ErrorColor;
                    checkUpdatesResult.Text = Strings.Format("UpdateCheckFailed", check.Error);
                }
                else if (check.Newer)
                {
                    // Installed from the menu: the app restarts, open settings would be lost
                    checkUpdatesResult.ForeColor = LinkColor;
                    checkUpdatesResult.Text = Strings.Format(check.Downgrade ? "UpdateCheckDowngrade" : "UpdateCheckAvailable", check.Latest);
                }
                else
                {
                    checkUpdatesResult.ForeColor = SuccessColor;
                    checkUpdatesResult.Text = Strings.Format("UpdateCheckLatest", AppPaths.Version);
                }
            }
            finally
            {
                if (!IsDisposed)
                {
                    UseWaitCursor = false;
                    checkUpdatesButton.Enabled = true;
                }
            }
        }

        void CopyDiagnostics()
        {
            try
            {
                Clipboard.SetText(diagnostics());
                diagnosticsResult.ForeColor = SuccessColor;
                diagnosticsResult.Text = Strings.Get("DiagnosticsCopied");
            }
            catch (Exception exception)
            {
                diagnosticsResult.ForeColor = ErrorColor;
                diagnosticsResult.Text = exception.Message;
            }
        }
    }
}
