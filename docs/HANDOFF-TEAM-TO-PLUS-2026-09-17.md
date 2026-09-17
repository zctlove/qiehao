# qiehaoqu 项目正式交接：Team → Plus

交接日期：2026-09-17

项目目录：`E:\codex\qiehaoqu`

当前开发分支：`feature/gui-v1`

最新 UI 阶段提交：`db22d67b`（`gui-glass-launch-identity`）

> 本文件用于下一账号、下一 Codex 会话的正式接管。本文只记录架构、已验证事实、安全边界和后续建议，不包含任何真实认证值或秘密。如果本文与当前 Git 仓库的实际代码或测试发生冲突，以当前 Git 仓库实际代码和测试为准。

## 1. 项目目标

本项目是面向 Windows 的本地 Codex Desktop 账号槽位管理工具，目标是在不接管网页登录、不自动执行官方登录流程、不影响 Web/PWA 会话的前提下，安全保存多个本地账号槽位，并在 Codex Desktop 完全退出后进行可验证、可回滚的本地账号切换。

项目优先级按以下顺序执行：

1. 防止真实认证资料泄露或进入 Git；
2. 防止 Codex 仍运行时读写认证文件；
3. 防止身份漂移导致把一个账号的最新认证覆盖进另一个槽位；
4. 防止切换中断后留下半完成状态；
5. 在安全边界内提供中文、易操作、可测试的 GUI；
6. 所有未知状态一律 fail closed（无法确认即停止），不猜测、不强行继续。

## 2. 当前整体架构

项目由五层组成：

- `qiehao.ps1`：命令行入口，负责参数路由和调用后端公开函数。
- `lib\CodexAuth.psm1`：安全核心。负责 Codex Home 定位、认证文件结构验证、进程闸、DPAPI 加解密、profile 三文件管理、identity marker、Switch 事务、回滚、Add/Rename/Delete/Verify 和只读当前身份确认。
- `gui\GuiHelpers.psm1`：GUI 的纯逻辑与依赖注入层。负责安全结果码到中文消息的映射、按钮状态、快照转换、启动目标验证、主题目录、搜索与操作编排，便于 fake 测试。
- `gui\QiehaoGui.ps1` 与 `gui\MainWindow.xaml`：WPF 界面与事件编排层。负责控件绑定、对话框、定时器、启动/正常退出请求、主题切换和调用安全后端。
- `tests\SelfTest.ps1` 与 `tests\GuiSelfTest.ps1`：全部使用临时目录、fake CODEX_HOME、假进程数据和 dependency injection（依赖注入）完成自动测试，不操作真实账号。

