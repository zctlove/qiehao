Qiehao v1.1.0（当前最新正式发布版本）

源码提示：GitHub main 已包含 v1.1.0 发布后的维护修复（源码检查点 18d4e3b），但尚未创建新 Release 或更新 ZIP/EXE。普通用户只下载 Releases 中的正式 ZIP；不要把仓库 Code → Download ZIP 当作安装包。

先说一句：Qiehao 不反代。

使用：

1. 请先把 ZIP 完整解压，不要直接在压缩包里运行。
2. 推荐双击 Qiehao.exe；Start-Qiehao.cmd 保留为兼容／排障入口。
3. 完全退出 Codex Desktop 后，在 Qiehao 点击添加账号，完成官方浏览器 OAuth 登录；不支持时按提示使用旧导入流程。
4. 切换账号时，按照提示正常退出 Codex。
5. Qiehao 不自动切号、不做账号池、不后台轮询多个账号、不读取浏览器 Cookie。
6. 额度查询使用 Codex app-server，偶尔可能比较慢或超时，失败时可稍后手动刷新。
7. 提供 Windows GUI（图形界面）EXE 启动器，不提供安装器；升级和安全说明见 README.md。
8. 有问题欢迎通过 GitHub Issues 反馈。
9. 如果 OAuth 报告失败但提示授权可能已改变，只在界面提供时使用“检查当前登录身份（只读）”；只有可靠验证并再次确认后才保存新档案。
10. “旧额度缓存归属未验证／历史缓存”不能当作当前账号额度；身份不一致时额度查询会暂停。
11. 如果提示“请勿启动 Codex／需要人工检查”，不要启动 Codex，不要重复操作，不要手工修改或删除认证文件和本地档案。
12. 不要在公开 Issue 上传 auth.json、Token、邮箱、账号 ID、Cookie、真实额度响应或其他真实凭据。

English

Qiehao v1.1.0 (latest published release)

Source note: GitHub main contains post-v1.1.0 maintenance fixes (source checkpoint 18d4e3b), but no new Release or updated ZIP/EXE has been published. Regular users should download the published ZIP from Releases; do not treat the repository's Code → Download ZIP as an installer.

First things first: Qiehao is not a reverse proxy.

Usage:

1. Extract the ZIP completely before running it.
2. Double-click Qiehao.exe; Start-Qiehao.cmd remains a compatibility/troubleshooting entry.
3. Completely exit Codex Desktop, select Add Account in Qiehao, and complete official browser OAuth. If unsupported, follow the legacy-import instructions.
4. When switching, exit Codex normally when prompted.
5. Qiehao does not automatically rotate accounts, maintain an account pool, poll multiple accounts in the background, or read browser cookies.
6. Quota refresh uses the Codex app-server and may occasionally be slow or time out. Retry manually later if needed.
7. A Windows GUI EXE launcher is included, not an installer. See README.en-US.md for upgrade and safety guidance.
8. Feedback is welcome through GitHub Issues.
9. If OAuth reports failure but the authorization may have changed, use “Check current identity (read-only)” only when the UI offers it. Save a new profile only after reliable verification and a separate confirmation.
10. “Legacy quota cache ownership unverified / Historical cache” must not be treated as the current account's quota. Quota queries pause when identities mismatch.
11. If Qiehao says “Do not start Codex / manual inspection required,” do not launch Codex, repeat the operation, or manually edit/delete authentication files or local profiles.
12. Never post auth.json, tokens, email addresses, account IDs, cookies, real quota responses, or other real credentials in public issues.
