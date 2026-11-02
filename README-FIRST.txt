Qiehao v1.1.1（正式版本，2026-11-02）

Windows Codex 多账号管理工具，支持 Plus、Team 等本地账号档案，适合管理三个及以上账号。在同一电脑、同一路径继续使用原有项目文件。
如果你使用的官方切换方式只有两个账号位置，可用 Qiehao 管理更多已保存档案；这不把两个账号视为所有官方版本的永久限制。
本地文件连续使用不等于官方聊天记录、项目元数据或 Memory（记忆）的账号间同步；Qiehao 不提供这些云端同步功能。

仅从 GitHub Releases 下载正式 Windows ZIP 并核对 SHA-256。Code → Download ZIP 是源码快照。正式包不含用户凭据或运行数据。
Qiehao 是非官方社区工具，不是 OpenAI 官方产品，不提供反代、自动账号池、自动切号或浏览器 Cookie 读取。

使用：
1. 完整解压 ZIP 后双击 Qiehao.exe；Start-Qiehao.cmd 为兼容／排障入口。
2. 添加账号使用官方 OAuth（开放授权）。OAuth 成功不等于本地档案保存成功，以最终结果和账号列表为准。
3. 切换前正常完全退出 Codex Desktop，包含后台客户端进程。Codex 运行期间，账号删除受到保护；不要强制结束进程绕过提示。
4. “检查当前登录身份（只读）”不会自动保存；身份可靠验证、属于新账号并经再次确认后，才能保存新档案。
5. 额度查询失败不能当作刷新成功，保留旧数字也不是本次查询结果。
6. 历史缓存“归属未验证”表示无法确认属于哪个已保存档案，不等于从未获取过额度。成功刷新并建立新的身份绑定后，才能作为可信快照。
7. Codex 启动时暂时显示未登录，先等待初始化；持续异常再完全退出并重新打开，必要时查看脱敏日志。不要连续重复切号或手工复制 auth.json。
8. 出现“请勿启动 Codex／需要人工检查”时，优先停止启动、添加、切换、恢复和删除；不要手工修改或删除认证和档案。
9. 升级只替换程序文件，保留自己的 profiles、state、logs、backup。DPAPI 档案仅支持同机同 Windows 用户，不要直接跨用户迁移。
10. 不要在公开 Issue 上传凭据、Token（令牌）、邮箱、账号 ID、Cookie（浏览器凭据）、完整日志或真实额度响应。
11. Windows 10/11 系统 Windows PowerShell 5.1 即可运行，无需 PowerShell 7 或管理员权限。详细升级、身份恢复及限制见 README.md。
12. 官方 OAuth 完成通知仍可能被拒绝；本地切换、官方身份验证、Desktop 登录显示是不同结果。额度获取依赖官方接口，可能失败或超时。

English

Qiehao v1.1.1 (official release, 2026-11-02)

A Windows Codex multi-account manager supporting local profiles such as Plus and Team, especially useful for three or more accounts. Continue using project files on the same computer at the same paths.
If your official switching option has only two account slots, Qiehao can manage more saved profiles; two accounts is not described as a permanent limit of every official version.
Local file continuity does not mean cross-account synchronization of official chats, project metadata, or Memory. Qiehao does not provide that cloud synchronization.

Download the official Windows ZIP from GitHub Releases and verify SHA-256. Code → Download ZIP is a source snapshot. The package contains no user credentials or runtime data.
Qiehao is an unofficial community tool, not an official OpenAI product. It provides no reverse proxy, automated account pool, automatic switching, or browser-cookie reading.

Usage:
1. Fully extract the ZIP and double-click Qiehao.exe. Start-Qiehao.cmd is the compatibility/troubleshooting entry.
2. Add accounts through official OAuth. Successful OAuth does not prove that a local profile was saved; check the final result and account list.
3. Fully exit Codex Desktop normally before switching, including background client processes. Profile deletion is protected while Codex is running; do not force-kill processes to bypass warnings.
4. Read-only identity inspection does not save automatically. Saving a new profile requires a reliably verified, previously unsaved identity and a separate confirmation.
5. A failed quota query is not a successful refresh. Retained numbers are not the result of that failed query.
6. Historical cache ownership marked unverified means that its saved-profile owner cannot be confirmed, not that quota was never retrieved. A successful refresh must establish a new identity binding before it is a trusted snapshot.
7. If Codex temporarily shows signed out at startup, wait for initialization. If it persists, fully exit and reopen it, then inspect redacted logs if needed. Do not switch repeatedly or manually copy auth.json.
8. An explicit “Do not start Codex / manual inspection required” warning takes priority: stop launching, adding, switching, recovering, and deleting. Do not manually edit or delete authentication or profile files.
9. Upgrade program files only, preserving your own profiles, state, logs, and backup. DPAPI profiles are supported only on the same computer under the same Windows user; do not migrate them directly across users.
10. Never post credentials, tokens, email addresses, account IDs, cookies, complete logs, or real quota responses in public issues.
11. Windows 10/11 with system Windows PowerShell 5.1 is sufficient. PowerShell 7 and administrator access are not required. See README.en-US.md for upgrades, recovery, and limitations.
12. Official OAuth completion notifications can still be rejected. A committed local switch, verified official identity, and the Desktop sign-in display are separate results. Quota requests depend on the official interface and may fail or time out.