<#
.SYNOPSIS
    Builds the Windows download TeamsBusyLight-Windows.zip.
.DESCRIPTION
    Builds TeamsBusyLight.exe (windows/app, .NET Framework 4.8) with the
    version passed in and puts it into <OutputPath>\TeamsBusyLight-Windows
    together with README.md, version.txt and Install.ps1 (only for the update
    from the PowerShell versions before 1.8.0).

    With a signing certificate it then writes two signed lists of the files:
    - TeamsBusyLight.sha256.p7m: the SHA-256 hashes of all files, signed as
      CMS. The update function of the app (Updater.cs) installs only
      downloads whose list is signed with the certificate pinned in Paths.cs
      and whose files match it.
    - TeamsBusyLight.cat: a catalog of all files with a timestamp, checked by
      the update function of the PowerShell versions before 1.8.0, so they
      can update themselves to this version.

    Without a certificate the download is built unsigned (the app then only
    shows the update hint, no update button).

    Used by the release workflow (Windows PowerShell 5.1) and for local tests;
    needs the .NET SDK.
.PARAMETER PfxBase64
    The PFX file as Base64 (GitHub secret WINDOWS_SIGNING_PFX).
.PARAMETER Password
    Its password (GitHub secret WINDOWS_SIGNING_PASSWORD).
#>
param(
    [Parameter(Mandatory)][string]$Version,
    [string]$OutputPath = (Join-Path $PSScriptRoot '..\..\dist'),
    [string]$PfxBase64 = $env:WINDOWS_SIGNING_PFX,
    [string]$Password = $env:WINDOWS_SIGNING_PASSWORD,
    [string]$TimestampServer = 'http://timestamp.digicert.com'
)

$ErrorActionPreference = 'Stop'

$WindowsDir = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$AppDir = Join-Path $WindowsDir 'app'
$ManifestName = 'TeamsBusyLight.sha256.p7m'
$CatalogName = 'TeamsBusyLight.cat'

# The pinned fingerprint, from the app itself
$PathsSource = [System.IO.File]::ReadAllText((Join-Path $AppDir 'Paths.cs'))
$PinnedSha256 = [regex]::Match($PathsSource, 'SigningCertificateSha256 = "([0-9A-Fa-f]*)"').Groups[1].Value

$Version = $Version.TrimStart('v')
if ($Version -notmatch '^(\d+)\.(\d+)\.(\d+)(-[0-9A-Za-z.-]+)?$') {
    throw "Invalid version '$Version' (expected 1.2.3 or 1.2.3-beta.1)."
}
# Windows wants four numbers for the file version
$NumericVersion = '{0}.{1}.{2}.0' -f $Matches[1], $Matches[2], $Matches[3]

New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null
$OutputPath = (Resolve-Path $OutputPath).Path
$StageDir = Join-Path $OutputPath 'TeamsBusyLight-Windows'
$BuildDir = Join-Path $OutputPath 'build'
$ZipPath = Join-Path $OutputPath 'TeamsBusyLight-Windows.zip'
foreach ($OldItem in $StageDir, $BuildDir, $ZipPath) {
    if (Test-Path $OldItem) {
        Remove-Item -LiteralPath $OldItem -Recurse -Force
    }
}

