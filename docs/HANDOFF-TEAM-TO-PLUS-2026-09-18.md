# Team → Plus 增量交接（2026-09-18）

本文档是当前阶段的增量交接，只记录相对于既有交接的新进展、真人实机验收结论和下一步安全边界。不要复制或重写以下基础交接：

- docs/HANDOFF-TEAM-TO-PLUS-2026-09-17.md
- docs/HANDOFF-PLUS-TO-TEAM-2026-09-17.md

本文档不包含任何真实认证值、原始 App Server response 或私有账号信息。

## 1. 当前 Git 状态

- 项目：E:\codex\qiehaoqu
- Branch：feature/gui-v1
- HEAD：48dd5b5d8d2de4591c782fb082801f21ae25133e
- HEAD short：48dd5b5d
- Commit message：fix-switch-ui-sync-dialog
- 创建本文档前 working tree：clean

## 2. 最近关键提交链

本阶段最直接相关的提交：

    48dd5b5d fix-switch-ui-sync-dialog
    c2975e77 one-click-manual-quit-auto-switch
    0deeb88  manual-quit-auto-continue
    03f5d413 docs-plus-to-team-handoff
    d65ffcbb native-codex-quit
    9c3211ac fix-exit-wait-timer-closure
    6f7154ca fix-theme-persistence-real-event
    49221d29 fix-exit-prefs-polling
    42e1a4ea docs-team-to-plus-handoff
    db22d67b gui-glass-launch-identity
    01b5bc7  gui-account-management
    e7a53828 gui-verify-safe-exit

理解当前状态时优先从 c2975e77 和 48dd5b5d 开始，再按需要回看上游提交及两份 2026-09-17 交接。

## 3. 当前切号主流程真人验收

当前“一次点击切号”流程已经真人实机 PASS。

完整用户流程：

    选择目标账号
    → 点击一次“切换账号”
    → 如果 Codex Running
    → 自动打开等待窗口
    → 自动开始 500ms 进程检测
    → 用户在 Codex 中手工执行“文件 → 退出”
       或使用系统托盘“Quit Codex”
    → 进程闸检测到 Stopped
    → 自动继续安全 Switch
    → Refresh
    → Active Profile 即时迁移
    → 左下角状态更新
    → 弹出切换成功提示

真人确认：不再需要第二次点击“开始检测”或任何第二阶段确认按钮。一次点击已经覆盖“进入等待 → 发现完全退出 → 自动续切”的完整流程。

后台安全原则没有变化：最终 Switch 后端仍会再次执行进程闸，GUI 的 500ms 检测不是替代后端安全检查。

## 4. Switch UI 同步 Bug 已修复并真人 PASS

修复前，Backend 已经完成切号并返回成功，但主 GUI 可能出现：

- “当前”是/否没有立即变化；
- Active 行没有立即迁移；
- 左下角长期停留在“正在切换”；
- 只有 Launch 或手工 Refresh 后才显示正确状态。

48dd5b5d fix-switch-ui-sync-dialog 已修复这一问题。

现在的成功顺序：

    Backend SWITCH_SUCCESS
    → 同一个 UI Dispatcher 流程内同步 Refresh
    → 验证 ActiveProfile == Target
    → Active 行迁移
    → Busy=false
    → 左下角显示切换成功和目标本地 Profile 名称
    → 关闭人工退出等待窗口
    → 显示 Success MessageBox

真人实测已确认当前账号、Active 高亮行和左下角状态都会立即更新，无需启动 Codex 或再次 Refresh。

如果未来 Backend 已成功但 UI Refresh 失败，必须明确区分“切号已经成功”和“界面刷新失败”，不得重复执行 Switch，也不得错误回滚已完成的后端事务。

## 5. 自动退出 Codex 的最终产品决定

不要继续研究或恢复自动 Quit。

已经确认：

- CloseMainWindow 只会关闭可见主窗口，不等于 Codex 应用完全退出；
- Codex 后台仍可能继续运行，进程闸仍显示 Running；
- Native UI Automation Quit 和 Tray 自动化无法在当前安全边界内稳定识别、验证并触发当前 Codex Desktop 的官方退出入口。

