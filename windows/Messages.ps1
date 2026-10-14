function Get-TeamsMessages {
    param(
        [string]$Language,
        [string]$Root = $PSScriptRoot
    )

    $LanguageCode = $Language
    if ([string]::IsNullOrWhiteSpace($LanguageCode)) {
        $LanguageCode = "en"
    }
    $LanguageCode = $LanguageCode.ToLowerInvariant().Split('-')[0]

    $TranslationPath = Join-Path $Root "Translations\$LanguageCode.psd1"
    if (-not (Test-Path $TranslationPath)) {
        $TranslationPath = Join-Path $Root "Translations\en.psd1"
    }
    if (-not (Test-Path $TranslationPath)) {
        throw "No English fallback translation found under '$Root\Translations'."
    }

    return Import-PowerShellDataFile -Path $TranslationPath
}
