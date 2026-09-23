# Qiehao

[简体中文](README.md) | [English](README.en-US.md)

Qiehao 是一个面向 Windows Codex Desktop 的本地账号切换工具，提供中文/英文 WPF 图形界面，并以“用户手动触发、Codex 完全退出后再切换”为核心安全边界。

> [!IMPORTANT]
> Qiehao 是非官方社区工具，不是 OpenAI 官方产品。它只管理 Codex Desktop 的本地认证状态，不修改 ChatGPT Web、浏览器或 PWA（渐进式网页应用）的登录状态。

## 产品预览 / Product Preview

![Qiehao 浅海冰晶主题产品预览](docs/screenshots/qiehao-preview-arctic-sea-glass.jpg)

这是 Qiehao 当前界面风格之一的实际运行效果，展示了本地账号管理、当前账号状态、额度快照，以及中英文、多主题界面能力。

## 先说最重要的：Qiehao 不反代

Qiehao **不是反代工具，也不准备往反代方向做。**

不反代，不轮询，不做额度池。

它不代理 Codex 或 API 流量，不帮你转发请求，不做账号池，不做自动轮换，不根据额度自动换号，也不会碰到 HTTP 429 就自己切另一个账号。

如果你找的是反代、自动养号、后台账号池、无人值守自动切号这一类东西，那这个项目不用继续往下看了。

我做它就是想把“我自己正常登录、自己正常使用的几个账号，切起来别那么折腾”这件事情做好。

## 我为什么会做 Qiehao

我做 Qiehao 的原因其实特别简单：

**我真的受够了切账号时那个 OAuth 登录页面一直转圈圈。**

本来只是想换一个自己正常使用的账号，结果经常要退出、重新登录、等 OAuth 页面、再等 Codex 认账号。网络或者登录状态稍微不顺一点，就在那里一直转。有时候转半天都登不上，如果几个自己正常使用的账号来回切，真的挺头疼。

所以我最开始想做的，并不是什么“绕过登录”的东西。恰恰相反，我做的是：

**能不能第一次老老实实走官方登录，以后在本机把已经正常登录过的账号安全保存下来，需要的时候再规规矩矩切回来？**

所以 Qiehao 的基本原则一直没变：

- 新账号第一次仍然走 Codex 官方 OAuth；
- 不模拟登录；
- 不抓浏览器 Cookie；
- 不接管 ChatGPT Web/PWA；
- 不反代；
- 不做自动账号池；
- 不在后台轮询多个账号；
- 每次切号都由人自己点；
- Codex 没真正退出，就不动认证文件。

说白了：

**它不是帮我养一池账号，而是让我切自己正常用的账号时，减少输密码与等待。**

## 我对使用方式的想法

我个人的想法也很简单：

**能规规矩矩用，就规规矩矩用，求的是长期稳定。**

所以这个工具没有做多账号后台轮询，没有做额度触发自动切号，没有做 429 自动换号，也没有做无人值守账号池。

能走官方登录就走官方登录，能走 Codex 自己提供的接口就用它自己的接口。能少做一次没必要的请求，就少做一次。能不自动化的地方，我宁愿让人自己点一下。

我当然也希望这种比较老实的用法，能够少碰一点莫名其妙的风控，少一点大家平时说的“降智”，也尽量降低账号被限制甚至封号的概率。

但这句话只是我自己的使用思路和期望，不是平台给出的承诺，Qiehao 也不可能保证：

- 一定不会风控；
- 一定不会降智；
- 一定不会限制；
- 一定不会封号。

平台规则、风控和模型行为都不是 Qiehao 能控制的。

Qiehao 能做的，只是尽量不要自己主动增加那些没必要的高频轮询、自动切号、异常请求和过度自动化行为。

**不想着钻空子，规规矩矩用，这就是我做这个工具时给自己定的方向。**

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

DPAPI CurrentUser 主要保护认证快照的静态存储，避免明文落盘。它不能防御已经能够以同一个 Windows 用户身份运行的恶意程序，也不意味着认证数据绝对安全、永远无法解密或永远不会被窃取。

## Quota Snapshot（额度快照）

额度快照通过 Codex app-server 接口读取当前 Active Profile 的额度信息：

- 只主动查询当前 Active Profile；
- inactive profile（非活动档案）只显示最后一次成功缓存；
- 不持续轮询，不构成实时额度监控；
- 查询失败时保留旧快照，不清零、不伪造更新时间；
- 快照只代表最后一次成功查询结果，不保证实时性；
- 额度失败不会自动触发账号切换。

### 关于额度查询速度

先说一下这个功能最容易让人觉得“不爽”的地方：

**额度查询有时候确实会慢。**

Qiehao 没有自己去抓网页，也没有自己搞一套私有额度接口。它用的是 Codex 自己的 app-server 接口，去读取当前活动账号的额度快照。

所以额度查询属于 best effort（尽力而为）：

**能查到就查，查不到就保留上一次结果，不保证每次一点刷新就马上秒回。**

有些时候 Codex app-server 启动会慢一点，有些时候返回额度会慢一点，也可能直接超时。这部分体验确实没有“点一下立刻出结果”那么爽，我知道。

但是我不想为了把界面做得看起来更快，就改成：

- 抓网页登录页面；
- 偷读浏览器 Cookie；
- 后台不停轮询；
- 同时去探测多个账号；
- 接第三方私有额度接口；
- 因为额度没回来就自动换号。

