<<<<<<< HEAD
<#
.NOTES
    Name: Get-TeamsStatus.ps1
    Author: Danny de Vries
    Requires: PowerShell v3 or higher
    Version History: https://github.com/EBOOZ/TeamsStatus/commits/main
.SYNOPSIS
    Sends the status of the Microsoft Teams client to Home Assistant.
.DESCRIPTION
    This script is monitoring the Teams client logfile for certain changes and
    sends them to the "Teams Busy Light" custom integration in Home
    Assistant via its webhook.
    The status (sensor.teams_status by default) is the availability status of
    your Teams client based on the icon overlay in the taskbar on Windows. The
    log contains it in the language of the Teams app; the language is detected
    automatically (see Languages.ps1 and $TeamsLanguage in Settings.ps1).
    The activity (sensor.teams_activity by default) shows if you are in a call.
    Both are sent as language-neutral states (e.g. "busy", "in_call"), Home
    Assistant shows them translated in its own language.
.PARAMETER SetStatus
    Run the script with the SetStatus-parameter to set the status of Microsoft
    Teams directly from the commandline, e.g. available, busy, away, offline.
.PARAMETER SetActivity
    Optional activity to send together with SetStatus, e.g. not_in_call.
.PARAMETER SetUsername
    Optional configured Windows username to target when using SetStatus. Without
    it, the test status is sent to each configured user's webhook.
.EXAMPLE
    .\Get-TeamsStatus.ps1 -SetStatus "offline"
    .\Get-TeamsStatus.ps1 -SetStatus "offline" -SetUsername "anna"
#>
# Configuring parameter for interactive run
Param($SetStatus, $SetActivity, $SetUsername)

# Import Settings and language patterns
. ($PSScriptRoot + "\Settings.ps1")
. ($PSScriptRoot + "\Languages.ps1")
. ($PSScriptRoot + "\Messages.ps1")
if ($null -eq $UiLanguage) { $UiLanguage = "en" }
$Messages = Get-TeamsMessages -Language $UiLanguage -Root $PSScriptRoot

if (-not $TeamsUsers -and $HAWebhookUrl -and $LocalUsername) {
    $TeamsUsers = @(@{
        Username = $LocalUsername
        HAWebhookUrl = $HAWebhookUrl
    })
}
if (-not $TeamsUsers) {
    throw $Messages.NoConfiguredUser
}
If ($null -eq $TeamsLanguage) { $TeamsLanguage = "auto" }
If ($null -eq $HeartbeatSeconds) { $HeartbeatSeconds = 60 }

# Returns the language-neutral status and the language of a Teams log line
function Get-StatusFromLogLine {
    param([string]$Line, [string]$Language)

    If ($Language -and $Language -ne "auto") {
        $Languages = @($Language)
    }
    Else {
        # Localized words are checked first, as a localized line may also
        # contain English technical terms.
        $Languages = @($StatusPatterns.Keys | Where-Object { $_ -ne "en" }) + "en"
    }

    foreach ($Lang in $Languages) {
        $Table = $StatusPatterns[$Lang]
        If ($null -eq $Table) { continue }
        foreach ($State in $Table.Keys) {
            foreach ($Pattern in $Table[$State]) {
                If ($Line -match $Pattern) {
                    return @{ Status = $State; Language = $Lang }
                }
            }
        }
    }
    return $null
}

# Sends status and activity to the Home Assistant webhook
function Send-TeamsStatus {
    param(
        [string]$WebhookUrl,
        [string]$Username,
        [string]$Status,
        [string]$Activity,
        [string]$Language
    )

    $Body = @{ "computer" = $env:COMPUTERNAME }
    If ($Status) { $Body["status"] = $Status }
    If ($Activity) { $Body["activity"] = $Activity }
    If ($Language) { $Body["language"] = $Language }
    $Json = $Body | ConvertTo-Json -Compress

    try {
        Invoke-RestMethod -Uri $WebhookUrl -Method POST -Body ([System.Text.Encoding]::UTF8.GetBytes($Json)) -ContentType "application/json" | Out-Null
        return $true
    } catch {
        Write-Warning ($Messages.SendFailed -f $Username, $_.Exception.Message)
        return $false
    }
}

