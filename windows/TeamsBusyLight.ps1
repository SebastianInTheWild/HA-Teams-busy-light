<#
.SYNOPSIS
    Teams Busy Light for Windows: sends the Microsoft Teams status to Home
    Assistant and shows it in the notification area of the taskbar.
.DESCRIPTION
    Runs for the signed-in Windows user (started by TeamsBusyLight.exe at
    sign-in). It reads the status of the new Teams client from its logfile and
    sends it to the "Teams Busy Light" custom integration in Home Assistant via
    its webhook:
    - Status: the availability, taken from the taskbar icon overlay that Teams
      logs in the language of the app (see Languages.ps1).
    - Activity: whether you are in a call, from the call events in the log.
    Both are sent as language-neutral states (e.g. "busy", "in_call") on every
    change and as keep-alive; Home Assistant shows them translated.

    The tray icon shows the status as a colored dot; its menu opens the
    settings (webhook URL, intervals, Teams language, autostart).
.PARAMETER SetStatus
    Sends a status once and exits, e.g. available, busy, away, offline.
.PARAMETER SetActivity
    Optional activity to send together with SetStatus, e.g. not_in_call.
.PARAMETER Settings
    Opens the settings window after start. If Teams Busy Light is already
    running, the running instance opens it.
.EXAMPLE
    .\TeamsBusyLight.ps1 -SetStatus busy
#>
param(
    [string]$SetStatus,
    [string]$SetActivity,
    [switch]$Settings
)

. (Join-Path $PSScriptRoot 'Common.ps1')
$Messages = Get-TeamsMessages

# Send a status once when called with -SetStatus
if ($SetStatus) {
    $Current = Read-TeamsSettings
    if (-not $Current.WebhookUrl) {
        throw $Messages.MissingWebhook
    }
    Write-Output ($Messages.StatusSet -f $SetStatus)
    $SendError = Send-TeamsStatus -WebhookUrl $Current.WebhookUrl -Status $SetStatus -Activity $SetActivity
    if ($SendError) {
        throw ($Messages.LogSendFailed -f $SendError)
    }
    Write-Output $Messages.StatusSetSuccess
    return
}

Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms
[System.Windows.Forms.Application]::EnableVisualStyles()

# Only one instance per Windows user; starting it again opens the settings
$CreatedNew = $false
$InstanceMutex = New-Object System.Threading.Mutex($true, $InstanceMutexName, [ref]$CreatedNew)
if (-not $CreatedNew) {
    [void](Send-TeamsInstanceSignal $ShowSettingsEventName)
    return
}
$ShowSettingsEvent = New-Object System.Threading.EventWaitHandle($false, [System.Threading.EventResetMode]::AutoReset, $ShowSettingsEventName)
$ExitEvent = New-Object System.Threading.EventWaitHandle($false, [System.Threading.EventResetMode]::AutoReset, $ExitEventName)

$Config = Read-TeamsSettings
$Http = New-TeamsHttpClient
$UpdateHttp = New-TeamsHttpClient -TimeoutSeconds 30
# The GitHub API needs a User-Agent
$UpdateHttp.DefaultRequestHeaders.UserAgent.ParseAdd('TeamsBusyLight')

# Current and last sent state
$State = @{
    Status = $null
    # Sent activity: the Teams one or, with DetectOtherCalls, in_call while
    # any app uses the microphone
    Activity = 'not_in_call'
    TeamsActivity = 'not_in_call'
    # $null = unknown (this Windows version does not report it)
    Camera = $null
    Microphone = $false
    MicrophoneApps = @()
    MicrophoneSource = $null
    CameraSource = $null
    Manual = Get-TeamsManualStatus
    Language = $null
    # What was sent last (status, activity, camera, microphone, source)
    SentKey = $null
    SendKey = $null
    LoggedStatus = $null
    LastSent = [datetime]::MinValue
    LastPoll = [datetime]::MinValue
    RetryAfter = [datetime]::MinValue
    SendTask = $null
    SendError = $null
    LogMissing = $false
    SettingsOpen = $false
    UpdateTask = $null
    UpdateVersion = $null
    LastUpdateCheck = [datetime]::MinValue
    Away = $false
    LastNetworkCheck = [datetime]::MinValue
    AskingNetwork = $false
    PausedUntil = Get-TeamsPause
    UpdateAssetUrl = $null
    UpdateDownload = $null
    UpdateInstaller = $null
    UpdateDir = $null
    Updating = $false
}
$AppVersion = Get-TeamsVersion

# --- Tray icon -------------------------------------------------------------

$DotColors = @{
    available = [System.Drawing.Color]::FromArgb(92, 184, 92)
    busy = [System.Drawing.Color]::FromArgb(212, 52, 70)
    away = [System.Drawing.Color]::FromArgb(250, 176, 40)
    offline = [System.Drawing.Color]::FromArgb(150, 150, 150)
}
$StatusColorKey = @{
    available = 'available'
    busy = 'busy'
    in_a_call = 'busy'
    in_a_meeting = 'busy'
    presenting = 'busy'
    focusing = 'busy'
    do_not_disturb = 'busy'
    be_right_back = 'away'
    away = 'away'
    offline = 'offline'
}
$BrandImage = Get-TeamsBrandImage 64
$IconCache = @{}

