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
    'Get-QiehaoGuiSnapshot',
    'Get-QiehaoBackgroundThemes',
    'Get-QiehaoBackgroundTheme',
    'Read-QiehaoUiPreferences',
    'Write-QiehaoUiPreferences',
    'Get-QiehaoBackgroundImage',
    'Enter-QiehaoGuiSingleInstance',
    'Exit-QiehaoGuiSingleInstance'
)
