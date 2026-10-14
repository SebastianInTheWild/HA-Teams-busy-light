Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope Process

$DetectedUiLanguage = [System.Globalization.CultureInfo]::CurrentUICulture.TwoLetterISOLanguageName
$LanguageCode = $DetectedUiLanguage.ToLowerInvariant().Split('-')[0]
$TranslationPath = Join-Path $PSScriptRoot "Translations\$LanguageCode.psd1"
if (-not (Test-Path $TranslationPath)) {
    $TranslationPath = Join-Path $PSScriptRoot "Translations\en.psd1"
}
if (-not (Test-Path $TranslationPath)) {
    throw "No English fallback translation found under '$PSScriptRoot\Translations'."
}
$Messages = Import-PowerShellDataFile -Path $TranslationPath

$CurrentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
$CurrentPrincipal = New-Object Security.Principal.WindowsPrincipal($CurrentIdentity)
if (-not $CurrentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    if ([string]::IsNullOrWhiteSpace($PSCommandPath)) {
        throw $Messages.SaveAndRun
    }

    Write-Host $Messages.Elevating
    $ElevatedArguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $PSCommandPath + '"'
    Start-Process -FilePath 'powershell.exe' -ArgumentList $ElevatedArguments -Verb RunAs
    exit
}

$InstallPath = 'C:\Scripts\TeamsStatus'
$SettingsPath = Join-Path $InstallPath 'Settings.ps1'
$ServiceName = 'Microsoft Teams Status Monitor'

if ((Read-Host $Messages.ConfirmUninstall) -notin @('Y', 'y', 'J', 'j')) {
    Write-Host $Messages.Cancelled
    exit
}

$HAHosts = @()
if (Test-Path $SettingsPath) {
    $SettingsText = Get-Content -Path $SettingsPath -Raw -ErrorAction Stop
    $WebhookMatches = [regex]::Matches(
        $SettingsText,
        'HAWebhookUrl\s*=\s*([''"])(?<url>.*?)\1',
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    )
    foreach ($Match in $WebhookMatches) {
        $WebhookUri = $null
        if ([System.Uri]::TryCreate($Match.Groups['url'].Value, [System.UriKind]::Absolute, [ref]$WebhookUri) -and
            $WebhookUri.Scheme -in @('http', 'https')) {
            $HAHosts += $WebhookUri.Host
        }
    }
    $HAHosts = @($HAHosts | Select-Object -Unique)
}

$Service = Get-CimInstance Win32_Service -Filter "Name='$ServiceName'" -ErrorAction SilentlyContinue
if ($Service) {
    $ExpectedNssmPath = Join-Path $InstallPath 'nssm.exe'
    $ExpectedServicePathPattern = '^\s*"?{0}"?(\s|$)' -f [regex]::Escape($ExpectedNssmPath)
    if ($Service.PathName -notmatch $ExpectedServicePathPattern) {
        throw ($Messages.ServicePathMismatch -f $ServiceName, $Service.PathName)
    }

    if ($Service.State -ne 'Stopped') {
        Stop-Service -Name $ServiceName -Force -PassThru -ErrorAction Stop |
            ForEach-Object { $_.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(30)) }
    }

    if (Test-Path $ExpectedNssmPath) {
        & $ExpectedNssmPath remove $ServiceName confirm | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw ($Messages.ServiceRemovalFailed -f $ServiceName, $LASTEXITCODE)
        }
    }
    else {
        & sc.exe delete $ServiceName | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw ($Messages.ServiceRemovalFailed -f $ServiceName, $LASTEXITCODE)
        }
    }

    $Deadline = (Get-Date).AddSeconds(10)
    do {
        Start-Sleep -Milliseconds 250
        $RemainingService = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    } while ($RemainingService -and (Get-Date) -lt $Deadline)

    if ($RemainingService) {
        throw ($Messages.ServiceStillExists -f $ServiceName)
    }
}

$HostsPath = Join-Path $env:windir 'System32\drivers\etc\hosts'
if (Test-Path $HostsPath) {
    $HostsLines = @(Get-Content -Path $HostsPath -ErrorAction Stop)
    $TaggedLines = New-Object System.Collections.Generic.List[int]
    $LegacyLines = New-Object System.Collections.Generic.List[int]
    $NormalizedHosts = @($HAHosts | ForEach-Object { $_.ToLowerInvariant() })

    for ($Index = 0; $Index -lt $HostsLines.Count; $Index++) {
        $Parts = $HostsLines[$Index] -split '#', 2
        $Tokens = @($Parts[0] -split '\s+' | Where-Object { $_ })
        if ($Tokens.Count -lt 2) { continue }

        $HasConfiguredHost = $false
        foreach ($HostName in $Tokens | Select-Object -Skip 1) {
            if ($HostName.ToLowerInvariant() -in $NormalizedHosts) {
                $HasConfiguredHost = $true
                break
            }
        }
        if (-not $HasConfiguredHost) { continue }

        if ($Parts.Count -gt 1 -and $Parts[1] -match '^\s*Teams Busy Light\s*$') {
            $TaggedLines.Add($Index)
        }
        else {
            $LegacyLines.Add($Index)
        }
    }

    $RemoveLegacyHosts = $false
    if ($LegacyLines.Count -gt 0 -and $NormalizedHosts.Count -gt 0) {
        $HostList = $NormalizedHosts -join ', '
        Write-Host ($Messages.LegacyHostsFound -f $HostList)
        $RemoveLegacyHosts = (Read-Host $Messages.RemoveLegacyHosts) -in @('Y', 'y', 'J', 'j')
    }

    if ($TaggedLines.Count -gt 0 -or ($RemoveLegacyHosts -and $LegacyLines.Count -gt 0)) {
        $TaggedIndexSet = @{}
        foreach ($Index in $TaggedLines) {
            $TaggedIndexSet[$Index] = $true
        }
        $LegacyIndexSet = @{}
        foreach ($Index in $LegacyLines) {
            $LegacyIndexSet[$Index] = $true
        }

        $RemainingLines = for ($Index = 0; $Index -lt $HostsLines.Count; $Index++) {
            if ($TaggedIndexSet.ContainsKey($Index)) { continue }
            if (-not $RemoveLegacyHosts -or -not $LegacyIndexSet.ContainsKey($Index)) {
                $HostsLines[$Index]
                continue
            }

            $Parts = $HostsLines[$Index] -split '#', 2
            $Tokens = @($Parts[0] -split '\s+' | Where-Object { $_ })
            $RemainingAliases = @(
                $Tokens | Select-Object -Skip 1 |
                    Where-Object { $_.ToLowerInvariant() -notin $NormalizedHosts }
            )
            if ($RemainingAliases.Count -eq 0) { continue }

            $Line = (@($Tokens[0]) + $RemainingAliases) -join "`t"
            if ($Parts.Count -gt 1) {
                $Line += "`t#$($Parts[1])"
            }
            $Line
        }
        Set-Content -Path $HostsPath -Value $RemainingLines -Encoding UTF8 -ErrorAction Stop
    }
}

if (Test-Path $InstallPath) {
    $ResolvedInstallPath = [System.IO.Path]::GetFullPath($InstallPath).TrimEnd('\')
    if ($ResolvedInstallPath -ne 'C:\Scripts\TeamsStatus') {
        throw ($Messages.UnsafeInstallPath -f $ResolvedInstallPath)
    }
    Remove-Item -LiteralPath $ResolvedInstallPath -Recurse -Force -ErrorAction Stop
}

Write-Host $Messages.UninstallComplete
