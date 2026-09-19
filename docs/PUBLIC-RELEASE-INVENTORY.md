# Public Release Inventory（公开发布清单）

本文定义未来 GitHub 源码仓库与 Release ZIP（发布压缩包）的候选内容。当前阶段不生成压缩包、不创建 GitHub 仓库，也不执行任何远端操作。

## 应包含

- README.md
- SECURITY.md
- CONTRIBUTING.md
- CHANGELOG.md
- LICENSE（待维护者选择许可证后加入）
- Start-Qiehao.cmd
- qiehao.ps1
- gui/
- lib/
- tools/（Quota Snapshot 的运行时依赖）
- tests/（源码仓库保留）

tests/ 是否进入面向普通用户的最终 Release ZIP，由后续 packaging（打包）阶段决定；无论是否打包，源码仓库都应保留测试。

## 绝对禁止包含

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

不要直接压缩开发工作目录；开发目录可能包含被 .gitignore 忽略、但仍然敏感的本机运行状态。