所以这里我宁愿接受它偶尔慢一点。

查询失败的时候，Qiehao 会尽量保留上一次成功的额度快照，让你之后自己再点一次刷新。

这也是为什么这个功能叫 **Quota Snapshot（额度快照）**，而不是 **实时额度监控**。

还有一个很重要的区别：

**额度刷新慢或者失败，不代表账号切换失败。**

账号切换和额度查询是两个不同的流程。我的取舍很简单：

**切号优先保证安全和正确；额度查询允许慢一点，也允许偶尔失败。**

额度查询属于辅助功能，不影响账号添加、切换和删除。

如果额度获取失败，可点击“刷新额度”重新获取。

## 系统要求

- Windows 10/11
- Windows PowerShell 5.1（普通用户运行所需，Windows 自带）
- Codex Desktop

PowerShell 7 只用于兼容性测试和开发测试，普通用户不需要为了运行 Qiehao 额外安装它。当前版本仅支持 Windows，不支持 macOS。

## 下载

当前推荐版本：

**Qiehao v1.0.3**

新用户请优先下载最新版本。

历史版本会保留用于版本追溯和问题排查，不建议新用户使用旧版本。

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

> ⚠ **空间账号首次添加：**
>
> 请在 Qiehao 开启状态下，完成一次该账号登录流程，否则可能被识别为个人账户。
>
> Codex 当前身份信息需要通过完整登录流程采集。
>
> 如果提前在客户端外登录空间账号，再让 Qiehao 读取，部分情况下可能无法正确区分 Team workspace（团队工作区）和 Personal（个人）身份。

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

## 常见问题

### 如果提示 Codex 正在运行怎么办？

如果 Codex 客户端刚刚关闭，Windows 可能仍需要少量时间释放后台进程。

此时 Qiehao 可能提示“Codex 正在运行”。

请稍作等待后再次尝试切换或删除操作。

为避免 Windows 进程状态刷新延迟影响判断，请避免在短时间内连续快速切换多个账号。

建议等待当前切换完成、客户端状态稳定后，再进行下一次切换。

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
- `profiles/`、`state/`、`logs/`、`backup/`、`auth.json`、DPAPI 容器和额度缓存均不得提交到 Git。

用户应妥善保护自己的 Windows 账号、Codex 登录和本机环境。不要把 `profiles/`、`state/`、`logs/`、`backup/` 或 `auth.json` 上传到 GitHub、网盘、聊天工具或公开 Issue（议题），也不要粘贴 Token（令牌）、邮箱、账号 ID、Cookie 或含凭据的日志。

## 命令行入口

`qiehao.ps1` 提供安全后端命令，例如：

~~~powershell
.\qiehao.ps1 status
.\qiehao.ps1 list
.\qiehao.ps1 active
.\qiehao.ps1 verify-profile ExampleProfile
~~~

涉及保存、添加、重命名、删除和切换的命令具有额外的进程门禁、身份验证和确认要求。普通用户建议通过 GUI（图形界面）完成流程。

## Development（开发）

项目同时在 Windows PowerShell 5.1 与 PowerShell 7 下验证。核心自测试位于 `tests/`，包括：

- `SelfTest.ps1`
- `MultiAccountStressSelfTest.ps1`（10+1 个纯假账号的添加、切换、重复、回滚与损坏隔离）
- `GuiSelfTest.ps1`
- `LongTermSafetyAuditSelfTest.ps1`
- `ProfileDeleteTransactionSelfTest.ps1`
- `CleanInstallSelfTest.ps1`
- `VisualPolishSelfTest.ps1`
- `AccountGridLayoutSelfTest.ps1`
- `LocalizationSelfTest.ps1`
- Quota 与 Switch-before-Quota（切换前额度快照）系列测试
- `LauncherSelfTest.ps1`

所有自动测试使用 fake-only（仅假数据）或 hidden/offscreen WPF（隐藏/离屏 WPF）；开发和 CI（持续集成）不得读取真实认证档案或发送真实额度请求。贡献前请阅读 [CONTRIBUTING.md](CONTRIBUTING.md)，安全问题处理方式见 [SECURITY.md](SECURITY.md)。

## 发布状态与版本历史

当前推荐下载版本是 **Qiehao v1.0.3（Latest，最新版本）**。

- v1.0.3 — Latest（最新版本）
- v1.0.2
- v1.0.1
- v1.0.0

v1.0.0、v1.0.1 和 v1.0.2 会继续保留，用于版本追溯和问题排查；不建议新用户使用旧版本。

当前暂不提供 Windows EXE 或安装器。第一版先保持 PowerShell 源码和启动器透明、简单，也方便别人直接看源码和反馈问题。后续会根据真实用户反馈，再评估 EXE / Installer（安装器）。

## Community（社区）

本项目认可并链接 [LINUX DO](https://linux.do/) 社区，欢迎社区佬友交流、测试、提建议和反馈问题。

Qiehao 也会在其他技术社区中分享和交流，感谢所有愿意实际使用、测试和反馈的人。

## 风险与许可证

Qiehao 操作本机 Codex 认证状态，使用前应确认源码来源并保留可恢复环境。官方 Codex 的本地文件格式或行为未来可能变化；遇到未知结构时，工具应安全拒绝而不是猜测。

本项目采用 [MIT License（MIT 许可证）](LICENSE)，Copyright (c) 2026 ZCT。完整条款以仓库根目录 `LICENSE` 为准。
