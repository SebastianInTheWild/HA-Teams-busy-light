<#
.SYNOPSIS
    Update from the PowerShell versions of Teams Busy Light to the Windows
    program. Not needed for a new installation.
.DESCRIPTION
    From version 2.0.0 Teams Busy Light is a Windows program
    (TeamsBusyLight.exe) that installs itself: start it to install or update.

    This script is only in the download because the update function of the
    PowerShell versions (1.7.x and older) runs Install.ps1 -Quiet from it,
    after checking the signed catalog. It starts the new program, which stops
    the old version, replaces it (the settings are kept) and starts again.
.PARAMETER Quiet
    Update without windows, as started by the update function.
#>
param(
    [switch]$Quiet
)

$Exe = Join-Path $PSScriptRoot 'TeamsBusyLight.exe'
$Arguments = if ($Quiet) { '--install --quiet' } else { '--install' }
# Not -Wait: it would also wait for the tray app the installer starts
$Process = Start-Process -FilePath $Exe -ArgumentList $Arguments -WorkingDirectory $PSScriptRoot -PassThru
# Windows PowerShell 5.1 only keeps the exit code when the handle was read before the exit
$null = $Process.Handle
$Process.WaitForExit()
exit $Process.ExitCode