# Run the script when a parameter is used and stop when done
If ($null -ne $SetStatus) {
    $Targets = @($TeamsUsers)
    if ($SetUsername) {
        $Targets = @($TeamsUsers | Where-Object { $_.Username -ieq $SetUsername })
        if (-not $Targets) {
            throw ($Messages.UnknownUser -f $SetUsername)
        }
    }
    foreach ($Target in $Targets) {
        Write-Host ($Messages.StatusSet -f $SetStatus, $Target.Username)
        if (Send-TeamsStatus -WebhookUrl $Target.HAWebhookUrl -Username $Target.Username -Status $SetStatus -Activity $SetActivity) {
            Write-Host $Messages.StatusSetSuccess
        }
    }
    break
}

$RuntimeByUsername = @{}
foreach ($ConfiguredUser in $TeamsUsers) {
    if ([string]::IsNullOrWhiteSpace($ConfiguredUser.Username) -or
        [string]::IsNullOrWhiteSpace($ConfiguredUser.HAWebhookUrl)) {
        throw $Messages.IncompleteUser
    }
    $UsernameKey = $ConfiguredUser.Username.ToLowerInvariant()
    if ($RuntimeByUsername.ContainsKey($UsernameKey)) {
        throw $Messages.DuplicateUsername
    }
    $RuntimeByUsername[$UsernameKey] = @{
        Config = $ConfiguredUser
        ProfilePath = Join-Path "C:\Users" $ConfiguredUser.Username
        ProfileSid = $null
        Status = $null
        Activity = $null
        Language = $null
        SentStatus = $null
        SentActivity = $null
        LastSent = [datetime]::MinValue
        RetryAfter = [datetime]::MinValue
    }
}

try {
    foreach ($Profile in Get-CimInstance Win32_UserProfile -ErrorAction Stop) {
        if (-not $Profile.LocalPath -or -not $Profile.SID) { continue }
        $ProfileName = Split-Path -Path $Profile.LocalPath -Leaf
        $ProfileKey = $ProfileName.ToLowerInvariant()
        if ($RuntimeByUsername.ContainsKey($ProfileKey)) {
            $RuntimeByUsername[$ProfileKey].ProfilePath = $Profile.LocalPath
            $RuntimeByUsername[$ProfileKey].ProfileSid = $Profile.SID
        }
    }
}
catch {
    Write-Warning ($Messages.ProfileLookupFailed -f $_.Exception.Message)
}

function Get-RunningTeamsUsernames {
    $RunningUsernames = @{}
    $Processes = Get-CimInstance Win32_Process -Filter "Name='ms-teams.exe'" -ErrorAction SilentlyContinue
    foreach ($Process in $Processes) {
        $Owner = Invoke-CimMethod -InputObject $Process -MethodName GetOwner -ErrorAction SilentlyContinue
        if ($Owner -and $Owner.User) {
            $RunningUsernames[$Owner.User.ToLowerInvariant()] = $true
            if ($Owner.Domain) {
                $OwnerAccount = "$($Owner.Domain)\$($Owner.User)"
                $AccountKey = $OwnerAccount.ToLowerInvariant()
                if ($OwnerSidByAccount.ContainsKey($AccountKey)) {
                    $OwnerSid = $OwnerSidByAccount[$AccountKey]
                    $RunningUsernames["sid:$($OwnerSid.ToLowerInvariant())"] = $true
                }
                elseif (-not $UnresolvedOwnerAccounts.ContainsKey($AccountKey)) {
                    try {
                        $OwnerSid = [System.Security.Principal.NTAccount]::new(
                            $Owner.Domain,
                            $Owner.User
                        ).Translate([System.Security.Principal.SecurityIdentifier]).Value
                        $OwnerSidByAccount[$AccountKey] = $OwnerSid
                        $RunningUsernames["sid:$($OwnerSid.ToLowerInvariant())"] = $true
                    }
                    catch {
                        Write-Warning ($Messages.OwnerSidLookupFailed -f $OwnerAccount, $_.Exception.Message)
                        $UnresolvedOwnerAccounts[$AccountKey] = $true
                    }
                }
            }
        }
    }
    return $RunningUsernames
}