最终产品方案：

1. 用户使用 Codex 自己的官方“文件 → 退出”；或
2. 用户使用 Codex 系统托盘的“Quit Codex”；
3. 账号管理器只负责 500ms 检测；
4. 检测到真正 Stopped 后自动继续 Switch。

禁止重新引入：

- CloseMainWindow 伪装成正常退出；
- Native Quit 或系统托盘猜测式自动化；
- SendKeys、Alt+F4；
- 鼠标模拟、固定坐标、OCR 或图像识别；
- Electron 注入、私有 IPC；
- taskkill /F、Stop-Process -Force；
- Kill 或 TerminateProcess 针对真实 Codex Desktop。

## 6. 当前已真人 PASS 的功能

以下项目已经有真人实机验收依据：

- Team ↔ Plus Switch；
- 一次点击切号；
- Codex Running 时自动打开人工退出等待窗口；
- 等待窗口打开后自动开始 500ms 检测；
- 用户手工官方退出后自动续切；
- Switch 后主 GUI 即时 Refresh；
- Active 行即时迁移；
- 左下角切换成功状态即时更新；
- 启动 Codex；
- 启动设置；
- 主题选择即时生效；
- state\ui-preferences.json 能真实覆盖保存；
- 关闭 GUI 后重新打开能恢复主题；
- 当前身份确认；
- 账号槽位验证；
- 5 秒普通进程检测；
- 用户主动启动、切换和刷新时立即检测；
- GUI 关闭后 DispatcherTimer 停止、handler 解除，没有后台探测残留。

“当前身份确认”和“验证账号”仍是两个不同概念：

- 当前身份确认：确认真实 active 认证与工具记录的 active profile 是否一致；
- 验证账号：验证指定本地槽位自身是否完整、可解密并与身份 marker 一致。

## 7. 当前 quota / usage 功能设计原则

额度功能的设计原则已经确定，但尚未接入 GUI，也尚未创建 quota cache。

核心原则：

- 只查询当前 active 账号；
- inactive profile 绝不主动联网查询；
- 每个本地 Profile 只保留其最后一次成功额度快照；
- 最后成功快照必须跨 GUI 关闭、重新打开和电脑重启长期保留；
- 只有某个 Profile 再次成为 Current，才允许联网更新它；
- 新查询失败不得删除、清零或以 N/A 覆盖旧成功快照；
- 查询失败时只标记“旧缓存 / 更新失败”。

未来建议查询时机：

1. GUI 打开时，只查询当前 active 账号一次；
2. 切号前，在旧账号仍 active 时查询一次，留下旧账号最后快照；
3. Switch 成功后，只查询新的 active 账号一次；
4. 用户手工刷新额度时，只查询当前 active 账号。

明确不做：

- 定时联网刷新或后台监控；
- 多账号轮询；
- inactive profile 查询；
- 解密其他 profile 后伪造查询环境；
- 直接使用认证值调用 private API。

## 8. Usage Window 必须动态显示

未来 GUI 不得硬编码所有账号都有“5 小时 + 周限”。不同账号或 Workspace 可能实际返回：

- 5-hour；
- weekly；
- monthly；
- 其他 duration；
- 只有一个窗口；
- 合法空 snapshot。

必须根据服务器实际返回的以下字段动态构造窗口：

    windowDurationMins
    usedPercent
    resetsAt

显示规则：

- 300 分钟可标记为 5h；
- 10080 分钟可标记为 Weekly；
- 其他 duration 显示真实分钟数，不猜测业务名称；
- 未返回的窗口不显示；
- 不制造固定 0%；
- 不为不存在的窗口制造固定 N/A 占位。

剩余百分比：

    remainingPercent = clamp(100 - usedPercent, 0, 100)

重置时间使用服务器返回的 Unix timestamp 并转为本机 local time，不根据 duration 或当前时间自行推算。

ordinaryUsageAllowed 必须按服务器值解释：

