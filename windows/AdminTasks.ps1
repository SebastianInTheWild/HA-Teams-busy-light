<#
.SYNOPSIS
    Steps of the Teams Busy Light installer and uninstaller that need
    administrator rights. Started by them with a UAC prompt.
.PARAMETER AddHost
    Resolves the host via the DNS servers of the active LAN/Wi-Fi adapters and
    adds or updates it in the Windows hosts file, e.g. when Home Assistant
    cannot be resolved while a company VPN is connected.
.PARAMETER RemoveHost
    Removes the entries that Teams Busy Light added for these hosts.
.PARAMETER RemoveLegacy
    Removes the Windows service "Microsoft Teams Status Monitor" and
    C:\Scripts\TeamsStatus of the versions before the tray app.
#>
param(
    [string[]]$AddHost = @(),
    [string[]]$RemoveHost = @(),
    [switch]$RemoveLegacy
)

. (Join-Path $PSScriptRoot 'Common.ps1')
$Messages = Get-TeamsMessages
Add-Type -AssemblyName System.Windows.Forms

$HostsPath = Join-Path $env:windir 'System32\drivers\etc\hosts'
$HostsTag = '# Teams Busy Light'
$LegacyServiceName = 'Microsoft Teams Status Monitor'
$LegacyPath = 'C:\Scripts\TeamsStatus'
$Report = New-Object System.Collections.Generic.List[string]
$Failed = $false

function Resolve-LanHost {
    param([string]$HostName)

    $ActiveAdapterAliases = Get-NetAdapter -Physical -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Status -eq 'Up' -and (
                $_.Name -match 'Ethernet|Wi-?Fi|WLAN' -or
                $_.InterfaceDescription -match 'Ethernet|Wi-?Fi|WLAN|Wireless'
            )
        } |
        Select-Object -ExpandProperty Name -Unique
    if (-not $ActiveAdapterAliases) {
        return $null
    }

    $DnsServers = Get-DnsClientServerAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.InterfaceAlias -in $ActiveAdapterAliases -and $_.ServerAddresses } |
        ForEach-Object { $_.ServerAddresses } |
        Where-Object { $_ -and $_ -notmatch '^127\.' } |
        Select-Object -Unique

    foreach ($DnsServer in $DnsServers) {
        try {
            $Answer = Resolve-DnsName -Name $HostName -Type A -Server $DnsServer -ErrorAction Stop |
                Where-Object { $_.Type -eq 'A' -and $_.IPAddress } |
                Select-Object -First 1
            if ($Answer) {
                return $Answer.IPAddress
            }
        }
        catch {
            Write-Verbose "DNS server $DnsServer could not resolve ${HostName}: $($_.Exception.Message)"
        }
    }
    return $null
}

# True if the line maps one of the hosts (comments are ignored)
function Test-HostsLine {
    param([string]$Line, [string[]]$HostNames)

    $Tokens = @((($Line -split '#', 2)[0] -split '\s+') | Where-Object { $_ })
    if ($Tokens.Count -lt 2) {
        return $false
    }
    foreach ($Name in $Tokens | Select-Object -Skip 1) {
        if ($HostNames -contains $Name.ToLowerInvariant()) {
            return $true
        }
    }
    return $false
}

# Rewrites the hosts file with the lines returned by $Transform. The file is
# opened once and exclusively, so it is never left truncated: if it is in use,
# nothing changes; if writing fails, the original content is written back.
# (Set-Content truncates first and left an empty hosts file when it failed.)
# Returns $true if the content changed.
function Update-HostsFile {
    param([scriptblock]$Transform)

    $Encoding = [System.Text.Encoding]::Default
    $Stream = $null
    for ($Try = 1; -not $Stream; $Try++) {
        try {
            $Stream = [System.IO.File]::Open($HostsPath, 'OpenOrCreate', 'ReadWrite', 'None')
        }
        catch [System.IO.IOException] {
            if ($Try -ge 20) {
                throw
            }
            Start-Sleep -Milliseconds 500
        }
    }
    try {
        $Original = New-Object byte[] $Stream.Length
        $Read = 0
        while ($Read -lt $Original.Length) {
            $Count = $Stream.Read($Original, $Read, $Original.Length - $Read)
            if ($Count -le 0) {
                break
            }
            $Read += $Count
        }
        $Text = $Encoding.GetString($Original)
        $Lines = @($Text -split '\r?\n')
        if ($Lines.Count -gt 0 -and $Lines[-1] -eq '') {
            $Lines = @($Lines | Select-Object -SkipLast 1)
        }
        $NewText = ((@(& $Transform $Lines) -join "`r`n") + "`r`n")
        if ($NewText -eq $Text) {
            return $false
        }
        $Bytes = $Encoding.GetBytes($NewText)
        try {
            $Stream.SetLength(0)
            $Stream.Write($Bytes, 0, $Bytes.Length)
            $Stream.Flush()
        }
        catch {
            $Stream.SetLength(0)
            $Stream.Write($Original, 0, $Original.Length)
            $Stream.Flush()
            throw
        }
        return $true
    }
    finally {
        $Stream.Dispose()
    }
}

