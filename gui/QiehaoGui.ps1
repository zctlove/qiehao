[CmdletBinding()]
param(
    [switch]$SelfTest,
    [switch]$SimulateQuotaModuleUnavailable,
    [switch]$SimulateQuotaQueryFailure,
    [switch]$QuotaAsyncLifecycleSelfTest,
    [switch]$LocalizationLifecycleSelfTest
)

if (($SimulateQuotaModuleUnavailable -or $SimulateQuotaQueryFailure -or
    $QuotaAsyncLifecycleSelfTest -or $LocalizationLifecycleSelfTest) -and
    -not $SelfTest) {
    throw 'SIMULATED_QUOTA_FAILURE_REQUIRES_SELFTEST'
}

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$guiRoot = $PSScriptRoot
$projectRoot = Split-Path -Parent $guiRoot
$coreModulePath = Join-Path -Path $projectRoot -ChildPath 'lib\CodexAuth.psm1'
$helperModulePath = Join-Path -Path $guiRoot -ChildPath 'GuiHelpers.psm1'
$localizationModulePath = Join-Path -Path $guiRoot `
    -ChildPath 'Localization.psm1'
$quotaParserModulePath = Join-Path -Path $projectRoot `
    -ChildPath 'tools\QuotaParser.psm1'
$quotaHelperModulePath = Join-Path -Path $guiRoot -ChildPath 'QuotaHelpers.psm1'
$quotaClientModulePath = Join-Path -Path $projectRoot -ChildPath 'tools\QuotaClient.psm1'
$xamlPath = Join-Path -Path $guiRoot -ChildPath 'MainWindow.xaml'
$stateDirectory = $null
$backgroundDirectory = Join-Path -Path $guiRoot -ChildPath 'assets\backgrounds'
$guiMutexName = 'Qiehaoqu.CodexAccountSwitcher.Gui.v1'

Add-Type -AssemblyName PresentationCore -ErrorAction Stop
Add-Type -AssemblyName PresentationFramework -ErrorAction Stop
Add-Type -AssemblyName WindowsBase -ErrorAction Stop

function Test-QiehaoModuleExportContract {
    param(
        [AllowNull()]
        [System.Management.Automation.PSModuleInfo]$Module,
        [Parameter(Mandatory = $true)]
        [string[]]$RequiredCommands
    )

    if ($null -eq $Module) { return $false }
    foreach ($requiredCommand in $RequiredCommands) {
        if (-not $Module.ExportedCommands.ContainsKey($requiredCommand)) {
            return $false
        }
    }
    return $true
}

