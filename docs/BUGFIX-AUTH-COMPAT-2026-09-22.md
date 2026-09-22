# P0/P1 修复任务：首次添加账号失败（Codex 认证兼容）

日期：2026-09-22

## 现场症状

全新用户首次运行 Qiehao：

1. Codex Desktop 已经正常登录过 ChatGPT 账号；
2. Codex 已完全退出；
3. 打开 Qiehao；
4. 点击“添加账号”；
5. 点击“我已登录新账号并退出”/等价确认；
6. 最终只弹出“操作失败，未进行不安全的继续操作”。

这条路径会让 0 个账号的新用户完全无法开始使用，按 P0/P1 处理。

## 已定位的兼容风险

### 1. `auth.json` 顶层字段被错误地按“必须恰好 4 个”校验

当前 `lib/CodexAuth.psm1`：

```powershell
$script:ExpectedAuthKeys = @('auth_mode', 'OPENAI_API_KEY', 'tokens', 'last_refresh')
```

`Test-CodexAuthBytes` 又要求实际字段数量必须与这 4 个完全相等。这样只要新版 Codex 在合法 `auth.json` 中增加任何可选字段，Qiehao 就会抛 `AUTH_SCHEMA_UNEXPECTED`。

截至 2026-09-22，上游 Codex `AuthDotJson` 已存在额外可选字段，例如：

- `agent_identity`
- `personal_access_token`
- `bedrock_api_key`
- `bedrock_access_keys`

未来还可能继续新增。

Qiehao 保存的是原始认证字节并用 DPAPI CurrentUser 加密，不应该因为不认识的“额外顶层字段”就拒绝整份由 Codex 自己生成的合法认证文件。

### 2. 新版 Codex 认证缓存不一定存在于 `auth.json`

Codex 支持 `cli_auth_credentials_store = file | keyring | auto | ephemeral`。

- `file`：使用 `CODEX_HOME/auth.json`
- `keyring`：使用操作系统凭据存储
- `auto`：系统凭据库可用时优先使用，否则回退文件
- `ephemeral`：仅当前进程内存

Qiehao 当前核心实现只读取 `CODEX_HOME/auth.json`。当用户使用 keyring/auto 且凭据实际位于系统凭据库时，不能把“找不到 auth.json”伪装成一个笼统的“操作失败”。

## 修复目标

### A. 修复文件认证的前向兼容性（必须）

修改 `Test-CodexAuthBytes` / 相关校验：

1. 仍然要求输入是有效 UTF-8 JSON 对象；
2. 对 Qiehao 真正依赖的关键结构做严格校验；
3. **允许未知/新增的顶层字段存在**；
4. 不允许因为 `agent_identity`、`personal_access_token`、`bedrock_*` 或未来未知字段而失败；
5. 不重写、不裁剪、不重新序列化用户的 `auth.json`；保存时必须继续保留原始字节，保证未知字段原样随快照保存和恢复；
6. ChatGPT 身份确认继续严格依赖现有的 `auth_mode == chatgpt` 与 `tokens.account_id` 逻辑；缺失、重复、类型错误或空值仍应 fail closed（安全拒绝）；
7. 不降低现有 DPAPI、身份标记、原子写、读回校验、回滚和进程门禁。

建议的校验语义：

- 顶层必须是 JSON object；
- `auth_mode`、`tokens` 等 Qiehao 实际依赖项必须存在并由后续身份函数严格验证；
- 额外顶层字段一律视为“可向前兼容的未知字段”，而不是异常；
- 对重复顶层关键字段仍应尽可能安全拒绝；
- API Key/Bedrock 模式不是本项目的账号切换目标，不要为了兼容额外字段而误接纳非 ChatGPT 登录。

### B. 修复 `AUTH_FILE_NOT_FOUND` 的用户诊断（必须）

当 Codex 已退出但 `CODEX_HOME/auth.json` 不存在时：

