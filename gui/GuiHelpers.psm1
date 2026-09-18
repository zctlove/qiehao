Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Get-ObjectPropertyValue {
    param(
        [AllowNull()]
        [object]$InputObject,

        [Parameter(Mandatory = $true)]
        [string]$Name,

        [AllowNull()]
        [object]$DefaultValue
    )

    if ($null -eq $InputObject) {
        return $DefaultValue
    }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) {
        return $DefaultValue
    }
    return $property.Value
}

function Get-AllowlistedDisplayValue {
    param(
        [AllowNull()]
        [object]$Value,

        [Parameter(Mandatory = $true)]
        [string[]]$AllowedValues,

        [Parameter(Mandatory = $true)]
        [string]$Fallback
    )

    $candidate = [string]$Value
    if ($AllowedValues -ccontains $candidate) {
        return $candidate
    }
    return $Fallback
}

function ConvertTo-QiehaoProfileDisplayValue {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Health', 'Artifact', 'Metadata')]
        [string]$Category,

        [AllowNull()]
        [object]$Value
    )

    $candidate = [string]$Value
    switch ($Category) {
        'Health' {
            switch ($candidate) {
                'READY' { return '正常' }
                'INCOMPLETE_PROFILE' { return '不完整' }
                'INVALID_METADATA' { return '元数据异常' }
                default { return '未知' }
            }
        }
        'Artifact' {
            switch ($candidate) {
                'PRESENT' { return '存在' }
                'MISSING' { return '缺失' }
                default { return '未知' }
            }
        }
        'Metadata' {
            switch ($candidate) {
                'VALID' { return '有效' }
                'MISSING' { return '缺失' }
                'INVALID' { return '异常' }
                default { return '未知' }
            }
        }
    }
}

