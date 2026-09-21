# Public Release Inventory（公开发布清单）

GitHub 源码仓库已经公开，Qiehao v1.0.0 是首个正式 Release（发布版本）。本文定义公开源码仓库与 Windows Release ZIP（发布压缩包）的内容边界。

## 公开源码仓库应包含

- README.md
- README.en-US.md
- README-FIRST.txt
- SECURITY.md
- CONTRIBUTING.md
- CHANGELOG.md
- LICENSE（MIT License）
- Start-Qiehao.bat
- Start-Qiehao.cmd
- qiehao.ps1
- gui/
- lib/
- tools/（Quota Snapshot 的运行时依赖）
- tests/（源码仓库保留）
- docs/

## 普通用户 Release ZIP 应包含

- README-FIRST.txt
- README.md
- README.en-US.md
- LICENSE
- CHANGELOG.md
- SECURITY.md
- Start-Qiehao.bat
- Start-Qiehao.cmd
- qiehao.ps1
- gui/
- lib/
- tools/

ZIP 必须从新的干净 staging（预备目录）生成。永远不得直接压缩开发工作目录；开发目录可能包含被 `.gitignore` 忽略但仍然敏感的本机运行状态。

## 永久排除

- docs/HANDOFF-*.md（私人开发交接资料）
- .git/
- .gitignore
- tests/（不进入普通用户 ZIP）
- docs/（不进入普通用户 ZIP）
- CONTRIBUTING.md（不进入普通用户 ZIP）
- profiles/
- state/
- logs/
- backup/
- auth.json
- *.auth.dpapi
- *.identity.dpapi
- quota-cache.json
- *.log
- *.dmp
- *.dump
- crash dump（崩溃转储）
- runtime temp（运行时临时文件）
- 浏览器 Profile、Cookie、LocalStorage、IndexedDB 或 PWA 会话文件
- 真实认证、Token、邮箱、账号 ID、额度响应或代理配置

HANDOFF 和所有 runtime secrets（运行时秘密）永久排除于公开源码、Release ZIP 和 Release assets（发布资产）之外。

## 发布门禁

1. 标准 MIT LICENSE 文件已加入。
2. PS5.1 与 PS7 全测试矩阵通过。
3. PowerShell AST、XAML、foreign CWD 和 launcher 路径测试通过。
4. 当前树与完整可达 Git 历史完成敏感信息扫描。
5. 从新的干净 staging 目录按允许清单生成 ZIP。
6. 对最终 ZIP 的全新解压副本再次离线扫描并运行 launcher 等价测试。
7. 记录最终 ZIP 的 SHA-256（安全哈希）校验值。
