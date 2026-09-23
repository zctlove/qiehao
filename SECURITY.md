# Security Policy（安全策略）

## Supported Version（支持版本）

当前接受安全修复的版本：

| Version（版本） | Supported（支持） |
| --- | --- |
| v1 | Yes |

## Reporting a Vulnerability（报告安全问题）

公开 GitHub 仓库创建后，请优先使用 GitHub Private Vulnerability Reporting / Security Advisory（GitHub 私密漏洞报告/安全公告）功能提交安全问题（如果该功能可用）。在私密渠道建立前，请不要在公开 Issue（问题）、Discussion（讨论）或 Pull Request（拉取请求）中披露可利用细节。

报告时请提供可复现步骤、影响范围和最小化的假数据示例。请勿提交或粘贴：

- auth.json 或其内容；
- Access Token / Refresh Token（访问令牌/刷新令牌）；
- 真实邮箱或账号 ID；
- 浏览器 Cookie、LocalStorage、IndexedDB 或会话文件；
- *.auth.dpapi、*.identity.dpapi 或其他认证备份；
- 含凭据、个人路径或身份信息的日志；
- 真实 account/rateLimits/read 响应。

## Security Boundaries（安全边界）

安全报告尤其应关注以下边界是否被绕过：

- **Auth（认证）**：真实认证内容不得进入日志、诊断、测试夹具或公开错误信息。
- **DPAPI**：认证快照和身份标记使用 Windows DPAPI CurrentUser 保护；不得降级为明文持久化。
- **Browser/PWA**：项目不得读取或修改浏览器/PWA 登录状态。
- **Process gate（进程门禁）**：认证写操作必须在 Codex 确认完全退出后执行；未知状态必须安全拒绝。
- **Quota（额度）**：只查询当前活动档案；失败不得触发自动切号，也不得清除旧快照。
- **Sensitive files（敏感文件）**：运行时档案、状态、日志、备份、认证文件和额度缓存不得进入 Git 或发布包。

测试报告必须使用虚构数据。若复现确实依赖真实环境，请先去除 Token、账号标识、邮箱、路径和其他可关联信息，再通过私密渠道说明最小必要条件。
