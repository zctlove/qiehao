# qiehaoqu：Windows 本地 Codex 账号槽位工具

这是一个以安全为首要目标的 Windows PowerShell 本地账号管理工具。当前版本包含安全后端和中文 WPF GUI，负责检查 Codex Home、验证文件型 `auth.json` 的已知结构、使用 Windows DPAPI 保存任意合理数量的本地账号槽位、识别重复身份、记录非秘密 active profile、提供 profile CRUD/健康检查，并在 Codex Desktop 完全退出后执行可回滚的本地账号切换。

## 安全边界

- `profiles` 中保存的是 DPAPI `CurrentUser` 加密后的 `*.auth.dpapi`，不是明文 `auth.json`；每个可切换槽位还必须有一个独立的 `*.identity.dpapi` 身份 marker。
- 不把 token、API key、cookie、OAuth credential、账号 ID、邮箱或认证 JSON 写入日志和 metadata。
- 不打印、截断或打码展示任何认证值。
- 不修改 `CODEX_HOME`、User/Machine 环境变量或注册表。
- 不自动登录、登出、强制终止或后台重启 Codex/ChatGPT；GUI 只在用户明确点击后启动 Codex，或向已验证的 Codex 主窗口发送正常关闭请求。启动/退出都只等待 10 秒确认进程状态，超时即停止，不强杀。
- `save` 只按明确的 Codex 进程名或已确认属于 Codex 的可执行路径拦截，无关 `node`/`pwsh`/`ChatGPT` 不会被名称误伤；关键路径不可读时返回 `CODEX_PROCESS_STATE_UNKNOWN`，且始终在读取真实 `auth.json` **之前**停止，不会自动关闭进程。
- 同名槽位默认拒绝覆盖；只有显式 `-Force` 才允许原子替换目标文件。
- `switch` 只在进程闸返回 `CODEX_PROCESSES_STOPPED` 后运行；它先确认当前 `auth.json` 的稳定身份与 active profile marker 一致，再回存当前最新认证、验证目标、原子替换、读回逐字节验证，最后才更新 active profile。
- Plus、Team、Work、Test 等都只是普通本地显示名称；没有硬编码特殊账号，也没有人为槽位数量上限。
- 所有修改操作由项目专用 named mutex 串行保护；锁已被其他实例持有时立即返回 `OPERATION_BUSY`，不等待形成死锁。
- Web Session Isolation：本工具不得读取、修改、退出或清理 Chrome/Edge 登录状态、ChatGPT Web/PWA、浏览器 Cookies、Local Storage、IndexedDB、Browser Profile 或 WebView 登录态；账号切换只允许影响 Codex Desktop 本地认证。

## 目录结构

```text
qiehao.ps1
README.md
.gitignore
lib/
  CodexAuth.psm1
profiles/
backup/
logs/
state/
tests/
  SelfTest.ps1
  GuiSelfTest.ps1
gui/
  QiehaoGui.ps1
  GuiHelpers.psm1
  MainWindow.xaml
```

`profiles`、`backup`、`logs`、`state` 的内容以及所有 `*.auth.dpapi`、`*.identity.dpapi`、`*.tmp`、`*.bak` 都被 `.gitignore` 忽略。不要对这些忽略规则做例外，也不要强制把凭证容器、身份 marker 或本机 active 状态加入 Git。

## CODEX_HOME 规则

`Get-CodexHome`：

1. 当前进程存在非空、绝对路径形式的 `CODEX_HOME` 时使用该路径。
2. 否则使用 `Join-Path $env:USERPROFILE '.codex'`。
3. 不设置或修改任何环境变量。
4. 不创建 `.codex`。
5. 显式路径无效或最终目录不存在时，以安全错误代码停止。

工具不硬编码 Windows 用户名。

官方 Codex 文档说明：`CODEX_HOME` 默认是 `~/.codex`；`file` 凭据模式将认证缓存放在 `CODEX_HOME/auth.json`，而 `keyring`、`auto`、`ephemeral` 可能使用其他位置或只使用内存。因此，存在 `auth.json` 不代表它在所有安装和策略下都是唯一凭据来源。