# Brand icon with a colored dot in the lower right corner
function Get-StatusIcon {
    param([string]$ColorKey)

    if ($IconCache.ContainsKey($ColorKey)) {
        return $IconCache[$ColorKey]
    }
    $Size = 32
    $Bitmap = New-Object System.Drawing.Bitmap($Size, $Size)
    $Graphics = [System.Drawing.Graphics]::FromImage($Bitmap)
    $Graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $Graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $Graphics.DrawImage($BrandImage, 0, 0, $Size, $Size)
    if ($DotColors.ContainsKey($ColorKey)) {
        $Dot = 16
        $Ring = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::White)
        $Fill = New-Object System.Drawing.SolidBrush($DotColors[$ColorKey])
        $Graphics.FillEllipse($Ring, $Size - $Dot, $Size - $Dot, $Dot, $Dot)
        $Graphics.FillEllipse($Fill, $Size - $Dot + 2, $Size - $Dot + 2, $Dot - 4, $Dot - 4)
        $Ring.Dispose()
        $Fill.Dispose()
    }
    $Graphics.Dispose()
    $Icon = [System.Drawing.Icon]::FromHandle($Bitmap.GetHicon())
    $IconCache[$ColorKey] = $Icon
    return $Icon
}

$Tray = New-Object System.Windows.Forms.NotifyIcon
$Tray.Icon = Get-StatusIcon 'none'
$Tray.Text = $Messages.AppName

$Menu = New-Object System.Windows.Forms.ContextMenuStrip
$StatusItem = New-Object System.Windows.Forms.ToolStripMenuItem
$StatusItem.Enabled = $false
$ActivityItem = New-Object System.Windows.Forms.ToolStripMenuItem
$ActivityItem.Enabled = $false
$ConnectionItem = New-Object System.Windows.Forms.ToolStripMenuItem
$ConnectionItem.Enabled = $false
$SettingsItem = New-Object System.Windows.Forms.ToolStripMenuItem($Messages.MenuSettings)
$SettingsItem.Font = New-Object System.Drawing.Font($SettingsItem.Font, [System.Drawing.FontStyle]::Bold)
$LogItem = New-Object System.Windows.Forms.ToolStripMenuItem($Messages.MenuOpenLog)
$UpdateItem = New-Object System.Windows.Forms.ToolStripMenuItem
$UpdateItem.Visible = $false
$PauseItem = New-Object System.Windows.Forms.ToolStripMenuItem($Messages.MenuPause)
foreach ($Choice in @(@($Messages.Pause1h, 1), @($Messages.Pause8h, 8), @($Messages.Pause1d, 24), @($Messages.PauseAlways, 0))) {
    $Item = New-Object System.Windows.Forms.ToolStripMenuItem($Choice[0])
    $Item.Tag = $Choice[1]
    $Item.Add_Click({
        param($EventSender)
        $Hours = [int]$EventSender.Tag
        Suspend-TeamsSending $(if ($Hours -eq 0) { [datetime]::MaxValue } else { (Get-Date).AddHours($Hours) })
    })
    [void]$PauseItem.DropDownItems.Add($Item)
}
$ResumeItem = New-Object System.Windows.Forms.ToolStripMenuItem($Messages.MenuResume)
$SetStatusItem = New-Object System.Windows.Forms.ToolStripMenuItem($Messages.MenuSetStatus)
foreach ($ManualStatus in $ManualStatuses) {
    $StatusChoice = New-Object System.Windows.Forms.ToolStripMenuItem($Messages.StatusNames.$ManualStatus)
    foreach ($Choice in @(@($Messages.Manual30m, 30), @($Messages.Manual1h, 60), @($Messages.Manual2h, 120), @($Messages.ManualAlways, 0))) {
        $Item = New-Object System.Windows.Forms.ToolStripMenuItem($Choice[0])
        $Item.Tag = @($ManualStatus, $Choice[1])
        $Item.Add_Click({
            param($EventSender)
            $Minutes = [int]$EventSender.Tag[1]
            Set-TeamsManualState $EventSender.Tag[0] $(if ($Minutes -eq 0) { [datetime]::MaxValue } else { (Get-Date).AddMinutes($Minutes) })
        })
        [void]$StatusChoice.DropDownItems.Add($Item)
    }
    [void]$SetStatusItem.DropDownItems.Add($StatusChoice)
}
$UseTeamsItem = New-Object System.Windows.Forms.ToolStripMenuItem($Messages.MenuUseTeamsStatus)
$ExitItem = New-Object System.Windows.Forms.ToolStripMenuItem($Messages.MenuExit)
[void]$Menu.Items.Add($StatusItem)
[void]$Menu.Items.Add($ActivityItem)
[void]$Menu.Items.Add($ConnectionItem)
[void]$Menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
[void]$Menu.Items.Add($SetStatusItem)
[void]$Menu.Items.Add($UseTeamsItem)
[void]$Menu.Items.Add($PauseItem)
[void]$Menu.Items.Add($ResumeItem)
[void]$Menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
[void]$Menu.Items.Add($SettingsItem)
[void]$Menu.Items.Add($LogItem)
[void]$Menu.Items.Add($UpdateItem)
[void]$Menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
[void]$Menu.Items.Add($ExitItem)
$Tray.ContextMenuStrip = $Menu