function ConvertTo-QiehaoGuiProfileRows {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$ProfileData,

        [AllowNull()]
        [string]$ActiveProfile,

        [switch]$ActiveProfileKnown
    )

    $rows = @()
    foreach ($item in @($ProfileData)) {
        if ($null -eq $item) {
            continue
        }

        $name = [string](Get-ObjectPropertyValue -InputObject $item `
            -Name 'Profile' -DefaultValue '<Unknown>')
        if ([string]::IsNullOrWhiteSpace($name)) {
            $name = '<Unknown>'
        }

        if ($ActiveProfileKnown) {
            $activeText = if ($name.Equals(
                $ActiveProfile,
                [StringComparison]::OrdinalIgnoreCase
            )) { '是' } else { '否' }
        }
        else {
            $activeValue = Get-ObjectPropertyValue -InputObject $item `
                -Name 'Active' -DefaultValue $null
            if ($activeValue -is [bool]) {
                $activeText = if ([bool]$activeValue) { '是' } else { '否' }
            }
            else {
                $activeText = '未知'
            }
        }

        $updated = [string](Get-ObjectPropertyValue -InputObject $item `
            -Name 'UpdatedAt' -DefaultValue '<UNAVAILABLE>')
        if ([string]::IsNullOrWhiteSpace($updated)) {
            $updated = '<UNAVAILABLE>'
        }
        switch ($updated) {
            '<UNAVAILABLE>' { $updated = '不可用' }
            '<INVALID_METADATA>' { $updated = '元数据异常' }
        }

        $rows += [pscustomobject]@{
            Name = $name
            Active = $activeText
            Verification = '未验证'
            Health = ConvertTo-QiehaoProfileDisplayValue -Category 'Health' `
                -Value (Get-ObjectPropertyValue -InputObject $item `
                    -Name 'Health' -DefaultValue 'UNKNOWN')
            Auth = ConvertTo-QiehaoProfileDisplayValue -Category 'Artifact' `
                -Value (Get-ObjectPropertyValue -InputObject $item `
                    -Name 'AuthFile' -DefaultValue 'UNKNOWN')
            Identity = ConvertTo-QiehaoProfileDisplayValue -Category 'Artifact' `
                -Value (Get-ObjectPropertyValue -InputObject $item `
                    -Name 'IdentityMarker' -DefaultValue 'UNKNOWN')
            Metadata = ConvertTo-QiehaoProfileDisplayValue -Category 'Metadata' `
                -Value (Get-ObjectPropertyValue -InputObject $item `
                    -Name 'Metadata' -DefaultValue 'UNKNOWN')
            Updated = $updated
        }
    }
    return @($rows)
}

function Invoke-QiehaoOptionalProfileRowEnrichment {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$Rows,

        [AllowNull()]
        [scriptblock]$Enrichment
    )

    # Profile rows are core state. Optional feature enrichment may mutate those
    # rows, but it can never define, remove, or replace the profile population.
    $coreRows = @($Rows)
    if ($null -eq $Enrichment) {
        return [pscustomobject]@{
            Rows = $coreRows
            EnrichmentSucceeded = $false
            FailureCode = 'OPTIONAL_ENRICHMENT_UNAVAILABLE'
        }
    }

    try {
        $null = & $Enrichment
        return [pscustomobject]@{
            Rows = $coreRows
            EnrichmentSucceeded = $true
            FailureCode = $null
        }
    }
    catch {
        return [pscustomobject]@{
            Rows = $coreRows
            EnrichmentSucceeded = $false
            FailureCode = 'OPTIONAL_ENRICHMENT_FAILED'
        }
    }
}

function ConvertTo-QiehaoVerifyMessage {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [string]$ResultCode
    )

    switch ($ResultCode) {
        'PROFILE_VERIFY_SUCCESS' { return '账号验证成功' }
        'PROFILE_INCOMPLETE' { return '账号资料不完整' }
        'PROFILE_IDENTITY_MISMATCH' { return '账号身份标记不匹配' }
        'PROFILE_IDENTITY_MARKER_MISSING' { return '身份标记缺失' }
        'PROFILE_METADATA_INVALID' { return '元数据异常' }
        'CODEX_PROCESS_RUNNING' { return 'Codex 正在运行' }
        'CODEX_PROCESS_STATE_UNKNOWN' { return '无法确认 Codex 进程状态' }
        'OPERATION_BUSY' { return '另一个操作正在执行' }
        'PROFILE_SELECTION_REQUIRED' { return '请先选择一个账号。' }
        default { return '验证失败，请查看安全状态信息' }
    }
}

function Invoke-QiehaoVerifyRequest {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [string]$SelectedProfile,

        [Parameter(Mandatory = $true)]
        [ValidateSet('运行中', '已退出', '未知')]
        [string]$CodexStatus,

        [Parameter(Mandatory = $true)]
        [scriptblock]$VerifyProvider
    )

    if ([string]::IsNullOrWhiteSpace($SelectedProfile)) {
        return [pscustomobject]@{
            CoreCalled = $false
            ResultCode = 'PROFILE_SELECTION_REQUIRED'
            Message = '请先选择一个账号。'
            VerificationStatus = '未验证'
        }
    }
    if ($CodexStatus -ceq '运行中') {
        return [pscustomobject]@{
            CoreCalled = $false
            ResultCode = 'CODEX_PROCESS_RUNNING'
            Message = '请先正常退出 Codex，再验证账号。'
            VerificationStatus = '未验证'
        }
    }
    if ($CodexStatus -cne '已退出') {
        return [pscustomobject]@{
            CoreCalled = $false
            ResultCode = 'CODEX_PROCESS_STATE_UNKNOWN'
            Message = '无法确认 Codex 进程状态，请重新检测。'
            VerificationStatus = '未验证'
        }
    }

    $resultCode = 'VERIFY_UNKNOWN'
    try {
        $result = & $VerifyProvider $SelectedProfile
        $resultProperty = if ($null -eq $result) {
            $null
        }
        else {
            $result.PSObject.Properties['Result']
        }
        if ($null -ne $resultProperty) {
            $resultCode = [string]$resultProperty.Value
        }
    }
    catch {
        $safeCodes = @(
            'PROFILE_INCOMPLETE',
            'PROFILE_IDENTITY_MISMATCH',
            'PROFILE_IDENTITY_MARKER_MISSING',
            'PROFILE_METADATA_INVALID',
            'CODEX_PROCESS_RUNNING',
            'CODEX_PROCESS_STATE_UNKNOWN',
            'OPERATION_BUSY'
        )
        if ($safeCodes -ccontains [string]$_.Exception.Message) {
            $resultCode = [string]$_.Exception.Message
        }
    }

    $success = $resultCode -ceq 'PROFILE_VERIFY_SUCCESS'
    return [pscustomobject]@{
        CoreCalled = $true
        ResultCode = $resultCode
        Message = ConvertTo-QiehaoVerifyMessage -ResultCode $resultCode
        VerificationStatus = if ($success) { '已验证' } else { '验证失败' }
    }
}

function Get-QiehaoSafeResultCode {
    param(
        [AllowNull()]
        [object]$Result,

        [AllowNull()]
        [object]$ErrorRecord,

        [Parameter(Mandatory = $true)]
        [string]$Fallback
    )

    if ($null -ne $Result) {
        $resultProperty = $Result.PSObject.Properties['Result']
        if ($null -ne $resultProperty) {
            $candidate = [string]$resultProperty.Value
            if ($candidate -match '^[A-Z][A-Z0-9_]+$') {
                return $candidate
            }
        }
    }

    if ($null -ne $ErrorRecord) {
        $candidate = [string]$ErrorRecord.Exception.Message
        $safeCodes = @(
            'SWITCH_SUCCESS',
            'ALREADY_ACTIVE',
            'ACTIVE_PROFILE_IDENTITY_MISMATCH',
            'PROFILE_IDENTITY_MISMATCH',
            'PROFILE_IDENTITY_MARKER_MISSING',
            'PROFILE_IDENTITY_MARKER_INVALID',
            'AUTH_IDENTITY_SCHEMA_UNRECOGNIZED',
            'PROFILE_IDENTITY_SCHEMA_UNRECOGNIZED',
            'CODEX_PROCESS_RUNNING',
            'CODEX_PROCESS_STATE_UNKNOWN',
            'CODEX_CLOSE_REQUESTED',
            'CODEX_NATIVE_QUIT_REQUESTED',
            'CODEX_NATIVE_QUIT_NOT_AVAILABLE',
            'CODEX_NATIVE_QUIT_UI_NOT_FOUND',
            'CODEX_NATIVE_QUIT_INVOKE_FAILED',
            'CODEX_ALREADY_STOPPED',
            'OPERATION_BUSY',
            'SWITCH_FAILED_ROLLED_BACK',
            'SWITCH_ROLLBACK_FAILED',
            'SWITCH_FAILED',
            'PROFILE_ADD_SUCCESS',
            'PROFILE_NAME_ALREADY_EXISTS',
            'PROFILE_IDENTITY_ALREADY_EXISTS',
            'PROFILE_IDENTITY_SCAN_INCOMPLETE',
            'PROFILE_ADD_VERIFICATION_FAILED',
            'PROFILE_ADD_ROLLBACK_FAILED',
            'PROFILE_ADD_FAILED',
            'PROFILE_RENAME_SUCCESS',
            'PROFILE_RENAME_FAILED_ROLLED_BACK',
            'PROFILE_RENAME_ROLLBACK_FAILED',
            'PROFILE_RENAME_FAILED',
            'PROFILE_REMOVE_SUCCESS',
            'PROFILE_REMOVE_PARTIAL_FAILURE',
            'PROFILE_REMOVE_CONFIRMATION_REQUIRED',
            'CANNOT_REMOVE_ACTIVE_PROFILE',
            'PROFILE_NOT_FOUND',
            'PROFILE_INCOMPLETE',
            'PROFILE_METADATA_INVALID',
            'PROFILE_NAME_INVALID',
            'PROFILE_NAME_TOO_LONG',
            'PROFILE_NAME_RESERVED',
            'ACTIVE_PROFILE_SAVE_SUCCESS',
            'ACTIVE_PROFILE_SAVE_VERIFICATION_FAILED',
            'ACTIVE_PROFILE_SAVE_FAILED'
        )
        if ($safeCodes -ccontains $candidate) {
            return $candidate
        }
    }
    return $Fallback
}

function ConvertTo-QiehaoOperationResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ResultCode
    )

    $message = '操作失败，未进行不安全的继续操作。'
    $severity = 'Warning'
    $success = $false
    $refresh = $false

    switch ($ResultCode) {
        'SWITCH_SUCCESS' {
            $message = '切换成功。'; $success = $true; $refresh = $true
        }
        'ALREADY_ACTIVE' { $message = '已经是当前账号。'; $severity = 'Information' }
        'ACTIVE_PROFILE_IDENTITY_MISMATCH' {
            $message = '当前账号身份与本地记录不一致，已阻止操作。'
        }
        'PROFILE_IDENTITY_MISMATCH' { $message = '目标账号身份验证失败。' }
        'PROFILE_IDENTITY_MARKER_MISSING' { $message = '目标账号身份标记缺失。' }
        'PROFILE_IDENTITY_MARKER_INVALID' { $message = '目标账号身份标记异常。' }
        'AUTH_IDENTITY_SCHEMA_UNRECOGNIZED' {
            $message = '当前 Codex 登录结构无法识别。'
        }
        'PROFILE_IDENTITY_SCHEMA_UNRECOGNIZED' {
            $message = '本地账号身份结构无法识别。'
        }
        'CODEX_PROCESS_RUNNING' { $message = 'Codex 正在运行。' }
        'CODEX_PROCESS_STATE_UNKNOWN' {
            $message = '无法确认 Codex 进程状态，请重新检测。'
        }
        'CODEX_EXIT_TIMEOUT' {
            $message = 'Codex 仍有后台进程，请使用 Codex 的退出功能或系统托盘退出后重试。'
        }
        'CODEX_EXIT_STATE_UNKNOWN' {
            $message = '无法确认 Codex 是否完全退出，本次未执行切换。'
        }
        'OPERATION_BUSY' { $message = '另一个操作正在执行。' }
        'OPERATION_CANCELLED' { $message = ''; $severity = 'Information' }
        'PROFILE_SELECTION_REQUIRED' { $message = '请先选择一个账号。' }
        'SWITCH_FAILED_ROLLED_BACK' {
            $message = '切换失败，已安全恢复原账号。'
        }
        'SWITCH_ROLLBACK_FAILED' {
            $message = '切换失败且自动恢复失败。请不要启动 Codex，先进行人工恢复。'
            $severity = 'Critical'
        }
        'PROFILE_ADD_SUCCESS' {
            $message = '账号已添加。'; $success = $true; $refresh = $true
        }
        'PROFILE_NAME_ALREADY_EXISTS' { $message = '该本地账号名称已经存在。' }
        'PROFILE_IDENTITY_ALREADY_EXISTS' {
            $message = '该账号已经存在于本地账号列表中。'
        }
        'PROFILE_IDENTITY_SCAN_INCOMPLETE' {
            $message = '本地账号身份检查不完整，已停止添加。'
        }
        'PROFILE_ADD_ROLLBACK_FAILED' {
            $message = '添加失败且清理未完成，请停止操作并人工检查本地账号槽位。'
            $severity = 'Critical'
        }
        'PROFILE_RENAME_SUCCESS' {
            $message = '账号已重命名。'; $success = $true; $refresh = $true
        }
        'PROFILE_RENAME_FAILED_ROLLED_BACK' {
            $message = '重命名失败，已恢复原名称。'
        }
        'PROFILE_RENAME_ROLLBACK_FAILED' {
            $message = '重命名失败且自动恢复失败，请停止操作并人工检查。'
            $severity = 'Critical'
        }
        'PROFILE_REMOVE_SUCCESS' {
            $message = '本地账号已删除。'; $success = $true; $refresh = $true
        }
        'PROFILE_REMOVE_PARTIAL_FAILURE' {
            $message = '本地账号仅部分删除，请停止操作并人工检查。'
            $severity = 'Critical'
            $refresh = $true
        }
        'PROFILE_REMOVE_CONFIRMATION_REQUIRED' {
            $message = '删除需要明确确认。'
        }
        'CANNOT_REMOVE_ACTIVE_PROFILE' { $message = '不能删除当前账号。' }
        'PROFILE_NOT_FOUND' { $message = '本地账号不存在。' }
        'PROFILE_INCOMPLETE' { $message = '账号资料不完整。' }
        'PROFILE_METADATA_INVALID' { $message = '账号元数据异常。' }
        'PROFILE_NAME_INVALID' { $message = '账号名称无效。' }
        'PROFILE_NAME_TOO_LONG' { $message = '账号名称不能超过 64 个字符。' }
        'PROFILE_NAME_RESERVED' { $message = '该账号名称为系统保留名称。' }
        'ACTIVE_PROFILE_SAVE_SUCCESS' {
            $message = '当前账号状态已安全保存。'; $success = $true
        }
        'ACTIVE_PROFILE_SAVE_VERIFICATION_FAILED' {
            $message = '当前账号状态保存后校验失败，已停止添加流程。'
            $severity = 'Critical'
        }
        'ACTIVE_PROFILE_SAVE_FAILED' {
            $message = '无法安全保存当前账号状态，已停止添加流程。'
        }
    }

    return [pscustomobject]@{
        ResultCode = $ResultCode
        Message = $message
        Severity = $severity
        IsSuccess = $success
        RefreshRequired = $refresh
    }
}

function Invoke-QiehaoOperationProvider {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('SWITCH', 'ADD', 'RENAME', 'DELETE', 'SAVE_ACTIVE')]
        [string]$Operation,

        [Parameter(Mandatory = $true)]
        [scriptblock]$Provider,

        [object[]]$ArgumentList = @(),

        [switch]$IsBusy
    )

    if ($IsBusy) {
        $mapped = ConvertTo-QiehaoOperationResult -ResultCode 'OPERATION_BUSY'
        $mapped | Add-Member -NotePropertyName CoreCalled -NotePropertyValue $false
        return $mapped
    }

    $fallback = switch ($Operation) {
        'SWITCH' { 'SWITCH_FAILED' }
        'ADD' { 'PROFILE_ADD_FAILED' }
        'RENAME' { 'PROFILE_RENAME_FAILED' }
        'DELETE' { 'PROFILE_REMOVE_FAILED' }
        'SAVE_ACTIVE' { 'ACTIVE_PROFILE_SAVE_FAILED' }
    }
    $code = $fallback
    try {
        $result = & $Provider @ArgumentList
        $code = Get-QiehaoSafeResultCode -Result $result -Fallback $fallback
    }
    catch {
        $code = Get-QiehaoSafeResultCode -ErrorRecord $_ -Fallback $fallback
    }
    $mapped = ConvertTo-QiehaoOperationResult -ResultCode $code
    $mapped | Add-Member -NotePropertyName CoreCalled -NotePropertyValue $true
    return $mapped
}

function Invoke-QiehaoSwitchUiCompletion {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Result,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$TargetProfile,

        [Parameter(Mandatory = $true)]
        [scriptblock]$RefreshProvider,

        [Parameter(Mandatory = $true)]
        [scriptblock]$StateProvider,

        [Parameter(Mandatory = $true)]
        [scriptblock]$BusyProvider
    )

    $backendSucceeded = (
        [bool]$Result.IsSuccess -and
        [string]$Result.ResultCode -ceq 'SWITCH_SUCCESS'
    )
    if (-not $backendSucceeded) {
        try { $null = & $BusyProvider $false }
        catch { }
        try { $null = & $StateProvider 'SwitchFailed' $TargetProfile }
        catch { }
        return [pscustomobject]@{
            State = 'SwitchFailed'
            BackendSucceeded = $false
            UiRefreshSucceeded = $false
            TargetProfile = $TargetProfile
        }
    }

    $refreshSucceeded = $false
    try { $refreshSucceeded = [bool](& $RefreshProvider $TargetProfile) }
    catch { $refreshSucceeded = $false }

    try { $null = & $BusyProvider $false }
    catch { }
    $state = if ($refreshSucceeded) {
        'SwitchSucceeded'
    }
    else {
        'SwitchSucceededUiRefreshFailed'
    }
    try { $null = & $StateProvider $state $TargetProfile }
    catch { }

    return [pscustomobject]@{
        State = $state
        BackendSucceeded = $true
        UiRefreshSucceeded = $refreshSucceeded
        TargetProfile = $TargetProfile
    }
}

function Select-QiehaoProfileRows {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$Rows,

        [AllowNull()]
        [string]$SearchText
    )

    $term = [string]$SearchText
    if ([string]::IsNullOrWhiteSpace($term)) {
        return @($Rows)
    }
    $term = $term.Trim()
    return @($Rows | Where-Object {
        $nameProperty = $_.PSObject.Properties['Name']
        $null -ne $nameProperty -and
        ([string]$nameProperty.Value).IndexOf(
            $term,
            [StringComparison]::OrdinalIgnoreCase
        ) -ge 0
    })
}

function Get-QiehaoActionState {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [string]$SelectedProfile,

        [AllowNull()]
        [string]$ActiveProfile,

        [Parameter(Mandatory = $true)]
        [ValidateSet('运行中', '已退出', '未知')]
        [string]$CodexStatus,

        [switch]$IsWriteOperationBusy,

        [bool]$LaunchTargetAvailable = $true
    )

    $hasSelection = -not [string]::IsNullOrWhiteSpace($SelectedProfile)
    $isActive = $hasSelection -and
        -not [string]::IsNullOrWhiteSpace($ActiveProfile) -and
        $SelectedProfile.Equals($ActiveProfile, [StringComparison]::OrdinalIgnoreCase)
    $available = -not $IsWriteOperationBusy
    return [pscustomobject]@{
        Refresh = $true
        Switch = $available -and $hasSelection -and -not $isActive
        Verify = $available -and $hasSelection -and $CodexStatus -ceq '已退出'
        Add = $available
        Rename = $available -and $hasSelection
        Delete = $available -and $hasSelection -and -not $isActive
        ContextSwitch = $available -and $hasSelection -and -not $isActive
        ContextVerify = $available -and $hasSelection -and
            $CodexStatus -ceq '已退出'
        ContextRename = $available -and $hasSelection
        ContextDelete = $available -and $hasSelection -and -not $isActive
        LaunchCodex = $available -and $LaunchTargetAvailable -and
            $CodexStatus -ceq '已退出'
        IsSelectedProfileActive = $isActive
    }
}

function Invoke-QiehaoSwitchRequest {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [string]$SelectedProfile,

        [AllowNull()]
        [string]$ActiveProfile,

        [Parameter(Mandatory = $true)]
        [scriptblock]$ProcessProvider,

        [Parameter(Mandatory = $true)]
        [scriptblock]$SwitchProvider,

        [scriptblock]$ManualWaitProvider = { param($TargetProfile) $null },

        [switch]$IsBusy
    )

    if ($IsBusy) {
        return Invoke-QiehaoOperationProvider -Operation 'SWITCH' `
            -Provider $SwitchProvider -IsBusy
    }
    if ([string]::IsNullOrWhiteSpace($SelectedProfile)) {
        $mapped = ConvertTo-QiehaoOperationResult `
            -ResultCode 'PROFILE_SELECTION_REQUIRED'
        $mapped | Add-Member -NotePropertyName CoreCalled -NotePropertyValue $false
        return $mapped
    }
    if (-not [string]::IsNullOrWhiteSpace($ActiveProfile) -and
        $SelectedProfile.Equals($ActiveProfile, [StringComparison]::OrdinalIgnoreCase)) {
        $mapped = ConvertTo-QiehaoOperationResult -ResultCode 'ALREADY_ACTIVE'
        $mapped | Add-Member -NotePropertyName CoreCalled -NotePropertyValue $false
        return $mapped
    }

    try {
        $status = ConvertTo-QiehaoCodexStatus -ProcessState (& $ProcessProvider)
    }
    catch {
        $status = '未知'
    }
    if ($status -ceq '未知') {
        $mapped = ConvertTo-QiehaoOperationResult `
            -ResultCode 'CODEX_PROCESS_STATE_UNKNOWN'
        $mapped | Add-Member -NotePropertyName CoreCalled -NotePropertyValue $false
        return $mapped
    }

    if ($status -ceq '运行中') {
        try {
            $null = & $ManualWaitProvider $SelectedProfile
        }
        catch {
            $mapped = ConvertTo-QiehaoOperationResult `
                -ResultCode 'CODEX_PROCESS_STATE_UNKNOWN'
            $mapped | Add-Member -NotePropertyName CoreCalled -NotePropertyValue $false
            $mapped | Add-Member -NotePropertyName WaitStarted -NotePropertyValue $false
            return $mapped
        }
        return [pscustomobject]@{
            ResultCode = 'CODEX_MANUAL_EXIT_WAIT_STARTED'
            Message = '请从 Codex 菜单“文件 → 退出”或系统托盘选择“退出”。检测到 Codex 完全退出后将自动继续切换。'
            Severity = 'Info'
            IsSuccess = $false
            RefreshRequired = $false
            CoreCalled = $false
            WaitStarted = $true
        }
    }

    return Invoke-QiehaoOperationProvider -Operation 'SWITCH' `
        -Provider $SwitchProvider -ArgumentList @($SelectedProfile)
}

function ConvertTo-QiehaoExitMessage {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [string]$ResultCode
    )

    switch ($ResultCode) {
        'CODEX_ALREADY_STOPPED' { return 'Codex 已经退出。' }
        'CODEX_PROCESS_STATE_UNKNOWN' {
            return '无法安全确认 Codex 进程，请手动退出后重新检测。'
        }
        'CODEX_CLOSE_REQUESTED' { return '已发送正常关闭请求，正在等待 Codex 退出。' }
        'CODEX_CLOSE_REQUEST_FAILED' {
            return 'Codex 主窗口拒绝了正常关闭请求，请在系统托盘中选择退出，然后点击“刷新”。'
        }
        'CODEX_MAIN_WINDOW_NOT_FOUND' {
            return '未找到可安全关闭的 Codex 主窗口，请在系统托盘中选择退出，然后点击“刷新”。'
        }
        'CODEX_NATIVE_QUIT_REQUESTED' { return 'Codex 正在退出……' }
        'CODEX_NATIVE_QUIT_NOT_AVAILABLE' {
            return '当前系统无法使用 Codex 原生退出入口，请使用 Codex 的退出功能或系统托盘退出后重试。'
        }
        'CODEX_NATIVE_QUIT_UI_NOT_FOUND' {
            return '未找到 Codex 原生退出菜单，请使用 Codex 的退出功能或系统托盘退出后重试。'
        }
        'CODEX_NATIVE_QUIT_INVOKE_FAILED' {
            return 'Codex 原生退出命令未能执行，请使用 Codex 的退出功能或系统托盘退出后重试。'
        }
        default { return '无法安全请求 Codex 退出，请手动退出后重新检测。' }
    }
}

function ConvertTo-QiehaoCodexStatus {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$ProcessState
    )

    $reasonCode = [string](Get-ObjectPropertyValue -InputObject $ProcessState `
        -Name 'ReasonCode' -DefaultValue 'CODEX_PROCESS_STATE_UNKNOWN')
    switch ($reasonCode) {
        'CODEX_PROCESSES_STOPPED' { return '已退出' }
        'CODEX_PROCESS_RUNNING' { return '运行中' }
        'CODEX_PROCESS_STATE_UNKNOWN' { return '未知' }
        default { return '未知' }
    }
}

function ConvertTo-QiehaoActiveIdentityStatus {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [string]$ResultCode
    )

    switch ($ResultCode) {
        'ACTIVE_IDENTITY_CONFIRMED' { return '已确认' }
        'ACTIVE_PROFILE_IDENTITY_MISMATCH' { return '不匹配' }
        'ACTIVE_PROFILE_NOT_INITIALIZED' { return '尚未初始化' }
        'CODEX_PROCESS_RUNNING' { return '待退出后确认' }
        'PROFILE_IDENTITY_MARKER_MISSING' { return '无法确认' }
        'PROFILE_IDENTITY_MARKER_INVALID' { return '无法确认' }
        'AUTH_IDENTITY_SCHEMA_UNRECOGNIZED' { return '无法确认' }
        'PROFILE_IDENTITY_SCHEMA_UNRECOGNIZED' { return '无法确认' }
        'CODEX_PROCESS_STATE_UNKNOWN' { return '无法确认' }
        'ACTIVE_IDENTITY_CHECK_FAILED' { return '无法确认' }
        'OPERATION_BUSY' { return '无法确认' }
        default { return '无法确认' }
    }
}

function Get-QiehaoGuiSnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock]$ListProvider,

        [Parameter(Mandatory = $true)]
        [scriptblock]$ActiveProvider,

        [Parameter(Mandatory = $true)]
        [scriptblock]$ProcessProvider,

        [AllowNull()]
        [scriptblock]$ActiveIdentityProvider
    )

    $errors = @()
    $rawProfiles = @()
    try {
        $rawProfiles = @(& $ListProvider)
    }
    catch {
        $errors += 'PROFILE_LIST_UNAVAILABLE'
        $rawProfiles = @()
    }

    $activeProfile = '未初始化'
    $activeProfileKnown = $false
    try {
        $activeState = & $ActiveProvider
        $candidate = [string](Get-ObjectPropertyValue -InputObject $activeState `
            -Name 'ActiveProfile' -DefaultValue '')
        if (-not [string]::IsNullOrWhiteSpace($candidate)) {
            $activeProfile = $candidate
            $activeProfileKnown = $true
        }
    }
    catch {
        $errors += 'ACTIVE_PROFILE_UNAVAILABLE'
    }

    $codexStatus = '未知'
    try {
        $codexStatus = ConvertTo-QiehaoCodexStatus -ProcessState (& $ProcessProvider)
    }
    catch {
        $errors += 'CODEX_PROCESS_STATE_UNAVAILABLE'
    }

    $rows = ConvertTo-QiehaoGuiProfileRows -ProfileData $rawProfiles `
        -ActiveProfile $activeProfile -ActiveProfileKnown:$activeProfileKnown

    $identityStatus = '无法确认'
    if ($codexStatus -ceq '运行中') {
        $identityStatus = '待退出后确认'
    }
    elseif ($codexStatus -ceq '已退出') {
        if (-not $activeProfileKnown) {
            $identityStatus = '尚未初始化'
        }
        elseif ($null -ne $ActiveIdentityProvider) {
            try {
                $identityResult = & $ActiveIdentityProvider
                $resultProperty = if ($null -eq $identityResult) {
                    $null
                }
                else {
                    $identityResult.PSObject.Properties['Result']
                }
                $identityCode = if ($null -eq $resultProperty) {
                    'ACTIVE_IDENTITY_CHECK_FAILED'
                }
                else {
                    [string]$resultProperty.Value
                }
                $identityStatus = ConvertTo-QiehaoActiveIdentityStatus `
                    -ResultCode $identityCode
            }
            catch {
                $identityStatus = '无法确认'
                $errors += 'ACTIVE_IDENTITY_UNAVAILABLE'
            }
        }
    }

    return [pscustomobject]@{
        CodexDesktop = $codexStatus
        ActiveProfile = $activeProfile
        IdentityStatus = $identityStatus
        WebChatGPT = '不受影响'
        Profiles = @($rows)
        ReadOnlyErrors = @($errors)
    }
}