## 命令

在项目目录中运行：

```powershell
.\qiehao.ps1 status
.\qiehao.ps1 list
.\qiehao.ps1 save Team
.\qiehao.ps1 save Team -Force
.\qiehao.ps1 active
.\qiehao.ps1 init-marker Team
.\qiehao.ps1 init-active Plus
.\qiehao.ps1 switch Team
.\qiehao.ps1 add-profile Work
.\qiehao.ps1 remove-profile Work -ConfirmDelete
.\qiehao.ps1 rename-profile Work Account3
.\qiehao.ps1 verify-profile Account3
```

### `status`

只显示：

- 解析后的 Codex Home 路径；
- Codex Home 是否存在；
- `auth.json` 路径；
- `auth.json` 是否存在。

它不读取或输出认证 JSON 的值。

### `list`

只读取文件存在性、非秘密 metadata 和 active 状态；不解密凭证，不读取 token，不读取 identity marker 内容，不访问网络。输出：

- `Profile`
- `Active`
- `AuthFile`：`PRESENT` / `MISSING` / `UNKNOWN`
- `IdentityMarker`：`PRESENT` / `MISSING` / `UNKNOWN`
- `Metadata`：`VALID` / `INVALID` / `MISSING` / `UNKNOWN`
- `Health`：`READY` / `INCOMPLETE_PROFILE` / `INVALID_METADATA` / `UNKNOWN`
- `CreatedAt`
- `UpdatedAt`
- `DPAPIScope`
- `EncryptedFileExists`

metadata 格式不符合严格预期时，只显示 `<INVALID_METADATA>`，不会把任意 metadata 字符串原样输出。

### `save <ProfileName>`

安全流程为：

1. 安全化 profile 名称，阻止路径穿越和 Windows 保留文件名。
2. 确认 Codex/ChatGPT 相关进程均已由用户正常退出；否则立即停止。
3. 定位 Codex Home 和 `auth.json`。
4. 将认证文件读为原始 `byte[]`。
5. 仅验证 JSON 有效、根节点为 Object，且顶层字段严格等于 `auth_mode`、`OPENAI_API_KEY`、`tokens`、`last_refresh`；不进入或输出 `tokens` 内容。
6. 使用 `ProtectedData.Protect(..., CurrentUser)` 和固定的非秘密 application entropy `CodexAccountSwitcher-v1` 加密。
7. 先写同目录随机临时文件，flush/close 后再 move；覆盖时使用 `File.Replace`。
8. 从显式 `tokens.account_id` 创建独立 DPAPI `CurrentUser` 身份 marker。
9. 写入只含非秘密信息的 `<Profile>.meta.json`。
10. 在 `finally` 中尽最大合理努力清理敏感 `byte[]`。

固定 entropy 只是应用隔离标签，不是密码。DPAPI 的安全边界来自当前 Windows 用户的密钥材料。

**重要：当前阶段不要在 Codex Desktop 仍运行时执行真实 `save`。** 检测闸会拒绝这种操作。未来确需保存时，应先由用户正常退出所有 Codex/ChatGPT 相关进程，再从独立的 Windows PowerShell 窗口运行。

### `active`

只读取非秘密的 `state\active-profile.json`，显示工具当前记录的 active profile 和更新时间，不解密槽位。

### `init-marker <ProfileName>`

这是旧槽位的一次性安全迁移命令。它要求 Codex Desktop 已完全退出，只解密指定的现有 `*.auth.dpapi` 槽位，在内存中验证 auth/identity schema，创建 `*.identity.dpapi`，然后回读验证 marker。它不读取或修改当前真实 `auth.json`，不切换账号，也不更新 active 状态。

### `init-active <ProfileName>`

初始化 active 状态前必须满足：

1. Codex Desktop 进程闸返回 `CODEX_PROCESSES_STOPPED`；
2. 指定槽位能够由当前 Windows 用户通过 DPAPI 解密；
3. 槽位和当前 `auth.json` 都符合预期 schema；
4. 两者原始 bytes 完全一致。

