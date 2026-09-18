# Plus → Team 增量交接（2026-09-18）

本文档是相对于既有交接的增量交接，只记录 504049a quota-appserver-poc 之后的变化、4ae0e77 quota-snapshot-gui-cache 的真人启动回归，以及下一账号应如何安全接手。

不要重写或删除以下历史交接：

- docs/HANDOFF-TEAM-TO-PLUS-2026-09-17.md
- docs/HANDOFF-PLUS-TO-TEAM-2026-09-17.md
- docs/HANDOFF-TEAM-TO-PLUS-2026-09-18.md

本文档不包含任何真实认证值、原始 App Server response、私有账号标识或浏览器数据。

## 1. 本轮立即停止开发

用户当前 Plus 账号额度只剩约 11%，本轮只允许创建并提交本增量交接。

本轮不得：

- 继续修 Bug 或增加功能；
- 再次修改 GUI 或业务代码；
- 启动新的真实额度查询；
- 启动真实 GUI 做验收；
- 执行真实 Switch / Add / Rename / Delete；
- 读取真实 auth/profile 内容；
- 删除、重建或迁移任何账号 Profile；
- 清理或重置 .codex、state、网络、TUN、proxy 或 permissions；
- 运行完整测试套件；
- merge、push 或访问 remote。

## 2. 创建本文档前的 Git 状态

- 项目：E:\codex\qiehaoqu
- Branch：feature/gui-v1
- HEAD：4ae0e772d47b75ab88f0c95fda131e9aa5c78e25
- HEAD short：4ae0e77
- Commit message：quota-snapshot-gui-cache
- 创建本文档前 working tree：clean

最近 12 条提交：

    4ae0e77 quota-snapshot-gui-cache
    504049a quota-appserver-poc
    c14f9f1 docs-team-to-plus-handoff-2026-09-18
    48dd5b5 fix-switch-ui-sync-dialog
    c2975e7 one-click-manual-quit-auto-switch
    0deeb88 manual-quit-auto-continue
    03f5d41 docs-plus-to-team-handoff
    d65ffcb native-codex-quit
    9c3211a fix-exit-wait-timer-closure
    6f7154c fix-theme-persistence-real-event
    49221d2 fix-exit-prefs-polling
    42e1a4e docs-team-to-plus-handoff

## 3. 最后的已知良好 GUI 基线

真人已经通过的 GUI 核心基线是：

    48dd5b5 fix-switch-ui-sync-dialog

该提交已经真人验证：

- 原有 Plus ↔ Team Switch 主链；
- 一次点击进入人工安全退出等待；
- 500ms 本机进程检测；
- 用户从 Codex 官方入口退出后自动续切；
- Backend Switch 成功后的同步 Refresh；
- Active 行即时迁移；
- 当前 Profile 和成功状态即时更新；
- 原有 Verify / Switch / Launch / Identity / Theme 等 GUI 行为。

随后 c14f9f1 docs-team-to-plus-handoff-2026-09-18 只增加交接文档，没有改变 GUI 行为。

再随后 504049a quota-appserver-poc 只增加官方额度读取 PoC、净化 Parser 和 fake 测试，没有修改主 GUI 核心行为。

因此，504049a 是当前必须保留的最后基线：

> Quota 官方 RPC PoC 已加入并真人验证成功，同时原 GUI 主流程仍保持已知良好。

不得丢失或回退掉 504049a 中已成功的 Quota PoC。

## 4. Quota PoC 已经真人端到端 PASS

本机版本：

    codex-cli 0.154.0-alpha.6.2

官方链路：

    codex app-server
    → initialize
    → initialized
    → account/rateLimits/read

请求参数：

    excludeResetCreditDetails = true
    supportsLunaReserve = omitted

真人诊断结果：

    MatchingResponseReceived = True
    MatchingErrorReceived = False
    LinesReceived = 2
    NotificationsReceived = 1
    ElapsedMilliseconds ≈ 2225
    Plan = Plus
    ordinaryUsageAllowed = True

真人返回的 Usage Windows：

    300 min
    → 5-hour
    → Remaining 84%
    → reset 2026-09-18 16:41:06 +08:00

    10080 min
    → Weekly
    → Remaining 61%
    → reset 2026-09-19 16:28:00 +08:00

随后用户真人打开 Usage 页面核对：

- 5-hour 从 84% 继续使用后变为约 82%；
- Weekly 仍为 61%。

因此，官方额度读取链路已经形成真人闭环。后续排障不要把 GUI 启动回归误判为 Quota RPC 本身未验证。

## 5. Quota PoC 安全边界必须继续保留

当前安全设计已经确认不读取：

- auth.json；
- token、access token、refresh token；
- accountId、email；
- DPAPI profile；
- Cookie；
- browser profile；
- Local Storage。

也不直接调用：