$UnresolvedOwnerAccounts = @{}
$OwnerSidByAccount = @{}
while ($true) {
    $RunningUsernames = Get-RunningTeamsUsernames
    foreach ($Key in @($RuntimeByUsername.Keys)) {
        $UserState = $RuntimeByUsername[$Key]
        $Username = $UserState.Config.Username
        $LogFolder = Join-Path $UserState.ProfilePath "AppData\Local\Packages\MSTeams_8wekyb3d8bbwe\LocalCache\Microsoft\MSTeams\Logs"

        $IsRunning = $RunningUsernames.ContainsKey($Key)
        if ($UserState.ProfileSid -and
            $RunningUsernames.ContainsKey("sid:$($UserState.ProfileSid.ToLowerInvariant())")) {
            $IsRunning = $true
        }

        if ($IsRunning) {
            $LatestLog = Get-ChildItem -Path $LogFolder -Filter "MSTeams_*" -File -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending |
                Select-Object -First 1
            if ($LatestLog) {
                $MSTeamsLog = Get-Content -Path $LatestLog.FullName -Tail 1000 -Encoding UTF8 -ErrorAction SilentlyContinue
                $TeamsStatus = $MSTeamsLog | Select-String -Pattern 'SetBadge Setting badge:', 'SetTaskbarIconOverlay' | Select-Object -Last 1
                $TeamsActivity = $MSTeamsLog | Select-String -Pattern 'NotifyCallActive', 'NotifyCallAccepted', 'NotifyCallEnded', 'reportIncomingCall', 'RequestNewOutgoingCallWithOptions' | Select-Object -Last 1

                if ($TeamsStatus) {
                    $Result = Get-StatusFromLogLine -Line $TeamsStatus.Line -Language $TeamsLanguage
                    if ($Result) {
                        $UserState.Status = $Result.Status
                        if ($UserState.Language -ne $Result.Language) {
                            $UserState.Language = $Result.Language
                            Write-Host ($Messages.DetectedLanguage -f $Username, $UserState.Language)
                        }
                    }
                }

                if (-not $TeamsActivity) {
                    if (-not $UserState.Activity) { $UserState.Activity = "not_in_call" }
                }
                elseif ($TeamsActivity -like "*reportIncomingCall*") {
                    $UserState.Activity = "incoming_call"
                }
                elseif ($TeamsActivity -like "*RequestNewOutgoingCallWithOptions*") {
                    $UserState.Activity = "outgoing_call"
                }
                elseif ($TeamsActivity -like "*NotifyCallActive*" -or $TeamsActivity -like "*NotifyCallAccepted*") {
                    $UserState.Activity = "in_call"
                }
                elseif ($TeamsActivity -like "*NotifyCallEnded*") {
                    $UserState.Activity = "not_in_call"
                }
            }
        }
        else {
            $UserState.Status = "offline"
            $UserState.Activity = "not_in_call"
        }

        $Now = Get-Date
        $Changed = ($UserState.Status -ne $UserState.SentStatus) -or ($UserState.Activity -ne $UserState.SentActivity)
        $Due = ($Now - $UserState.LastSent).TotalSeconds -ge $HeartbeatSeconds
        if (($Changed -or $Due) -and $Now -ge $UserState.RetryAfter -and ($UserState.Status -or $UserState.Activity)) {
            if ($Changed) {
                Write-Host ($Messages.StatusChanged -f $Username, $UserState.Status, $UserState.Activity)
            }
            if (Send-TeamsStatus -WebhookUrl $UserState.Config.HAWebhookUrl -Username $Username -Status $UserState.Status -Activity $UserState.Activity -Language $UserState.Language) {
                $UserState.SentStatus = $UserState.Status
                $UserState.SentActivity = $UserState.Activity
                $UserState.LastSent = $Now
            }
            else {
                $UserState.RetryAfter = $Now.AddSeconds(10)
            }
        }
    }
    Start-Sleep 1
}
=======
<#
.NOTES
    Name: Get-TeamsStatus.ps1
    Author: Danny de Vries
    Requires: PowerShell v3 or higher
    Version History: https://github.com/EBOOZ/TeamsStatus/commits/main
