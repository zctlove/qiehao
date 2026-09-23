Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:QiehaoSupportedLanguages = @('zh-CN', 'en-US')
$script:QiehaoThemeDisplayKeys = [ordered]@{
    '01-blue-glass' = 'Theme.01BlueGlass'
    '02-navy-gold' = 'Theme.02NavyGold'
    '03-ice-glass' = 'Theme.03IceGlass'
    '04-purple-tech' = 'Theme.04PurpleTech'
    '05-light-flow' = 'Theme.05LightFlow'
    '06-aurora-silver-blue' = 'Theme.06AuroraSilverBlue'
    '07-arctic-sea-glass' = 'Theme.07ArcticSeaGlass'
}

$script:QiehaoStrings = [ordered]@{
    'zh-CN' = [ordered]@{}
    'en-US' = [ordered]@{}
}

function Add-QiehaoCatalogPair {
    param(
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)][string]$ZhCn,
        [Parameter(Mandatory = $true)][string]$EnUs
    )
    if ($script:QiehaoStrings['zh-CN'].Contains($Key) -or
        $script:QiehaoStrings['en-US'].Contains($Key)) {
        throw 'LOCALIZATION_DUPLICATE_KEY'
    }
    $script:QiehaoStrings['zh-CN'][$Key] = $ZhCn
    $script:QiehaoStrings['en-US'][$Key] = $EnUs
}