任何不一致都返回 `ACTIVE_PROFILE_MISMATCH`，不会盲目标记。完全一致后，工具会为该槽位创建或更新 DPAPI `CurrentUser` 保护的身份 marker，然后才提交 active 状态。这也是旧槽位建立 marker 的安全迁移点。

### `switch <ProfileName>`

事务顺序：

1. 确认 Codex Desktop 已完全退出；
2. 读取并严格验证 active profile 状态；
3. 当前 active 与目标相同时返回 `ALREADY_ACTIVE`；
4. 验证当前 `auth.json` 的已知 schema，并提取 `tokens.account_id`；
5. 解密 active profile 的身份 marker，在内存中比较身份；不一致返回 `ACTIVE_PROFILE_IDENTITY_MISMATCH`，且不覆盖 active 槽位；
6. 身份一致后，使用 DPAPI 覆盖回存当前最新 `auth.json` 至 active 槽位，并更新槽位 metadata 的 `updated_at` 和身份 marker；
7. 解密并验证目标槽位，同时验证目标槽位与其 marker 一致；任何失败都发生在替换 `auth.json` 之前；
8. 在 `auth.json` 同目录写随机临时明文文件，flush/close 后使用 Windows 同卷原子替换且不创建明文备份；
9. 重新读取 `auth.json`，在内存中与目标 bytes 逐字节比较；
10. 最后才原子更新 `state\active-profile.json`。

身份 schema v1 使用 Codex 本地 TokenData 的显式 `tokens.account_id` 字段，不解码 JWT，也不依赖 email、plan、quota、Usage Limit 或 429。token 正常刷新会改变 token 字符串，但不会改变所选 ChatGPT account/workspace 的 `account_id`。该本地字段目前没有得到官方文档的兼容性承诺，因此字段缺失、重复、类型错误、`auth_mode` 不是已支持的 ChatGPT 模式、marker 缺失、DPAPI 解密失败或 marker 版本不认识时，一律 fail closed。

成功只输出：

```text
SWITCH_SUCCESS
From: Plus
To: Team
```

替换后的验证或最终状态提交失败时，工具会从刚更新的原 active 槽位重新解密、恢复并验证 `auth.json`。恢复成功返回 `SWITCH_FAILED_ROLLED_BACK`，active 状态保持原值；恢复失败返回 `SWITCH_ROLLBACK_FAILED` 和 `DO_NOT_START_CODEX_MANUAL_RECOVERY_REQUIRED`，且不更新 active 状态。

CLI 不会自动关闭或启动 Codex，也不会登录或登出账号。GUI 提供用户明确点击后的受约束启动和正常关闭请求；启动时不附加账号、token 或浏览器参数，不提权，不修改环境变量或 Codex 配置；关闭时不提供强制终止。

## 中文 GUI

在项目目录中启动：

```powershell
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\gui\QiehaoGui.ps1
```

GUI 提供统一的手动账号管理流程：