- true：普通额度当前允许；
- false：普通额度当前不允许；
- null 或缺失：不可用；
- 不得只凭 remaining 或 reset time 自行推断已经恢复。

## 9. Official App Server Quota PoC 当前结果

官方本地链路已经部分真人验证成功。

本机版本：

    codex-cli 0.154.0-alpha.6.2

已确认支持：

    codex app-server --stdio

初始化流程已验证：

    initialize
    → initialized

第二轮真人 PoC 只发送了一次：

    account/rateLimits/read

请求参数：

    excludeResetCreditDetails = true
    supportsLunaReserve = omitted

JSONL 诊断结果：

    LinesReceived = 2
    NotificationsReceived = 1
    ResponsesWithOtherId = 0
    MatchingResponseReceived = true
    MatchingErrorReceived = false
    NotificationMethods = remoteControl/status/changed

随后收到了与 request id 匹配的 result。整个进程约 2.6 秒结束，远低于 60 秒客户端 deadline。

因此已经确认：

- 官方 account/rateLimits/read 在当前 Windows 和当前 Codex 版本上可返回匹配 response；
- JSONL 中 notification 和 response 可以交错；
- 客户端必须按 request id 循环读取，不能把第一条 notification 当作最终结果；
- 上一轮 20 秒没有拿到 snapshot 不能解释为 RPC 不受支持；
- 下一账号不需要重新研究初始化协议或证明 RPC 是否存在。

## 10. Quota PoC 尚未端到端完成的原因

真实 RPC 本身成功，失败发生在本地 sanitized snapshot parser，不是服务器 timeout，也不是匹配 response 缺失。

运行时结果：

    POC_RESULT = FAILURE
    FailureCode = UNEXPECTED_ERROR_AT_PARSESNAPSHOT

精确原因：

在 Windows PowerShell 5.1 中，将 System.Collections.Generic.List[object] 使用以下方式放入 [pscustomobject]：

    Windows = @($windows)

会发生：

    System.ArgumentException
    Argument types do not match

使用纯 fake response 已确认修复方式：

    Windows = $windows.ToArray()

修正后得到：

    FAKE_PARSE_OK_PS51

本轮真实 response 按安全设计没有输出、没有写盘、没有缓存，因此 parser 修正后不能事后恢复真实 plan 和 usage windows。为遵守“一轮只发一次真实 request”，没有重试。

下一账号接手后只需要：

    实现 PS5.1-safe parser
    → 先用 fake response 覆盖动态窗口和空 snapshot
    → 再获准执行一次严格单次 account/rateLimits/read
    → 输出脱敏 summary
    → 用户人工与 Settings → Usage 对照

成功摘要至少应包含：

- 非敏感 plan 类型；
- ordinaryUsageAllowed；
- 实际返回的所有 usage windows；
- 每个窗口的真实 windowDurationMins；
- clamp 后的 remaining；
- 本机 local reset time；
- JSONL 分类计数；
- child cleanup 结果。

不得输出或保存 raw response。

## 11. Quota PoC 安全边界

已确认 PoC 没有直接：

- 读取 auth.json；
- 读取 access token 或 refresh token；
- 读取真实账号标识或邮箱；
- 读取 Cookie、浏览器 profile 或 Local Storage；
- 解密 Team/Plus DPAPI profile；
- 查询 inactive profile；
- 设置伪造 CODEX_HOME；
- 构造自定义认证 header；
- 直接调用 private backend；
- 使用 Invoke-WebRequest、Invoke-RestMethod、HttpClient、curl 或 wget。

官方认证和当前账号选择全部交给 codex app-server。

本轮 PoC 查询期间持有项目现有写操作 mutex，保证 active 账号不能在 request 期间被本账号管理器并发切换。该检查不读取认证文件或 profile 内容。

下一轮必须继续保持这些边界。

## 12. App Server 子进程行为

第二轮真人 PoC：

    ChildCleanup = Normal
    AccountStabilityLockCleanup = Released

行为：