function Format-TeamsTime {
    param([datetime]$Time)
    if ($Time.Date -eq (Get-Date).Date) { $Time.ToString('t') } else { $Time.ToString('g') }
}

function Update-TrayDisplay {
    $EffectiveStatus = Get-TeamsEffectiveStatus
    $StatusKey = if ($EffectiveStatus) { $EffectiveStatus } else { 'unknown' }
    $StatusName = $Messages.StatusNames.$StatusKey
    $ActivityName = $Messages.ActivityNames.($State.Activity)

    if (Test-TeamsManualActive) {
        $StatusItem.Text = if ($State.Manual.Until -eq [datetime]::MaxValue) {
            $Messages.MenuStatusManualAlways -f $StatusName
        }
        else {
            $Messages.MenuStatusManual -f $StatusName, (Format-TeamsTime $State.Manual.Until)
        }
    }
    else {
        $StatusItem.Text = $Messages.MenuStatus -f $StatusName
    }
    if ($State.Activity -eq 'in_call' -and $State.TeamsActivity -eq 'not_in_call') {
        $Apps = if ($State.MicrophoneApps.Count) { $State.MicrophoneApps -join ', ' } else { '?' }
        $ActivityItem.Text = $Messages.MenuActivityOther -f $Apps
    }
    else {
        $ActivityItem.Text = $Messages.MenuActivity -f $ActivityName
    }
    $UseTeamsItem.Visible = Test-TeamsManualActive
    if (-not $Config.WebhookUrl) {
        $ConnectionItem.Text = $Messages.MenuNotConfigured
    }
    elseif ($State.PausedUntil) {
        $ConnectionItem.Text = if ($State.PausedUntil -eq [datetime]::MaxValue) {
            $Messages.MenuPausedAlways
        }
        else {
            $Messages.MenuPausedUntil -f (Format-TeamsTime $State.PausedUntil)
        }
    }
    elseif ($State.Away) {
        $ConnectionItem.Text = $Messages.MenuAway
    }
    elseif ($State.SendError) {
        $ConnectionItem.Text = $Messages.MenuSendFailed
    }
    elseif ($State.LastSent -ne [datetime]::MinValue) {
        $ConnectionItem.Text = $Messages.MenuSentAt -f $State.LastSent.ToString('T')
    }
    else {
        $ConnectionItem.Text = $Messages.MenuSentAt -f '-'
    }

    $ResumeItem.Visible = [bool]$State.PausedUntil

    $ColorKey = if ($EffectiveStatus -and $StatusColorKey.ContainsKey($EffectiveStatus)) { $StatusColorKey[$EffectiveStatus] } else { 'none' }
    if ($State.Activity -ne 'not_in_call') {
        $ColorKey = 'busy'
    }
    $Tray.Icon = Get-StatusIcon $ColorKey

    $Tooltip = "Teams Busy Light: $StatusName"
    if ($State.Activity -ne 'not_in_call') {
        $Tooltip += " ($ActivityName)"
    }
    if ($State.PausedUntil) {
        $Tooltip += " - " + $Messages.TooltipPaused
    }
    elseif (-not $Config.WebhookUrl -or $State.SendError) {
        $Tooltip += " - HA " + $Messages.TooltipError
    }
    # The tooltip of a NotifyIcon is limited to 63 characters
    if ($Tooltip.Length -gt 63) {
        $Tooltip = $Tooltip.Substring(0, 63)
    }
    $Tray.Text = $Tooltip
}

# --- Updates ---------------------------------------------------------------
# Checks the latest GitHub release once a day. If its Windows download can be
# checked (pinned certificate), the menu offers to install it; otherwise it
# only links to the release page. Nothing is installed without confirmation.

function Set-TeamsUpdateItem {
    if ($State.Updating) {
        $UpdateItem.Text = $Messages.MenuUpdating -f $State.UpdateVersion
        $UpdateItem.Enabled = $false
    }
    elseif ($State.UpdateAssetUrl) {
        $UpdateItem.Text = $Messages.MenuInstallUpdate -f $State.UpdateVersion
        $UpdateItem.Enabled = $true
    }
    else {
        $UpdateItem.Text = $Messages.MenuUpdate -f $State.UpdateVersion
        $UpdateItem.Enabled = $true
    }
    $UpdateItem.Visible = [bool]$State.UpdateVersion
}