- 顶部“当前身份确认”与列表“槽位验证”是两个不同概念。手动“刷新”在 Codex 已退出时调用只读 `Test-CodexActiveIdentity`，仅显示“已确认 / 不匹配 / 尚未初始化 / 无法确认”；Codex 运行中显示“待退出后确认”，不会读取当前 auth。
- GUI 每 5 秒只检测一次 Codex 进程状态，用于更新“启动 Codex / 正常退出 Codex”按钮；这个计时器不读取 auth、identity marker、profile 列表或 active 状态。用户点击启动、正常退出、切换或刷新时仍立即重新检测；启动/退出的最长 10 秒有界等待使用 500ms 局部检测。关闭账号管理器会停止计时器并解除 Tick handler，不留下后台探测。完整资料刷新只在启动、正常退出完成或用户点击“刷新”时执行。
- “启动 Codex”默认从 AppX manifest 或 Windows Start Apps 自动检测官方 AUMID；特殊安装可在“启动设置”中选择现有的本地 `.exe`。自定义路径拒绝不存在文件、非 `.exe` 和 reparse point；启动不附加任意参数、不提权、不更改配置或环境变量。
- “启动 Codex”只在进程闸确认“已退出”且启动目标有效时可用；“正常退出 Codex”只在确认“运行中”时可用。点击时还会即时复核，状态未知时两者都不会继续。
- “切换账号”按钮、账号整行双击和右键“切换到此账号”共用同一个 Switch handler；当前账号不会调用后端。
- Codex 正在运行时，只有用户选择“正常退出并切换”后才调用安全关闭链；10 秒仍运行或状态未知时不会切换，也不存在强杀。
- 右键账号行会先选中该行；当前账号的 Switch/Delete 禁用，Rename 仍允许。
- `F2`、按钮和右键重命名共用同一对话框与 handler；DataGrid 始终只读，不做内联编辑。
- Delete 必须显示本地槽位删除说明并要求确认，后端调用始终显式传递 `-ConfirmDelete`。
- Add 向导先通过 `Save-CodexActiveProfile` 验证 active identity 并安全保存最新凭证，再要求用户自行使用官方 Codex OAuth 登录；GUI 不打开或自动操作 OAuth，不读取浏览器 Cookie。
- 搜索只对内存中的本地 Profile 名称做不区分大小写的 substring 过滤，不解密 auth/identity，不搜索 metadata、email 或 account ID。
- GUI `IsWriteOperationBusy` 防止按钮、双击、右键和快捷键重复触发；后端 named mutex 仍是最终并发安全边界。
- 所有异常只通过安全代码白名单映射为中文消息；原始 `Exception.Message` 不显示。`SWITCH_ROLLBACK_FAILED` 使用高优先级错误 UI。

### `add-profile <ProfileName>`

`add-profile` 不执行、打开或绕过 OAuth。正确前置流程是：用户已经在 Codex Desktop 中通过官方登录流程登录新账号，然后正常退出 Codex。

后端流程：

1. 取得 named mutex；
2. 进程闸必须返回 `CODEX_PROCESSES_STOPPED`；
3. 新 profile 名不得已有任何三文件残留；
4. 读取当前 `auth.json`，验证 auth/identity schema；
5. 逐个解密现有 identity marker，在内存中检查重复 account/workspace；
6. 重复身份返回 `PROFILE_IDENTITY_ALREADY_EXISTS`，只允许报告已有 profile 的本地显示名称；
7. 写入 `.auth.dpapi`、`.identity.dpapi` 和安全 `.meta.json`；
8. 回读 profile，逐字节验证 auth，并验证 marker 身份；
9. 最后才将 active 状态更新为新 profile。

如果现有 profile 缺 marker 或 marker 无法可靠解析，duplicate scan 返回 `PROFILE_IDENTITY_SCAN_INCOMPLETE`，不会冒险添加。

### `remove-profile <ProfileName> -ConfirmDelete`

删除必须显式提供 `-ConfirmDelete`；否则返回 `PROFILE_REMOVE_CONFIRMATION_REQUIRED`。当前 active profile 返回 `CANNOT_REMOVE_ACTIVE_PROFILE`。

每个目标路径都重新规范化并确认直接位于项目 `profiles` 根目录，同时拒绝 reparse point。删除范围只允许：

- `.auth.dpapi`
- `.identity.dpapi`
- `.meta.json`

部分删除失败返回 `PROFILE_REMOVE_PARTIAL_FAILURE`，只报告成功/失败的文件类型，不输出凭证、identity 或文件正文。该操作不访问 OpenAI 云端，不取消订阅，不退出浏览器或 Web ChatGPT。

### `rename-profile <OldName> <NewName>`

rename 要求旧 profile 三文件完整、metadata 有效且新名称未被占用。它只移动加密 auth、加密 identity marker 和非秘密 metadata；不解密、不修改认证正文，也不修改 marker 内容。

metadata 的 `profile_name` 和 `encrypted_file_name` 更新为新名称。如果旧 profile 是 active，文件移动和 metadata 更新全部成功后，最后才原子更新 active 状态。中途失败会按反序回滚已完成的文件移动；回滚成功返回 `PROFILE_RENAME_FAILED_ROLLED_BACK`，回滚失败返回 `PROFILE_RENAME_ROLLBACK_FAILED`。

### `verify-profile <ProfileName>`