.SYNOPSIS
    Sends the status of the Microsoft Teams client to Home Assistant.
.DESCRIPTION
    This script is monitoring the Teams client logfile for certain changes and
    sends them to the "Teams Busy Light" custom integration in Home
    Assistant via its webhook.
    The status (sensor.teams_status by default) is the availability status of
    your Teams client based on the icon overlay in the taskbar on Windows. The
    log contains it in the language of the Teams app; the language is detected
    automatically (see Languages.ps1 and $TeamsLanguage in Settings.ps1).
    The activity (sensor.teams_activity by default) shows if you are in a call.
    Both are sent as language-neutral states (e.g. "busy", "in_call"), Home
    Assistant shows them translated in its own language.
.PARAMETER SetStatus
    Run the script with the SetStatus-parameter to set the status of Microsoft
    Teams directly from the commandline, e.g. available, busy, away, offline.
.PARAMETER SetActivity
    Optional activity to send together with SetStatus, e.g. not_in_call.
.EXAMPLE
    .\Get-TeamsStatus.ps1 -SetStatus "offline"
#>
# Configuring parameter for interactive run
Param($SetStatus, $SetActivity)

# Import Settings and language patterns
. ($PSScriptRoot + "\Settings.ps1")
. ($PSScriptRoot + "\Languages.ps1")

If ([string]::IsNullOrWhiteSpace($HAWebhookUrl)) {
    throw "HAWebhookUrl is not set in Settings.ps1."
}
If ($null -eq $TeamsLanguage) { $TeamsLanguage = "auto" }
If ($null -eq $HeartbeatSeconds) { $HeartbeatSeconds = 60 }

# Returns the language-neutral status and the language of a Teams log line
function Get-StatusFromLogLine {
    param([string]$Line, [string]$Language)

    If ($Language -and $Language -ne "auto") {
        $Languages = @($Language)
    }
    Else {
        # Localized words are checked first, as a localized line may also
        # contain English technical terms.
        $Languages = @($StatusPatterns.Keys | Where-Object { $_ -ne "en" }) + "en"
    }

    foreach ($Lang in $Languages) {
        $Table = $StatusPatterns[$Lang]
        If ($null -eq $Table) { continue }
        foreach ($State in $Table.Keys) {
            foreach ($Pattern in $Table[$State]) {
                If ($Line -match $Pattern) {
                    return @{ Status = $State; Language = $Lang }
                }
            }
        }
    }
    return $null
}

# Sends status and activity to the Home Assistant webhook
function Send-TeamsStatus {
    param([string]$Status, [string]$Activity, [string]$Language)

    $Body = @{ "computer" = $env:COMPUTERNAME }
    If ($Status) { $Body["status"] = $Status }
    If ($Activity) { $Body["activity"] = $Activity }
    If ($Language) { $Body["language"] = $Language }
    $Json = $Body | ConvertTo-Json -Compress

    try {
        Invoke-RestMethod -Uri $HAWebhookUrl -Method POST -Body ([System.Text.Encoding]::UTF8.GetBytes($Json)) -ContentType "application/json" | Out-Null
        return $true
    } catch {
        Write-Warning "Failed to send status to Home Assistant: $($_.Exception.Message)"
        return $false
    }
}

# Run the script when a parameter is used and stop when done
If ($null -ne $SetStatus) {
    Write-Host ("Setting Microsoft Teams status to " + $SetStatus + ":")
    If (Send-TeamsStatus -Status $SetStatus -Activity $SetActivity) {
        Write-Host "Status set successfully."
    }
    break
}