function Get-QiehaoBackgroundThemes {
    [CmdletBinding()]
    param()

    return @(
        [pscustomobject]@{
            Id = '01-blue-glass'
            Name = '科技蓝'
            FileName = '01-blue-glass.png'
            OverlayMode = 'Dark'
            OverlayColor = '#66101D2B'
            CardTop = '#96394E66'
            CardBottom = '#8A1D3046'
            BorderTint = '#88A7C9E8'
            TextPrimary = '#FFF4F8FC'
            TextSecondary = '#FFD0DCE8'
            ButtonTop = '#E04F769E'
            ButtonBottom = '#E02B4E73'
            ButtonHover = '#F06087B1'
            ButtonPressed = '#E023405F'
            ActiveRowTint = '#C03B6FA8'
            ActiveSelectedRowTint = '#E04487CF'
            SelectedRowTint = '#B85C4B7D'
            ActiveBorderTint = '#FF7EC8FF'
            RunningWarningTint = '#FFFFAAA4'
            UnknownWarningTint = '#FFFFB84D'
            ColumnHeaderBackgroundTint = '#FF233B55'
            ColumnHeaderForegroundTint = '#FFF7FBFF'
            ColumnHeaderBorderTint = '#FF6F91B2'
            CurrentYesTint = '#FF72E6A6'
            CurrentNoTint = '#FFFFC56B'
            AccentTint = '#FF5CC58A'
            DangerTop = '#E08F5D68'
            DangerBottom = '#E06F3F4A'
        },
        [pscustomobject]@{
            Id = '02-navy-gold'
            Name = '深蓝鎏金'
            FileName = '02-navy-gold.png'
            OverlayMode = 'Dark'
            OverlayColor = '#70100F18'
            CardTop = '#962A3041'
            CardBottom = '#88151B2A'
            BorderTint = '#8CBDAA72'
            TextPrimary = '#FFFFF9EB'
            TextSecondary = '#FFE0D6BC'
            ButtonTop = '#E06C675A'
            ButtonBottom = '#E0464350'
            ButtonHover = '#F0837960'
            ButtonPressed = '#E0353442'
            ActiveRowTint = '#C035659A'
            ActiveSelectedRowTint = '#E0437DB8'
            SelectedRowTint = '#B86B5940'
            ActiveBorderTint = '#FF79BFFF'
            RunningWarningTint = '#FFFF7D73'
            UnknownWarningTint = '#FFFFC857'
            ColumnHeaderBackgroundTint = '#FF212736'
            ColumnHeaderForegroundTint = '#FFFFF9EB'
            ColumnHeaderBorderTint = '#FF8F8058'
            CurrentYesTint = '#FF78D99A'
            CurrentNoTint = '#FFFFC857'
            AccentTint = '#FFD2B86E'
            DangerTop = '#E0945F63'
            DangerBottom = '#E0713D45'
        },
        [pscustomobject]@{
            Id = '03-ice-glass'
            Name = '冰蓝玻璃'
            FileName = '03-ice-glass.png'
            OverlayMode = 'Light'
            OverlayColor = '#55EAF5FA'
            CardTop = '#AEEAF7FC'
            CardBottom = '#A0DCECF4'
            BorderTint = '#A8FFFFFF'
            TextPrimary = '#FF173047'
            TextSecondary = '#FF50687A'
            ButtonTop = '#E8EAF7FC'
            ButtonBottom = '#E8BFD9E7'
            ButtonHover = '#F4F5FCFF'
            ButtonPressed = '#E8ABCBD9'
            ActiveRowTint = '#D6A9D6F5'
            ActiveSelectedRowTint = '#E78BC3EC'
            SelectedRowTint = '#C9D9C5EA'
            ActiveBorderTint = '#FF246FAD'
            RunningWarningTint = '#FFB42318'
            UnknownWarningTint = '#FF9A5A00'
            ColumnHeaderBackgroundTint = '#FFD6EAF5'
            ColumnHeaderForegroundTint = '#FF173047'
            ColumnHeaderBorderTint = '#FF799DB5'
            CurrentYesTint = '#FF146C43'
            CurrentNoTint = '#FF9C3B2F'
            AccentTint = '#FF27845A'
            DangerTop = '#E8F2D4D8'
            DangerBottom = '#E8DDAEB5'
        },
        [pscustomobject]@{
            Id = '04-purple-tech'
            Name = '紫蓝星河'
            FileName = '04-purple-tech.png'
            OverlayMode = 'Dark'
            OverlayColor = '#6821163A'
            CardTop = '#963F3562'
            CardBottom = '#88251E45'
            BorderTint = '#88C2A9F0'
            TextPrimary = '#FFF8F3FF'
            TextSecondary = '#FFDCCFEB'
            ButtonTop = '#E06E5A9B'
            ButtonBottom = '#E0473B75'
            ButtonHover = '#F0846DB4'
            ButtonPressed = '#E0382E5E'
            ActiveRowTint = '#C03E70B2'
            ActiveSelectedRowTint = '#E0528DD2'
            SelectedRowTint = '#BF6B4F91'
            ActiveBorderTint = '#FF91C8FF'
            RunningWarningTint = '#FFFF7F91'
            UnknownWarningTint = '#FFFFC56B'
            ColumnHeaderBackgroundTint = '#FF2E254B'
            ColumnHeaderForegroundTint = '#FFF8F3FF'
            ColumnHeaderBorderTint = '#FF9C83C9'
            CurrentYesTint = '#FF7BE0A7'
            CurrentNoTint = '#FFFFC56B'
            AccentTint = '#FF70D09B'
            DangerTop = '#E095627C'
            DangerBottom = '#E070405D'
        },
        [pscustomobject]@{
            Id = '05-light-flow'
            Name = '清透流光'
            FileName = '05-light-flow.png'
            OverlayMode = 'Light'
            OverlayColor = '#4DECF2F6'
            CardTop = '#ADF7FAFC'
            CardBottom = '#9FE3EBF0'
            BorderTint = '#B0FFFFFF'
            TextPrimary = '#FF1F2E3A'
            TextSecondary = '#FF586A78'
            ButtonTop = '#EAF8FBFC'
            ButtonBottom = '#EACBD9E1'
            ButtonHover = '#F8FFFFFF'
            ButtonPressed = '#EAB7C9D3'
            ActiveRowTint = '#D6B2D9F3'
            ActiveSelectedRowTint = '#E794C7E8'
            SelectedRowTint = '#C9DCC8E5'
            ActiveBorderTint = '#FF286FA7'
            RunningWarningTint = '#FFB3261E'
            UnknownWarningTint = '#FF925B00'
            ColumnHeaderBackgroundTint = '#FFDCE8EF'
            ColumnHeaderForegroundTint = '#FF1F2E3A'
            ColumnHeaderBorderTint = '#FF8399A8'
            CurrentYesTint = '#FF176C45'
            CurrentNoTint = '#FF96392F'
            AccentTint = '#FF2F865E'
            DangerTop = '#EAF2D9DC'
            DangerBottom = '#EADDB5BB'
        }
    )
}

