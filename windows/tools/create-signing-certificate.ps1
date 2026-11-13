<#
.SYNOPSIS
    Creates the self-signed code signing certificate for the Windows release
    of Teams Busy Light (run once).
.DESCRIPTION
    The release workflow signs a catalog of all files of the Windows download
    with this certificate. The update function of the app installs a new
    version only if the catalog is signed with exactly this certificate (its
    SHA-256 fingerprint is pinned in Common.ps1). Windows itself does not need
    to trust the certificate.

    Writes the PFX file, its password and a Base64 copy for the GitHub secret
    to a folder outside the repository, prints the fingerprint and removes the
    certificate from the certificate store again.

    Keep the PFX file and its password. A new certificate needs a new
    fingerprint in Common.ps1; installed versions with the old fingerprint
    then no longer accept updates and have to be updated by hand once.
.PARAMETER OutputPath
    Target folder, by default teams-busy-light-signing-windows in the user
    profile. Never inside the repository.
#>
param(
    [string]$OutputPath = (Join-Path $HOME 'teams-busy-light-signing-windows')
)

$ErrorActionPreference = 'Stop'

$RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$FullOutputPath = [System.IO.Path]::GetFullPath($OutputPath)
if ($FullOutputPath.StartsWith($RepositoryRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "The private key must not be stored inside the repository ($RepositoryRoot). Choose another -OutputPath."
}
if (Test-Path (Join-Path $FullOutputPath 'signing.pfx')) {
    throw "$FullOutputPath\signing.pfx already exists. Move it away first; a new certificate breaks updates of installed versions."
}
New-Item -Path $FullOutputPath -ItemType Directory -Force | Out-Null

$Certificate = New-SelfSignedCertificate -Type CodeSigningCert -Subject 'CN=Teams Busy Light' `
    -KeyAlgorithm RSA -KeyLength 3072 -HashAlgorithm SHA256 -KeyExportPolicy Exportable `
    -NotAfter (Get-Date).AddYears(10) -CertStoreLocation 'Cert:\CurrentUser\My'
try {
    $Bytes = New-Object byte[] 24
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($Bytes)
    $Password = [Convert]::ToBase64String($Bytes)
    $SecurePassword = ConvertTo-SecureString -String $Password -AsPlainText -Force

    $PfxPath = Join-Path $FullOutputPath 'signing.pfx'
    Export-PfxCertificate -Cert $Certificate -FilePath $PfxPath -Password $SecurePassword | Out-Null
    $Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText((Join-Path $FullOutputPath 'password.txt'), $Password, $Utf8NoBom)
    [System.IO.File]::WriteAllText((Join-Path $FullOutputPath 'signing.pfx.base64'), [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($PfxPath)), $Utf8NoBom)

    $Hash = [System.Security.Cryptography.SHA256]::Create().ComputeHash($Certificate.RawData)
    $Fingerprint = [BitConverter]::ToString($Hash).Replace('-', '')
}
finally {
    # Only the PFX file keeps the private key
    Remove-Item -LiteralPath "Cert:\CurrentUser\My\$($Certificate.Thumbprint)" -DeleteKey -ErrorAction SilentlyContinue
}

# Only the current user may read the folder
$Acl = New-Object System.Security.AccessControl.DirectorySecurity
$Acl.SetAccessRuleProtection($true, $false)
$Acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
    [System.Security.Principal.WindowsIdentity]::GetCurrent().User, 'FullControl', 'ContainerInherit, ObjectInherit', 'None', 'Allow')))
Set-Acl -Path $FullOutputPath -AclObject $Acl

Write-Output "Created in ${FullOutputPath}:"
Write-Output '  signing.pfx          certificate and private key'
Write-Output '  password.txt         its password'
Write-Output '  signing.pfx.base64   for the GitHub secret'
Write-Output ''
Write-Output "SHA-256 fingerprint (for `$SigningCertificateSha256 in windows/Common.ps1):"
Write-Output "  $Fingerprint"
Write-Output ''
Write-Output 'Set the GitHub secrets (in the repository folder):'
Write-Output "  gh secret set WINDOWS_SIGNING_PFX < `"$FullOutputPath\signing.pfx.base64`""
Write-Output "  gh secret set WINDOWS_SIGNING_PASSWORD < `"$FullOutputPath\password.txt`""
Write-Output ''
Write-Output 'Build a signed download locally:'
Write-Output "  `$env:WINDOWS_SIGNING_PFX = Get-Content `"$FullOutputPath\signing.pfx.base64`""
Write-Output "  `$env:WINDOWS_SIGNING_PASSWORD = Get-Content `"$FullOutputPath\password.txt`""
Write-Output '  powershell -ExecutionPolicy Bypass -File windows\tools\build-release.ps1 -Version 1.2.3'
