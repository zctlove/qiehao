# Changelog（变更日志）

本文件记录面向用户的重要变化，不展开内部提交历史。

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

## v1.1.0 test5 — Unreleased（测试中，尚未正式发布）

The current official recommended release remains v1.0.3（当前正式推荐版本仍为 v1.0.3）. Test5 packages the real-user-accepted test4 core; no tag or GitHub Release is created in this round（test5 保留真人通过的 test4 核心，本轮不创建标签或正式发布）.

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

## v1.0.4 test3 — Unreleased（尚未正式发布）

- Preserve verified Windows Sandbox Service compatibility（保留经严格证明的 Windows 沙箱服务兼容）。
- Separate local switch commit from bounded official account verification（区分本地切换提交与有界官方账号验证）。
- Persist official token refresh as original DPAPI-protected bytes without changing profile format（官方刷新后保留原字节安全回存，不改变档案格式）。
- Delegate the existing Add Account entry to official managed ChatGPT browser login, with cancellation and explicit legacy fallback（现有添加入口委托官方托管浏览器登录，支持取消和明确旧版回退）。
- Responsive lifecycle worker, quota isolation, and safe verification diagnostics（响应式账号操作、额度隔离与安全验证诊断）。
- Same-user in-place upgrade guidance and synthetic compatibility tests（同用户原目录升级说明与合成数据兼容测试）。
- Immediately refresh committed Active Profile on the GUI dispatcher, preserve recovery uncertainty, and reject stale refreshes（GUI 主线程立即刷新已提交当前账号，保留人工恢复的不确定状态，丢弃过期刷新）。

Official recommended version remains v1.0.3（正式推荐版本仍为 v1.0.3）；no v1.0.4 release is published by this task（本轮不发布 v1.0.4）。

## v1

- Secure local Codex profile switching（安全的本地 Codex 档案切换）
- Manual exit gate（用户正常退出与进程门禁）
- Identity verification（身份一致性验证）
- Quota Snapshot（额度快照与失败保留旧缓存）
- zh-CN / en-US（简体中文/英文界面）
- Responsive account grid（响应式账号表格）
- 7 themes（7 套主题）
- ZCT watermark（ZCT 品牌水印）