Import-Module -Name $coreModulePath -Force -ErrorAction Stop
Import-Module -Name $helperModulePath -Force -ErrorAction Stop
$script:guiLocalizationAvailable = $false
try {
    $localizationModule = @(Import-Module -Name $localizationModulePath `
        -PassThru -Force -ErrorAction Stop | Select-Object -Last 1)[0]
    $script:guiLocalizationAvailable = Test-QiehaoModuleExportContract `
        -Module $localizationModule -RequiredCommands @(
            'Get-QiehaoSupportedLanguages',
            'Resolve-QiehaoLanguage',
            'Get-QiehaoLocalizedString',
            'Format-QiehaoLocalizedString',
            'Get-QiehaoLocalizedThemeName'
        )
}
catch {
    # Localization is optional presentation infrastructure. The existing
    # Chinese XAML and GUI text remain a fail-open fallback for Core.
    $script:guiLocalizationAvailable = $false
}
$script:guiQuotaModulesAvailable = $false
$script:guiQuotaInitializationFailureCode = $null
if ($SimulateQuotaModuleUnavailable) {
    $script:guiQuotaInitializationFailureCode =
        'QUOTA_HELPERS_IMPORT_FAILED'
}
else {
    $quotaParserModule = $null
    $quotaClientModule = $null
    $quotaHelperModule = $null
    try {
        $quotaParserModule = @(Import-Module -Name $quotaParserModulePath `
            -PassThru -ErrorAction Stop | Select-Object -Last 1)[0]
    }
    catch {
        $script:guiQuotaInitializationFailureCode =
            'QUOTA_PARSER_IMPORT_FAILED'
    }
    if ($null -eq $script:guiQuotaInitializationFailureCode) {
        try {
            $quotaClientModule = @(Import-Module -Name $quotaClientModulePath `
                -PassThru -ErrorAction Stop | Select-Object -Last 1)[0]
        }
        catch {
            $script:guiQuotaInitializationFailureCode =
                'QUOTA_CLIENT_IMPORT_FAILED'
        }
    }
    if ($null -eq $script:guiQuotaInitializationFailureCode) {
        try {
            $quotaHelperModule = @(Import-Module -Name $quotaHelperModulePath `
                -PassThru -ErrorAction Stop | Select-Object -Last 1)[0]
        }
        catch {
            $script:guiQuotaInitializationFailureCode =
                'QUOTA_HELPERS_IMPORT_FAILED'
        }
    }
    if ($null -eq $script:guiQuotaInitializationFailureCode) {
        $parserContract = Test-QiehaoModuleExportContract `
            -Module $quotaParserModule `
            -RequiredCommands @('ConvertTo-QiehaoQuotaSnapshot')
        $clientContract = Test-QiehaoModuleExportContract `
            -Module $quotaClientModule `
            -RequiredCommands @(
                'Get-QiehaoCurrentQuotaSnapshot',
                'Invoke-QiehaoQuotaBackgroundWorker'
            )
        $helperContract = Test-QiehaoModuleExportContract `
            -Module $quotaHelperModule -RequiredCommands @(
                'Get-QiehaoQuotaUiText',
                'New-QiehaoEmptyQuotaCache',
                'Read-QiehaoQuotaCache',
                'Write-QiehaoQuotaCache',
                'Get-QiehaoQuotaCacheSnapshot',
                'Save-QiehaoQuotaSnapshot',
                'Rename-QiehaoQuotaCacheProfile',
                'Remove-QiehaoQuotaCacheProfile',
                'New-QiehaoQuotaCoordinatorState',
                'Invoke-QiehaoQuotaCacheRefresh',
                'Update-QiehaoQuotaProfileRows'
            )
        if ($parserContract -and $clientContract -and $helperContract) {
            $script:guiQuotaModulesAvailable = $true
        }
        else {
            $script:guiQuotaInitializationFailureCode =
                'QUOTA_REQUIRED_COMMAND_MISSING'
        }
    }
}
$stateDirectory = Resolve-QiehaoProjectStateDirectory -GuiScriptRoot $guiRoot
$script:guiLanguage = 'zh-CN'

function Get-QiehaoGuiText {
    param(
        [Parameter(Mandatory = $true)][string]$Key,
        [string]$Fallback = ''
    )
    if ($script:guiLocalizationAvailable) {
        try {
            $localized = Get-QiehaoLocalizedString -Key $Key `
                -Language $script:guiLanguage
            if (-not $localized.StartsWith(
                '[Missing:', [StringComparison]::Ordinal
            )) { return $localized }
        }
        catch { }
    }
    if (-not [string]::IsNullOrWhiteSpace($Fallback)) { return $Fallback }
    return '[Missing:' + $Key + ']'
}

function Format-QiehaoGuiText {
    param(
        [Parameter(Mandatory = $true)][string]$Key,
        [AllowNull()][object[]]$Arguments = @(),
        [string]$Fallback = ''
    )
    if ($script:guiLocalizationAvailable) {
        try {
            $localized = Format-QiehaoLocalizedString -Key $Key `
                -Language $script:guiLanguage -Arguments $Arguments
            if (-not $localized.StartsWith(
                '[Missing:', [StringComparison]::Ordinal
            )) { return $localized }
        }
        catch { }
    }
    if (-not [string]::IsNullOrWhiteSpace($Fallback)) {
        try { return [string]::Format($Fallback, [object[]]$Arguments) }
        catch { return $Fallback }
    }
    return '[Missing:' + $Key + ']'
}

$script:guiQuotaFallbackStrings = [ordered]@{
    RefreshButton = '刷新额度'
    ColumnHeader = '额度快照'
    CacheUnavailable = '额度功能不可用，账号管理功能不受影响。'
    UpdateFailedRetry = '额度更新失败，可稍后点击“刷新额度”重试。'
    NoSnapshot = '额度不可用'
    InactiveTooltip = '额度功能当前不可用；账号管理功能不受影响。'
}

function Get-QiehaoQuotaUiTextSafe {
    param([Parameter(Mandatory = $true)][string]$Key)
    if ($script:guiQuotaModulesAvailable) {
        try {
            return Get-QiehaoQuotaUiText -Key $Key `
                -Language $script:guiLanguage
        }
        catch { }
    }
    if ($script:guiQuotaFallbackStrings.Contains($Key)) {
        return [string]$script:guiQuotaFallbackStrings[$Key]
    }
    return '额度不可用'
}

function Get-QiehaoSafeQuotaFailureCode {
    param(
        [AllowNull()][object]$Value,
        [string]$Fallback = 'QUOTA_BACKGROUND_WORKER_FAILED'
    )
    $candidate = if ($null -eq $Value) { '' } else { [string]$Value }
    $allowed = @(
        'QUOTA_CODEX_NOT_FOUND',
        'QUOTA_APP_SERVER_START_FAILED',
        'QUOTA_INITIALIZE_TIMEOUT',
        'QUOTA_INITIALIZE_ERROR',
        'QUOTA_RATE_LIMITS_TIMEOUT',
        'QUOTA_RATE_LIMITS_RPC_ERROR',
        'QUOTA_RESPONSE_INVALID',
        'QUOTA_PARSE_FAILED',
        'QUOTA_CHILD_CLEANUP_FAILED',
        'QUOTA_BACKGROUND_WORKER_FAILED',
        'QUOTA_RESULT_MISSING',
        'QUOTA_QUERY_FAILED',
        'QUOTA_CACHE_WRITE_FAILED',
        'OPERATION_BUSY'
    )
    if ($allowed -ccontains $candidate) { return $candidate }
    return $Fallback
}

function Format-QiehaoQuotaFailureStatus {
    param(
        [Parameter(Mandatory = $true)][string]$BaseText,
        [Parameter(Mandatory = $true)][string]$FailureCode
    )
    return ($BaseText + ' ' + (Format-QiehaoGuiText `
        -Key 'Quota.ErrorCode' `
        -Arguments @((Get-QiehaoSafeQuotaFailureCode -Value $FailureCode)) `
        -Fallback '错误代码：{0}'))
}

function Read-QiehaoMainWindow {
    $xamlText = [System.IO.File]::ReadAllText($xamlPath)
    $stringReader = $null
    $xmlReader = $null
    try {
        $stringReader = New-Object System.IO.StringReader($xamlText)
        $xmlReader = [System.Xml.XmlReader]::Create($stringReader)
        return [Windows.Markup.XamlReader]::Load($xmlReader)
    }
    finally {
        if ($null -ne $xmlReader) { $xmlReader.Dispose() }
        if ($null -ne $stringReader) { $stringReader.Dispose() }
        $xamlText = $null
    }
}

function Get-RequiredControl {
    param(
        [Parameter(Mandatory = $true)]
        [System.Windows.Window]$Window,
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $control = $Window.FindName($Name)
    if ($null -eq $control) { throw ('GUI_CONTROL_NOT_FOUND_' + $Name) }
    return $control
}

function Get-RequiredContextMenuItem {
    param(
        [Parameter(Mandatory = $true)]
        [System.Windows.Controls.ContextMenu]$ContextMenu,
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    foreach ($item in @($ContextMenu.Items)) {
        if ($item -is [System.Windows.Controls.MenuItem] -and
            [string]$item.Name -ceq $Name) { return $item }
    }
    throw ('GUI_CONTEXT_MENU_ITEM_NOT_FOUND_' + $Name)
}

$lease = $null
$window = $null
try {
    if (-not $SelfTest) {
        $lease = Enter-QiehaoGuiSingleInstance -MutexName $guiMutexName
        if (-not $lease.Acquired) {
            [void][System.Windows.MessageBox]::Show(
                'Codex 账号管理器已在运行。',
                'Codex 账号管理器',
                [System.Windows.MessageBoxButton]::OK,
                [System.Windows.MessageBoxImage]::Information
            )
            return
        }
    }

    $window = Read-QiehaoMainWindow
    $profilesGrid = Get-RequiredControl -Window $window -Name 'ProfilesGrid'
    $headerTitleText = Get-RequiredControl -Window $window -Name 'HeaderTitleText'
    $themeLabelText = Get-RequiredControl -Window $window -Name 'ThemeLabelText'
    $languageLabelText = Get-RequiredControl -Window $window -Name 'LanguageLabelText'
    $languageComboBox = Get-RequiredControl -Window $window -Name 'LanguageComboBox'
    $codexClientLabelText = Get-RequiredControl -Window $window -Name 'CodexClientLabelText'
    $currentAccountLabelText = Get-RequiredControl -Window $window -Name 'CurrentAccountLabelText'
    $currentIdentityLabelText = Get-RequiredControl -Window $window -Name 'CurrentIdentityLabelText'
    $webChatGPTLabelText = Get-RequiredControl -Window $window -Name 'WebChatGPTLabelText'
    $webChatGPTHintText = Get-RequiredControl -Window $window -Name 'WebChatGPTHintText'
    $savedAccountsHeadingText = Get-RequiredControl -Window $window -Name 'SavedAccountsHeadingText'
    $searchAccountsLabelText = Get-RequiredControl -Window $window -Name 'SearchAccountsLabelText'
    $browserSafetyFooterText = Get-RequiredControl -Window $window -Name 'BrowserSafetyFooterText'
    $profileColumn = Get-RequiredControl -Window $window -Name 'ProfileColumn'
    $currentColumn = Get-RequiredControl -Window $window -Name 'CurrentColumn'
    $verificationColumn = Get-RequiredControl -Window $window -Name 'VerificationColumn'
    $healthColumn = Get-RequiredControl -Window $window -Name 'HealthColumn'
    $authColumn = Get-RequiredControl -Window $window -Name 'AuthColumn'
    $identityColumn = Get-RequiredControl -Window $window -Name 'IdentityColumn'
    $metadataColumn = Get-RequiredControl -Window $window -Name 'MetadataColumn'
    $updatedColumn = Get-RequiredControl -Window $window -Name 'UpdatedColumn'
    $quotaColumn = Get-RequiredControl -Window $window -Name 'QuotaColumn'
    $profileSearchTextBox = Get-RequiredControl -Window $window -Name 'ProfileSearchTextBox'
    $profileCountText = Get-RequiredControl -Window $window -Name 'ProfileCountText'
    $codexStatusText = Get-RequiredControl -Window $window -Name 'CodexStatusText'
    $activeProfileText = Get-RequiredControl -Window $window -Name 'ActiveProfileText'
    $identityStatusText = Get-RequiredControl -Window $window -Name 'IdentityStatusText'
    $webChatGPTText = Get-RequiredControl -Window $window -Name 'WebChatGPTText'
    $refreshStatusText = Get-RequiredControl -Window $window -Name 'RefreshStatusText'
    $switchButton = Get-RequiredControl -Window $window -Name 'SwitchButton'
    $verifyButton = Get-RequiredControl -Window $window -Name 'VerifyButton'
    $refreshButton = Get-RequiredControl -Window $window -Name 'RefreshButton'
    $refreshQuotaButton = Get-RequiredControl -Window $window -Name 'RefreshQuotaButton'
    $refreshQuotaButton.Content = Get-QiehaoQuotaUiTextSafe -Key 'RefreshButton'
    $quotaColumn.Header = Get-QiehaoQuotaUiTextSafe -Key 'ColumnHeader'
    $addButton = Get-RequiredControl -Window $window -Name 'AddButton'
    $renameButton = Get-RequiredControl -Window $window -Name 'RenameButton'
    $deleteButton = Get-RequiredControl -Window $window -Name 'DeleteButton'
    $launchCodexButton = Get-RequiredControl -Window $window -Name 'LaunchCodexButton'
    $codexSafetyHintText = Get-RequiredControl -Window $window -Name 'CodexSafetyHintText'
    $launchSettingsButton = Get-RequiredControl -Window $window -Name 'LaunchSettingsButton'
    $launchTargetText = Get-RequiredControl -Window $window -Name 'LaunchTargetText'
    $themeComboBox = Get-RequiredControl -Window $window -Name 'ThemeComboBox'
    $backgroundImage = Get-RequiredControl -Window $window -Name 'BackgroundImage'
    $backgroundOverlay = Get-RequiredControl -Window $window -Name 'BackgroundOverlay'
    $profileContextMenu = $profilesGrid.ContextMenu
    if ($null -eq $profileContextMenu) { throw 'GUI_CONTEXT_MENU_NOT_FOUND' }
    $contextSwitchMenuItem = Get-RequiredContextMenuItem -ContextMenu $profileContextMenu -Name 'ContextSwitchMenuItem'
    $contextVerifyMenuItem = Get-RequiredContextMenuItem -ContextMenu $profileContextMenu -Name 'ContextVerifyMenuItem'
    $contextRenameMenuItem = Get-RequiredContextMenuItem -ContextMenu $profileContextMenu -Name 'ContextRenameMenuItem'
    $contextDeleteMenuItem = Get-RequiredContextMenuItem -ContextMenu $profileContextMenu -Name 'ContextDeleteMenuItem'

    $script:guiCurrentCodexStatus = '未知'
    $script:guiCurrentCodexState = 'Unknown'
    $script:guiCurrentActiveProfile = '未初始化'
    $script:guiActiveProfileKnown = $false
    $script:guiCurrentIdentityState = 'Unavailable'
    $script:guiCurrentStatusKey = 'Status.Ready'
    $script:guiCurrentStatusArguments = @()
    $script:guiLanguagePersistenceReady = $false
    $script:guiIsWriteOperationBusy = $false
    $script:guiManualSwitchWaitInProgress = $false
    $script:guiManualSwitchWaitTimer = $null
    $script:guiManualSwitchWaitTimerTickHandler = $null
    $script:guiManualSwitchWaitRuntime = $null
    $script:guiLaunchTimer = $null
    $script:guiLaunchTimerTickHandler = $null
    $script:guiLaunchWaitRuntime = $null
    $script:guiProcessTimer = $null
    $script:guiProcessTimerTickHandler = $null
    $script:guiPendingAction = $null
    $script:guiPendingTargetProfile = $null
    $script:guiManualSwitchWaitDialog = $null
    $script:guiManualSwitchWaitStatusText = $null
    $script:guiManualSwitchWaitCancelButton = $null
    $script:guiManualSwitchWaitOutcome = 'Idle'
    $script:guiManualSwitchCodexStopped = $false
    $script:guiManualSwitchResult = $null
    $script:guiManualSwitchPresentation = $null
    $script:guiSwitchUiState = 'Idle'
    $script:guiManualSwitchWaitInternalClose = $false
    $script:guiLaunchTarget = $null
    $script:guiLaunchSettings = $null
    $script:guiAllProfileRows = @()
    $script:guiVerificationStates = @{}
    $script:guiVerificationStateCodes = @{}
    $script:guiIsClosing = $false
    $script:guiThemePersistenceReady = $false
    $script:guiQuotaCacheRead = if (-not $script:guiQuotaModulesAvailable) {
        [pscustomobject]@{
            Cache = $null
            IsValid = $false
            UsedEmpty = $true
            ErrorCode = 'QUOTA_MODULE_UNAVAILABLE'
        }
    }
    elseif ($SelfTest) {
        [pscustomobject]@{
            Cache = New-QiehaoEmptyQuotaCache
            IsValid = $true
            UsedEmpty = $true
            ErrorCode = $null
        }
    }
    else {
        try {
            Read-QiehaoQuotaCache -StateDirectory $stateDirectory
        }
        catch {
            $script:guiQuotaModulesAvailable = $false
            $script:guiQuotaInitializationFailureCode =
                'QUOTA_RUNTIME_INIT_FAILED'
            [pscustomobject]@{
                Cache = $null
                IsValid = $false
                UsedEmpty = $true
                ErrorCode = 'QUOTA_CACHE_LOAD_FAILED'
            }
        }
    }
    $script:guiQuotaCache = $script:guiQuotaCacheRead.Cache
    $script:guiQuotaCoordinator = $null
    if ($script:guiQuotaModulesAvailable) {
        try {
            $script:guiQuotaCoordinator = New-QiehaoQuotaCoordinatorState
        }
        catch {
            $script:guiQuotaModulesAvailable = $false
            $script:guiQuotaInitializationFailureCode =
                'QUOTA_RUNTIME_INIT_FAILED'
        }
    }
    if ($null -eq $script:guiQuotaCoordinator) {
        $script:guiQuotaCache = $null
        $script:guiQuotaCoordinator = [pscustomobject]@{
            StartupAttempted = $false
            QueryInProgress = $false
        }
    }
    $script:guiQuotaJustUpdatedProfile = $null
    $script:guiQuotaAsyncPowerShell = $null
    $script:guiQuotaAsyncResult = $null
    $script:guiQuotaCompletionTimer = $null
    $script:guiQuotaCompletionTickHandler = $null
    $script:guiQuotaRequestedProfile = $null
    $script:guiQuotaAsyncReason = $null
    $script:guiQuotaStartedUtc = $null
    $script:guiQuotaDeadlineUtc = $null
    $script:guiQuotaSlowStatusShown = $false
    $script:guiQuotaLastQueryFailed = $false
    $script:guiQuotaLastFailureCode = $null
    $script:guiQuotaLastDiagnostics = $null
    $script:guiQuotaWorkerOutputCount = 0
    $script:guiQuotaCompletionTimerStopped = $false
    $script:guiQuotaCompletionHandlerRemoved = $false
    $script:guiQuotaEndInvokeAttempted = $false
    $script:guiQuotaSelfTestScenario = $null
    $script:guiQuotaSelfTestQueryCount = 0
    $script:guiQuotaSelfTestHardCeilingMilliseconds = 0

    function Set-QiehaoSwitchQuotaStatus {
        param(
            [Parameter(Mandatory = $true)][string]$Text,
            [ValidateSet('Warning', 'Success')][string]$Tone = 'Warning'
        )
        $refreshStatusText.Text = $Text
        if ($null -ne $script:guiManualSwitchWaitStatusText) {
            $script:guiManualSwitchWaitStatusText.Text = $Text
            $brushKey = if ($Tone -ceq 'Success') {
                'DialogSuccessBrush'
            }
            else { 'DialogWarningBrush' }
            $script:guiManualSwitchWaitStatusText.Foreground =
                $window.Resources[$brushKey]
        }
    }

    function Set-QiehaoLocalizedStatus {
        param(
            [Parameter(Mandatory = $true)][string]$Key,
            [AllowNull()][object[]]$Arguments = @(),
            [string]$Fallback = ''
        )
        $script:guiCurrentStatusKey = $Key
        $script:guiCurrentStatusArguments = @($Arguments)
        $refreshStatusText.Text = Format-QiehaoGuiText -Key $Key `
            -Arguments $Arguments -Fallback $Fallback
    }

    function Update-QiehaoLocalizedProfileRows {
        foreach ($row in @($script:guiAllProfileRows)) {
            if ($null -eq $row) { continue }
            $activeKey = switch ([string]$row.ActiveCode) {
                'Yes' { 'Profile.Active.Yes' }
                'No' { 'Profile.Active.No' }
                default { 'Profile.Active.Unknown' }
            }
            $verificationKey = switch ([string]$row.VerificationCode) {
                'Verified' { 'Profile.Verification.Verified' }
                'Failed' { 'Profile.Verification.Failed' }
                default { 'Profile.Verification.Unverified' }
            }
            $healthKey = switch ([string]$row.HealthCode) {
                'READY' { 'Profile.Health.Ready' }
                'INCOMPLETE_PROFILE' { 'Profile.Health.Incomplete' }
                'INVALID_METADATA' { 'Profile.Health.InvalidMetadata' }
                default { 'Profile.Health.Unknown' }
            }
            $authKey = switch ([string]$row.AuthCode) {
                'PRESENT' { 'Profile.Artifact.Present' }
                'MISSING' { 'Profile.Artifact.Missing' }
                default { 'Profile.Artifact.Unknown' }
            }
            $identityKey = switch ([string]$row.IdentityCode) {
                'PRESENT' { 'Profile.Artifact.Present' }
                'MISSING' { 'Profile.Artifact.Missing' }
                default { 'Profile.Artifact.Unknown' }
            }
            $metadataKey = switch ([string]$row.MetadataCode) {
                'VALID' { 'Profile.Metadata.Valid' }
                'MISSING' { 'Profile.Metadata.Missing' }
                'INVALID' { 'Profile.Metadata.Invalid' }
                default { 'Profile.Metadata.Unknown' }
            }
            $row.Active = Get-QiehaoGuiText -Key $activeKey
            $row.Verification = Get-QiehaoGuiText -Key $verificationKey
            $row.Health = Get-QiehaoGuiText -Key $healthKey
            $row.Auth = Get-QiehaoGuiText -Key $authKey
            $row.Identity = Get-QiehaoGuiText -Key $identityKey
            $row.Metadata = Get-QiehaoGuiText -Key $metadataKey
            if ([string]$row.UpdatedCode -ceq 'Unavailable') {
                $row.Updated = Get-QiehaoGuiText `
                    -Key 'Profile.Updated.Unavailable'
            }
            elseif ([string]$row.UpdatedCode -ceq 'InvalidMetadata') {
                $row.Updated = Get-QiehaoGuiText `
                    -Key 'Profile.Updated.InvalidMetadata'
            }
        }
    }

    function Get-QiehaoLocalizedLaunchStatus {
        if ($null -eq $script:guiLaunchTarget) {
            return Get-QiehaoGuiText -Key 'Launch.Status.NotFound'
        }
        $key = switch ([string]$script:guiLaunchTarget.DisplayStatus) {
            '已自动检测' { 'Launch.Status.AutoDetected' }
            '已使用自定义文件' { 'Launch.Status.Custom' }
            '自定义路径无效' { 'Launch.Status.InvalidCustom' }
            default { 'Launch.Status.NotFound' }
        }
        return Get-QiehaoGuiText -Key $key
    }

    function Apply-QiehaoLocalization {
        if (-not $script:guiLocalizationAvailable) { return }
        $window.Title = Get-QiehaoGuiText -Key 'App.Title'
        $headerTitleText.Text = Get-QiehaoGuiText -Key 'App.Title'
        $themeLabelText.Text = Get-QiehaoGuiText -Key 'Theme.Label'
        $languageLabelText.Text = Get-QiehaoGuiText -Key 'Language.Label'
        $codexClientLabelText.Text = Get-QiehaoGuiText -Key 'Section.CodexClient'
        $currentAccountLabelText.Text = Get-QiehaoGuiText -Key 'Section.CurrentAccount'
        $currentIdentityLabelText.Text = Get-QiehaoGuiText -Key 'Section.CurrentIdentity'
        $webChatGPTLabelText.Text = Get-QiehaoGuiText -Key 'Section.WebChatGPT'
        $webChatGPTText.Text = Get-QiehaoGuiText -Key 'WebChatGPT.Unchanged'
        $webChatGPTHintText.Text = Get-QiehaoGuiText -Key 'WebChatGPT.Hint'
        $savedAccountsHeadingText.Text = Get-QiehaoGuiText -Key 'Section.SavedAccounts'
        $searchAccountsLabelText.Text = Get-QiehaoGuiText -Key 'Search.Label'
        $profileSearchTextBox.ToolTip = Get-QiehaoGuiText -Key 'Search.ToolTip'
        $browserSafetyFooterText.Text = Get-QiehaoGuiText -Key 'Footer.BrowserSafe'
        $profileColumn.Header = Get-QiehaoGuiText -Key 'Column.Profile'
        $currentColumn.Header = Get-QiehaoGuiText -Key 'Column.Current'
        $verificationColumn.Header = Get-QiehaoGuiText -Key 'Column.Verification'
        $healthColumn.Header = Get-QiehaoGuiText -Key 'Column.Status'
        $authColumn.Header = Get-QiehaoGuiText -Key 'Column.Auth'
        $identityColumn.Header = Get-QiehaoGuiText -Key 'Column.Identity'
        $metadataColumn.Header = Get-QiehaoGuiText -Key 'Column.Metadata'
        $updatedColumn.Header = Get-QiehaoGuiText -Key 'Column.Updated'
        $quotaColumn.Header = Get-QiehaoGuiText -Key 'Column.QuotaSnapshot'
        $switchButton.Content = Get-QiehaoGuiText -Key 'Button.Switch'
        $verifyButton.Content = Get-QiehaoGuiText -Key 'Button.Verify'
        $refreshButton.Content = Get-QiehaoGuiText -Key 'Button.Refresh'
        $refreshQuotaButton.Content = Get-QiehaoGuiText -Key 'Button.RefreshQuota'
        $addButton.Content = Get-QiehaoGuiText -Key 'Button.Add'
        $renameButton.Content = Get-QiehaoGuiText -Key 'Button.Rename'
        $deleteButton.Content = Get-QiehaoGuiText -Key 'Button.Delete'
        $launchCodexButton.Content = Get-QiehaoGuiText -Key 'Button.LaunchCodex'
        $launchSettingsButton.Content = Get-QiehaoGuiText -Key 'Button.LaunchSettings'
        $contextSwitchMenuItem.Header = Get-QiehaoGuiText -Key 'Context.Switch'
        $contextVerifyMenuItem.Header = Get-QiehaoGuiText -Key 'Context.Verify'
        $contextRenameMenuItem.Header = Get-QiehaoGuiText -Key 'Context.Rename'
        $contextDeleteMenuItem.Header = Get-QiehaoGuiText -Key 'Context.Delete'
        foreach ($theme in @($themeComboBox.ItemsSource)) {
            if ($null -ne $theme) {
                $theme.Name = Get-QiehaoLocalizedThemeName `
                    -ThemeId ([string]$theme.Id) -Language $script:guiLanguage
            }
        }
        $themeComboBox.Items.Refresh()
        $codexStatusText.Text = Get-QiehaoGuiText -Key (
            'Status.Codex.' + $script:guiCurrentCodexState
        )
        $activeProfileText.Text = if ($script:guiActiveProfileKnown) {
            [string]$script:guiCurrentActiveProfile
        }
        else { Get-QiehaoGuiText -Key 'Status.Active.Uninitialized' }
        $identityStatusText.Text = Get-QiehaoGuiText -Key (
            'Status.Identity.' + $script:guiCurrentIdentityState
        )
        Update-QiehaoLocalizedProfileRows
        if ($script:guiQuotaModulesAvailable) {
            $rows = @(Update-QiehaoQuotaProfileRows `
                -Rows $script:guiAllProfileRows `
                -Cache $script:guiQuotaCache `
                -ActiveProfile $script:guiCurrentActiveProfile `
                -JustUpdatedProfile $script:guiQuotaJustUpdatedProfile `
                -Language $script:guiLanguage)
            $script:guiAllProfileRows = $rows
        }
        if ($null -ne $script:guiLaunchTarget) {
            $launchTargetText.Text = Format-QiehaoGuiText `
                -Key 'Launch.Target' `
                -Arguments @((Get-QiehaoLocalizedLaunchStatus))
        }
        if ([bool]$script:guiQuotaCoordinator.QueryInProgress) {
            $refreshStatusText.Text = Get-QiehaoGuiText -Key 'Quota.Updating'
        }
        elseif (-not [string]::IsNullOrWhiteSpace(
            [string]$script:guiCurrentStatusKey
        )) {
            $refreshStatusText.Text = Format-QiehaoGuiText `
                -Key $script:guiCurrentStatusKey `
                -Arguments $script:guiCurrentStatusArguments
        }
        Update-QiehaoCodexSafetyHint
        Update-QiehaoProfileFilter
    }

    function Set-QiehaoQuotaUnavailableRows {
        param(
            [AllowNull()]
            [AllowEmptyCollection()]
            [object[]]$Rows
        )
        foreach ($row in @($Rows)) {
            if ($null -eq $row) { continue }
            Add-Member -InputObject $row -NotePropertyName QuotaSummary -NotePropertyValue (Get-QiehaoQuotaUiTextSafe -Key 'NoSnapshot') -Force
            Add-Member -InputObject $row -NotePropertyName QuotaFreshness -NotePropertyValue '' -Force
            Add-Member -InputObject $row -NotePropertyName QuotaAvailability -NotePropertyValue '' -Force
            Add-Member -InputObject $row -NotePropertyName QuotaToolTip -NotePropertyValue (Get-QiehaoQuotaUiTextSafe -Key 'InactiveTooltip') -Force
            Add-Member -InputObject $row -NotePropertyName QuotaIsActive -NotePropertyValue $false -Force
        }
    }

    function Disable-QiehaoQuotaFeature {
        param(
            [ValidateSet(
                'QUOTA_PARSER_IMPORT_FAILED',
                'QUOTA_CLIENT_IMPORT_FAILED',
                'QUOTA_HELPERS_IMPORT_FAILED',
                'QUOTA_REQUIRED_COMMAND_MISSING',
                'QUOTA_RUNTIME_INIT_FAILED'
            )]
            [string]$FailureCode = 'QUOTA_RUNTIME_INIT_FAILED'
        )
        $script:guiQuotaModulesAvailable = $false
        if ($null -eq $script:guiQuotaInitializationFailureCode) {
            $script:guiQuotaInitializationFailureCode = $FailureCode
        }
        $script:guiQuotaCoordinator.QueryInProgress = $false
        $refreshQuotaButton.IsEnabled = $false
    }

    function Get-QiehaoSelectedProfileName {
        if ($null -eq $profilesGrid.SelectedItem) { return $null }
        return [string]$profilesGrid.SelectedItem.Name
    }

    function Update-QiehaoActionButtons {
        $state = Get-QiehaoActionState `
            -SelectedProfile (Get-QiehaoSelectedProfileName) `
            -ActiveProfile $script:guiCurrentActiveProfile `
            -CodexStatus $script:guiCurrentCodexStatus `
            -IsWriteOperationBusy:$script:guiIsWriteOperationBusy `
            -LaunchTargetAvailable:($null -ne $script:guiLaunchTarget -and
                [bool]$script:guiLaunchTarget.Available)
        $refreshButton.IsEnabled = [bool]$state.Refresh
        $refreshQuotaButton.IsEnabled = (
            $script:guiQuotaModulesAvailable -and
            -not $script:guiIsClosing -and
            -not $script:guiIsWriteOperationBusy -and
            -not [bool]$script:guiQuotaCoordinator.QueryInProgress -and
            -not [string]::IsNullOrWhiteSpace(
                [string]$script:guiCurrentActiveProfile
            ) -and
            [string]$script:guiCurrentActiveProfile -cne '未初始化'
        )
        $switchButton.IsEnabled = [bool]$state.Switch
        $verifyButton.IsEnabled = [bool]$state.Verify
        $addButton.IsEnabled = [bool]$state.Add
        $renameButton.IsEnabled = [bool]$state.Rename
        $deleteButton.IsEnabled = [bool]$state.Delete
        $launchCodexButton.IsEnabled = [bool]$state.LaunchCodex
        $contextSwitchMenuItem.IsEnabled = [bool]$state.ContextSwitch
        $contextVerifyMenuItem.IsEnabled = [bool]$state.ContextVerify
        $contextRenameMenuItem.IsEnabled = [bool]$state.ContextRename
        $contextDeleteMenuItem.IsEnabled = [bool]$state.ContextDelete
        Update-QiehaoCodexSafetyHint
    }

    function Set-QiehaoWriteBusy {
        param(
            [Parameter(Mandatory = $true)]
            [bool]$Value,
            [string]$StatusText = ''
        )
        $script:guiIsWriteOperationBusy = $Value
        if (-not [string]::IsNullOrWhiteSpace($StatusText)) {
            $refreshStatusText.Text = $StatusText
        }
        Update-QiehaoActionButtons
    }

    function Show-QiehaoSafeMessage {
        param(
            [Parameter(Mandatory = $true)]
            [string]$Message,
            [ValidateSet('Information', 'Warning', 'Critical')]
            [string]$Severity = 'Information'
        )
        $icon = [System.Windows.MessageBoxImage]::Information
        $title = Get-QiehaoGuiText -Key 'App.Title' `
            -Fallback 'Codex 账号管理器'
        if ($Severity -ceq 'Warning') {
            $icon = [System.Windows.MessageBoxImage]::Warning
        }
        elseif ($Severity -ceq 'Critical') {
            $icon = [System.Windows.MessageBoxImage]::Error
            $title = Get-QiehaoGuiText -Key 'App.CriticalTitle' `
                -Fallback '严重安全错误 - Codex 账号管理器'
        }
        [void][System.Windows.MessageBox]::Show(
            $window, $Message, $title,
            [System.Windows.MessageBoxButton]::OK, $icon
        )
    }

    function Show-QiehaoOperationResult {
        param([Parameter(Mandatory = $true)][object]$Result)
        if (-not [string]::IsNullOrWhiteSpace([string]$Result.Message)) {
            $message = Get-QiehaoGuiText `
                -Key ('Operation.' + [string]$Result.ResultCode) `
                -Fallback ([string]$Result.Message)
            Show-QiehaoSafeMessage -Message $message `
                -Severity ([string]$Result.Severity)
        }
    }

    function Show-QiehaoChoiceDialog {
        param(
            [Parameter(Mandatory = $true)][string]$Title,
            [Parameter(Mandatory = $true)][string]$Message,
            [Parameter(Mandatory = $true)][string]$ConfirmText,
            [string]$CancelText = ''
        )
        if ([string]::IsNullOrWhiteSpace($CancelText)) {
            $CancelText = Get-QiehaoGuiText -Key 'Button.Cancel' `
                -Fallback '取消'
        }
        $dialog = New-Object System.Windows.Window
        $dialog.Title = $Title
        $dialog.Width = 500
        $dialog.Height = 230
        $dialog.MinWidth = 420
        $dialog.MinHeight = 200
        $dialog.WindowStartupLocation = 'CenterOwner'
        $dialog.ResizeMode = 'NoResize'
        $dialog.ShowInTaskbar = $false
        $dialog.Owner = $window
        $dialog.FontFamily = $window.FontFamily
        $dialog.FontSize = $window.FontSize
        $root = New-Object System.Windows.Controls.Grid
        $root.Margin = 18
        $root.RowDefinitions.Add((New-Object System.Windows.Controls.RowDefinition))
        $buttonRow = New-Object System.Windows.Controls.RowDefinition
        $buttonRow.Height = 'Auto'
        $root.RowDefinitions.Add($buttonRow)
        $messageText = New-Object System.Windows.Controls.TextBlock
        $messageText.Text = $Message
        $messageText.TextWrapping = 'Wrap'
        $messageText.VerticalAlignment = 'Center'
        [System.Windows.Controls.Grid]::SetRow($messageText, 0)
        $root.Children.Add($messageText) | Out-Null
        $buttons = New-Object System.Windows.Controls.StackPanel
        $buttons.Orientation = 'Horizontal'
        $buttons.HorizontalAlignment = 'Right'
        $buttons.Margin = '0,18,0,0'
        [System.Windows.Controls.Grid]::SetRow($buttons, 1)
        $confirmButton = New-Object System.Windows.Controls.Button
        $confirmButton.Content = $ConfirmText
        $confirmButton.MinWidth = 130
        $confirmButton.MinHeight = 34
        $confirmButton.Margin = '0,0,8,0'
        $confirmButton.IsDefault = $true
        $cancelButton = New-Object System.Windows.Controls.Button
        $cancelButton.Content = $CancelText
        $cancelButton.MinWidth = 90
        $cancelButton.MinHeight = 34
        $cancelButton.IsCancel = $true
        $confirmButton.Add_Click({ $dialog.Tag = $true; $dialog.DialogResult = $true })
        $cancelButton.Add_Click({ $dialog.Tag = $false; $dialog.DialogResult = $false })
        $buttons.Children.Add($confirmButton) | Out-Null
        $buttons.Children.Add($cancelButton) | Out-Null
        $root.Children.Add($buttons) | Out-Null
        $dialog.Tag = $false
        $dialog.Content = $root
        $null = $dialog.ShowDialog()
        return [bool]$dialog.Tag
    }

    function Show-QiehaoNameDialog {
        param(
            [Parameter(Mandatory = $true)][string]$Title,
            [Parameter(Mandatory = $true)][string]$Prompt,
            [string]$CurrentName = ''
        )
        $dialog = New-Object System.Windows.Window
        $dialog.Title = $Title
        $dialog.Width = 440
        $dialog.Height = 240
        $dialog.WindowStartupLocation = 'CenterOwner'
        $dialog.ResizeMode = 'NoResize'
        $dialog.ShowInTaskbar = $false
        $dialog.Owner = $window
        $dialog.FontFamily = $window.FontFamily
        $dialog.FontSize = $window.FontSize
        $root = New-Object System.Windows.Controls.Grid
        $root.Margin = 18
        foreach ($height in @('Auto', 'Auto', 'Auto', '*', 'Auto')) {
            $row = New-Object System.Windows.Controls.RowDefinition
            $row.Height = $height
            $root.RowDefinitions.Add($row)
        }
        if (-not [string]::IsNullOrWhiteSpace($CurrentName)) {
            $currentText = New-Object System.Windows.Controls.TextBlock
            $currentText.Text = Format-QiehaoGuiText `
                -Key 'Dialog.Name.Current' -Arguments @($CurrentName) `
                -Fallback '当前名称：{0}'
            $currentText.Margin = '0,0,0,12'
            [System.Windows.Controls.Grid]::SetRow($currentText, 0)
            $root.Children.Add($currentText) | Out-Null
        }
        $promptText = New-Object System.Windows.Controls.TextBlock
        $promptText.Text = $Prompt
        [System.Windows.Controls.Grid]::SetRow($promptText, 1)
        $root.Children.Add($promptText) | Out-Null
        $nameBox = New-Object System.Windows.Controls.TextBox
        $nameBox.MaxLength = 64
        $nameBox.MinHeight = 32
        $nameBox.Margin = '0,6,0,0'
        $nameBox.Padding = '7,4'
        [System.Windows.Controls.Grid]::SetRow($nameBox, 2)
        $root.Children.Add($nameBox) | Out-Null
        $buttons = New-Object System.Windows.Controls.StackPanel
        $buttons.Orientation = 'Horizontal'
        $buttons.HorizontalAlignment = 'Right'
        $buttons.Margin = '0,18,0,0'
        [System.Windows.Controls.Grid]::SetRow($buttons, 4)
        $okButton = New-Object System.Windows.Controls.Button
        $okButton.Content = Get-QiehaoGuiText -Key 'Button.Confirm' `
            -Fallback '确定'
        $okButton.MinWidth = 90
        $okButton.MinHeight = 34
        $okButton.Margin = '0,0,8,0'
        $okButton.IsDefault = $true
        $cancelButton = New-Object System.Windows.Controls.Button
        $cancelButton.Content = Get-QiehaoGuiText -Key 'Button.Cancel' `
            -Fallback '取消'
        $cancelButton.MinWidth = 90
        $cancelButton.MinHeight = 34
        $cancelButton.IsCancel = $true
        $okButton.Add_Click({
            $candidate = ([string]$nameBox.Text).Trim()
            if ([string]::IsNullOrWhiteSpace($candidate)) {
                [void][System.Windows.MessageBox]::Show(
                    $dialog, (Get-QiehaoGuiText -Key 'Dialog.Name.Empty' `
                        -Fallback '名称不能为空。'),
                    (Get-QiehaoGuiText -Key 'App.Title' `
                        -Fallback 'Codex 账号管理器'),
                    [System.Windows.MessageBoxButton]::OK,
                    [System.Windows.MessageBoxImage]::Warning
                )
                return
            }
            $dialog.Tag = $candidate
            $dialog.DialogResult = $true
        })
        $cancelButton.Add_Click({ $dialog.DialogResult = $false })
        $buttons.Children.Add($okButton) | Out-Null
        $buttons.Children.Add($cancelButton) | Out-Null
        $root.Children.Add($buttons) | Out-Null
        $dialog.Content = $root
        $result = $dialog.ShowDialog()
        if ($result -eq $true) { return [string]$dialog.Tag }
        return $null
    }

    function New-QiehaoSolidBrush {
        param([Parameter(Mandatory = $true)][string]$Color)
        $brush = New-Object System.Windows.Media.SolidColorBrush
        $brush.Color = [System.Windows.Media.ColorConverter]::ConvertFromString($Color)
        if ($brush.CanFreeze) { $brush.Freeze() }
        return $brush
    }

    function New-QiehaoGradientBrush {
        param(
            [Parameter(Mandatory = $true)][string]$Top,
            [Parameter(Mandatory = $true)][string]$Bottom
        )
        $brush = New-Object System.Windows.Media.LinearGradientBrush
        $brush.StartPoint = New-Object System.Windows.Point(0, 0)
        $brush.EndPoint = New-Object System.Windows.Point(0, 1)
        $brush.GradientStops.Add((New-Object System.Windows.Media.GradientStop(
            ([System.Windows.Media.ColorConverter]::ConvertFromString($Top)), 0
        )))
        $brush.GradientStops.Add((New-Object System.Windows.Media.GradientStop(
            ([System.Windows.Media.ColorConverter]::ConvertFromString($Bottom)), 1
        )))
        if ($brush.CanFreeze) { $brush.Freeze() }
        return $brush
    }

    function Set-QiehaoThemeResources {
        param([Parameter(Mandatory = $true)][object]$Theme)
        $dialogPalette = Get-QiehaoSwitchDialogPalette -Theme $Theme
        $values = [ordered]@{
            PanelBrush = New-QiehaoGradientBrush -Top ([string]$Theme.CardTop) `
                -Bottom ([string]$Theme.CardBottom)
            PanelBorderBrush = New-QiehaoSolidBrush -Color ([string]$Theme.BorderTint)
            TextPrimaryBrush = New-QiehaoSolidBrush -Color ([string]$Theme.TextPrimary)
            TextSecondaryBrush = New-QiehaoSolidBrush -Color ([string]$Theme.TextSecondary)
            ButtonFaceBrush = New-QiehaoGradientBrush -Top ([string]$Theme.ButtonTop) `
                -Bottom ([string]$Theme.ButtonBottom)
            ButtonHoverBrush = New-QiehaoSolidBrush -Color ([string]$Theme.ButtonHover)
            ButtonPressedBrush = New-QiehaoSolidBrush -Color ([string]$Theme.ButtonPressed)
            DangerButtonBrush = New-QiehaoGradientBrush -Top ([string]$Theme.DangerTop) `
                -Bottom ([string]$Theme.DangerBottom)
            ActiveRowBrush = New-QiehaoSolidBrush -Color ([string]$Theme.ActiveRowTint)
            ActiveSelectedRowBrush = New-QiehaoSolidBrush `
                -Color ([string]$Theme.ActiveSelectedRowTint)
            SelectedRowBrush = New-QiehaoSolidBrush -Color ([string]$Theme.SelectedRowTint)
            ActiveBorderBrush = New-QiehaoSolidBrush -Color ([string]$Theme.ActiveBorderTint)
            RunningWarningBrush = New-QiehaoSolidBrush `
                -Color ([string]$Theme.RunningWarningTint)
            UnknownWarningBrush = New-QiehaoSolidBrush `
                -Color ([string]$Theme.UnknownWarningTint)
            ColumnHeaderBackgroundBrush = New-QiehaoSolidBrush `
                -Color ([string]$Theme.ColumnHeaderBackgroundTint)
            ColumnHeaderForegroundBrush = New-QiehaoSolidBrush `
                -Color ([string]$Theme.ColumnHeaderForegroundTint)
            ColumnHeaderBorderBrush = New-QiehaoSolidBrush `
                -Color ([string]$Theme.ColumnHeaderBorderTint)
            CurrentYesBrush = New-QiehaoSolidBrush `
                -Color ([string]$Theme.CurrentYesTint)
            CurrentNoBrush = New-QiehaoSolidBrush `
                -Color ([string]$Theme.CurrentNoTint)
            AccentBrush = New-QiehaoSolidBrush -Color ([string]$Theme.AccentTint)
            DialogBackgroundBrush = New-QiehaoSolidBrush `
                -Color ([string]$dialogPalette.Background)
            DialogCardBrush = New-QiehaoGradientBrush `
                -Top ([string]$dialogPalette.CardTop) `
                -Bottom ([string]$dialogPalette.CardBottom)
            DialogBorderBrush = New-QiehaoSolidBrush `
                -Color ([string]$dialogPalette.Border)
            DialogForegroundBrush = New-QiehaoSolidBrush `
                -Color ([string]$dialogPalette.Foreground)
            DialogSecondaryBrush = New-QiehaoSolidBrush `
                -Color ([string]$dialogPalette.Secondary)
            DialogAccentBrush = New-QiehaoSolidBrush `
                -Color ([string]$dialogPalette.Accent)
            DialogWarningBrush = New-QiehaoSolidBrush `
                -Color ([string]$dialogPalette.Warning)
            DialogSuccessBrush = New-QiehaoSolidBrush `
                -Color ([string]$dialogPalette.Success)
            DialogButtonBackgroundBrush = New-QiehaoSolidBrush `
                -Color ([string]$dialogPalette.ButtonBackground)
            DialogButtonForegroundBrush = New-QiehaoSolidBrush `
                -Color ([string]$dialogPalette.ButtonForeground)
            DialogButtonBorderBrush = New-QiehaoSolidBrush `
                -Color ([string]$dialogPalette.ButtonBorder)
            ButtonDisabledBrush = New-QiehaoSolidBrush -Color $(
                if ([string]$Theme.OverlayMode -ceq 'Dark') { '#705B6472' }
                else { '#70AAB5BE' }
            )
            GridBackgroundBrush = New-QiehaoSolidBrush -Color $(
                if ([string]$Theme.OverlayMode -ceq 'Dark') { '#3AFFFFFF' }
                else { '#68FFFFFF' }
            )
            GridRowBrush = New-QiehaoSolidBrush -Color $(
                if ([string]$Theme.OverlayMode -ceq 'Dark') { '#25FFFFFF' }
                else { '#50FFFFFF' }
            )
            GridAltRowBrush = New-QiehaoSolidBrush -Color $(
                if ([string]$Theme.OverlayMode -ceq 'Dark') { '#16FFFFFF' }
                else { '#36FFFFFF' }
            )
        }
        foreach ($entry in $values.GetEnumerator()) {
            $window.Resources[[string]$entry.Key] = $entry.Value.PSObject.BaseObject
        }
        $window.Background = $values.PanelBrush.PSObject.BaseObject
        $window.Foreground = $values.TextPrimaryBrush.PSObject.BaseObject
    }

    function Set-QiehaoTheme {
        param(
            [Parameter(Mandatory = $true)][object]$Theme,
            [switch]$Persist
        )
        $imageResult = Get-QiehaoBackgroundImage -Theme $Theme `
            -BackgroundDirectory $backgroundDirectory
        Set-QiehaoThemeResources -Theme $Theme
        if ($imageResult.Loaded) { $backgroundImage.Source = $imageResult.ImageSource }
        else { $backgroundImage.Source = $null }
        $overlayBrush = New-QiehaoSolidBrush -Color ([string]$Theme.OverlayColor)
        $backgroundOverlay.Background = $overlayBrush.PSObject.BaseObject
        if ($Persist) {
            try {
                $null = Write-QiehaoUiPreferences -StateDirectory $stateDirectory `
                    -Background $Theme.Id
                $refreshStatusText.Text = if ($imageResult.Loaded) {
                    Get-QiehaoGuiText -Key 'Theme.Saved' `
                        -Fallback '皮肤已切换并保存'
                }
                else {
                    Get-QiehaoGuiText -Key 'Theme.SavedWithFallback' `
                        -Fallback '背景图片不可用，已使用默认纯色并保存选择'
                }
            }
            catch {
                $refreshStatusText.Text = Get-QiehaoGuiText `
                    -Key 'Theme.SaveFailed' `
                    -Fallback '皮肤已切换，但偏好保存失败'
            }
        }
        return $imageResult
    }

    function Update-QiehaoProfileFilter {
        $selectedName = Get-QiehaoSelectedProfileName
        $filteredRows = @(Select-QiehaoProfileRows -Rows $script:guiAllProfileRows `
            -SearchText $profileSearchTextBox.Text)
        $profilesGrid.ItemsSource = $filteredRows
        $profilesGrid.SelectedItem = $null
        if (-not [string]::IsNullOrWhiteSpace($selectedName)) {
            $matching = @($filteredRows | Where-Object {
                ([string]$_.Name).Equals($selectedName, [StringComparison]::OrdinalIgnoreCase)
            } | Select-Object -First 1)
            if ($matching.Count -eq 1) { $profilesGrid.SelectedItem = $matching[0] }
        }
        if ($filteredRows.Count -eq $script:guiAllProfileRows.Count) {
            $profileCountText.Text = Format-QiehaoGuiText `
                -Key 'Profile.Count' -Arguments @($filteredRows.Count) `
                -Fallback '{0} 个账号'
        }
        else {
            $profileCountText.Text = Format-QiehaoGuiText `
                -Key 'Profile.FilteredCount' `
                -Arguments @($filteredRows.Count, $script:guiAllProfileRows.Count) `
                -Fallback '{0} / {1} 个账号'
        }
        Update-QiehaoActionButtons
    }

    function Set-QiehaoSnapshot {
        param([Parameter(Mandatory = $true)][object]$Snapshot)
        $rows = @($Snapshot.Profiles)
        foreach ($row in $rows) {
            if ($script:guiVerificationStates.ContainsKey([string]$row.Name)) {
                $row.Verification = [string]$script:guiVerificationStates[[string]$row.Name]
            }
            if ($script:guiVerificationStateCodes.ContainsKey([string]$row.Name)) {
                $row.VerificationCode = [string](
                    $script:guiVerificationStateCodes[[string]$row.Name]
                )
            }
        }
        # Establish core state before optional quota enrichment. Quota failures
        # must never replace the profile population or core status fields.
        $script:guiAllProfileRows = @($rows)
        $script:guiCurrentCodexStatus = [string]$Snapshot.CodexDesktop
        $script:guiCurrentCodexState = [string]$Snapshot.CodexState
        $script:guiCurrentActiveProfile = [string]$Snapshot.ActiveProfile
        $script:guiActiveProfileKnown = [bool]$Snapshot.ActiveProfileKnown
        $script:guiCurrentIdentityState = [string]$Snapshot.IdentityState
        Set-QiehaoCodexStatusVisual -Status $script:guiCurrentCodexStatus
        $activeProfileText.Text = if ($script:guiActiveProfileKnown) {
            [string]$script:guiCurrentActiveProfile
        }
        else {
            Get-QiehaoGuiText -Key 'Status.Active.Uninitialized' `
                -Fallback '未初始化'
        }
        $identityStatusText.Text = Get-QiehaoGuiText `
            -Key ('Status.Identity.' + $script:guiCurrentIdentityState) `
            -Fallback ([string]$Snapshot.IdentityStatus)
        $webChatGPTText.Text = Get-QiehaoGuiText -Key 'WebChatGPT.Unchanged' `
            -Fallback ([string]$Snapshot.WebChatGPT)
        switch ([string]$Snapshot.IdentityStatus) {
            '已确认' { $identityStatusText.Foreground = '#FF59D48B' }
            '不匹配' { $identityStatusText.Foreground = '#FFFF7B72' }
            '待退出后确认' { $identityStatusText.Foreground = '#FFFFC857' }
            default { $identityStatusText.Foreground = $window.Resources['TextSecondaryBrush'] }
        }
        Set-QiehaoQuotaUnavailableRows -Rows $rows
        $quotaEnrichment = $null
        $quotaEnrichmentArguments = @()
        if ($script:guiQuotaModulesAvailable) {
            $quotaEnrichment = {
                param($Context)
                $decoratedRows = @(Update-QiehaoQuotaProfileRows `
                    -Rows $Context.Rows `
                    -Cache $Context.Cache `
                    -ActiveProfile ([string]$Context.ActiveProfile) `
                    -JustUpdatedProfile $Context.JustUpdatedProfile `
                    -Language $Context.Language)
                if ($decoratedRows.Count -ne @($Context.Rows).Count) {
                    throw 'QUOTA_ENRICHMENT_CHANGED_PROFILE_POPULATION'
                }
            }
            $quotaEnrichmentArguments = @([pscustomobject]@{
                Rows = $rows
                Cache = $script:guiQuotaCache
                ActiveProfile = [string]$Snapshot.ActiveProfile
                JustUpdatedProfile = $script:guiQuotaJustUpdatedProfile
                Language = $script:guiLanguage
            })
        }
        $quotaResult = Invoke-QiehaoOptionalProfileRowEnrichment `
            -Rows $rows -Enrichment $quotaEnrichment `
            -EnrichmentArguments $quotaEnrichmentArguments
        $script:guiAllProfileRows = @($quotaResult.Rows)
        if (-not $quotaResult.EnrichmentSucceeded) {
            Set-QiehaoQuotaUnavailableRows -Rows $script:guiAllProfileRows
            Disable-QiehaoQuotaFeature
        }
        if (@($Snapshot.ReadOnlyErrors).Count -eq 0) {
            Set-QiehaoLocalizedStatus -Key 'Status.Refreshed' `
                -Fallback '状态已刷新'
        }
        else {
            Set-QiehaoLocalizedStatus -Key 'Status.PartialReadOnly' `
                -Fallback '部分只读状态暂不可用'
        }
        Update-QiehaoLocalizedProfileRows
        Update-QiehaoProfileFilter
    }

    function Invoke-QiehaoReadOnlyRefresh {
        param(
            [string]$ExpectedActiveProfile = '',
            [switch]$PassThru
        )
        $refreshSucceeded = $false
        try {
            $snapshot = Get-QiehaoGuiSnapshot `
                -ListProvider { @(Get-CodexAccountSlot) } `
                -ActiveProvider { Get-CodexActiveProfile } `
                -ProcessProvider { Test-CodexProcessesStopped } `
                -ActiveIdentityProvider { Test-CodexActiveIdentity }
            Set-QiehaoSnapshot -Snapshot $snapshot
            $refreshSucceeded = (
                @($snapshot.ReadOnlyErrors).Count -eq 0 -and
                (
                    [string]::IsNullOrWhiteSpace($ExpectedActiveProfile) -or
                    ([string]$script:guiCurrentActiveProfile).Equals(
                        $ExpectedActiveProfile,
                        [StringComparison]::OrdinalIgnoreCase
                    )
                )
            )
        }
        catch {
            Set-QiehaoLocalizedStatus -Key 'Status.RefreshFailed' `
                -Fallback '只读刷新失败'
            $script:guiCurrentCodexStatus = '未知'
            $script:guiCurrentCodexState = 'Unknown'
            $script:guiCurrentIdentityState = 'Unavailable'
            $codexStatusText.Text = Get-QiehaoGuiText `
                -Key 'Status.Codex.Unknown' -Fallback '未知'
            $identityStatusText.Text = Get-QiehaoGuiText `
                -Key 'Status.Identity.Unavailable' -Fallback '无法确认'
            Update-QiehaoActionButtons
        }
        if ($PassThru) { return $refreshSucceeded }
    }

    function Update-QiehaoQuotaRows {
        if (-not $script:guiQuotaModulesAvailable) {
            Set-QiehaoQuotaUnavailableRows -Rows $script:guiAllProfileRows
            Update-QiehaoProfileFilter
            return
        }
        try {
            $rows = @(Update-QiehaoQuotaProfileRows `
                -Rows $script:guiAllProfileRows `
                -Cache $script:guiQuotaCache `
                -ActiveProfile $script:guiCurrentActiveProfile `
                -JustUpdatedProfile $script:guiQuotaJustUpdatedProfile `
                -Language $script:guiLanguage)
            if ($rows.Count -ne $script:guiAllProfileRows.Count) {
                throw 'QUOTA_ENRICHMENT_CHANGED_PROFILE_POPULATION'
            }
            $script:guiAllProfileRows = $rows
        }
        catch {
            Disable-QiehaoQuotaFeature
            Set-QiehaoQuotaUnavailableRows -Rows $script:guiAllProfileRows
            $refreshStatusText.Text =
                Get-QiehaoQuotaUiTextSafe -Key 'CacheUnavailable'
        }
        Update-QiehaoProfileFilter
    }

    function Stop-QiehaoQuotaCompletionTimer {
        if ($null -ne $script:guiQuotaCompletionTimer) {
            try {
                $script:guiQuotaCompletionTimer.Stop()
                $script:guiQuotaCompletionTimerStopped = $true
            }
            catch { }
            if ($null -ne $script:guiQuotaCompletionTickHandler) {
                try {
                    $script:guiQuotaCompletionTimer.Remove_Tick(
                        $script:guiQuotaCompletionTickHandler
                    )
                    $script:guiQuotaCompletionHandlerRemoved = $true
                }
                catch { }
            }
        }
        $script:guiQuotaCompletionTimer = $null
        $script:guiQuotaCompletionTickHandler = $null
    }

    function Stop-QiehaoQuotaAsync {
        param([switch]$ForClosing)
        Stop-QiehaoQuotaCompletionTimer
        $powerShell = $script:guiQuotaAsyncPowerShell
        $asyncResult = $script:guiQuotaAsyncResult
        try {
            if ($null -ne $powerShell -and $null -ne $asyncResult -and
                -not $asyncResult.IsCompleted) {
                try { $powerShell.Stop() }
                catch { }
            }
        }
        finally {
            if ($null -ne $powerShell) {
                try { $powerShell.Dispose() }
                catch { }
            }
            $script:guiQuotaAsyncPowerShell = $null
            $script:guiQuotaAsyncResult = $null
            $script:guiQuotaRequestedProfile = $null
            $script:guiQuotaAsyncReason = $null
            $script:guiQuotaStartedUtc = $null
            $script:guiQuotaDeadlineUtc = $null
            $script:guiQuotaSlowStatusShown = $false
            $script:guiQuotaCoordinator.QueryInProgress = $false
        }
        if (-not $ForClosing) { Update-QiehaoActionButtons }
    }

    function Complete-QiehaoQuotaAsync {
        param([switch]$HardTimeout)
        Stop-QiehaoQuotaCompletionTimer
        $powerShell = $script:guiQuotaAsyncPowerShell
        $asyncResult = $script:guiQuotaAsyncResult
        $requestedProfile = $script:guiQuotaRequestedProfile
        $reason = $script:guiQuotaAsyncReason
        $providerResult = $null
        $completionFailureCode = if ($HardTimeout) {
            'QUOTA_BACKGROUND_WORKER_FAILED'
        }
        else { $null }
        $script:guiQuotaWorkerOutputCount = 0
        $script:guiQuotaLastDiagnostics = $null
        try {
            if ($HardTimeout -and $null -ne $powerShell -and
                $null -ne $asyncResult -and -not $asyncResult.IsCompleted) {
                try { $powerShell.Stop() }
                catch { }
            }
            elseif ($null -ne $powerShell -and $null -ne $asyncResult) {
                $script:guiQuotaEndInvokeAttempted = $true
                $output = @($powerShell.EndInvoke($asyncResult))
                $script:guiQuotaWorkerOutputCount = $output.Count
                if ($output.Count -eq 1 -and
                    $null -ne $output[0] -and
                    $null -ne $output[0].PSObject.Properties['Succeeded']) {
                    $providerResult = $output[0]
                    $diagnosticsProperty =
                        $providerResult.PSObject.Properties['Diagnostics']
                    if ($null -ne $diagnosticsProperty) {
                        $script:guiQuotaLastDiagnostics =
                            $diagnosticsProperty.Value
                        if ($null -ne $script:guiQuotaLastDiagnostics) {
                            $script:guiQuotaLastDiagnostics | Add-Member `
                                -NotePropertyName WorkerOutputCount `
                                -NotePropertyValue $output.Count -Force
                        }
                    }
                    if (-not [bool]$providerResult.Succeeded) {
                        $failureProperty =
                            $providerResult.PSObject.Properties['FailureCode']
                        $completionFailureCode =
                            Get-QiehaoSafeQuotaFailureCode -Value $(
                                if ($null -eq $failureProperty) {
                                    $null
                                }
                                else { $failureProperty.Value }
                            )
                    }
                }
                else {
                    $providerResult = $null
                    $completionFailureCode = 'QUOTA_RESULT_MISSING'
                }
            }
        }
        catch {
            $providerResult = $null
            $completionFailureCode = 'QUOTA_BACKGROUND_WORKER_FAILED'
        }
        finally {
            if ($null -ne $powerShell) {
                try { $powerShell.Dispose() }
                catch { }
            }
            $script:guiQuotaAsyncPowerShell = $null
            $script:guiQuotaAsyncResult = $null
            $script:guiQuotaRequestedProfile = $null
            $script:guiQuotaAsyncReason = $null
            $script:guiQuotaStartedUtc = $null
            $script:guiQuotaDeadlineUtc = $null
            $script:guiQuotaSlowStatusShown = $false
            $script:guiQuotaCoordinator.QueryInProgress = $false
        }

        $stillCurrent = (
            -not [string]::IsNullOrWhiteSpace($requestedProfile) -and
            ([string]$script:guiCurrentActiveProfile).Equals(
                $requestedProfile,
                [StringComparison]::OrdinalIgnoreCase
            )
        )
        $updated = $false
        try {
            if (-not $HardTimeout -and $stillCurrent -and
                $null -ne $providerResult -and
                [bool]$providerResult.Succeeded) {
                $saved = Save-QiehaoQuotaSnapshot `
                    -StateDirectory $stateDirectory `
                    -Cache $script:guiQuotaCache `
                    -ProfileName $requestedProfile `
                    -Snapshot $providerResult.Snapshot
                if ($saved.Succeeded) {
                    $script:guiQuotaCache = $saved.Cache
                    $script:guiQuotaJustUpdatedProfile = $requestedProfile
                    $updated = $true
                }
                else {
                    $completionFailureCode = Get-QiehaoSafeQuotaFailureCode `
                        -Value $saved.FailureCode
                }
            }
        }
        catch {
            $updated = $false
            $completionFailureCode = 'QUOTA_CACHE_WRITE_FAILED'
        }

        $script:guiQuotaLastQueryFailed = -not $updated
        if ($updated) {
            $script:guiQuotaLastFailureCode = $null
            if ($reason -ceq 'SwitchBefore') {
                $switchQuotaSuccessText = if (
                    $script:guiManualSwitchWaitInProgress -and
                    -not $script:guiManualSwitchCodexStopped
                ) {
                    Format-QiehaoGuiText `
                        -Key 'Quota.SwitchBeforeSavedWaiting' `
                        -Arguments @($requestedProfile) `
                        -Fallback "'{0}' 的额度快照已保存，正在等待 Codex 安全退出……"
                }
                else {
                    Format-QiehaoGuiText `
                        -Key 'Quota.SwitchBeforeSaved' `
                        -Arguments @($requestedProfile) `
                        -Fallback "'{0}' 的额度快照已保存，正在切换账号……"
                }
                Set-QiehaoSwitchQuotaStatus -Tone Success `
                    -Text $switchQuotaSuccessText
            }
            else {
                Set-QiehaoLocalizedStatus -Key 'Quota.Updated' `
                    -Fallback '当前账号额度已更新。'
            }
        }
        else {
            if ([string]::IsNullOrWhiteSpace($completionFailureCode)) {
                $completionFailureCode = 'QUOTA_RESULT_MISSING'
            }
            $script:guiQuotaLastFailureCode =
                Get-QiehaoSafeQuotaFailureCode -Value $completionFailureCode
            if ($reason -ceq 'SwitchBefore') {
                Set-QiehaoSwitchQuotaStatus -Text (
                    Format-QiehaoGuiText `
                        -Key 'Quota.SwitchBeforeFallback' `
                        -Arguments @($requestedProfile) `
                        -Fallback "本次未能更新 '{0}' 的额度快照。已保留上次缓存，正在继续切换……"
                )
            }
            elseif ($reason -ceq 'SwitchAfter') {
                Set-QiehaoLocalizedStatus `
                    -Key 'Quota.SwitchNewFailedWithCode' `
                    -Arguments @($script:guiQuotaLastFailureCode) `
                    -Fallback '切换成功；额度更新失败，保留原缓存。 错误代码：{0}'
            }
            else {
                Set-QiehaoLocalizedStatus `
                    -Key 'Quota.UpdateFailedRetryWithCode' `
                    -Arguments @($script:guiQuotaLastFailureCode) `
                    -Fallback '额度更新失败，可稍后点击“刷新额度”重试。 错误代码：{0}'
            }
        }
        try {
            Update-QiehaoQuotaRows
        }
        finally {
            Update-QiehaoActionButtons
        }
        if ($reason -ceq 'SwitchBefore' -and
            -not $script:guiManualSwitchWaitInProgress -and
            [string]$script:guiPendingAction -ceq 'SwitchAfterQuota') {
            Continue-QiehaoStoppedSwitchAfterQuota
        }
    }

    function Start-QiehaoQuotaAsync {
        param(
            [Parameter(Mandatory = $true)]
            [ValidateSet('Open', 'Manual', 'SwitchBefore', 'SwitchAfter')]
            [string]$Reason
        )
        if (-not $script:guiQuotaModulesAvailable -or
            $script:guiIsClosing -or
            [bool]$script:guiQuotaCoordinator.QueryInProgress) {
            return $false
        }
        if ($Reason -ceq 'Open') {
            if ([bool]$script:guiQuotaCoordinator.StartupAttempted) {
                return $false
            }
            $script:guiQuotaCoordinator.StartupAttempted = $true
        }
        $activeProfile = [string]$script:guiCurrentActiveProfile
        if ([string]::IsNullOrWhiteSpace($activeProfile) -or
            $activeProfile -ceq '未初始化') {
            return $false
        }

        $script:guiQuotaCoordinator.QueryInProgress = $true
        $script:guiQuotaLastQueryFailed = $false
        $script:guiQuotaLastFailureCode = $null
        $script:guiQuotaLastDiagnostics = $null
        $script:guiQuotaWorkerOutputCount = 0
        $script:guiQuotaCompletionTimerStopped = $false
        $script:guiQuotaCompletionHandlerRemoved = $false
        $script:guiQuotaEndInvokeAttempted = $false
        $script:guiQuotaRequestedProfile = $activeProfile
        $script:guiQuotaAsyncReason = $Reason
        $script:guiQuotaStartedUtc = [DateTime]::UtcNow
        $script:guiQuotaSlowStatusShown = $false
        $quotaTimeoutSeconds = if ($Reason -ceq 'SwitchBefore') {
            8
        }
        elseif ($Reason -ceq 'SwitchAfter') { 10 }
        else { 30 }
        $hardCeilingMilliseconds = if (
            $SelfTest -and
            -not [string]::IsNullOrWhiteSpace(
                [string]$script:guiQuotaSelfTestScenario
            ) -and
            $script:guiQuotaSelfTestHardCeilingMilliseconds -gt 0
        ) {
            $script:guiQuotaSelfTestHardCeilingMilliseconds
        }
        elseif ($Reason -ceq 'SwitchBefore') { 8000 }
        elseif ($Reason -ceq 'SwitchAfter') { 18000 }
        else { 38000 }
        $script:guiQuotaDeadlineUtc = [DateTime]::UtcNow.AddMilliseconds(
            $hardCeilingMilliseconds
        )
        Set-QiehaoLocalizedStatus -Key 'Quota.Updating' `
            -Fallback '正在更新当前账号额度……'
        Update-QiehaoActionButtons
        try {
            $powerShell = [PowerShell]::Create()
            $queryScript = {
                param($ClientModulePath, $Scenario, $TimeoutSeconds)
                $ErrorActionPreference = 'Stop'
                $clientModule = @(Import-Module -Name $ClientModulePath `
                    -PassThru -ErrorAction Stop |
                    Select-Object -Last 1)[0]
                if ($null -eq $clientModule -or
                    -not $clientModule.ExportedCommands.ContainsKey(
                        'Invoke-QiehaoQuotaBackgroundWorker'
                    )) {
                    throw 'QUOTA_BACKGROUND_WORKER_FAILED'
                }

                if (-not [string]::IsNullOrWhiteSpace([string]$Scenario)) {
                    if ($Scenario -ceq 'Throw') {
                        throw 'FAKE_ASYNC_COMPLETION_EXCEPTION'
                    }
                    $fakeProvider = {
                        param($IgnoredTimeoutSeconds, $ProviderScenario)
                        switch ([string]$ProviderScenario) {
                        'Success' {
                            return [pscustomobject]@{
                                Succeeded = $true
                                FailureCode = $null
                                Snapshot = [pscustomobject]@{
                                    Plan = 'team'
                                    OrdinaryUsageAllowed = $true
                                    Windows = @(
                                        [pscustomobject]@{
                                            DurationMinutes = 300
                                            Label = '5-hour'
                                            RemainingPercent = 35
                                            ResetsAt = 1893542400
                                            ResetLocal = ''
                                        },
                                        [pscustomobject]@{
                                            DurationMinutes = 10080
                                            Label = 'Weekly'
                                            RemainingPercent = 15
                                            ResetsAt = 1893628800
                                            ResetLocal = ''
                                        }
                                    )
                                }
                                Diagnostics = [pscustomobject]@{
                                    AccountStabilityLockAcquired = $true
                                    AppServerStarted = $false
                                    InitializeMatched = $false
                                    RateLimitsResponseMatched = $false
                                }
                                ElapsedMilliseconds = 1
                                ChildCleanup = 'NotStarted'
                                AccountStabilityLockCleanup = 'Released'
                            }
                        }
                        'Failure' {
                            return [pscustomobject]@{
                                Succeeded = $false
                                FailureCode = 'QUOTA_RATE_LIMITS_TIMEOUT'
                                Snapshot = $null
                                Diagnostics = [pscustomobject]@{
                                    AccountStabilityLockAcquired = $true
                                    AppServerStarted = $true
                                    InitializeMatched = $true
                                    RateLimitsResponseMatched = $false
                                }
                                ElapsedMilliseconds = 2
                                ChildCleanup = 'Normal'
                                AccountStabilityLockCleanup = 'Released'
                            }
                        }
                        'CleanupFailure' {
                            return [pscustomobject]@{
                                Succeeded = $false
                                FailureCode =
                                    'QUOTA_CHILD_CLEANUP_FAILED'
                                Snapshot = $null
                                PrimarySucceeded = $true
                                PrimaryFailureCode = $null
                                CleanupSucceeded = $false
                                CleanupFailureCode =
                                    'QUOTA_CHILD_CLEANUP_FAILED'
                                Diagnostics = [pscustomobject]@{
                                    AccountStabilityLockAcquired = $true
                                    AppServerStarted = $true
                                    ProcessStarted = $true
                                    InitializeMatched = $true
                                    RateLimitsResponseMatched = $true
                                    SnapshotParsed = $true
                                    StdinCloseAttempted = $true
                                    StdinCloseSucceeded = $true
                                    ChildExitedNaturally = $false
                                    ChildHasExited = $false
                                    CleanupElapsedMilliseconds = 4000
                                    PrimarySucceeded = $true
                                    PrimaryFailureCode = $null
                                    CleanupSucceeded = $false
                                    CleanupFailureCode =
                                        'QUOTA_CHILD_CLEANUP_FAILED'
                                }
                                ElapsedMilliseconds = 2200
                                CleanupElapsedMilliseconds = 4000
                                ChildCleanup = 'GraceExpired'
                                AccountStabilityLockCleanup = 'Released'
                            }
                        }
                        'Timeout' {
                            Start-Sleep -Seconds 5
                            return [pscustomobject]@{
                                Succeeded = $false
                                FailureCode = 'QUOTA_RATE_LIMITS_TIMEOUT'
                                Snapshot = $null
                            }
                        }
                        'Closing' {
                            Start-Sleep -Seconds 5
                            return [pscustomobject]@{
                                Succeeded = $false
                                FailureCode = 'QUOTA_BACKGROUND_WORKER_FAILED'
                                Snapshot = $null
                            }
                        }
                        default { throw 'FAKE_QUOTA_SCENARIO_INVALID' }
                    }
                    }
                    Invoke-QiehaoQuotaBackgroundWorker `
                        -TimeoutSeconds $TimeoutSeconds `
                        -QuotaProvider $fakeProvider `
                        -QuotaProviderArgument $Scenario
                    return
                }

                Invoke-QiehaoQuotaBackgroundWorker `
                    -TimeoutSeconds $TimeoutSeconds
            }
            $workerScenario = if ($SelfTest) {
                [string]$script:guiQuotaSelfTestScenario
            }
            else { '' }
            $null = $powerShell.AddScript($queryScript.ToString()).
                AddArgument($quotaClientModulePath).
                AddArgument($workerScenario).
                AddArgument($quotaTimeoutSeconds)
            $script:guiQuotaAsyncPowerShell = $powerShell
            $script:guiQuotaAsyncResult = $powerShell.BeginInvoke()
            if ($SelfTest -and -not [string]::IsNullOrWhiteSpace(
                [string]$script:guiQuotaSelfTestScenario
            )) {
                $script:guiQuotaSelfTestQueryCount++
            }

            $timer = New-Object System.Windows.Threading.DispatcherTimer
            $timer.Interval = [TimeSpan]::FromMilliseconds(125)
            $tickHandler = [System.EventHandler]({
                param($sender, $eventArgs)
                try {
                    if ($script:guiIsClosing) {
                        Stop-QiehaoQuotaAsync -ForClosing
                        return
                    }
                    if ($null -ne $script:guiQuotaAsyncResult -and
                        $script:guiQuotaAsyncResult.IsCompleted) {
                        Complete-QiehaoQuotaAsync
                        return
                    }
                    if ([string]$script:guiQuotaAsyncReason -ceq
                        'SwitchBefore' -and
                        -not $script:guiQuotaSlowStatusShown -and
                        $null -ne $script:guiQuotaStartedUtc -and
                        [DateTime]::UtcNow -ge
                            ([DateTime]$script:guiQuotaStartedUtc).
                                AddSeconds(3)) {
                        $script:guiQuotaSlowStatusShown = $true
                        if (-not $script:guiManualSwitchCodexStopped) {
                            Set-QiehaoSwitchQuotaStatus -Text (
                                Get-QiehaoGuiText -Key 'Quota.SlowResponse' `
                                    -Fallback '额度服务响应较慢，仍在等待……'
                            )
                        }
                    }
                    if ($null -ne $script:guiQuotaDeadlineUtc -and
                        [DateTime]::UtcNow -ge
                            [DateTime]$script:guiQuotaDeadlineUtc) {
                        Complete-QiehaoQuotaAsync -HardTimeout
                    }
                }
                catch {
                    Stop-QiehaoQuotaAsync
                    $script:guiQuotaLastQueryFailed = $true
                    $script:guiQuotaLastFailureCode =
                        'QUOTA_BACKGROUND_WORKER_FAILED'
                    Set-QiehaoLocalizedStatus `
                        -Key 'Quota.UpdateFailedRetryWithCode' `
                        -Arguments @($script:guiQuotaLastFailureCode) `
                        -Fallback '额度更新失败，可稍后点击“刷新额度”重试。 错误代码：{0}'
                    try { Update-QiehaoQuotaRows }
                    finally { Update-QiehaoActionButtons }
                }
            })
            $script:guiQuotaCompletionTimer = $timer
            $script:guiQuotaCompletionTickHandler = $tickHandler
            $timer.Add_Tick($tickHandler)
            $timer.Start()
            return $true
        }
        catch {
            Stop-QiehaoQuotaAsync
            $script:guiQuotaLastQueryFailed = $true
            $script:guiQuotaLastFailureCode =
                'QUOTA_BACKGROUND_WORKER_FAILED'
            Set-QiehaoLocalizedStatus `
                -Key 'Quota.UpdateFailedRetryWithCode' `
                -Arguments @($script:guiQuotaLastFailureCode) `
                -Fallback '额度更新失败，可稍后点击“刷新额度”重试。 错误代码：{0}'
            return $false
        }
    }

    function Invoke-QiehaoQuotaBeforeSwitch {
        if (-not $script:guiQuotaModulesAvailable) { return }
        Stop-QiehaoQuotaAsync
        $activeProfile = [string]$script:guiCurrentActiveProfile
        if ([string]::IsNullOrWhiteSpace($activeProfile) -or
            $activeProfile -ceq '未初始化') {
            return
        }
        $result = Invoke-QiehaoQuotaCacheRefresh `
            -Reason SwitchBefore `
            -Coordinator $script:guiQuotaCoordinator `
            -StateDirectory $stateDirectory `
            -Cache $script:guiQuotaCache `
            -ActiveProfile $activeProfile `
            -SelectedProfile (Get-QiehaoSelectedProfileName) `
            -QuotaProvider {
                param($IgnoredProfile)
                Get-QiehaoCurrentQuotaSnapshot -TimeoutSeconds 8
            }
        if ($result.Succeeded) {
            $script:guiQuotaCache = $result.Cache
            $script:guiQuotaJustUpdatedProfile = $activeProfile
            Update-QiehaoQuotaRows
        }
        else {
            $refreshStatusText.Text =
                Get-QiehaoQuotaUiTextSafe -Key 'SwitchOldFailed'
        }
    }

    function Invoke-QiehaoManualQuotaRefresh {
        if (-not $script:guiQuotaModulesAvailable) {
            $refreshStatusText.Text =
                Get-QiehaoQuotaUiTextSafe -Key 'CacheUnavailable'
            return
        }
        if ($script:guiIsWriteOperationBusy -or
            [bool]$script:guiQuotaCoordinator.QueryInProgress) {
            return
        }
        $selectedProfile = Get-QiehaoSelectedProfileName
        if (-not [string]::IsNullOrWhiteSpace($selectedProfile) -and
            -not $selectedProfile.Equals(
                [string]$script:guiCurrentActiveProfile,
                [StringComparison]::OrdinalIgnoreCase
            )) {
            $refreshStatusText.Text =
                Get-QiehaoQuotaUiTextSafe -Key 'RefreshCurrentOnly'
        }
        $null = Start-QiehaoQuotaAsync -Reason Manual
    }

    function Set-QiehaoSwitchUiState {
        param(
            [Parameter(Mandatory = $true)]
            [ValidateSet(
                'Idle', 'WaitingForCodexExit', 'Switching',
                'SwitchSucceeded', 'SwitchSucceededUiRefreshFailed',
                'SwitchFailed', 'Cancelled', 'Unknown', 'TimedOut', 'Closing'
            )]
            [string]$State,
            [string]$TargetProfile = ''
        )
        $script:guiSwitchUiState = $State
        switch ($State) {
            'WaitingForCodexExit' {
                Set-QiehaoLocalizedStatus `
                    -Key 'Dialog.Switch.WaitingTarget' `
                    -Arguments @($TargetProfile) `
                    -Fallback "正在等待 Codex 安全退出，随后自动切换到 '{0}'……"
            }
            'Switching' {
                Set-QiehaoLocalizedStatus `
                    -Key 'Switch.Status.SwitchingTarget' `
                    -Arguments @($TargetProfile) `
                    -Fallback "已检测到 Codex 完全退出，正在切换到 '{0}'……"
            }
            'SwitchSucceeded' {
                Set-QiehaoLocalizedStatus `
                    -Key 'Switch.Status.SuccessCurrent' `
                    -Arguments @($TargetProfile) `
                    -Fallback '切换成功，当前账号：{0}'
            }
            'SwitchSucceededUiRefreshFailed' {
                Set-QiehaoLocalizedStatus -Key 'Switch.RefreshFailed' `
                    -Fallback '账号切换已经成功，但界面状态刷新失败。请点击“刷新”重新读取当前状态。'
            }
            'SwitchFailed' {
                Set-QiehaoLocalizedStatus -Key 'Switch.Status.Failed' `
                    -Fallback '账号切换未完成'
            }
            'Cancelled' {
                Set-QiehaoLocalizedStatus -Key 'Switch.Status.Cancelled' `
                    -Fallback '已取消等待，本次未切换账号'
            }
            'Unknown' {
                Set-QiehaoLocalizedStatus -Key 'Switch.Status.Unknown' `
                    -Fallback '进程状态未知，本次未切换账号'
            }
            'TimedOut' {
                Set-QiehaoLocalizedStatus -Key 'Switch.Status.TimedOut' `
                    -Fallback '等待超时，本次未切换账号'
            }
            'Closing' {
                Set-QiehaoLocalizedStatus -Key 'Switch.Status.Closing' `
                    -Fallback '切换等待已停止'
            }
        }
    }

    function Update-QiehaoCodexSafetyHint {
        if ($script:guiManualSwitchWaitInProgress) {
            $codexSafetyHintText.Text = Get-QiehaoGuiText `
                -Key 'Safety.WaitingForExit' `
                -Fallback '等待用户正常退出 Codex；检测到完全退出后将自动继续切换。'
            $codexSafetyHintText.Foreground =
                $window.Resources['RunningWarningBrush']
            return
        }
        switch ($script:guiCurrentCodexState) {
            'Running' {
                $codexSafetyHintText.Text = Get-QiehaoGuiText `
                    -Key 'Safety.Running' `
                    -Fallback 'Codex 正在运行。切换账号前请安全退出 Codex。'
                $codexSafetyHintText.Foreground =
                    $window.Resources['RunningWarningBrush']
            }
            'Stopped' {
                $codexSafetyHintText.Text = Get-QiehaoGuiText `
                    -Key 'Safety.Stopped' `
                    -Fallback 'Codex 已安全退出，可以切换账号。'
                $codexSafetyHintText.Foreground =
                    $window.Resources['CurrentYesBrush']
            }
            default {
                $codexSafetyHintText.Text = Get-QiehaoGuiText `
                    -Key 'Safety.Unknown' `
                    -Fallback '无法确认 Codex 是否完全退出；切换与写操作将安全停止。'
                $codexSafetyHintText.Foreground =
                    $window.Resources['UnknownWarningBrush']
            }
        }
    }

    function Set-QiehaoCodexStatusVisual {
        param(
            [Parameter(Mandatory = $true)]
            [ValidateSet('运行中', '已退出', '未知')]
            [string]$Status
        )
        $script:guiCurrentCodexStatus = $Status
        $script:guiCurrentCodexState = switch ($Status) {
            '运行中' { 'Running' }
            '已退出' { 'Stopped' }
            default { 'Unknown' }
        }
        $codexStatusText.Text = Get-QiehaoGuiText `
            -Key ('Status.Codex.' + $script:guiCurrentCodexState) `
            -Fallback $Status
        switch ($Status) {
            '运行中' { $codexStatusText.Foreground = '#FFFF7B72' }
            '已退出' { $codexStatusText.Foreground = '#FF59D48B' }
            default { $codexStatusText.Foreground = $window.Resources['TextSecondaryBrush'] }
        }
        Update-QiehaoCodexSafetyHint
    }

    function Get-QiehaoLiveCodexStatus {
        try {
            return ConvertTo-QiehaoCodexStatus -ProcessState (Test-CodexProcessesStopped)
        }
        catch { return '未知' }
    }

    function Update-QiehaoProcessOnlyStatus {
        if ($script:guiIsClosing) { return '未知' }
        $status = Get-QiehaoLiveCodexStatus
        Set-QiehaoCodexStatusVisual -Status $status
        Update-QiehaoActionButtons
        return $status
    }

    function Stop-QiehaoProcessMonitor {
        $null = Stop-QiehaoDispatcherTimer `
            -Timer $script:guiProcessTimer `
            -TickHandler $script:guiProcessTimerTickHandler
        $script:guiProcessTimer = $null
        $script:guiProcessTimerTickHandler = $null
    }

    function Start-QiehaoProcessMonitor {
        if ($script:guiIsClosing -or $null -ne $script:guiProcessTimer) { return }
        $script:guiProcessTimer = New-Object System.Windows.Threading.DispatcherTimer
        $script:guiProcessTimer.Interval = [TimeSpan]::FromSeconds(5)
        $script:guiProcessTimerTickHandler = [System.EventHandler]{
            param($sender, $eventArgs)
            if (-not $script:guiIsClosing) {
                $null = Update-QiehaoProcessOnlyStatus
            }
        }
        $script:guiProcessTimer.Add_Tick($script:guiProcessTimerTickHandler)
        $script:guiProcessTimer.Start()
    }

    function Stop-QiehaoLaunchWaitTimer {
        if ($null -ne $script:guiLaunchWaitRuntime) {
            $null = Stop-QiehaoWaitTimerRuntime `
                -Runtime $script:guiLaunchWaitRuntime -Result 'Cancelled'
        }
        else {
            $null = Stop-QiehaoDispatcherTimer `
                -Timer $script:guiLaunchTimer `
                -TickHandler $script:guiLaunchTimerTickHandler
        }
        $script:guiLaunchWaitRuntime = $null
        $script:guiLaunchTimer = $null
        $script:guiLaunchTimerTickHandler = $null
    }

    function Stop-QiehaoManualSwitchWaitTimer {
        param([string]$Result = 'Cancelled')
        if ($null -ne $script:guiManualSwitchWaitRuntime) {
            $null = Stop-QiehaoWaitTimerRuntime `
                -Runtime $script:guiManualSwitchWaitRuntime -Result $Result
        }
        else {
            $null = Stop-QiehaoDispatcherTimer `
                -Timer $script:guiManualSwitchWaitTimer `
                -TickHandler $script:guiManualSwitchWaitTimerTickHandler
        }
        $script:guiManualSwitchWaitRuntime = $null
        $script:guiManualSwitchWaitTimer = $null
        $script:guiManualSwitchWaitTimerTickHandler = $null
    }

    function Stop-QiehaoAllTimers {
        $hadActiveWait = (
            $null -ne $script:guiManualSwitchWaitRuntime -and
            [bool]$script:guiManualSwitchWaitRuntime.Active
        )
        $script:guiIsClosing = $true
        Stop-QiehaoQuotaAsync -ForClosing
        Stop-QiehaoProcessMonitor
        Stop-QiehaoLaunchWaitTimer
        Stop-QiehaoManualSwitchWaitTimer -Result 'WindowClosing'
        if ($null -ne $script:guiManualSwitchWaitDialog) {
            $script:guiManualSwitchWaitInternalClose = $true
            try { $script:guiManualSwitchWaitDialog.Close() }
            catch { }
        }
        $script:guiPendingAction = $null
        $script:guiPendingTargetProfile = $null
        $script:guiManualSwitchWaitInProgress = $false
        $script:guiManualSwitchWaitDialog = $null
        $script:guiManualSwitchWaitStatusText = $null
        $script:guiManualSwitchWaitCancelButton = $null
        $script:guiManualSwitchWaitOutcome = 'Closing'
        $script:guiManualSwitchCodexStopped = $false
        $script:guiManualSwitchResult = $null
        $script:guiManualSwitchPresentation = $null
        $script:guiSwitchUiState = 'Closing'
        $script:guiIsWriteOperationBusy = $false
        if ($hadActiveWait) {
            try {
                Set-QiehaoLocalizedStatus -Key 'Switch.Status.Closing' `
                    -Fallback '切换等待已停止'
            }
            catch { }
        }
        try { Update-QiehaoActionButtons }
        catch { }
    }

    function Get-QiehaoInstalledCodexApplications {
        $results = @()
        if ($null -eq (Get-Command -Name Get-AppxPackage -ErrorAction SilentlyContinue) -or
            $null -eq (Get-Command -Name Get-AppxPackageManifest -ErrorAction SilentlyContinue)) {
            return @()
        }
        try {
            foreach ($package in @(Get-AppxPackage -Name 'OpenAI.Codex' -ErrorAction Stop)) {
                $family = [string]$package.PackageFamilyName
                if ([string]::IsNullOrWhiteSpace($family)) { continue }
                $manifest = Get-AppxPackageManifest -Package $package -ErrorAction Stop
                foreach ($application in @($manifest.Package.Applications.Application)) {
                    $applicationId = [string]$application.Id
                    if (-not [string]::IsNullOrWhiteSpace($applicationId)) {
                        $results += [pscustomobject]@{
                            PackageFamilyName = $family
                            ApplicationId = $applicationId
                        }
                    }
                }
            }
        }
        catch { return @() }
        return @($results)
    }

    function Get-QiehaoStartApplications {
        if ($null -eq (Get-Command -Name Get-StartApps -ErrorAction SilentlyContinue)) {
            return @()
        }
        try { return @(Get-StartApps -ErrorAction Stop) }
        catch { return @() }
    }

    function Resolve-QiehaoLaunchTarget {
        if ($null -eq $script:guiLaunchSettings) {
            $script:guiLaunchSettings = Read-QiehaoLaunchSettings `
                -StateDirectory $stateDirectory
        }
        try {
            if ([string]$script:guiLaunchSettings.Mode -ceq 'Custom') {
                $script:guiLaunchTarget = Find-QiehaoCodexLaunchTarget `
                    -Mode Custom -CustomPath ([string]$script:guiLaunchSettings.CustomPath)
            }
            else {
                $script:guiLaunchTarget = Find-QiehaoCodexLaunchTarget -Mode Auto `
                    -AppxApplications @(Get-QiehaoInstalledCodexApplications) `
                    -StartApps @(Get-QiehaoStartApplications)
            }
        }
        catch {
            $script:guiLaunchTarget = [pscustomobject]@{
                Available = $false; Type = 'Unavailable'
                AppUserModelId = $null; ExecutablePath = $null
                DisplayStatus = '检测失败'; Source = 'None'
            }
        }
        $launchTargetText.Text = Format-QiehaoGuiText `
            -Key 'Launch.Target' `
            -Arguments @((Get-QiehaoLocalizedLaunchStatus)) `
            -Fallback 'Codex 启动目标：{0}'
        Update-QiehaoActionButtons
        return $script:guiLaunchTarget
    }

    function Show-QiehaoLaunchSettingsDialog {
        $dialog = New-Object System.Windows.Window
        $dialog.Title = Get-QiehaoGuiText -Key 'Launch.Settings.Title' `
            -Fallback 'Codex 启动设置'
        $dialog.Width = 600
        $dialog.Height = 310
        $dialog.MinWidth = 520
        $dialog.MinHeight = 280
        $dialog.WindowStartupLocation = 'CenterOwner'
        $dialog.ResizeMode = 'NoResize'
        $dialog.ShowInTaskbar = $false
        $dialog.Owner = $window
        $dialog.FontFamily = $window.FontFamily
        $dialog.FontSize = $window.FontSize

        $root = New-Object System.Windows.Controls.Grid
        $root.Margin = 18
        foreach ($height in @('Auto', 'Auto', 'Auto', '*', 'Auto')) {
            $row = New-Object System.Windows.Controls.RowDefinition
            $row.Height = $height
            $root.RowDefinitions.Add($row)
        }
        $intro = New-Object System.Windows.Controls.TextBlock
        $intro.Text = Get-QiehaoGuiText -Key 'Launch.Settings.Intro' `
            -Fallback '推荐使用自动检测。仅在特殊安装位置时选择自定义 EXE。'
        $intro.TextWrapping = 'Wrap'
        [System.Windows.Controls.Grid]::SetRow($intro, 0)
        $root.Children.Add($intro) | Out-Null

        $modePanel = New-Object System.Windows.Controls.StackPanel
        $modePanel.Orientation = 'Horizontal'
        $modePanel.Margin = '0,14,0,10'
        [System.Windows.Controls.Grid]::SetRow($modePanel, 1)
        $autoRadio = New-Object System.Windows.Controls.RadioButton
        $autoRadio.Content = Get-QiehaoGuiText -Key 'Launch.Settings.Auto' `
            -Fallback '自动检测（推荐）'
        $autoRadio.GroupName = 'LaunchMode'
        $autoRadio.Margin = '0,0,18,0'
        $customRadio = New-Object System.Windows.Controls.RadioButton
        $customRadio.Content = Get-QiehaoGuiText -Key 'Launch.Settings.Custom' `
            -Fallback '自定义 EXE'
        $customRadio.GroupName = 'LaunchMode'
        $modePanel.Children.Add($autoRadio) | Out-Null
        $modePanel.Children.Add($customRadio) | Out-Null
        $root.Children.Add($modePanel) | Out-Null

        $pathGrid = New-Object System.Windows.Controls.Grid
        $pathGrid.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition))
        $browseColumn = New-Object System.Windows.Controls.ColumnDefinition
        $browseColumn.Width = 'Auto'
        $pathGrid.ColumnDefinitions.Add($browseColumn)
        [System.Windows.Controls.Grid]::SetRow($pathGrid, 2)
        $pathBox = New-Object System.Windows.Controls.TextBox
        $pathBox.MinHeight = 32
        $pathBox.Padding = '7,4'
        $pathBox.Text = [string]$script:guiLaunchSettings.CustomPath
        $browseButton = New-Object System.Windows.Controls.Button
        $browseButton.Content = Get-QiehaoGuiText -Key 'Launch.Settings.Browse' `
            -Fallback '浏览…'
        $browseButton.MinWidth = 82
        $browseButton.Margin = '8,0,0,0'
        [System.Windows.Controls.Grid]::SetColumn($browseButton, 1)
        $pathGrid.Children.Add($pathBox) | Out-Null
        $pathGrid.Children.Add($browseButton) | Out-Null
        $root.Children.Add($pathGrid) | Out-Null

        $hint = New-Object System.Windows.Controls.TextBlock
        $hint.Margin = '0,12,0,0'
        $hint.TextWrapping = 'Wrap'
        $hint.Text = Get-QiehaoGuiText -Key 'Launch.Settings.Hint' `
            -Fallback '不会附加命令行参数，不会更改 Codex 配置或登录状态。'
        [System.Windows.Controls.Grid]::SetRow($hint, 3)
        $root.Children.Add($hint) | Out-Null

        $buttons = New-Object System.Windows.Controls.StackPanel
        $buttons.Orientation = 'Horizontal'
        $buttons.HorizontalAlignment = 'Right'
        [System.Windows.Controls.Grid]::SetRow($buttons, 4)
        $detectButton = New-Object System.Windows.Controls.Button
        $detectButton.Content = Get-QiehaoGuiText -Key 'Launch.Settings.Detect' `
            -Fallback '重新检测'
        $saveButton = New-Object System.Windows.Controls.Button
        $saveButton.Content = Get-QiehaoGuiText -Key 'Launch.Settings.Save' `
            -Fallback '保存'
        $saveButton.IsDefault = $true
        $cancelButton = New-Object System.Windows.Controls.Button
        $cancelButton.Content = Get-QiehaoGuiText -Key 'Button.Cancel' `
            -Fallback '取消'
        $cancelButton.IsCancel = $true
        $cancelButton.Margin = '0'
        $buttons.Children.Add($detectButton) | Out-Null
        $buttons.Children.Add($saveButton) | Out-Null
        $buttons.Children.Add($cancelButton) | Out-Null
        $root.Children.Add($buttons) | Out-Null

        $setPathAvailability = {
            $pathBox.IsEnabled = [bool]$customRadio.IsChecked
            $browseButton.IsEnabled = [bool]$customRadio.IsChecked
        }
        $autoRadio.IsChecked = ([string]$script:guiLaunchSettings.Mode -ceq 'Auto')
        $customRadio.IsChecked = -not [bool]$autoRadio.IsChecked
        $autoRadio.Add_Checked($setPathAvailability)
        $customRadio.Add_Checked($setPathAvailability)
        & $setPathAvailability
        $browseButton.Add_Click({
            $picker = New-Object Microsoft.Win32.OpenFileDialog
            $picker.Title = Get-QiehaoGuiText `
                -Key 'Launch.Settings.PickerTitle' `
                -Fallback '选择 Codex 可执行文件'
            $picker.Filter = Get-QiehaoGuiText `
                -Key 'Launch.Settings.FileFilter' `
                -Fallback '可执行文件 (*.exe)|*.exe'
            $picker.CheckFileExists = $true
            $picker.Multiselect = $false
            if ($picker.ShowDialog($dialog) -eq $true) { $pathBox.Text = $picker.FileName }
        })
        $detectButton.Add_Click({
            $autoRadio.IsChecked = $true
            $target = Find-QiehaoCodexLaunchTarget -Mode Auto `
                -AppxApplications @(Get-QiehaoInstalledCodexApplications) `
                -StartApps @(Get-QiehaoStartApplications)
            $hint.Text = Format-QiehaoGuiText `
                -Key 'Launch.Settings.Result' `
                -Arguments @([string]$target.DisplayStatus) `
                -Fallback '检测结果：{0}'
        })
        $saveButton.Add_Click({
            $mode = if ([bool]$customRadio.IsChecked) { 'Custom' } else { 'Auto' }
            try {
                $script:guiLaunchSettings = Write-QiehaoLaunchSettings `
                    -StateDirectory $stateDirectory -Mode $mode `
                    -CustomPath ([string]$pathBox.Text)
                $null = Resolve-QiehaoLaunchTarget
                $dialog.DialogResult = $true
            }
            catch {
                [void][System.Windows.MessageBox]::Show(
                    $dialog,
                    (Get-QiehaoGuiText -Key 'Launch.Settings.InvalidPath' `
                        -Fallback '自定义路径必须是现有的本地 .exe 文件。'),
                    (Get-QiehaoGuiText -Key 'Launch.Settings.Title' `
                        -Fallback 'Codex 启动设置'),
                    [System.Windows.MessageBoxButton]::OK,
                    [System.Windows.MessageBoxImage]::Warning
                )
            }
        })
        $dialog.Content = $root
        $null = $dialog.ShowDialog()
    }

    function Complete-QiehaoLaunchWait {
        param(
            [Parameter(Mandatory = $true)]
            [ValidateSet('Running', 'Stopped', 'Unknown')]
            [string]$FinalState
        )
        Stop-QiehaoLaunchWaitTimer
        $script:guiIsWriteOperationBusy = $false
        Set-QiehaoWriteBusy -Value $false
        try {
            if (-not $script:guiIsClosing) { Start-QiehaoProcessMonitor }
            if ($FinalState -ceq 'Running') {
                $refreshStatusText.Text = Get-QiehaoGuiText `
                    -Key 'Launch.Started' -Fallback 'Codex 已启动'
                Invoke-QiehaoReadOnlyRefresh
                return
            }
            if ($FinalState -ceq 'Unknown') {
                Show-QiehaoSafeMessage `
                    -Message (Get-QiehaoGuiText `
                        -Key 'Launch.StartStateUnknown' `
                        -Fallback '已请求启动，但无法确认 Codex 进程状态。') `
                    -Severity Warning
            }
            else {
                Show-QiehaoSafeMessage `
                    -Message (Get-QiehaoGuiText `
                        -Key 'Launch.StartTimeout' `
                        -Fallback '已请求启动，但 10 秒内未检测到 Codex 运行。') `
                    -Severity Warning
            }
            $null = Update-QiehaoProcessOnlyStatus
        }
        catch {
            $script:guiIsWriteOperationBusy = $false
            try {
                Set-QiehaoLocalizedStatus -Key 'Launch.WaitFailed' `
                    -Fallback '启动状态检测失败，已停止等待'
                Update-QiehaoActionButtons
            }
            catch { }
        }
    }

    function Start-QiehaoLaunchWait {
        Stop-QiehaoProcessMonitor
        Stop-QiehaoLaunchWaitTimer
        $script:guiLaunchWaitRuntime = New-QiehaoWaitTimerRuntime `
            -IntervalMilliseconds 500 -TimeoutSeconds 10 `
            -ClosingProvider { [bool]$script:guiIsClosing } `
            -ProbeProvider {
                $status = Get-QiehaoLiveCodexStatus
                if ($status -ceq '运行中') { return 'Succeeded' }
                if ($status -ceq '未知') { return 'Unknown' }
                return 'Pending'
            } `
            -CompletionAction {
                param($Result, $Runtime)
                switch ($Result) {
                    'Succeeded' { Complete-QiehaoLaunchWait -FinalState 'Running' }
                    'TimedOut' { Complete-QiehaoLaunchWait -FinalState 'Stopped' }
                    'Closing' { Stop-QiehaoLaunchWaitTimer }
                    default { Complete-QiehaoLaunchWait -FinalState 'Unknown' }
                }
            }
        $script:guiLaunchTimer = $script:guiLaunchWaitRuntime.Timer
        $script:guiLaunchTimerTickHandler = `
            $script:guiLaunchWaitRuntime.TickHandler
        try {
            $null = Start-QiehaoWaitTimerRuntime `
                -Runtime $script:guiLaunchWaitRuntime
        }
        catch { Complete-QiehaoLaunchWait -FinalState 'Unknown' }
    }

    function Invoke-QiehaoLaunchCodex {
        if ($script:guiIsWriteOperationBusy) { return }
        $liveStatus = Get-QiehaoLiveCodexStatus
        Set-QiehaoCodexStatusVisual -Status $liveStatus
        if ($liveStatus -ceq '运行中') {
            Update-QiehaoActionButtons
            Show-QiehaoSafeMessage -Message (Get-QiehaoGuiText `
                -Key 'Launch.AlreadyRunning' -Fallback 'Codex 已在运行。')
            return
        }
        if ($liveStatus -cne '已退出') {
            Update-QiehaoActionButtons
            Show-QiehaoSafeMessage -Message (Get-QiehaoGuiText `
                -Key 'Launch.UnsafeExitUnknown' `
                -Fallback '无法安全确认 Codex 是否已退出，本次未启动。') `
                -Severity Warning
            return
        }
        if ($null -eq $script:guiLaunchTarget -or
            -not [bool]$script:guiLaunchTarget.Available) {
            $null = Resolve-QiehaoLaunchTarget
        }
        Set-QiehaoWriteBusy -Value $true -StatusText (
            Get-QiehaoGuiText -Key 'Launch.Requesting' `
                -Fallback '正在请求启动 Codex…'
        )
        $result = Invoke-QiehaoCodexLaunchRequest -Target $script:guiLaunchTarget `
            -LaunchProvider {
                param($Target)
                if ([string]$Target.Type -ceq 'AppUserModelId') {
                    $aumid = [string]$Target.AppUserModelId
                    if ($aumid -notmatch '^[A-Za-z0-9._-]+![A-Za-z0-9._-]+$') {
                        throw 'CODEX_LAUNCH_TARGET_INVALID'
                    }
                    Start-Process -FilePath 'explorer.exe' `
                        -ArgumentList ('shell:AppsFolder\' + $aumid) `
                        -WindowStyle Hidden -ErrorAction Stop
                    return $true
                }
                $validation = Test-QiehaoCustomLaunchPath `
                    -Path ([string]$Target.ExecutablePath)
                if (-not $validation.IsValid) { throw 'CODEX_CUSTOM_PATH_INVALID' }
                Start-Process -FilePath ([string]$validation.FullPath) -ErrorAction Stop
                return $true
            }
        if ([string]$result.Result -ceq 'CODEX_LAUNCH_REQUESTED') {
            Start-QiehaoLaunchWait
            return
        }
        Set-QiehaoWriteBusy -Value $false
        Show-QiehaoSafeMessage `
            -Message '无法启动 Codex。请打开“启动设置”重新检测或选择正确的 EXE。' `
            -Severity Warning
    }

    function Close-QiehaoManualSwitchWaitDialog {
        if ($null -eq $script:guiManualSwitchWaitDialog) { return }
        $script:guiManualSwitchWaitInternalClose = $true
        try { $script:guiManualSwitchWaitDialog.Close() }
        catch { }
    }

    function Continue-QiehaoStoppedSwitchAfterQuota {
        $targetProfile = [string]$script:guiPendingTargetProfile
        $script:guiPendingAction = $null
        $script:guiPendingTargetProfile = $null
        if ($script:guiIsClosing -or
            [string]::IsNullOrWhiteSpace($targetProfile)) {
            Set-QiehaoWriteBusy -Value $false
            return
        }
        Set-QiehaoSwitchUiState -State 'Switching' `
            -TargetProfile $targetProfile
        Invoke-QiehaoSwitchCore -TargetProfile $targetProfile `
            -SkipQuotaBefore
    }

    function Complete-QiehaoManualSwitchWait {
        param(
            [Parameter(Mandatory = $true)]
            [ValidateSet('Stopped', 'Running', 'Unknown', 'Cancelled', 'Closing')]
            [string]$FinalState,
            [switch]$DialogAlreadyClosing
        )
        $targetProfile = $script:guiPendingTargetProfile
        Stop-QiehaoManualSwitchWaitTimer -Result $FinalState
        $script:guiPendingAction = $null
        $script:guiPendingTargetProfile = $null
        $script:guiManualSwitchWaitInProgress = $false
        $script:guiManualSwitchCodexStopped = $false

        if ($FinalState -ceq 'Stopped' -and
            -not $script:guiIsClosing -and
            -not [string]::IsNullOrWhiteSpace($targetProfile)) {
            Set-QiehaoCodexStatusVisual -Status '已退出'
            Set-QiehaoSwitchUiState -State 'Switching' `
                -TargetProfile $targetProfile
            if ($null -ne $script:guiManualSwitchWaitStatusText) {
                $script:guiManualSwitchWaitStatusText.Text =
                    Get-QiehaoGuiText -Key 'Dialog.Switch.Stopped' `
                        -Fallback '已检测到 Codex 完全退出，正在切换账号……'
                $script:guiManualSwitchWaitStatusText.Foreground =
                    $window.Resources['DialogSuccessBrush']
            }
            if ($null -ne $script:guiManualSwitchWaitCancelButton) {
                $script:guiManualSwitchWaitCancelButton.IsEnabled = $false
            }
            $capturedTarget = $targetProfile
            $switchAction = [System.Action]({
                try {
                    $script:guiManualSwitchResult = Invoke-QiehaoSwitchCore `
                        -TargetProfile $capturedTarget -DeferPresentation `
                        -SkipQuotaBefore
                }
                catch {
                    $script:guiManualSwitchResult =
                        ConvertTo-QiehaoOperationResult -ResultCode 'SWITCH_FAILED'
                }
                $script:guiManualSwitchPresentation =
                    Complete-QiehaoSwitchUiAfterBackend `
                        -Result $script:guiManualSwitchResult `
                        -TargetProfile $capturedTarget
                $script:guiManualSwitchWaitOutcome =
                    [string]$script:guiManualSwitchPresentation.State
                Close-QiehaoManualSwitchWaitDialog
            }.GetNewClosure())
            try {
                $null = $script:guiManualSwitchWaitDialog.Dispatcher.BeginInvoke(
                    [System.Windows.Threading.DispatcherPriority]::Background,
                    $switchAction
                )
            }
            catch {
                $script:guiManualSwitchResult =
                    ConvertTo-QiehaoOperationResult -ResultCode 'SWITCH_FAILED'
                $script:guiManualSwitchPresentation =
                    Complete-QiehaoSwitchUiAfterBackend `
                        -Result $script:guiManualSwitchResult `
                        -TargetProfile $capturedTarget
                $script:guiManualSwitchWaitOutcome =
                    [string]$script:guiManualSwitchPresentation.State
                Close-QiehaoManualSwitchWaitDialog
            }
            return
        }

        $script:guiIsWriteOperationBusy = $false
        if ([string]$script:guiQuotaAsyncReason -ceq 'SwitchBefore') {
            Stop-QiehaoQuotaAsync
        }
        $script:guiManualSwitchWaitOutcome = switch ($FinalState) {
            'Running' { 'TimedOut' }
            'Cancelled' { 'Cancelled' }
            'Closing' { 'Closing' }
            default { 'Unknown' }
        }
        $nonSwitchState = switch ($script:guiManualSwitchWaitOutcome) {
            'TimedOut' { 'TimedOut' }
            'Cancelled' { 'Cancelled' }
            'Closing' { 'Closing' }
            default { 'Unknown' }
        }
        Set-QiehaoSwitchUiState -State $nonSwitchState
        if (-not $DialogAlreadyClosing) {
            Close-QiehaoManualSwitchWaitDialog
        }
    }

    function Start-QiehaoManualSwitchWaitTimer {
        param([ValidateRange(0.001, 3600)][double]$TimeoutSeconds = 90)
        try {
            $script:guiManualSwitchWaitRuntime = New-QiehaoWaitTimerRuntime `
                -IntervalMilliseconds 500 -TimeoutSeconds $TimeoutSeconds `
                -ClosingProvider { [bool]$script:guiIsClosing } `
                -ProbeProvider {
                    $status = ConvertTo-QiehaoCodexStatus `
                        -ProcessState (Test-CodexProcessesStopped)
                    if ($status -ceq '已退出') {
                        if ([string]$script:guiQuotaAsyncReason -ceq
                            'SwitchBefore' -and
                            [bool]$script:guiQuotaCoordinator.
                                QueryInProgress) {
                            $script:guiManualSwitchCodexStopped = $true
                            Set-QiehaoCodexStatusVisual -Status '已退出'
                            Set-QiehaoSwitchQuotaStatus -Text (
                                'Codex 已安全退出。' +
                                "正在完成 '$script:guiQuotaRequestedProfile' " +
                                '的额度快照，随后自动切换……'
                            )
                            return 'Pending'
                        }
                        return 'Succeeded'
                    }
                    if ($status -ceq '未知') { return 'Unknown' }
                    return 'Pending'
                } `
                -CompletionAction {
                    param($Result, $Runtime)
                    switch ($Result) {
                        'Succeeded' {
                            Complete-QiehaoManualSwitchWait -FinalState 'Stopped'
                        }
                        'TimedOut' {
                            Complete-QiehaoManualSwitchWait -FinalState 'Running'
                        }
                        'Closing' {
                            Complete-QiehaoManualSwitchWait -FinalState 'Closing'
                        }
                        default {
                            Complete-QiehaoManualSwitchWait -FinalState 'Unknown'
                        }
                    }
                }
            $script:guiManualSwitchWaitTimer =
                $script:guiManualSwitchWaitRuntime.Timer
            $script:guiManualSwitchWaitTimerTickHandler =
                $script:guiManualSwitchWaitRuntime.TickHandler
            $null = Start-QiehaoWaitTimerRuntime `
                -Runtime $script:guiManualSwitchWaitRuntime
        }
        catch { Complete-QiehaoManualSwitchWait -FinalState 'Unknown' }
    }

    function Cancel-QiehaoManualSwitchWait {
        if (-not $script:guiManualSwitchWaitInProgress) { return }
        if ($null -ne $script:guiManualSwitchWaitDialog) {
            $script:guiManualSwitchWaitDialog.Close()
            return
        }
        Complete-QiehaoManualSwitchWait -FinalState 'Cancelled'
    }

    function Show-QiehaoManualSwitchWaitDialog {
        param(
            [Parameter(Mandatory = $true)][string]$TargetProfile,
            [ValidateRange(0.001, 3600)][double]$TimeoutSeconds = 90
        )
        Stop-QiehaoManualSwitchWaitTimer -Result 'Restarted'

        $dialog = New-Object System.Windows.Window
        $dialog.Title = Get-QiehaoGuiText -Key 'Dialog.Switch.Title' `
            -Fallback '切换账号'
        $dialog.Width = 540
        $dialog.Height = 340
        $dialog.MinWidth = 480
        $dialog.MinHeight = 310
        $dialog.WindowStartupLocation = 'CenterOwner'
        $dialog.ResizeMode = 'NoResize'
        $dialog.ShowInTaskbar = $false
        $dialog.Owner = $window
        $dialog.FontFamily = $window.FontFamily
        $dialog.FontSize = $window.FontSize
        foreach ($resourceKey in @(
            'DialogBackgroundBrush', 'DialogCardBrush', 'DialogBorderBrush',
            'DialogForegroundBrush', 'DialogSecondaryBrush',
            'DialogAccentBrush', 'DialogWarningBrush', 'DialogSuccessBrush',
            'DialogButtonBackgroundBrush', 'DialogButtonForegroundBrush',
            'DialogButtonBorderBrush', 'TextPrimaryBrush',
            'TextSecondaryBrush', 'ButtonFaceBrush', 'ButtonHoverBrush',
            'ButtonPressedBrush', 'ButtonDisabledBrush', 'PanelBorderBrush',
            'AccentBrush'
        )) {
            $dialog.Resources[$resourceKey] = $window.Resources[$resourceKey]
        }
        $dialog.Background = $dialog.Resources['DialogBackgroundBrush']
        $dialog.Foreground = $dialog.Resources['DialogForegroundBrush']

        $root = New-Object System.Windows.Controls.Grid
        $root.Margin = 0
        foreach ($height in @('Auto', '14', '*', '16', 'Auto')) {
            $row = New-Object System.Windows.Controls.RowDefinition
            $row.Height = $height
            $root.RowDefinitions.Add($row)
        }
        $targetText = New-Object System.Windows.Controls.TextBlock
        $targetText.Text = Format-QiehaoGuiText `
            -Key 'Dialog.Switch.Target' -Arguments @($TargetProfile) `
            -Fallback '目标账号：{0}'
        $targetText.FontSize = 17
        $targetText.FontWeight = 'Bold'
        $targetText.Foreground = $dialog.Resources['DialogAccentBrush']
        [System.Windows.Controls.Grid]::SetRow($targetText, 0)
        $root.Children.Add($targetText) | Out-Null

        $instructionsPanel = New-Object System.Windows.Controls.StackPanel
        $instructionsPanel.Orientation = 'Vertical'
        $instructionHeading = New-Object System.Windows.Controls.TextBlock
        $instructionHeading.Text = Get-QiehaoGuiText `
            -Key 'Dialog.Switch.Heading' -Fallback '请在 Codex 中安全退出'
        $instructionHeading.FontSize = 16
        $instructionHeading.FontWeight = 'Bold'
        $instructionHeading.Foreground =
            $dialog.Resources['DialogForegroundBrush']
        $instructionHeading.Margin = '0,0,0,10'
        $instructionsText = New-Object System.Windows.Controls.TextBlock
        $instructionsText.Text = Get-QiehaoGuiText `
            -Key 'Dialog.Switch.Instructions' `
            -Fallback "「文件 → 退出」`n或`n系统托盘 → 「Quit Codex」`n`n检测到完全退出后，本工具将自动继续切换。"
        $instructionsText.TextWrapping = 'Wrap'
        $instructionsText.Foreground = $dialog.Resources['DialogForegroundBrush']
        $instructionsPanel.Children.Add($instructionHeading) | Out-Null
        $instructionsPanel.Children.Add($instructionsText) | Out-Null
        [System.Windows.Controls.Grid]::SetRow($instructionsPanel, 2)
        $root.Children.Add($instructionsPanel) | Out-Null

        $statusText = New-Object System.Windows.Controls.TextBlock
        $statusText.Text = if (
            [string]$script:guiQuotaAsyncReason -ceq 'SwitchBefore'
        ) {
            Format-QiehaoGuiText -Key 'Quota.SwitchBeforeSavingWithExit' `
                -Arguments @($script:guiQuotaRequestedProfile) `
                -Fallback "正在保存 '{0}' 的最新额度快照，同时等待 Codex 安全退出……"
        }
        else {
            Get-QiehaoGuiText -Key 'Dialog.Switch.Waiting' `
                -Fallback '正在等待 Codex 安全退出……'
        }
        $statusText.FontWeight = 'Bold'
        $statusText.Foreground = $dialog.Resources['DialogWarningBrush']
        $statusText.VerticalAlignment = 'Center'
        $cancelButton = New-Object System.Windows.Controls.Button
        $cancelButton.Content = Get-QiehaoGuiText -Key 'Button.Cancel' `
            -Fallback '取消'
        $cancelButton.MinWidth = 90
        $cancelButton.MinHeight = 34
        $cancelButton.HorizontalAlignment = 'Right'
        $cancelButton.VerticalAlignment = 'Bottom'
        $cancelButton.IsCancel = $false
        $cancelButton.Margin = '0,0,0,0'
        $cancelButton.Style = $window.Resources['PrimaryButtonStyle']
        $cancelButton.Background =
            $dialog.Resources['DialogButtonBackgroundBrush']
        $cancelButton.Foreground =
            $dialog.Resources['DialogButtonForegroundBrush']
        $cancelButton.BorderBrush = $dialog.Resources['DialogButtonBorderBrush']

        $footer = New-Object System.Windows.Controls.Grid
        $footer.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition))
        $cancelColumn = New-Object System.Windows.Controls.ColumnDefinition
        $cancelColumn.Width = 'Auto'
        $footer.ColumnDefinitions.Add($cancelColumn)
        [System.Windows.Controls.Grid]::SetColumn($statusText, 0)
        [System.Windows.Controls.Grid]::SetColumn($cancelButton, 1)
        $footer.Children.Add($statusText) | Out-Null
        $footer.Children.Add($cancelButton) | Out-Null
        [System.Windows.Controls.Grid]::SetRow($footer, 4)
        $root.Children.Add($footer) | Out-Null

        $card = New-Object System.Windows.Controls.Border
        $card.Background = $dialog.Resources['DialogCardBrush']
        $card.BorderBrush = $dialog.Resources['DialogBorderBrush']
        $card.BorderThickness = 1
        $card.CornerRadius = 14
        $card.Padding = 20
        $card.Effect = New-Object System.Windows.Media.Effects.DropShadowEffect
        $card.Effect.BlurRadius = 18
        $card.Effect.ShadowDepth = 4
        $card.Effect.Opacity = 0.28
        $card.Child = $root
        $dialogShell = New-Object System.Windows.Controls.Grid
        $dialogShell.Margin = 18
        $dialogShell.Children.Add($card) | Out-Null
        $dialog.Content = $dialogShell
        $script:guiManualSwitchWaitDialog = $dialog
        $script:guiManualSwitchWaitStatusText = $statusText
        $script:guiManualSwitchWaitCancelButton = $cancelButton
        $cancelButton.Add_Click({ Cancel-QiehaoManualSwitchWait })
        $dialog.Add_Loaded(({
            Start-QiehaoManualSwitchWaitTimer -TimeoutSeconds $TimeoutSeconds
        }.GetNewClosure()))
        $dialog.Add_Closing({
            if (-not $script:guiManualSwitchWaitInternalClose -and
                $script:guiManualSwitchWaitInProgress) {
                Complete-QiehaoManualSwitchWait -FinalState 'Cancelled' `
                    -DialogAlreadyClosing
            }
        })

        $script:guiPendingAction = 'Switch'
        $script:guiPendingTargetProfile = $TargetProfile
        $script:guiManualSwitchWaitInProgress = $true
        $script:guiManualSwitchWaitOutcome = 'Waiting'
        $script:guiManualSwitchCodexStopped = $false
        $script:guiManualSwitchResult = $null
        $script:guiManualSwitchPresentation = $null
        $script:guiManualSwitchWaitInternalClose = $false
        Set-QiehaoWriteBusy -Value $true `
            -StatusText (Format-QiehaoGuiText `
                -Key 'Dialog.Switch.WaitingTarget' `
                -Arguments @($TargetProfile) `
                -Fallback "正在等待 Codex 安全退出，随后自动切换到 '{0}'……")
        Set-QiehaoSwitchUiState -State 'WaitingForCodexExit' `
            -TargetProfile $TargetProfile
        if ([string]$script:guiQuotaAsyncReason -ceq 'SwitchBefore') {
            Set-QiehaoSwitchQuotaStatus -Text $statusText.Text
        }
        Stop-QiehaoProcessMonitor

        try { [void]$dialog.ShowDialog() }
        catch {
            if ($script:guiManualSwitchWaitInProgress) {
                Complete-QiehaoManualSwitchWait -FinalState 'Unknown'
            }
        }
        finally {
            if ($script:guiManualSwitchWaitInProgress) {
                Complete-QiehaoManualSwitchWait -FinalState 'Cancelled'
            }
        }

        $outcome = $script:guiManualSwitchWaitOutcome
        $switchResult = $script:guiManualSwitchResult
        $switchPresentation = $script:guiManualSwitchPresentation
        $script:guiManualSwitchWaitDialog = $null
        $script:guiManualSwitchWaitStatusText = $null
        $script:guiManualSwitchWaitCancelButton = $null
        $script:guiManualSwitchWaitInternalClose = $false
        $script:guiManualSwitchResult = $null
        $script:guiManualSwitchPresentation = $null
        if ($script:guiIsClosing) { return }

        Start-QiehaoProcessMonitor
        Set-QiehaoWriteBusy -Value $false
        switch ($outcome) {
            'SwitchSucceeded' {
                Show-QiehaoSwitchCompletionMessage -Result $switchResult `
                    -Presentation $switchPresentation `
                    -TargetProfile $TargetProfile
            }
            'SwitchSucceededUiRefreshFailed' {
                Show-QiehaoSwitchCompletionMessage -Result $switchResult `
                    -Presentation $switchPresentation `
                    -TargetProfile $TargetProfile
            }
            'SwitchFailed' {
                Show-QiehaoSwitchCompletionMessage -Result $switchResult `
                    -Presentation $switchPresentation `
                    -TargetProfile $TargetProfile
            }
            'TimedOut' {
                Set-QiehaoCodexStatusVisual -Status '运行中'
                Show-QiehaoSafeMessage `
                    -Message (Get-QiehaoGuiText -Key 'Switch.WaitTimeout' `
                        -Fallback '等待超时，尚未检测到 Codex 完全退出。未执行账号切换。') `
                    -Severity Warning
            }
            'Unknown' {
                Set-QiehaoCodexStatusVisual -Status '未知'
                Show-QiehaoSafeMessage `
                    -Message (Get-QiehaoGuiText -Key 'Switch.UnknownExit' `
                        -Fallback '无法确认 Codex 是否完全退出，本次未执行账号切换。') `
                    -Severity Warning
            }
            'Cancelled' {
                Set-QiehaoSwitchUiState -State 'Cancelled'
            }
        }
        Update-QiehaoActionButtons
    }

    function Complete-QiehaoSwitchUiAfterBackend {
        param(
            [Parameter(Mandatory = $true)][object]$Result,
            [Parameter(Mandatory = $true)][string]$TargetProfile
        )
        try {
            return Invoke-QiehaoSwitchUiCompletion -Result $Result `
                -TargetProfile $TargetProfile `
                -RefreshProvider {
                    param($ExpectedProfile)
                    return [bool](Invoke-QiehaoReadOnlyRefresh `
                        -ExpectedActiveProfile $ExpectedProfile -PassThru)
                } `
                -BusyProvider {
                    param($IsBusy)
                    Set-QiehaoWriteBusy -Value ([bool]$IsBusy)
                } `
                -StateProvider {
                    param($State, $Profile)
                    Set-QiehaoSwitchUiState -State $State `
                        -TargetProfile $Profile
                }
        }
        catch {
            $backendSucceeded = (
                [bool]$Result.IsSuccess -and
                [string]$Result.ResultCode -ceq 'SWITCH_SUCCESS'
            )
            Set-QiehaoWriteBusy -Value $false
            $fallbackState = if ($backendSucceeded) {
                'SwitchSucceededUiRefreshFailed'
            }
            else {
                'SwitchFailed'
            }
            Set-QiehaoSwitchUiState -State $fallbackState `
                -TargetProfile $TargetProfile
            return [pscustomobject]@{
                State = $fallbackState
                BackendSucceeded = $backendSucceeded
                UiRefreshSucceeded = $false
                TargetProfile = $TargetProfile
            }
        }
    }

    function Show-QiehaoSwitchCompletionMessage {
        param(
            [Parameter(Mandatory = $true)][object]$Result,
            [Parameter(Mandatory = $true)][object]$Presentation,
            [Parameter(Mandatory = $true)][string]$TargetProfile
        )
        switch ([string]$Presentation.State) {
            'SwitchSucceeded' {
                Show-QiehaoSafeMessage `
                    -Message (Format-QiehaoGuiText `
                        -Key 'Switch.SuccessCurrent' `
                        -Arguments @($TargetProfile) `
                        -Fallback "切换成功。`n`n当前账号：{0}")
                $null = Start-QiehaoQuotaAsync -Reason SwitchAfter
            }
            'SwitchSucceededUiRefreshFailed' {
                Show-QiehaoSafeMessage `
                    -Message (Get-QiehaoGuiText `
                        -Key 'Switch.RefreshFailed' `
                        -Fallback '账号切换已经成功，但界面状态刷新失败。请点击“刷新”重新读取当前状态。') `
                    -Severity Warning
            }
            default { Show-QiehaoOperationResult -Result $Result }
        }
    }

    function Show-QiehaoSwitchResult {
        param(
            [Parameter(Mandatory = $true)][object]$Result,
            [Parameter(Mandatory = $true)][string]$TargetProfile
        )
        $presentation = Complete-QiehaoSwitchUiAfterBackend `
            -Result $Result -TargetProfile $TargetProfile
        Show-QiehaoSwitchCompletionMessage -Result $Result `
            -Presentation $presentation -TargetProfile $TargetProfile
    }

    function Invoke-QiehaoSwitchCore {
        param(
            [Parameter(Mandatory = $true)][string]$TargetProfile,
            [switch]$DeferPresentation,
            [switch]$SkipQuotaBefore
        )
        try {
            if (-not $SkipQuotaBefore) {
                try { Invoke-QiehaoQuotaBeforeSwitch }
                catch {
                    $refreshStatusText.Text =
                        Get-QiehaoQuotaUiTextSafe -Key 'SwitchOldFailed'
                }
            }
            $result = Invoke-QiehaoOperationProvider -Operation 'SWITCH' `
                -Provider { param($Name) Switch-CodexAccountProfile -Name $Name } `
                -ArgumentList @($TargetProfile)
            if ($DeferPresentation) { return $result }
            Show-QiehaoSwitchResult -Result $result -TargetProfile $TargetProfile
            return $result
        }
        finally {
            if (-not $DeferPresentation) {
                Set-QiehaoWriteBusy -Value $false
            }
        }
    }

    function Invoke-QiehaoSwitchSelectedProfile {
        $targetProfile = Get-QiehaoSelectedProfileName
        if ($script:guiIsWriteOperationBusy) {
            Show-QiehaoOperationResult -Result (
                ConvertTo-QiehaoOperationResult -ResultCode 'OPERATION_BUSY'
            )
            return
        }
        if ([string]::IsNullOrWhiteSpace($targetProfile)) {
            Show-QiehaoOperationResult -Result (
                ConvertTo-QiehaoOperationResult -ResultCode 'PROFILE_SELECTION_REQUIRED'
            )
            return
        }
        if ($targetProfile.Equals($script:guiCurrentActiveProfile,
            [StringComparison]::OrdinalIgnoreCase)) {
            Show-QiehaoOperationResult -Result (
                ConvertTo-QiehaoOperationResult -ResultCode 'ALREADY_ACTIVE'
            )
            return
        }
        # A user-requested Switch takes priority over an in-flight quota read.
        Stop-QiehaoQuotaAsync
        $liveStatus = Get-QiehaoLiveCodexStatus
        if ($liveStatus -ceq '未知') {
            Show-QiehaoOperationResult -Result (
                ConvertTo-QiehaoOperationResult -ResultCode 'CODEX_EXIT_STATE_UNKNOWN'
            )
            return
        }
        if ($liveStatus -ceq '运行中') {
            $null = Start-QiehaoQuotaAsync -Reason SwitchBefore
            try {
                Show-QiehaoManualSwitchWaitDialog -TargetProfile $targetProfile
            }
            catch {
                Stop-QiehaoManualSwitchWaitTimer -Result 'Error'
                Stop-QiehaoQuotaAsync
                if ($null -ne $script:guiManualSwitchWaitDialog) {
                    $script:guiManualSwitchWaitInternalClose = $true
                    try { $script:guiManualSwitchWaitDialog.Close() }
                    catch { }
                }
                $script:guiPendingAction = $null
                $script:guiPendingTargetProfile = $null
                $script:guiManualSwitchWaitInProgress = $false
                $script:guiManualSwitchWaitDialog = $null
                $script:guiManualSwitchWaitStatusText = $null
                $script:guiManualSwitchWaitCancelButton = $null
                $script:guiIsWriteOperationBusy = $false
                Start-QiehaoProcessMonitor
                Update-QiehaoActionButtons
                Show-QiehaoSafeMessage `
                    -Message (Get-QiehaoGuiText -Key 'Switch.DialogFailed' `
                        -Fallback '无法启动安全等待窗口，本次未执行账号切换。') `
                    -Severity Warning
            }
            return
        }
        Set-QiehaoWriteBusy -Value $true `
            -StatusText (Format-QiehaoGuiText `
                -Key 'Quota.SwitchBeforeSaving' `
                -Arguments @($script:guiCurrentActiveProfile) `
                -Fallback "正在保存 '{0}' 的最新额度快照……")
        $script:guiPendingAction = 'SwitchAfterQuota'
        $script:guiPendingTargetProfile = $targetProfile
        if (Start-QiehaoQuotaAsync -Reason SwitchBefore) {
            Set-QiehaoSwitchQuotaStatus -Text (Format-QiehaoGuiText `
                -Key 'Quota.SwitchBeforeSaving' `
                -Arguments @($script:guiCurrentActiveProfile) `
                -Fallback "正在保存 '{0}' 的最新额度快照……")
            return
        }
        Continue-QiehaoStoppedSwitchAfterQuota
    }

    function Invoke-QiehaoVerifySelectedProfile {
        if ($script:guiIsWriteOperationBusy) {
            Show-QiehaoOperationResult -Result (
                ConvertTo-QiehaoOperationResult -ResultCode 'OPERATION_BUSY'
            )
            return
        }
        $selectedProfile = Get-QiehaoSelectedProfileName
        Set-QiehaoWriteBusy -Value $true -StatusText (
            Get-QiehaoGuiText -Key 'Verify.Working' `
                -Fallback '正在验证账号…'
        )
        try {
            $verifyResult = Invoke-QiehaoVerifyRequest `
                -SelectedProfile $selectedProfile `
                -CodexStatus (Get-QiehaoLiveCodexStatus) `
                -VerifyProvider { param($ProfileName) Test-CodexProfile -Name $ProfileName }
            if ($verifyResult.CoreCalled -and
                -not [string]::IsNullOrWhiteSpace($selectedProfile)) {
                $script:guiVerificationStates[$selectedProfile] = `
                    [string]$verifyResult.VerificationStatus
                $script:guiVerificationStateCodes[$selectedProfile] = if (
                    [string]$verifyResult.ResultCode -ceq
                        'PROFILE_VERIFY_SUCCESS'
                ) { 'Verified' } else { 'Failed' }
            }
            $message = [string]$verifyResult.Message
            if ($verifyResult.ResultCode -ceq 'PROFILE_VERIFY_SUCCESS') {
                $message = Format-QiehaoGuiText -Key 'Verify.Success' `
                    -Arguments @($selectedProfile) `
                    -Fallback "账号：{0}`n状态：已验证"
            }
            Show-QiehaoSafeMessage -Message $message
            if ($verifyResult.CoreCalled) { Invoke-QiehaoReadOnlyRefresh }
        }
        finally { Set-QiehaoWriteBusy -Value $false }
    }

    function Invoke-QiehaoRenameSelectedProfile {
        if ($script:guiIsWriteOperationBusy) { return }
        $oldName = Get-QiehaoSelectedProfileName
        if ([string]::IsNullOrWhiteSpace($oldName)) { return }
        $newName = Show-QiehaoNameDialog `
            -Title (Get-QiehaoGuiText -Key 'Dialog.Rename.Title' `
                -Fallback '重命名账号') `
            -Prompt (Get-QiehaoGuiText -Key 'Dialog.Name.New' `
                -Fallback '新名称：') -CurrentName $oldName
        if ([string]::IsNullOrWhiteSpace($newName)) { return }
        Stop-QiehaoQuotaAsync
        Set-QiehaoWriteBusy -Value $true -StatusText (
            Get-QiehaoGuiText -Key 'Account.Renaming' `
                -Fallback '正在重命名账号…'
        )
        try {
            $quotaCacheWarning = $null
            $result = Invoke-QiehaoOperationProvider -Operation 'RENAME' `
                -Provider {
                    param($From, $To)
                    Rename-CodexProfile -OldName $From -NewName $To
                } -ArgumentList @($oldName, $newName)
            if ($result.IsSuccess -and
                $script:guiVerificationStates.ContainsKey($oldName)) {
                $script:guiVerificationStates[$newName] = $script:guiVerificationStates[$oldName]
                $script:guiVerificationStates.Remove($oldName)
            }
            if ($result.IsSuccess -and
                $script:guiVerificationStateCodes.ContainsKey($oldName)) {
                $script:guiVerificationStateCodes[$newName] =
                    $script:guiVerificationStateCodes[$oldName]
                $script:guiVerificationStateCodes.Remove($oldName)
            }
            if ($result.IsSuccess -and $script:guiQuotaModulesAvailable) {
                $quotaRename = Rename-QiehaoQuotaCacheProfile `
                    -StateDirectory $stateDirectory `
                    -Cache $script:guiQuotaCache `
                    -OldName $oldName -NewName $newName
                if ($quotaRename.Succeeded) {
                    $script:guiQuotaCache = $quotaRename.Cache
                    if (-not [string]::IsNullOrWhiteSpace(
                        $script:guiQuotaJustUpdatedProfile
                    ) -and $script:guiQuotaJustUpdatedProfile.Equals(
                        $oldName,
                        [StringComparison]::OrdinalIgnoreCase
                    )) {
                        $script:guiQuotaJustUpdatedProfile = $newName
                    }
                }
                else {
                    $quotaCacheWarning =
                        Get-QiehaoQuotaUiTextSafe -Key 'RenameCacheFailed'
                }
            }
            Show-QiehaoOperationResult -Result $result
            if ($result.RefreshRequired) { Invoke-QiehaoReadOnlyRefresh }
            if (-not [string]::IsNullOrWhiteSpace($quotaCacheWarning)) {
                $refreshStatusText.Text = $quotaCacheWarning
            }
        }
        finally { Set-QiehaoWriteBusy -Value $false }
    }

    function Invoke-QiehaoDeleteSelectedProfile {
        if ($script:guiIsWriteOperationBusy) { return }
        $profileName = Get-QiehaoSelectedProfileName
        if ([string]::IsNullOrWhiteSpace($profileName) -or
            $profileName.Equals($script:guiCurrentActiveProfile,
                [StringComparison]::OrdinalIgnoreCase)) { return }
        $message = Format-QiehaoGuiText -Key 'Dialog.Delete.Message' `
            -Arguments @($profileName) `
            -Fallback "确定删除本地账号 '{0}' 吗？"
        if (-not (Show-QiehaoChoiceDialog `
            -Title (Get-QiehaoGuiText -Key 'Dialog.Delete.Title' `
                -Fallback '删除本地账号') `
            -Message $message `
            -ConfirmText (Get-QiehaoGuiText -Key 'Dialog.Delete.Confirm' `
                -Fallback '删除'))) { return }
        Stop-QiehaoQuotaAsync
        Set-QiehaoWriteBusy -Value $true -StatusText (
            Get-QiehaoGuiText -Key 'Account.Deleting' `
                -Fallback '正在删除本地账号…'
        )
        try {
            $quotaCacheWarning = $null
            $result = Invoke-QiehaoOperationProvider -Operation 'DELETE' `
                -Provider { param($Name) Remove-CodexProfile -Name $Name -ConfirmDelete } `
                -ArgumentList @($profileName)
            if ($result.IsSuccess) {
                $script:guiVerificationStates.Remove($profileName)
                $script:guiVerificationStateCodes.Remove($profileName)
            }
            if ($result.IsSuccess -and $script:guiQuotaModulesAvailable) {
                $quotaDelete = Remove-QiehaoQuotaCacheProfile `
                    -StateDirectory $stateDirectory `
                    -Cache $script:guiQuotaCache `
                    -ProfileName $profileName
                if ($quotaDelete.Succeeded) {
                    $script:guiQuotaCache = $quotaDelete.Cache
                }
                else {
                    $quotaCacheWarning =
                        Get-QiehaoQuotaUiTextSafe -Key 'DeleteCacheFailed'
                }
            }
            Show-QiehaoOperationResult -Result $result
            if ($result.RefreshRequired) { Invoke-QiehaoReadOnlyRefresh }
            if (-not [string]::IsNullOrWhiteSpace($quotaCacheWarning)) {
                $refreshStatusText.Text = $quotaCacheWarning
            }
        }
        finally { Set-QiehaoWriteBusy -Value $false }
    }

    function Start-QiehaoAddWizard {
        try {
            $activeName = $null
            try {
                $activeState = Get-CodexActiveProfile
                $activeName = [string]$activeState.ActiveProfile
            }
            catch {
                if ([string]$_.Exception.Message -ceq 'ACTIVE_PROFILE_NOT_INITIALIZED') {
                    $activeName = $null
                }
                else {
                    Show-QiehaoSafeMessage `
                        -Message (Get-QiehaoGuiText `
                            -Key 'Account.AddReadActiveFailed' `
                            -Fallback '无法安全读取当前账号状态，已停止添加流程。') `
                        -Severity Warning
                    return
                }
            }
            if (-not [string]::IsNullOrWhiteSpace($activeName)) {
                $saveResult = Invoke-QiehaoOperationProvider `
                    -Operation 'SAVE_ACTIVE' -Provider { Save-CodexActiveProfile }
                if (-not $saveResult.IsSuccess) {
                    Show-QiehaoOperationResult -Result $saveResult
                    return
                }
            }
            $instructions = Get-QiehaoGuiText `
                -Key 'Account.AddInstructions' `
                -Fallback '请使用 Codex Desktop 官方登录流程登录新账号，完成后正常退出 Codex。'
            $ready = Show-QiehaoChoiceDialog `
                -Title (Get-QiehaoGuiText -Key 'Dialog.Add.Title' `
                    -Fallback '添加账号') `
                -Message $instructions `
                -ConfirmText (Get-QiehaoGuiText -Key 'Account.AddReady' `
                    -Fallback '我已登录新账号并退出')
            if (-not $ready) { return }
            $liveStatus = Get-QiehaoLiveCodexStatus
            if ($liveStatus -ceq '运行中') {
                Show-QiehaoSafeMessage -Message (Get-QiehaoGuiText `
                    -Key 'Account.AddQuitBeforeCapture' `
                    -Fallback '请先正常退出 Codex，再采集新账号。') `
                    -Severity Warning
                return
            }
            if ($liveStatus -cne '已退出') {
                Show-QiehaoSafeMessage `
                    -Message (Get-QiehaoGuiText `
                        -Key 'Account.AddExitUnknown' `
                        -Fallback '无法确认 Codex 是否完全退出，本次未添加账号。') `
                    -Severity Warning
                return
            }
            $profileName = Show-QiehaoNameDialog `
                -Title (Get-QiehaoGuiText -Key 'Dialog.Add.Title' `
                    -Fallback '添加账号') `
                -Prompt (Get-QiehaoGuiText -Key 'Dialog.Name.Local' `
                    -Fallback '本地名称：')
            if ([string]::IsNullOrWhiteSpace($profileName)) { return }
            $result = Invoke-QiehaoOperationProvider -Operation 'ADD' `
                -Provider { param($Name) Add-CodexProfile -Name $Name } `
                -ArgumentList @($profileName)
            Show-QiehaoOperationResult -Result $result
            if ($result.RefreshRequired) { Invoke-QiehaoReadOnlyRefresh }
        }
        finally { Set-QiehaoWriteBusy -Value $false }
    }

    function Invoke-QiehaoAddAccount {
        if ($script:guiIsWriteOperationBusy) { return }
        $liveStatus = Get-QiehaoLiveCodexStatus
        if ($liveStatus -ceq '未知') {
            Show-QiehaoSafeMessage -Message (Get-QiehaoGuiText `
                -Key 'Common.CodexUnknown' `
                -Fallback '无法确认 Codex 进程状态，请重新检测。') `
                -Severity Warning
            return
        }
        Stop-QiehaoQuotaAsync
        Set-QiehaoWriteBusy -Value $true -StatusText (
            Get-QiehaoGuiText -Key 'Account.AddPreparing' `
                -Fallback '准备添加账号…'
        )
        if ($liveStatus -ceq '运行中') {
            Set-QiehaoWriteBusy -Value $false
            Show-QiehaoSafeMessage `
                -Message (Get-QiehaoGuiText `
                    -Key 'Account.AddQuitBeforeStart' `
                    -Fallback '请先从 Codex 菜单“文件 → 退出”或系统托盘选择“退出”，确认状态变为“已退出”后再添加账号。') `
                -Severity Warning
            return
        }
        Start-QiehaoAddWizard
    }

    function Get-QiehaoDataGridRowFromSource {
        param([AllowNull()][object]$Source)
        $current = $Source -as [System.Windows.DependencyObject]
        while ($null -ne $current) {
            if ($current -is [System.Windows.Controls.DataGridRow]) { return $current }
            if ($current -eq $profilesGrid) { return $null }
            try { $current = [System.Windows.Media.VisualTreeHelper]::GetParent($current) }
            catch { return $null }
        }
        return $null
    }

    $preference = if ($SelfTest) {
        [pscustomobject]@{
            Background = '01-blue-glass'; Language = 'zh-CN'
            IsValid = $true; UsedDefault = $true
        }
    } else { Read-QiehaoUiPreferences -StateDirectory $stateDirectory }
    $script:guiLanguage = if ($script:guiLocalizationAvailable) {
        Resolve-QiehaoLanguage -Language ([string]$preference.Language)
    }
    else { 'zh-CN' }
    if ($script:guiLocalizationAvailable) {
        $languages = @(Get-QiehaoSupportedLanguages)
        $languageComboBox.ItemsSource = $languages
        $languageComboBox.SelectedItem = @($languages | Where-Object {
            [string]$_.Code -ceq $script:guiLanguage
        } | Select-Object -First 1)[0]
    }
    else {
        $languageComboBox.IsEnabled = $false
    }
    $themes = @(Get-QiehaoBackgroundThemes)
    $themeComboBox.ItemsSource = $themes
    $startupTheme = @($themes | Where-Object {
        [string]$_.Id -ceq [string]$preference.Background
    } | Select-Object -First 1)
    if ($startupTheme.Count -ne 1) {
        $startupTheme = @($themes | Where-Object {
            [string]$_.Id -ceq '01-blue-glass'
        } | Select-Object -First 1)
    }
    if ($startupTheme.Count -ne 1) { throw 'GUI_DEFAULT_THEME_NOT_FOUND' }
    $startupTheme = $startupTheme[0]
    $themeComboBox.SelectedItem = $startupTheme
    $startupImageResult = Set-QiehaoTheme -Theme $startupTheme
    $themeComboBox.Add_SelectionChanged({
        if ($script:guiThemePersistenceReady -and
            $null -ne $themeComboBox.SelectedItem) {
            $selectedTheme = $themeComboBox.SelectedItem
            $null = Set-QiehaoTheme -Theme $selectedTheme -Persist
        }
    })
    $languageComboBox.Add_SelectionChanged({
        if ($script:guiLanguagePersistenceReady -and
            $null -ne $languageComboBox.SelectedItem) {
            $selectedLanguage = Resolve-QiehaoLanguage `
                -Language ([string]$languageComboBox.SelectedItem.Code)
            if ($selectedLanguage -cne $script:guiLanguage) {
                $script:guiLanguage = $selectedLanguage
                try {
                    $null = Write-QiehaoUiPreferences `
                        -StateDirectory $stateDirectory `
                        -Language $script:guiLanguage
                }
                catch { }
                Apply-QiehaoLocalization
            }
        }
    })

    if ($SelfTest) {
        $script:guiLaunchSettings = [pscustomobject]@{
            Mode = 'Auto'; CustomPath = ''; IsValid = $true; UsedDefault = $true
        }
        $script:guiLaunchTarget = Find-QiehaoCodexLaunchTarget -Mode Auto `
            -AppxApplications @([pscustomobject]@{
                PackageFamilyName = 'OpenAI.Codex_8wekyb3d8bbwe'
                ApplicationId = 'App'
            })
        $launchTargetText.Text = Format-QiehaoGuiText `
            -Key 'Launch.Target' `
            -Arguments @([string]$script:guiLaunchTarget.DisplayStatus) `
            -Fallback 'Codex 启动目标：{0}'
    }
    else {
        $script:guiLaunchSettings = Read-QiehaoLaunchSettings `
            -StateDirectory $stateDirectory
        $null = Resolve-QiehaoLaunchTarget
    }
    Apply-QiehaoLocalization

    if ($SelfTest) {
        $fakeProfiles = @(
            [pscustomobject]@{
                Profile = 'Plus'; Active = $true; Health = 'READY'
                AuthFile = 'PRESENT'; IdentityMarker = 'PRESENT'
                Metadata = 'VALID'; UpdatedAt = '2000-01-01T00:00:00Z'
            },
            [pscustomobject]@{
                Profile = 'Team'; Active = $false; Health = 'READY'
                AuthFile = 'PRESENT'; IdentityMarker = 'PRESENT'
                Metadata = 'VALID'; UpdatedAt = '2000-01-02T00:00:00Z'
            }
        )
        $snapshot = Get-QiehaoGuiSnapshot `
            -ListProvider { $fakeProfiles }.GetNewClosure() `
            -ActiveProvider { [pscustomobject]@{ ActiveProfile = 'Plus' } } `
            -ProcessProvider { [pscustomobject]@{ ReasonCode = 'CODEX_PROCESSES_STOPPED' } } `
            -ActiveIdentityProvider { [pscustomobject]@{ Result = 'ACTIVE_IDENTITY_CONFIRMED' } }
        Set-QiehaoSnapshot -Snapshot $snapshot
        if ($SimulateQuotaQueryFailure) {
            $script:guiQuotaCoordinator.QueryInProgress = $true
            $script:guiQuotaRequestedProfile =
                [string]$script:guiCurrentActiveProfile
            $script:guiQuotaAsyncReason = 'Manual'
            Complete-QiehaoQuotaAsync
        }
        if (@($profilesGrid.ItemsSource).Count -ne 2 -or
            $codexStatusText.Text -cne '已退出' -or
            $activeProfileText.Text -cne 'Plus' -or
            $identityStatusText.Text -cne '已确认' -or
            -not [bool]$script:guiLaunchTarget.Available -or
            $themes.Count -ne 5 -or -not $startupImageResult.Loaded) {
            throw 'GUI_SELFTEST_BINDING_FAILED'
        }
        if ($refreshQuotaButton.Content -cne
            (Get-QiehaoQuotaUiTextSafe -Key 'RefreshButton') -or
            $null -eq $profilesGrid.ItemsSource[0].PSObject.Properties[
                'QuotaSummary'
            ]) {
            throw 'GUI_SELFTEST_QUOTA_BINDING_FAILED'
        }
        if ($script:guiQuotaModulesAvailable -and
            [string]$profilesGrid.ItemsSource[0].QuotaSummary -cne
                (Get-QiehaoQuotaUiTextSafe -Key 'NoSnapshot')) {
            throw 'GUI_SELFTEST_NO_CACHE_PRESENTATION_FAILED'
        }
        if ($LocalizationLifecycleSelfTest) {
            $initialNames = @($script:guiAllProfileRows | ForEach-Object {
                [string]$_.Name
            }) -join '|'
            $initialActive = [string]$script:guiCurrentActiveProfile
            $initialThemeId = [string]$themeComboBox.SelectedItem.Id
            $initialQuotaJson = if ($null -eq $script:guiQuotaCache) {
                'NULL'
            }
            else { $script:guiQuotaCache | ConvertTo-Json -Depth 12 -Compress }
            $initialZhCnTextsCorrect = (
                $window.Title -ceq 'Codex 账号管理器' -and
                [string]$switchButton.Content -ceq '切换账号' -and
                [string]$profileColumn.Header -ceq '名称' -and
                $codexStatusText.Text -ceq '已退出'
            )

            $script:guiLanguage = 'en-US'
            Apply-QiehaoLocalization
            $switchToEnUsUpdatesWindowTitle =
                $window.Title -ceq 'Codex Account Manager'
            $switchToEnUsUpdatesButtons = (
                [string]$switchButton.Content -ceq 'Switch Account' -and
                [string]$refreshQuotaButton.Content -ceq 'Refresh Quota' -and
                [string]$launchSettingsButton.Content -ceq 'Launch Settings'
            )
            $switchToEnUsUpdatesDataGridHeaders = (
                [string]$profileColumn.Header -ceq 'Name' -and
                [string]$currentColumn.Header -ceq 'Current' -and
                [string]$quotaColumn.Header -ceq 'Quota Snapshot'
            )
            $switchToEnUsUpdatesStatus = (
                $codexStatusText.Text -ceq 'Stopped' -and
                $identityStatusText.Text -ceq 'Confirmed' -and
                $refreshStatusText.Text -ceq 'Status refreshed.'
            )
            $switchToEnUsUpdatesQuotaTooltip = (
                [string]$profilesGrid.ItemsSource[0].QuotaSummary -ceq
                    'No quota snapshot' -and
                [string]$profilesGrid.ItemsSource[0].QuotaToolTip -match
                    '^The current account has no quota snapshot'
            )

            Set-QiehaoCodexStatusVisual -Status '运行中'
            $runningEn = [string]$codexStatusText.Text
            Set-QiehaoCodexStatusVisual -Status '已退出'
            $stoppedEn = [string]$codexStatusText.Text
            Set-QiehaoCodexStatusVisual -Status '未知'
            $unknownEn = [string]$codexStatusText.Text
            $dynamicCodexStatesEnUs = (
                $runningEn -ceq 'Running' -and
                $stoppedEn -ceq 'Stopped' -and
                $unknownEn -ceq 'Unknown'
            )
            $switchWaitingEn = Format-QiehaoGuiText `
                -Key 'Dialog.Switch.WaitingTarget' -Arguments @('Team')
            $switchSuccessEn = Format-QiehaoGuiText `
                -Key 'Switch.SuccessCurrent' -Arguments @('Team')
            $quotaFailureEn = Format-QiehaoQuotaFailureStatus `
                -BaseText (Get-QiehaoQuotaUiTextSafe `
                    -Key 'UpdateFailedRetry') `
                -FailureCode 'QUOTA_RATE_LIMITS_TIMEOUT'
            Set-QiehaoSwitchUiState -State 'Cancelled'
            $switchCancelledEn = [string]$refreshStatusText.Text
            $dynamicWorkflowStatesEnUs = (
                $switchWaitingEn -match 'switching to ''Team''' -and
                $switchSuccessEn -match 'Current account: Team' -and
                $switchCancelledEn -match 'Waiting was cancelled' -and
                $quotaFailureEn -match
                    'Error code: QUOTA_RATE_LIMITS_TIMEOUT'
            )
            Set-QiehaoLocalizedStatus `
                -Key 'Quota.UpdateFailedRetryWithCode' `
                -Arguments @('QUOTA_RATE_LIMITS_TIMEOUT')
            $quotaFailureStatusEn = [string]$refreshStatusText.Text

            $window.Measure((New-Object System.Windows.Size(1040, 690)))
            $window.Arrange((New-Object System.Windows.Rect(0, 0, 1040, 690)))
            $window.UpdateLayout()
            $unboundedLayoutSize = New-Object System.Windows.Size(
                [double]::PositiveInfinity,
                [double]::PositiveInfinity
            )
            $headerTitleText.Measure($unboundedLayoutSize)
            $englishHeaderFits = (
                $headerTitleText.DesiredSize.Width -gt 0 -and
                [double]$themeComboBox.Width -ge 132 -and
                [double]$languageComboBox.Width -ge 105 -and
                $headerTitleText.DesiredSize.Width + 390 -lt 1004
            )
            $englishLayoutButtons = @(
                $switchButton, $verifyButton, $refreshButton,
                $refreshQuotaButton, $addButton, $renameButton,
                $deleteButton, $launchCodexButton, $launchSettingsButton
            )
            foreach ($layoutButton in $englishLayoutButtons) {
                $layoutButton.Measure($unboundedLayoutSize)
            }
            $englishButtonsRemainSingleLine = @(
                $englishLayoutButtons
            ) | Where-Object {
                $_.DesiredSize.Height -gt 44 -or $_.DesiredSize.Width -gt 190
            }
            $xamlSourceForLayout =
                [IO.File]::ReadAllText($xamlPath)
            $englishLayoutMeasured = (
                $englishHeaderFits -and
                @($englishButtonsRemainSingleLine).Count -eq 0 -and
                $xamlSourceForLayout -match
                    '<Setter Property="MinHeight" Value="30"' -and
                $xamlSourceForLayout -match 'TextWrapping="NoWrap"'
            )
            if (-not $englishLayoutMeasured) {
                Write-Output (
                    'LocalizationLayoutDiagnostics=' +
                    'HeaderFits:' + $englishHeaderFits +
                    ';TitleDesiredWidth:' +
                    $headerTitleText.DesiredSize.Width +
                    ';ThemeWidth:' + $themeComboBox.Width +
                    ';LanguageWidth:' + $languageComboBox.Width +
                    ';OversizeButtons:' +
                    (@($englishButtonsRemainSingleLine | ForEach-Object {
                        [string]$_.Name
                    }) -join ',') +
                    ';RowContract:' + ($xamlSourceForLayout -match
                        '<Setter Property="MinHeight" Value="30"') +
                    ';NoWrapContract:' + ($xamlSourceForLayout -match
                        'TextWrapping="NoWrap"')
                )
            }

            $script:guiLanguage = 'zh-CN'
            Set-QiehaoCodexStatusVisual -Status '已退出'
            Apply-QiehaoLocalization
            $switchBackToZhCnWorks = (
                $window.Title -ceq 'Codex 账号管理器' -and
                [string]$switchButton.Content -ceq '切换账号' -and
                $codexStatusText.Text -ceq '已退出'
            )
            $dynamicQuotaStatusRedrawsAcrossLanguages = (
                $quotaFailureStatusEn -match
                    'Error code: QUOTA_RATE_LIMITS_TIMEOUT' -and
                $refreshStatusText.Text -match '额度更新失败' -and
                $refreshStatusText.Text -match
                    'QUOTA_RATE_LIMITS_TIMEOUT'
            )
            $finalQuotaJson = if ($null -eq $script:guiQuotaCache) {
                'NULL'
            }
            else { $script:guiQuotaCache | ConvertTo-Json -Depth 12 -Compress }
            $languageSwitchPreservesCoreState = (
                (@($script:guiAllProfileRows | ForEach-Object {
                    [string]$_.Name
                }) -join '|') -ceq $initialNames -and
                [string]$script:guiCurrentActiveProfile -ceq $initialActive -and
                [string]$themeComboBox.SelectedItem.Id -ceq $initialThemeId -and
                $finalQuotaJson -ceq $initialQuotaJson
            )
            $languageSwitchStartsNoBusinessAction = (
                $script:guiQuotaSelfTestQueryCount -eq 0 -and
                -not [bool]$script:guiQuotaCoordinator.QueryInProgress -and
                -not [bool]$script:guiIsWriteOperationBusy
            )

            $localizationChecks = [ordered]@{
                InitialZhCnTextsCorrect = $initialZhCnTextsCorrect
                SwitchToEnUsUpdatesWindowTitle =
                    $switchToEnUsUpdatesWindowTitle
                SwitchToEnUsUpdatesButtons = $switchToEnUsUpdatesButtons
                SwitchToEnUsUpdatesDataGridHeaders =
                    $switchToEnUsUpdatesDataGridHeaders
                SwitchToEnUsUpdatesStatus = $switchToEnUsUpdatesStatus
                SwitchToEnUsUpdatesQuotaTooltip =
                    $switchToEnUsUpdatesQuotaTooltip
                DynamicCodexStatesEnUs = $dynamicCodexStatesEnUs
                DynamicWorkflowStatesEnUs = $dynamicWorkflowStatesEnUs
                DynamicQuotaStatusRedrawsAcrossLanguages =
                    $dynamicQuotaStatusRedrawsAcrossLanguages
                SwitchBackToZhCnWorks = $switchBackToZhCnWorks
                LanguageSwitchPreservesCoreState =
                    $languageSwitchPreservesCoreState
                LanguageSwitchStartsNoBusinessAction =
                    $languageSwitchStartsNoBusinessAction
                EnglishWpfLayoutMeasured = $englishLayoutMeasured
            }
            foreach ($check in $localizationChecks.GetEnumerator()) {
                if (-not [bool]$check.Value) {
                    throw ('GUI_LOCALIZATION_SELFTEST_FAILED_' +
                        [string]$check.Key)
                }
                Write-Output ([string]$check.Key + '=True')
            }
            Write-Output 'GUI_LOCALIZATION_LIFECYCLE_SELFTEST_PASS'
            return
        }
        if ($QuotaAsyncLifecycleSelfTest) {
            $tempBase = [System.IO.Path]::GetFullPath(
                [System.IO.Path]::GetTempPath()
            ).TrimEnd([System.IO.Path]::DirectorySeparatorChar)
            $quotaAsyncTestDirectory = [System.IO.Path]::GetFullPath(
                (Join-Path $tempBase (
                    'qiehao-quota-async-' +
                    [Guid]::NewGuid().ToString('N')
                ))
            )
            if (-not $quotaAsyncTestDirectory.StartsWith(
                $tempBase + [System.IO.Path]::DirectorySeparatorChar,
                [StringComparison]::OrdinalIgnoreCase
            )) {
                throw 'GUI_QUOTA_ASYNC_TEST_PATH_INVALID'
            }
            [System.IO.Directory]::CreateDirectory(
                $quotaAsyncTestDirectory
            ) | Out-Null
            $originalStateDirectory = $stateDirectory

            function Wait-QiehaoQuotaSelfTestUntilIdle {
                param([int]$TimeoutMilliseconds = 4000)
                $deadline = [DateTime]::UtcNow.AddMilliseconds(
                    $TimeoutMilliseconds
                )
                while ([bool]$script:guiQuotaCoordinator.QueryInProgress -and
                    [DateTime]::UtcNow -lt $deadline) {
                    $frame = New-Object `
                        System.Windows.Threading.DispatcherFrame
                    $pumpTimer = New-Object `
                        System.Windows.Threading.DispatcherTimer
                    $pumpTimer.Interval =
                        [TimeSpan]::FromMilliseconds(25)
                    $pumpHandler = [System.EventHandler]({
                        param($sender, $eventArgs)
                        $sender.Stop()
                        $frame.Continue = $false
                    }.GetNewClosure())
                    $pumpTimer.Add_Tick($pumpHandler)
                    try {
                        $pumpTimer.Start()
                        [System.Windows.Threading.Dispatcher]::PushFrame(
                            $frame
                        )
                    }
                    finally {
                        $pumpTimer.Remove_Tick($pumpHandler)
                        $pumpTimer.Stop()
                    }
                }
                return (-not [bool]$script:guiQuotaCoordinator.QueryInProgress)
            }

            function Reset-QiehaoQuotaSelfTestScenario {
                param(
                    [Parameter(Mandatory = $true)][string]$Scenario,
                    [int]$HardCeilingMilliseconds = 2000
                )
                Stop-QiehaoQuotaAsync
                $script:guiQuotaCoordinator =
                    New-QiehaoQuotaCoordinatorState
                $script:guiQuotaCache = New-QiehaoEmptyQuotaCache
                $script:guiQuotaJustUpdatedProfile = $null
                $script:guiCurrentActiveProfile = 'Team'
                $activeProfileText.Text = 'Team'
                $script:guiIsClosing = $false
                $script:guiQuotaSelfTestScenario = $Scenario
                $script:guiQuotaSelfTestQueryCount = 0
                $script:guiQuotaSelfTestHardCeilingMilliseconds =
                    $HardCeilingMilliseconds
                $profileSearchTextBox.Text = ''
                Update-QiehaoQuotaRows
                Update-QiehaoActionButtons
            }

            try {
                $stateDirectory = $quotaAsyncTestDirectory

                Reset-QiehaoQuotaSelfTestScenario -Scenario 'Success'
                $successStarted = Start-QiehaoQuotaAsync -Reason Open
                $successBusyObserved = (
                    [bool]$script:guiQuotaCoordinator.QueryInProgress -and
                    -not [bool]$refreshQuotaButton.IsEnabled -and
                    $refreshStatusText.Text -ceq
                        (Get-QiehaoQuotaUiTextSafe -Key 'Updating')
                )
                $duplicateStartup = Start-QiehaoQuotaAsync -Reason Open
                $successIdle =
                    Wait-QiehaoQuotaSelfTestUntilIdle
                $lateStartup = Start-QiehaoQuotaAsync -Reason Open
                $successEntry = Get-QiehaoQuotaCacheSnapshot `
                    -Cache $script:guiQuotaCache -ProfileName 'Team'
                $successTeamRow = @($script:guiAllProfileRows |
                    Where-Object { $_.Name -ceq 'Team' })[0]
                $startupSuccessClearsBusy = (
                    $successStarted -and $successBusyObserved -and
                    $successIdle -and
                    -not [bool]$script:guiQuotaCoordinator.QueryInProgress
                )
                $startupSuccessReEnablesRefresh = (
                    [bool]$refreshQuotaButton.IsEnabled -and
                    $refreshStatusText.Text -ceq
                        (Get-QiehaoQuotaUiTextSafe -Key 'Updated')
                )
                $startupCompletionTimerStops = (
                    $script:guiQuotaCompletionTimerStopped -and
                    $null -eq $script:guiQuotaCompletionTimer
                )
                $startupCompletionHandlerRemoved = (
                    $script:guiQuotaCompletionHandlerRemoved -and
                    $null -eq $script:guiQuotaCompletionTickHandler
                )
                $startupAtMostOneQuery = (
                    $script:guiQuotaSelfTestQueryCount -eq 1 -and
                    -not $duplicateStartup -and -not $lateStartup
                )
                $startupUsesActiveProfile = (
                    $null -ne $successEntry -and
                    [string]$successTeamRow.QuotaSummary -ceq
                        '5h 35% · Week 15%'
                )
                $successDiagnostics = $script:guiQuotaLastDiagnostics
                $backgroundWorkerImportsQuotaClient = (
                    $null -ne $successDiagnostics -and
                    [bool]$successDiagnostics.ModulesLoaded -and
                    [bool]$successDiagnostics.QuotaClientCommandAvailable
                )
                $backgroundWorkerImportsQuotaParser = (
                    $null -ne $successDiagnostics -and
                    [bool]$successDiagnostics.QuotaParserCommandAvailable
                )
                $backgroundWorkerHasQuotaPublicCommand = (
                    $null -ne $successDiagnostics -and
                    [bool]$successDiagnostics.QuotaClientCommandAvailable
                )
                $backgroundWorkerReturnsStructuredResult = (
                    $null -ne $successDiagnostics -and
                    $null -ne $successEntry -and
                    $null -ne $successEntry.PSObject.Properties['Windows']
                )
                $backgroundWorkerOwnsDependencies = (
                    $null -ne $successDiagnostics -and
                    [bool]$successDiagnostics.CodexAuthReferenceValid -and
                    [bool]$successDiagnostics.ModulesLoaded
                )
                $workerOutputCountOne = (
                    $script:guiQuotaWorkerOutputCount -eq 1 -and
                    [int]$successDiagnostics.WorkerOutputCount -eq 1 -and
                    [int]$successDiagnostics.ProviderOutputCount -eq 1
                )
                $workerSnapshotSurvivesEndInvoke = (
                    $null -ne $successEntry -and
                    @($successEntry.Windows).Count -eq 2
                )
                $workerExecutableDiscoverySucceeded = (
                    [bool]$successDiagnostics.ExecutableDiscoverySucceeded -and
                    @(
                        'BundledCodex',
                        'PathCommand',
                        'ExplicitKnownPath'
                    ) -ccontains [string]$successDiagnostics.ExecutableSource
                )
                $workerLockDiagnosticSurvives = (
                    [bool]$successDiagnostics.AccountStabilityLockAcquired
                )

                Reset-QiehaoQuotaSelfTestScenario -Scenario 'Failure'
                $failureStarted = Start-QiehaoQuotaAsync -Reason Open
                $failureIdle = Wait-QiehaoQuotaSelfTestUntilIdle
                $failureTeamRow = @($script:guiAllProfileRows |
                    Where-Object { $_.Name -ceq 'Team' })[0]
                $failureBaseText =
                    Get-QiehaoQuotaUiTextSafe -Key 'UpdateFailedRetry'
                $startupFailureClearsBusy = (
                    $failureStarted -and $failureIdle -and
                    -not [bool]$script:guiQuotaCoordinator.QueryInProgress -and
                    $script:guiQuotaLastQueryFailed
                )
                $startupFailureReEnablesRefresh = (
                    [bool]$refreshQuotaButton.IsEnabled -and
                    $refreshStatusText.Text.StartsWith(
                        $failureBaseText,
                        [StringComparison]::Ordinal
                    ) -and
                    [string]$failureTeamRow.QuotaSummary -ceq
                        (Get-QiehaoQuotaUiTextSafe -Key 'NoSnapshot')
                )
                $workerFailureCodeSurvivesEndInvoke = (
                    $script:guiQuotaLastFailureCode -ceq
                        'QUOTA_RATE_LIMITS_TIMEOUT' -and
                    $refreshStatusText.Text -match
                        '错误代码：QUOTA_RATE_LIMITS_TIMEOUT'
                )
                $queryFailureDoesNotDisableRuntime = (
                    $script:guiQuotaModulesAvailable -and
                    $null -eq $script:guiQuotaInitializationFailureCode
                )

                Reset-QiehaoQuotaSelfTestScenario `
                    -Scenario 'CleanupFailure'
                $cleanupFailureStarted =
                    Start-QiehaoQuotaAsync -Reason Open
                $cleanupFailureIdle =
                    Wait-QiehaoQuotaSelfTestUntilIdle
                $cleanupFailureBaseText =
                    Get-QiehaoQuotaUiTextSafe -Key 'UpdateFailedRetry'
                $cleanupFailureClearsBusy = (
                    $cleanupFailureStarted -and
                    $cleanupFailureIdle -and
                    -not [bool]$script:guiQuotaCoordinator.QueryInProgress -and
                    $script:guiQuotaLastQueryFailed
                )
                $cleanupFailureReEnablesRefresh = (
                    [bool]$refreshQuotaButton.IsEnabled -and
                    $refreshStatusText.Text.StartsWith(
                        $cleanupFailureBaseText,
                        [StringComparison]::Ordinal
                    ) -and
                    $script:guiQuotaLastFailureCode -ceq
                        'QUOTA_CHILD_CLEANUP_FAILED'
                )
                $cleanupFailureDiagnosticsPreserved = (
                    $null -ne $script:guiQuotaLastDiagnostics -and
                    [bool]$script:guiQuotaLastDiagnostics.PrimarySucceeded -and
                    $null -eq
                        $script:guiQuotaLastDiagnostics.PrimaryFailureCode -and
                    -not [bool](
                        $script:guiQuotaLastDiagnostics.CleanupSucceeded
                    ) -and
                    [string](
                        $script:guiQuotaLastDiagnostics.CleanupFailureCode
                    ) -ceq 'QUOTA_CHILD_CLEANUP_FAILED' -and
                    [bool]$script:guiQuotaLastDiagnostics.SnapshotParsed
                )

                Reset-QiehaoQuotaSelfTestScenario -Scenario 'Timeout' `
                    -HardCeilingMilliseconds 250
                $timeoutStarted = Start-QiehaoQuotaAsync -Reason Open
                $longQueryKeepsCoreGuiResponsive = (
                    $timeoutStarted -and
                    [bool]$script:guiQuotaCoordinator.QueryInProgress -and
                    -not [bool]$refreshQuotaButton.IsEnabled -and
                    $refreshStatusText.Text -ceq
                        (Get-QiehaoQuotaUiTextSafe -Key 'Updating') -and
                    $script:guiQuotaModulesAvailable -and
                    -not $script:guiIsWriteOperationBusy -and
                    [string]$script:guiCurrentActiveProfile -ceq 'Team' -and
                    @($script:guiAllProfileRows).Count -eq 2 -and
                    $window.Dispatcher.CheckAccess()
                )
                $timeoutIdle = Wait-QiehaoQuotaSelfTestUntilIdle
                $startupTimeoutClearsBusy = (
                    $timeoutStarted -and $timeoutIdle -and
                    -not [bool]$script:guiQuotaCoordinator.QueryInProgress -and
                    $script:guiQuotaLastQueryFailed -and
                    [bool]$refreshQuotaButton.IsEnabled -and
                    $script:guiQuotaCompletionTimerStopped -and
                    $script:guiQuotaCompletionHandlerRemoved
                )

                Reset-QiehaoQuotaSelfTestScenario -Scenario 'Throw'
                $throwStarted = Start-QiehaoQuotaAsync -Reason Open
                $throwIdle = Wait-QiehaoQuotaSelfTestUntilIdle
                $asyncCompletionExceptionCleansUp = (
                    $throwStarted -and $throwIdle -and
                    $script:guiQuotaEndInvokeAttempted -and
                    $script:guiQuotaLastQueryFailed -and
                    -not [bool]$script:guiQuotaCoordinator.QueryInProgress -and
                    [bool]$refreshQuotaButton.IsEnabled -and
                    $null -eq $script:guiQuotaAsyncPowerShell -and
                    $null -eq $script:guiQuotaAsyncResult
                )

                Reset-QiehaoQuotaSelfTestScenario -Scenario 'Closing' `
                    -HardCeilingMilliseconds 3000
                $closingStarted = Start-QiehaoQuotaAsync -Reason Open
                $closingTimerWasActive = (
                    $null -ne $script:guiQuotaCompletionTimer -and
                    $script:guiQuotaCompletionTimer.IsEnabled
                )
                $script:guiIsClosing = $true
                Stop-QiehaoQuotaAsync -ForClosing
                $guiClosingCleansUp = (
                    $closingStarted -and $closingTimerWasActive -and
                    -not [bool]$script:guiQuotaCoordinator.QueryInProgress -and
                    $script:guiQuotaCompletionTimerStopped -and
                    $script:guiQuotaCompletionHandlerRemoved -and
                    $null -eq $script:guiQuotaAsyncPowerShell -and
                    $null -eq $script:guiQuotaAsyncResult -and
                    $null -eq $script:guiQuotaDeadlineUtc
                )
                $script:guiIsClosing = $false
                Update-QiehaoActionButtons

                $asyncChecks = [ordered]@{
                    StartupQuotaSuccessClearsBusy =
                        $startupSuccessClearsBusy
                    StartupQuotaFailureClearsBusy =
                        $startupFailureClearsBusy
                    StartupQuotaTimeoutClearsBusy =
                        $startupTimeoutClearsBusy
                    LongQuotaKeepsCoreGuiResponsive =
                        $longQueryKeepsCoreGuiResponsive
                    StartupQuotaCompletionTimerStops =
                        $startupCompletionTimerStops
                    StartupQuotaCompletionHandlerRemoved =
                        $startupCompletionHandlerRemoved
                    StartupQuotaSuccessReEnablesRefresh =
                        $startupSuccessReEnablesRefresh
                    StartupQuotaFailureReEnablesRefresh =
                        $startupFailureReEnablesRefresh
                    QueryFailureDoesNotDisableQuotaRuntime =
                        $queryFailureDoesNotDisableRuntime
                    CleanupFailureClearsBusy =
                        $cleanupFailureClearsBusy
                    CleanupFailureReEnablesRefresh =
                        $cleanupFailureReEnablesRefresh
                    CleanupFailureDiagnosticsPreserved =
                        $cleanupFailureDiagnosticsPreserved
                    AsyncCompletionExceptionStillCleansUp =
                        $asyncCompletionExceptionCleansUp
                    GuiClosingDuringQuotaQueryCleansUp =
                        $guiClosingCleansUp
                    StartupSendsAtMostOneQuery =
                        $startupAtMostOneQuery
                    StartupUsesActiveProfile =
                        $startupUsesActiveProfile
                    BackgroundWorkerImportsQuotaClient =
                        $backgroundWorkerImportsQuotaClient
                    BackgroundWorkerImportsQuotaParser =
                        $backgroundWorkerImportsQuotaParser
                    BackgroundWorkerHasQuotaPublicCommand =
                        $backgroundWorkerHasQuotaPublicCommand
                    BackgroundWorkerReturnsStructuredResult =
                        $backgroundWorkerReturnsStructuredResult
                    BackgroundWorkerFailureCodeSurvivesEndInvoke =
                        $workerFailureCodeSurvivesEndInvoke
                    BackgroundWorkerDoesNotRequireCallerScopeModules =
                        $backgroundWorkerOwnsDependencies
                    WorkerOutputCountOne =
                        $workerOutputCountOne
                    WorkerSnapshotSurvivesEndInvoke =
                        $workerSnapshotSurvivesEndInvoke
                    WorkerExecutableDiscoverySucceeded =
                        $workerExecutableDiscoverySucceeded
                    WorkerLockDiagnosticSurvives =
                        $workerLockDiagnosticSurvives
                }
                foreach ($asyncCheck in $asyncChecks.GetEnumerator()) {
                    if (-not [bool]$asyncCheck.Value) {
                        throw ('GUI_QUOTA_ASYNC_SELFTEST_FAILED_' +
                            [string]$asyncCheck.Key)
                    }
                    Write-Output ([string]$asyncCheck.Key + '=True')
                }
                Write-Output 'QUOTA_ASYNC_LIFECYCLE_SELFTEST_PASS'
            }
            finally {
                $script:guiIsClosing = $false
                Stop-QiehaoQuotaAsync
                $script:guiQuotaSelfTestScenario = $null
                $script:guiQuotaSelfTestHardCeilingMilliseconds = 0
                $stateDirectory = $originalStateDirectory
                if ([System.IO.Directory]::Exists(
                    $quotaAsyncTestDirectory
                )) {
                    [System.IO.Directory]::Delete(
                        $quotaAsyncTestDirectory,
                        $true
                    )
                }
            }
            return
        }
        $profileSearchTextBox.Text = 'team'
        Update-QiehaoProfileFilter
        if (@($profilesGrid.ItemsSource).Count -ne 1 -or
            [string]$profilesGrid.ItemsSource[0].Name -cne 'Team') {
            throw 'GUI_SELFTEST_SEARCH_FAILED'
        }
        $alternateImageResult = Set-QiehaoTheme `
            -Theme (Get-QiehaoBackgroundTheme -Id '03-ice-glass')
        if (-not $alternateImageResult.Loaded) { throw 'GUI_SELFTEST_THEME_SWITCH_FAILED' }
        Write-Output ('QUOTA_RUNTIME_AVAILABLE=' +
            [string]$script:guiQuotaModulesAvailable)
        Write-Output ('QUOTA_INITIALIZATION_FAILURE_CODE=' + $(
            if ($null -eq $script:guiQuotaInitializationFailureCode) {
                'NONE'
            }
            else { [string]$script:guiQuotaInitializationFailureCode }
        ))
        Write-Output ('QUOTA_REFRESH_BUTTON_ENABLED=' +
            [string]$refreshQuotaButton.IsEnabled)
        Write-Output ('QUOTA_CACHE_EXISTS=' +
            [string](-not [bool]$script:guiQuotaCacheRead.UsedEmpty))
        Write-Output 'GUI_SELFTEST_READY'
        return
    }

    $profilesGrid.Add_SelectionChanged({ Update-QiehaoActionButtons })
    $profileSearchTextBox.Add_TextChanged({ Update-QiehaoProfileFilter })
    $refreshButton.Add_Click({ Invoke-QiehaoReadOnlyRefresh })
    $refreshQuotaButton.Add_Click({ Invoke-QiehaoManualQuotaRefresh })
    $switchButton.Add_Click({ Invoke-QiehaoSwitchSelectedProfile })
    $verifyButton.Add_Click({ Invoke-QiehaoVerifySelectedProfile })
    $addButton.Add_Click({ Invoke-QiehaoAddAccount })
    $renameButton.Add_Click({ Invoke-QiehaoRenameSelectedProfile })
    $deleteButton.Add_Click({ Invoke-QiehaoDeleteSelectedProfile })
    $launchCodexButton.Add_Click({ Invoke-QiehaoLaunchCodex })
    $launchSettingsButton.Add_Click({ Show-QiehaoLaunchSettingsDialog })
    $contextSwitchMenuItem.Add_Click({ Invoke-QiehaoSwitchSelectedProfile })
    $contextVerifyMenuItem.Add_Click({ Invoke-QiehaoVerifySelectedProfile })
    $contextRenameMenuItem.Add_Click({ Invoke-QiehaoRenameSelectedProfile })
    $contextDeleteMenuItem.Add_Click({ Invoke-QiehaoDeleteSelectedProfile })
    $profilesGrid.Add_PreviewMouseRightButtonDown({
        param($sender, $eventArgs)
        $row = Get-QiehaoDataGridRowFromSource -Source $eventArgs.OriginalSource
        if ($null -eq $row) { $eventArgs.Handled = $true; return }
        $profilesGrid.SelectedItem = $row.Item
        Update-QiehaoActionButtons
    })
    $profilesGrid.Add_MouseDoubleClick({
        param($sender, $eventArgs)
        $row = Get-QiehaoDataGridRowFromSource -Source $eventArgs.OriginalSource
        if ($null -eq $row) { return }
        $profilesGrid.SelectedItem = $row.Item
        Invoke-QiehaoSwitchSelectedProfile
        $eventArgs.Handled = $true
    })
    $profilesGrid.Add_PreviewKeyDown({
        param($sender, $eventArgs)
        if ($eventArgs.Key -eq [System.Windows.Input.Key]::F2 -and
            $null -ne $profilesGrid.SelectedItem -and
            -not $script:guiIsWriteOperationBusy) {
            $eventArgs.Handled = $true
            Invoke-QiehaoRenameSelectedProfile
        }
    })
    $profileContextMenu.Add_Opened({ Update-QiehaoActionButtons })
    $window.Add_Loaded({
        Invoke-QiehaoReadOnlyRefresh
        if (-not $script:guiQuotaModulesAvailable -or
            -not [bool]$script:guiQuotaCacheRead.IsValid) {
            $refreshStatusText.Text =
                Get-QiehaoQuotaUiTextSafe -Key 'CacheUnavailable'
        }
        if ($script:guiQuotaModulesAvailable) {
            $null = Start-QiehaoQuotaAsync -Reason Open
        }
        Start-QiehaoProcessMonitor
        $script:guiThemePersistenceReady = $true
        $script:guiLanguagePersistenceReady = $true
    })
    $window.Add_Closing({ Stop-QiehaoAllTimers })
    $window.Add_Closed({
        Stop-QiehaoAllTimers
    })
    [void]$window.ShowDialog()
}
finally {
    try {
        if ($null -ne (Get-Command -Name Stop-QiehaoAllTimers `
            -CommandType Function -ErrorAction SilentlyContinue)) {
            Stop-QiehaoAllTimers
        }
    }
    catch { }
    if ($null -ne $window -and $SelfTest) { $window.Close() }
    if ($null -ne $lease) { Exit-QiehaoGuiSingleInstance -Lease $lease }
}