- private backend / backend-api；
- Invoke-WebRequest；
- Invoke-RestMethod；
- HttpClient；
- curl；
- wget。

认证和账号上下文全部由官方 codex app-server 自行处理。这个设计不可改变，不要为了修复 GUI 回归而读取认证内容或自行构造 Authorization。

## 6. 4ae0e77 的实现目标

4ae0e77 quota-snapshot-gui-cache 尝试把已验证的官方额度读取能力接入 GUI，包括：

- state\quota-cache.json 长期持久缓存；
- 保存每个旧账号最后一次成功额度快照；
- GUI open 只查询 Current Profile；
- inactive Profile 永不主动联网；
- switch-before 为旧 Current 留最后快照；
- switch-after 查询新 Current；
- 手工“刷新额度”；
- 动态 Usage Windows；
- Rename/Delete 的 cache 生命周期；
- DataGrid“额度快照”概要列；
- “刷新额度”按钮；
- quota 中文字符串集中管理；
- fake-only 自动测试。

自动测试当时全部报告 PASS，包括 PS5.1 / PS7 Parser、GUI、自检、静态解析和敏感扫描。

但是，真人第一次启动 GUI 即出现初始化回归。

结论：

> 自动测试 PASS 不能作为 4ae0e77 的真人验收依据。

## 7. 4ae0e77 真人启动后的实际故障

用户真人截图确认 GUI 窗口可以打开，皮肤和基本窗口能够显示，但初始化状态错误。

顶部状态：

    Codex 客户端：未知
    当前账号：未初始化
    当前身份确认：无法确认
    网页 ChatGPT：不受影响

安全提示：

    无法确认 Codex 是否完全退出，
    请先检查 Codex 状态；
    为保护账号状态，切换与写操作将安全停止。

账号区域：

    已保存账号：0 个账号

DataGrid 完全为空。

Switch / Verify / Rename / Delete 等按钮被禁用。

底部状态：

    部分只读状态不可用

因此，当前 4ae0e77 GUI 不能用于正常账号切换真人验收。

## 8. 不要认为账号真的丢失

目前没有证据证明以下任何情况发生：

- Profile 文件被删除；
- auth 被删除；
- DPAPI profile 被破坏；
- active state 被删除；
- Plus 或 Team 账号槽位真正丢失。

截图更符合以下一类启动初始化回归：

- GUI startup 初始化顺序；
- 主只读 Refresh；
- Quota module import；
- Quota cache load；
- 异步 quota initialization；
- Profile rows 构造或 DataGrid binding。

下一账号必须先按“GUI 初始化回归”调查。

在没有明确文件证据前，禁止：

- 删除任何 Profile；
- 重新 Add Account；
- 重新登录两个账号；
- 重建 auth；
- 清理 .codex；
- 重装 Codex；
- 删除、重建或重置 state。

## 9. 下一账号的第一优先级

不要增加新功能。

第一目标是恢复 4ae0e77 后 GUI 的正常启动初始化。

成功后，真人打开 GUI 应重新看到：

- 已保存 Plus；
- 已保存 Team；
- 正确的 Current Profile；
- 正确的 Codex Running / Stopped 状态；
- 原有 Active 行；
- 原有 Verify / Switch / Launch 状态。

在上述目标真人通过前，不要：

- 美化 quota UI；
- 实现语言切换；
- 开始正式视觉优化；
- 扩展新的额度功能；
- 做完整重构。

## 10. 推荐的只读排查方向

第一步只做代码级 diff：

    git diff 504049a..4ae0e77 -- gui tools tests .gitignore

重点检查：

1. QiehaoGui.ps1 启动初始化顺序；
2. QuotaHelpers.psm1 import 是否可能抛异常；
3. QuotaClient.psm1 import 是否改变全局状态；
4. quota cache 加载失败是否错误影响主 Profile refresh；
5. 新增 async quota initialization 是否提前进入 Busy 或 fail-closed；
6. Invoke-QiehaoReadOnlyRefresh 是否因 quota 相关错误整体失败；
7. quota provider 是否被错误放进主 snapshot 构造；
8. GUI Loaded handler 是否覆盖、短路或提前中断原初始化；
9. 新 module/function 名是否发生作用域或命名冲突；
10. 新 DataGrid row model 是否导致原 Profile rows 构造异常；
11. quota row decoration 是否对空值、不同 PSObject 类型或 PowerShell 5.1 产生运行时异常；
12. 顶层 Quota module import 是否让本来独立的附属功能变成 GUI 启动硬依赖。

核心原则：

> Quota 是附属只读能力。任何 quota cache、parser、RPC 或 UI 错误，都必须对原 GUI 只读展示 fail-open。

这里的 fail-open 是指：

- Profile 列表仍正常加载；
- Current Profile 仍正常显示；
- Codex process state 仍正常显示；
- 原 Verify / Switch / Launch 状态仍正常；
- 只有 quota 区域显示不可用或旧缓存。