1. 不要显示只有一句“操作失败”；
2. 给出安全、非敏感、可执行的中文/英文提示；
3. 提示应说明：新版 Codex 可能把登录凭据保存在 Windows Credential Manager / OS keyring（系统凭据库），当前 Qiehao 的文件快照模式无法直接导入这种凭据；
4. **不要自动读取 Windows Credential Manager**；
5. **不要自动修改 `config.toml`**；
6. **不要自动注销/重新登录**；
7. **不要访问浏览器 Cookie、LocalStorage、IndexedDB 或网页登录状态**；
8. 可以显示安全错误代码（例如 `AUTH_FILE_NOT_FOUND`），方便客户截图后定位。

如果能可靠只读判断 `cli_auth_credentials_store`，可以显示更精准的提示；判断失败时不要猜，使用“可能使用系统凭据库”的措辞。

### C. 改善首次添加账号路径（建议一并完成）

在 Add Account（添加账号）流程中，在真正写入 Profile 之前做 preflight（预检）：

- Codex 必须已确认完全退出；
- `CODEX_HOME` 可解析；
- 文件模式下 `auth.json` 可读；
- JSON/ChatGPT 身份结构可识别；

如果预检失败，在询问本地 Profile 名称之前就告诉用户明确原因，避免用户走完整套流程后才收到笼统报错。

文案上要区分：

- 已登录过且当前文件凭据可直接导入；
- 尚未登录，需要走 Codex 官方登录；
- 已登录但凭据位于 keyring/系统凭据库，当前版本不能直接导入。

不要声称“必须 Qiehao 开着时登录一次”。Qiehao 不应监听 OAuth 登录过程；它只应在 Codex 完全退出后读取落盘的本地认证状态。

## 必须补的测试

在现有 `tests/SelfTest.ps1` / GUI 自测中新增回归覆盖，至少包括：

1. 旧版 4 字段 ChatGPT `auth.json`：继续通过；
2. 增加 `agent_identity`：通过；
3. 增加 `personal_access_token`：通过（不读取/输出该值）；
4. 增加 `bedrock_api_key` / `bedrock_access_keys` 顶层可选字段但当前仍是 ChatGPT 登录：基础结构校验不应因“额外字段”失败，最终身份模式仍由 `auth_mode`/`tokens.account_id` 决定；
5. 增加任意 `future_optional_field`：通过；
6. 缺失关键身份字段：拒绝；
7. `auth_mode` 非 `chatgpt`：账号添加/身份确认拒绝；
8. `tokens.account_id` 缺失、空、非 string、重复：拒绝；
9. 非法 JSON / 非 object / 空文件：继续拒绝；
10. `AUTH_FILE_NOT_FOUND`：GUI 显示针对性的安全提示和错误代码，不泄漏凭据/路径敏感信息；
11. 所有原有安全/切换/回滚自测继续通过。

特别注意：现有 SelfTest 中“只要多一个 unexpected 字段就必须拒绝”的断言需要改掉，因为这正是本次兼容 BUG 的来源。应该改成“未知顶层字段被保留并接受，但关键身份结构仍严格验证”。

## 不允许的修法

- 不要把所有校验直接删掉；
- 不要把 `AUTH_SCHEMA_UNEXPECTED` 全部吞掉；
- 不要重新序列化后只保存 Qiehao 认识的字段；
- 不要通过读取浏览器 Cookie 解决；
- 不要静默读取 Windows Credential Manager；
- 不要静默把 `cli_auth_credentials_store` 改为 `file`；
- 不要降低 Codex 必须完全退出的进程门禁；
- 不要强杀 Codex；
- 不要破坏 DPAPI CurrentUser、原子替换、读回验证、Rollback（回滚）、命名互斥锁。

## 验收标准

- 新用户机器上，只要 Codex 当前使用 file-backed（文件型）ChatGPT 认证，且 `auth.json` 是 Codex 新版合法结构，即使含新增可选字段，也能直接“添加账号”；
- 如果认证在 keyring/系统凭据库，Qiehao 明确解释“不支持直接导入当前存储方式”，而不是泛化失败；
- 不需要 Qiehao 在 OAuth 登录时保持运行来“抓凭据”；
- 不泄漏 token、refresh token、account id 等敏感值到日志/异常/UI；
- 原有安全边界全部保持；
- 回归测试覆盖本次现场路径。