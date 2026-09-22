# Public Release Inventory（公开发布清单）

本文定义 Qiehao RC（Release Candidate，候选发布）阶段的 GitHub 源码仓库与 Release ZIP（发布压缩包）内容边界。源码仓库保留开发、审计和测试材料；面向普通用户的 Release ZIP 只包含运行所需文件和必要说明。

## GitHub 源码仓库应包含

- README.md
- SECURITY.md
- CONTRIBUTING.md
- CHANGELOG.md
- LICENSE（正式公开发布前由维护者选择并加入；当前缺失）
- Start-Qiehao.cmd
- qiehao.ps1
- gui/
- lib/
- tools/（Quota Snapshot 的运行时依赖）
- tests/（自动测试与发布审计）
- docs/（发布清单与维护文档）

## Release ZIP 应包含

- README.md
- SECURITY.md
- CHANGELOG.md
- LICENSE（维护者选择并加入后）
- Start-Qiehao.cmd
- qiehao.ps1
- gui/
- lib/
- tools/（Quota Snapshot 的运行时依赖）

面向普通用户的 Release ZIP 不包含 `.git/`、`tests/`、开发工作区或本机生成的运行数据。用户应完整解压 ZIP，并通过 `Start-Qiehao.cmd` 启动；不要直接在 ZIP 压缩包内运行。

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
- crash dump（崩溃转储）
- runtime temp（运行时临时文件）
- 浏览器 Profile、Cookie、LocalStorage、IndexedDB 或 PWA 会话文件
- 真实认证、Token、邮箱、账号 ID、额度响应或代理配置

## 打包前门禁

1. 许可证已经由维护者明确选择并以标准 LICENSE 文件加入。
2. PS5.1 与 PS7 全测试矩阵通过。
3. PowerShell AST、XAML、foreign CWD 和 launcher 路径测试通过。
4. 当前树与完整可达 Git 历史完成敏感信息扫描。
5. 从干净检出目录生成文件清单，拒绝任何未列入允许集合的运行时内容。
6. 对最终 ZIP 再做一次离线敏感扫描，并记录 SHA-256（安全哈希）校验值。
7. 在全仓文本与最终 ZIP 中确认正式入口统一为 `Start-Qiehao.cmd`，且不存在其他启动入口说明。

不要直接压缩开发工作目录；开发目录可能包含被 .gitignore 忽略、但仍然敏感的本机运行状态。
