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