function Get-QiehaoSwitchDialogPalette {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Theme
    )

    return [pscustomobject]@{
        Background = [string]$Theme.ColumnHeaderBackgroundTint
        CardTop = [string]$Theme.CardTop
        CardBottom = [string]$Theme.CardBottom
        Border = [string]$Theme.ActiveBorderTint
        Foreground = [string]$Theme.TextPrimary
        Secondary = [string]$Theme.TextSecondary
        Accent = [string]$Theme.ActiveBorderTint
        Warning = [string]$Theme.RunningWarningTint
        Success = [string]$Theme.CurrentYesTint
        ButtonBackground = [string]$Theme.ColumnHeaderForegroundTint
        ButtonForeground = [string]$Theme.ColumnHeaderBackgroundTint
        ButtonBorder = [string]$Theme.ActiveBorderTint
    }
}

function Get-QiehaoBackgroundTheme {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [string]$Id
    )

    foreach ($theme in @(Get-QiehaoBackgroundThemes)) {
        if ($theme.Id -ceq $Id) {
            return $theme
        }
    }
    return $null
}

function Resolve-QiehaoProjectStateDirectory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$GuiScriptRoot
    )

    if ([string]::IsNullOrWhiteSpace($GuiScriptRoot) -or
        -not [System.IO.Path]::IsPathRooted($GuiScriptRoot)) {
        throw 'GUI_SCRIPT_ROOT_INVALID'
    }
    $guiRoot = [System.IO.Path]::GetFullPath($GuiScriptRoot).TrimEnd(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar
    )
    $projectRoot = [System.IO.Path]::GetFullPath(
        (Join-Path -Path $guiRoot -ChildPath '..')
    )
    return [System.IO.Path]::GetFullPath(
        (Join-Path -Path $projectRoot -ChildPath 'state')
    )
}

