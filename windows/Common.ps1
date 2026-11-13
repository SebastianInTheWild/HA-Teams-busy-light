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

# Installed version (version.txt, written by the installer), "0.0.0" if unknown
function Get-TeamsVersion {
    param([string]$Root = $PSScriptRoot)

    $VersionFile = Join-Path $Root 'version.txt'
    if (Test-Path $VersionFile) {
        return (Get-Content -Path $VersionFile -TotalCount 1).Trim()
    }
    return '0.0.0'
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
        [string]$Language
    )

    $Body = [ordered]@{ computer = $env:COMPUTERNAME }
    if ($Status) { $Body.status = $Status }
    if ($Activity) { $Body.activity = $Activity }
    if ($Language) { $Body.language = $Language }
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
        [int]$TimeoutSeconds = 10
    )

    $Client = New-TeamsHttpClient -TimeoutSeconds $TimeoutSeconds
    try {
        $Task = Start-TeamsStatusSend -Client $Client -WebhookUrl $WebhookUrl -Status $Status -Activity $Activity -Language $Language
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
        [string]$Version = (Get-TeamsVersion)
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

    $AddLabel = {
        param([string]$Text, [int]$X, [int]$Top, [int]$LabelWidth, [switch]$Hint)
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
        $Form.Controls.Add($Label)
        return $Label
    }

    [void](& $AddLabel $Messages.Webhook $Margin $Y $InnerWidth)
    $Y += 24
    $WebhookInput = New-Object System.Windows.Forms.TextBox
    $WebhookInput.Location = New-Object System.Drawing.Point($Margin, $Y)
    $WebhookInput.Size = New-Object System.Drawing.Size($InnerWidth, 27)
    $WebhookInput.Font = New-TeamsFont 10
    $WebhookInput.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
    $WebhookInput.Text = $Settings.WebhookUrl
    $Form.Controls.Add($WebhookInput)
    $Y = $WebhookInput.Bottom + 4
    $Hint = & $AddLabel $Messages.WebhookHint $Margin $Y $InnerWidth -Hint
    $Y = $Hint.Bottom + 16

    $ColumnWidth = [int](($InnerWidth - 16) / 2)
    $SecondColumn = $Margin + $ColumnWidth + 16

    $AddNumber = {
        param([int]$X, [int]$Top, [int]$Value, [int]$Minimum, [int]$Maximum)
        $Number = New-Object System.Windows.Forms.NumericUpDown
        $Number.Location = New-Object System.Drawing.Point($X, $Top)
        $Number.Size = New-Object System.Drawing.Size(90, 27)
        $Number.Minimum = $Minimum
        $Number.Maximum = $Maximum
        $Number.Value = [Math]::Min([Math]::Max($Value, $Minimum), $Maximum)
        $Form.Controls.Add($Number)
        return $Number
    }

    [void](& $AddLabel $Messages.Heartbeat $Margin $Y $ColumnWidth)
    [void](& $AddLabel $Messages.Poll $SecondColumn $Y $ColumnWidth)
    $Y += 24
    $HeartbeatInput = & $AddNumber $Margin $Y $Settings.HeartbeatSeconds 10 3600
    $PollInput = & $AddNumber $SecondColumn $Y $Settings.PollSeconds 1 60
    $Y = $HeartbeatInput.Bottom + 4
    $Hint = & $AddLabel $Messages.HeartbeatHint $Margin $Y $InnerWidth -Hint
    $Y = $Hint.Bottom + 16

    [void](& $AddLabel $Messages.TeamsLanguage $Margin $Y $InnerWidth)
    $Y += 24
    $LanguageInput = New-Object System.Windows.Forms.ComboBox
    $LanguageInput.Location = New-Object System.Drawing.Point($Margin, $Y)
    $LanguageInput.Size = New-Object System.Drawing.Size($ColumnWidth, 27)
    $LanguageInput.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
    $LanguageCodes = @('auto', 'de', 'en')
    [void]$LanguageInput.Items.AddRange(@($Messages.TeamsLanguageAuto, $Messages.TeamsLanguageDe, $Messages.TeamsLanguageEn))
    $LanguageInput.SelectedIndex = [Math]::Max([array]::IndexOf($LanguageCodes, [string]$Settings.TeamsLanguage), 0)
    $Form.Controls.Add($LanguageInput)
    $Y = $LanguageInput.Bottom + 16

    [void](& $AddLabel $Messages.HomeNetworks $Margin $Y $InnerWidth)
    $Y += 24
    $NetworkButtonWidth = 190
    $NetworksInput = New-Object System.Windows.Forms.TextBox
    $NetworksInput.Location = New-Object System.Drawing.Point($Margin, $Y)
    $NetworksInput.Size = New-Object System.Drawing.Size(($InnerWidth - $NetworkButtonWidth - 10), 27)
    $NetworksInput.Font = New-TeamsFont 10
    $NetworksInput.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
    $NetworksInput.Text = [string]$Settings.HomeNetworks
    $Form.Controls.Add($NetworksInput)
    $NetworkButton = New-Object System.Windows.Forms.Button
    $NetworkButton.Location = New-Object System.Drawing.Point(($Margin + $InnerWidth - $NetworkButtonWidth), ($Y - 1))
    $NetworkButton.Size = New-Object System.Drawing.Size($NetworkButtonWidth, 29)
    $NetworkButton.Text = $Messages.AddCurrentNetwork
    $NetworkButton.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $NetworkButton.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(205, 213, 224)
    $NetworkButton.BackColor = [System.Drawing.Color]::White
    $NetworkButton.ForeColor = [System.Drawing.Color]::FromArgb(45, 80, 145)
    $Form.Controls.Add($NetworkButton)
    $Y = $NetworksInput.Bottom + 4
    $Hint = & $AddLabel $Messages.HomeNetworksHint $Margin $Y $InnerWidth -Hint
    $Y = $Hint.Bottom + 4
    $AskNetworksInput = New-Object System.Windows.Forms.CheckBox
    $AskNetworksInput.Location = New-Object System.Drawing.Point($Margin, $Y)
    $AskNetworksInput.Size = New-Object System.Drawing.Size($InnerWidth, 24)
    $AskNetworksInput.Text = $Messages.AskForNewNetworks
    $AskNetworksInput.Checked = [bool]$Settings.AskForNewNetworks
    $Form.Controls.Add($AskNetworksInput)
    $Y = $AskNetworksInput.Bottom + 16

    $AutostartInput = New-Object System.Windows.Forms.CheckBox
    $AutostartInput.Location = New-Object System.Drawing.Point($Margin, $Y)
    $AutostartInput.Size = New-Object System.Drawing.Size($InnerWidth, 24)
    $AutostartInput.Text = $Messages.Autostart
    $AutostartInput.Checked = $Autostart
    $Form.Controls.Add($AutostartInput)
    $Y = $AutostartInput.Bottom + 2

    $UpdatesInput = New-Object System.Windows.Forms.CheckBox
    $UpdatesInput.Location = New-Object System.Drawing.Point($Margin, $Y)
    $UpdatesInput.Size = New-Object System.Drawing.Size($InnerWidth, 24)
    $UpdatesInput.Text = $Messages.CheckForUpdates
    $UpdatesInput.Checked = [bool]$Settings.CheckForUpdates
    $Form.Controls.Add($UpdatesInput)
    $Y = $UpdatesInput.Bottom + 6

    $HostsInput = $null
    if ($Install) {
        $HostsInput = New-Object System.Windows.Forms.CheckBox
        $HostsInput.Location = New-Object System.Drawing.Point($Margin, $Y)
        $HostsInput.Size = New-Object System.Drawing.Size($InnerWidth, 24)
        $HostsInput.Text = $Messages.InstallHosts
        $Form.Controls.Add($HostsInput)
        $Y = $HostsInput.Bottom
        $Hint = & $AddLabel $Messages.InstallHostsHint ($Margin + 18) $Y ($InnerWidth - 18) -Hint
        $Y = $Hint.Bottom + 6
    }
    $Y += 14

    $TestButton = New-Object System.Windows.Forms.Button
    $TestButton.Location = New-Object System.Drawing.Point($Margin, $Y)
    $TestButton.Size = New-Object System.Drawing.Size(130, 32)
    $TestButton.Text = $Messages.Test
    $TestButton.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $TestButton.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(205, 213, 224)
    $TestButton.BackColor = [System.Drawing.Color]::White
    $TestButton.ForeColor = [System.Drawing.Color]::FromArgb(45, 80, 145)
    $Form.Controls.Add($TestButton)

    $TestResult = New-Object System.Windows.Forms.Label
    $TestResult.Location = New-Object System.Drawing.Point(($Margin + 142), ($Y + 2))
    $TestResult.Size = New-Object System.Drawing.Size(($InnerWidth - 142), 30)
    $TestResult.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
    $TestResult.AutoEllipsis = $true
    $Form.Controls.Add($TestResult)
    $Y = $TestButton.Bottom + 24

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

    $Form.Add_Shown({ $Form.Activate(); $WebhookInput.Focus() })

    try {
        while ($Form.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $Url = $WebhookInput.Text.Trim()
            if (-not (Test-WebhookUrl $Url)) {
                & $ShowInvalidWebhook
                continue
            }
            $Networks = $NetworksInput.Text.Trim()
            $InvalidNetwork = Find-TeamsInvalidNetwork $Networks
            if ($InvalidNetwork) {
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