Add-QiehaoCatalogPair 'App.Title' 'Codex 账号管理器' 'Codex Account Manager'
Add-QiehaoCatalogPair 'App.CriticalTitle' '严重安全错误 - Codex 账号管理器' 'Critical Safety Error - Codex Account Manager'
Add-QiehaoCatalogPair 'App.AlreadyRunning' 'Codex 账号管理器已在运行。' 'Codex Account Manager is already running.'
Add-QiehaoCatalogPair 'Language.Label' '语言：' 'Language:'
Add-QiehaoCatalogPair 'Language.ZhCn' '中文' '中文'
Add-QiehaoCatalogPair 'Language.EnUs' 'English' 'English'
Add-QiehaoCatalogPair 'Theme.Label' '皮肤：' 'Theme:'
Add-QiehaoCatalogPair 'Theme.01BlueGlass' '科技蓝' 'Tech Blue'
Add-QiehaoCatalogPair 'Theme.02NavyGold' '深蓝鎏金' 'Navy Gold'
Add-QiehaoCatalogPair 'Theme.03IceGlass' '冰蓝玻璃' 'Ice Glass'
Add-QiehaoCatalogPair 'Theme.04PurpleTech' '紫蓝星河' 'Purple Nebula'
Add-QiehaoCatalogPair 'Theme.05LightFlow' '清透流光' 'Light Flow'
Add-QiehaoCatalogPair 'Theme.06AuroraSilverBlue' '极光银蓝' 'Aurora Silver Blue'
Add-QiehaoCatalogPair 'Theme.07ArcticSeaGlass' '浅海冰晶' 'Arctic Sea Glass'
Add-QiehaoCatalogPair 'Theme.Saved' '皮肤已切换并保存' 'Theme changed and saved.'
Add-QiehaoCatalogPair 'Theme.SavedWithFallback' '背景图片不可用，已使用默认纯色并保存选择' 'Background unavailable. Solid fallback active; choice saved.'
Add-QiehaoCatalogPair 'Theme.SaveFailed' '皮肤已切换，但偏好保存失败' 'Theme changed, but the preference could not be saved.'
Add-QiehaoCatalogPair 'Section.CodexClient' 'Codex 客户端' 'Codex Client'
Add-QiehaoCatalogPair 'Section.CurrentAccount' '当前账号' 'Current Account'
Add-QiehaoCatalogPair 'Section.CurrentIdentity' '当前身份确认' 'Current Identity'
Add-QiehaoCatalogPair 'Section.WebChatGPT' '网页 ChatGPT' 'Web ChatGPT'
Add-QiehaoCatalogPair 'Section.SavedAccounts' '已保存账号' 'Saved Accounts'
Add-QiehaoCatalogPair 'WebChatGPT.Unchanged' '不受影响' 'Unaffected'
Add-QiehaoCatalogPair 'WebChatGPT.Hint' '浏览器 / PWA 登录状态不会被本工具修改' 'This tool does not change browser or PWA sign-in state.'
Add-QiehaoCatalogPair 'Search.Label' '搜索账号：' 'Search accounts:'
Add-QiehaoCatalogPair 'Search.ToolTip' '仅按本地 Profile 名称搜索，不访问凭证或身份内容' 'Searches local Profile names only; credentials and identity data are not accessed.'
Add-QiehaoCatalogPair 'Account.TeamFirstAddHint' '⚠ 空间账号首次添加：请在 Qiehao 开启状态下，完成一次该账号登录流程，否则可能被识别为个人账户。' '⚠ Team workspace account first add: Please complete one login flow for this account while Qiehao is running, otherwise it may be identified as a Personal account.'
Add-QiehaoCatalogPair 'Profile.Count' '{0} 个账号' '{0} accounts'
Add-QiehaoCatalogPair 'Profile.FilteredCount' '{0} / {1} 个账号' '{0} / {1} accounts'
Add-QiehaoCatalogPair 'Column.Profile' '名称' 'Name'
Add-QiehaoCatalogPair 'Column.Current' '当前' 'Current'
Add-QiehaoCatalogPair 'Column.Verification' '槽位验证' 'Verification'
Add-QiehaoCatalogPair 'Column.Status' '状态' 'Status'
Add-QiehaoCatalogPair 'Column.Auth' '凭证' 'Auth'
Add-QiehaoCatalogPair 'Column.Identity' '身份标记' 'Identity'
Add-QiehaoCatalogPair 'Column.Metadata' '元数据' 'Metadata'
Add-QiehaoCatalogPair 'Column.Updated' '更新时间' 'Updated'
Add-QiehaoCatalogPair 'Column.QuotaSnapshot' '额度快照' 'Quota Snapshot'
Add-QiehaoCatalogPair 'Button.Switch' '切换账号' 'Switch Account'
Add-QiehaoCatalogPair 'Button.Verify' '验证账号' 'Verify Account'
Add-QiehaoCatalogPair 'Button.Refresh' '刷新' 'Refresh'
Add-QiehaoCatalogPair 'Button.RefreshQuota' '刷新额度' 'Refresh Quota'
Add-QiehaoCatalogPair 'Button.Add' '添加账号' 'Add Account'
Add-QiehaoCatalogPair 'Button.Rename' '重命名' 'Rename'
Add-QiehaoCatalogPair 'Button.Delete' '删除账号' 'Delete Account'
Add-QiehaoCatalogPair 'Button.LaunchCodex' '启动 Codex' 'Launch Codex'
Add-QiehaoCatalogPair 'Button.LaunchSettings' '启动设置' 'Launch Settings'
Add-QiehaoCatalogPair 'Button.Confirm' '确定' 'Confirm'
Add-QiehaoCatalogPair 'Button.Cancel' '取消' 'Cancel'
Add-QiehaoCatalogPair 'Context.Switch' '切换到此账号' 'Switch to This Account'
Add-QiehaoCatalogPair 'Context.Verify' '验证账号' 'Verify Account'
Add-QiehaoCatalogPair 'Context.Rename' '重命名' 'Rename'
Add-QiehaoCatalogPair 'Context.Delete' '删除账号' 'Delete Account'
Add-QiehaoCatalogPair 'Status.Ready' '准备就绪' 'Ready'
Add-QiehaoCatalogPair 'Status.Refreshed' '状态已刷新' 'Status refreshed.'
Add-QiehaoCatalogPair 'Status.PartialReadOnly' '部分只读状态暂不可用' 'Some read-only status is temporarily unavailable.'
Add-QiehaoCatalogPair 'Status.RefreshFailed' '只读刷新失败' 'Read-only refresh failed.'
Add-QiehaoCatalogPair 'Footer.BrowserSafe' '不访问浏览器或网页登录状态' 'Browser and web sign-in state are not accessed.'
Add-QiehaoCatalogPair 'Status.Codex.Running' '运行中' 'Running'
Add-QiehaoCatalogPair 'Status.Codex.Stopped' '已退出' 'Stopped'
Add-QiehaoCatalogPair 'Status.Codex.Unknown' '未知' 'Unknown'
Add-QiehaoCatalogPair 'Status.Active.Uninitialized' '未初始化' 'Not initialized'
Add-QiehaoCatalogPair 'Status.Identity.Confirmed' '已确认' 'Confirmed'
Add-QiehaoCatalogPair 'Status.Identity.Mismatch' '不匹配' 'Mismatch'
Add-QiehaoCatalogPair 'Status.Identity.Uninitialized' '尚未初始化' 'Not initialized'
Add-QiehaoCatalogPair 'Status.Identity.PendingExit' '待退出后确认' 'Confirm after exit'
Add-QiehaoCatalogPair 'Status.Identity.Unavailable' '无法确认' 'Unavailable'
Add-QiehaoCatalogPair 'Safety.Detecting' '正在检测 Codex 进程状态……' 'Detecting Codex process status…'
Add-QiehaoCatalogPair 'Safety.WaitingForExit' '等待用户正常退出 Codex；检测到完全退出后将自动继续切换。' 'Waiting for you to quit Codex safely. Switching continues after Codex fully exits.'
Add-QiehaoCatalogPair 'Safety.Running' 'Codex 正在运行。切换账号前，请在 Codex 中选择“文件 → 退出”，或从系统托盘选择“Quit Codex”。关闭主窗口不等于完全退出。' 'Codex is running. Before switching accounts, use File → Exit in Codex or Quit Codex from the system tray. Closing the main window does not fully exit Codex.'
Add-QiehaoCatalogPair 'Safety.Stopped' 'Codex 已安全退出，可以切换账号。' 'Codex has exited safely. You can switch accounts.'
Add-QiehaoCatalogPair 'Safety.Unknown' '无法确认 Codex 是否完全退出，请先检查 Codex 状态；为保护账号状态，切换与写操作将安全停止。' 'Unable to confirm whether Codex fully exited. Switching and write operations are stopped to protect account state.'
Add-QiehaoCatalogPair 'Profile.Active.Yes' '是' 'Yes'
Add-QiehaoCatalogPair 'Profile.Active.No' '否' 'No'
Add-QiehaoCatalogPair 'Profile.Active.Unknown' '未知' 'Unknown'
Add-QiehaoCatalogPair 'Profile.Verification.Unverified' '未验证' 'Not verified'
Add-QiehaoCatalogPair 'Profile.Verification.Verified' '已验证' 'Verified'
Add-QiehaoCatalogPair 'Profile.Verification.Failed' '验证失败' 'Verification failed'
Add-QiehaoCatalogPair 'Profile.Health.Ready' '正常' 'Ready'
Add-QiehaoCatalogPair 'Profile.Health.Incomplete' '不完整' 'Incomplete'
Add-QiehaoCatalogPair 'Profile.Health.InvalidMetadata' '元数据异常' 'Invalid metadata'
Add-QiehaoCatalogPair 'Profile.Health.Unknown' '未知' 'Unknown'
Add-QiehaoCatalogPair 'Profile.Artifact.Present' '存在' 'Present'
Add-QiehaoCatalogPair 'Profile.Artifact.Missing' '缺失' 'Missing'
Add-QiehaoCatalogPair 'Profile.Artifact.Unknown' '未知' 'Unknown'
Add-QiehaoCatalogPair 'Profile.Metadata.Valid' '有效' 'Valid'
Add-QiehaoCatalogPair 'Profile.Metadata.Missing' '缺失' 'Missing'
Add-QiehaoCatalogPair 'Profile.Metadata.Invalid' '异常' 'Invalid'
Add-QiehaoCatalogPair 'Profile.Metadata.Unknown' '未知' 'Unknown'
Add-QiehaoCatalogPair 'Profile.Updated.Unavailable' '不可用' 'Unavailable'
Add-QiehaoCatalogPair 'Profile.Updated.InvalidMetadata' '元数据异常' 'Invalid metadata'
Add-QiehaoCatalogPair 'Launch.Target' 'Codex 启动目标：{0}' 'Codex launch target: {0}'
Add-QiehaoCatalogPair 'Launch.Status.AutoDetected' '已自动检测' 'Auto-detected'
Add-QiehaoCatalogPair 'Launch.Status.Custom' '已使用自定义文件' 'Using custom executable'
Add-QiehaoCatalogPair 'Launch.Status.InvalidCustom' '自定义路径无效' 'Custom path is invalid'
Add-QiehaoCatalogPair 'Launch.Status.NotFound' '未检测到' 'Not detected'
Add-QiehaoCatalogPair 'Launch.Settings.Title' 'Codex 启动设置' 'Codex Launch Settings'
Add-QiehaoCatalogPair 'Launch.Settings.Intro' '推荐使用自动检测。仅在便携版或特殊安装位置时选择自定义 EXE。' 'Automatic detection is recommended. Use a custom EXE only for portable or unusual installations.'
Add-QiehaoCatalogPair 'Launch.Settings.Auto' '自动检测（推荐）' 'Automatic detection (recommended)'
Add-QiehaoCatalogPair 'Launch.Settings.Custom' '自定义 EXE' 'Custom EXE'
Add-QiehaoCatalogPair 'Launch.Settings.Browse' '浏览…' 'Browse…'
Add-QiehaoCatalogPair 'Launch.Settings.Hint' '不会附加命令行参数，不会更改环境变量、权限、Codex 配置或登录状态。' 'No command-line arguments are added. Environment variables, permissions, Codex settings, and sign-in state are unchanged.'
Add-QiehaoCatalogPair 'Launch.Settings.Detect' '重新检测' 'Detect Again'
Add-QiehaoCatalogPair 'Launch.Settings.Save' '保存' 'Save'
Add-QiehaoCatalogPair 'Launch.Settings.PickerTitle' '选择 Codex 可执行文件' 'Select the Codex executable'
Add-QiehaoCatalogPair 'Launch.Settings.FileFilter' '可执行文件 (*.exe)|*.exe' 'Executable files (*.exe)|*.exe'
Add-QiehaoCatalogPair 'Launch.Settings.Result' '检测结果：{0}' 'Detection result: {0}'
Add-QiehaoCatalogPair 'Launch.Settings.InvalidPath' '自定义路径必须是现有的本地 .exe 文件，且不能是重解析链接。' 'The custom path must be an existing local .exe file and cannot be a reparse point.'
Add-QiehaoCatalogPair 'Launch.Started' 'Codex 已启动' 'Codex started.'
Add-QiehaoCatalogPair 'Launch.Requesting' '正在请求启动 Codex…' 'Requesting Codex launch…'
Add-QiehaoCatalogPair 'Launch.AlreadyRunning' 'Codex 已在运行。' 'Codex is already running.'
Add-QiehaoCatalogPair 'Launch.UnsafeExitUnknown' '无法安全确认 Codex 是否已退出，本次未启动。' 'Unable to safely confirm that Codex has exited. Codex was not launched.'
Add-QiehaoCatalogPair 'Launch.StartStateUnknown' '已请求启动，但无法确认 Codex 进程状态。' 'Launch was requested, but the Codex process state could not be confirmed.'
Add-QiehaoCatalogPair 'Launch.StartTimeout' '已请求启动，但 10 秒内未检测到 Codex 运行。' 'Launch was requested, but Codex was not detected within 10 seconds.'
Add-QiehaoCatalogPair 'Launch.WaitFailed' '启动状态检测失败，已停止等待' 'Launch-state detection failed. Waiting stopped.'
Add-QiehaoCatalogPair 'Quota.RefreshCurrentOnly' '仅刷新当前账号额度。' 'Refreshes quota for the current account only.'
Add-QiehaoCatalogPair 'Quota.Updating' '正在更新当前账号额度……' 'Refreshing current account quota…'
Add-QiehaoCatalogPair 'Quota.Updated' '当前账号额度已更新。' 'Current account quota updated.'
Add-QiehaoCatalogPair 'Quota.UpdateFailedRetry' '额度获取失败，可点击刷新额度重新获取。' 'Quota retrieval failed. Select Refresh Quota to try again.'
Add-QiehaoCatalogPair 'Quota.UpdateFailedRetryWithCode' '额度获取失败，可点击刷新额度重新获取。' 'Quota retrieval failed. Select Refresh Quota to try again.'
Add-QiehaoCatalogPair 'Quota.UpdateFailedCached' '额度更新失败，保留原缓存。' 'Quota update failed. The previous cache was preserved.'
Add-QiehaoCatalogPair 'Quota.UpdateFailedNoCache' '额度更新失败；当前账号尚无额度快照。' 'Quota update failed. The current account has no quota snapshot yet.'
Add-QiehaoCatalogPair 'Quota.CacheUnavailable' '额度缓存不可用；不影响账号管理。' 'Quota cache is unavailable; account management is unaffected.'
Add-QiehaoCatalogPair 'Quota.NoSnapshot' '尚无额度快照' 'No quota snapshot'
Add-QiehaoCatalogPair 'Quota.NoWindows' '未返回额度窗口' 'No quota windows returned'
Add-QiehaoCatalogPair 'Quota.JustQueried' '刚查询' 'Just queried'
Add-QiehaoCatalogPair 'Quota.CachedPrefix' '缓存' 'Cached'
Add-QiehaoCatalogPair 'Quota.UsageAvailable' '包含额度：可用' 'Included usage: available'
Add-QiehaoCatalogPair 'Quota.UsageUnavailable' '当前包含额度不可用' 'Included usage is currently unavailable'
Add-QiehaoCatalogPair 'Quota.UsageUnknown' '包含额度状态未知' 'Included usage status is unknown'
Add-QiehaoCatalogPair 'Quota.CurrentTitle' '当前账号额度' 'Current account quota'
Add-QiehaoCatalogPair 'Quota.SnapshotTitle' '额度快照' 'Quota snapshot'
Add-QiehaoCatalogPair 'Quota.Remaining' '剩余：{0}%' 'Remaining: {0}%'
Add-QiehaoCatalogPair 'Quota.Resets' '重置：{0}' 'Resets: {0}'
Add-QiehaoCatalogPair 'Quota.QueriedAt' '查询于：' 'Queried at:'
Add-QiehaoCatalogPair 'Quota.CurrentTooltip' '这是当前账号最近一次成功保存的额度快照。' 'This is the latest successfully saved quota snapshot for the current account.'
Add-QiehaoCatalogPair 'Quota.CurrentNoSnapshotTooltip' '当前账号尚无额度快照；可点击“刷新额度”查询。' 'The current account has no quota snapshot yet. Select Refresh Quota to query it.'
Add-QiehaoCatalogPair 'Quota.InactiveTooltip' '这是该账号上次作为当前账号时保存的额度快照。切换为当前账号后可刷新。' 'This snapshot was saved when this account was last active. Switch to it before refreshing.'
Add-QiehaoCatalogPair 'Quota.InactiveNoSnapshotTooltip' '该账号尚无额度快照。非当前账号不会联网；切换为当前账号后可刷新。' 'This account has no quota snapshot. Inactive accounts are never queried; switch to it before refreshing.'
Add-QiehaoCatalogPair 'Quota.ErrorCode' '错误代码：{0}' 'Error code: {0}'
Add-QiehaoCatalogPair 'Quota.RenameCacheFailed' '账号已重命名；额度缓存迁移失败，不影响账号状态。' 'Account renamed, but quota cache migration failed. Account state is unaffected.'
Add-QiehaoCatalogPair 'Quota.DeleteCacheFailed' '账号已删除；额度缓存清理失败，不影响账号状态。' 'Account deleted, but quota cache cleanup failed. Account state is unaffected.'
Add-QiehaoCatalogPair 'Quota.SwitchOldFailed' '旧账号额度更新失败，已保留原缓存；继续切换。' 'The old account quota could not be updated. Previous cache preserved; switching continues.'
Add-QiehaoCatalogPair 'Quota.SwitchNewFailed' '额度获取失败，可点击刷新额度重新获取。' 'Quota retrieval failed. Select Refresh Quota to try again.'
Add-QiehaoCatalogPair 'Quota.SwitchNewFailedWithCode' '额度获取失败，可点击刷新额度重新获取。' 'Quota retrieval failed. Select Refresh Quota to try again.'
Add-QiehaoCatalogPair 'Quota.SlowResponse' '额度服务响应较慢，仍在等待……' 'The quota service is responding slowly. Still waiting…'
Add-QiehaoCatalogPair 'Quota.SwitchBeforeSaving' "正在保存 '{0}' 的最新额度快照……" "Saving the latest quota snapshot for '{0}'…"
Add-QiehaoCatalogPair 'Quota.SwitchBeforeSavingWithExit' "正在保存 '{0}' 的最新额度快照，同时等待 Codex 安全退出……" "Saving the latest quota snapshot for '{0}' while waiting for Codex to exit safely…"
Add-QiehaoCatalogPair 'Quota.SwitchBeforeStopped' "Codex 已安全退出。正在完成 '{0}' 的额度快照，随后自动切换……" "Codex has exited safely. Finishing the quota snapshot for '{0}', then switching automatically…"
Add-QiehaoCatalogPair 'Quota.SwitchBeforeSaved' "'{0}' 的额度快照已保存，正在切换账号……" "Quota snapshot for '{0}' saved. Switching accounts…"
Add-QiehaoCatalogPair 'Quota.SwitchBeforeSavedWaiting' "'{0}' 的额度快照已保存，正在等待 Codex 安全退出……" "Quota snapshot for '{0}' saved. Waiting for Codex to exit safely…"
Add-QiehaoCatalogPair 'Quota.SwitchBeforeFallback' "本次未能更新 '{0}' 的额度快照。已保留上次缓存，正在继续切换……" "Could not update the quota snapshot for '{0}'. Previous cache preserved; switching continues…"
Add-QiehaoCatalogPair 'Dialog.Add.Title' '添加账号' 'Add Account'
Add-QiehaoCatalogPair 'Dialog.Rename.Title' '重命名账号' 'Rename Account'
Add-QiehaoCatalogPair 'Dialog.Delete.Title' '删除本地账号' 'Delete Local Account'
Add-QiehaoCatalogPair 'Dialog.Name.Current' '当前名称：{0}' 'Current name: {0}'
Add-QiehaoCatalogPair 'Dialog.Name.New' '新名称：' 'New name:'
Add-QiehaoCatalogPair 'Dialog.Name.Local' '本地名称：' 'Local name:'
Add-QiehaoCatalogPair 'Dialog.Name.Empty' '名称不能为空。' 'Name cannot be empty.'
Add-QiehaoCatalogPair 'Dialog.Delete.Confirm' '删除' 'Delete'
Add-QiehaoCatalogPair 'Dialog.Delete.Message' "确定删除本地账号 '{0}' 吗？`n`n这只会删除本工具保存的本地账号槽位，`n不会删除 OpenAI 账号、订阅或网页登录状态。" "Delete local account '{0}'?`n`nThis removes only the local account slot saved by this tool.`nIt does not delete the OpenAI account, subscription, or web sign-in state."
Add-QiehaoCatalogPair 'Dialog.Switch.Title' '切换账号' 'Switch Account'
Add-QiehaoCatalogPair 'Dialog.Switch.Target' '目标账号：{0}' 'Target account: {0}'
Add-QiehaoCatalogPair 'Dialog.Switch.Heading' '请在 Codex 中安全退出' 'Quit Codex safely'
Add-QiehaoCatalogPair 'Dialog.Switch.Instructions' "「文件 → 退出」`n或`n系统托盘 → 「Quit Codex」`n`n检测到完全退出后，本工具将自动继续切换。" "File → Exit`nor`nSystem tray → Quit Codex`n`nSwitching continues automatically after Codex fully exits."
Add-QiehaoCatalogPair 'Dialog.Switch.Waiting' '正在等待 Codex 安全退出……' 'Waiting for Codex to exit safely…'
Add-QiehaoCatalogPair 'Dialog.Switch.WaitingTarget' "正在等待 Codex 安全退出，随后自动切换到 '{0}'……" "Waiting for Codex to exit safely, then switching to '{0}' automatically…"
Add-QiehaoCatalogPair 'Dialog.Switch.Stopped' '已检测到 Codex 完全退出，正在切换账号……' 'Codex fully exited. Switching accounts…'
Add-QiehaoCatalogPair 'Switch.Success' '切换成功。' 'Account switched successfully.'
Add-QiehaoCatalogPair 'Switch.SuccessCurrent' "切换成功。`n`n当前账号：{0}" "Account switched successfully.`n`nCurrent account: {0}"
Add-QiehaoCatalogPair 'Switch.RefreshFailed' '账号切换已经成功，但界面状态刷新失败。请点击“刷新”重新读取当前状态。' 'The account switch succeeded, but the UI could not refresh. Select Refresh to reload status.'
Add-QiehaoCatalogPair 'Switch.WaitTimeout' '等待超时，尚未检测到 Codex 完全退出。未执行账号切换。' 'Timed out before Codex fully exited. The account was not switched.'
Add-QiehaoCatalogPair 'Switch.UnknownExit' '无法确认 Codex 是否完全退出，本次未执行账号切换。' 'Unable to confirm that Codex fully exited. The account was not switched.'
Add-QiehaoCatalogPair 'Switch.DialogFailed' '无法启动安全等待窗口，本次未执行账号切换。' 'The safe-exit dialog could not be opened. The account was not switched.'
Add-QiehaoCatalogPair 'Switch.Status.SwitchingTarget' "已检测到 Codex 完全退出，正在切换到 '{0}'……" "Codex fully exited. Switching to '{0}'…"
Add-QiehaoCatalogPair 'Switch.Status.SuccessCurrent' '切换成功，当前账号：{0}' 'Switch succeeded. Current account: {0}'
Add-QiehaoCatalogPair 'Switch.Status.Failed' '账号切换未完成' 'Account switch did not complete.'
Add-QiehaoCatalogPair 'Switch.Status.Cancelled' '已取消等待，本次未切换账号' 'Waiting was cancelled. The account was not switched.'
Add-QiehaoCatalogPair 'Switch.Status.Unknown' '进程状态未知，本次未切换账号' 'Process state is unknown. The account was not switched.'
Add-QiehaoCatalogPair 'Switch.Status.TimedOut' '等待超时，本次未切换账号' 'Waiting timed out. The account was not switched.'
Add-QiehaoCatalogPair 'Switch.Status.Closing' '切换等待已停止' 'Switch waiting stopped.'
Add-QiehaoCatalogPair 'Verify.Working' '正在验证账号…' 'Verifying account…'
Add-QiehaoCatalogPair 'Verify.Success' "账号：{0}`n状态：已验证" "Account: {0}`nStatus: Verified"
Add-QiehaoCatalogPair 'Verify.SuccessDetailed' "账号：{0}`nProfile：完整`n保存身份：{1}`n当前 Codex：{2}`n凭据来源：{3}`n结果：身份一致" "Account: {0}`nProfile: complete`nSaved identity: {1}`nCurrent Codex: {2}`nCredential source: {3}`nResult: identity matches"
Add-QiehaoCatalogPair 'Verify.IdentityMismatchDetailed' "账号：{0}`nProfile：完整`n保存的账号空间类型：{1}`n当前 Codex 登录空间类型：{2}`n凭据来源：{3}`n结果：当前 Codex 登录身份与保存账号不一致；未修改任何 Profile。" "Account: {0}`nProfile: complete`nSaved account workspace type: {1}`nCurrent Codex signed-in workspace type: {2}`nCredential source: {3}`nResult: the current Codex identity differs from the saved account; no profile was modified."
Add-QiehaoCatalogPair 'Verify.WorkspaceUnknownDetailed' "账号：{0}`nProfile：完整`n工作区身份：旧版资料未知`n凭据来源：{1}`n结果：未完整验证" "Account: {0}`nProfile: complete`nWorkspace identity: unknown for legacy profile`nCredential source: {1}`nResult: not fully verified"
Add-QiehaoCatalogPair 'Account.Renaming' '正在重命名账号…' 'Renaming account…'
Add-QiehaoCatalogPair 'Account.Deleting' '正在删除本地账号…' 'Deleting local account…'
Add-QiehaoCatalogPair 'Account.AddPreparing' '准备添加账号…' 'Preparing to add an account…'
Add-QiehaoCatalogPair 'Account.AddInstructions' "请先在 Codex 中登录或切换到要添加的账号。`n`n确认目标账号登录成功后，请完全退出 Codex 客户端，再返回 Qiehao 继续。这里是退出 Codex 客户端，不是注销当前登录账号。`n`n每个账号只需添加一次；以后可直接使用 Qiehao 切换，不需要重复 OAuth 登录。" "First, sign in or switch to the account you want to add in Codex.`n`nAfter confirming that the target account is signed in, fully quit the Codex client and return to Qiehao. Quit the Codex client; do not sign out of the account.`n`nEach account only needs to be added once. After that, use Qiehao to switch accounts without repeating OAuth sign-in."
Add-QiehaoCatalogPair 'Account.AddReady' '我已登录账号并退出' 'I signed in and quit Codex'
Add-QiehaoCatalogPair 'Account.AddReadActiveFailed' '无法安全读取当前账号状态，已停止添加流程。' 'Unable to safely read the current account state. The add-account flow stopped.'
Add-QiehaoCatalogPair 'Account.AddQuitBeforeCapture' '请先正常退出 Codex，再采集新账号。' 'Quit Codex normally before capturing the new account.'
Add-QiehaoCatalogPair 'Account.AddExitUnknown' '无法确认 Codex 是否完全退出，本次未添加账号。' 'Unable to confirm that Codex fully exited. No account was added.'
Add-QiehaoCatalogPair 'Account.AddQuitBeforeStart' "要添加新账号，请先在 Codex 中登录或切换到目标账号。确认目标账号登录成功后，请完全退出 Codex 客户端，然后返回 Qiehao 再次点击「添加账号」。`n`n注意：这里是退出 Codex 客户端，不是注销当前登录账号。" "To add a new account, first sign in or switch to the target account in Codex. After confirming that it is signed in, fully quit the Codex client, return to Qiehao, and click Add Account again.`n`nNote: quit the Codex client; do not sign out of the current account."
Add-QiehaoCatalogPair 'Account.AddCurrentAlreadySaved' '当前 Codex 登录的仍是已保存账号。要添加另一个账号，请先在 Codex 中登录或切换到目标账号，登录成功后完全退出 Codex 客户端，再返回 Qiehao 点击“添加账号”。' 'Codex is still signed in to an account that is already saved. To add another account, sign in or switch to the target account in Codex, fully quit the Codex client after sign-in succeeds, then return to Qiehao and click Add Account.'
Add-QiehaoCatalogPair 'Account.SyncChecking' '正在核对 Qiehao 当前账号与 Codex 实际登录账号…' 'Checking the Qiehao active account against the account currently signed in to Codex…'
Add-QiehaoCatalogPair 'Dialog.SyncActive.Title' '同步当前账号状态' 'Synchronize Active Account State'
Add-QiehaoCatalogPair 'Dialog.SyncActive.Message' 'Qiehao 记录的当前账号与 Codex 实际登录账号不同。如果当前 Codex 登录账号已保存在本地，可仅同步当前状态；不会修改或复制任何账号凭据。' 'The active account recorded by Qiehao differs from the account currently signed in to Codex. If the current Codex account is already saved locally, Qiehao can synchronize only the active-state record. No account credentials will be modified or copied.'
Add-QiehaoCatalogPair 'Dialog.Delete.SyncActive.Message' 'Qiehao 的当前账号记录已过期。先仅同步到 Codex 实际登录的已保存账号，再继续删除所选旧账号；不会复制或覆盖任何账号凭据。' 'Qiehao''s active-account record is stale. First synchronize it to the saved account currently signed in to Codex, then continue deleting the selected old account. No credentials will be copied or overwritten.'
Add-QiehaoCatalogPair 'Dialog.SyncActive.Confirm' '同步当前 Codex 登录账号' 'Synchronize Current Codex Account'
Add-QiehaoCatalogPair 'Common.ProfileSelectionRequired' '请先选择一个账号。' 'Select an account first.'
Add-QiehaoCatalogPair 'Common.OperationBusy' '另一个操作正在执行。' 'Another operation is in progress.'
Add-QiehaoCatalogPair 'Common.OperationFailed' '操作失败，未进行不安全的继续操作。' 'The operation failed. No unsafe continuation was attempted.'
Add-QiehaoCatalogPair 'Common.CodexRunning' 'Codex 正在运行。' 'Codex is running.'
Add-QiehaoCatalogPair 'Common.CodexUnknown' '无法确认 Codex 进程状态，请重新检测。' 'Unable to confirm Codex process status. Check again.'
Add-QiehaoCatalogPair 'Operation.ALREADY_ACTIVE' '已经是当前账号。' 'This is already the current account.'
Add-QiehaoCatalogPair 'Operation.ACTIVE_PROFILE_OUT_OF_SYNC' 'Qiehao 记录的当前账号与 Codex 实际登录账号不同。未修改任何账号数据。' 'The active account recorded by Qiehao differs from the account currently signed in to Codex. No account data was changed.'
Add-QiehaoCatalogPair 'Operation.ACTIVE_PROFILE_SYNCED' '已将 Qiehao 当前账号状态同步为 Codex 实际登录的本地账号。' 'Qiehao active-account state was synchronized to the saved local account currently signed in to Codex.'
Add-QiehaoCatalogPair 'Operation.ACTIVE_PROFILE_SYNC_FAILED' '无法安全同步当前账号状态。未修改任何账号凭据。' 'The active-account state could not be synchronized safely. No account credentials were changed.'
Add-QiehaoCatalogPair 'Operation.SWITCH_FAILED_ROLLED_BACK' '切换失败，已安全恢复原账号。' 'Switch failed. The original account was restored safely.'
Add-QiehaoCatalogPair 'Operation.SWITCH_ROLLBACK_FAILED' '切换失败且自动恢复失败。请不要启动 Codex，先进行人工恢复。' 'Switch and automatic recovery both failed. Do not launch Codex; recover manually first.'
Add-QiehaoCatalogPair 'Operation.PROFILE_ADD_SUCCESS' '已识别当前 Codex 登录账号，凭据已安全保存，账号添加成功。' 'The current Codex signed-in account was identified, its credentials were saved securely, and the account was added successfully.'
Add-QiehaoCatalogPair 'Operation.PROFILE_RENAME_SUCCESS' '账号已重命名。' 'Account renamed.'
Add-QiehaoCatalogPair 'Operation.PROFILE_REMOVE_SUCCESS' '本地账号已删除。' 'Local account deleted.'
Add-QiehaoCatalogPair 'Operation.PROFILE_NAME_ALREADY_EXISTS' '该本地账号名称已经存在。' 'That local account name already exists.'
Add-QiehaoCatalogPair 'Operation.PROFILE_IDENTITY_ALREADY_EXISTS' '当前 Codex 登录账号已保存在本地账号列表中，不会重复添加。' 'The account currently signed in to Codex is already saved in the local account list and will not be added again.'
Add-QiehaoCatalogPair 'Operation.CANNOT_REMOVE_ACTIVE_PROFILE' '不能删除当前账号。' 'The current account cannot be deleted.'
Add-QiehaoCatalogPair 'Operation.CANNOT_REMOVE_CURRENT_CODEX_PROFILE' '不能删除 Codex 当前实际登录的账号。' 'The account currently signed in to Codex cannot be deleted.'
Add-QiehaoCatalogPair 'Operation.PROFILE_DELETE_ACTIVE_OUT_OF_SYNC' 'Qiehao 的当前账号记录与 Codex 实际登录账号不同。请先安全同步当前状态，再删除旧账号。' 'Qiehao''s active-account record differs from the account currently signed in to Codex. Safely synchronize the active state before deleting the old account.'
Add-QiehaoCatalogPair 'Operation.PROFILE_DELETE_IDENTITY_UNKNOWN' '无法把 Codex 当前登录身份安全对应到本地账号，已停止删除。' 'The current Codex identity could not be safely matched to a local account. Deletion was stopped.'
Add-QiehaoCatalogPair 'Operation.PROFILE_NOT_FOUND' '本地账号不存在。' 'The local account does not exist.'
Add-QiehaoCatalogPair 'Operation.PROFILE_INCOMPLETE' '账号资料不完整。' 'The account profile is incomplete.'
Add-QiehaoCatalogPair 'Operation.PROFILE_METADATA_INVALID' '账号元数据异常。' 'Account metadata is invalid.'
Add-QiehaoCatalogPair 'Operation.PROFILE_NAME_INVALID' '账号名称无效。' 'The account name is invalid.'
Add-QiehaoCatalogPair 'Operation.PROFILE_NAME_TOO_LONG' '账号名称不能超过 64 个字符。' 'The account name cannot exceed 64 characters.'
Add-QiehaoCatalogPair 'Operation.PROFILE_NAME_RESERVED' '该账号名称为系统保留名称。' 'That account name is reserved by the system.'
Add-QiehaoCatalogPair 'Operation.AUTH_FILE_NOT_FOUND' "未检测到可导入的 Codex 登录凭据。`n`n请启动 Codex，使用官方流程完成目标账号登录。确认登录成功后，请完全退出 Codex 客户端（不要注销当前账号），然后返回 Qiehao 再次点击「添加账号」。`n`n如果完成登录并退出后仍然出现此提示，当前 Codex 可能使用系统凭据库存储登录信息，本版本暂不支持直接导入该存储方式。`n`n未修改任何 Codex 登录状态。" "No importable Codex sign-in credentials were detected.`n`nStart Codex and complete sign-in to the target account using the official flow. After confirming that sign-in succeeded, fully quit the Codex client (do not sign out of the account), then return to Qiehao and click Add Account again.`n`nIf this message still appears after signing in and quitting, Codex may be storing sign-in information in the operating system keyring, which this version cannot import directly.`n`nNo Codex sign-in state was changed."
Add-QiehaoCatalogPair 'Operation.AUTH_FILE_EMPTY' 'Codex 登录文件为空，无法安全采集账号。未修改任何 Codex 登录状态。' 'The Codex sign-in file is empty, so the account could not be captured safely. No Codex sign-in state was changed.'
Add-QiehaoCatalogPair 'Operation.AUTH_FILE_READ_FAILED' '无法安全读取 Codex 登录文件。请确认 Codex 已完全退出后重试；未修改任何 Codex 登录状态。' 'The Codex sign-in file could not be read safely. Confirm that Codex has fully exited and try again. No Codex sign-in state was changed.'
Add-QiehaoCatalogPair 'Operation.AUTH_JSON_INVALID' 'Codex 登录文件不是有效的 JSON，可能已损坏。未修改任何账号数据。' 'The Codex sign-in file is not valid JSON and may be damaged. No account data was changed.'
Add-QiehaoCatalogPair 'Operation.AUTH_SCHEMA_UNEXPECTED' '当前 Codex 登录文件结构暂无法兼容，未修改任何账号数据。' 'The current Codex sign-in file structure is not yet compatible. No account data was changed.'
Add-QiehaoCatalogPair 'Operation.AUTH_IDENTITY_SCHEMA_UNRECOGNIZED' '当前 Codex 登录文件缺少可安全验证的 ChatGPT 账号身份，未修改任何账号数据。' 'The Codex sign-in file does not contain a ChatGPT account identity that can be verified safely. No account data was changed.'
Add-QiehaoCatalogPair 'Operation.AUTH_CREDENTIAL_SOURCE_UNSUPPORTED' 'Codex 当前使用系统凭据库或临时凭据存储；Qiehao 无法安全确认 auth.json 是实际登录来源。未修改任何账号数据。' 'Codex is using the system keyring or temporary credential storage. Qiehao cannot safely confirm that auth.json is the active sign-in source. No account data was changed.'
Add-QiehaoCatalogPair 'Operation.AUTH_CREDENTIAL_SOURCE_AMBIGUOUS' 'Codex 当前使用自动凭据存储模式，无法安全确认文件凭据与实际登录身份一致。未修改任何账号数据。' 'Codex is using automatic credential storage. Qiehao cannot safely confirm that the file credential matches the actual signed-in identity. No account data was changed.'
Add-QiehaoCatalogPair 'Operation.AUTH_CREDENTIAL_SOURCE_UNKNOWN' '无法安全确认 Codex 当前凭据来源。未修改任何账号数据。' 'The current Codex credential source could not be safely confirmed. No account data was changed.'
Add-QiehaoCatalogPair 'Operation.CODEX_HOME_NOT_FOUND' '未找到 Codex 本地数据目录，无法采集登录凭据。未修改任何 Codex 登录状态。' 'The local Codex data directory was not found, so sign-in credentials could not be captured. No Codex sign-in state was changed.'