function Invoke-QiehaoExitButtonAction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock]$ExitAction
    )

    try {
        $null = & $ExitAction
        return [pscustomobject]@{
            Completed = $true
            Failed = $false
        }
    }
    catch {
        return [pscustomobject]@{
            Completed = $false
            Failed = $true
        }
    }
}

function Stop-QiehaoDispatcherTimer {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$Timer,

        [AllowNull()]
        [object]$TickHandler
    )

    if ($null -eq $Timer) {
        return [pscustomobject]@{ Stopped = $false; HandlerRemoved = $false }
    }
    $handlerRemoved = $false
    if ($null -ne $TickHandler) {
        try {
            $Timer.Remove_Tick($TickHandler)
            $handlerRemoved = $true
        }
        catch {
            $handlerRemoved = $false
        }
    }
    try { $Timer.Stop() }
    catch { }
    return [pscustomobject]@{
        Stopped = $true
        HandlerRemoved = $handlerRemoved
    }
}

function New-QiehaoWaitTimerRuntime {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock]$ProbeProvider,

        [Parameter(Mandatory = $true)]
        [scriptblock]$CompletionAction,

        [scriptblock]$ClosingProvider = { $false },

        [scriptblock]$ClockProvider = { [DateTime]::UtcNow },

        [scriptblock]$TimerFactory,

        [ValidateRange(1, 60000)]
        [int]$IntervalMilliseconds = 500,

        [ValidateRange(0.001, 3600)]
        [double]$TimeoutSeconds = 10,

        [ValidateRange(0, 3600)]
        [double]$MilestoneSeconds = 0,

        [scriptblock]$MilestoneAction
    )

    $timer = if ($null -ne $TimerFactory) {
        & $TimerFactory
    }
    else {
        New-Object System.Windows.Threading.DispatcherTimer
    }
    if ($null -eq $timer) { throw 'GUI_WAIT_TIMER_FACTORY_FAILED' }
    $timer.Interval = [TimeSpan]::FromMilliseconds($IntervalMilliseconds)
    $state = [pscustomobject]@{
        StartedAt = [DateTime](& $ClockProvider)
        TimeoutSeconds = $TimeoutSeconds
        MilestoneSeconds = $MilestoneSeconds
        Timer = $timer
        TickHandler = $null
        Active = $true
        Started = $false
        Stopped = $false
        HandlerRemoved = $false
        TickCount = 0
        CallbackFailed = $false
        CompletionFailed = $false
        Result = 'Pending'
        LastProbe = 'Pending'
        ElapsedMilliseconds = 0
        MilestoneReached = $false
        PreviousBlockingProcessCount = $null
        BlockingProcessCount = $null
        BlockingProcessProgress = $false
    }

    $finalize = {
        param([Parameter(Mandatory = $true)][string]$Result)
        if (-not $state.Active) { return }
        $state.Active = $false
        $state.Result = $Result
        $cleanup = Stop-QiehaoDispatcherTimer -Timer $state.Timer `
            -TickHandler $state.TickHandler
        $state.Stopped = [bool]$cleanup.Stopped
        $state.HandlerRemoved = [bool]$cleanup.HandlerRemoved
        try { $null = & $CompletionAction $Result $state }
        catch { $state.CompletionFailed = $true }
    }.GetNewClosure()

    $handler = [System.EventHandler]({
        param($sender, $eventArgs)
        if (-not $state.Active) { return }
        $state.TickCount++
        try {
            if ([bool](& $ClosingProvider)) {
                & $finalize 'Closing'
                return
            }
            $probe = [string](& $ProbeProvider)
            $state.LastProbe = $probe
            if ($probe -ceq 'Succeeded') {
                & $finalize 'Succeeded'
                return
            }
            if ($probe -ceq 'Unknown') {
                & $finalize 'Unknown'
                return
            }
            if ($probe -cne 'Pending') {
                throw 'GUI_WAIT_TIMER_PROBE_INVALID'
            }
            $now = [DateTime](& $ClockProvider)
            $elapsed = $now - $state.StartedAt
            $state.ElapsedMilliseconds = [Math]::Max(
                0,
                [int][Math]::Floor($elapsed.TotalMilliseconds)
            )
            if (-not $state.MilestoneReached -and
                $state.MilestoneSeconds -gt 0 -and
                $elapsed.TotalSeconds -ge $state.MilestoneSeconds) {
                $state.MilestoneReached = $true
                if ($null -ne $MilestoneAction) {
                    $null = & $MilestoneAction $state
                }
            }
            if ($elapsed.TotalSeconds -ge $state.TimeoutSeconds) {
                & $finalize 'TimedOut'
            }
        }
        catch {
            $state.CallbackFailed = $true
            & $finalize 'Error'
        }
    }.GetNewClosure())
    $state.TickHandler = $handler
    $timer.Add_Tick($handler)
    return $state
}

function Start-QiehaoWaitTimerRuntime {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Runtime
    )

    try {
        $Runtime.Timer.Start()
        $Runtime.Started = $true
    }
    catch {
        $null = Stop-QiehaoWaitTimerRuntime -Runtime $Runtime `
            -Result 'StartFailed'
        throw
    }
    return $Runtime
}

