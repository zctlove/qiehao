[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$localizationPath = Join-Path $projectRoot 'gui\Localization.psm1'
$helperPath = Join-Path $projectRoot 'gui\GuiHelpers.psm1'
$quotaHelperPath = Join-Path $projectRoot 'gui\QuotaHelpers.psm1'
$guiPath = Join-Path $projectRoot 'gui\QiehaoGui.ps1'
$hostExecutable = if ($PSVersionTable.PSVersion.Major -ge 6) {
    Join-Path $PSHOME 'pwsh.exe'
}
else { Join-Path $PSHOME 'powershell.exe' }

function Assert-LocalizationTest {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Code
    )
    if (-not $Condition) { throw $Code }
}

Import-Module -Name $localizationPath -Force -ErrorAction Stop
Import-Module -Name $helperPath -Force -ErrorAction Stop
Import-Module -Name $quotaHelperPath -Force -ErrorAction Stop

$languages = @(Get-QiehaoSupportedLanguages)
Assert-LocalizationTest (
    $languages.Count -eq 2 -and
    (@($languages.Code) -join '|') -ceq 'zh-CN|en-US'
) 'SUPPORTED_LANGUAGES_INVALID'
Assert-LocalizationTest (
    (Resolve-QiehaoLanguage -Language $null) -ceq 'zh-CN' -and
    (Resolve-QiehaoLanguage -Language '') -ceq 'zh-CN'
) 'DEFAULT_LANGUAGE_NOT_ZH_CN'
Assert-LocalizationTest (
    (Resolve-QiehaoLanguage -Language 'fr-FR') -ceq 'zh-CN' -and
    (Resolve-QiehaoLanguage -Language 'abc') -ceq 'zh-CN'
) 'UNKNOWN_LANGUAGE_DID_NOT_FALL_BACK'

