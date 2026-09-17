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
            $message = 'Codex 仍有后台进程，请从系统托盘退出后重试。'
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

        [switch]$ExitInProgress
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
        ExitCodex = $available -and -not $ExitInProgress -and
            $CodexStatus -ceq '运行中'
        ContextSwitch = $available -and $hasSelection -and -not $isActive
        ContextVerify = $available -and $hasSelection -and
            $CodexStatus -ceq '已退出'
        ContextRename = $available -and $hasSelection
        ContextDelete = $available -and $hasSelection -and -not $isActive
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

        [scriptblock]$ConfirmExitProvider = { $false },

        [scriptblock]$ExitProvider = { $null },

        [scriptblock]$WaitForStopProvider = { param($TimeoutSeconds) $null },

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
        if (-not [bool](& $ConfirmExitProvider)) {
            $mapped = ConvertTo-QiehaoOperationResult -ResultCode 'OPERATION_CANCELLED'
            $mapped | Add-Member -NotePropertyName CoreCalled -NotePropertyValue $false
            return $mapped
        }
        try {
            $exitResult = & $ExitProvider
            $exitCode = Get-QiehaoSafeResultCode -Result $exitResult `
                -Fallback 'CODEX_PROCESS_STATE_UNKNOWN'
        }
        catch {
            $exitCode = 'CODEX_PROCESS_STATE_UNKNOWN'
        }
        if ($exitCode -cne 'CODEX_CLOSE_REQUESTED' -and
            $exitCode -cne 'CODEX_ALREADY_STOPPED') {
            $mapped = ConvertTo-QiehaoOperationResult `
                -ResultCode 'CODEX_PROCESS_STATE_UNKNOWN'
            $mapped | Add-Member -NotePropertyName CoreCalled -NotePropertyValue $false
            return $mapped
        }
        try {
            $postExitStatus = ConvertTo-QiehaoCodexStatus `
                -ProcessState (& $WaitForStopProvider 10)
        }
        catch {
            $postExitStatus = '未知'
        }
        if ($postExitStatus -ceq '运行中') {
            $mapped = ConvertTo-QiehaoOperationResult -ResultCode 'CODEX_EXIT_TIMEOUT'
            $mapped | Add-Member -NotePropertyName CoreCalled -NotePropertyValue $false
            return $mapped
        }
        if ($postExitStatus -cne '已退出') {
            $mapped = ConvertTo-QiehaoOperationResult `
                -ResultCode 'CODEX_EXIT_STATE_UNKNOWN'
            $mapped | Add-Member -NotePropertyName CoreCalled -NotePropertyValue $false
            return $mapped
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
        'CODEX_MAIN_WINDOW_NOT_FOUND' {
            return '未找到可安全关闭的 Codex 主窗口，请在系统托盘中选择退出，然后点击“刷新”。'
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

function Get-QiehaoGuiSnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock]$ListProvider,

        [Parameter(Mandatory = $true)]
        [scriptblock]$ActiveProvider,

        [Parameter(Mandatory = $true)]
        [scriptblock]$ProcessProvider
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

    return [pscustomobject]@{
        CodexDesktop = $codexStatus
        ActiveProfile = $activeProfile
        IdentityStatus = '未检查'
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
        },
        [pscustomobject]@{
            Id = '02-navy-gold'
            Name = '深蓝鎏金'
            FileName = '02-navy-gold.png'
            OverlayMode = 'Dark'
        },
        [pscustomobject]@{
            Id = '03-ice-glass'
            Name = '冰蓝玻璃'
            FileName = '03-ice-glass.png'
            OverlayMode = 'Light'
        },
        [pscustomobject]@{
            Id = '04-purple-tech'
            Name = '紫蓝星河'
            FileName = '04-purple-tech.png'
            OverlayMode = 'Dark'
        },
        [pscustomobject]@{
            Id = '05-light-flow'
            Name = '清透流光'
            FileName = '05-light-flow.png'
            OverlayMode = 'Light'
        }
    )
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
            [System.IO.File]::Replace($temporaryPath, $preferencePath, $null)
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
    'ConvertTo-QiehaoCodexStatus',
    'ConvertTo-QiehaoVerifyMessage',
    'Invoke-QiehaoVerifyRequest',
    'ConvertTo-QiehaoOperationResult',
    'Invoke-QiehaoOperationProvider',
    'Select-QiehaoProfileRows',
    'Get-QiehaoActionState',
    'Invoke-QiehaoSwitchRequest',
    'ConvertTo-QiehaoExitMessage',
    'Get-QiehaoGuiSnapshot',
    'Get-QiehaoBackgroundThemes',
    'Get-QiehaoBackgroundTheme',
    'Read-QiehaoUiPreferences',
    'Write-QiehaoUiPreferences',
    'Get-QiehaoBackgroundImage',
    'Enter-QiehaoGuiSingleInstance',
    'Exit-QiehaoGuiSingleInstance'
)