function Stop-QiehaoWaitTimerRuntime {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$Runtime,

        [string]$Result = 'Cancelled'
    )

    if ($null -eq $Runtime) {
        return [pscustomobject]@{ Stopped = $false; HandlerRemoved = $false }
    }
    $Runtime.Active = $false
    if ([string]$Runtime.Result -ceq 'Pending') { $Runtime.Result = $Result }
    $cleanup = Stop-QiehaoDispatcherTimer -Timer $Runtime.Timer `
        -TickHandler $Runtime.TickHandler
    $Runtime.Stopped = [bool]$cleanup.Stopped
    $Runtime.HandlerRemoved = [bool]$cleanup.HandlerRemoved
    return $cleanup
}

function Read-QiehaoUiPreferences {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$StateDirectory
    )

    $defaultBackground = '01-blue-glass'
    $preferencePath = Join-Path -Path $StateDirectory `
        -ChildPath 'ui-preferences.json'
    if (-not [System.IO.File]::Exists($preferencePath)) {
        return [pscustomobject]@{
            Background = $defaultBackground
            IsValid = $true
            UsedDefault = $true
        }
    }

    $text = $null
    try {
        $length = ([System.IO.FileInfo]$preferencePath).Length
        if ($length -le 0 -or $length -gt 8192) {
            throw 'UI_PREFERENCES_INVALID'
        }
        $text = [System.IO.File]::ReadAllText($preferencePath)
        $data = ConvertFrom-Json -InputObject $text -ErrorAction Stop
        if ($null -eq $data -or -not ($data -is [pscustomobject])) {
            throw 'UI_PREFERENCES_INVALID'
        }
        $keys = @($data.PSObject.Properties | ForEach-Object { $_.Name })
        if ($keys.Count -ne 2 -or
            -not ($keys -ccontains 'schema_version') -or
            -not ($keys -ccontains 'background') -or
            [int]$data.schema_version -ne 1 -or
            $null -eq (Get-QiehaoBackgroundTheme -Id ([string]$data.background))) {
            throw 'UI_PREFERENCES_INVALID'
        }
        return [pscustomobject]@{
            Background = [string]$data.background
            IsValid = $true
            UsedDefault = $false
        }
    }
    catch {
        return [pscustomobject]@{
            Background = $defaultBackground
            IsValid = $false
            UsedDefault = $true
        }
    }
    finally {
        $text = $null
        $data = $null
    }
}