function Invoke-TeamsUpdateAction {
    if (-not $State.UpdateVersion -or $State.Updating) {
        return
    }
    if (-not $State.UpdateAssetUrl) {
        Start-Process $ReleasesPage
        return
    }
    $Answer = Show-TeamsMessageBox -Text ($Messages.UpdateConfirm -f $State.UpdateVersion) -Caption $Messages.AppName `
        -Buttons YesNo -Icon Question
    if ($Answer -ne [System.Windows.Forms.DialogResult]::Yes) {
        return
    }
    Write-TeamsLog "Downloading update $($State.UpdateVersion)"
    $State.Updating = $true
    $State.UpdateDownload = $UpdateHttp.GetByteArrayAsync($State.UpdateAssetUrl)
    Set-TeamsUpdateItem
}

function Stop-TeamsUpdate {
    param([string]$Reason)

    Write-TeamsLog "Update to $($State.UpdateVersion) failed: $Reason"
    $State.Updating = $false
    $State.UpdateDownload = $null
    $State.UpdateInstaller = $null
    if ($State.UpdateDir) {
        Remove-Item -LiteralPath $State.UpdateDir -Recurse -Force -ErrorAction SilentlyContinue
        $State.UpdateDir = $null
    }
    Set-TeamsUpdateItem
    [void](Show-TeamsMessageBox -Text ($Messages.UpdateFailed -f $State.UpdateVersion, $Reason) -Caption $Messages.AppName -Icon Warning)
}

# Unpacks and checks the download, then starts its installer. The installer
# stops this instance and starts the new version.
function Install-TeamsUpdate {
    param([byte[]]$Bytes)

    $State.UpdateDir = Join-Path ([System.IO.Path]::GetTempPath()) ('TeamsBusyLight-Update-{0}' -f [guid]::NewGuid())
    New-Item -Path $State.UpdateDir -ItemType Directory | Out-Null
    $ZipPath = Join-Path $State.UpdateDir $ReleaseAssetName
    [System.IO.File]::WriteAllBytes($ZipPath, $Bytes)
    $FilesDir = Join-Path $State.UpdateDir 'files'
    Expand-TeamsZip -ZipPath $ZipPath -Destination $FilesDir
    $SourceDir = Join-Path $FilesDir 'TeamsBusyLight-Windows'
    if (-not (Test-Path (Join-Path $SourceDir 'Install.ps1'))) {
        throw 'unexpected content of the download'
    }
    $Problem = Test-TeamsReleaseSignature -Path $SourceDir
    if ($Problem) {
        throw "signature check failed: $Problem"
    }
    # A correctly signed older release must not be installed instead
    $DownloadVersion = Get-TeamsVersion -Root $SourceDir
    if ($DownloadVersion -ne $State.UpdateVersion) {
        throw "the download contains version $DownloadVersion"
    }
    Get-ChildItem -LiteralPath $SourceDir -Recurse -File | Unblock-File
    Write-TeamsLog "Update $DownloadVersion checked, starting the installer"
    # Working directory outside the program folder, which the installer replaces
    $State.UpdateInstaller = Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -WorkingDirectory $SourceDir -PassThru -ArgumentList @(
        '-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
        '-File', ('"{0}"' -f (Join-Path $SourceDir 'Install.ps1')), '-Quiet')
}

function Complete-TeamsUpdate {
    if (-not $State.Updating) {
        return
    }
    $Task = $State.UpdateDownload
    if ($Task) {
        if (-not $Task.IsCompleted) {
            return
        }
        $State.UpdateDownload = $null
        if ($Task.Status -ne [System.Threading.Tasks.TaskStatus]::RanToCompletion) {
            $Reason = if ($Task.Exception) { $Task.Exception.GetBaseException().Message } else { 'download cancelled' }
            Stop-TeamsUpdate "download failed: $Reason"
            return
        }
        try {
            Install-TeamsUpdate $Task.Result
        }
        catch {
            Stop-TeamsUpdate $_.Exception.Message
        }
        return
    }
    # Still running after the installer has finished: it failed
    if ($State.UpdateInstaller -and $State.UpdateInstaller.HasExited) {
        Stop-TeamsUpdate $Messages.UpdateInstallerFailed
    }
}

# Removes update folders of earlier updates
function Clear-TeamsUpdateFolders {
    Get-ChildItem -Path ([System.IO.Path]::GetTempPath()) -Filter 'TeamsBusyLight-Update-*' -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt (Get-Date).AddMinutes(-10) } |
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
}

function Invoke-TeamsUpdateCheck {
    $Task = $State.UpdateTask
    if ($Task) {
        if (-not $Task.IsCompleted) {
            return
        }
        $State.UpdateTask = $null
        if ($Task.Status -eq [System.Threading.Tasks.TaskStatus]::RanToCompletion) {
            try {
                $Release = $Task.Result | ConvertFrom-Json
                $Latest = ([string]$Release.tag_name).TrimStart('v')
                if ($Latest -and (Test-TeamsNewerVersion $Latest $AppVersion) -and $Latest -ne $State.UpdateVersion -and -not $State.Updating) {
                    $State.UpdateVersion = $Latest
                    # Install from the app only if the download can be checked
                    $Asset = @($Release.assets | Where-Object { $_.name -eq $ReleaseAssetName }) | Select-Object -First 1
                    $State.UpdateAssetUrl = if ($SigningCertificateSha256 -and $Asset -and ([string]$Asset.browser_download_url).StartsWith('https://')) {
                        [string]$Asset.browser_download_url
                    }
                    else {
                        $null
                    }
                    Write-TeamsLog "Update available: $Latest$(if ($State.UpdateAssetUrl) { ' (can be installed from the app)' })"
                    Set-TeamsUpdateItem
                    $Balloon = if ($State.UpdateAssetUrl) { $Messages.UpdateBalloonInstall } else { $Messages.UpdateBalloon }
                    $Tray.ShowBalloonTip(10000, $Messages.AppName, ($Balloon -f $Latest), [System.Windows.Forms.ToolTipIcon]::Info)
                }
            }
            catch {
                Write-TeamsLog "Update check failed: $($_.Exception.Message)"
            }
        }
        return
    }
    if (-not $Config.CheckForUpdates -or $AppVersion -eq '0.0.0') {
        return
    }
    if (((Get-Date) - $State.LastUpdateCheck).TotalHours -ge 24) {
        $State.LastUpdateCheck = Get-Date
        $State.UpdateTask = $UpdateHttp.GetStringAsync($ReleasesApi)
    }
}

# --- Settings --------------------------------------------------------------

function Open-TeamsSettings {
    if ($State.SettingsOpen) {
        return
    }
    $State.SettingsOpen = $true
    try {
        $Result = Show-TeamsSettingsDialog -Settings $Config -Autostart (Get-TeamsAutostart) -Diagnostics { Get-TeamsDiagnostics }
        if ($Result) {
            Save-TeamsSettings $Result.Settings
            Set-TeamsAutostart $Result.Autostart
            $script:Config = Read-TeamsSettings
            # Send right away to the (possibly new) webhook
            $State.SentKey = $null
            $State.RetryAfter = [datetime]::MinValue
            $State.SendError = $null
            $State.LastPoll = [datetime]::MinValue
            $State.LastNetworkCheck = [datetime]::MinValue
            Update-TrayDisplay
        }
    }
    finally {
        $State.SettingsOpen = $false
    }
}

# --- Monitoring ------------------------------------------------------------

function Complete-TeamsSend {
    $Task = $State.SendTask
    if (-not $Task -or -not $Task.IsCompleted) {
        return
    }
    $State.SendTask = $null
    $SendError = Get-TeamsSendError $Task
    if ($State.Away -or $State.PausedUntil) {
        return
    }
    if ($SendError) {
        if ($SendError -ne $State.SendError) {
            Write-TeamsLog ($Messages.LogSendFailed -f $SendError)
        }
        $State.SendError = $SendError
        $State.RetryAfter = (Get-Date).AddSeconds(10)
    }
    else {
        if ($State.SendError) {
            Write-TeamsLog $Messages.LogSendOk
        }
        $State.SendError = $null
        $State.SentKey = $State.SendKey
        $State.LastSent = Get-Date
    }
    Update-TrayDisplay
}

function Update-TeamsState {
    $Current = Get-TeamsState -TeamsLanguage $Config.TeamsLanguage

    if ($Current.Running -and -not $Current.LogFound) {
        if (-not $State.LogMissing) {
            Write-TeamsLog ($Messages.LogNoLogs -f $TeamsLogFolder)
        }
        $State.LogMissing = $true
    }
    else {
        $State.LogMissing = $false
    }

    if ($Current.Language -and $Current.Language -ne $State.Language) {
        Write-TeamsLog ($Messages.LogLanguage -f $Current.Language)
        $State.Language = $Current.Language
    }

    $Changed = $false
    # Keep the previous value when the log does not contain one
    if ($Current.Status -and $Current.Status -ne $State.Status) {
        $State.Status = $Current.Status
        $Changed = $true
    }
    if ($Current.Activity) {
        $State.TeamsActivity = $Current.Activity
    }

    $Devices = Get-TeamsDeviceUsage
    $State.MicrophoneSource = $Devices.MicrophoneSource
    $State.CameraSource = $Devices.CameraSource
    if ($Devices.Camera -ne $State.Camera) {
        $WasOn = $State.Camera -eq $true
        $State.Camera = $Devices.Camera
        if ($Devices.Camera) {
            Write-TeamsLog $(if ($Devices.CameraApps.Count) { $Messages.LogCameraOn -f ($Devices.CameraApps -join ', ') } else { $Messages.LogCameraOnNoApp })
        }
        elseif ($WasOn) {
            Write-TeamsLog $Messages.LogCameraOff
        }
        $Changed = $true
    }
    $MicrophoneApps = ($Devices.MicrophoneApps -join ', ')
    if ($Devices.Microphone -ne $State.Microphone -or ($Devices.Microphone -and $MicrophoneApps -ne ($State.MicrophoneApps -join ', '))) {
        $State.Microphone = $Devices.Microphone
        $State.MicrophoneApps = $Devices.MicrophoneApps
        if ($null -ne $Devices.Microphone) {
            Write-TeamsLog $(if ($Devices.Microphone) { $Messages.LogMicrophoneOn -f $MicrophoneApps } else { $Messages.LogMicrophoneOff })
        }
        $Changed = $true
    }

    $Activity = $State.TeamsActivity
    if ($Activity -eq 'not_in_call' -and $Config.DetectOtherCalls -and $State.Microphone) {
        $Activity = 'in_call'
    }
    if ($Activity -ne $State.Activity) {
        $State.Activity = $Activity
        $Changed = $true
    }
    if ($Changed) {
        # Only when status or activity changed, not for camera/microphone alone
        $Line = $Messages.LogStatus -f (Get-TeamsEffectiveStatus), $State.Activity
        if ($Line -ne $State.LoggedStatus) {
            Write-TeamsLog $Line
            $State.LoggedStatus = $Line
        }
        Update-TrayDisplay
    }
}

function Test-TeamsManualActive {
    return [bool]($State.Manual -and (Get-Date) -lt $State.Manual.Until)
}

# Status that is sent: the one set from the menu, otherwise the Teams status
function Get-TeamsEffectiveStatus {
    if (Test-TeamsManualActive) {
        return $State.Manual.Status
    }
    return $State.Status
}

function Set-TeamsManualState {
    param([string]$Status, [datetime]$Until)

    $State.Manual = @{ Status = $Status; Until = $Until }
    Set-TeamsManualStatus $Status $Until
    if ($Until -eq [datetime]::MaxValue) {
        Write-TeamsLog ($Messages.LogManualStatusAlways -f $Status)
    }
    else {
        Write-TeamsLog ($Messages.LogManualStatus -f $Status, $Until.ToString('g'))
    }
    $State.SentKey = $null
    $State.RetryAfter = [datetime]::MinValue
    Update-TrayDisplay
}

function Clear-TeamsManualState {
    if (-not $State.Manual) {
        return
    }
    $State.Manual = $null
    Set-TeamsManualStatus $null $null
    Write-TeamsLog $Messages.LogManualEnded
    $State.SentKey = $null
    $State.RetryAfter = [datetime]::MinValue
    Update-TrayDisplay
}

# Text for "Copy diagnostics" in the settings window, without the webhook ID
function Get-TeamsDiagnostics {
    $YesNo = { param($Value) if ($Value) { 'yes' } else { 'no' } }
    $Webhook = '(not set)'
    if ($Config.WebhookUrl) {
        try {
            $Uri = [Uri]$Config.WebhookUrl
            $Webhook = '{0}://{1}/api/webhook/<hidden>' -f $Uri.Scheme, $Uri.Authority
        }
        catch {
            $Webhook = '(invalid)'
        }
    }
    $Manual = 'no'
    if (Test-TeamsManualActive) {
        $Manual = $State.Manual.Status + $(if ($State.Manual.Until -eq [datetime]::MaxValue) { ' (until reset)' } else { ' until ' + $State.Manual.Until.ToString('s') })
    }
    $Pause = 'no'
    if ($State.PausedUntil) {
        $Pause = if ($State.PausedUntil -eq [datetime]::MaxValue) { 'until resumed' } else { 'until ' + $State.PausedUntil.ToString('s') }
    }
    $Teams = Get-Process -Name 'ms-teams' -ErrorAction SilentlyContinue | Select-Object -First 1
    $Os = [Environment]::OSVersion.Version
    $Lines = @(
        "Teams Busy Light $AppVersion (Windows tray app)"
        "Windows:          $Os, PowerShell $($PSVersionTable.PSVersion), $([CultureInfo]::CurrentUICulture.Name)"
        "Signature pin:    $(if ($SigningCertificateSha256) { 'set (in-app updates)' } else { 'none' })"
        "Update available: $(if ($State.UpdateVersion) { $State.UpdateVersion } else { 'no' })"
        ''
        "Teams running:    $(& $YesNo $Teams)$(if ($Teams) { ', version ' + $Teams.FileVersion })"
        "Teams log:        $(if ($State.LogMissing) { 'MISSING in ' + $TeamsLogFolder } else { 'ok' })"
        "Teams language:   $(if ($State.Language) { $State.Language } else { '-' }) (setting $($Config.TeamsLanguage))"
        "Teams status:     $(if ($State.Status) { $State.Status } else { '-' })"
        "Teams activity:   $($State.TeamsActivity)"
        "Manual status:    $Manual"
        "Camera in use:    $(if ($null -eq $State.Camera) { 'unknown (not reported by this Windows version)' } elseif ($State.Camera) { 'yes' } else { 'no' }) (from $($State.CameraSource))"
        "Microphone:       $(if ($null -eq $State.Microphone) { 'unknown' } elseif ($State.Microphone) { 'in use by ' + ($State.MicrophoneApps -join ', ') } else { 'not in use' }) (from $($State.MicrophoneSource))"
        "Other calls:      $(if ($Config.DetectOtherCalls) { 'on' } else { 'off' })"
        "Effective:        status $(Get-TeamsEffectiveStatus), activity $($State.Activity)"
        ''
        "Webhook:          $Webhook"
        "Home networks:    $(if ($Config.HomeNetworks) { $Config.HomeNetworks } else { '(everywhere)' })"
        "Current networks: $(@(Get-TeamsCurrentNetworks) -join ', ')"
        "In home network:  $(& $YesNo (-not $State.Away))"
        "Paused:           $Pause"
        "Last sent:        $(if ($State.LastSent -ne [datetime]::MinValue) { $State.LastSent.ToString('s') } else { '-' })"
        "Last error:       $(if ($State.SendError) { $State.SendError } else { '-' })"
        "Intervals:        check $($Config.PollSeconds) s, keep-alive $($Config.HeartbeatSeconds) s"
        "Autostart:        $(& $YesNo (Get-TeamsAutostart))"
        ''
        'Last log lines:'
    )
    if (Test-Path $LogPath) {
        $Lines += @(Get-Content -Path $LogPath -Tail 40 -Encoding UTF8) -replace '/api/webhook/[^\s"'']+', '/api/webhook/<hidden>'
    }
    return ($Lines -join "`r`n") + "`r`n"
}

# Pauses sending from the tray menu; Home Assistant gets "offline" once
function Suspend-TeamsSending {
    param([datetime]$Until)

    $TellHomeAssistant = $Config.WebhookUrl -and -not $State.Away -and -not $State.PausedUntil
    $State.PausedUntil = $Until
    Set-TeamsPause $Until
    if ($Until -eq [datetime]::MaxValue) {
        Write-TeamsLog $Messages.LogPausedAlways
    }
    else {
        Write-TeamsLog ($Messages.LogPaused -f $Until.ToString('g'))
    }
    if ($TellHomeAssistant) {
        # Not awaited; the result is not needed
        [void](Start-TeamsStatusSend -Client $Http -WebhookUrl $Config.WebhookUrl -Status 'offline' -Activity 'not_in_call' -Extra (Get-TeamsOfflineExtra))
    }
    $State.SendError = $null
    Update-TrayDisplay
}

function Resume-TeamsSending {
    $State.PausedUntil = $null
    Set-TeamsPause $null
    Write-TeamsLog $Messages.LogResumed
    $State.SentKey = $null
    $State.RetryAfter = [datetime]::MinValue
    Update-TrayDisplay
}

# Pauses sending outside the networks set under "Send only in these networks";
# Home Assistant then sets Teams offline after its timeout
function Update-TeamsNetworkState {
    if (((Get-Date) - $State.LastNetworkCheck).TotalSeconds -lt 5) {
        return
    }
    $State.LastNetworkCheck = Get-Date
    $Away = -not (Test-TeamsHomeNetwork $Config.HomeNetworks)
    if ($Away -eq $State.Away) {
        return
    }
    $State.Away = $Away
    if ($Away) {
        Write-TeamsLog $Messages.LogAway
        $State.SendError = $null
    }
    else {
        Write-TeamsLog $Messages.LogHome
        $State.SentKey = $null
        $State.RetryAfter = [datetime]::MinValue
    }
    Update-TrayDisplay
}

# Asks whether to add a network the PC is in that is not a home network yet.
# "No" remembers the network, so it is asked only once.
function Request-TeamsNewNetwork {
    if (-not $State.Away -or -not $Config.AskForNewNetworks -or $State.AskingNetwork -or $State.SettingsOpen) {
        return
    }
    $Network = @(Get-TeamsNewNetworks $Config.HomeNetworks $Config.IgnoredNetworks) | Select-Object -First 1
    if (-not $Network) {
        return
    }
    $State.AskingNetwork = $true
    try {
        $Answer = Show-TeamsMessageBox -Text ($Messages.NewNetworkText -f $Network) -Caption $Messages.AppName `
            -Buttons YesNoCancel -Icon Question
        switch ($Answer) {
            'Yes' {
                $Config.HomeNetworks = Add-TeamsNetworkText $Config.HomeNetworks @($Network)
                Write-TeamsLog ($Messages.LogNetworkAdded -f $Network)
            }
            'No' {
                $Config.IgnoredNetworks = Add-TeamsNetworkText $Config.IgnoredNetworks @($Network)
                Write-TeamsLog ($Messages.LogNetworkIgnored -f $Network)
            }
            default {
                $Config.AskForNewNetworks = $false
                Write-TeamsLog $Messages.LogNetworkAskOff
            }
        }
        Save-TeamsSettings $Config
        $State.LastNetworkCheck = [datetime]::MinValue
    }
    finally {
        $State.AskingNetwork = $false
    }
}

