<#
.SYNOPSIS
    Builds the Windows download TeamsBusyLight-Windows.zip.
.DESCRIPTION
    Copies the app files (without tools) to <OutputPath>\TeamsBusyLight-Windows,
    writes version.txt and, with a signing certificate, creates the catalog
    TeamsBusyLight.cat with the SHA-256 hashes of all files and signs it with
    a timestamp. The update function of the app installs only downloads whose
    catalog is signed with the certificate pinned in Common.ps1 and whose files
    match the catalog.

    Without a certificate the download is built unsigned (the app then only
    shows the update hint, no update button).

    Used by the release workflow (Windows PowerShell 5.1) and for local tests.
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

$SourceDir = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
. (Join-Path $SourceDir 'Common.ps1')

New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null
$OutputPath = (Resolve-Path $OutputPath).Path
$StageDir = Join-Path $OutputPath 'TeamsBusyLight-Windows'
$ZipPath = Join-Path $OutputPath 'TeamsBusyLight-Windows.zip'
foreach ($OldItem in $StageDir, $ZipPath) {
    if (Test-Path $OldItem) {
        Remove-Item -LiteralPath $OldItem -Recurse -Force
    }
}

New-Item -Path $StageDir -ItemType Directory | Out-Null
Get-ChildItem -LiteralPath $SourceDir | Where-Object { $_.Name -ne 'tools' } |
    Copy-Item -Destination $StageDir -Recurse
[System.IO.File]::WriteAllText((Join-Path $StageDir 'version.txt'), $Version.TrimStart('v'), (New-Object System.Text.ASCIIEncoding))

if ($PfxBase64) {
    $PfxPath = Join-Path ([System.IO.Path]::GetTempPath()) ('TeamsBusyLight-{0}.pfx' -f [guid]::NewGuid())
    try {
        [System.IO.File]::WriteAllBytes($PfxPath, [Convert]::FromBase64String($PfxBase64.Trim()))
        $Certificate = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($PfxPath, $Password)
    }
    finally {
        Remove-Item -LiteralPath $PfxPath -Force -ErrorAction SilentlyContinue
    }
    $Fingerprint = Get-TeamsCertificateSha256 $Certificate
    Write-Output "Signing certificate: $($Certificate.Subject), SHA-256 $Fingerprint"
    if ($SigningCertificateSha256 -and $Fingerprint -ne $SigningCertificateSha256) {
        throw "The signing certificate does not match `$SigningCertificateSha256 in Common.ps1 ($SigningCertificateSha256). Installed apps would reject this download."
    }

    $CatalogPath = Join-Path $StageDir $ReleaseCatalogName
    Import-TeamsSecurityModule
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
        throw "Signing failed: $($Signature.Status) $($Signature.StatusMessage)"
    }
    if (-not $Signature.TimeStamperCertificate) {
        throw "No timestamp from $TimestampServer."
    }

    $Problem = Test-TeamsReleaseSignature -Path $StageDir -Fingerprint $Fingerprint
    if ($Problem) {
        throw "Check of the signed download failed: $Problem"
    }
    Write-Output 'Catalog signed and checked.'
}
else {
    Write-Warning 'No signing certificate (WINDOWS_SIGNING_PFX); the download is unsigned.'
}

Add-Type -AssemblyName System.IO.Compression.FileSystem
[System.IO.Compression.ZipFile]::CreateFromDirectory($StageDir, $ZipPath, [System.IO.Compression.CompressionLevel]::Optimal, $true)
Write-Output "Created $ZipPath"