function Write-QiehaoUiPreferences {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$StateDirectory,

        [Parameter(Mandatory = $true)]
        [string]$Background
    )

    if ($null -eq (Get-QiehaoBackgroundTheme -Id $Background)) {
        throw 'UI_BACKGROUND_THEME_INVALID'
    }
    [System.IO.Directory]::CreateDirectory($StateDirectory) | Out-Null
    $preferencePath = Join-Path -Path $StateDirectory `
        -ChildPath 'ui-preferences.json'
    $temporaryPath = Join-Path -Path $StateDirectory -ChildPath (
        '.ui-preferences.' + [Guid]::NewGuid().ToString('N') + '.tmp'
    )
    $json = $null
    $stream = $null
    $writer = $null
    try {
        $json = [ordered]@{
            schema_version = 1
            background = $Background
        } | ConvertTo-Json
        $encoding = New-Object System.Text.UTF8Encoding($false)
        $stream = New-Object System.IO.FileStream(
            $temporaryPath,
            [System.IO.FileMode]::CreateNew,
            [System.IO.FileAccess]::Write,
            [System.IO.FileShare]::None
        )
        $writer = New-Object System.IO.StreamWriter($stream, $encoding)
        $writer.Write($json)
        $writer.Flush()
        $stream.Flush($true)
        $writer.Dispose()
        $writer = $null
        $stream.Dispose()
        $stream = $null

        if ([System.IO.File]::Exists($preferencePath)) {
            # PowerShell coerces a plain $null string argument to an empty path.
            [System.IO.File]::Replace(
                $temporaryPath,
                $preferencePath,
                [System.Management.Automation.Language.NullString]::Value
            )
        }
        else {
            [System.IO.File]::Move($temporaryPath, $preferencePath)
        }
        return Read-QiehaoUiPreferences -StateDirectory $StateDirectory
    }
    finally {
        if ($null -ne $writer) { $writer.Dispose() }
        if ($null -ne $stream) { $stream.Dispose() }
        if ([System.IO.File]::Exists($temporaryPath)) {
            [System.IO.File]::Delete($temporaryPath)
        }
        $json = $null
    }
}

function Test-QiehaoCustomLaunchPath {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or
        -not [System.IO.Path]::IsPathRooted($Path)) {
        return [pscustomobject]@{ IsValid = $false; FullPath = $null }
    }
    try {
        $fullPath = [System.IO.Path]::GetFullPath($Path.Trim())
        if (-not [System.IO.File]::Exists($fullPath) -or
            [System.IO.Path]::GetExtension($fullPath) -ine '.exe') {
            return [pscustomobject]@{ IsValid = $false; FullPath = $null }
        }
        $fileInfo = [System.IO.FileInfo]$fullPath
        if (($fileInfo.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            return [pscustomobject]@{ IsValid = $false; FullPath = $null }
        }
        return [pscustomobject]@{ IsValid = $true; FullPath = $fullPath }
    }
    catch {
        return [pscustomobject]@{ IsValid = $false; FullPath = $null }
    }
}

function Read-QiehaoLaunchSettings {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$StateDirectory
    )

    $default = [pscustomobject]@{
        Mode = 'Auto'
        CustomPath = ''
        IsValid = $true
        UsedDefault = $true
    }
    $settingsPath = Join-Path -Path $StateDirectory `
        -ChildPath 'codex-launch-settings.json'
    if (-not [System.IO.File]::Exists($settingsPath)) { return $default }

    $text = $null
    $data = $null
    try {
        $length = ([System.IO.FileInfo]$settingsPath).Length
        if ($length -le 0 -or $length -gt 16384) { throw 'LAUNCH_SETTINGS_INVALID' }
        $text = [System.IO.File]::ReadAllText($settingsPath)
        $data = ConvertFrom-Json -InputObject $text -ErrorAction Stop
        $keys = @($data.PSObject.Properties | ForEach-Object { $_.Name })
        if ($keys.Count -ne 3 -or
            -not ($keys -ccontains 'schema_version') -or
            -not ($keys -ccontains 'mode') -or
            -not ($keys -ccontains 'custom_path') -or
            [int]$data.schema_version -ne 1 -or
            @('Auto', 'Custom') -cnotcontains [string]$data.mode) {
            throw 'LAUNCH_SETTINGS_INVALID'
        }
        $customPath = [string]$data.custom_path
        if ([string]$data.mode -ceq 'Custom') {
            $validation = Test-QiehaoCustomLaunchPath -Path $customPath
            if (-not $validation.IsValid) { throw 'LAUNCH_SETTINGS_INVALID' }
            $customPath = [string]$validation.FullPath
        }
        else {
            $customPath = ''
        }
        return [pscustomobject]@{
            Mode = [string]$data.mode
            CustomPath = $customPath
            IsValid = $true
            UsedDefault = $false
        }
    }
    catch {
        return [pscustomobject]@{
            Mode = 'Auto'
            CustomPath = ''
            IsValid = $false
            UsedDefault = $true
        }
    }
    finally {
        $text = $null
        $data = $null
    }
}