function Invoke-TeamsSend {
    $Status = Get-TeamsEffectiveStatus
    if (-not $Config.WebhookUrl -or $State.Away -or $State.PausedUntil -or $State.SendTask -or -not $Status) {
        return
    }
    $Source = if (Test-TeamsManualActive) { 'manual' } else { 'teams' }
    $Key = '{0}|{1}|{2}|{3}|{4}' -f $Status, $State.Activity, $State.Camera, $State.Microphone, $Source
    $Now = Get-Date
    $Changed = $Key -ne $State.SentKey
    $Due = ($Now - $State.LastSent).TotalSeconds -ge $Config.HeartbeatSeconds
    if (($Changed -or $Due) -and $Now -ge $State.RetryAfter) {
        $State.SendKey = $Key
        $Extra = @{ source = $Source }
        # Unknown values are left out, Home Assistant then keeps the sensor unknown
        if ($null -ne $State.Camera) { $Extra.camera = $State.Camera }
        if ($null -ne $State.Microphone) { $Extra.microphone = $State.Microphone }
        $State.SendTask = Start-TeamsStatusSend -Client $Http -WebhookUrl $Config.WebhookUrl -Status $Status -Activity $State.Activity -Language $State.Language -Extra $Extra
    }
}

function Exit-TeamsBusyLight {
    $Timer.Stop()
    # Tell Home Assistant right away instead of waiting for the timeout; not
    # when stopped for an update, the new version sends right after starting
    if ($Config.WebhookUrl -and -not $State.PausedUntil -and -not $State.Updating -and (Test-TeamsHomeNetwork $Config.HomeNetworks)) {
        [void](Send-TeamsStatus -WebhookUrl $Config.WebhookUrl -Status 'offline' -Activity 'not_in_call' -Extra (Get-TeamsOfflineExtra) -TimeoutSeconds 3)
    }
    $Tray.Visible = $false
    $Tray.Dispose()
    [System.Windows.Forms.Application]::Exit()
}

