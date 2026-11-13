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
    Activity = 'not_in_call'
    Language = $null
    SentStatus = $null
    SentActivity = $null
    LastSent = [datetime]::MinValue
    LastPoll = [datetime]::MinValue
    RetryAfter = [datetime]::MinValue
    SendTask = $null
    SendStatus = $null
    SendActivity = $null
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
$ExitItem = New-Object System.Windows.Forms.ToolStripMenuItem($Messages.MenuExit)
[void]$Menu.Items.Add($StatusItem)
[void]$Menu.Items.Add($ActivityItem)
[void]$Menu.Items.Add($ConnectionItem)
[void]$Menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
[void]$Menu.Items.Add($PauseItem)
[void]$Menu.Items.Add($ResumeItem)
[void]$Menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
[void]$Menu.Items.Add($SettingsItem)
[void]$Menu.Items.Add($LogItem)
[void]$Menu.Items.Add($UpdateItem)
[void]$Menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
[void]$Menu.Items.Add($ExitItem)
$Tray.ContextMenuStrip = $Menu

function Update-TrayDisplay {
    $StatusKey = if ($State.Status) { $State.Status } else { 'unknown' }
    $StatusName = $Messages.StatusNames.$StatusKey
    $ActivityName = $Messages.ActivityNames.($State.Activity)

    $StatusItem.Text = $Messages.MenuStatus -f $StatusName
    $ActivityItem.Text = $Messages.MenuActivity -f $ActivityName
    if (-not $Config.WebhookUrl) {
        $ConnectionItem.Text = $Messages.MenuNotConfigured
    }
    elseif ($State.PausedUntil) {
        $ConnectionItem.Text = if ($State.PausedUntil -eq [datetime]::MaxValue) {
            $Messages.MenuPausedAlways
        }
        elseif ($State.PausedUntil.Date -eq (Get-Date).Date) {
            $Messages.MenuPausedUntil -f $State.PausedUntil.ToString('t')
        }
        else {
            $Messages.MenuPausedUntil -f $State.PausedUntil.ToString('g')
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

    $ColorKey = if ($State.Status -and $StatusColorKey.ContainsKey($State.Status)) { $StatusColorKey[$State.Status] } else { 'none' }
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

# --- Update hint -----------------------------------------------------------

# Checks the latest GitHub release once a day; only shows a hint
function Invoke-TeamsUpdateCheck {
    $Task = $State.UpdateTask
    if ($Task) {
        if (-not $Task.IsCompleted) {
            return
        }
        $State.UpdateTask = $null
        if ($Task.Status -eq [System.Threading.Tasks.TaskStatus]::RanToCompletion) {
            try {
                $Latest = ([string]($Task.Result | ConvertFrom-Json).tag_name).TrimStart('v')
                if ($Latest -and (Test-TeamsNewerVersion $Latest $AppVersion) -and $Latest -ne $State.UpdateVersion) {
                    $State.UpdateVersion = $Latest
                    Write-TeamsLog "Update available: $Latest"
                    $UpdateItem.Text = $Messages.MenuUpdate -f $Latest
                    $UpdateItem.Visible = $true
                    $Tray.ShowBalloonTip(10000, $Messages.AppName, ($Messages.UpdateBalloon -f $Latest), [System.Windows.Forms.ToolTipIcon]::Info)
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
        $Result = Show-TeamsSettingsDialog -Settings $Config -Autostart (Get-TeamsAutostart)
        if ($Result) {
            Save-TeamsSettings $Result.Settings
            Set-TeamsAutostart $Result.Autostart
            $script:Config = Read-TeamsSettings
            # Send right away to the (possibly new) webhook
            $State.SentStatus = $null
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
        $State.SentStatus = $State.SendStatus
        $State.SentActivity = $State.SendActivity
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
    if ($Current.Activity -and $Current.Activity -ne $State.Activity) {
        $State.Activity = $Current.Activity
        $Changed = $true
    }
    if ($Changed) {
        Write-TeamsLog ($Messages.LogStatus -f $State.Status, $State.Activity)
        Update-TrayDisplay
    }
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
        [void](Start-TeamsStatusSend -Client $Http -WebhookUrl $Config.WebhookUrl -Status 'offline' -Activity 'not_in_call')
    }
    $State.SendError = $null
    Update-TrayDisplay
}

function Resume-TeamsSending {
    $State.PausedUntil = $null
    Set-TeamsPause $null
    Write-TeamsLog $Messages.LogResumed
    $State.SentStatus = $null
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
        $State.SentStatus = $null
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
    # Invisible topmost owner, so the question comes to the front even while
    # another app is active. (MessageBoxOptions.DefaultDesktopOnly must not be
    # used: in the tray app it returned "No" at once without showing the box.)
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
        $Answer = [System.Windows.Forms.MessageBox]::Show(
            $Owner,
            ($Messages.NewNetworkText -f $Network),
            $Messages.AppName,
            [System.Windows.Forms.MessageBoxButtons]::YesNoCancel,
            [System.Windows.Forms.MessageBoxIcon]::Question
        )
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
        $Owner.Dispose()
        $State.AskingNetwork = $false
    }
}

function Invoke-TeamsSend {
    if (-not $Config.WebhookUrl -or $State.Away -or $State.PausedUntil -or $State.SendTask -or -not $State.Status) {
        return
    }
    $Now = Get-Date
    $Changed = ($State.Status -ne $State.SentStatus) -or ($State.Activity -ne $State.SentActivity)
    $Due = ($Now - $State.LastSent).TotalSeconds -ge $Config.HeartbeatSeconds
    if (($Changed -or $Due) -and $Now -ge $State.RetryAfter) {
        $State.SendStatus = $State.Status
        $State.SendActivity = $State.Activity
        $State.SendTask = Start-TeamsStatusSend -Client $Http -WebhookUrl $Config.WebhookUrl -Status $State.Status -Activity $State.Activity -Language $State.Language
    }
}

function Exit-TeamsBusyLight {
    $Timer.Stop()
    # Tell Home Assistant right away instead of waiting for the timeout
    if ($Config.WebhookUrl -and -not $State.PausedUntil -and (Test-TeamsHomeNetwork $Config.HomeNetworks)) {
        [void](Send-TeamsStatus -WebhookUrl $Config.WebhookUrl -Status 'offline' -Activity 'not_in_call' -TimeoutSeconds 3)
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
        if (((Get-Date) - $State.LastPoll).TotalSeconds -ge $Config.PollSeconds) {
            $State.LastPoll = Get-Date
            Update-TeamsState
        }
        Update-TeamsNetworkState
        Request-TeamsNewNetwork
        Invoke-TeamsSend
        Invoke-TeamsUpdateCheck
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
$UpdateItem.Add_Click({ Start-Process $ReleasesPage })
$Tray.Add_BalloonTipClicked({ if ($State.UpdateVersion) { Start-Process $ReleasesPage } })
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