function Write-QiehaoLaunchSettings {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$StateDirectory,

        [Parameter(Mandatory = $true)]
        [ValidateSet('Auto', 'Custom')]
        [string]$Mode,

        [AllowNull()]
        [string]$CustomPath = ''
    )

    $safePath = ''
    if ($Mode -ceq 'Custom') {
        $validation = Test-QiehaoCustomLaunchPath -Path $CustomPath
        if (-not $validation.IsValid) { throw 'CODEX_CUSTOM_PATH_INVALID' }
        $safePath = [string]$validation.FullPath
    }
    [System.IO.Directory]::CreateDirectory($StateDirectory) | Out-Null
    $settingsPath = Join-Path -Path $StateDirectory `
        -ChildPath 'codex-launch-settings.json'
    $temporaryPath = Join-Path -Path $StateDirectory -ChildPath (
        '.codex-launch-settings.' + [Guid]::NewGuid().ToString('N') + '.tmp'
    )
    $stream = $null
    $writer = $null
    $json = $null
    try {
        $json = [ordered]@{
            schema_version = 1
            mode = $Mode
            custom_path = $safePath
        } | ConvertTo-Json
        $encoding = New-Object System.Text.UTF8Encoding($false)
        $stream = New-Object System.IO.FileStream(
            $temporaryPath,
            [System.IO.FileMode]::CreateNew,
            [System.IO.FileAccess]::Write,
            [System.IO.FileShare]::None
        )
        $writer = New-Object System.IO.StreamWriter($stream, $encoding)
        $writer.Write($json)
        $writer.Flush()
        $stream.Flush($true)
        $writer.Dispose(); $writer = $null
        $stream.Dispose(); $stream = $null
        if ([System.IO.File]::Exists($settingsPath)) {
            [System.IO.File]::Replace($temporaryPath, $settingsPath, $null)
        }
        else {
            [System.IO.File]::Move($temporaryPath, $settingsPath)
        }
        return Read-QiehaoLaunchSettings -StateDirectory $StateDirectory
    }
    finally {
        if ($null -ne $writer) { $writer.Dispose() }
        if ($null -ne $stream) { $stream.Dispose() }
        if ([System.IO.File]::Exists($temporaryPath)) {
            [System.IO.File]::Delete($temporaryPath)
        }
        $json = $null
    }
}

function Find-QiehaoCodexLaunchTarget {
    [CmdletBinding()]
    param(
        [ValidateSet('Auto', 'Custom')]
        [string]$Mode = 'Auto',

        [AllowNull()]
        [string]$CustomPath = '',

        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$AppxApplications = @(),

        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$StartApps = @()
    )

    if ($Mode -ceq 'Custom') {
        $validation = Test-QiehaoCustomLaunchPath -Path $CustomPath
        if (-not $validation.IsValid) {
            return [pscustomobject]@{
                Available = $false; Type = 'CustomExecutable'
                AppUserModelId = $null; ExecutablePath = $null
                DisplayStatus = '自定义路径无效'; Source = 'Custom'
            }
        }
        return [pscustomobject]@{
            Available = $true; Type = 'CustomExecutable'
            AppUserModelId = $null; ExecutablePath = [string]$validation.FullPath
            DisplayStatus = '已使用自定义文件'; Source = 'Custom'
        }
    }

    foreach ($application in @($AppxApplications)) {
        if ($null -eq $application) { continue }
        $familyProperty = $application.PSObject.Properties['PackageFamilyName']
        $idProperty = $application.PSObject.Properties['ApplicationId']
        if ($null -eq $familyProperty -or $null -eq $idProperty) { continue }
        $family = [string]$familyProperty.Value
        $applicationId = [string]$idProperty.Value
        $aumid = $family + '!' + $applicationId
        if ($family -match '^(?i:OpenAI\.Codex_[A-Za-z0-9]+)$' -and
            $applicationId -match '^[A-Za-z0-9._-]+$' -and
            $aumid -match '^[A-Za-z0-9._-]+![A-Za-z0-9._-]+$') {
            return [pscustomobject]@{
                Available = $true; Type = 'AppUserModelId'
                AppUserModelId = $aumid; ExecutablePath = $null
                DisplayStatus = '已自动检测'; Source = 'AppxManifest'
            }
        }
    }

    foreach ($startApp in @($StartApps)) {
        if ($null -eq $startApp) { continue }
        $appIdProperty = $startApp.PSObject.Properties['AppID']
        if ($null -eq $appIdProperty) { continue }
        $aumid = [string]$appIdProperty.Value
        if ($aumid -match '^(?i:OpenAI\.Codex_[A-Za-z0-9]+![A-Za-z0-9._-]+)$') {
            return [pscustomobject]@{
                Available = $true; Type = 'AppUserModelId'
                AppUserModelId = $aumid; ExecutablePath = $null
                DisplayStatus = '已自动检测'; Source = 'StartApps'
            }
        }
    }

    return [pscustomobject]@{
        Available = $false; Type = 'Unavailable'
        AppUserModelId = $null; ExecutablePath = $null
        DisplayStatus = '未检测到'; Source = 'None'
    }
}

function Invoke-QiehaoCodexLaunchRequest {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$Target,

        [Parameter(Mandatory = $true)]
        [scriptblock]$LaunchProvider,

        [switch]$IsBusy
    )

    if ($IsBusy) {
        return [pscustomobject]@{ Result='OPERATION_BUSY'; LaunchCalled=$false }
    }
    if ($null -eq $Target -or -not [bool]$Target.Available -or
        @('AppUserModelId', 'CustomExecutable') -cnotcontains [string]$Target.Type) {
        return [pscustomobject]@{ Result='CODEX_LAUNCH_TARGET_UNAVAILABLE'; LaunchCalled=$false }
    }
    try {
        $launched = [bool](& $LaunchProvider $Target)
        return [pscustomobject]@{
            Result = if ($launched) { 'CODEX_LAUNCH_REQUESTED' } else { 'CODEX_LAUNCH_FAILED' }
            LaunchCalled = $true
        }
    }
    catch {
        return [pscustomobject]@{ Result='CODEX_LAUNCH_FAILED'; LaunchCalled=$true }
    }
}

function Get-QiehaoBackgroundImage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Theme,

        [Parameter(Mandatory = $true)]
        [string]$BackgroundDirectory
    )

    $failureStage = 'VALIDATE'
    $failureType = $null
    $imageBytes = $null
    $memoryStream = $null
    try {
        $knownTheme = Get-QiehaoBackgroundTheme -Id ([string]$Theme.Id)
        if ($null -eq $knownTheme -or
            $knownTheme.FileName -cne [string]$Theme.FileName) {
            throw 'UI_BACKGROUND_THEME_INVALID'
        }
        $root = [System.IO.Path]::GetFullPath($BackgroundDirectory).TrimEnd(
            [System.IO.Path]::DirectorySeparatorChar,
            [System.IO.Path]::AltDirectorySeparatorChar
        )
        $path = [System.IO.Path]::GetFullPath(
            (Join-Path -Path $root -ChildPath $knownTheme.FileName)
        )
        $parent = [System.IO.Path]::GetDirectoryName($path).TrimEnd(
            [System.IO.Path]::DirectorySeparatorChar,
            [System.IO.Path]::AltDirectorySeparatorChar
        )
        if (-not $parent.Equals($root, [StringComparison]::OrdinalIgnoreCase) -or
            -not [System.IO.File]::Exists($path)) {
            throw 'UI_BACKGROUND_IMAGE_UNAVAILABLE'
        }

        $failureStage = 'LOAD_ASSEMBLY'
        Add-Type -AssemblyName PresentationCore -ErrorAction Stop
        $failureStage = 'READ_BYTES'
        $imageBytes = [System.IO.File]::ReadAllBytes($path)
        $failureStage = 'CREATE_STREAM'
        $memoryStream = [System.IO.MemoryStream]::new()
        $memoryStream.Write($imageBytes, 0, $imageBytes.Length)
        $memoryStream.Position = 0
        $failureStage = 'DECODE_BITMAP_FRAME'
        $bitmap = [System.Windows.Media.Imaging.BitmapFrame]::Create(
            $memoryStream,
            [System.Windows.Media.Imaging.BitmapCreateOptions]::IgnoreImageCache,
            [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
        )
        $failureStage = 'FREEZE_BITMAP'
        $bitmap.Freeze()
        return [pscustomobject]@{
            Loaded = $true
            ThemeId = $knownTheme.Id
            ImageSource = $bitmap
            UsedSolidFallback = $false
            FailureStage = $null
        }
    }
    catch {
        $failureType = $_.Exception.GetType().Name
        if ($null -ne $_.Exception.InnerException) {
            $failureType += '_' + $_.Exception.InnerException.GetType().Name
        }
        return [pscustomobject]@{
            Loaded = $false
            ThemeId = [string]$Theme.Id
            ImageSource = $null
            UsedSolidFallback = $true
            FailureStage = $failureStage
            FailureType = $failureType
        }
    }
    finally {
        if ($null -ne $memoryStream) {
            $memoryStream.Dispose()
        }
        $imageBytes = $null
    }
}

function Enter-QiehaoGuiSingleInstance {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$MutexName
    )

    $createdNew = $false
    $mutex = $null
    try {
        $mutex = [System.Threading.Mutex]::new(
            $true,
            $MutexName,
            [ref]$createdNew
        )
        if (-not $createdNew) {
            $mutex.Dispose()
            $mutex = $null
        }
        return [pscustomobject]@{
            Acquired = $createdNew
            Mutex = $mutex
        }
    }
    catch {
        if ($null -ne $mutex) {
            $mutex.Dispose()
        }
        throw
    }
}

function Exit-QiehaoGuiSingleInstance {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$Lease
    )

    if ($null -eq $Lease -or -not [bool]$Lease.Acquired -or
        $null -eq $Lease.Mutex) {
        return
    }
    try {
        $Lease.Mutex.ReleaseMutex()
    }
    catch [System.ApplicationException] {
        # The lease was not owned by this thread. Disposal is still required.
    }
    finally {
        $Lease.Mutex.Dispose()
    }
}

Export-ModuleMember -Function @(
    'ConvertTo-QiehaoGuiProfileRows',
    'Invoke-QiehaoOptionalProfileRowEnrichment',
    'ConvertTo-QiehaoCodexStatus',
    'ConvertTo-QiehaoActiveIdentityStatus',
    'ConvertTo-QiehaoVerifyMessage',
    'Invoke-QiehaoVerifyRequest',
    'ConvertTo-QiehaoOperationResult',
    'Invoke-QiehaoOperationProvider',
    'Invoke-QiehaoSwitchUiCompletion',
    'Select-QiehaoProfileRows',
    'Get-QiehaoActionState',
    'Invoke-QiehaoSwitchRequest',
    'ConvertTo-QiehaoExitMessage',
    'Get-QiehaoGuiSnapshot',
    'Get-QiehaoBackgroundThemes',
    'Get-QiehaoBackgroundTheme',
    'Get-QiehaoSwitchDialogPalette',
    'Resolve-QiehaoProjectStateDirectory',
    'Invoke-QiehaoExitButtonAction',
    'Stop-QiehaoDispatcherTimer',
    'New-QiehaoWaitTimerRuntime',
    'Start-QiehaoWaitTimerRuntime',
    'Stop-QiehaoWaitTimerRuntime',
    'Read-QiehaoUiPreferences',
    'Write-QiehaoUiPreferences',
    'Test-QiehaoCustomLaunchPath',
    'Read-QiehaoLaunchSettings',
    'Write-QiehaoLaunchSettings',
    'Find-QiehaoCodexLaunchTarget',
    'Invoke-QiehaoCodexLaunchRequest',
    'Get-QiehaoBackgroundImage',
    'Enter-QiehaoGuiSingleInstance',
    'Exit-QiehaoGuiSingleInstance'
)