foreach ($HostName in $AddHost) {
    try {
        $Address = Resolve-LanHost $HostName
        if (-not $Address) {
            $Report.Add(($Messages.DnsFailed -f $HostName))
            $Failed = $true
            continue
        }
        $DesiredLine = "$Address`t$HostName`t$HostsTag"
        $Names = @($HostName.ToLowerInvariant())
        $State = @{ Replaced = $false }
        [void](Update-HostsFile {
            param($Lines)
            foreach ($Line in $Lines) {
                if (Test-HostsLine $Line $Names) {
                    if (-not $State.Replaced) {
                        $DesiredLine
                        $State.Replaced = $true
                    }
                    continue
                }
                $Line
            }
            if (-not $State.Replaced) {
                $DesiredLine
            }
        })
        $Message = if ($State.Replaced) { $Messages.HostsUpdated } else { $Messages.HostsAdded }
        $Report.Add(($Message -f $Address, $HostName))
    }
    catch {
        $Report.Add(($Messages.HostsFailed -f $HostName, $_.Exception.Message))
        $Failed = $true
    }
}

if ($RemoveHost.Count -gt 0) {
    try {
        $Names = @($RemoveHost | ForEach-Object { $_.ToLowerInvariant() })
        $Changed = Update-HostsFile {
            param($Lines)
            $Lines | Where-Object { -not ($_.TrimEnd().EndsWith($HostsTag) -and (Test-HostsLine $_ $Names)) }
        }
        if ($Changed) {
            $Report.Add($Messages.HostsRemoved)
        }
    }
    catch {
        $Report.Add(($Messages.HostsFailed -f ($RemoveHost -join ', '), $_.Exception.Message))
        $Failed = $true
    }
}

if ($RemoveLegacy) {
    try {
        $Service = Get-CimInstance Win32_Service -Filter "Name='$LegacyServiceName'" -ErrorAction SilentlyContinue
        if ($Service) {
            $NssmPath = Join-Path $LegacyPath 'nssm.exe'
            $ExpectedPathPattern = '^\s*"?{0}"?(\s|$)' -f [regex]::Escape($NssmPath)
            if ($Service.PathName -notmatch $ExpectedPathPattern) {
                throw ($Messages.ServicePathMismatch -f $LegacyServiceName, $Service.PathName)
            }
            if ($Service.State -ne 'Stopped') {
                Stop-Service -Name $LegacyServiceName -Force -PassThru -ErrorAction Stop |
                    ForEach-Object { $_.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(30)) }
            }
            if (Test-Path $NssmPath) {
                & $NssmPath remove $LegacyServiceName confirm | Out-Null
            }
            else {
                & sc.exe delete $LegacyServiceName | Out-Null
            }
            if ($LASTEXITCODE -ne 0) {
                throw ($Messages.ServiceRemovalFailed -f $LegacyServiceName, $LASTEXITCODE)
            }
            $Deadline = (Get-Date).AddSeconds(10)
            do {
                Start-Sleep -Milliseconds 250
                $RemainingService = Get-Service -Name $LegacyServiceName -ErrorAction SilentlyContinue
            } while ($RemainingService -and (Get-Date) -lt $Deadline)
            if ($RemainingService) {
                throw ($Messages.ServiceStillExists -f $LegacyServiceName)
            }
        }
        if (Test-Path $LegacyPath) {
            Remove-Item -LiteralPath $LegacyPath -Recurse -Force -ErrorAction Stop
        }
        $Report.Add($Messages.LegacyRemoved)
    }
    catch {
        $Report.Add($_.Exception.Message)
        $Failed = $true
    }
}

if ($Report.Count -gt 0) {
    $Icon = if ($Failed) { [System.Windows.Forms.MessageBoxIcon]::Warning } else { [System.Windows.Forms.MessageBoxIcon]::Information }
    [void][System.Windows.Forms.MessageBox]::Show(($Report -join "`n`n"), $Messages.AppName, [System.Windows.Forms.MessageBoxButtons]::OK, $Icon)
}
if ($Failed) {
    exit 1
}
