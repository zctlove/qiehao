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

添加账号时，用户先在 Codex 中通过官方 OAuth（开放授权）流程登录或切换到要保存的账号。确认目标账号登录成功后，应完全退出 Codex 客户端，但不要注销当前登录账号。Qiehao 随后识别当前文件型登录凭据，并将其原始认证状态保存为由 Windows DPAPI CurrentUser（数据保护 API，当前用户作用域）保护的加密快照。

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

## 下载、安装与启动

普通用户请从 GitHub Releases 下载最新的 Qiehao Release ZIP（发布压缩包）：

1. 下载最新 Release ZIP。
2. 将 ZIP 完整解压到本地普通用户具有读写权限的目录。
3. 不要直接在 ZIP 压缩包内运行程序。
4. 普通用户推荐双击仓库或已完整解压 ZIP 根目录中的：

~~~text
Start-Qiehao.cmd
~~~

Qiehao 不需要管理员权限，也不需要安装 Node.js、Python、Visual Studio 或第三方 PowerShell 模块。

普通用户无需执行 PowerShell 命令，该命令仅用于高级用户排障：

~~~powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File ".\gui\QiehaoGui.ps1"
~~~

这里的 ExecutionPolicy Bypass（绕过执行策略）只应用于本次启动的 PowerShell 进程，不会永久修改系统 PowerShell 执行策略，不写注册表，也不要求管理员权限。

## 使用方法

首次添加账号：

1. 在 Codex 中通过官方流程登录要保存的账号。
2. 确认登录成功后完全退出 Codex 客户端。
3. 打开 Qiehao，点击“添加账号”。
4. Qiehao 自动识别当前文件型登录凭据，完成安全验证后保存。

添加第二个或后续账号：

1. 在 Codex 中登录或切换到新的目标账号。
2. 确认登录成功后完全退出 Codex 客户端。
3. 返回 Qiehao，点击“添加账号”。
4. Qiehao 自动识别并保存这个新账号；不会把新账号凭据回存到先前的 Active Profile（当前活动档案）。

这里的“退出 Codex”是关闭 Codex 客户端，包括可能仍在运行的系统托盘进程，不是注销当前登录账号。每个账号只需要成功添加一次；以后在已保存账号之间切换时，直接在 Qiehao 选择目标档案并点击“切换账号”，不需要重复 OAuth 登录。切换前仍应按界面提示完全退出 Codex，切换完成后再由用户手动重新启动 Codex。

不要把关闭主窗口等同于完全退出；Codex 仍可能驻留在系统托盘。Qiehao 不会把任务管理器强杀当作正常流程。

## 更新

普通用户推荐使用 GitHub Releases 提供的新版 Release ZIP 更新：

1. 完全退出 Qiehao。
2. 下载新版 Release ZIP。
3. 将新版 ZIP 的内容完整解压到现有 Qiehao 目录；如系统询问，只覆盖同名程序文件，不要删除整个原目录。
4. 使用更新后的 `Start-Qiehao.cmd` 启动。

不要直接在 ZIP 压缩包内运行，也不要为了更新而删除包含本机运行数据的旧目录。`profiles/`、`state/`、`logs/` 和 `backup/` 可能包含当前 Windows 用户在本机产生的私有运行数据；确认新版正常工作并妥善处理这些数据前，不要删除旧目录。

通过 Git 管理源码的高级用户应先检查：

~~~powershell
git status --short
~~~

确认没有本地源码修改后，再执行：

~~~powershell
git pull --ff-only
~~~

`--ff-only` 只允许 Fast-forward（快进）更新；如果本地历史已经分叉，Git 会安全停止，而不是自动产生 merge commit（合并提交）。如果 `git status --short` 显示源码文件有本地修改，应先自行审查并妥善处理，不要强制覆盖。

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
- Qiehao 账号配置使用 Windows DPAPI CurrentUser（数据保护 API，当前用户作用域）保护，并绑定当前 Windows 用户和本机保护环境。
- 不要直接把 `profiles/` 目录复制到另一台电脑使用；即使另一台电脑使用相同的 Windows 用户名，也不能假定这些文件能够解密。
- Browser/PWA untouched（浏览器/PWA 不受影响）。
- 本项目未加入 telemetry（遥测）或 analytics（分析统计）。
- 本项目不运营中转服务器。
- 不对非活动账号发起额度查询。
- profiles/、state/、logs/、backup/、auth.json、DPAPI 容器和额度缓存均不得提交到 Git。

用户应妥善保护自己的 Windows 账号、Codex 登录和本机环境。不要把 `profiles/`、`state/`、`logs/`、`backup/` 或 `auth.json` 上传到 GitHub、网盘、聊天工具或公开 Issue（问题），也不要粘贴 Token（令牌）、邮箱、账号 ID、Cookie 或含凭据的日志。

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
- MultiAccountStressSelfTest.ps1（10+1 个纯假账号的添加、切换、重复、回滚与损坏隔离）
- GuiSelfTest.ps1
- VisualPolishSelfTest.ps1
- AccountGridLayoutSelfTest.ps1
- LocalizationSelfTest.ps1
- Quota 与 Switch-before-Quota（切换前额度快照）系列测试
- LauncherSelfTest.ps1

所有自动测试使用 fake-only（仅假数据）或 hidden/offscreen WPF（隐藏/离屏 WPF）；开发和 CI（持续集成）不得读取真实认证档案或发送真实额度请求。贡献前请阅读 [CONTRIBUTING.md](CONTRIBUTING.md)，安全问题处理方式见 [SECURITY.md](SECURITY.md)。

## 风险与许可证

Qiehao 操作本机 Codex 认证状态，使用前应确认源码来源并保留可恢复环境。官方 Codex 的本地文件格式或行为未来可能变化；遇到未知结构时，工具应安全拒绝而不是猜测。

开源许可证尚待项目维护者选择。在 LICENSE 文件正式加入前，不应把“代码可见”误解为已经获得复制、修改或再分发授权。
