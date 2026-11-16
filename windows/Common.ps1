# Shared functions of the Teams Busy Light tray app and its installer:
# texts, settings, autostart, Teams status detection, sending to Home
# Assistant and the settings window.
#
# Teams Busy Light runs per Windows user without administrator rights:
#   program   %LOCALAPPDATA%\Programs\TeamsBusyLight
#   settings  %LOCALAPPDATA%\TeamsBusyLight\settings.json
#   log       %LOCALAPPDATA%\TeamsBusyLight\TeamsBusyLight.log

. (Join-Path $PSScriptRoot 'Languages.ps1')

$AppName = 'Teams Busy Light'
$ProgramDir = Join-Path $env:LOCALAPPDATA 'Programs\TeamsBusyLight'
$DataDir = Join-Path $env:LOCALAPPDATA 'TeamsBusyLight'
$SettingsPath = Join-Path $DataDir 'settings.json'
$LogPath = Join-Path $DataDir 'TeamsBusyLight.log'
$PausePath = Join-Path $DataDir 'pause.txt'
$ManualStatusPath = Join-Path $DataDir 'manual-status.txt'
$LauncherPath = Join-Path $ProgramDir 'TeamsBusyLight.exe'
$TeamsLogFolder = Join-Path $env:LOCALAPPDATA 'Packages\MSTeams_8wekyb3d8bbwe\LocalCache\Microsoft\MSTeams\Logs'
$RunKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$UninstallKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\TeamsBusyLight'
$StartMenuShortcut = Join-Path ([Environment]::GetFolderPath('Programs')) 'Teams Busy Light.lnk'
# Names of the objects used to talk to a running instance
$InstanceMutexName = 'Local\TeamsBusyLight'
$ShowSettingsEventName = 'Local\TeamsBusyLight.ShowSettings'
$ExitEventName = 'Local\TeamsBusyLight.Exit'
$ReleasesPage = 'https://github.com/SebastianInTheWild/HA-Teams-busy-light/releases/latest'
$ReleasesApi = 'https://api.github.com/repos/SebastianInTheWild/HA-Teams-busy-light/releases/latest'
# The Windows download contains a catalog with the hashes of all its files,
# signed with our own certificate (windows/tools/create-signing-certificate.ps1).
# Updates are installed only if the catalog is signed with the certificate
# with this SHA-256 fingerprint. Empty = no update button, only the hint.
$ReleaseCatalogName = 'TeamsBusyLight.cat'
$ReleaseAssetName = 'TeamsBusyLight-Windows.zip'
$SigningCertificateSha256 = 'C490C7763D8BB1C4098F00D45BB87C7BC45A41282686F89D32C941EBDBABF48F'

$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

# Loads the UI texts from Translations\<language>.json (English as fallback).
# The files are read explicitly as UTF-8, so umlauts are shown correctly in
# Windows PowerShell 5.1 as well.
function Get-TeamsMessages {
    param(
        [string]$Language,
        [string]$Root = $PSScriptRoot
    )

    $LanguageCode = $Language
    if ([string]::IsNullOrWhiteSpace($LanguageCode)) {
        $LanguageCode = [System.Globalization.CultureInfo]::CurrentUICulture.TwoLetterISOLanguageName
    }
    $LanguageCode = $LanguageCode.ToLowerInvariant().Split('-')[0]

    $TranslationPath = Join-Path $Root "Translations\$LanguageCode.json"
    if (-not (Test-Path $TranslationPath)) {
        $TranslationPath = Join-Path $Root "Translations\en.json"
    }
    if (-not (Test-Path $TranslationPath)) {
        throw "No English fallback translation found under '$Root\Translations'."
    }

    $Json = [System.IO.File]::ReadAllText($TranslationPath, [System.Text.Encoding]::UTF8)
    return $Json | ConvertFrom-Json
}

function Write-TeamsLog {
    param([string]$Message)

    try {
        if (-not (Test-Path $DataDir)) {
            New-Item -Path $DataDir -ItemType Directory -Force | Out-Null
        }
        # Keep one older log of about 1 MB
        $LogFile = Get-Item -LiteralPath $LogPath -ErrorAction SilentlyContinue
        if ($LogFile -and $LogFile.Length -gt 1MB) {
            Move-Item -LiteralPath $LogPath -Destination "$LogPath.old" -Force
        }
        $Line = '{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
        [System.IO.File]::AppendAllText($LogPath, $Line + [Environment]::NewLine, $Utf8NoBom)
    }
    catch {
        Write-Verbose $_.Exception.Message
    }
}

function Test-WebhookUrl {
    param([string]$Url)

    $Uri = $null
    return (
        $Url -match '/api/webhook/[^/]+$' -and
        [System.Uri]::TryCreate($Url, [System.UriKind]::Absolute, [ref]$Uri) -and
        $Uri.Scheme -in @('http', 'https')
    )
}

# --- Send only in these networks -------------------------------------------
# Teams Busy Light sends only while the PC has an address in one of the
# networks (CIDR, e.g. 192.168.1.0/24), so it does not send through an
# externally reachable webhook URL while on the road. Empty = everywhere.

# Splits the entered list (commas, semicolons or spaces)
function Split-TeamsNetworkText {
    param([string]$Text)

    return @(([string]$Text) -split '[,;\s]+' | Where-Object { $_ })
}

# Returns @{ Bytes; Prefix } or $null if the entry is not a valid network
function ConvertFrom-TeamsNetwork {
    param([string]$Text)

    $Parts = $Text.Split('/')
    if ($Parts.Count -gt 2) { return $null }
    $Address = $null
    if (-not [System.Net.IPAddress]::TryParse($Parts[0], [ref]$Address)) { return $null }
    # IPAddress also accepts shortened forms like "10.1"
    if ($Address.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork -and $Parts[0].Split('.').Count -ne 4) { return $null }
    $Bytes = $Address.GetAddressBytes()
    $Prefix = $Bytes.Length * 8
    if ($Parts.Count -eq 2) {
        $Value = 0
        if (-not [int]::TryParse($Parts[1], [ref]$Value) -or $Value -lt 0 -or $Value -gt $Prefix) { return $null }
        $Prefix = $Value
    }
    return @{ Bytes = $Bytes; Prefix = $Prefix }
}

# Returns the first invalid entry of the list, $null if all are valid
function Find-TeamsInvalidNetwork {
    param([string]$Text)

    foreach ($Entry in (Split-TeamsNetworkText $Text)) {
        if (-not (ConvertFrom-TeamsNetwork $Entry)) {
            return $Entry
        }
    }
    return $null
}

function Test-TeamsAddressInNetwork {
    param([byte[]]$Address, [hashtable]$Network)

    if ($Address.Length -ne $Network.Bytes.Length) { return $false }
    $Bits = $Network.Prefix
    for ($Index = 0; $Index -lt $Address.Length -and $Bits -gt 0; $Index++) {
        $Mask = if ($Bits -ge 8) { 255 } else { (255 -shl (8 - $Bits)) -band 255 }
        if (($Address[$Index] -band $Mask) -ne ($Network.Bytes[$Index] -band $Mask)) { return $false }
        $Bits -= 8
    }
    return $true
}

