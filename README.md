# Qiehao

Qiehao 是一个面向 Windows Codex Desktop 的本地账号切换工具，提供中文/英文 WPF 图形界面，并以“用户手动触发、Codex 完全退出后再切换”为核心安全边界。

> [!IMPORTANT]
> Qiehao 是非官方社区工具，不是 OpenAI 官方产品。它只管理 Codex Desktop 的本地认证状态，不修改 ChatGPT Web、浏览器或 PWA（渐进式网页应用）的登录状态。

## 项目定位

- 仅面向 Codex Desktop，不支持自动账号轮换。
- 不读取浏览器 Cookie（浏览器凭据）、LocalStorage（本地存储）或 IndexedDB（浏览器数据库）。
- 不修改或退出 ChatGPT Web/PWA 会话。
- 不根据 Quota（额度）、HTTP 429 或其他错误自动切号。
- 不做 round-robin（轮询轮换）或后台自动切换。
- 每次账号切换都必须由用户明确触发。

## 工作方式

首次添加新账号时，用户仍通过 Codex 官方 OAuth（开放授权）流程手动登录。Codex 完全退出后，Qiehao 将该账号的本地认证状态保存为由 Windows DPAPI CurrentUser（数据保护 API，当前用户作用域）保护的加密快照。

后续切换时，Qiehao 要求 Codex Desktop 完全退出，然后安全回存当前账号、验证目标账号、原子替换 Codex 本地认证文件、读回校验，最后更新本地 Active Profile（当前活动档案）状态。Qiehao 不自动操作 OAuth、不强制终止 Codex，也不接触浏览器登录态。

## 安全设计

- **Manual-only switching（仅手动切换）**：切换只由用户点击发起。
- **DPAPI CurrentUser（当前用户加密）**：认证快照和身份标记只能由同一 Windows 用户解密。
- **Atomic replace（原子替换）**：关键文件使用同卷临时文件和原子替换，避免半写入状态。
- **Reread verification（读回验证）**：替换后重新读取并逐字节核对目标内容。
- **Rollback（回滚）**：替换后验证或状态提交失败时，尝试恢复原活动账号。
- **Named mutex（命名互斥锁）**：写操作串行化，避免多个实例并发修改。
- **Process gate（进程门禁）**：仅在 Codex 已确认完全退出时执行认证写操作。
- **Unknown fail closed（未知状态安全拒绝）**：无法可靠判断进程或认证状态时停止，不冒险继续。
- **No forced kill（不强杀）**：要求用户从 Codex 官方菜单或系统托盘正常退出。
- **Browser/PWA untouched（浏览器/PWA 不受影响）**：不读取或修改浏览器会话数据。

## Quota Snapshot（额度快照）

额度快照通过 Codex 官方 app-server 接口读取当前 Active Profile 的额度信息：

- 只主动查询当前 Active Profile；
- inactive profile（非活动档案）只显示最后一次成功缓存；
- 不持续轮询，不构成实时额度监控；
- 查询失败时保留旧快照，不清零、不伪造更新时间；
- 快照只代表最后一次成功查询结果，不保证实时性；
- 额度失败不会自动触发账号切换。

## 系统要求

- Designed for Windows 10/11（为 Windows 10/11 设计）
- Windows PowerShell 5.1
- PowerShell 7（已纳入自动测试矩阵）
- Codex Desktop

当前版本仅支持 Windows，不支持 macOS。

## 启动

推荐双击仓库根目录中的：

~~~text
Start-Qiehao.cmd
~~~

也可以在仓库根目录手动运行：

~~~powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File ".\gui\QiehaoGui.ps1"
~~~

这里的 ExecutionPolicy Bypass（绕过执行策略）只应用于本次启动的 PowerShell 进程，不会永久修改系统 PowerShell 执行策略，不写注册表，也不要求管理员权限。

## 使用方法

1. 启动 Qiehao。
2. 使用 Codex 官方登录流程登录账号。
3. 按界面引导添加本地 Profile（档案）。
4. 需要切换时选择目标档案并点击“切换账号”。
5. 按提示从 Codex 官方菜单或系统托盘正常退出 Codex。
6. Qiehao 检测到 Codex 完全退出后执行安全切换。
7. 切换完成后，由用户手动重新启动 Codex。

不要把关闭主窗口等同于完全退出；Codex 仍可能驻留在系统托盘。Qiehao 不会把任务管理器强杀当作正常流程。

## 主题与语言

界面支持 zh-CN 和 en-US，并提供 7 套主题：

1. 01 Tech Blue（科技蓝）
2. 02 Navy Gold（深蓝鎏金）
3. 03 Ice Glass（冰蓝玻璃）
4. 04 Purple Nebula（紫蓝星河）
5. 05 Light Flow（清透流光）
6. 06 Aurora Silver Blue（极光银蓝）
7. 07 Arctic Sea Glass（浅海冰晶）

主题只改变视觉，不改变账号数据、认证保护、进程门禁或切换逻辑。

## Privacy（隐私）

- Local-first（本地优先）：档案、状态和额度缓存保存在本机运行目录中。
- Browser/PWA untouched（浏览器/PWA 不受影响）。
- 本项目未加入 telemetry（遥测）或 analytics（分析统计）。
- 本项目不运营中转服务器。
- 不对非活动账号发起额度查询。
- profiles/、state/、logs/、backup/、auth.json、DPAPI 容器和额度缓存均不得提交到 Git。

用户应妥善保护自己的 Windows 账号、Codex 登录和本机环境。不要向公开 Issue（问题）粘贴认证文件、Token（令牌）、邮箱、账号 ID、Cookie 或含凭据的日志。

## 命令行入口

qiehao.ps1 提供安全后端命令，例如：

~~~powershell
.\qiehao.ps1 status
.\qiehao.ps1 list
.\qiehao.ps1 active
.\qiehao.ps1 verify-profile ExampleProfile
~~~

涉及保存、添加、重命名、删除和切换的命令具有额外的进程门禁、身份验证和确认要求。普通用户建议通过 GUI（图形界面）完成流程。

## Development（开发）

项目同时在 Windows PowerShell 5.1 与 PowerShell 7 下验证。核心自测试位于 tests/，包括：

- SelfTest.ps1
- GuiSelfTest.ps1
- VisualPolishSelfTest.ps1
- AccountGridLayoutSelfTest.ps1
- LocalizationSelfTest.ps1
- Quota 与 Switch-before-Quota（切换前额度快照）系列测试
- LauncherSelfTest.ps1

所有自动测试使用 fake-only（仅假数据）或 hidden/offscreen WPF（隐藏/离屏 WPF）；开发和 CI（持续集成）不得读取真实认证档案或发送真实额度请求。贡献前请阅读 [CONTRIBUTING.md](CONTRIBUTING.md)，安全问题处理方式见 [SECURITY.md](SECURITY.md)。

## 风险与许可证

Qiehao 操作本机 Codex 认证状态，使用前应确认源码来源并保留可恢复环境。官方 Codex 的本地文件格式或行为未来可能变化；遇到未知结构时，工具应安全拒绝而不是猜测。

本项目采用 [MIT License（MIT 许可证）](LICENSE)，Copyright (c) 2026 ZCT。完整条款以仓库根目录 LICENSE 为准。
