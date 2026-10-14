Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope Process

$CurrentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
$CurrentPrincipal = New-Object Security.Principal.WindowsPrincipal($CurrentIdentity)
$IsAdmin = $CurrentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $IsAdmin) {
    if ([string]::IsNullOrWhiteSpace($PSCommandPath)) {
        throw "This script must run as Administrator. Save and run the script file to allow automatic elevation."
    }

    Write-Host "Restarting installer with Administrator rights..."
    $ElevatedArgs = @(
        '-NoProfile'
        '-ExecutionPolicy', 'Bypass'
        '-File', $PSCommandPath
    )

    Start-Process -FilePath 'powershell.exe' -ArgumentList $ElevatedArgs -Verb RunAs
    exit
}

# The webhook URL is shown in Home Assistant after adding the
# "Teams Busy Light" integration (and later in its options).
$HAWebhookUrl = Read-Host "Enter the Home Assistant webhook URL (e.g. https://yourha.duckdns.org/api/webhook/abc123...)"
$HAWebhookUrl = $HAWebhookUrl.Trim()
if ($HAWebhookUrl -notmatch '/api/webhook/[^/]+$') {
    throw "This does not look like a Home Assistant webhook URL (.../api/webhook/<id>)."
}
$LocalUsername = Read-Host "Enter the local Windows username or press enter to auto-detect"

if ([string]::IsNullOrWhiteSpace($LocalUsername)) {
    # Try to detect the interactive signed-in user when no username is entered.
    $ExplorerUsers = Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" -ErrorAction SilentlyContinue |
        ForEach-Object {
            $Owner = Invoke-CimMethod -InputObject $_ -MethodName GetOwner -ErrorAction SilentlyContinue
            if ($Owner -and $Owner.User) {
                $Owner.User
            }
        } |
        Select-Object -Unique

    if ($ExplorerUsers) {
        $LocalUsername = $ExplorerUsers | Select-Object -First 1
    }
    else {
        $LoggedOnUser = (Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue).UserName
        if ($LoggedOnUser -and $LoggedOnUser -match '\\') {
            $LocalUsername = $LoggedOnUser.Split('\\')[-1]
        }
    }

    if ([string]::IsNullOrWhiteSpace($LocalUsername) -and -not [string]::IsNullOrWhiteSpace($env:USERNAME)) {
        $LocalUsername = $env:USERNAME
    }

    if ([string]::IsNullOrWhiteSpace($LocalUsername)) {
        throw "Could not auto-detect the signed-in Windows username. Please run again and enter the username manually."
    }
}

$Path = "C:\Scripts\TeamsStatus"
if (-not (Test-Path $Path)) {
    New-Item -Path $Path -ItemType Directory
}

$ServiceName = "Microsoft Teams Status Monitor"
$ExistingService = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if ($ExistingService -and $ExistingService.Status -ne 'Stopped') {
    Write-Host "Stopping existing service..."
    Stop-Service -Name $ServiceName -Force
}

Copy-Item -Path "$PSScriptRoot\Settings.ps1" -Destination $Path
$SettingsPath = "$Path\Settings.ps1"
$SettingsContent = Get-Content $SettingsPath
$SettingsContent = $SettingsContent | ForEach-Object {
    if ($_ -match '^\$HAWebhookUrl\s*=') {
        "`$HAWebhookUrl = `"$HAWebhookUrl`""
    }
    elseif ($_ -match '^\$LocalUsername\s*=') {
        "`$LocalUsername = `"$LocalUsername`""
    }
    else {
        $_
    }
}
$SettingsContent | Set-Content $SettingsPath

