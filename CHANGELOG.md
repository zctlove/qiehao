# Changelog（变更日志）

本文件记录面向用户的重要变化，不展开内部提交历史。

## v1.1.1 — 2026-11-02

**Release scope（发布范围）：** 收口已通过用户真实手工验收的多账号维护修复，更新双语说明，并从正式源码重新编译 v1.1.1 Windows 启动器（ships the manually accepted multi-account maintenance fixes, updated bilingual guidance, and a rebuilt v1.1.1 Windows launcher）.

Profile 格式、DPAPI CurrentUser 加密和既有账号事务保持兼容（Profile format, DPAPI CurrentUser protection, and existing account transactions remain compatible）.

Documentation（使用说明）：明确三个及以上 Plus / Team 本地档案管理的适用场景，以及同机同路径的项目文件连续使用；这不包含官方聊天记录、项目元数据或 Memory 的账号间同步。补充保存确认、运行期间删除保护、历史额度归属和客户端初始化提醒（clarifies three-or-more Plus / Team profiles and local file continuity on the same computer and paths, without cross-account chat, project metadata, or Memory synchronization; adds saving, deletion-protection, cache-ownership, and client-initialization guidance）.

Validation disclosure（验证披露）：发布记录保留实际 PASS、FAIL、NOT RUN 数量。PS5.1 完整 GUI 自测的后台 Job 结果接收存在测试基础设施问题；没有把该用例或未执行项目标成 PASS，也不宣称全部自动测试通过（release records disclose actual PASS, FAIL, and NOT RUN counts; a PS5.1 background-job result-receive issue remains documented as test infrastructure, without claiming that test or the full matrix passed）.

### Added / Improved（新增／改善）

- Added a read-only identity inspection path after an OAuth completion failure when the current authorization may already have changed; save a new profile only after reliable verification and a separate user confirmation（OAuth 完成失败但当前授权可能已改变时，增加只读身份核对；只有身份可靠验证并经用户再次确认后才保存新档案）.
- Removed the active-profile synchronization prerequisite from this verified fallback-add path; existing profiles are not overwritten and already-saved identities are not duplicated（此异常恢复新增路径不再要求先同步活动档案；不覆盖已有档案，不重复保存已存在身份）.
- Added narrowly scoped, explicitly confirmed recovery for a verified Personal Plus current sign-in versus a saved Team active profile（增加严格限定且需要明确确认的 Personal Plus 当前登录与已保存 Team 活动档案恢复路径）.
- Bound quota snapshots to stable profile identity; legacy cache ownership remains unverified, and identity mismatch blocks quota queries or cache writes（额度快照绑定稳定档案身份；旧缓存归属保持未验证，身份不一致时阻止额度查询或缓存写入）.
- Updated Chinese and English user guidance for OAuth rejection, identity mismatch, Team recovery, historical quota cache, and manual-stop conditions（更新中英文用户说明，覆盖 OAuth 被拒绝、身份错位、Team 恢复、历史额度缓存及必须人工停止的情况）.
- Increased the bounded post-switch official verification budget to 8 seconds, with up to 4 seconds for the first account read; refresh uses only the remaining total budget, with no automatic retry（切号后官方验证整体预算增至 8 秒，首次读取最多 4 秒；刷新后读取只使用整体剩余时间，不增加自动重试）.
- Retained local-switch commit facts on transient verification timeouts and improved quota feedback and dialog placement（暂时性验证超时保留本地切换提交事实，改善额度反馈与弹窗位置）.

### Known limitations（已知限制，尚未宣称解决）

- Codex Desktop may occasionally display signed out after reopening; official OAuth completion can still be rejected. These changes improve safe diagnosis and recovery but do not guarantee desktop sign-in or server-side acceptance（Codex Desktop 重新打开后偶尔仍可能显示未登录；官方 OAuth 完成通知仍可能被拒绝。本轮改善安全诊断和恢复流程，但不保证桌面端登录或服务端接受）.
- Quota caches remain auxiliary snapshots, not identity evidence. Stop when manual inspection is required; v1.1.0 packages require an explicit program update to receive these fixes（额度缓存仍是辅助快照，不是身份依据；人工检查提示必须停止操作，v1.1.0 程序包需主动更新才能获得这些修复）.

## v1.1.0 — 2026-10-04

### Added / Improved（新增／改善）

- Added Qiehao.exe no-console launcher; retained Start-Qiehao.cmd for compatibility and troubleshooting（新增无控制台 EXE 启动器，保留 CMD 兼容／排障入口）.
- Added official ChatGPT browser OAuth account add through Codex app-server, with explicit legacy fallback（官方浏览器添加账号及明确旧流程回退）.
- Added post-switch official account verification, separate from local transaction completion（切换后官方验证与本地事务分别报告）.
- Persist refreshed authentication as original bytes in the active Profile only when identity checks pass（身份严格一致时安全回存原始刷新认证）.
- Added support for verified persistent Windows Codex Sandbox Service（支持经严格验证的常驻 Windows 沙箱服务）.
- Improved sequential managed-login reliability, cancellation, and child cleanup（改善连续托管登录、取消与子进程清理）.
- Improved Active Profile / Current GUI synchronization and transactional Refresh snapshots（改善当前账号同步与事务式刷新快照）.
- Improved exact Qiehao-owned app-server tracking through child exit（改善自有应用服务进程跟踪，持续至退出）.
- Improved Quota compatibility and isolation from account lifecycle; best-effort snapshots remain auxiliary（改善额度兼容与账号生命周期隔离，尽力而为的快照仍为辅助能力）.
- Updated bilingual launch, account-add, same-user upgrade, and program-only rollback guidance（更新双语启动、添加、同用户升级与仅回退程序的说明）.

