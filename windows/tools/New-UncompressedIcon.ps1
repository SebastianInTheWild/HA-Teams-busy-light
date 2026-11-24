<#
.SYNOPSIS
    Creates windows/app/app-icon.ico, the icon embedded in TeamsBusyLight.exe,
    from windows/icon.ico.
.DESCRIPTION
    Writes the images up to 64 pixels as uncompressed 32-bit bitmaps. The PNG
    images of icon.ico are compressed; embedded in the executable they looked
    like packed data (high entropy) to security software. Larger images are
    left out: uncompressed, a 256 pixel image alone takes 256 KB, and Windows
    scales the 64 pixel image instead.
    Run again after changing icon.ico and commit the result.
#>
param(
    [string]$Source = (Join-Path $PSScriptRoot '..\icon.ico'),
    [string]$Destination = (Join-Path $PSScriptRoot '..\app\app-icon.ico'),
    [int]$MaxSize = 64
)

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Drawing
$Source = (Resolve-Path $Source).Path
$Data = [System.IO.File]::ReadAllBytes($Source)
$Images = @()
for ($Index = 0; $Index -lt [BitConverter]::ToUInt16($Data, 4); $Index++) {
    $Entry = 6 + 16 * $Index
    $Size = [BitConverter]::ToInt32($Data, $Entry + 8)
    $Offset = [BitConverter]::ToInt32($Data, $Entry + 12)
    # icon.ico holds PNG images only
    if ($Data[$Offset] -ne 0x89) {
        throw "Image $($Index + 1) of $Source is not a PNG image."
    }
    $Stream = New-Object System.IO.MemoryStream($Data, $Offset, $Size)
    try {
        $Bitmap = New-Object System.Drawing.Bitmap($Stream)
    }
    finally {
        $Stream.Dispose()
    }
    if ($Bitmap.Width -le $MaxSize -and $Bitmap.Height -le $MaxSize) {
        $Images += $Bitmap
    }
    else {
        $Bitmap.Dispose()
    }
}
if (-not $Images.Count) {
    throw "$Source has no image of up to $MaxSize pixels."
}

$Output = New-Object System.IO.MemoryStream
$Writer = New-Object System.IO.BinaryWriter($Output)
$Writer.Write([uint16]0); $Writer.Write([uint16]1); $Writer.Write([uint16]$Images.Count)
$Offset = 6 + 16 * $Images.Count
$Blocks = foreach ($Bitmap in $Images) {
    $Width = $Bitmap.Width
    $Height = $Bitmap.Height
    $MaskRow = [int]([Math]::Ceiling($Width / 32) * 4)
    $PixelBytes = $Width * $Height * 4
    $Block = New-Object byte[] (40 + $PixelBytes + $MaskRow * $Height)
    $Header = New-Object System.IO.BinaryWriter(New-Object System.IO.MemoryStream(, $Block))
    # BITMAPINFOHEADER; the height counts the colors and the mask
    $Header.Write([int]40); $Header.Write([int]$Width); $Header.Write([int]($Height * 2))
    $Header.Write([uint16]1); $Header.Write([uint16]32); $Header.Write([int]0)
    $Header.Write([int]($Block.Length - 40))
    $Rect = New-Object System.Drawing.Rectangle(0, 0, $Width, $Height)
    $Locked = $Bitmap.LockBits($Rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    try {
        # BGRA rows, bottom-up; the mask stays empty (the alpha channel counts)
        for ($Row = 0; $Row -lt $Height; $Row++) {
            $Line = [IntPtr]::Add($Locked.Scan0, $Row * $Locked.Stride)
            [System.Runtime.InteropServices.Marshal]::Copy($Line, $Block, 40 + ($Height - 1 - $Row) * $Width * 4, $Width * 4)
        }
    }
    finally {
        $Bitmap.UnlockBits($Locked)
        $Bitmap.Dispose()
    }
    $Writer.Write([byte]($Width % 256)); $Writer.Write([byte]($Height % 256))
    $Writer.Write([byte]0); $Writer.Write([byte]0)
    $Writer.Write([uint16]1); $Writer.Write([uint16]32)
    $Writer.Write([int]$Block.Length); $Writer.Write([int]$Offset)
    $Offset += $Block.Length
    , $Block
}
foreach ($Block in $Blocks) {
    $Writer.Write($Block)
}
[System.IO.File]::WriteAllBytes([System.IO.Path]::GetFullPath($Destination), $Output.ToArray())
Write-Output "Created $Destination ($($Images.Count) images)"
