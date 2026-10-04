# Public Release Inventory（公开发布清单）

本文定义 Qiehao v1.1.0 正式发布的源码仓库与 Release ZIP（发布压缩包）内容边界。源码仓库保留开发、审计和测试材料；面向普通用户的 ZIP 只包含运行所需文件和必要说明。正式发布从最终 test6 候选版本收口，不再修改账号核心逻辑。

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

面向普通用户的 ZIP 不包含 `.git/`、`tests/`、`docs/`、`launcher/`、`obj/`、`bin/`、PDB、开发工作区或本机运行数据。用户应完整解压 ZIP，推荐双击 `Qiehao.exe`；`Start-Qiehao.cmd` 保留为兼容／排障入口，启动同一套程序逻辑。不要直接在 ZIP 内运行。

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
2. PS5.1 与 PS7 全测试矩阵通过。
3. PowerShell AST、XAML、foreign CWD 和 launcher 路径测试通过。
4. 当前树与完整可达 Git 历史完成敏感信息扫描。
5. 从最终封板工作树按明确白名单复制到全新隔离目录，逐文件校验；测试与 ZIP 验证通过后提交同一份内容，并核对提交与发布清单一致。不得用旧 HEAD 丢弃候选版本修复，也不得直接压缩开发目录。
6. 对最终 ZIP 再做一次离线敏感扫描，并记录 SHA-256（安全哈希）校验值。
7. 验证 `Qiehao.exe` 为 Windows GUI 子系统且版本为 1.1.0，CMD 备用入口仍存在；旧 BAT 文件和启动说明不得进入 ZIP。解压后复核 EXE／ZIP 哈希及离线启动自检。

不要直接压缩开发工作目录；开发目录可能包含被 .gitignore 忽略、但仍然敏感的本机运行状态。