function Get-QiehaoSupportedLanguages {
    [CmdletBinding()]
    param()
    return @(
        [pscustomobject]@{ Code = 'zh-CN'; NativeName = '中文' },
        [pscustomobject]@{ Code = 'en-US'; NativeName = 'English' }
    )
}

function Test-QiehaoLanguage {
    [CmdletBinding()]
    param([AllowNull()][string]$Language)
    return $script:QiehaoSupportedLanguages -ccontains [string]$Language
}

function Resolve-QiehaoLanguage {
    [CmdletBinding()]
    param([AllowNull()][string]$Language)
    if (Test-QiehaoLanguage -Language $Language) { return [string]$Language }
    return 'zh-CN'
}

function Get-QiehaoLocalizationCatalog {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Language)
    $resolved = Resolve-QiehaoLanguage -Language $Language
    return $script:QiehaoStrings[$resolved]
}

function Get-QiehaoLocalizedString {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Key,
        [AllowNull()][string]$Language = 'zh-CN'
    )
    $resolved = Resolve-QiehaoLanguage -Language $Language
    $catalog = $script:QiehaoStrings[$resolved]
    if ($catalog.Contains($Key)) { return [string]$catalog[$Key] }
    $fallback = $script:QiehaoStrings['zh-CN']
    if ($fallback.Contains($Key)) { return [string]$fallback[$Key] }
    return '[Missing:' + $Key + ']'
}