$Timer = New-Object System.Windows.Forms.Timer
$Timer.Interval = 500
$Timer.Add_Tick({
    try {
        if ($ExitEvent.WaitOne(0)) {
            Exit-TeamsBusyLight
            return
        }
        if ($ShowSettingsEvent.WaitOne(0)) {
            Open-TeamsSettings
        }
        Complete-TeamsSend
        if ($State.PausedUntil -and $State.PausedUntil -ne [datetime]::MaxValue -and (Get-Date) -ge $State.PausedUntil) {
            Resume-TeamsSending
        }
        if ($State.Manual -and -not (Test-TeamsManualActive)) {
            Clear-TeamsManualState
        }
        if (((Get-Date) - $State.LastPoll).TotalSeconds -ge $Config.PollSeconds) {
            $State.LastPoll = Get-Date
            Update-TeamsState
        }
        Update-TeamsNetworkState
        Request-TeamsNewNetwork
        Invoke-TeamsSend
        Invoke-TeamsUpdateCheck
        Complete-TeamsUpdate
    }
    catch {
        Write-TeamsLog $_.Exception.Message
    }
})

$SettingsItem.Add_Click({ Open-TeamsSettings })
$LogItem.Add_Click({
    if (Test-Path $LogPath) {
        Start-Process -FilePath 'notepad.exe' -ArgumentList ('"{0}"' -f $LogPath)
    }
})
$ExitItem.Add_Click({ Exit-TeamsBusyLight })
$ResumeItem.Add_Click({ Resume-TeamsSending })
$UseTeamsItem.Add_Click({ Clear-TeamsManualState })
$UpdateItem.Add_Click({ Invoke-TeamsUpdateAction })
$Tray.Add_BalloonTipClicked({ Invoke-TeamsUpdateAction })
$Tray.Add_DoubleClick({ Open-TeamsSettings })
# Show the menu on a left click as well
$Tray.Add_MouseUp({
    param($EventSender, $MouseEvent)
    if ($MouseEvent.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
        $ShowMenu = [System.Windows.Forms.NotifyIcon].GetMethod('ShowContextMenu', [System.Reflection.BindingFlags]'Instance,NonPublic')
        [void]$ShowMenu.Invoke($Tray, $null)
    }
})

Write-TeamsLog ($Messages.LogStarted -f $env:COMPUTERNAME, $env:USERNAME)
Clear-TeamsUpdateFolders
Update-TrayDisplay
$Tray.Visible = $true
$Timer.Start()
if ($Settings -or -not $Config.WebhookUrl) {
    [void]$ShowSettingsEvent.Set()
}

try {
    [System.Windows.Forms.Application]::Run()
}
finally {
    $Timer.Dispose()
    $Http.Dispose()
    $UpdateHttp.Dispose()
    $Tray.Dispose()
    $InstanceMutex.ReleaseMutex()
    $InstanceMutex.Dispose()
}
