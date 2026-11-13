<#
.SYNOPSIS
    Installs Teams Busy Light for the signed-in Windows user.
.DESCRIPTION
    Shows the settings window, copies the app to
    %LOCALAPPDATA%\Programs\TeamsBusyLight, builds TeamsBusyLight.exe (a small
    starter without console window), adds it to the Start menu, the Windows
    sign-in and "Installed apps", and starts it.
    No administrator rights are needed. A UAC prompt only appears for the
    optional hosts file entry and when the Windows service of earlier versions
    is removed.
    Run again to update; the settings are kept.
.PARAMETER Quiet
    Update of an existing installation started by the app's update function:
    no settings window, the settings and autostart are kept, no steps that
    need administrator rights, no completion message.
#>
param(
    [switch]$Quiet
)

. (Join-Path $PSScriptRoot 'Common.ps1')
$Messages = Get-TeamsMessages

# WinForms needs a single-threaded apartment
if ($Host.Runspace.ApartmentState -ne 'STA') {
    $PowerShellPath = (Get-Process -Id $PID).Path
    $Arguments = @('-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $PSCommandPath))
    if ($Quiet) {
        $Arguments += '-Quiet'
    }
    Start-Process -FilePath $PowerShellPath -ArgumentList $Arguments -Wait
    exit
}

Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms
[System.Windows.Forms.Application]::EnableVisualStyles()

# The installer runs without a console, so show errors in a window
trap {
    if ($Quiet) {
        Write-TeamsLog "Installing the update failed: $($_.Exception.Message)"
    }
    [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message, $Messages.InstallTitle, [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
    exit 1
}

$LegacyServiceName = 'Microsoft Teams Status Monitor'
$LegacyPath = 'C:\Scripts\TeamsStatus'
$LegacyFound = [bool](Get-Service -Name $LegacyServiceName -ErrorAction SilentlyContinue) -or (Test-Path $LegacyPath)

# Returns the webhook URL of the current user from the settings of the
# Windows service of earlier versions
function Get-LegacyWebhookUrl {
    $LegacySettings = Join-Path $LegacyPath 'Settings.ps1'
    if (-not (Test-Path $LegacySettings)) {
        return ''
    }
    $Text = Get-Content -Path $LegacySettings -Raw -ErrorAction SilentlyContinue
    $Entries = [regex]::Matches($Text, "Username\s*=\s*(?<q1>['""])(?<user>.*?)\k<q1>\s+HAWebhookUrl\s*=\s*(?<q2>['""])(?<url>.*?)\k<q2>")
    foreach ($Entry in $Entries) {
        if ($Entry.Groups['user'].Value -ieq $env:USERNAME) {
            return $Entry.Groups['url'].Value
        }
    }
    # Single user configuration of version 1.0
    $Single = [regex]::Match($Text, "\`$HAWebhookUrl\s*=\s*(['""])(?<url>.*?)\1")
    if ($Single.Success) {
        return $Single.Groups['url'].Value
    }
    return ''
}

$IsUpdate = Test-Path $SettingsPath
$Current = Read-TeamsSettings
if (-not $Current.WebhookUrl -and $LegacyFound) {
    $Current.WebhookUrl = Get-LegacyWebhookUrl
}
$Autostart = if ($IsUpdate) { Get-TeamsAutostart } else { $true }

# Version for the update hint: version.txt of the release download, or the
# integration's manifest in a checkout of the repository
$Version = Get-TeamsVersion
$Manifest = Join-Path $PSScriptRoot '..\custom_components\teams_status\manifest.json'
if ($Version -eq '0.0.0' -and (Test-Path $Manifest)) {
    $Version = ([System.IO.File]::ReadAllText($Manifest) | ConvertFrom-Json).version
}

if ($Quiet) {
    if (-not $IsUpdate) {
        throw 'Teams Busy Light is not installed yet; run Install.cmd.'
    }
    # Steps with administrator rights (hosts file, old service) stay with
    # the normal installer
    $LegacyFound = $false
    $Result = [pscustomobject]@{ Settings = $Current; Autostart = $Autostart; AddHosts = $false }
}
else {
    $Result = Show-TeamsSettingsDialog -Settings $Current -Autostart $Autostart -Install -LegacyFound $LegacyFound -Version $Version
    if (-not $Result) {
        exit
    }
}

# Replace the program files of a running instance
Stop-TeamsBusyLight
if (Test-Path $ProgramDir) {
    Remove-Item -LiteralPath $ProgramDir -Recurse -Force
}
New-Item -Path (Join-Path $ProgramDir 'Translations') -ItemType Directory -Force | Out-Null
foreach ($File in 'TeamsBusyLight.ps1', 'Common.ps1', 'Languages.ps1', 'AdminTasks.ps1', 'Uninstall.ps1', 'icon.png', 'icon.ico') {
    Copy-Item -Path (Join-Path $PSScriptRoot $File) -Destination $ProgramDir
}
Copy-Item -Path (Join-Path $PSScriptRoot 'Translations\*.json') -Destination (Join-Path $ProgramDir 'Translations')

Set-Content -Path (Join-Path $ProgramDir 'version.txt') -Value $Version -Encoding ASCII

# Build the starter with the C# compiler of the .NET Framework
$Compiler = Join-Path ([System.Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()) 'csc.exe'
$CompilerOutput = & $Compiler /nologo /target:winexe /optimize+ `
    "/win32icon:$(Join-Path $ProgramDir 'icon.ico')" `
    "/out:$LauncherPath" `
    (Join-Path $PSScriptRoot 'Launcher.cs') 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "TeamsBusyLight.exe could not be built:`n$($CompilerOutput -join "`n")"
}
Get-ChildItem -Path $ProgramDir -Recurse -File | Unblock-File

Save-TeamsSettings $Result.Settings
Set-TeamsAutostart $Result.Autostart

# Start menu entry; it opens the settings (and starts the app if needed)
$Shell = New-Object -ComObject WScript.Shell
$Shortcut = $Shell.CreateShortcut($StartMenuShortcut)
$Shortcut.TargetPath = $LauncherPath
$Shortcut.Arguments = '-Settings'
$Shortcut.WorkingDirectory = $ProgramDir
$Shortcut.IconLocation = Join-Path $ProgramDir 'icon.ico'
$Shortcut.Description = $Messages.Subtitle
$Shortcut.Save()

# Entry under Settings > Apps > Installed apps
New-Item -Path $UninstallKey -Force | Out-Null
$UninstallCommand = '"{0}" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{1}"' -f `
    (Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe'), (Join-Path $ProgramDir 'Uninstall.ps1')
Set-ItemProperty -Path $UninstallKey -Name DisplayName -Value $AppName
Set-ItemProperty -Path $UninstallKey -Name DisplayVersion -Value $Version
Set-ItemProperty -Path $UninstallKey -Name DisplayIcon -Value (Join-Path $ProgramDir 'icon.ico')
Set-ItemProperty -Path $UninstallKey -Name Publisher -Value 'SebastianInTheWild'
Set-ItemProperty -Path $UninstallKey -Name URLInfoAbout -Value 'https://github.com/SebastianInTheWild/HA-Teams-busy-light'
Set-ItemProperty -Path $UninstallKey -Name InstallLocation -Value $ProgramDir
Set-ItemProperty -Path $UninstallKey -Name UninstallString -Value $UninstallCommand
Set-ItemProperty -Path $UninstallKey -Name NoModify -Value 1 -Type DWord
Set-ItemProperty -Path $UninstallKey -Name NoRepair -Value 1 -Type DWord

# Steps that need administrator rights
$AdminArguments = @()
$AdminSteps = @()
if ($Result.AddHosts) {
    $AdminArguments += '-AddHost', ([System.Uri]$Result.Settings.WebhookUrl).Host
    $AdminSteps += $Messages.AdminHosts
}
if ($LegacyFound) {
    $AdminArguments += '-RemoveLegacy'
    $AdminSteps += $Messages.AdminLegacy
}
if ($AdminArguments) {
    try {
        $Arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', ('"{0}"' -f (Join-Path $ProgramDir 'AdminTasks.ps1'))) + $AdminArguments
        Start-Process -FilePath 'powershell.exe' -ArgumentList $Arguments -Verb RunAs -Wait
    }
    catch {
        # The UAC prompt was declined
        [void][System.Windows.Forms.MessageBox]::Show(
            ($Messages.AdminCancelled -f ($AdminSteps -join ', ')),
            $Messages.InstallTitle,
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        )
    }
}

Start-Process -FilePath $LauncherPath

if ($Quiet) {
    Write-TeamsLog "Updated to version $Version"
    exit
}

[void][System.Windows.Forms.MessageBox]::Show(
    $Messages.InstallComplete,
    $Messages.CompleteTitle,
    [System.Windows.Forms.MessageBoxButtons]::OK,
    [System.Windows.Forms.MessageBoxIcon]::Information
)