$LogFolder = "C:\Users\$LocalUsername\AppData\Local\Packages\MSTeams_8wekyb3d8bbwe\LocalCache\Microsoft\MSTeams\Logs"
$Enable = 1
$Status = $null
$Activity = $null
$Language = $null
$SentStatus = $null
$SentActivity = $null
$LastSent = [datetime]::MinValue
$RetryAfter = [datetime]::MinValue

# Start monitoring the Teams logfile when no parameter is used to run the script
DO {
    # Get Teams application process
    $TeamsProcess = Get-Process -Name ms-teams -ErrorAction SilentlyContinue

    # Check if Teams is running and start monitoring the log if it is
    If ($null -ne $TeamsProcess) {
        # Get latest MSTeams_ logfile
        $MSTeamsLog = $null
        $LatestLogfile = Get-ChildItem -Path $LogFolder -Name "MSTeams_*" -ErrorAction SilentlyContinue | Select-Object -Last 1
        If ($LatestLogfile) {
            $MSTeamsLog = Get-Content -Path "$LogFolder\$LatestLogfile" -Tail 1000 -Encoding UTF8 -ErrorAction SilentlyContinue
        }

        # Get last icon overlay status
        $TeamsStatus = $MSTeamsLog | Select-String -Pattern `
          'SetBadge Setting badge:',`
          'SetTaskbarIconOverlay' | Select-Object -Last 1

        # Get last call activity
        $TeamsActivity = $MSTeamsLog | Select-String -Pattern `
          'NotifyCallActive',`
          'NotifyCallAccepted',`
          'NotifyCallEnded',`
          'reportIncomingCall',`
          'RequestNewOutgoingCallWithOptions' | Select-Object -Last 1

        If ($null -ne $TeamsStatus) {
            $Result = Get-StatusFromLogLine -Line $TeamsStatus.Line -Language $TeamsLanguage
            If ($null -ne $Result) {
                $Status = $Result.Status
                If ($Language -ne $Result.Language) {
                    $Language = $Result.Language
                    Write-Host "Detected Teams language: $Language"
                }
            }
        }

        If ($null -eq $TeamsActivity) {
            If ($null -eq $Activity) { $Activity = "not_in_call" }
        }
        ElseIf ($TeamsActivity -like "*reportIncomingCall*") {
            $Activity = "incoming_call"
        }
        ElseIf ($TeamsActivity -like "*RequestNewOutgoingCallWithOptions*") {
            $Activity = "outgoing_call"
        }
        ElseIf ($TeamsActivity -like "*NotifyCallActive*" -or `
            $TeamsActivity -like "*NotifyCallAccepted*") {
            $Activity = "in_call"
        }
        ElseIf ($TeamsActivity -like "*NotifyCallEnded*") {
            $Activity = "not_in_call"
        }
    }
    # Set status to offline when the Teams application is not running
    Else {
        $Status = "offline"
        $Activity = "not_in_call"
    }

    # Send on every change and as keep-alive every $HeartbeatSeconds
    $Now = Get-Date
    $Changed = ($Status -ne $SentStatus) -or ($Activity -ne $SentActivity)
    $Due = ($Now - $LastSent).TotalSeconds -ge $HeartbeatSeconds
    If (($Changed -or $Due) -and $Now -ge $RetryAfter -and ($Status -or $Activity)) {
        If ($Changed) {
            Write-Host "Status: $Status, activity: $Activity"
        }
        If (Send-TeamsStatus -Status $Status -Activity $Activity -Language $Language) {
            $SentStatus = $Status
            $SentActivity = $Activity
            $LastSent = $Now
        }
        Else {
            $RetryAfter = $Now.AddSeconds(10)
        }
    }

    Start-Sleep 1
} Until ($Enable -eq 0)
>>>>>>> b9d542111a29b60513cdb592535e8745e562db0a