# Resolve the HA host via DNS servers configured on active LAN/Wi-Fi adapters
# and add/update it in the hosts file.
try {
    $HAUrlForUri = $HAWebhookUrl
    if ($HAUrlForUri -notmatch '^\w+://') {
        $HAUrlForUri = "https://$HAUrlForUri"
    }

    $HAHost = ([System.Uri]$HAUrlForUri).Host
    $ResolvedIP = $null

    $ActiveAdapterAliases = Get-NetAdapter -Physical -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Status -eq 'Up' -and (
                $_.Name -match 'Ethernet|Wi-?Fi|WLAN' -or
                $_.InterfaceDescription -match 'Ethernet|Wi-?Fi|WLAN|Wireless'
            )
        } |
        Select-Object -ExpandProperty Name -Unique

    $DnsServers = @()
    if ($ActiveAdapterAliases) {
        $DnsServers = Get-DnsClientServerAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object {
                $_.InterfaceAlias -in $ActiveAdapterAliases -and
                $_.ServerAddresses -and
                $_.ServerAddresses.Count -gt 0
            } |
            ForEach-Object { $_.ServerAddresses } |
            Where-Object { $_ -and $_ -notmatch '^127\.' } |
            Select-Object -Unique
    }

    foreach ($DnsServer in $DnsServers) {
        try {
            $DnsAnswer = Resolve-DnsName -Name $HAHost -Type A -Server $DnsServer -ErrorAction Stop |
                Where-Object { $_.Type -eq 'A' -and $_.IPAddress } |
                Select-Object -First 1

            if ($DnsAnswer) {
                $ResolvedIP = $DnsAnswer.IPAddress
                break
            }
        }
        catch {
            # Try next DNS server.
        }
    }

    if ($ResolvedIP) {
        $HostsPath = "$env:windir\System32\drivers\etc\hosts"
        $HostsLines = Get-Content -Path $HostsPath -ErrorAction Stop
        $HostPattern = "^\s*(?!#)\s*\S+\s+.*\b$([regex]::Escape($HAHost))\b"
        $MatchingIndexes = @()

        for ($i = 0; $i -lt $HostsLines.Count; $i++) {
            if ($HostsLines[$i] -match $HostPattern) {
                $MatchingIndexes += $i
            }
        }

        $DesiredLine = "$ResolvedIP`t$HAHost"

        if ($MatchingIndexes.Count -eq 0) {
            Add-Content -Path $HostsPath -Value $DesiredLine
            Write-Host "Added hosts entry: $ResolvedIP $HAHost"
        }
        else {
            $UpdatedLines = New-Object System.Collections.Generic.List[string]
            $FirstMatchHandled = $false

            for ($i = 0; $i -lt $HostsLines.Count; $i++) {
                if ($i -in $MatchingIndexes) {
                    if (-not $FirstMatchHandled) {
                        $UpdatedLines.Add($DesiredLine)
                        $FirstMatchHandled = $true
                    }
                    continue
                }

                $UpdatedLines.Add($HostsLines[$i])
            }

            $UpdatedLines | Set-Content -Path $HostsPath
            Write-Host "Updated hosts entry: $ResolvedIP $HAHost"
        }
    }
    else {
        Write-Warning "Could not resolve IPv4 for $HAHost using DNS servers from active LAN/Wi-Fi adapters."
    }
}
catch {
    Write-Warning "Could not add hosts entry for '$HAWebhookUrl'. Run as Administrator and verify the URL. Error: $($_.Exception.Message)"
}

Copy-Item -Path "$PSScriptRoot\Get-TeamsStatus.ps1" -Destination $Path
Copy-Item -Path "$PSScriptRoot\Languages.ps1" -Destination $Path
Copy-Item -Path "$PSScriptRoot\nssm.exe" -Destination $Path


Unblock-File $Path\Settings.ps1
Unblock-File $Path\Languages.ps1
Unblock-File $Path\Get-TeamsStatus.ps1
if (-not $ExistingService) {
    Start-Process -FilePath $Path\nssm.exe -ArgumentList 'install "Microsoft Teams Status Monitor" "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe" "-command "& { . C:\Scripts\TeamsStatus\Get-TeamsStatus.ps1 }"" ' -NoNewWindow -Wait
}
Start-Service -Name $ServiceName