function Get-TeamsActiveInterfaces {
    return @([System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces() | Where-Object {
        $_.OperationalStatus -eq [System.Net.NetworkInformation.OperationalStatus]::Up -and
        $_.NetworkInterfaceType -ne [System.Net.NetworkInformation.NetworkInterfaceType]::Loopback
    })
}

# True when no networks are set or an active interface has an address in one of them
function Test-TeamsHomeNetwork {
    param([string]$Text)

    $Networks = @(Split-TeamsNetworkText $Text | ForEach-Object { ConvertFrom-TeamsNetwork $_ } | Where-Object { $_ })
    if ($Networks.Count -eq 0) {
        return $true
    }
    foreach ($Interface in (Get-TeamsActiveInterfaces)) {
        foreach ($Unicast in $Interface.GetIPProperties().UnicastAddresses) {
            $Bytes = $Unicast.Address.GetAddressBytes()
            foreach ($Network in $Networks) {
                if (Test-TeamsAddressInNetwork $Bytes $Network) {
                    return $true
                }
            }
        }
    }
    return $false
}

# IPv4 networks of the active interfaces with a gateway (no VPN tunnels),
# e.g. "192.168.1.0/24", for "Add current network"
function Get-TeamsCurrentNetworks {
    $Result = New-Object System.Collections.Generic.List[string]
    foreach ($Interface in (Get-TeamsActiveInterfaces)) {
        if ($Interface.NetworkInterfaceType -in @(
            [System.Net.NetworkInformation.NetworkInterfaceType]::Tunnel,
            [System.Net.NetworkInformation.NetworkInterfaceType]::Ppp)) {
            continue
        }
        $Properties = $Interface.GetIPProperties()
        if (@($Properties.GatewayAddresses | Where-Object { -not $_.Address.Equals([System.Net.IPAddress]::Any) }).Count -eq 0) {
            continue
        }
        foreach ($Unicast in $Properties.UnicastAddresses) {
            if ($Unicast.Address.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) { continue }
            $Bytes = $Unicast.Address.GetAddressBytes()
            if ($Bytes[0] -eq 169 -and $Bytes[1] -eq 254) { continue }
            $Prefix = [int]$Unicast.PrefixLength
            $Bits = $Prefix
            for ($Index = 0; $Index -lt 4; $Index++) {
                $Mask = if ($Bits -ge 8) { 255 } elseif ($Bits -le 0) { 0 } else { (255 -shl (8 - $Bits)) -band 255 }
                $Bytes[$Index] = $Bytes[$Index] -band $Mask
                $Bits -= 8
            }
            $Network = '{0}/{1}' -f ([System.Net.IPAddress]::new($Bytes)), $Prefix
            if (-not $Result.Contains($Network)) {
                $Result.Add($Network)
            }
        }
    }
    return $Result.ToArray()
}

# Current networks that are neither covered by the home networks nor
# ignored; only while home networks are set (otherwise everything is sent)
function Get-TeamsNewNetworks {
    param([string]$HomeNetworks, [string]$IgnoredNetworks)

    $Networks = @(Split-TeamsNetworkText $HomeNetworks | ForEach-Object { ConvertFrom-TeamsNetwork $_ } | Where-Object { $_ })
    if ($Networks.Count -eq 0) {
        return @()
    }
    $Ignored = @(Split-TeamsNetworkText $IgnoredNetworks)
    return @(Get-TeamsCurrentNetworks | Where-Object {
        $Bytes = (ConvertFrom-TeamsNetwork $_).Bytes
        $_ -notin $Ignored -and -not ($Networks | Where-Object { Test-TeamsAddressInNetwork $Bytes $_ })
    })
}

# Appends networks to a list, without duplicates
function Add-TeamsNetworkText {
    param([string]$Text, [string[]]$Networks)

    $Entries = New-Object System.Collections.Generic.List[string]
    foreach ($Entry in @(Split-TeamsNetworkText $Text) + $Networks) {
        if ($Entry -and -not $Entries.Contains($Entry)) {
            $Entries.Add($Entry)
        }
    }
    return $Entries -join ', '
}

function Read-TeamsSettings {
    $Values = [ordered]@{
        WebhookUrl = ''
        HeartbeatSeconds = 60
        PollSeconds = 2
        TeamsLanguage = 'auto'
        CheckForUpdates = $true
        HomeNetworks = ''
        AskForNewNetworks = $true
        IgnoredNetworks = ''
        DetectOtherCalls = $true
    }
    if (Test-Path $SettingsPath) {
        try {
            $Saved = [System.IO.File]::ReadAllText($SettingsPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
            foreach ($Name in @($Values.Keys)) {
                if ($null -ne $Saved.$Name) {
                    $Values[$Name] = $Saved.$Name
                }
            }
        }
        catch {
            Write-TeamsLog "Cannot read ${SettingsPath}: $($_.Exception.Message)"
        }
    }
    $Values.WebhookUrl = ([string]$Values.WebhookUrl).Trim()
    $Values.HeartbeatSeconds = [Math]::Min([Math]::Max([int]$Values.HeartbeatSeconds, 10), 3600)
    $Values.PollSeconds = [Math]::Min([Math]::Max([int]$Values.PollSeconds, 1), 60)
    $Values.CheckForUpdates = [bool]$Values.CheckForUpdates
    $Values.HomeNetworks = ([string]$Values.HomeNetworks).Trim()
    $Values.AskForNewNetworks = [bool]$Values.AskForNewNetworks
    $Values.IgnoredNetworks = ([string]$Values.IgnoredNetworks).Trim()
    $Values.DetectOtherCalls = [bool]$Values.DetectOtherCalls
    if ($Values.TeamsLanguage -notin @('auto', 'de', 'en')) {
        $Values.TeamsLanguage = 'auto'
    }
    return [pscustomobject]$Values
}

function Save-TeamsSettings {
    param([pscustomobject]$Settings)

    if (-not (Test-Path $DataDir)) {
        New-Item -Path $DataDir -ItemType Directory -Force | Out-Null
    }
    $Json = $Settings | ConvertTo-Json
    [System.IO.File]::WriteAllText($SettingsPath, $Json, $Utf8NoBom)
}

# Sending paused from the tray menu, kept over restarts: the end as UTC
# timestamp, [datetime]::MaxValue = until resumed, $null = not paused
function Get-TeamsPause {
    if (-not (Test-Path $PausePath)) {
        return $null
    }
    $Text = ([System.IO.File]::ReadAllText($PausePath)).Trim()
    if ($Text -eq 'always') {
        return [datetime]::MaxValue
    }
    $Until = [datetime]::MinValue
    if ([datetime]::TryParse($Text, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind, [ref]$Until)) {
        return $Until.ToLocalTime()
    }
    return $null
}

function Set-TeamsPause {
    param([Nullable[datetime]]$Until)

    if ($null -eq $Until) {
        Remove-Item -LiteralPath $PausePath -ErrorAction SilentlyContinue
        return
    }
    if (-not (Test-Path $DataDir)) {
        New-Item -Path $DataDir -ItemType Directory -Force | Out-Null
    }
    $Text = if ($Until -eq [datetime]::MaxValue) { 'always' } else { $Until.ToUniversalTime().ToString('o') }
    [System.IO.File]::WriteAllText($PausePath, $Text, $Utf8NoBom)
}

# Status set from the tray menu instead of the Teams status, kept over
# restarts: "<status> <end as UTC timestamp or always>", $null = none
function Get-TeamsManualStatus {
    if (-not (Test-Path $ManualStatusPath)) {
        return $null
    }
    $Parts = ([System.IO.File]::ReadAllText($ManualStatusPath)).Trim() -split '\s+', 2
    if ($Parts.Count -ne 2 -or $Parts[0] -notin $ManualStatuses) {
        return $null
    }
    if ($Parts[1] -eq 'always') {
        return @{ Status = $Parts[0]; Until = [datetime]::MaxValue }
    }
    $Until = [datetime]::MinValue
    if ([datetime]::TryParse($Parts[1], [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind, [ref]$Until)) {
        return @{ Status = $Parts[0]; Until = $Until.ToLocalTime() }
    }
    return $null
}

function Set-TeamsManualStatus {
    param([string]$Status, [Nullable[datetime]]$Until)

    if (-not $Status) {
        Remove-Item -LiteralPath $ManualStatusPath -ErrorAction SilentlyContinue
        return
    }
    if (-not (Test-Path $DataDir)) {
        New-Item -Path $DataDir -ItemType Directory -Force | Out-Null
    }
    $End = if ($Until -eq [datetime]::MaxValue) { 'always' } else { $Until.ToUniversalTime().ToString('o') }
    [System.IO.File]::WriteAllText($ManualStatusPath, "$Status $End", $Utf8NoBom)
}

# Statuses offered under "Set status" in the tray menu
$ManualStatuses = @('available', 'busy', 'do_not_disturb', 'be_right_back', 'away')

# Camera and microphone in use by any app. No permission needed.
# - Microphone: the active recording sessions of the Windows audio system
#   (WASAPI), with the process of each session. Works on all Windows versions.
# - Camera: Windows has no such interface. Older Windows versions record the
#   use per app in the registry for the privacy settings ("recently used"):
#   an app uses the device while LastUsedTimeStop is 0. Newer Windows 11
#   versions keep this in a database only the system can read; then the
#   events of the camera service are used (experimental, without app name,
#   see Get-TeamsCameraFromEvents). Without both the camera is unknown ($null)
#   and not sent.
#   The registry is also the fallback for the microphone.
function Get-TeamsDeviceUsage {
    $Camera = Get-TeamsDeviceUsers 'webcam'
    $Result = @{
        Camera = $null
        CameraApps = $Camera.Apps
        CameraSource = 'none'
        MicrophoneApps = @()
        MicrophoneSource = 'audio system'
    }
    if ($Camera.Tracked) {
        $Result.Camera = $Camera.Apps.Count -gt 0
        $Result.CameraSource = 'registry'
    }
    else {
        $Result.Camera = Get-TeamsCameraFromEvents
        if ($null -ne $Result.Camera) {
            $Result.CameraSource = 'camera service events (experimental)'
        }
    }
    $Apps = Get-TeamsMicrophoneUsers
    if ($null -eq $Apps) {
        $Microphone = Get-TeamsDeviceUsers 'microphone'
        $Result.MicrophoneSource = if ($Microphone.Tracked) { 'registry' } else { 'none' }
        $Apps = if ($Microphone.Tracked) { $Microphone.Apps } else { $null }
    }
    $Result.Microphone = if ($null -eq $Apps) { $null } else { @($Apps).Count -gt 0 }
    if ($Apps) { $Result.MicrophoneApps = @($Apps) }
    return $Result
}

$TeamsAudioCaptureSource = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

namespace TeamsBusyLight {
    [ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")] class MMDeviceEnumerator {}

    [ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDeviceEnumerator {
        [PreserveSig] int EnumAudioEndpoints(int dataFlow, int stateMask, out IMMDeviceCollection devices);
    }

    [ComImport, Guid("0BD7A1BE-7A1A-44DB-8397-CC5392387B5E"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDeviceCollection {
        [PreserveSig] int GetCount(out int count);
        [PreserveSig] int Item(int index, out IMMDevice device);
    }

    [ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDevice {
        [PreserveSig] int Activate(ref Guid iid, int clsCtx, IntPtr activationParams, [MarshalAs(UnmanagedType.IUnknown)] out object instance);
    }

    [ComImport, Guid("77AA99A0-1BD6-484F-8BC7-2C654C9A9B6F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioSessionManager2 {
        [PreserveSig] int GetAudioSessionControl(IntPtr sessionGuid, int flags, out IntPtr control);
        [PreserveSig] int GetSimpleAudioVolume(IntPtr sessionGuid, int flags, out IntPtr volume);
        [PreserveSig] int GetSessionEnumerator(out IAudioSessionEnumerator sessions);
    }

    [ComImport, Guid("E2F5BB11-0570-40CA-ACDD-3AA01277DEE8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioSessionEnumerator {
        [PreserveSig] int GetCount(out int count);
        [PreserveSig] int GetSession(int index, [MarshalAs(UnmanagedType.IUnknown)] out object session);
    }

    [ComImport, Guid("bfb7ff88-7239-4fc9-8fa2-07c950be9c6d"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioSessionControl2 {
        [PreserveSig] int GetState(out int state);
        [PreserveSig] int GetDisplayName(out IntPtr name);
        [PreserveSig] int SetDisplayName(IntPtr name, IntPtr context);
        [PreserveSig] int GetIconPath(out IntPtr path);
        [PreserveSig] int SetIconPath(IntPtr path, IntPtr context);
        [PreserveSig] int GetGroupingParam(out Guid param);
        [PreserveSig] int SetGroupingParam(IntPtr param, IntPtr context);
        [PreserveSig] int RegisterAudioSessionNotification(IntPtr client);
        [PreserveSig] int UnregisterAudioSessionNotification(IntPtr client);
        [PreserveSig] int GetSessionIdentifier(out IntPtr id);
        [PreserveSig] int GetSessionInstanceIdentifier(out IntPtr id);
        [PreserveSig] int GetProcessId(out int pid);
        [PreserveSig] int IsSystemSoundsSession();
    }

    public static class AudioCapture {
        static void Release(object o) {
            if (o != null && Marshal.IsComObject(o)) Marshal.ReleaseComObject(o);
        }

        // Process IDs of all recording sessions that are active right now, on all microphones
        public static int[] ActiveProcessIds() {
            var result = new List<int>();
            object enumerator = new MMDeviceEnumerator();
            IMMDeviceCollection devices = null;
            try {
                Marshal.ThrowExceptionForHR(((IMMDeviceEnumerator)enumerator).EnumAudioEndpoints(1 /* eCapture */, 1 /* DEVICE_STATE_ACTIVE */, out devices));
                int count;
                devices.GetCount(out count);
                for (int i = 0; i < count; i++) {
                    IMMDevice device = null;
                    object manager = null;
                    IAudioSessionEnumerator sessions = null;
                    try {
                        if (devices.Item(i, out device) != 0) continue;
                        Guid iid = typeof(IAudioSessionManager2).GUID;
                        if (device.Activate(ref iid, 23 /* CLSCTX_ALL */, IntPtr.Zero, out manager) != 0) continue;
                        if (((IAudioSessionManager2)manager).GetSessionEnumerator(out sessions) != 0) continue;
                        int n;
                        sessions.GetCount(out n);
                        for (int j = 0; j < n; j++) {
                            object session = null;
                            try {
                                if (sessions.GetSession(j, out session) != 0) continue;
                                var control = (IAudioSessionControl2)session;
                                int state, pid;
                                // State 1 = active; IsSystemSoundsSession returns 0 for system sounds
                                if (control.GetState(out state) == 0 && state == 1 &&
                                    control.IsSystemSoundsSession() != 0 &&
                                    control.GetProcessId(out pid) == 0 && pid != 0 && !result.Contains(pid)) {
                                    result.Add(pid);
                                }
                            }
                            finally { Release(session); }
                        }
                    }
                    finally { Release(sessions); Release(manager); Release(device); }
                }
            }
            finally { Release(devices); Release(enumerator); }
            return result.ToArray();
        }
    }
}
'@

# Names of the processes recording from a microphone right now (e.g. "Zoom",
# "msedge"): an empty list when none, $null when the audio system cannot be asked
function Get-TeamsMicrophoneUsers {
    if ($null -eq $script:TeamsAudioCaptureReady) {
        try {
            Add-Type -TypeDefinition $TeamsAudioCaptureSource -ErrorAction Stop
            $script:TeamsAudioCaptureReady = $true
        }
        catch {
            $script:TeamsAudioCaptureReady = $false
        }
    }
    if (-not $script:TeamsAudioCaptureReady) {
        return $null
    }
    try {
        $Ids = [TeamsBusyLight.AudioCapture]::ActiveProcessIds()
    }
    catch {
        return $null
    }
    $Names = @(foreach ($Id in $Ids) {
        $Process = Get-Process -Id $Id -ErrorAction SilentlyContinue
        if ($Process) { $Process.ProcessName }
    })
    # The comma keeps an empty list from turning into $null
    return , @($Names | Sort-Object -Unique)
}

# Camera in use according to the camera service (Frame Server), for Windows
# versions that no longer record it in the registry. Experimental: the service
# writes no documented "camera on/off" event, so this relies on its watchdog
# events (ID 11) in the diagnostic log Camera_FrameServer, which a normal user
# may read. For the camera device (TimerScope 2) the operation is 2 when a
# stream starts and 3 when it stops; the newest event per device object counts,
# the camera is on while any object last started. Observed on Windows 11 26H2
# (16.11.2026). When the service is not running, the camera is off.
# Returns $null when the log is missing, turned off or unreadable.
$TeamsCameraEventLog = 'Microsoft-Windows-MF-FrameServer/Camera_FrameServer'

function Get-TeamsCameraFromEvents {
    if ($null -eq $script:TeamsCameraEventLogEnabled) {
        try {
            $LogConfig = New-Object System.Diagnostics.Eventing.Reader.EventLogConfiguration($TeamsCameraEventLog)
            $script:TeamsCameraEventLogEnabled = $LogConfig.IsEnabled
            $LogConfig.Dispose()
        }
        catch {
            $script:TeamsCameraEventLogEnabled = $false
        }
    }
    if (-not $script:TeamsCameraEventLogEnabled) {
        return $null
    }
    $Service = Get-Service -Name 'FrameServer' -ErrorAction SilentlyContinue
    if (-not $Service) {
        return $null
    }
    if ($Service.Status -ne 'Running') {
        return $false
    }
    $Reader = $null
    try {
        $Query = New-Object System.Diagnostics.Eventing.Reader.EventLogQuery($TeamsCameraEventLog, [System.Diagnostics.Eventing.Reader.PathType]::LogName, '*[System[EventID=11]]')
        $Query.ReverseDirection = $true
        $Reader = New-Object System.Diagnostics.Eventing.Reader.EventLogReader($Query)
        $LastOperation = @{}
        for ($Index = 0; $Index -lt 30; $Index++) {
            $Record = $Reader.ReadEvent()
            if (-not $Record) { break }
            try {
                $Values = $Record.Properties
                if ($Values.Count -ge 3 -and "$($Values[0].Value)" -eq '2') {
                    $Device = "$($Values[1].Value)"
                    if (-not $LastOperation.ContainsKey($Device)) {
                        $LastOperation[$Device] = "$($Values[2].Value)"
                    }
                }
            }
            finally {
                $Record.Dispose()
            }
        }
        return ($LastOperation.Values -contains '2')
    }
    catch {
        return $null
    }
    finally {
        if ($Reader) { $Reader.Dispose() }
    }
}

# Apps using a device according to the registry. Tracked is false when this
# Windows version does not record the use there (no LastUsedTimeStart at all).
function Get-TeamsDeviceUsers {
    param([string]$Capability)

    $Users = New-Object System.Collections.Generic.List[string]
    $Seen = @{ Tracked = $false }
    $Root = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey("Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\$Capability")
    if ($Root) {
        try {
            $Check = {
                param($Key, [string]$Name)
                $Start = $Key.GetValue('LastUsedTimeStart')
                $Stop = $Key.GetValue('LastUsedTimeStop')
                if ($null -ne $Start) {
                    $Seen.Tracked = $true
                }
                if ($null -ne $Start -and [long]$Start -ne 0 -and $null -ne $Stop -and [long]$Stop -eq 0) {
                    $Users.Add($Name)
                }
            }
            foreach ($Name in $Root.GetSubKeyNames()) {
                $Key = $Root.OpenSubKey($Name)
                if (-not $Key) { continue }
                try {
                    if ($Name -eq 'NonPackaged') {
                        # Desktop apps: the path with # instead of \, e.g. C:#Program Files#Zoom#bin#Zoom.exe -> Zoom
                        foreach ($AppName in $Key.GetSubKeyNames()) {
                            $AppKey = $Key.OpenSubKey($AppName)
                            if (-not $AppKey) { continue }
                            try { & $Check $AppKey (($AppName -split '#')[-1] -replace '\.exe$', '') } finally { $AppKey.Close() }
                        }
                    }
                    else {
                        # Store apps, e.g. MSTeams_8wekyb3d8bbwe
                        & $Check $Key ($Name -split '_')[0]
                    }
                }
                finally {
                    $Key.Close()
                }
            }
        }
        finally {
            $Root.Close()
        }
    }
    return @{ Tracked = $Seen.Tracked; Apps = @($Users) }
}

# Installed version (version.txt, written by the installer), "0.0.0" if unknown
function Get-TeamsVersion {
    param([string]$Root = $PSScriptRoot)

    $VersionFile = Join-Path $Root 'version.txt'
    if (Test-Path $VersionFile) {
        return (Get-Content -Path $VersionFile -TotalCount 1).Trim()
    }
    return '0.0.0'
}

# Sent with every message, so Home Assistant can point out outdated apps
$script:TeamsAppVersion = Get-TeamsVersion

# Camera and microphone are reported off together with offline (the app
# stops watching them). A camera this Windows version does not report
# ($State.Camera is $null) is left out, so it stays unknown in Home Assistant.
function Get-TeamsOfflineExtra {
    $Extra = @{ microphone = $false; source = 'teams' }
    if ($null -ne $State.Camera) {
        $Extra.camera = $false
    }
    return $Extra
}

# True if version a is newer than version b (e.g. "1.10.0" > "1.9.2")
function Test-TeamsNewerVersion {
    param([string]$Candidate, [string]$Current)

    $A = @($Candidate.TrimStart('v').Split('.') | ForEach-Object { [int]($_ -replace '\D', '0') })
    $B = @($Current.TrimStart('v').Split('.') | ForEach-Object { [int]($_ -replace '\D', '0') })
    for ($Index = 0; $Index -lt [Math]::Max($A.Count, $B.Count); $Index++) {
        $X = if ($Index -lt $A.Count) { $A[$Index] } else { 0 }
        $Y = if ($Index -lt $B.Count) { $B[$Index] } else { 0 }
        if ($X -ne $Y) { return $X -gt $Y }
    }
    return $false
}

# Test-FileCatalog/New-FileCatalog: load the module of this PowerShell
# explicitly. Started from PowerShell 7 (e.g. Install.cmd in a PowerShell 7
# terminal), PSModulePath points to the PowerShell 7 module first, which
# Windows PowerShell 5.1 cannot load.
function Import-TeamsSecurityModule {
    Import-Module -Name (Join-Path $PSHOME 'Modules\Microsoft.PowerShell.Security') -ErrorAction Stop
}

function Get-TeamsCertificateSha256 {
    param([System.Security.Cryptography.X509Certificates.X509Certificate2]$Certificate)

    $Hash = [System.Security.Cryptography.SHA256]::Create().ComputeHash($Certificate.RawData)
    return [BitConverter]::ToString($Hash).Replace('-', '')
}

# Checks an unpacked Windows download: the catalog must be signed with the
# pinned certificate and all files must match it (none changed, added or
# missing). Windows does not need to trust the certificate, so the signature
# is checked here instead of with Get-AuthenticodeSignature.
# Returns $null if everything is fine, otherwise the reason.
function Test-TeamsReleaseSignature {
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$Fingerprint = $SigningCertificateSha256
    )

    if (-not $Fingerprint) {
        return 'no signing certificate pinned'
    }
    $CatalogPath = Join-Path $Path $ReleaseCatalogName
    if (-not (Test-Path -LiteralPath $CatalogPath)) {
        return 'not signed'
    }
    Add-Type -AssemblyName System.Security
    $SignedData = New-Object System.Security.Cryptography.Pkcs.SignedCms
    try {
        $SignedData.Decode([System.IO.File]::ReadAllBytes($CatalogPath))
        # Checks the signature itself, not whether Windows trusts the certificate
        $SignedData.CheckSignature($true)
    }
    catch {
        return "invalid signature ($($_.Exception.Message.Trim()))"
    }
    if ($SignedData.SignerInfos.Count -ne 1 -or -not $SignedData.SignerInfos[0].Certificate) {
        return 'unexpected signers'
    }
    if ((Get-TeamsCertificateSha256 $SignedData.SignerInfos[0].Certificate) -ne $Fingerprint) {
        return 'signed with another certificate'
    }
    Import-TeamsSecurityModule
    $Result = Test-FileCatalog -CatalogFilePath $CatalogPath -Path $Path -Detailed
    if ($Result.Status -ne 'Valid') {
        $Differences = @($Result.CatalogItems.Keys | Where-Object { $Result.CatalogItems[$_] -ne $Result.PathItems[$_] }) +
            @($Result.PathItems.Keys | Where-Object { -not $Result.CatalogItems.ContainsKey($_) })
        return "files do not match the catalog: $($Differences -join ', ')"
    }
    return $null
}

# Unpacks a ZIP file; refuses entries outside the target folder and
# archives that unpack to more than $MaxBytes
function Expand-TeamsZip {
    param(
        [Parameter(Mandatory)][string]$ZipPath,
        [Parameter(Mandatory)][string]$Destination,
        [long]$MaxBytes = 50MB
    )

    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $Root = [System.IO.Path]::GetFullPath($Destination).TrimEnd('\') + '\'
    $Archive = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        $Total = 0
        foreach ($Entry in $Archive.Entries) {
            $Total += $Entry.Length
            if ($Total -gt $MaxBytes) {
                throw 'The archive is too large.'
            }
            $Target = [System.IO.Path]::GetFullPath((Join-Path $Root $Entry.FullName))
            if (-not $Target.StartsWith($Root, [System.StringComparison]::OrdinalIgnoreCase)) {
                throw "The archive contains an invalid path: $($Entry.FullName)"
            }
            if ($Entry.FullName.EndsWith('/') -or $Entry.FullName.EndsWith('\')) {
                New-Item -Path $Target -ItemType Directory -Force | Out-Null
                continue
            }
            New-Item -Path (Split-Path $Target) -ItemType Directory -Force | Out-Null
            [System.IO.Compression.ZipFileExtensions]::ExtractToFile($Entry, $Target, $false)
        }
    }
    finally {
        $Archive.Dispose()
    }
}

# Message box in front of other windows: an invisible topmost owner window,
# because a tray app has no window of its own. (MessageBoxOptions.
# DefaultDesktopOnly must not be used: in the tray app the box returned "No"
# at once without being shown.)
function Show-TeamsMessageBox {
    param(
        [string]$Text,
        [string]$Caption = $AppName,
        [System.Windows.Forms.MessageBoxButtons]$Buttons = [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]$Icon = [System.Windows.Forms.MessageBoxIcon]::Information
    )

    $Owner = New-Object System.Windows.Forms.Form
    $Owner.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
    $Owner.ShowInTaskbar = $false
    $Owner.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
    $Owner.Location = New-Object System.Drawing.Point(-32000, -32000)
    $Owner.Size = New-Object System.Drawing.Size(1, 1)
    $Owner.TopMost = $true
    try {
        $Owner.Show()
        $Owner.Activate()
        return [System.Windows.Forms.MessageBox]::Show($Owner, $Text, $Caption, $Buttons, $Icon)
    }
    finally {
        $Owner.Dispose()
    }
}

function Get-TeamsAutostart {
    $Value = Get-ItemProperty -Path $RunKey -Name $AppName -ErrorAction SilentlyContinue
    return [bool]$Value
}

function Set-TeamsAutostart {
    param([bool]$Enabled)

    if ($Enabled) {
        Set-ItemProperty -Path $RunKey -Name $AppName -Value ('"{0}"' -f $LauncherPath)
    }
    else {
        Remove-ItemProperty -Path $RunKey -Name $AppName -ErrorAction SilentlyContinue
    }
}

# Asks a running instance to show its settings or to exit. Returns $false if
# Teams Busy Light is not running.
function Send-TeamsInstanceSignal {
    param([string]$EventName)

    $Handle = $null
    if (-not [System.Threading.EventWaitHandle]::TryOpenExisting($EventName, [ref]$Handle)) {
        return $false
    }
    [void]$Handle.Set()
    $Handle.Dispose()
    return $true
}

# Stops a running instance and waits until it has exited
function Stop-TeamsBusyLight {
    if (-not (Send-TeamsInstanceSignal $ExitEventName)) {
        return
    }
    $Mutex = $null
    if ([System.Threading.Mutex]::TryOpenExisting($InstanceMutexName, [ref]$Mutex)) {
        try {
            if ($Mutex.WaitOne(15000)) {
                $Mutex.ReleaseMutex()
            }
        }
        catch [System.Threading.AbandonedMutexException] {
            $Mutex.ReleaseMutex()
        }
        finally {
            $Mutex.Dispose()
        }
    }
}

# Returns the language-neutral status and the language of a Teams log line
function Get-StatusFromLogLine {
    param([string]$Line, [string]$Language)

    if ($Language -and $Language -ne 'auto') {
        $Languages = @($Language)
    }
    else {
        # Localized words are checked first, as a localized line may also
        # contain English technical terms.
        $Languages = @($StatusPatterns.Keys | Where-Object { $_ -ne 'en' }) + 'en'
    }

    foreach ($Lang in $Languages) {
        $Table = $StatusPatterns[$Lang]
        if ($null -eq $Table) { continue }
        foreach ($State in $Table.Keys) {
            foreach ($Pattern in $Table[$State]) {
                if ($Line -match $Pattern) {
                    return @{ Status = $State; Language = $Lang }
                }
            }
        }
    }
    return $null
}

# Reads the Teams status of the current Windows user. Status, Activity and
# Language are $null when the log does not contain them (yet).
function Get-TeamsState {
    param([string]$TeamsLanguage = 'auto')

    $State = @{ Running = $false; LogFound = $false; Status = $null; Activity = $null; Language = $null }

    $SessionId = [System.Diagnostics.Process]::GetCurrentProcess().SessionId
    $TeamsProcess = Get-Process -Name 'ms-teams' -ErrorAction SilentlyContinue |
        Where-Object { $_.SessionId -eq $SessionId } |
        Select-Object -First 1
    if (-not $TeamsProcess) {
        $State.Status = 'offline'
        $State.Activity = 'not_in_call'
        return $State
    }
    $State.Running = $true

    $LatestLog = Get-ChildItem -Path $TeamsLogFolder -Filter 'MSTeams_*.log' -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
    if (-not $LatestLog) {
        return $State
    }
    $State.LogFound = $true

    $Lines = Get-Content -Path $LatestLog.FullName -Tail 1000 -Encoding UTF8 -ErrorAction SilentlyContinue
    $StatusLine = $Lines | Select-String -Pattern 'SetBadge Setting badge:', 'SetTaskbarIconOverlay' | Select-Object -Last 1
    $ActivityLine = $Lines | Select-String -Pattern 'NotifyCallActive', 'NotifyCallAccepted', 'NotifyCallEnded', 'reportIncomingCall', 'RequestNewOutgoingCallWithOptions' | Select-Object -Last 1

    if ($StatusLine) {
        $Result = Get-StatusFromLogLine -Line $StatusLine.Line -Language $TeamsLanguage
        if ($Result) {
            $State.Status = $Result.Status
            $State.Language = $Result.Language
        }
    }

    if ($ActivityLine) {
        $Line = $ActivityLine.Line
        if ($Line -like '*reportIncomingCall*') {
            $State.Activity = 'incoming_call'
        }
        elseif ($Line -like '*RequestNewOutgoingCallWithOptions*') {
            $State.Activity = 'outgoing_call'
        }
        elseif ($Line -like '*NotifyCallActive*' -or $Line -like '*NotifyCallAccepted*') {
            $State.Activity = 'in_call'
        }
        else {
            $State.Activity = 'not_in_call'
        }
    }
    return $State
}

function New-TeamsHttpClient {
    param([int]$TimeoutSeconds = 10)

    Add-Type -AssemblyName System.Net.Http
    # Windows PowerShell 5.1 may not offer TLS 1.2 by default
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12
    $Client = New-Object System.Net.Http.HttpClient
    $Client.Timeout = [TimeSpan]::FromSeconds($TimeoutSeconds)
    return $Client
}

# Starts sending status and activity to the Home Assistant webhook and returns
# the task; use Get-TeamsSendError when it is completed.
function Start-TeamsStatusSend {
    param(
        [System.Net.Http.HttpClient]$Client,
        [string]$WebhookUrl,
        [string]$Status,
        [string]$Activity,
        [string]$Language,
        [hashtable]$Extra
    )

    $Body = [ordered]@{ computer = $env:COMPUTERNAME; app_version = $script:TeamsAppVersion; platform = 'windows' }
    if ($Status) { $Body.status = $Status }
    if ($Activity) { $Body.activity = $Activity }
    if ($Language) { $Body.language = $Language }
    if ($Extra) {
        foreach ($Key in $Extra.Keys) { $Body[$Key] = $Extra[$Key] }
    }
    $Content = New-Object System.Net.Http.StringContent(
        ($Body | ConvertTo-Json -Compress),
        [System.Text.Encoding]::UTF8,
        'application/json'
    )
    return $Client.PostAsync($WebhookUrl, $Content)
}

# Returns $null if the completed send task succeeded, otherwise the reason
function Get-TeamsSendError {
    param([System.Threading.Tasks.Task]$Task)

    if ($Task.IsCanceled) {
        return 'Timeout'
    }
    if ($Task.IsFaulted) {
        $Exception = $Task.Exception
        while ($Exception.InnerException) {
            $Exception = $Exception.InnerException
        }
        return $Exception.Message
    }
    $Response = $Task.Result
    $Response.Dispose()
    if (-not $Response.IsSuccessStatusCode) {
        return 'HTTP {0} {1}' -f [int]$Response.StatusCode, $Response.ReasonPhrase
    }
    return $null
}

# Sends once and waits for the result; returns $null or the reason it failed
function Send-TeamsStatus {
    param(
        [string]$WebhookUrl,
        [string]$Status,
        [string]$Activity,
        [string]$Language,
        [hashtable]$Extra,
        [int]$TimeoutSeconds = 10
    )

    $Client = New-TeamsHttpClient -TimeoutSeconds $TimeoutSeconds
    try {
        $Task = Start-TeamsStatusSend -Client $Client -WebhookUrl $WebhookUrl -Status $Status -Activity $Activity -Language $Language -Extra $Extra
        try {
            [void]$Task.Wait()
        }
        catch {
            Write-Verbose $_.Exception.Message
        }
        return Get-TeamsSendError $Task
    }
    finally {
        $Client.Dispose()
    }
}

function Get-TeamsBrandImage {
    param([int]$Size = 48)

    $Source = [System.Drawing.Image]::FromFile((Join-Path $PSScriptRoot 'icon.png'))
    try {
        return New-Object System.Drawing.Bitmap($Source, $Size, $Size)
    }
    finally {
        $Source.Dispose()
    }
}

function New-TeamsFont {
    param([float]$Size = 9, [switch]$Bold)

    $Family = if ($Bold) { 'Segoe UI Semibold' } else { 'Segoe UI' }
    return New-Object System.Drawing.Font($Family, $Size)
}

# Settings window, also used as the installer window (-Install). Returns
# $null when cancelled, otherwise @{ Settings; Autostart; AddHosts }.
function Show-TeamsSettingsDialog {
    param(
        [pscustomobject]$Settings,
        [bool]$Autostart = $true,
        [switch]$Install,
        [bool]$LegacyFound = $false,
        [string]$Version = (Get-TeamsVersion),
        # Returns the text for "Copy diagnostics" (only in the tray app)
        [scriptblock]$Diagnostics
    )

    $Width = 660
    $Margin = 24
    $InnerWidth = $Width - 2 * $Margin
    $TextColor = [System.Drawing.Color]::FromArgb(45, 55, 72)
    $HintColor = [System.Drawing.Color]::FromArgb(105, 115, 130)

    $Form = New-Object System.Windows.Forms.Form
    $Form.Text = if ($Install) { $Messages.InstallTitle } else { $Messages.SettingsTitle }
    $Form.StartPosition = 'CenterScreen'
    $Form.FormBorderStyle = 'FixedDialog'
    $Form.MaximizeBox = $false
    $Form.MinimizeBox = $false
    $Form.ShowInTaskbar = $true
    $Form.TopMost = $true
    $Form.BackColor = [System.Drawing.Color]::FromArgb(245, 247, 250)
    $Form.Font = New-TeamsFont 9
    $Form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi
    $Form.Icon = New-Object System.Drawing.Icon((Join-Path $PSScriptRoot 'icon.ico'))

    $Header = New-Object System.Windows.Forms.Panel
    $Header.Location = New-Object System.Drawing.Point(0, 0)
    $Header.Size = New-Object System.Drawing.Size($Width, 88)
    $Header.BackColor = [System.Drawing.Color]::FromArgb(25, 45, 70)
    $Form.Controls.Add($Header)

    $BrandMark = New-Object System.Windows.Forms.PictureBox
    $BrandMark.Location = New-Object System.Drawing.Point($Margin, 20)
    $BrandMark.Size = New-Object System.Drawing.Size(48, 48)
    $BrandMark.SizeMode = [System.Windows.Forms.PictureBoxSizeMode]::Zoom
    $BrandMark.Image = Get-TeamsBrandImage 96
    $Header.Controls.Add($BrandMark)

    $Title = New-Object System.Windows.Forms.Label
    $Title.Location = New-Object System.Drawing.Point(88, 16)
    $Title.Size = New-Object System.Drawing.Size(540, 32)
    $Title.Text = $Messages.AppName
    $Title.Font = New-TeamsFont 16 -Bold
    $Title.ForeColor = [System.Drawing.Color]::White
    $Header.Controls.Add($Title)

    $Subtitle = New-Object System.Windows.Forms.Label
    $Subtitle.Location = New-Object System.Drawing.Point(90, 50)
    $Subtitle.Size = New-Object System.Drawing.Size(540, 22)
    $Subtitle.Text = $Messages.Subtitle
    $Subtitle.ForeColor = [System.Drawing.Color]::FromArgb(205, 216, 232)
    $Header.Controls.Add($Subtitle)

    $Y = 104

    # Adds a text card (info or warning) over the full width
    $AddCard = {
        param([string]$Text, [System.Drawing.Color]$Back, [System.Drawing.Color]$Fore)
        $Card = New-Object System.Windows.Forms.Label
        $Card.Location = New-Object System.Drawing.Point($Margin, $Y)
        $Card.Padding = New-Object System.Windows.Forms.Padding(12, 10, 12, 10)
        $Card.BackColor = $Back
        $Card.ForeColor = $Fore
        $Card.Text = $Text
        $Form.Controls.Add($Card)
        # Full width, as high as the wrapped text needs
        $TextSize = [System.Windows.Forms.TextRenderer]::MeasureText(
            $Text,
            $Card.Font,
            (New-Object System.Drawing.Size(($InnerWidth - 44), 0)),
            [System.Windows.Forms.TextFormatFlags]::WordBreak
        )
        $Card.Size = New-Object System.Drawing.Size($InnerWidth, ($TextSize.Height + 22))
        return $Card
    }

    if ($Install) {
        $Card = & $AddCard $Messages.InstallInfo ([System.Drawing.Color]::FromArgb(232, 240, 255)) ([System.Drawing.Color]::FromArgb(40, 65, 105))
        $Y = $Card.Bottom + 12
        if ($LegacyFound) {
            $Card = & $AddCard $Messages.InstallLegacy ([System.Drawing.Color]::FromArgb(255, 244, 222)) ([System.Drawing.Color]::FromArgb(110, 70, 10))
            $Y = $Card.Bottom + 12
        }
        $Y += 4
    }

    # Tabs like the macOS app: General, Detection, Networks. New settings go
    # into the fitting tab, so the window keeps its height.
    $Tabs = New-Object System.Windows.Forms.TabControl
    $Tabs.Location = New-Object System.Drawing.Point($Margin, $Y)
    $Tabs.Size = New-Object System.Drawing.Size($InnerWidth, 400)
    $Tabs.Padding = New-Object System.Drawing.Point(16, 5)
    $Form.Controls.Add($Tabs)

    $NewPage = {
        param([string]$Text)
        $Page = New-Object System.Windows.Forms.TabPage
        $Page.Text = $Text
        $Page.UseVisualStyleBackColor = $true
        [void]$Tabs.TabPages.Add($Page)
        return $Page
    }
    $GeneralPage = & $NewPage $Messages.TabGeneral
    $DetectionPage = & $NewPage $Messages.TabDetection
    $NetworksPage = & $NewPage $Messages.TabNetworks

    # Positions inside a tab page
    $PageMargin = 16
    # A tab page is about 8 px narrower than the TabControl (border); the
    # DisplayRectangle is not reliable before the window is shown
    $PageWidth = $InnerWidth - 8 - 2 * $PageMargin
    $ColumnWidth = [int](($PageWidth - 16) / 2)
    $SecondColumn = $PageMargin + $ColumnWidth + 16

    $AddLabel = {
        param([System.Windows.Forms.Control]$Parent, [string]$Text, [int]$X, [int]$Top, [int]$LabelWidth, [switch]$Hint)
        $Label = New-Object System.Windows.Forms.Label
        $Label.Location = New-Object System.Drawing.Point($X, $Top)
        $Label.Text = $Text
        if ($Hint) {
            $Label.ForeColor = $HintColor
            $Label.MaximumSize = New-Object System.Drawing.Size($LabelWidth, 0)
            $Label.AutoSize = $true
        }
        else {
            $Label.Size = New-Object System.Drawing.Size($LabelWidth, 20)
            $Label.Font = New-TeamsFont 9 -Bold
            $Label.ForeColor = $TextColor
        }
        $Parent.Controls.Add($Label)
        return $Label
    }

    $AddCheckBox = {
        param([System.Windows.Forms.Control]$Parent, [string]$Text, [int]$Top, [bool]$Checked)
        $CheckBox = New-Object System.Windows.Forms.CheckBox
        $CheckBox.Location = New-Object System.Drawing.Point($PageMargin, $Top)
        $CheckBox.Size = New-Object System.Drawing.Size($PageWidth, 24)
        $CheckBox.Text = $Text
        $CheckBox.Checked = $Checked
        $Parent.Controls.Add($CheckBox)
        return $CheckBox
    }

    $AddButton = {
        param([System.Windows.Forms.Control]$Parent, [string]$Text, [int]$X, [int]$Top, [int]$ButtonWidth)
        $Button = New-Object System.Windows.Forms.Button
        $Button.Location = New-Object System.Drawing.Point($X, $Top)
        $Button.Size = New-Object System.Drawing.Size($ButtonWidth, 32)
        $Button.Text = $Text
        $Button.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
        $Button.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(205, 213, 224)
        $Button.BackColor = [System.Drawing.Color]::White
        $Button.ForeColor = [System.Drawing.Color]::FromArgb(45, 80, 145)
        $Parent.Controls.Add($Button)
        return $Button
    }

    $AddResult = {
        param([System.Windows.Forms.Control]$Parent, [int]$X, [int]$Top)
        $Result = New-Object System.Windows.Forms.Label
        $Result.Location = New-Object System.Drawing.Point($X, ($Top + 2))
        $Result.Size = New-Object System.Drawing.Size(($PageMargin + $PageWidth - $X), 30)
        $Result.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
        $Result.AutoEllipsis = $true
        $Parent.Controls.Add($Result)
        return $Result
    }

    $AddNumber = {
        param([System.Windows.Forms.Control]$Parent, [int]$X, [int]$Top, [int]$Value, [int]$Minimum, [int]$Maximum)
        $Number = New-Object System.Windows.Forms.NumericUpDown
        $Number.Location = New-Object System.Drawing.Point($X, $Top)
        $Number.Size = New-Object System.Drawing.Size(90, 27)
        $Number.Minimum = $Minimum
        $Number.Maximum = $Maximum
        $Number.Value = [Math]::Min([Math]::Max($Value, $Minimum), $Maximum)
        $Parent.Controls.Add($Number)
        return $Number
    }

    # --- General: webhook with test, autostart, updates (installer: hosts file)
    $Y = 16
    [void](& $AddLabel $GeneralPage $Messages.Webhook $PageMargin $Y $PageWidth)
    $Y += 24
    $WebhookInput = New-Object System.Windows.Forms.TextBox
    $WebhookInput.Location = New-Object System.Drawing.Point($PageMargin, $Y)
    $WebhookInput.Size = New-Object System.Drawing.Size($PageWidth, 27)
    $WebhookInput.Font = New-TeamsFont 10
    $WebhookInput.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
    $WebhookInput.Text = $Settings.WebhookUrl
    $GeneralPage.Controls.Add($WebhookInput)
    $Y = $WebhookInput.Bottom + 4
    $Hint = & $AddLabel $GeneralPage $Messages.WebhookHint $PageMargin $Y $PageWidth -Hint
    $Y = $Hint.Bottom + 10
    $TestButton = & $AddButton $GeneralPage $Messages.Test $PageMargin $Y 130
    $TestResult = & $AddResult $GeneralPage ($PageMargin + 142) $Y
    $Y = $TestButton.Bottom + 18

    $AutostartInput = & $AddCheckBox $GeneralPage $Messages.Autostart $Y $Autostart
    $Y = $AutostartInput.Bottom + 2
    $UpdatesInput = & $AddCheckBox $GeneralPage $Messages.CheckForUpdates $Y ([bool]$Settings.CheckForUpdates)
    $Y = $UpdatesInput.Bottom + 6

    $HostsInput = $null
    if ($Install) {
        $HostsInput = & $AddCheckBox $GeneralPage $Messages.InstallHosts $Y $false
        $Y = $HostsInput.Bottom
        $Hint = & $AddLabel $GeneralPage $Messages.InstallHostsHint ($PageMargin + 18) $Y ($PageWidth - 18) -Hint
        $Y = $Hint.Bottom + 6
    }
    $PageHeights = @($Y + 10)

    # --- Detection: other calls, intervals, Teams language, diagnostics
    $Y = 16
    $OtherCallsInput = & $AddCheckBox $DetectionPage $Messages.DetectOtherCalls $Y ([bool]$Settings.DetectOtherCalls)
    $Y = $OtherCallsInput.Bottom
    $Hint = & $AddLabel $DetectionPage $Messages.DetectOtherCallsHint ($PageMargin + 18) $Y ($PageWidth - 18) -Hint
    $Y = $Hint.Bottom + 16

    [void](& $AddLabel $DetectionPage $Messages.Heartbeat $PageMargin $Y $ColumnWidth)
    [void](& $AddLabel $DetectionPage $Messages.Poll $SecondColumn $Y $ColumnWidth)
    $Y += 24
    $HeartbeatInput = & $AddNumber $DetectionPage $PageMargin $Y $Settings.HeartbeatSeconds 10 3600
    $PollInput = & $AddNumber $DetectionPage $SecondColumn $Y $Settings.PollSeconds 1 60
    $Y = $HeartbeatInput.Bottom + 4
    $Hint = & $AddLabel $DetectionPage $Messages.HeartbeatHint $PageMargin $Y $PageWidth -Hint
    $Y = $Hint.Bottom + 16

    [void](& $AddLabel $DetectionPage $Messages.TeamsLanguage $PageMargin $Y $PageWidth)
    $Y += 24
    $LanguageInput = New-Object System.Windows.Forms.ComboBox
    $LanguageInput.Location = New-Object System.Drawing.Point($PageMargin, $Y)
    $LanguageInput.Size = New-Object System.Drawing.Size($ColumnWidth, 27)
    $LanguageInput.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
    $LanguageCodes = @('auto', 'de', 'en')
    [void]$LanguageInput.Items.AddRange(@($Messages.TeamsLanguageAuto, $Messages.TeamsLanguageDe, $Messages.TeamsLanguageEn))
    $LanguageInput.SelectedIndex = [Math]::Max([array]::IndexOf($LanguageCodes, [string]$Settings.TeamsLanguage), 0)
    $DetectionPage.Controls.Add($LanguageInput)
    $Y = $LanguageInput.Bottom + 16

    $DiagnosticsButton = $null
    $DiagnosticsResult = $null
    if ($Diagnostics) {
        $DiagnosticsButton = & $AddButton $DetectionPage $Messages.CopyDiagnostics $PageMargin $Y 170
        $DiagnosticsResult = & $AddResult $DetectionPage ($PageMargin + 182) $Y
        $Y = $DiagnosticsButton.Bottom + 4
        $Hint = & $AddLabel $DetectionPage $Messages.DiagnosticsHint $PageMargin $Y $PageWidth -Hint
        $Y = $Hint.Bottom + 6
    }
    $PageHeights += $Y + 10

    # --- Networks: send only in these networks
    $Y = 16
    [void](& $AddLabel $NetworksPage $Messages.HomeNetworks $PageMargin $Y $PageWidth)
    $Y += 24
    $NetworkButtonWidth = 190
    $NetworksInput = New-Object System.Windows.Forms.TextBox
    $NetworksInput.Location = New-Object System.Drawing.Point($PageMargin, $Y)
    $NetworksInput.Size = New-Object System.Drawing.Size(($PageWidth - $NetworkButtonWidth - 10), 27)
    $NetworksInput.Font = New-TeamsFont 10
    $NetworksInput.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
    $NetworksInput.Text = [string]$Settings.HomeNetworks
    $NetworksPage.Controls.Add($NetworksInput)
    $NetworkButton = & $AddButton $NetworksPage $Messages.AddCurrentNetwork ($PageMargin + $PageWidth - $NetworkButtonWidth) ($Y - 2) $NetworkButtonWidth
    $Y = $NetworksInput.Bottom + 4
    $Hint = & $AddLabel $NetworksPage $Messages.HomeNetworksHint $PageMargin $Y $PageWidth -Hint
    $Y = $Hint.Bottom + 8
    $AskNetworksInput = & $AddCheckBox $NetworksPage $Messages.AskForNewNetworks $Y ([bool]$Settings.AskForNewNetworks)
    $Y = $AskNetworksInput.Bottom
    $PageHeights += $Y + 10

    # As high as the tallest page
    $Tabs.Height = ($PageHeights | Measure-Object -Maximum).Maximum + $Tabs.ItemSize.Height + 12
    $Y = $Tabs.Bottom + 20

    $OkButton = New-Object System.Windows.Forms.Button
    $OkButton.Size = New-Object System.Drawing.Size(124, 36)
    $OkButton.Location = New-Object System.Drawing.Point(($Width - $Margin - 124), $Y)
    $OkButton.Text = if ($Install) { $Messages.Install } else { $Messages.Save }
    $OkButton.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $OkButton.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $OkButton.FlatAppearance.BorderSize = 0
    $OkButton.BackColor = [System.Drawing.Color]::FromArgb(45, 100, 210)
    $OkButton.ForeColor = [System.Drawing.Color]::White
    $OkButton.Font = New-TeamsFont 9 -Bold
    $Form.Controls.Add($OkButton)

    $CancelButton = New-Object System.Windows.Forms.Button
    $CancelButton.Size = New-Object System.Drawing.Size(114, 36)
    $CancelButton.Location = New-Object System.Drawing.Point(($OkButton.Left - 124), $Y)
    $CancelButton.Text = $Messages.Cancel
    $CancelButton.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $CancelButton.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $CancelButton.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(205, 213, 224)
    $CancelButton.BackColor = [System.Drawing.Color]::White
    $CancelButton.ForeColor = [System.Drawing.Color]::FromArgb(55, 65, 80)
    $Form.Controls.Add($CancelButton)

    if ($Version -and $Version -ne '0.0.0') {
        $VersionLabel = New-Object System.Windows.Forms.Label
        $VersionLabel.Location = New-Object System.Drawing.Point($Margin, ($Y + 9))
        $VersionLabel.Size = New-Object System.Drawing.Size(200, 20)
        $VersionLabel.Text = $Messages.Version -f $Version
        $VersionLabel.ForeColor = $HintColor
        $Form.Controls.Add($VersionLabel)
    }

    $Form.ClientSize = New-Object System.Drawing.Size($Width, ($OkButton.Bottom + $Margin))
    $Form.AcceptButton = $OkButton
    $Form.CancelButton = $CancelButton

    $ShowInvalidWebhook = {
        [void][System.Windows.Forms.MessageBox]::Show(
            $Form,
            $Messages.InvalidWebhook,
            $Messages.InvalidTitle,
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        )
    }

    $NetworkButton.Add_Click({
        $Current = @(Get-TeamsCurrentNetworks)
        if ($Current.Count -eq 0) {
            [void][System.Windows.Forms.MessageBox]::Show($Form, $Messages.NoCurrentNetwork, $Messages.AppName)
            return
        }
        $NetworksInput.Text = Add-TeamsNetworkText $NetworksInput.Text $Current
    })

    $TestButton.Add_Click({
        $Url = $WebhookInput.Text.Trim()
        if (-not (Test-WebhookUrl $Url)) {
            & $ShowInvalidWebhook
            return
        }
        $TestButton.Enabled = $false
        $TestResult.ForeColor = $HintColor
        $TestResult.Text = $Messages.Testing
        $Form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        $Form.Refresh()
        try {
            $Current = Get-TeamsState -TeamsLanguage $LanguageCodes[$LanguageInput.SelectedIndex]
            if (-not $Current.Activity) { $Current.Activity = 'not_in_call' }
            $SendError = Send-TeamsStatus -WebhookUrl $Url -Status $Current.Status -Activity $Current.Activity -Language $Current.Language
            if ($SendError) {
                $TestResult.ForeColor = [System.Drawing.Color]::FromArgb(170, 40, 40)
                $TestResult.Text = $Messages.TestFailed -f $SendError
            }
            else {
                $StatusKey = if ($Current.Status) { $Current.Status } else { 'unknown' }
                $TestResult.ForeColor = [System.Drawing.Color]::FromArgb(30, 120, 60)
                $TestResult.Text = $Messages.TestOk -f $Messages.StatusNames.$StatusKey
            }
        }
        finally {
            $Form.Cursor = [System.Windows.Forms.Cursors]::Default
            $TestButton.Enabled = $true
        }
    })

    if ($DiagnosticsButton) {
        $DiagnosticsButton.Add_Click({
            try {
                [System.Windows.Forms.Clipboard]::SetText((& $Diagnostics))
                $DiagnosticsResult.ForeColor = [System.Drawing.Color]::FromArgb(30, 120, 60)
                $DiagnosticsResult.Text = $Messages.DiagnosticsCopied
            }
            catch {
                $DiagnosticsResult.ForeColor = [System.Drawing.Color]::FromArgb(170, 40, 40)
                $DiagnosticsResult.Text = $_.Exception.Message
            }
        })
    }

    $Form.Add_Shown({ $Form.Activate(); $WebhookInput.Focus() })

    try {
        while ($Form.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $Url = $WebhookInput.Text.Trim()
            if (-not (Test-WebhookUrl $Url)) {
                $Tabs.SelectedTab = $GeneralPage
                & $ShowInvalidWebhook
                continue
            }
            $Networks = $NetworksInput.Text.Trim()
            $InvalidNetwork = Find-TeamsInvalidNetwork $Networks
            if ($InvalidNetwork) {
                $Tabs.SelectedTab = $NetworksPage
                [void][System.Windows.Forms.MessageBox]::Show(
                    $Form,
                    ($Messages.InvalidNetwork -f $InvalidNetwork),
                    $Messages.InvalidTitle,
                    [System.Windows.Forms.MessageBoxButtons]::OK,
                    [System.Windows.Forms.MessageBoxIcon]::Warning
                )
                continue
            }
            $NewSettings = [pscustomobject][ordered]@{
                WebhookUrl = $Url
                HeartbeatSeconds = [int]$HeartbeatInput.Value
                PollSeconds = [int]$PollInput.Value
                TeamsLanguage = $LanguageCodes[$LanguageInput.SelectedIndex]
                CheckForUpdates = $UpdatesInput.Checked
                HomeNetworks = $Networks
                AskForNewNetworks = $AskNetworksInput.Checked
                IgnoredNetworks = [string]$Settings.IgnoredNetworks
                DetectOtherCalls = $OtherCallsInput.Checked
            }
            return @{
                Settings = $NewSettings
                Autostart = $AutostartInput.Checked
                AddHosts = [bool]($HostsInput -and $HostsInput.Checked)
            }
        }
        return $null
    }
    finally {
        $Form.Dispose()
    }
}
