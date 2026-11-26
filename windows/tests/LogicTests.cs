using System;
using System.Collections.Generic;
using System.Linq;
using System.Net;
using Xunit;

namespace TeamsBusyLight.Tests
{
    public class VersionTests
    {
        [Theory]
        [InlineData("1.10.0", "1.9.2", 1)]
        [InlineData("1.6.0-beta.2", "1.6.0-beta.10", -1)]
        [InlineData("1.6.0-beta.10", "1.6.0", -1)]
        [InlineData("v1.7.0", "1.7.0", 0)]
        [InlineData("1.7.0+abc", "1.7.0", 0)]
        [InlineData("1.7.0-alpha", "1.7.0-1", 1)]
        [InlineData("1.7", "1.7.0", 0)]
        public void Compare(string first, string second, int expected) =>
            Assert.Equal(expected, UpdateChecker.Compare(first, second));

        [Theory]
        [InlineData("1.8.0", "1.7.1", false, "update")]
        [InlineData("1.7.1", "1.7.1", false, null)]
        [InlineData("1.7.1", "1.8.0-beta.1", false, "downgrade")]
        [InlineData("1.7.1", "1.8.0-beta.1", true, null)]
        [InlineData("1.8.0-beta.2", "1.8.0-beta.1", true, "update")]
        public void Offer(string latest, string current, bool preReleases, string expected) =>
            Assert.Equal(expected, UpdateChecker.Offer(latest, current, preReleases));

        [Theory]
        [InlineData("1.7.1", false)]
        [InlineData("1.8.0-beta.1", true)]
        [InlineData("1.8.0", true)]
        public void CanInstall(string version, bool expected) => Assert.Equal(expected, UpdateChecker.CanInstall(version));