& dotnet build $AppDir --configuration Release --nologo --output $BuildDir `
    "-p:Version=$Version" "-p:AssemblyVersion=$NumericVersion" "-p:FileVersion=$NumericVersion"
if ($LASTEXITCODE -ne 0) {
    throw "dotnet build failed ($LASTEXITCODE)."
}

New-Item -Path $StageDir -ItemType Directory | Out-Null
Copy-Item -LiteralPath (Join-Path $BuildDir 'TeamsBusyLight.exe') -Destination $StageDir
Copy-Item -LiteralPath (Join-Path $WindowsDir 'README.md') -Destination $StageDir
Copy-Item -LiteralPath (Join-Path $WindowsDir 'Install.ps1') -Destination $StageDir
[System.IO.File]::WriteAllText((Join-Path $StageDir 'version.txt'), $Version, (New-Object System.Text.ASCIIEncoding))
Remove-Item -LiteralPath $BuildDir -Recurse -Force

# Placeholder: with a code signing certificate trusted by Windows, sign the
# executable itself here (Set-AuthenticodeSignature with a timestamp), before
# the lists below are written.

function Get-CertificateSha256 {
    param([System.Security.Cryptography.X509Certificates.X509Certificate2]$Certificate)

    $Hash = [System.Security.Cryptography.SHA256]::Create().ComputeHash($Certificate.RawData)
    return [BitConverter]::ToString($Hash).Replace('-', '')
}

# The text of the file list, exactly as Updater.ManifestText writes it:
# "<sha256>  <path>" per file, paths relative with "/", sorted ordinally
function Get-ManifestText {
    param([string]$Folder)

    $Paths = [System.Collections.Generic.List[string]]::new()
    # -Name: relative paths (FullName may use the long form of a short 8.3 path)
    foreach ($Name in Get-ChildItem -LiteralPath $Folder -Recurse -File -Name) {
        $Relative = $Name.Replace('\', '/')
        if ($Relative -ne $ManifestName -and $Relative -ne $CatalogName) {
            $Paths.Add($Relative)
        }
    }
    $Paths.Sort([System.StringComparer]::Ordinal)
    $Sha256 = [System.Security.Cryptography.SHA256]::Create()
    $Lines = foreach ($Relative in $Paths) {
        $Bytes = [System.IO.File]::ReadAllBytes((Join-Path $Folder $Relative.Replace('/', '\')))
        $Hash = [BitConverter]::ToString($Sha256.ComputeHash($Bytes)).Replace('-', '').ToLowerInvariant()
        "$Hash  $Relative"
    }
    return ($Lines -join "`n") + "`n"
}

if ($PfxBase64) {
    Add-Type -AssemblyName System.Security
    $PfxPath = Join-Path ([System.IO.Path]::GetTempPath()) ('TeamsBusyLight-{0}.pfx' -f [guid]::NewGuid())
    try {
        [System.IO.File]::WriteAllBytes($PfxPath, [Convert]::FromBase64String($PfxBase64.Trim()))
        $Certificate = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($PfxPath, $Password)
    }
    finally {
        Remove-Item -LiteralPath $PfxPath -Force -ErrorAction SilentlyContinue
    }
    $Fingerprint = Get-CertificateSha256 $Certificate
    Write-Output "Signing certificate: $($Certificate.Subject), SHA-256 $Fingerprint"
    if ($PinnedSha256 -and $Fingerprint -ne $PinnedSha256) {
        throw "The signing certificate does not match SigningCertificateSha256 in Paths.cs ($PinnedSha256). Installed apps would reject this download."
    }

    # File list for the app (CMS, the list inside the signature)
    $ManifestPath = Join-Path $StageDir $ManifestName
    $Text = Get-ManifestText $StageDir
    $Content = New-Object System.Security.Cryptography.Pkcs.ContentInfo(, [System.Text.Encoding]::UTF8.GetBytes($Text))
    $Signed = New-Object System.Security.Cryptography.Pkcs.SignedCms($Content, $false)
    $Signed.ComputeSignature((New-Object System.Security.Cryptography.Pkcs.CmsSigner($Certificate)))
    [System.IO.File]::WriteAllBytes($ManifestPath, $Signed.Encode())

    # Check it like the app does
    $Check = New-Object System.Security.Cryptography.Pkcs.SignedCms
    $Check.Decode([System.IO.File]::ReadAllBytes($ManifestPath))
    $Check.CheckSignature($true)
    if ((Get-CertificateSha256 $Check.SignerInfos[0].Certificate) -ne $Fingerprint -or
        [System.Text.Encoding]::UTF8.GetString($Check.ContentInfo.Content) -ne (Get-ManifestText $StageDir)) {
        throw 'Check of the signed file list failed.'
    }
    Write-Output 'File list signed and checked.'

    # Catalog for the PowerShell versions before 1.8.0 (over all files, the list included)
    $CatalogPath = Join-Path $StageDir $CatalogName
    Import-Module -Name (Join-Path $PSHOME 'Modules\Microsoft.PowerShell.Security') -ErrorAction Stop
    New-FileCatalog -Path $StageDir -CatalogFilePath $CatalogPath -CatalogVersion 2.0 | Out-Null
    # The timestamp keeps the signature valid after the certificate expires
    $Signature = $null
    for ($Attempt = 1; $Attempt -le 3; $Attempt++) {
        $Signature = Set-AuthenticodeSignature -FilePath $CatalogPath -Certificate $Certificate -HashAlgorithm SHA256 -TimestampServer $TimestampServer
        if ($Signature.TimeStamperCertificate) {
            break
        }
        Start-Sleep -Seconds (5 * $Attempt)
    }
    # UnknownError/NotTrusted: Windows does not trust the self-signed root; expected
    if ($Signature.Status -notin @('Valid', 'UnknownError', 'NotTrusted') -or -not $Signature.SignerCertificate) {
        throw "Signing the catalog failed: $($Signature.Status) $($Signature.StatusMessage)"
    }
    if (-not $Signature.TimeStamperCertificate) {
        throw "No timestamp from $TimestampServer."
    }
    $Result = Test-FileCatalog -CatalogFilePath $CatalogPath -Path $StageDir
    if ($Result -ne 'Valid') {
        throw "Check of the signed catalog failed: $Result"
    }
    Write-Output 'Catalog signed and checked.'
}
else {
    Write-Warning 'No signing certificate (WINDOWS_SIGNING_PFX); the download is unsigned.'
}

Add-Type -AssemblyName System.IO.Compression.FileSystem
[System.IO.Compression.ZipFile]::CreateFromDirectory($StageDir, $ZipPath, [System.IO.Compression.CompressionLevel]::Optimal, $true)
Write-Output "Created $ZipPath"