Quota 错误绝不能再次把整个账号管理器初始化成 0 accounts / uninitialized。

## 11. 不要直接 reset 到旧提交

接手后先诊断，不要第一步执行：

    git reset --hard 504049a

原因：

- 4ae0e77 已包含大量 quota cache / GUI integration 工作；
- 当前可能只是一个启动初始化错误；
- 直接 reset 会丢失定位线索，也容易误删可保留的安全实现。

优先路线：

    只读审计
    → 定位最小 root cause
    → fake/local test
    → 最小修复 commit
    → 用户允许后只真人启动 GUI 一次

只有确认 4ae0e77 的集成结构整体风险过高时，才考虑安全 revert。

如需回退 GUI integration，目标必须是恢复 504049a 的 GUI 行为，同时保留 504049a 已真人成功的官方 Quota PoC。不要回到更早、会丢失 PoC 的提交。

## 12. quota cache 产品规则仍然有效

GUI Bug 不改变以下产品原则：

1. 只查询 Current Active Profile。
2. Inactive Profile 永不主动联网。
3. 旧账号最后一次成功快照跨 GUI 关闭、GUI 重开和 Windows 重启长期保留。
4. 只有账号重新成为 Current，才允许重新查询。
5. 新查询失败不得删除、清零或覆盖旧成功快照。
6. Usage Window 必须动态显示服务器实际返回的窗口。
7. 不得硬编码所有账号都有 5-hour + Weekly。
8. 可能存在 weekly、monthly、其他周期、单窗口、多窗口或空窗口。
9. switch-before quota 失败不得阻止核心 Switch。
10. switch-after quota 失败不得把 Switch 成功改成失败。

## 13. localization 继续延后

用户仍需要右上角中文 / English 切换，并支持：

- zh-CN；
- en-US；
- 用户选择持久化。

但是，在 GUI 启动回归真人修复之前，不要实现语言切换。

Quota 新增字符串已经尝试集中管理。未来 localization 应继续使用统一资源字典，禁止在 handler 中继续散落大量语言 if/else。

## 14. 当前真人环境判断

最近 Codex 整体运行状态很好。重装清理后：

- 任务速度显著提高；
- 当天几乎没有重连；
- 用户仍使用 TUN。

不要随意修改网络、TUN、proxy 或 permissions 配置。

当前已知问题是账号管理器 GUI 的 4ae0e77 启动回归，不要误诊为：

- Codex 本身失效；
- 网络失效；
- 账号认证失效；
- Plus / Team 数据必然损坏。

## 15. 下一账号推荐执行顺序

1. 阅读本 HANDOFF；
2. 确认 Git clean；
3. 只读检查 504049a..4ae0e77；
4. 找出 GUI startup initialization regression；
5. 只使用 fake/local tests 修复；
6. 保证 quota 故障对原 GUI 主状态 fail-open；
7. 用户明确允许后，只真人启动 GUI 一次；
8. 确认 Plus / Team 两个 Profile 重新出现；
9. 确认 Current Profile 与 process state 正常；
10. 确认原 Switch 主链仍可使用；
11. 再验 quota cache；
12. 最后才继续 localization。

不要一上来完整重构。

## 16. 下一轮真人验收门槛

下一轮不能只报告自动测试 PASS，必须至少由用户真人确认：

A. 启动 GUI 能看到原有 Plus 和 Team 两个账号。

B. Current Profile 正确。

C. Codex Running / Stopped 状态正确。

D. 原 Switch 主链仍能使用。

E. Quota 功能失败时不影响 A-D。

只有 A-E 全部 PASS，才能认为 quota GUI integration 修复完成。

## 17. 继续遵守的安全边界

禁止：

- taskkill /F；
- Stop-Process -Force；
- Kill() 或 TerminateProcess 针对真实 Codex Desktop；
- SendKeys；
- 鼠标模拟；
- 固定坐标点击；
- OCR 或猜测式图像自动化；
- Electron 注入；
- app.asar 修改；
- private IPC；
- 修改 browser/PWA；
- 读取 browser Cookie。

真实测试时避免 Add / Delete / Rename，除非用户明确允许。

不要为了 GUI 排障读取真实 auth/profile 内容。先使用源码审计、fake fixture 和非敏感状态证据。

## 18. 本交接提交边界

本轮只新增：

    docs/HANDOFF-PLUS-TO-TEAM-2026-09-18.md

只允许执行：

- Git 只读状态确认；
- git diff --check；
- 本 HANDOFF 的敏感内容扫描；
- 精确暂存本 HANDOFF；
- 本地提交 docs-plus-to-team-handoff-2026-09-18。

禁止使用 git add .。

提交后立即停止开发，不执行测试、GUI、真实额度读取、merge、push 或 remote。