- PoC 只持有自己启动的 app-server child；
- 查询完成后关闭 stdin；
- child 自行正常退出；
- 写操作 mutex 正常释放；
- 没有枚举其他 codex.exe；
- 没有关闭 Codex Desktop；
- 没有执行 taskkill 或 Stop-Process；
- 没有强杀其他进程；
- 没有残留后台 child。

未来如果 stdin 关闭后 child 在规定时间内没有自行退出，兜底清理也只能针对 PoC 精确持有的 Process 实例，禁止按进程名扩大范围。

## 13. 下一步最高优先级

下一账号接手后不要直接接 GUI。

第一优先级仍是完成 quota App Server PoC：

1. 创建独立、PS5.1/PS7 兼容的 sanitized parser；
2. 将泛型窗口集合使用 .ToArray() 转换；
3. fake 测试覆盖 5-hour、weekly、其他 duration、顺序变化、单窗口、合法空 snapshot、percentage clamp、reset 缺失、ordinaryUsageAllowed 三态、多 bucket 选择和输出脱敏；
4. JSONL client 持续读取到匹配 request id；
5. notification 只记录安全 method 名和计数；
6. 60 秒内只有一个 account/rateLimits/read 在 flight；
7. 用户明确允许后，再执行一次真实只读查询；
8. 输出脱敏 summary；
9. 用户人工与 Settings → Usage 对照。

只有真实数据一致后，才开始：

    quota cache
    +
    GUI integration

## 14. 后续 quota cache 目标

未来建议路径：

    state\quota-cache.json

该文件必须继续 Git ignored。

只允许保存非敏感快照字段，例如：

- 本地 Profile 昵称；
- usage windows 和 duration；
- remaining percentage；
- reset timestamp；
- ordinaryUsageAllowed；
- queried_at；
- 成功、旧缓存或更新失败等非敏感状态。

禁止保存任何真实账号标识、邮箱、token、Cookie、auth 内容、credential、DPAPI 明文、raw App Server response 或 HTTP headers。

缓存更新必须遵循：

- 只查询并更新当前 active profile；
- inactive profile 的最后成功快照长期保留；
- 失败不得覆盖旧成功快照；
- Profile 名称只是本地显示键，不得把远端账号标识写入 cache；
- 切号成功前后明确区分旧 active 和新 active，避免写错 Profile。

## 15. 语言切换待办

用户已确认未来需要右上角中英语言切换：

    zh-CN
    en-US

语言选择需要持久化，并且和主题一样只属于非敏感 UI preference。尚未开始实现。

后续不得在各事件 handler 中散落大量 if Chinese / else English。应先设计统一的 localization resource / string dictionary，集中管理窗口标题、状态文本、按钮、对话框、错误映射、quota window 标签和成功/警告消息。

语言切换不得影响 auth、profile、identity、active state、Switch 事务或 quota 数据本身。

## 16. UI 后续方向

只有 quota PoC 真人数据对照成功以后，才进入：

1. quota snapshot UI；
2. 中英语言切换；
3. quota cache；
4. 最终视觉成品化。

视觉阶段待办：

- 真正玻璃拟态；
- DataGrid 更成熟的行高和文字上下空间；
- Active / Selected / Active+Selected 最终样式；
- 功能按钮语义色；
- 背景素材重新设计；
- 最终快捷方式或 EXE。

这些工作不得抢在 quota 官方链路验收之前，也不得借视觉调整重构认证核心或 Switch 事务。

## 17. 最终权威原则

如果旧 HANDOFF、旧聊天记录、本增量交接、当前仓库、自动测试或真人实机验收结果发生冲突，以以下顺序作为最高权威：

1. 当前 Git 仓库实际代码；
2. 当前 HEAD；
3. 当前可复现测试；
4. 真人实机验收结果；
5. 交接文档和旧聊天只作为背景材料。

下一账号开始任何开发前必须先执行：

    git branch --show-current
    git rev-parse --short=8 HEAD
    git status --short
    git log -12 --oneline

若 working tree 出现未知修改，先只读审计；不得 reset、restore、clean 或覆盖未确认的本地成果。

本交接完成后应停止，不继续 quota PoC、不继续 GUI 开发、不运行真实切号。