深度检查会与所有写操作串行，并要求 Codex Desktop 已完全退出。它解密指定 auth、验证 schema、解密 identity marker、比较身份并验证非秘密 metadata，但不输出任何认证或身份值。成功返回 `PROFILE_VERIFY_SUCCESS`。

## 并发保护

修改操作使用 named mutex：

```text
Global\Qiehaoqu.CodexAccountSwitcher.<CurrentUserSID>.WriteOperation.v1
```

受保护操作包括：

- `save`
- GUI Add 向导的 active profile 安全刷新保存
- `switch`
- `add-profile`
- `remove-profile`
- `rename-profile`
- `init-marker`
- `init-active`
- `verify-profile`（深度读取也与写入串行，避免边读边改）

mutex 名称包含当前 Windows 用户 SID，使同一用户在不同桌面/RDP 会话中的实例也互斥，而不同 Windows 用户不会共享 DPAPI 写锁。SID 无法读取时退回当前会话的 `Local\Qiehaoqu.CodexAccountSwitcher.WriteOperation.v1`。`status`、`list`、`active` 保持只读。发生 abandoned mutex 时，取得锁的实例仍会依靠完整 schema、三文件 health 和身份验证 fail closed；锁始终在 `finally` 中释放。

## Active profile 状态

`state\active-profile.json` 只允许包含：

- `schema_version`
- `active_profile`
- `updated_at`

不得包含 token、账号 ID、邮箱、认证内容、token hash 或 OAuth secret。它是本机运行状态，已被 Git 忽略。

## 身份 marker

每个 profile 的 `<Profile>.identity.dpapi` 是独立 DPAPI `CurrentUser` 保护的二进制 marker。marker 明文载荷带有固定 magic、schema 版本和身份类型，并仅在内存中包含稳定身份 bytes；磁盘上不保存明文账号 ID、email、token、token hash 或 OAuth secret。marker 不绑定 profile 名称，因此未来安全重命名只需事务性移动三个 profile 文件并同步 active 状态，不需要解密或改写认证内容本身。

旧版本创建、尚无 marker 的槽位不会被 switch 猜测或自动信任，而是返回 `PROFILE_IDENTITY_MARKER_MISSING`。只能在可证明的初始化/迁移流程中创建 marker。

## Metadata

每个成功槽位可以有一个 `<Profile>.meta.json`，只包含：

- `schema_version`
- `profile_name`
- `created_at`
- `updated_at`
- `encrypted_file_name`
- `encrypted_file_size`
- `dpapi_scope`，固定为 `CurrentUser`

禁止加入账号 ID、邮箱、token、token hash、API key、cookie、OAuth 响应、认证 JSON 或 workspace secret。

## 日志

日志只使用代码内固定模板，例如：

```text
2026-09-15 15:00:00 INFO profile save started: Team
2026-09-15 15:00:01 INFO encrypted profile written successfully: Team
```

失败只记录固定安全代码，不记录异常对象全文、JSON 正文或认证值。日志目录不可用于调试输出凭证。

## 自测试

执行：

```powershell
.\tests\SelfTest.ps1
.\tests\GuiSelfTest.ps1
```

自测试只使用源码中明确写出的虚构 JSON，并只在 `tests` 下建立随机临时目录。它测试：

- 预期顶层 schema；
- 非预期顶层字段必须以 `AUTH_SCHEMA_UNEXPECTED` 拒绝；
- fake bytes → DPAPI Protect → Unprotect → byte comparison；
- 临时加密 profile 的原子写入 → 读取 → 解密 → byte comparison；
- 同名目标默认必须以 `PROFILE_EXISTS` 拒绝覆盖；
- fake A → B 完整切换，并确认切换前已刷新的 A 被先回存；
- token bytes 已刷新但稳定身份不变时仍识别为同一账号；
- active=A 但当前 auth 实际为 B 时，在覆盖 A 槽位前返回 `ACTIVE_PROFILE_IDENTITY_MISMATCH`；
- Add 向导保存 active 最新凭证时验证 identity drift，并在 fake 环境完成回读比对；
- marker 缺失或身份 schema 不认识时 fail closed；
- profile 文件重命名后 marker 仍可与认证身份正确关联；
- 添加第三个账号、同名拒绝和跨名称重复身份拒绝；
- 非 active 删除、active 删除拒绝、显式确认和部分失败报告；
- 普通/active rename、metadata 更新和中途失败回滚；
- 三文件不完整 health、深度 verify 和 marker/auth 不一致拒绝；
- 两个进程竞争 named mutex 时第二个写操作返回 `OPERATION_BUSY`；
- 目标 DPAPI 损坏或 schema 异常时 fake `auth.json` 不变；
- 替换后验证失败时自动恢复 fake A，active 状态保持 A；
- active 状态缺失、目标已 active、浏览器 extension-host 和 Codex 进程闸；
- `init-active` 逐字节不一致时拒绝标记；
- 删除测试产生的临时文件和目录。

