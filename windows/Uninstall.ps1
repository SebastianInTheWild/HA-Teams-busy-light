<#
.SYNOPSIS
    Removes Teams Busy Light for the signed-in Windows user.
.DESCRIPTION
    Stops the app and removes it from the Windows sign-in, the Start menu and
    "Installed apps", and deletes its program files, settings and log.
    Optionally removes its hosts file entries and the Windows service of
    earlier versions (both with a UAC prompt). The Home Assistant integration
    entry is not changed.
    Can also be started from Settings > Apps > Installed apps.
#>
. (Join-Path $PSScriptRoot 'Common.ps1')
$Messages = Get-TeamsMessages
Add-Type -AssemblyName System.Windows.Forms

$Title = $Messages.AppName
$YesNo = [System.Windows.Forms.MessageBoxButtons]::YesNo
$Question = [System.Windows.Forms.MessageBoxIcon]::Question
$Yes = [System.Windows.Forms.DialogResult]::Yes

if ([System.Windows.Forms.MessageBox]::Show($Messages.ConfirmUninstall, $Title, $YesNo, $Question) -ne $Yes) {
    exit
}

$Settings = Read-TeamsSettings
Stop-TeamsBusyLight

# Steps that need administrator rights, only after asking
$AdminArguments = @()
if ($Settings.WebhookUrl) {
    $HostName = ([System.Uri]$Settings.WebhookUrl).Host
    $HostsPath = Join-Path $env:windir 'System32\drivers\etc\hosts'
    $Tagged = Get-Content -Path $HostsPath -ErrorAction SilentlyContinue |
        Where-Object { $_ -match "\s$([regex]::Escape($HostName))\s+# Teams Busy Light\s*$" }
    if ($Tagged -and [System.Windows.Forms.MessageBox]::Show($Messages.UninstallHosts, $Title, $YesNo, $Question) -eq $Yes) {
        $AdminArguments += '-RemoveHost', $HostName
    }
}
if ((Get-Service -Name 'Microsoft Teams Status Monitor' -ErrorAction SilentlyContinue) -and
    [System.Windows.Forms.MessageBox]::Show($Messages.UninstallLegacy, $Title, $YesNo, $Question) -eq $Yes) {
    $AdminArguments += '-RemoveLegacy'
}
if ($AdminArguments) {
    # Run a copy, as the program folder is removed below
    $AdminCopy = Join-Path $env:TEMP 'TeamsBusyLight-Uninstall'
    New-Item -Path (Join-Path $AdminCopy 'Translations') -ItemType Directory -Force | Out-Null
    foreach ($File in 'AdminTasks.ps1', 'Common.ps1', 'Languages.ps1') {
        Copy-Item -Path (Join-Path $PSScriptRoot $File) -Destination $AdminCopy -Force
    }
    Copy-Item -Path (Join-Path $PSScriptRoot 'Translations\*.json') -Destination (Join-Path $AdminCopy 'Translations') -Force
    try {
        $Arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', ('"{0}"' -f (Join-Path $AdminCopy 'AdminTasks.ps1'))) + $AdminArguments
        Start-Process -FilePath 'powershell.exe' -ArgumentList $Arguments -Verb RunAs -Wait
    }
    catch {
        Write-Verbose "UAC prompt declined: $($_.Exception.Message)"
    }
    Remove-Item -LiteralPath $AdminCopy -Recurse -Force -ErrorAction SilentlyContinue
}

Set-TeamsAutostart $false
Remove-Item -LiteralPath $StartMenuShortcut -Force -ErrorAction SilentlyContinue
Remove-Item -Path $UninstallKey -Recurse -Force -ErrorAction SilentlyContinue
Set-Location -Path $env:TEMP
foreach ($Folder in $ProgramDir, $DataDir) {
    if (Test-Path $Folder) {
        Remove-Item -LiteralPath $Folder -Recurse -Force -ErrorAction SilentlyContinue
    }
}

[void][System.Windows.Forms.MessageBox]::Show($Messages.UninstallComplete, $Title, [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