$zhCatalog = Get-QiehaoLocalizationCatalog -Language 'zh-CN'
$enCatalog = Get-QiehaoLocalizationCatalog -Language 'en-US'
$zhKeys = @($zhCatalog.Keys | Sort-Object)
$enKeys = @($enCatalog.Keys | Sort-Object)
Assert-LocalizationTest (
    $zhKeys.Count -gt 100 -and
    ($zhKeys -join '|') -ceq ($enKeys -join '|')
) 'LOCALIZATION_PRODUCTION_KEY_SET_MISMATCH'
Assert-LocalizationTest (
    @($zhKeys | Select-Object -Unique).Count -eq $zhKeys.Count -and
    @($enKeys | Select-Object -Unique).Count -eq $enKeys.Count
) 'LOCALIZATION_DUPLICATE_KEYS'
Assert-LocalizationTest (
    (Format-QiehaoLocalizedString -Language 'en-US' `
        -Key 'Switch.SuccessCurrent' -Arguments @('Team')) -match
        'Current account: Team'
) 'LOCALIZATION_FORMAT_ARGUMENT_FAILED'
Assert-LocalizationTest (
    (Get-QiehaoLocalizedString -Language 'en-US' `
        -Key 'Does.Not.Exist') -ceq '[Missing:Does.Not.Exist]'
) 'LOCALIZATION_MISSING_KEY_NOT_SAFE'
Assert-LocalizationTest (
    (Get-QiehaoLocalizedThemeName -Language 'zh-CN' `
        -ThemeId '04-purple-tech') -ceq '紫蓝星河' -and
    (Get-QiehaoLocalizedThemeName -Language 'en-US' `
        -ThemeId '04-purple-tech') -ceq 'Purple Nebula' -and
    (Get-QiehaoLocalizedThemeName -Language 'zh-CN' `
        -ThemeId '06-aurora-silver-blue') -ceq '极光银蓝' -and
    (Get-QiehaoLocalizedThemeName -Language 'en-US' `
        -ThemeId '06-aurora-silver-blue') -ceq 'Aurora Silver Blue' -and
    (Get-QiehaoLocalizedThemeName -Language 'zh-CN' `
        -ThemeId '07-arctic-sea-glass') -ceq '浅海冰晶' -and
    (Get-QiehaoLocalizedThemeName -Language 'en-US' `
        -ThemeId '07-arctic-sea-glass') -ceq 'Arctic Sea Glass'
) 'LOCALIZATION_THEME_NAMES_INVALID'
$diagnostic = Format-QiehaoLocalizedString -Language 'en-US' `
    -Key 'Quota.ErrorCode' -Arguments @('QUOTA_RATE_LIMITS_TIMEOUT')
Assert-LocalizationTest (
    $diagnostic -ceq 'Error code: QUOTA_RATE_LIMITS_TIMEOUT'
) 'LOCALIZATION_DIAGNOSTIC_CODE_TRANSLATED'

$tempBase = [System.IO.Path]::GetFullPath(
    [System.IO.Path]::GetTempPath()
).TrimEnd([System.IO.Path]::DirectorySeparatorChar)
$testRoot = [System.IO.Path]::GetFullPath((Join-Path $tempBase (
    'qiehao-localization-' + [Guid]::NewGuid().ToString('N')
)))
if (-not $testRoot.StartsWith(
    $tempBase + [System.IO.Path]::DirectorySeparatorChar,
    [StringComparison]::OrdinalIgnoreCase
)) { throw 'LOCALIZATION_TEST_PATH_INVALID' }
[System.IO.Directory]::CreateDirectory($testRoot) | Out-Null

try {
    $missing = Read-QiehaoUiPreferences -StateDirectory $testRoot
    Assert-LocalizationTest (
        $missing.Background -ceq '01-blue-glass' -and
        $missing.Language -ceq 'zh-CN' -and $missing.UsedDefault
    ) 'MISSING_PREFERENCES_NOT_SAFE'

    $written = Write-QiehaoUiPreferences -StateDirectory $testRoot `
        -Background '06-aurora-silver-blue' -Language 'en-US'
    $path = Join-Path $testRoot 'ui-preferences.json'
    $firstText = [System.IO.File]::ReadAllText($path)
    $languageChanged = Write-QiehaoUiPreferences `
        -StateDirectory $testRoot -Language 'zh-CN'
    $themeChanged = Write-QiehaoUiPreferences `
        -StateDirectory $testRoot -Background '07-arctic-sea-glass'
    $restart = Read-QiehaoUiPreferences -StateDirectory $testRoot
    Assert-LocalizationTest (
        $written.Background -ceq '06-aurora-silver-blue' -and
        $written.Language -ceq 'en-US' -and
        $languageChanged.Background -ceq '06-aurora-silver-blue' -and
        $languageChanged.Language -ceq 'zh-CN' -and
        $themeChanged.Background -ceq '07-arctic-sea-glass' -and
        $themeChanged.Language -ceq 'zh-CN' -and
        $restart.Background -ceq '07-arctic-sea-glass' -and
        $restart.Language -ceq 'zh-CN'
    ) 'LANGUAGE_THEME_PERSISTENCE_NOT_INDEPENDENT'
    Assert-LocalizationTest (
        $firstText -match '"schema_version"\s*:\s*2' -and
        $firstText -match '"language"\s*:\s*"en-US"' -and
        @([System.IO.Directory]::GetFiles(
            $testRoot, '.ui-preferences.*.tmp'
        )).Count -eq 0
    ) 'ATOMIC_PREFERENCE_WRITE_FAILED'

    [System.IO.File]::WriteAllText(
        $path,
        '{"schema_version":1,"background":"02-navy-gold"}'
    )
    $oldSchema = Read-QiehaoUiPreferences -StateDirectory $testRoot
    Assert-LocalizationTest (
        $oldSchema.Background -ceq '02-navy-gold' -and
        $oldSchema.Language -ceq 'zh-CN'
    ) 'OLD_PREFERENCES_DID_NOT_DEFAULT_ZH_CN'

    [System.IO.File]::WriteAllText($path, '{"Language":"en-US"}')
    $languageOnly = Read-QiehaoUiPreferences -StateDirectory $testRoot
    [System.IO.File]::WriteAllText($path, '{"Theme":"02-navy-gold"}')
    $themeOnly = Read-QiehaoUiPreferences -StateDirectory $testRoot
    [System.IO.File]::WriteAllText(
        $path,
        '{"schema_version":2,"background":"04-purple-tech","language":"fr-FR"}'
    )
    $unknownLanguage = Read-QiehaoUiPreferences -StateDirectory $testRoot
    Assert-LocalizationTest (
        $languageOnly.Background -ceq '01-blue-glass' -and
        $languageOnly.Language -ceq 'en-US' -and
        $themeOnly.Background -ceq '02-navy-gold' -and
        $themeOnly.Language -ceq 'zh-CN' -and
        $unknownLanguage.Background -ceq '04-purple-tech' -and
        $unknownLanguage.Language -ceq 'zh-CN' -and
        -not $unknownLanguage.IsValid
    ) 'PARTIAL_OR_UNKNOWN_PREFERENCES_NOT_SAFE'

    [System.IO.File]::WriteAllText($path, '{BROKEN JSON')
    $corrupt = Read-QiehaoUiPreferences -StateDirectory $testRoot
    Assert-LocalizationTest (
        $corrupt.Background -ceq '01-blue-glass' -and
        $corrupt.Language -ceq 'zh-CN' -and
        -not $corrupt.IsValid -and $corrupt.UsedDefault
    ) 'CORRUPT_PREFERENCES_DID_NOT_FAIL_OPEN'

    $otherCwd = Join-Path $testRoot 'foreign-cwd'
    [System.IO.Directory]::CreateDirectory($otherCwd) | Out-Null
    Push-Location -LiteralPath $otherCwd
    try {
        Import-Module -Name $localizationPath -Force -ErrorAction Stop
        $foreignText = Get-QiehaoLocalizedString `
            -Language 'en-US' -Key 'Button.Switch'
    }
    finally { Pop-Location }
    Assert-LocalizationTest (
        $foreignText -ceq 'Switch Account'
    ) 'LOCALIZATION_FOREIGN_CWD_FAILED'
}
finally {
    if ([System.IO.Directory]::Exists($testRoot)) {
        [System.IO.Directory]::Delete($testRoot, $true)
    }
}

$helperSource = [System.IO.File]::ReadAllText($helperPath)
Assert-LocalizationTest (
    $helperSource -match 'NullString\]::Value' -and
    $helperSource -match 'schema_version = 2' -and
    $helperSource -match 'language = \$resolvedLanguage'
) 'POWERSHELL51_NULLSTRING_REPLACE_CONTRACT_FAILED'
$guiSource = [System.IO.File]::ReadAllText($guiPath)
Assert-LocalizationTest (
    $guiSource -notmatch
        'if\s*\(\s*\$[^\r\n]*language[^\r\n]*-eq[^\r\n]*zh-CN' -and
    $guiSource -match 'Apply-QiehaoLocalization' -and
    $guiSource -match 'Update-QiehaoQuotaProfileRows[\s\S]*-Language'
) 'LOCALIZATION_PRODUCTION_ARCHITECTURE_INVALID'

$guiOutput = @(& $hostExecutable -NoProfile -NonInteractive -STA `
    -ExecutionPolicy Bypass -File $guiPath -SelfTest `
    -LocalizationLifecycleSelfTest 2>&1)
$guiExitCode = $LASTEXITCODE
$requiredGuiOutput = @(
    'InitialZhCnTextsCorrect=True',
    'SwitchToEnUsUpdatesWindowTitle=True',
    'SwitchToEnUsUpdatesButtons=True',
    'SwitchToEnUsUpdatesDataGridHeaders=True',
    'SwitchToEnUsUpdatesStatus=True',
    'SwitchToEnUsUpdatesQuotaTooltip=True',
    'DynamicCodexStatesEnUs=True',
    'DynamicWorkflowStatesEnUs=True',
    'DynamicQuotaStatusRedrawsAcrossLanguages=True',
    'SwitchBackToZhCnWorks=True',
    'LanguageSwitchPreservesCoreState=True',
    'LanguageSwitchStartsNoBusinessAction=True',
    'EnglishWpfLayoutMeasured=True',
    'GUI_LOCALIZATION_LIFECYCLE_SELFTEST_PASS'
)
$guiLines = @($guiOutput | ForEach-Object { [string]$_ })
Assert-LocalizationTest (
    $guiExitCode -eq 0 -and
    @($requiredGuiOutput | Where-Object {
        $guiLines -cnotcontains $_
    }).Count -eq 0
) ('GUI_LOCALIZATION_LIFECYCLE_FAILED: ' + ($guiLines -join ' | '))

Write-Output 'SupportedLanguagesExactlyZhCnEnUs=True'
Write-Output 'DefaultLanguageZhCn=True'
Write-Output 'UnknownLanguageFallsBackZhCn=True'
Write-Output 'AllProductionKeysExistZhCn=True'
Write-Output 'AllProductionKeysExistEnUs=True'
Write-Output 'NoDuplicateKeys=True'
Write-Output 'FormattedStringArgumentsWork=True'
Write-Output 'MissingKeyFailsSafe=True'
Write-Output 'ThemeDisplayNamesLocalized=True'
Write-Output 'NewThemeDisplayNamesLocalized=True'
Write-Output 'DiagnosticCodesRemainUntranslated=True'
Write-Output 'LanguagePreferencePersists=True'
Write-Output 'LanguagePreferenceSurvivesRestartSimulation=True'
Write-Output 'OldPreferencesWithoutLanguageDefaultsZhCn=True'
Write-Output 'ChangingLanguagePreservesTheme=True'
Write-Output 'ChangingThemePreservesLanguage=True'
Write-Output 'NewThemePreferencesPersist=True'
Write-Output 'CorruptPreferencesFailOpen=True'
Write-Output 'AtomicPreferenceWrite=True'
Write-Output 'PowerShell51NullStringReplaceContract=True'
Write-Output 'LocalizationForeignCwd=True'
Write-Output 'LOCALIZATION_SELFTEST_PASS'
