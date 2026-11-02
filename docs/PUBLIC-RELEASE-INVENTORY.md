# Public Release Inventory（公开发布清单）

本文定义 Qiehao v1.1.1（2026-11-02，最新正式版本）Windows Release ZIP（发布压缩包）的内容边界。源码仓库保留开发、审计和测试材料；面向普通用户的 ZIP 只包含运行所需文件和必要说明。正式包必须从独立 staging（临时打包目录）按白名单生成，本清单本身不构成发布授权。

## GitHub 源码仓库应包含

- README.md
- README.en-US.md
- SECURITY.md
- CONTRIBUTING.md
- CHANGELOG.md
- LICENSE（MIT 许可证）
- Start-Qiehao.cmd
- qiehao.ps1
- gui/
- lib/
- tools/（Quota Snapshot 的运行时依赖）
- tests/（自动测试与发布审计）
- docs/（发布清单与维护文档）
- launcher/（薄 EXE 源码与离线构建脚本；不进入用户 ZIP）

## Release ZIP 应包含

- Qiehao.exe（薄启动器，无脚本嵌入）
- README-FIRST.txt（中英文快速说明，已与正式 README 同步审查）
- README.md
- README.en-US.md
- SECURITY.md
- CHANGELOG.md
- LICENSE（MIT 许可证）
- Start-Qiehao.cmd
- qiehao.ps1
- gui/
- lib/
- tools/（Quota Snapshot 的运行时依赖）

面向普通用户的 ZIP 不包含 `.git/`、`tests/`、`docs/`、`launcher/`、`evidence/`、`obj/`、`bin/`、`.codex/`、`node_modules/`、PDB、开发工作区或本机运行数据。用户应完整解压 ZIP，推荐双击 `Qiehao.exe`；`Start-Qiehao.cmd` 保留为兼容／排障入口，启动同一套程序逻辑。不要直接在 ZIP 内运行。

## 源码提交与 Release ZIP 绝对禁止包含

- profiles/
- state/
- logs/
- backup/
- auth.json
- *.auth.dpapi
- *.identity.dpapi
- quota-cache.json
- *.log
- *.tmp / *.bak / *.pdb / .selftest-*
- crash dump（崩溃转储）
- runtime temp（运行时临时文件）
- 浏览器 Profile、Cookie、LocalStorage、IndexedDB 或 PWA 会话文件
- 真实认证、Token、邮箱、账号 ID、额度响应或代理配置

## 打包前门禁

1. 许可证已经由维护者明确选择并以标准 LICENSE 文件加入。
2. 如实记录 PS5.1 / PS7 的 PASS、FAIL、NOT RUN。产品真实功能断言或凭据隔离、身份验证、安全检查失败必须停止；测试模拟缺陷及 PowerShell / Job / 临时目录基础设施故障保留证据并明确披露，按维护者已批准的发布政策评估，不要求虚报 54/54 通过。
3. PowerShell AST、XAML、foreign CWD 和 launcher 路径测试通过。
4. 当前树与完整可达 Git 历史完成敏感信息扫描。
5. 从最终封板工作树按明确白名单复制到全新隔离目录，逐文件校验；测试与 ZIP 验证通过后提交同一份内容，并核对提交与发布清单一致。不得用旧 HEAD 丢弃候选版本修复，也不得直接压缩开发目录。
6. 对最终 ZIP 再做一次离线敏感扫描，并记录 SHA-256（安全哈希）校验值。
7. 验证重新编译的 `Qiehao.exe` 为 Windows GUI 子系统，FileVersion / AssemblyVersion 为 `1.1.1.0`、ProductVersion / AssemblyInformationalVersion 为 `1.1.1`，CMD 备用入口仍存在；旧 BAT 文件和启动说明不得进入 ZIP。解压后复核 EXE／ZIP 哈希及离线启动自检。
8. 逐项核对 ZIP 成员白名单、隐藏文件、扩展名、敏感内容及重解析点／符号链接；任何私有运行数据进入 ZIP 都必须拒绝发布。`.gitignore` 不能代替打包白名单。

不要直接压缩开发工作目录；开发目录可能包含被 .gitignore 忽略、但仍然敏感的本机运行状态。

## Documentation consistency gate（发布文档一致性门禁）

每次准备新的公开 Release 前，必须同时复核中文与英文用户说明：

1. 明确区分最新已发布版本、当前 main 源码检查点和未发布候选；不得把源码推送描述成新 Release。
2. 双语 README 必须同步说明 OAuth 完成通知失败但本机授权可能已改变时的只读身份检查、再次确认保存新档案、活动档案不同步时的安全停止规则。
3. 双语 README 必须说明 Plus → 已保存 Team 恢复的严格适用条件、替换当前 Plus 登录的后果，以及“需要人工检查／请勿启动 Codex”的停止要求。
4. 双语 README 必须说明旧额度缓存可能归属未验证、身份不一致时暂停额度查询，以及“无可显示额度窗口”不等于额度为 0。
5. 双语 README 必须明确列出尚未解决的已知限制：Codex Desktop 偶尔显示未登录、官方 OAuth 完成通知仍可能被拒绝；不得宣称本轮已彻底解决。
6. 未发布源码变化记录在 Unreleased；获准正式发行时收口为带日期的版本记录，并保留历史。v1.1.1 发布记录日期为 2026-11-02。README-FIRST.txt 经双语审查后纳入本版 Release ZIP 白名单。测试基础设施问题及未运行项目必须在发行说明中公开披露。