GUI 自测试在 Windows PowerShell 5.1 与 PowerShell 7 中解析 XAML，并通过 dependency injection 覆盖 Switch、正常退出后切换、受约束启动目标、刷新身份语义、进程计时器隔离、回滚结果映射、Add/Rename/Delete、整行双击、右键、F2、搜索、Busy 门禁、五套玻璃主题、活动账号行、中文编码以及 Chrome/Edge extension-host 隔离。它不会显示真实 GUI，不会启动或关闭真实 Codex，也不会调用真实账号后端。

自测试不会调用 `Get-CodexHome`，不会读取真实 `.codex/auth.json`，不会写入正式 `profiles`，也不会改变 `CODEX_HOME`。

## PowerShell 5.1 与内存清理限制

- 脚本只使用 Windows PowerShell 5.1 和 Windows/.NET 自带能力，不依赖 Python、Node.js、第三方模块、第三方 EXE、在线 API或网络服务。
- 在提供 `System.Text.Json` 的运行时中，schema 检查直接从 `byte[]` 流解析，只枚举顶层 key 名称。
- Windows PowerShell 5.1 默认不附带 `System.Text.Json`，因此兼容路径必须临时把 UTF-8 bytes 转成内存字符串并调用内置 `ConvertFrom-Json`。该字符串从不打印、记录或落盘，但 .NET 不允许可靠地原地擦除不可变字符串。
- 工具会使用 `Array.Clear` 尽最大合理努力清理可控的明文、密文和解密后 `byte[]`。垃圾回收、运行时复制、不可变字符串、操作系统缓存和崩溃转储意味着 PowerShell/.NET 无法承诺“绝对内存擦除”。本工具不会作这种不真实的保证。

## 当前支持与未支持

当前支持：

- 检测 Codex Home；
- 检测 `auth.json` 是否存在及是否符合已知顶层结构；
- DPAPI CurrentUser 加密与解密函数；
- 在所有 Codex/ChatGPT 进程退出后保存账号槽位；
- 查看槽位而不解密；
- 初始化并查看非秘密 active profile 状态；
- 以独立 DPAPI 身份 marker 防止手工登录导致的 active profile 状态漂移污染；
- 添加任意合理数量的本地 profile，并拒绝同名或同 identity 重复项；
- 删除非 active profile、事务性重命名 profile；
- 不解密的 profile health 列表和显式深度验证；
- named mutex 单写保护；
- 在 Codex Desktop 完全退出后执行“回存当前 → 验证目标 → 原子替换 → 读回验证 → 提交 active 状态”的本地切换；
- 替换后失败时从刚更新的原 active 槽位回滚；
- 中文 WPF GUI 的手动 Switch/Add/Rename/Delete、受约束启动/正常退出、当前身份只读确认、进程状态计时器、五套玻璃主题、整行双击、右键、F2、名称搜索和写操作 Busy 门禁；
- 用户明确确认后的 Codex 主窗口正常关闭请求与 10 秒 fail-closed 等待；
- 完全虚构数据自测试。

尚不支持：

- 强制关闭或自动启动 Codex；
- 自动登录或登出；
- 自动 quota failover；
- round-robin；
- 多账号并发；
- 自动绕过使用限制；
- 将配置 profile 当作账号身份；
- 验证操作系统 keyring/Windows Credential Manager 中的凭据状态。
