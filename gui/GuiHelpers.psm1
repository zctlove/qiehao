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

function ConvertTo-QiehaoUpdatedDisplay {
    param(
        [AllowNull()]
        [object]$Value
    )

    $candidate = [string]$Value
    if ([string]::IsNullOrWhiteSpace($candidate)) {
        return '<UNAVAILABLE>'
    }
    if ($candidate -ceq '<UNAVAILABLE>' -or
        $candidate -ceq '<INVALID_METADATA>') {
        return $candidate
    }
    $parsed = [DateTime]::MinValue
    if ([DateTime]::TryParse(
        $candidate,
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::RoundtripKind,
        [ref]$parsed
    )) {
        return $parsed.ToString(
            'yyyy-MM-dd HH:mm:ss',
            [Globalization.CultureInfo]::InvariantCulture
        )
    }
    return $candidate
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
            $activeCode = if ($name.Equals(
                $ActiveProfile,
                [StringComparison]::OrdinalIgnoreCase
            )) { 'Yes' } else { 'No' }
            $activeText = if ($name.Equals(
                $ActiveProfile,
                [StringComparison]::OrdinalIgnoreCase
            )) { '是' } else { '否' }
        }
        else {
            $activeValue = Get-ObjectPropertyValue -InputObject $item `
                -Name 'Active' -DefaultValue $null
            if ($activeValue -is [bool]) {
                $activeCode = if ([bool]$activeValue) { 'Yes' } else { 'No' }
                $activeText = if ([bool]$activeValue) { '是' } else { '否' }
            }
            else {
                $activeCode = 'Unknown'
                $activeText = '未知'
            }
        }

        $healthCode = [string](Get-ObjectPropertyValue -InputObject $item `
            -Name 'Health' -DefaultValue 'UNKNOWN')
        $authCode = [string](Get-ObjectPropertyValue -InputObject $item `
            -Name 'AuthFile' -DefaultValue 'UNKNOWN')
        $identityCode = [string](Get-ObjectPropertyValue -InputObject $item `
            -Name 'IdentityMarker' -DefaultValue 'UNKNOWN')
        $metadataCode = [string](Get-ObjectPropertyValue -InputObject $item `
            -Name 'Metadata' -DefaultValue 'UNKNOWN')
        $updatedRaw = [string](Get-ObjectPropertyValue -InputObject $item `
            -Name 'UpdatedAt' -DefaultValue '<UNAVAILABLE>')
        if ([string]::IsNullOrWhiteSpace($updatedRaw)) {
            $updatedRaw = '<UNAVAILABLE>'
        }
        $updatedDisplay = ConvertTo-QiehaoUpdatedDisplay -Value $updatedRaw
        switch ($updatedDisplay) {
            '<UNAVAILABLE>' { $updatedDisplay = '不可用' }
            '<INVALID_METADATA>' { $updatedDisplay = '元数据异常' }
        }

        $rows += [pscustomobject]@{
            Name = $name
            ActiveCode = $activeCode
            Active = $activeText
            VerificationCode = 'Unverified'
            Verification = '未验证'
            HealthCode = $healthCode
            Health = ConvertTo-QiehaoProfileDisplayValue -Category 'Health' `
                -Value $healthCode
            AuthCode = $authCode
            Auth = ConvertTo-QiehaoProfileDisplayValue -Category 'Artifact' `
                -Value $authCode
            IdentityCode = $identityCode
            Identity = ConvertTo-QiehaoProfileDisplayValue -Category 'Artifact' `
                -Value $identityCode
            MetadataCode = $metadataCode
            Metadata = ConvertTo-QiehaoProfileDisplayValue -Category 'Metadata' `
                -Value $metadataCode
            UpdatedCode = if ($updatedDisplay -eq '不可用') {
                'Unavailable'
            }
            elseif ($updatedDisplay -eq '元数据异常') { 'InvalidMetadata' }
            else { 'Value' }
            UpdatedRaw = $updatedRaw
            UpdatedDisplay = $updatedDisplay
            Updated = $updatedDisplay
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
        [scriptblock]$Enrichment,

        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$EnrichmentArguments = @()
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
        $null = & $Enrichment @EnrichmentArguments
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
        'PROFILE_VERIFY_SUCCESS' { return '账号资料完整，且与当前 Codex 身份一致' }
        'PROFILE_VERIFY_IDENTITY_MISMATCH' {
            return '账号资料完整，但与当前 Codex 登录身份或工作区不一致'
        }
        'PROFILE_VERIFY_WORKSPACE_CONTEXT_UNKNOWN' {
            return '账号资料完整，但旧版身份缺少可确认的工作区上下文，不能显示为完整验证成功'
        }
        'PROFILE_INCOMPLETE' { return '账号资料不完整' }
        'PROFILE_IDENTITY_MISMATCH' { return '账号身份标记不匹配' }
        'PROFILE_IDENTITY_MARKER_MISSING' { return '身份标记缺失' }
        'PROFILE_METADATA_INVALID' { return '元数据异常' }
        'AUTH_CREDENTIAL_SOURCE_UNSUPPORTED' {
            return 'Codex 当前使用本版本不支持的凭据存储来源'
        }
        'AUTH_CREDENTIAL_SOURCE_AMBIGUOUS' {
            return 'Codex 当前凭据来源为自动模式，无法安全确认文件凭据是实际登录来源'
        }
        'AUTH_CREDENTIAL_SOURCE_UNKNOWN' {
            return '无法安全确认 Codex 当前凭据来源'
        }
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
    $result = $null
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
            'PROFILE_VERIFY_IDENTITY_MISMATCH',
            'PROFILE_VERIFY_WORKSPACE_CONTEXT_UNKNOWN',
            'PROFILE_IDENTITY_MARKER_MISSING',
            'PROFILE_METADATA_INVALID',
            'AUTH_CREDENTIAL_SOURCE_UNSUPPORTED',
            'AUTH_CREDENTIAL_SOURCE_AMBIGUOUS',
            'AUTH_CREDENTIAL_SOURCE_UNKNOWN',
            'CODEX_PROCESS_RUNNING',
            'CODEX_PROCESS_STATE_UNKNOWN',
            'OPERATION_BUSY'
        )
        if ($safeCodes -ccontains [string]$_.Exception.Message) {
            $resultCode = [string]$_.Exception.Message
        }
    }

    $success = $resultCode -ceq 'PROFILE_VERIFY_SUCCESS'
    $output = [pscustomobject]@{
        CoreCalled = $true
        ResultCode = $resultCode
        Message = ConvertTo-QiehaoVerifyMessage -ResultCode $resultCode
        VerificationStatus = if ($success) { '已验证' } else { '验证失败' }
    }
    foreach ($propertyName in @(
        'ProfileIntegrity',
        'SavedWorkspaceClass',
        'CurrentWorkspaceClass',
        'WorkspaceContextStatus',
        'CredentialSource',
        'CredentialSourceConfidence'
    )) {
        if ($null -ne $result -and
            $null -ne $result.PSObject.Properties[$propertyName]) {
            $output | Add-Member -NotePropertyName $propertyName `
                -NotePropertyValue $result.$propertyName
        }
    }
    return $output
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
            'ACTIVE_PROFILE_OUT_OF_SYNC',
            'ACTIVE_PROFILE_SYNCED',
            'ACTIVE_PROFILE_SYNC_FAILED',
            'ACTIVE_PROFILE_IDENTITY_MISMATCH',
            'PROFILE_IDENTITY_MISMATCH',
            'PROFILE_IDENTITY_MARKER_MISSING',
            'PROFILE_IDENTITY_MARKER_INVALID',
            'AUTH_FILE_NOT_FOUND',
            'AUTH_FILE_EMPTY',
            'AUTH_FILE_READ_FAILED',
            'AUTH_JSON_INVALID',
            'AUTH_SCHEMA_UNEXPECTED',
            'AUTH_IDENTITY_SCHEMA_UNRECOGNIZED',
            'AUTH_CREDENTIAL_SOURCE_UNSUPPORTED',
            'AUTH_CREDENTIAL_SOURCE_AMBIGUOUS',
            'AUTH_CREDENTIAL_SOURCE_UNKNOWN',
            'CODEX_HOME_NOT_FOUND',
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
            'PROFILE_DELETE_SAFE',
            'PROFILE_DELETE_ACTIVE_OUT_OF_SYNC',
            'PROFILE_DELETE_IDENTITY_UNKNOWN',
            'CANNOT_REMOVE_CURRENT_CODEX_PROFILE',
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
        'ACTIVE_PROFILE_OUT_OF_SYNC' {
            $message = 'Qiehao 记录的当前账号与 Codex 实际登录账号不同。未修改任何账号数据。'
        }
        'ACTIVE_PROFILE_SYNCED' {
            $message = '已将 Qiehao 当前账号状态同步为 Codex 实际登录的本地账号。'
            $success = $true; $refresh = $true
        }
        'ACTIVE_PROFILE_SYNC_FAILED' {
            $message = '无法安全同步当前账号状态。未修改任何账号凭据。'
        }
        'ACTIVE_PROFILE_IDENTITY_MISMATCH' {
            $message = '当前账号身份与本地记录不一致，已阻止操作。'
        }
        'PROFILE_IDENTITY_MISMATCH' { $message = '目标账号身份验证失败。' }
        'PROFILE_IDENTITY_MARKER_MISSING' { $message = '目标账号身份标记缺失。' }
        'PROFILE_IDENTITY_MARKER_INVALID' { $message = '目标账号身份标记异常。' }
        'AUTH_FILE_NOT_FOUND' {
            $message = "未检测到可导入的 Codex 登录凭据。`n`n请启动 Codex，使用官方流程完成目标账号登录。确认登录成功后，请完全退出 Codex 客户端（不要注销当前账号），然后返回 Qiehao 再次点击「添加账号」。`n`n如果完成登录并退出后仍然出现此提示，当前 Codex 可能使用系统凭据库存储登录信息，本版本暂不支持直接导入该存储方式。`n`n未修改任何 Codex 登录状态。"
        }
        'AUTH_FILE_EMPTY' {
            $message = 'Codex 登录文件为空，无法安全采集账号。未修改任何 Codex 登录状态。'
        }
        'AUTH_FILE_READ_FAILED' {
            $message = '无法安全读取 Codex 登录文件。请确认 Codex 已完全退出后重试；未修改任何 Codex 登录状态。'
        }
        'AUTH_JSON_INVALID' {
            $message = 'Codex 登录文件不是有效的 JSON，可能已损坏。未修改任何账号数据。'
        }
        'AUTH_SCHEMA_UNEXPECTED' {
            $message = '当前 Codex 登录文件结构暂无法兼容，未修改任何账号数据。'
        }
        'AUTH_IDENTITY_SCHEMA_UNRECOGNIZED' {
            $message = '当前 Codex 登录文件缺少可安全验证的 ChatGPT 账号身份，未修改任何账号数据。'
        }
        'AUTH_CREDENTIAL_SOURCE_UNSUPPORTED' {
            $message = 'Codex 当前使用系统凭据库或临时凭据存储；Qiehao 无法安全确认 auth.json 是实际登录来源。未修改任何账号数据。'
        }
        'AUTH_CREDENTIAL_SOURCE_AMBIGUOUS' {
            $message = 'Codex 当前使用自动凭据存储模式，无法安全确认文件凭据与实际登录身份一致。未修改任何账号数据。'
        }
        'AUTH_CREDENTIAL_SOURCE_UNKNOWN' {
            $message = '无法安全确认 Codex 当前凭据来源。未修改任何账号数据。'
        }
        'CODEX_HOME_NOT_FOUND' {
            $message = '未找到 Codex 本地数据目录，无法采集登录凭据。未修改任何 Codex 登录状态。'
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
            $message = '已识别当前 Codex 登录账号，凭据已安全保存，账号添加成功。'
            $success = $true; $refresh = $true
        }
        'PROFILE_NAME_ALREADY_EXISTS' { $message = '该本地账号名称已经存在。' }
        'PROFILE_IDENTITY_ALREADY_EXISTS' {
            $message = '当前 Codex 登录账号已保存在本地账号列表中，不会重复添加。'
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
        'PROFILE_DELETE_SAFE' {
            $message = '已确认所选账号不是 Codex 当前实际登录账号。'
            $success = $true
        }
        'PROFILE_DELETE_ACTIVE_OUT_OF_SYNC' {
            $message = 'Qiehao 的当前账号记录已过期。可先同步到 Codex 实际登录的已保存账号，再删除所选旧账号；尚未删除任何文件。'
        }
        'PROFILE_DELETE_IDENTITY_UNKNOWN' {
            $message = '当前 Codex 登录身份不属于可确认的本地账号，无法安全解除当前账号保护。尚未删除任何文件。'
        }
        'CANNOT_REMOVE_CURRENT_CODEX_PROFILE' {
            $message = '不能删除 Codex 当前实际登录的账号。请先安全切换到另一个已保存账号。'
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
        [ValidateSet(
            'SWITCH', 'ADD', 'RENAME', 'DELETE', 'SAVE_ACTIVE', 'SYNC_ACTIVE'
        )]
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
        'SYNC_ACTIVE' { 'ACTIVE_PROFILE_SYNC_FAILED' }
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
        Switch = $available -and $hasSelection
        Verify = $available -and $hasSelection -and $CodexStatus -ceq '已退出'
        Add = $available
        Rename = $available -and $hasSelection
        Delete = $available -and $hasSelection -and
            $CodexStatus -ceq '已退出'
        ContextSwitch = $available -and $hasSelection
        ContextVerify = $available -and $hasSelection -and
            $CodexStatus -ceq '已退出'
        ContextRename = $available -and $hasSelection
        ContextDelete = $available -and $hasSelection -and
            $CodexStatus -ceq '已退出'
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
    $codexState = switch ($codexStatus) {
        '运行中' { 'Running' }
        '已退出' { 'Stopped' }
        default { 'Unknown' }
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

    $identityState = switch ($identityStatus) {
        '已确认' { 'Confirmed' }
        '不匹配' { 'Mismatch' }
        '尚未初始化' { 'Uninitialized' }
        '待退出后确认' { 'PendingExit' }
        default { 'Unavailable' }
    }

    return [pscustomobject]@{
        CodexState = $codexState
        CodexDesktop = $codexStatus
        ActiveProfileKnown = $activeProfileKnown
        ActiveProfile = $activeProfile
        IdentityState = $identityState
        IdentityStatus = $identityStatus
        WebChatGPTState = 'Unaffected'
        WebChatGPT = '不受影响'
        Profiles = @($rows)
        ReadOnlyErrors = @($errors)
    }
}

function Get-QiehaoBackgroundThemes {
    [CmdletBinding()]
    param()

    $themes = @(
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
            OverlayColor = '#24E9F8FF'
            CardTop = '#82F8FCFF'
            CardBottom = '#70D6EEFB'
            BorderTint = '#B8F5FCFF'
            TextPrimary = '#FF102C43'
            TextSecondary = '#FF385D75'
            ButtonTop = '#B8FAFDFF'
            ButtonBottom = '#9ED5EBF7'
            ButtonHover = '#D8FFFFFF'
            ButtonPressed = '#B2ACD1E2'
            ActiveRowTint = '#A29FD5F2'
            ActiveSelectedRowTint = '#C37CBCE7'
            SelectedRowTint = '#92C5E4F5'
            ActiveBorderTint = '#FF1E7DB8'
            RunningWarningTint = '#FFB42318'
            UnknownWarningTint = '#FF9A5A00'
            ColumnHeaderBackgroundTint = '#FFD8EFFA'
            ColumnHeaderForegroundTint = '#FF102C43'
            ColumnHeaderBorderTint = '#B1699CBC'
            CurrentYesTint = '#FF146C43'
            CurrentNoTint = '#FF9C3B2F'
            AccentTint = '#FF27845A'
            DangerTop = '#C8FFF5F6'
            DangerBottom = '#B8F2C6CD'
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
            OverlayColor = '#18F0FCFF'
            CardTop = '#7CFAFDFF'
            CardBottom = '#68D8F3F7'
            BorderTint = '#B2F4FEFF'
            TextPrimary = '#FF15313D'
            TextSecondary = '#FF3A626D'
            ButtonTop = '#B2FBFEFF'
            ButtonBottom = '#98CDEBEF'
            ButtonHover = '#D5FFFFFF'
            ButtonPressed = '#ADB1D6DA'
            ActiveRowTint = '#9FB3E1EC'
            ActiveSelectedRowTint = '#C084CAD8'
            SelectedRowTint = '#90C8E9E7'
            ActiveBorderTint = '#FF167F9C'
            RunningWarningTint = '#FFB3261E'
            UnknownWarningTint = '#FF925B00'
            ColumnHeaderBackgroundTint = '#FFDDF1F4'
            ColumnHeaderForegroundTint = '#FF15313D'
            ColumnHeaderBorderTint = '#AA689DA8'
            CurrentYesTint = '#FF176C45'
            CurrentNoTint = '#FF96392F'
            AccentTint = '#FF2F865E'
            DangerTop = '#C5FFF6F7'
            DangerBottom = '#B5F1C8CD'
        },
        [pscustomobject]@{
            Id = '06-aurora-silver-blue'
            Name = '极光银蓝'
            FileName = '06-aurora-silver-blue.png'
            OverlayMode = 'Light'
            OverlayColor = '#1CECF7FF'
            CardTop = '#80F8FCFF'
            CardBottom = '#6CC8E2F4'
            BorderTint = '#BAF7FCFF'
            TextPrimary = '#FF163047'
            TextSecondary = '#FF3D5F77'
            ButtonTop = '#B0FBFDFF'
            ButtonBottom = '#98D1E3F3'
            ButtonHover = '#D6FFFFFF'
            ButtonPressed = '#AAB6CEE5'
            ActiveRowTint = '#9EA9CDED'
            ActiveSelectedRowTint = '#C17FAFE0'
            SelectedRowTint = '#90C2D7EF'
            ActiveBorderTint = '#FF2878B5'
            RunningWarningTint = '#FFA81712'
            UnknownWarningTint = '#FF885000'
            ColumnHeaderBackgroundTint = '#FFD9EAF7'
            ColumnHeaderForegroundTint = '#FF163047'
            ColumnHeaderBorderTint = '#B36D91B2'
            CurrentYesTint = '#FF126840'
            CurrentNoTint = '#FF91352D'
            AccentTint = '#FF4778A8'
            DangerTop = '#C7FFF5F6'
            DangerBottom = '#B7F1C4CD'
        },
        [pscustomobject]@{
            Id = '07-arctic-sea-glass'
            Name = '浅海冰晶'
            FileName = '07-arctic-sea-glass.png'
            OverlayMode = 'Light'
            OverlayColor = '#20E9FCFF'
            CardTop = '#84F7FEFF'
            CardBottom = '#70BFEAF1'
            BorderTint = '#BEF2FFFF'
            TextPrimary = '#FF11343F'
            TextSecondary = '#FF35636C'
            ButtonTop = '#B4FBFFFF'
            ButtonBottom = '#9BC7ECEF'
            ButtonHover = '#DAFFFFFF'
            ButtonPressed = '#ADB1DDE1'
            ActiveRowTint = '#9B8DD5DC'
            ActiveSelectedRowTint = '#C174C6CF'
            SelectedRowTint = '#8FC4ECE8'
            ActiveBorderTint = '#FF087E91'
            RunningWarningTint = '#FFA71B17'
            UnknownWarningTint = '#FF875400'
            ColumnHeaderBackgroundTint = '#FFD7F0F2'
            ColumnHeaderForegroundTint = '#FF11343F'
            ColumnHeaderBorderTint = '#AF5C9DA8'
            CurrentYesTint = '#FF126647'
            CurrentNoTint = '#FF91362F'
            AccentTint = '#FF217E75'
            DangerTop = '#C8FFF5F5'
            DangerBottom = '#B8EFC4C9'
        }
    )

    $semanticPalettes = [ordered]@{
        '01-blue-glass' = [ordered]@{
            TextMuted = '#FF9FB2C4'; Primary = '#FF2E6FAF'
            PrimaryHover = '#FF3E82C7'; PrimaryPressed = '#FF245A91'
            Positive = '#FF2D7D5A'; PositiveHover = '#FF38976C'
            PositivePressed = '#FF246649'; Info = '#FF247A91'
            InfoHover = '#FF2D91AB'; InfoPressed = '#FF1D6377'
            Accent = '#FF585FA8'; AccentHover = '#FF6C74C2'
            AccentPressed = '#FF474D8D'; Secondary = '#B83D5369'
            SecondaryHover = '#D04B657F'; SecondaryPressed = '#D032465B'
            Danger = '#FF9D4451'; DangerHover = '#FFB65260'
            DangerPressed = '#FF833743'; ControlBackground = '#C41B2B3D'
            ControlBorder = '#AA6F91B2'; GridHover = '#3A7EC8FF'
            FocusRing = '#FF8CCBFF'; ToolTipBackground = '#F01B2B3D'
            ToolTipBorder = '#CC7EC8FF'; ToolTipForeground = '#FFF7FBFF'
            ButtonOnAccent = '#FFF7FBFF'; DisabledBackground = '#A0445362'
            BrandWatermark = '#2D7EC8FF'
        }
        '02-navy-gold' = [ordered]@{
            TextMuted = '#FFB5AA90'; Primary = '#FF356D9B'
            PrimaryHover = '#FF4383B6'; PrimaryPressed = '#FF2A587F'
            Positive = '#FF3E7758'; PositiveHover = '#FF4B8C69'
            PositivePressed = '#FF326047'; Info = '#FF3C7282'
            InfoHover = '#FF4A8798'; InfoPressed = '#FF305D6A'
            Accent = '#FF6B5C94'; AccentHover = '#FF806FAC'
            AccentPressed = '#FF574B79'; Secondary = '#B8444652'
            SecondaryHover = '#D0565866'; SecondaryPressed = '#D0373945'
            Danger = '#FFA14C56'; DangerHover = '#FFB95C66'
            DangerPressed = '#FF853E47'; ControlBackground = '#C4181D29'
            ControlBorder = '#AA8F8058'; GridHover = '#3AC7A85C'
            FocusRing = '#FFE0C477'; ToolTipBackground = '#F0181D29'
            ToolTipBorder = '#CCD2B86E'; ToolTipForeground = '#FFFFF9EB'
            ButtonOnAccent = '#FFFFF9EB'; DisabledBackground = '#A04D4D52'
            BrandWatermark = '#2AD2B86E'
        }
        '03-ice-glass' = [ordered]@{
            TextMuted = '#FF557386'; Primary = '#FF1F74AE'
            PrimaryHover = '#FF2D83C3'; PrimaryPressed = '#FF1C5B8B'
            Positive = '#FF2E7657'; PositiveHover = '#FF388C67'
            PositivePressed = '#FF255F46'; Info = '#FF2C7187'
            InfoHover = '#FF37869E'; InfoPressed = '#FF245B6D'
            Accent = '#FF5B569E'; AccentHover = '#FF6C66B6'
            AccentPressed = '#FF4A4682'; Secondary = '#9ECFE6F2'
            SecondaryHover = '#BCEAF7FC'; SecondaryPressed = '#A4B5D6E6'
            Danger = '#FFB03D4A'; DangerHover = '#FFC34D5A'
            DangerPressed = '#FF922F3B'; ControlBackground = '#A6FAFDFF'
            ControlBorder = '#A0649BBD'; GridHover = '#6687C9E8'
            FocusRing = '#FF1F7FB9'; ToolTipBackground = '#EE17364B'
            ToolTipBorder = '#D05296BE'; ToolTipForeground = '#FFF7FBFF'
            ButtonOnAccent = '#FFFFFFFF'; DisabledBackground = '#A6C5DCE7'
            CardShadow = '#30285B76'; GridHeader = '#A4D8EFFA'
            BrandWatermark = '#221F7FB9'
        }
        '04-purple-tech' = [ordered]@{
            TextMuted = '#FFB6A7C8'; Primary = '#FF446EAA'
            PrimaryHover = '#FF5483C2'; PrimaryPressed = '#FF375A8D'
            Positive = '#FF3A7D5B'; PositiveHover = '#FF47936B'
            PositivePressed = '#FF2F664A'; Info = '#FF347B92'
            InfoHover = '#FF4091AA'; InfoPressed = '#FF2A6477'
            Accent = '#FF6754A3'; AccentHover = '#FF7B66BC'
            AccentPressed = '#FF554586'; Secondary = '#B84B4162'
            SecondaryHover = '#D05E5277'; SecondaryPressed = '#D03D3550'
            Danger = '#FFA34861'; DangerHover = '#FFBA5972'
            DangerPressed = '#FF863A50'; ControlBackground = '#C4292244'
            ControlBorder = '#AAA18AC9'; GridHover = '#3AAE8DE0'
            FocusRing = '#FFA9D4FF'; ToolTipBackground = '#F0292244'
            ToolTipBorder = '#CCC2A9F0'; ToolTipForeground = '#FFF8F3FF'
            ButtonOnAccent = '#FFF8F3FF'; DisabledBackground = '#A0524964'
            BrandWatermark = '#2CA9D4FF'
        }
        '05-light-flow' = [ordered]@{
            TextMuted = '#FF5B7880'; Primary = '#FF287DAD'
            PrimaryHover = '#FF3283C1'; PrimaryPressed = '#FF205B89'
            Positive = '#FF317653'; PositiveHover = '#FF3B8B62'
            PositivePressed = '#FF285F43'; Info = '#FF2D7186'
            InfoHover = '#FF38869C'; InfoPressed = '#FF255C6C'
            Accent = '#FF426F9A'; AccentHover = '#FF5685B1'
            AccentPressed = '#FF365C81'; Secondary = '#98CCE4E7'
            SecondaryHover = '#BAE9F7F8'; SecondaryPressed = '#A0B2D4D8'
            Danger = '#FFAE3E49'; DangerHover = '#FFC14E59'
            DangerPressed = '#FF90313C'; ControlBackground = '#A0FCFEFF'
            ControlBorder = '#9C5E96A3'; GridHover = '#607CC6CD'
            FocusRing = '#FF167F9C'; ToolTipBackground = '#EE163A43'
            ToolTipBorder = '#D04F96A5'; ToolTipForeground = '#FFFFFFFF'
            ButtonOnAccent = '#FFFFFFFF'; DisabledBackground = '#A3C4DADE'
            CardShadow = '#2C245765'; GridHeader = '#9FDDF1F4'
            BrandWatermark = '#1F167F9C'
        }
        '06-aurora-silver-blue' = [ordered]@{
            TextMuted = '#FF55728A'; Primary = '#FF2878B5'
            PrimaryHover = '#FF378CC9'; PrimaryPressed = '#FF205F91'
            Positive = '#FF2A7455'; PositiveHover = '#FF378A66'
            PositivePressed = '#FF215E45'; Info = '#FF286F89'
            InfoHover = '#FF37859F'; InfoPressed = '#FF205A70'
            Accent = '#FF4A6F9D'; AccentHover = '#FF5B82B2'
            AccentPressed = '#FF3C5C84'; Secondary = '#9BC9DEEF'
            SecondaryHover = '#B9E8F3FC'; SecondaryPressed = '#A1B2CDE2'
            Danger = '#FFAA3B49'; DangerHover = '#FFBE4C5A'
            DangerPressed = '#FF8D2F3B'; ControlBackground = '#A3FBFDFF'
            ControlBorder = '#9E668FAD'; GridHover = '#627DB6DF'
            FocusRing = '#FF2878B5'; ToolTipBackground = '#EE17344C'
            ToolTipBorder = '#D05A93BD'; ToolTipForeground = '#FFF8FCFF'
            ButtonOnAccent = '#FFFFFFFF'; DisabledBackground = '#A4C3D5E4'
            CardShadow = '#2E244A67'; GridHeader = '#A1D9EAF7'
            BrandWatermark = '#202878B5'
        }
        '07-arctic-sea-glass' = [ordered]@{
            TextMuted = '#FF52747C'; Primary = '#FF167D99'
            PrimaryHover = '#FF2292AE'; PrimaryPressed = '#FF11667E'
            Positive = '#FF22745B'; PositiveHover = '#FF2E8A6C'
            PositivePressed = '#FF1A5E49'; Info = '#FF1B7286'
            InfoHover = '#FF28899D'; InfoPressed = '#FF165C6D'
            Accent = '#FF347B86'; AccentHover = '#FF45919C'
            AccentPressed = '#FF28656F'; Secondary = '#99C7E8EC'
            SecondaryHover = '#B9E5F8F8'; SecondaryPressed = '#A0ADD6DB'
            Danger = '#FFA93C48'; DangerHover = '#FFBD4D59'
            DangerPressed = '#FF8C303A'; ControlBackground = '#A4FAFEFF'
            ControlBorder = '#9E5795A1'; GridHover = '#6077C9D2'
            FocusRing = '#FF087E91'; ToolTipBackground = '#EE123842'
            ToolTipBorder = '#D04794A2'; ToolTipForeground = '#FFF7FFFF'
            ButtonOnAccent = '#FFFFFFFF'; DisabledBackground = '#A2BDD9DC'
            CardShadow = '#2D174B59'; GridHeader = '#A2D7F0F2'
            BrandWatermark = '#22087E91'
        }
    }

    foreach ($theme in $themes) {
        $palette = $semanticPalettes[[string]$theme.Id]
        $derived = [ordered]@{
            WindowOverlay = [string]$theme.OverlayColor
            CardBackground = [string]$theme.CardTop
            CardBorder = [string]$theme.BorderTint
            CardShadow = if ([string]$theme.OverlayMode -ceq 'Dark') {
                '#7807111E'
            }
            else { '#4A38556A' }
            Warning = [string]$theme.UnknownWarningTint
            GridHeader = [string]$theme.ColumnHeaderBackgroundTint
            GridSelected = [string]$theme.SelectedRowTint
            GridActive = [string]$theme.ActiveRowTint
            GridActiveSelected = [string]$theme.ActiveSelectedRowTint
        }
        foreach ($entry in $palette.GetEnumerator()) {
            $derived[[string]$entry.Key] = [string]$entry.Value
        }
        foreach ($entry in $derived.GetEnumerator()) {
            Add-Member -InputObject $theme -NotePropertyName ([string]$entry.Key) `
                -NotePropertyValue ([string]$entry.Value)
        }
    }
    return $themes
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
    $defaultLanguage = 'zh-CN'
    $preferencePath = Join-Path -Path $StateDirectory `
        -ChildPath 'ui-preferences.json'
    if (-not [System.IO.File]::Exists($preferencePath)) {
        return [pscustomobject]@{
            Background = $defaultBackground
            Language = $defaultLanguage
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
        $schemaProperty = $data.PSObject.Properties['schema_version']
        $schemaVersion = if ($null -eq $schemaProperty) {
            0
        }
        else { [int]$schemaProperty.Value }
        if ($schemaVersion -notin @(0, 1, 2)) {
            throw 'UI_PREFERENCES_INVALID'
        }
        $backgroundProperty = $data.PSObject.Properties['background']
        if ($null -eq $backgroundProperty) {
            $backgroundProperty = $data.PSObject.Properties['Theme']
        }
        $languageProperty = $data.PSObject.Properties['language']
        if ($null -eq $languageProperty) {
            $languageProperty = $data.PSObject.Properties['Language']
        }
        $backgroundCandidate = if ($null -eq $backgroundProperty) {
            $defaultBackground
        }
        else { [string]$backgroundProperty.Value }
        $languageCandidate = if ($null -eq $languageProperty) {
            $defaultLanguage
        }
        else { [string]$languageProperty.Value }
        $backgroundValid = $null -ne (
            Get-QiehaoBackgroundTheme -Id $backgroundCandidate
        )
        $languageValid = @('zh-CN', 'en-US') -ccontains $languageCandidate
        $resolvedBackground = if ($backgroundValid) {
            $backgroundCandidate
        }
        else { $defaultBackground }
        $resolvedLanguage = if ($languageValid) {
            $languageCandidate
        }
        else { $defaultLanguage }
        return [pscustomobject]@{
            Background = $resolvedBackground
            Language = $resolvedLanguage
            IsValid = ($backgroundValid -and $languageValid)
            UsedDefault = (-not $backgroundValid -or -not $languageValid -or
                $null -eq $backgroundProperty -or $null -eq $languageProperty)
        }
    }
    catch {
        return [pscustomobject]@{
            Background = $defaultBackground
            Language = $defaultLanguage
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

        [string]$Background,

        [string]$Language
    )

    if (-not $PSBoundParameters.ContainsKey('Background') -and
        -not $PSBoundParameters.ContainsKey('Language')) {
        throw 'UI_PREFERENCES_VALUE_REQUIRED'
    }
    $current = Read-QiehaoUiPreferences -StateDirectory $StateDirectory
    $resolvedBackground = if ($PSBoundParameters.ContainsKey('Background')) {
        $Background
    }
    else { [string]$current.Background }
    $resolvedLanguage = if ($PSBoundParameters.ContainsKey('Language')) {
        $Language
    }
    else { [string]$current.Language }
    if ($null -eq (Get-QiehaoBackgroundTheme -Id $resolvedBackground)) {
        throw 'UI_BACKGROUND_THEME_INVALID'
    }
    if (@('zh-CN', 'en-US') -cnotcontains $resolvedLanguage) {
        throw 'UI_LANGUAGE_INVALID'
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
            schema_version = 2
            background = $resolvedBackground
            language = $resolvedLanguage
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