### Fixed（修复）

- Fixed verified persistent Sandbox Service being mistaken for blocking Codex（修复可信常驻沙箱服务误阻塞）.
- Fixed OAuth failure or cancellation leaving Add disabled or the GUI stuck Busy（修复登录失败／取消后添加禁用或忙状态残留）.
- Fixed Refresh temporarily hiding saved profiles; failed/incomplete snapshots preserve existing rows（修复刷新暂时隐藏档案，失败／不完整快照保留既有行）.
- Fixed stale Current account state and stale async GUI results overriding newer commits（修复当前账号滞后及过期异步结果覆盖较新提交）.
- Fixed locally committed switches being reported as failures when official verification only timed out（修复官方验证暂时超时导致本地已提交切换被误报失败）.
- Fixed ownership races that could misclassify Qiehao-owned Quota / Verify / Login children as external Codex（修复自有额度／验证／登录子进程被误判为外部 Codex 的竞态）.

Profile format, DPAPI CurrentUser, identity checks, and account transaction safeguards remain intact（档案格式、当前用户加密、身份校验与账号事务安全边界保持不变）. Historical releases remain available; quota/network failures do not imply a failed local switch（保留历史版本，额度／网络失败不等于本地切换失败）.

## Historical development candidate: v1.1.0 test5 — Unreleased（历史测试候选，未单独发布）

This section is retained for development history only. Test5 was not a separate public release; the later published v1.1.0 release is listed above.（本节仅保留开发历史。test5 不是单独的公开发布版本；后续正式发布的 v1.1.0 已列于上方。）

### Added / Improved（新增／改善）

- Direct official ChatGPT browser OAuth account add through Codex app-server（通过官方应用服务发起浏览器添加账号）.
- Post-switch official account verification, reported separately from local transaction completion（切换后官方验证，与本地事务分别报告）.
- Safely persist refreshed authentication as original bytes in the active local profile（身份严格一致时将刷新认证原字节安全回存）.
- Compatibility for persistent Windows Codex Sandbox Service（兼容常驻 Windows Codex 沙箱服务）.
- Managed-login cancellation, independent timeouts, cleanup, and sequential login reliability（托管登录取消、独立超时、清理及连续添加可靠性）.
- Active Profile / Current account GUI synchronization and stale-result rejection（当前账号同步及过期异步结果拒绝）.
- Quota request compatibility and lifecycle isolation; cached snapshots, not real-time monitoring（额度兼容与账号操作隔离，保留快照而非实时监控）.
- Thin Qiehao.exe launcher for normal no-console startup, with Start-Qiehao.cmd retained as a backup（薄 EXE 无控制台启动器，保留 CMD 备用入口）.
- Production version identifiers unified to 1.1.0 and same-user upgrade instructions（生产版本统一及同机同用户升级说明）.

### Fixed（修复）

- False "Codex is running" caused by a proven persistent codex-windows-sandbox-service.exe（经证明的常驻沙箱服务造成的误阻塞）.
- Account switch reporting success before official verification completed（官方验证前提前宣称成功）.
- Stale Current display until Codex Desktop was launched（未启动 Desktop 时当前账号显示滞后）.
- OAuth failure/cancellation leaving Add disabled or the GUI stuck busy（登录失败／取消后添加禁用或界面忙状态卡住）.
- Refresh temporarily hiding saved profiles during account login（登录期间刷新暂时隐藏账号）.
- Stale asynchronous GUI results overwriting newer committed state（过期异步结果覆盖较新已提交状态）.

These fixes were implemented in test2-test4. Test5 only adds launcher/package/documentation and version-literal changes; it does not redesign account transactions, DPAPI, profile format, OAuth, or Quota（上述修复来自 test2–test4，test5 仅收口启动器、包装、文档及版本字面量，不重做核心）.

## Historical development candidate: v1.0.4 test3 — Unreleased（历史测试候选，未发布）

- Preserve verified Windows Sandbox Service compatibility（保留经严格证明的 Windows 沙箱服务兼容）。
- Separate local switch commit from bounded official account verification（区分本地切换提交与有界官方账号验证）。
- Persist official token refresh as original DPAPI-protected bytes without changing profile format（官方刷新后保留原字节安全回存，不改变档案格式）。
- Delegate the existing Add Account entry to official managed ChatGPT browser login, with cancellation and explicit legacy fallback（现有添加入口委托官方托管浏览器登录，支持取消和明确旧版回退）。
- Responsive lifecycle worker, quota isolation, and safe verification diagnostics（响应式账号操作、额度隔离与安全验证诊断）。
- Same-user in-place upgrade guidance and synthetic compatibility tests（同用户原目录升级说明与合成数据兼容测试）。
- Immediately refresh committed Active Profile on the GUI dispatcher, preserve recovery uncertainty, and reject stale refreshes（GUI 主线程立即刷新已提交当前账号，保留人工恢复的不确定状态，丢弃过期刷新）。

At the time this historical candidate was recorded, v1.0.3 was the recommended release; v1.0.4 test3 was not published（记录该历史候选时，正式推荐版本为 v1.0.3；v1.0.4 test3 未公开发布）。 The current latest published release is v1.1.1（当前最新正式发布版本为 v1.1.1，见上文）。

## v1

- Secure local Codex profile switching（安全的本地 Codex 档案切换）
- Manual exit gate（用户正常退出与进程门禁）
- Identity verification（身份一致性验证）
- Quota Snapshot（额度快照与失败保留旧缓存）
- zh-CN / en-US（简体中文/英文界面）
- Responsive account grid（响应式账号表格）
- 7 themes（7 套主题）
- ZCT watermark（ZCT 品牌水印）