        [Fact]
        public void SelectNewestFromList()
        {
            const string json = @"[
                {""tag_name"": ""v1.8.0-beta.1"", ""draft"": false, ""html_url"": ""https://github.com/x/releases/1"",
                 ""assets"": [{""name"": ""TeamsBusyLight-Windows.zip"", ""browser_download_url"": ""https://github.com/x/a.zip""}]},
                {""tag_name"": ""v1.9.0"", ""draft"": true},
                {""tag_name"": ""v1.7.1"", ""draft"": false, ""html_url"": ""https://example.com/""}
            ]";
            var release = UpdateChecker.SelectNewest(json);
            Assert.Equal("1.8.0-beta.1", release.Version);
            Assert.Equal("https://github.com/x/a.zip", release.AssetUrl);
            Assert.Equal("https://github.com/x/releases/1", release.Page);
        }

        [Fact]
        public void SelectNewestSingleWithoutAsset()
        {
            var release = UpdateChecker.SelectNewest(@"{""tag_name"": ""v1.7.1"", ""html_url"": ""https://example.com/x"", ""assets"": []}");
            Assert.Equal("1.7.1", release.Version);
            Assert.Null(release.AssetUrl);
            // Only release pages on GitHub are opened
            Assert.Null(release.Page);
        }
    }

    public class NetworkTests
    {
        [Theory]
        [InlineData("192.168.1.0/24", true)]
        [InlineData("10.0.0.0/8", true)]
        [InlineData("192.168.1.5", true)]
        [InlineData("fd00::/8", true)]
        [InlineData("10.1", false)]
        [InlineData("192.168.1.0/33", false)]
        [InlineData("192.168.1.0/24/1", false)]
        [InlineData("example.com", false)]
        public void Parse(string text, bool valid) => Assert.Equal(valid, HomeNetwork.Parse(text) != null);

        [Fact]
        public void Contains()
        {
            var network = HomeNetwork.Parse("192.168.1.0/24").Value;
            Assert.True(HomeNetwork.Contains(network, IPAddress.Parse("192.168.1.77").GetAddressBytes()));
            Assert.False(HomeNetwork.Contains(network, IPAddress.Parse("192.168.2.1").GetAddressBytes()));
            Assert.False(HomeNetwork.Contains(network, IPAddress.Parse("fd00::1").GetAddressBytes()));
            var odd = HomeNetwork.Parse("10.0.0.0/12").Value;
            Assert.True(HomeNetwork.Contains(odd, IPAddress.Parse("10.15.255.255").GetAddressBytes()));
            Assert.False(HomeNetwork.Contains(odd, IPAddress.Parse("10.16.0.0").GetAddressBytes()));
        }

        [Fact]
        public void FindInvalidAndSplit()
        {
            Assert.Null(HomeNetwork.FindInvalid("192.168.1.0/24, 10.0.0.0/8;172.16.0.0/12"));
            Assert.Equal("10.1", HomeNetwork.FindInvalid("192.168.1.0/24, 10.1"));
            Assert.Null(HomeNetwork.FindInvalid(""));
        }

        [Fact]
        public void NetworkOf()
        {
            Assert.Equal("192.168.1.0/24", HomeNetwork.NetworkOf(new byte[] { 192, 168, 1, 77 }, 24));
            Assert.Equal("10.16.0.0/12", HomeNetwork.NetworkOf(new byte[] { 10, 20, 3, 4 }, 12));
            Assert.Null(HomeNetwork.NetworkOf(new byte[] { 169, 254, 1, 2 }, 16));
        }

        [Fact]
        public void NewNetworks()
        {
            var current = new[] { "192.168.1.0/24", "10.10.0.0/16", "172.16.5.0/24" };
            // Without home networks everything is sent: nothing to ask
            Assert.Empty(HomeNetwork.New("", "", current));
            Assert.Equal(new[] { "10.10.0.0/16" }, HomeNetwork.New("192.168.0.0/16", "172.16.5.0/24", current));
        }

        [Fact]
        public void Add() =>
            Assert.Equal("192.168.1.0/24, 10.0.0.0/8", HomeNetwork.Add("192.168.1.0/24", new[] { "10.0.0.0/8", "192.168.1.0/24" }));
    }

    public class TeamsLogTests
    {
        [Theory]
        [InlineData("SetTaskbarIconOverlay overlay description: Beschäftigt", "auto", "busy", "de")]
        [InlineData("SetTaskbarIconOverlay overlay description: Bin gleich zurück", "auto", "be_right_back", "de")]
        [InlineData("SetTaskbarIconOverlay overlay description: Nicht stören", "de", "do_not_disturb", "de")]
        [InlineData("SetBadge Setting badge: doNotDistrb", "auto", "do_not_disturb", "en")]
        [InlineData("SetTaskbarIconOverlay overlay description: Be right back", "auto", "be_right_back", "en")]
        [InlineData("SetTaskbarIconOverlay overlay description: Available", "en", "available", "en")]
        [InlineData("SetTaskbarIconOverlay overlay description: In a meeting", "auto", "in_a_meeting", "en")]
        public void Status(string line, string language, string status, string detected)
        {
            var result = TeamsMonitor.StatusFromLine(line, language);
            Assert.NotNull(result);
            Assert.Equal(status, result.Value.Status);
            Assert.Equal(detected, result.Value.Language);
        }

        [Fact]
        public void UnknownStatus() => Assert.Null(TeamsMonitor.StatusFromLine("SetTaskbarIconOverlay overlay description: ???", "auto"));

        [Theory]
        [InlineData("... reportIncomingCall ...", "incoming_call")]
        [InlineData("... RequestNewOutgoingCallWithOptions ...", "outgoing_call")]
        [InlineData("... NotifyCallActive ...", "in_call")]
        [InlineData("... NotifyCallAccepted ...", "in_call")]
        [InlineData("... NotifyCallEnded ...", "not_in_call")]
        public void Activity(string line, string expected) => Assert.Equal(expected, TeamsMonitor.ActivityFromLine(line));

        [Fact]
        public void LastLinesCount()
        {
            var state = new TeamsState();
            TeamsMonitor.Apply(state, new List<string>
            {
                "SetTaskbarIconOverlay overlay description: Available",
                "NotifyCallActive",
                "SetTaskbarIconOverlay overlay description: Busy",
                "something else",
                "NotifyCallEnded",
            }, "auto");
            Assert.Equal("busy", state.Status);
            Assert.Equal("not_in_call", state.Activity);
        }
    }

    public class SettingsTests
    {
        [Fact]
        public void DefaultsAndLimits()
        {
            var settings = Settings.Parse(@"{""WebhookUrl"": "" http://ha:8123/api/webhook/abc "", ""HeartbeatSeconds"": 5, ""PollSeconds"": 600,
                ""TeamsLanguage"": ""fr"", ""CheckForUpdates"": false, ""DetectOtherCalls"": ""yes""}");
            Assert.Equal("http://ha:8123/api/webhook/abc", settings.WebhookUrl);
            Assert.Equal(10, settings.HeartbeatSeconds);
            Assert.Equal(60, settings.PollSeconds);
            Assert.Equal("auto", settings.TeamsLanguage);
            Assert.False(settings.CheckForUpdates);
            Assert.True(settings.DetectOtherCalls);
            Assert.True(settings.AskForNewNetworks);
        }

        [Fact]
        public void RoundTrip()
        {
            var settings = new Settings { WebhookUrl = "https://ha.example/api/webhook/x", PreReleases = true, HomeNetworks = "192.168.1.0/24", PollSeconds = 5 };
            var again = Settings.Parse(settings.ToJson());
            Assert.Equal(settings.ToJson(), again.ToJson());
            Assert.True(again.PreReleases);
        }

        [Theory]
        [InlineData("http://homeassistant.local:8123/api/webhook/abc", true)]
        [InlineData("https://ha.example.com/api/webhook/abc-123", true)]
        [InlineData("ftp://ha/api/webhook/abc", false)]
        [InlineData("http://ha/api/webhook/", false)]
        [InlineData("http://ha/api/webhook/abc/def", false)]
        [InlineData("", false)]
        public void WebhookUrl(string url, bool valid) => Assert.Equal(valid, Settings.IsValidWebhookUrl(url));

        [Fact]
        public void PauseEnd()
        {
            Assert.Equal(DateTime.MaxValue, Settings.ParseEnd("always"));
            var until = new DateTime(2026, 11, 24, 15, 30, 0, DateTimeKind.Local);
            Assert.Equal(until, Settings.ParseEnd(Settings.FormatEnd(until)));
            Assert.Null(Settings.ParseEnd("tomorrow"));
        }

        [Fact]
        public void ManualStatusFile()
        {
            var manual = ManualStatus.Parse("busy always");
            Assert.Equal("busy", manual.Status);
            Assert.Equal(DateTime.MaxValue, manual.Until);
            Assert.True(manual.IsActive);
            Assert.Null(ManualStatus.Parse("in_a_call always"));
            Assert.Null(ManualStatus.Parse("busy"));
            var past = ManualStatus.Parse("away 2020-01-01T00:00:00.0000000Z");
            Assert.False(past.IsActive);
        }
    }

    public class MessageTests
    {
        [Fact]
        public void Body()
        {
            var body = Json.AsObject(Json.Parse(Sender.Body("busy", "in_call", "de", new Dictionary<string, object> { ["camera"] = true, ["source"] = "teams" })));
            Assert.Equal("busy", body["status"]);
            Assert.Equal("in_call", body["activity"]);
            Assert.Equal("de", body["language"]);
            Assert.Equal(true, body["camera"]);
            Assert.Equal("windows", body["platform"]);
            Assert.True(body.ContainsKey("computer"));
            Assert.True(body.ContainsKey("app_version"));
        }

        [Fact]
        public void OfflineExtraLeavesUnknownCameraOut()
        {
            Assert.False(Sender.OfflineExtra(null).ContainsKey("camera"));
            Assert.Equal(false, Sender.OfflineExtra(true)["camera"]);
        }

        [Fact]
        public void DiagnosticsHideWebhookId() =>
            Assert.Equal("POST http://ha:8123/api/webhook/<hidden> failed",
                Diagnostics.HideWebhookId("POST http://ha:8123/api/webhook/secret-id failed"));

        [Fact]
        public void Translations()
        {
            Strings.Load("de");
            Assert.Equal("Beschäftigt", Strings.Status("busy"));
            Strings.Load("xx");
            Assert.Equal("Busy", Strings.Status("busy"));
            Assert.Equal("Unknown", Strings.Status(null));
            Assert.Equal("Teams: Busy", Strings.Format("MenuStatus", "Busy"));
        }
    }

    public class HostsTests
    {
        [Theory]
        [InlineData("192.168.1.10\thomeassistant.local\t# Teams Busy Light", true)]
        [InlineData("192.168.1.10 other HomeAssistant.Local", true)]
        [InlineData("# 192.168.1.10 homeassistant.local", false)]
        [InlineData("192.168.1.10 homeassistant.localdomain", false)]
        public void MapsHost(string line, bool expected) =>
            Assert.Equal(expected, HostsFile.MapsHost(line, new[] { "homeassistant.local" }));

        [Fact]
        public void DnsAnswer()
        {
            var query = HostsFile.BuildQuery(0x1234, "ha.local");
            // Answer: the question, then one A record with a compressed name
            var answer = new List<byte>(query);
            answer[2] = 0x81; answer[3] = 0x80; answer[7] = 1;
            answer.AddRange(new byte[] { 0xC0, 0x0C, 0, 1, 0, 1, 0, 0, 0, 60, 0, 4, 192, 168, 1, 10 });
            Assert.Equal(IPAddress.Parse("192.168.1.10"), HostsFile.ParseAnswer(answer.ToArray(), 0x1234));
            Assert.Null(HostsFile.ParseAnswer(answer.ToArray(), 0x9999));
        }
    }
}