function Format-QiehaoLocalizedString {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Key,
        [AllowNull()][string]$Language = 'zh-CN',
        [AllowNull()][object[]]$Arguments = @()
    )
    $format = Get-QiehaoLocalizedString -Key $Key -Language $Language
    try {
        return [string]::Format(
            [Globalization.CultureInfo]::InvariantCulture,
            $format,
            [object[]]$Arguments
        )
    }
    catch { return '[Missing:' + $Key + ']' }
}

function Get-QiehaoLocalizedThemeName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ThemeId,
        [AllowNull()][string]$Language = 'zh-CN'
    )
    if (-not $script:QiehaoThemeDisplayKeys.Contains($ThemeId)) {
        return '[Missing:Theme.' + $ThemeId + ']'
    }
    return Get-QiehaoLocalizedString `
        -Key ([string]$script:QiehaoThemeDisplayKeys[$ThemeId]) `
        -Language $Language
}

Export-ModuleMember -Function @(
    'Get-QiehaoSupportedLanguages',
    'Test-QiehaoLanguage',
    'Resolve-QiehaoLanguage',
    'Get-QiehaoLocalizationCatalog',
    'Get-QiehaoLocalizedString',
    'Format-QiehaoLocalizedString',
    'Get-QiehaoLocalizedThemeName'
)