背景资源位于 `gui\assets\backgrounds\`。运行期的 `profiles\`、`state\`、`logs\`、`backup\` 不属于源代码，必须继续由 `.gitignore` 隔离。

## 3. 当前分支和最新 HEAD

本交接文件创建前的只读核验结果：

- 工作目录：`E:\codex\qiehaoqu`
- 分支：`feature/gui-v1`
- HEAD：`db22d67bee84e34bcccb62370a585c40e8ffe819`
- 短 HEAD：`db22d67b`
- 提交信息：`gui-glass-launch-identity`
- working tree：clean

最近 5 个代码阶段提交：

```text
db22d67 gui-glass-launch-identity
01b5bc7 gui-account-management
e7a5382 gui-verify-safe-exit
e239238 gui-chinese-themes
eaf06e9 gui-readonly-shell
```

## 4. 已完成的重要功能

- 严格定位 Codex Home，但不修改 `CODEX_HOME` 环境变量。
- 严格验证文件型认证文件的已知外层结构，未知结构拒绝继续。
- Windows DPAPI CurrentUser 保护的多 profile 本地槽位。
- 每个完整 profile 使用加密认证文件、加密 identity marker、非秘密 metadata 三件套。
- active profile 使用非秘密状态文件记录，并且最后提交。
- Codex/ChatGPT 相关进程安全识别与 fail-closed 进程闸。
- Chrome/Edge extension-host 来源链分类，避免误伤浏览器扩展宿主。
- Switch 完整事务、读回验证、失败回滚及严重回滚失败提示。
- Add、Rename、Delete、Verify 后端与 GUI 流程。
- 中文 WPF GUI、五套主题、搜索、整行双击、右键菜单、F2、Busy 门禁和单实例门禁。
- 启动 Codex、正常退出 Codex、10 秒有界等待和 2 秒只读进程检测。
- “当前身份确认”与“槽位验证”分离。
- Windows PowerShell 5.1 和 PowerShell 7 双兼容测试。

## 5. 账号切换安全核心

所有会修改 profile、active 状态或当前认证文件的操作必须经过以下安全边界：

1. 使用项目专用 named mutex 串行化写操作；
2. 首先检查 Codex Desktop 是否完全退出；
3. 进程运行或状态无法可靠判断时，在读取真实认证文件之前停止；
4. active profile、当前认证身份和 active profile 的 marker 必须一致；
5. 目标 profile 必须完整、可解密、结构有效并且身份 marker 一致；
6. 所有磁盘写入使用同目录临时文件、flush、关闭后再执行原子移动或替换；
7. 切换后的当前认证文件必须重新读取并逐字节验证；
8. active 状态只能在全部关键步骤成功后最后提交；
9. 错误信息只允许输出安全结果码和本地显示名称，不输出认证正文或身份值。

## 6. identity marker / identity drift 机制

identity marker 是每个 profile 独立保存的 DPAPI CurrentUser 加密二进制标记。它表示稳定的本地账号/工作区身份，不依赖会随刷新变化的认证字节，也不绑定 profile 显示名称。

identity drift（身份漂移）保护用于防止以下事故：工具记录 active profile 为 A，但当前 Codex 认证实际上已经变成 B。如果此时直接“回存当前认证”，就可能把 B 覆盖进 A 槽位。

当前实现会先在内存中比较当前认证身份与 active profile marker：

- 一致：允许后续安全保存或切换；
- 不一致：返回 `ACTIVE_PROFILE_IDENTITY_MISMATCH`，不覆盖 active 槽位；
- marker 缺失、损坏、版本未知或无法可靠解析：停止，不猜测；
- Codex 正在运行或进程状态未知：在读取当前认证文件之前停止。

Rename 只移动 marker，不修改 marker 的内部身份，因此正常重命名不会改变身份关联。

## 7. DPAPI profile 机制

每个完整 profile 由三类文件组成：

- `<Name>.auth.dpapi`：由 Windows DPAPI CurrentUser 保护的认证容器；
- `<Name>.identity.dpapi`：由 Windows DPAPI CurrentUser 保护的身份 marker；
- `<Name>.meta.json`：仅包含允许公开的本地元信息，不保存秘密。

DPAPI CurrentUser 意味着加密文件绑定当前 Windows 用户的密钥材料，不应复制到其他 Windows 用户或其他机器后期待直接可用。应用 entropy 只是应用隔离标签，不是独立密码。

敏感字节只在内存中短暂存在，关键路径在 `finally` 中尽最大合理努力清理字节数组。任何解密、结构验证或读回验证失败都必须停止后续写入。

## 8. Switch transaction / rollback

Switch 的关键事务顺序如下：

1. 取得写操作 mutex；
2. 确认 Codex Desktop 已完全退出；
3. 读取并严格验证 active 状态；
4. 目标与 active 相同时返回 `ALREADY_ACTIVE`；
5. 验证当前认证身份与 active marker 一致；
6. 将当前最新认证安全回存 active profile；
7. 解密并验证目标 profile 与目标 marker；
8. 在当前认证文件所在目录创建随机临时文件并完整写入；
9. 原子替换当前认证文件，不创建明文备份；
10. 重新读取并逐字节验证替换结果；
11. 最后原子更新 active profile 状态。

如果替换后的验证或最终 active 状态提交失败，后端会从刚更新的原 active profile 恢复当前认证文件并再次验证：

- 恢复成功：返回 `SWITCH_FAILED_ROLLED_BACK`，active 状态保持原账号；
- 恢复失败：返回 `SWITCH_ROLLBACK_FAILED` 和人工恢复警告，禁止继续启动 Codex，必须先人工审查。

不得简化或重新排序上述事务步骤。

## 9. GUI 当前已经实现的全部功能

- 顶部展示 Codex 客户端状态、当前账号、当前身份确认和 Web ChatGPT 隔离提示。
- 动态 profile 列表、健康状态、槽位验证状态和 active 行标识。
- 按本地 profile 名称进行不区分大小写的 substring 搜索。
- Switch 按钮、整行双击、右键“切换到此账号”共用安全切换逻辑。
- Verify 按钮与右键验证。
- Add、Rename、Delete 按钮与对应对话框。
- F2 重命名。
- 右键前自动选择目标行；点击空白处不会误操作。
- 当前 active profile 禁止 Switch 和 Delete，但允许 Rename。
- Busy 状态防止按钮、双击、右键和快捷键重复触发。
- 单实例 GUI mutex，防止同一用户同时打开多个管理器实例。
- 手动刷新、当前身份确认和安全中文错误映射。
- 启动 Codex、启动设置、正常退出 Codex。
- 2 秒只读进程检测和启动/退出按钮自动同步。
- 五套玻璃主题、背景即时切换与偏好恢复。

## 10. 启动 Codex / 正常退出 Codex

“启动 Codex”只在以下条件同时满足时可用：

- 进程闸确认 Codex 已退出；
- 启动目标有效；
- 当前没有写操作或退出等待进行中。

自动检测优先读取 AppX manifest，其次读取 Windows Start Apps。特殊安装可选择现有本地 `.exe`；自定义路径必须是绝对路径、文件必须存在、扩展名必须为 `.exe`，并拒绝 reparse point。启动不附加账号参数，不提权，不修改环境变量或 Codex Desktop 配置。发出请求后最多等待 10 秒检测进程出现。

“正常退出 Codex”只在进程闸确认 Codex 正在运行时可用。点击时再次即时复核，只向验证过的 Codex 主窗口发送正常关闭请求。最多等待 10 秒；仍有进程时提示用户从系统托盘正常退出。代码中没有强制终止路径。

## 11. 当前身份确认 / 槽位验证的区别

“当前身份确认”针对正在作为 active 使用的账号：

- Codex 已退出时，比较当前认证身份与 active profile marker；
- Codex 运行中显示“待退出后确认”，不读取当前认证文件；
- 状态可能为“已确认 / 不匹配 / 尚未初始化 / 无法确认”。

“槽位验证”针对列表中的某一个已保存 profile：

- 由用户显式执行 Verify；
- 要求 Codex 已完全退出；
- 检查加密认证、identity marker、metadata 和它们之间的一致性；
- 只显示允许的验证结果，不显示认证或身份正文。

两者不可合并成同一个概念，也不能因为 active 身份已确认就自动把所有槽位标记为已验证。

## 12. 2 秒只读进程检测

GUI 使用 WPF `DispatcherTimer` 每 2 秒调用一次只读进程状态检测，只更新：

- Codex 客户端状态；
- “启动 Codex”按钮；
- “正常退出 Codex”按钮；
- 与 Busy/退出等待相关的按钮可用性。

该计时器不得读取当前认证文件、不得解密 profile、不得读取 identity marker、不得重新加载 profile 列表，也不得更新 active 状态。完整资料刷新只由用户点击“刷新”，或在明确的启动/正常退出完成后触发。

## 13. 5 套玻璃主题和 Active 行高亮

当前主题为：

1. 科技蓝；
2. 深蓝鎏金；
3. 冰蓝玻璃；
4. 紫蓝星河；
5. 清透流光。

每套主题都有独立的背景遮罩、玻璃卡片渐变、边框、主/次文字、按钮渐变、悬停、按下、危险按钮、普通选中行、active 行和 active+selected 行颜色。

active profile 使用绿色系整行高亮、较粗左侧强调边和加粗文字；普通选中行使用不同颜色；active 行被选中时使用第三种状态，避免把“当前账号”和“鼠标选中账号”混淆。

## 14. Add / Rename / Delete 当前实现情况

Add：

- 如果已有 active profile，先验证当前身份并安全保存 active 最新认证；
- 用户必须自己通过官方 Codex 登录流程登录新账号；
- 工具不自动操作 OAuth 或网页登录；
- Codex 完全退出后才采集新 profile；
- 拒绝重复名称和重复身份；
- 只有 profile 三件套验证成功后才提交 active 状态。

Rename：

- 要求旧 profile 完整、新名称未占用；
- 事务性移动三件套并更新非秘密 metadata；
- active profile 被重命名时，最后同步 active 状态；
- 中途失败按反序回滚，回滚失败返回高优先级错误。

Delete：

- 必须显式确认；
- 只删除项目 profile 根目录下允许的三类文件；
- 禁止删除当前 active profile；
- 部分失败只报告文件类型，不输出内容；
- 不影响 OpenAI 云端账号或 Web/PWA 会话。

## 15. 已完成的真实人工验收

已真实人工验证：

- **Team → Plus 的 GUI Switch 成功，无报错。**

该事实是目前最重要的真实验收基线。不要因为后续自动测试覆盖充分，就把未真实执行过的操作描述为已人工验收。

## 16. 尚未进行的真实验收

以下项目没有拿真实 Plus / Team 做破坏性测试：

- Add；
- Rename；
- Delete。

它们只通过 fake CODEX_HOME 自动测试。除非用户再次明确授权，并且准备了可丢弃的测试槽位与可恢复方案，否则不要在真实 Plus / Team 上补做破坏性验收。

最新 UI 阶段的“启动 Codex / 正常退出 Codex / 当前身份确认 / 2 秒进程检测 / 五套玻璃主题”已经完成自动测试和只读检测，但本阶段没有自动点击真实启动或真实退出，也没有为了视觉确认而自动运行 GUI。

## 17. 当前测试体系

`tests\SelfTest.ps1` 是后端 SelfTest，覆盖：

- 认证外层结构验证与未知结构拒绝；
- DPAPI round trip；
- 原子 profile 写入、默认禁止覆盖；
- 进程闸、未知进程状态和浏览器 extension-host 隔离；
- A → B fake Switch、active 最新认证回存；
- identity drift、marker 缺失、旧槽位 marker 初始化；
- 当前身份只读确认、身份不匹配和进程闸先于认证读取；
- Switch 失败回滚与回滚后 active 状态；
- Add、重复名称、重复身份；
- Rename、active Rename、Rename 回滚；
- Delete、确认门禁、禁止删除 active、部分失败报告；
- Verify、并发 mutex 和用户作用域锁。

`tests\GuiSelfTest.ps1` 是 GUI SelfTest，覆盖：

- PowerShell 5.1/7 XAML 解析和 GUI `-SelfTest` 启动；
- 中文编码、五套主题、玻璃资源和 active 行状态；
- 动态 profile 数量、健康状态、搜索；
- Switch/Verify/Add/Rename/Delete 的 dependency injection；
- 双击、右键、F2、空白区防误触和 Busy 门禁；
- 正常退出、10 秒超时、不强杀和浏览器隔离；
- 启动目标 AppX/Start Apps 检测、自定义 EXE 校验和启动提供器契约；
- 当前身份刷新语义；
- 2 秒进程检测不读取认证/profile/identity；
- 单实例 GUI mutex。

截至 `db22d67b` 的最近一次完整测试记录中，两套 SelfTest 均在 Windows PowerShell 5.1 和 PowerShell 7 通过，并明确报告未读取真实认证/profile。本次文档交接没有重新运行完整测试套件。

## 18. Windows PowerShell 5.1 / PowerShell 7 兼容要求

- 所有核心脚本必须同时通过 Windows PowerShell 5.1 和 PowerShell 7 解析及测试。
- WPF GUI 应继续使用 `-STA` 启动。
- 含中文的 `.ps1`/`.psm1` 应保留对 Windows PowerShell 5.1 可靠的 UTF-8 编码策略，修改后必须重新检查乱码与替换字符。
- 不得为了使用新语法而无意中放弃 PowerShell 5.1。
- 主题资源动态替换时要保留当前对 WPF 原始 Brush 对象的兼容处理，避免 PowerShell 包装对象被错误转换成字符串。
- 下一次业务代码改动后，必须分别运行两种 PowerShell 的 Backend SelfTest 和 GUI SelfTest。

## 19. Web/PWA 隔离要求

本工具只管理 Codex Desktop 的本地文件型认证槽位。不得读取、修改、退出或清理：

- ChatGPT Web 登录状态；
- PWA 登录状态；
- Chrome/Edge 浏览器 profile；
- 浏览器会话存储；
- WebView 登录态；
- 任何网页账号选择状态。

GUI 中“网页 ChatGPT：不受影响”是安全承诺，不只是提示文案。未来功能不得破坏该隔离。

## 20. Chrome/Edge extension-host 隔离要求

Codex 插件或浏览器插件可能存在名称相同的 `extension-host`。不能只凭进程名判断是否属于 Codex。

当前进程分类会结合：

- 可执行文件路径；
- 父进程链；
- 浏览器来源；
- Codex 安装/插件路径；
- 路径或父进程信息是否可读取。

确认来自 Chrome/Edge 的 extension-host 不应阻止安全操作；确认属于 Codex 的 extension-host 必须阻止；无法可靠判断时返回 `CODEX_PROCESS_STATE_UNKNOWN` 并停止。不得退化为“看到 extension-host 就全部阻止”或“全部放行”。

## 21. 绝对禁止事项

- 禁止自动操作真实 Plus / Team 登录、切换、Add、Rename 或 Delete，除非用户在当轮明确授权。
- 禁止在 Codex 运行或状态未知时读写当前认证文件。
- 禁止强制终止 Codex；不得加入 `Stop-Process`、`taskkill`、`.Kill()` 或等价实现。
- 禁止自动操作 OAuth、浏览器、Web/PWA 会话或账号选择。
- 禁止输出、记录、提交或展示任何认证正文、身份值或秘密。
- 禁止修改 Codex Desktop 自身的 `config.toml`、approval、sandbox、permissions、plugins 或环境变量。
- 禁止为方便测试而指向真实 CODEX_HOME；自动测试必须使用 fake CODEX_HOME 和 dependency injection。
- 禁止跳过进程闸、identity drift 检查、目标验证、读回验证或 rollback。
- 禁止使用 `git reset`、`git clean`、`git restore`、覆盖式 `git checkout` 或删除未提交成果。
- 禁止擅自 merge master、访问 remote 或 push。
- 禁止把未知错误原文直接显示到 GUI；必须映射为安全结果码和中文说明。

## 22. profiles/state/logs/backup/auth 等敏感文件规则

以下目录或文件不得作为普通源代码读取、展示或加入 Git：

- `profiles\`
- `state\`
- `logs\`
- `backup\`
- `auth.json`
- `*.auth.dpapi`
- `*.identity.dpapi`
- 临时文件和备份文件

规则：

1. 不打开、打印或复制真实 `auth.json` 内容；
2. 不解密真实 profile 或 identity marker；
3. 不把真实文件名、身份值或认证摘要写进文档、日志、错误信息或测试快照；
4. 保持 `.gitignore` 对上述目录和文件的覆盖；
5. 暂存前必须检查 staged 路径，提交前必须检查 Git 已跟踪路径；
6. 测试所需认证资料只能由测试脚本在受控临时目录中生成，并在 `finally` 中删除；
7. 即使是加密文件也不得提交，因为它仍是敏感认证容器。

## 23. Git 当前状态

创建本交接文件之前：

- branch：`feature/gui-v1`
- HEAD：`db22d67b`
- working tree：clean
- 敏感文件 tracked：0
- 没有 merge；
- 没有 push；
- 没有 remote 操作。

本交接文件应单独暂存并以 `docs-team-to-plus-handoff` 创建本地提交。该文档提交不得混入业务代码或运行期文件。

## 24. 下一阶段建议

建议按低风险顺序推进：

1. 新会话先执行第 25 节的只读检查，不要立即编辑。
2. 确认文档提交之后工作树干净，并确认最新代码提交 `db22d67b` 仍在历史中。
3. 如需继续 GUI 验收，先做无破坏性的视觉与按钮状态人工检查，不进行真实账号写操作。
4. 人工检查 Codex 运行中时“启动 Codex”禁用、“正常退出 Codex”启用；Codex 完全退出后状态反转。
5. 人工检查运行中点击“刷新”只显示“待退出后确认”，不会尝试身份读取。
6. 如要真实验收启动/退出，应先说明它会影响当前 Codex 会话，并由用户明确选择安全时机；禁止在正在进行重要任务的 Codex 会话中自动执行。
7. Add/Rename/Delete 的真实验收只能使用专门准备、可丢弃、可恢复的测试槽位，不使用真实 Plus / Team。
8. 任何业务代码变更后，先跑静态解析和 XAML 解析，再跑 PowerShell 5.1/7 两套完整 fake 测试，最后做 Git 敏感文件审计。
9. 保持修改小而可审查；每个阶段单独本地提交，不 merge、不 push，直到用户明确要求。

## 25. 下一任 Codex 接管时的第一步检查流程

先只读执行：

```powershell
Set-Location -LiteralPath 'E:\codex\qiehaoqu'
(Get-Location).Path
git branch --show-current
git rev-parse --short=8 HEAD
git status --short
git log -5 --oneline
```

预期：

- 目录为 `E:\codex\qiehaoqu`；
- 分支为 `feature/gui-v1`；
- 历史中包含 `db22d67b gui-glass-launch-identity`；
- 文档交接提交信息为 `docs-team-to-plus-handoff`；
- working tree 应干净。

如果存在未提交修改：

1. 只读检查文件名和 diff；
2. 判断是否属于同一任务；
3. 不 reset、不 restore、不 clean、不覆盖；
4. 如果是异常修改，立即停止并报告；
5. 在确认来源之前不运行真实 GUI、不进行账号操作。

确认 Git 正常后，再按任务范围读取必要代码。不要为了“熟悉项目”遍历敏感目录，也不要运行真实账号操作。只有业务代码发生变化时才需要重新运行完整测试；纯文档接管可只做 `git diff --check` 和 staged 敏感路径审计。

## 26. 冲突处理原则

如果代码与交接文档冲突，以当前 Git 仓库实际代码和测试为准。

接管者应先确认冲突来自文档过期、代码尚未提交还是工作树异常，再决定后续动作。不得仅依据本文件覆盖代码、删除本地成果或降低安全门禁。任何需要改变既有安全边界的方案，都必须先给出风险分析并取得用户明确授权。
