# Contributing to Qiehao（参与贡献）

感谢帮助改进 Qiehao。这个项目处理本机认证状态，安全边界和可恢复性优先于功能数量。

## 不可破坏的边界

贡献不得：

- 加入浏览器 Cookie、LocalStorage、IndexedDB 或 Web/PWA 会话读取逻辑；
- 加入强制终止 Codex 进程的正常流程；
- 加入自动账号轮换、round-robin（轮询轮换）或无人值守切号；
- 根据 Quota（额度）、HTTP 429 或错误状态自动切号；
- 对 inactive profile（非活动档案）发起网络轮询；
- 提交真实 auth/profile（认证/档案）测试夹具、Token、邮箱、账号 ID 或真实额度响应；
- 把未知进程、认证或身份状态按成功处理；
- 绕过 named mutex（命名互斥锁）、process gate（进程门禁）、原子替换、读回验证或回滚流程。

## 开发原则

- 使用最小、可审计的变更，避免把无关重构混入安全修复。
- 测试必须使用 fake-only（仅假数据）和临时目录。
- WPF 验证必须使用 hidden/offscreen（隐藏/离屏）方式，不启动生产 GUI。
- 错误输出只使用安全白名单代码，不输出原始认证、身份、stderr 或服务响应。
- 新增运行时文件时，同步评估 .gitignore 和发布包排除规则。

## 测试要求

提交前必须在 Windows PowerShell 5.1 和 PowerShell 7 中运行：

~~~powershell
$tests = @(
  'VisualPolishSelfTest.ps1',
  'AccountGridLayoutSelfTest.ps1',
  'LocalizationSelfTest.ps1',
  'GuiSelfTest.ps1',
  'QuotaGuiSelfTest.ps1',
  'QuotaParserSelfTest.ps1',
  'QuotaImportContractSelfTest.ps1',
  'QuotaBackgroundWorkerSelfTest.ps1',
  'QuotaChildCleanupSelfTest.ps1',
  'SwitchBeforeQuotaSelfTest.ps1',
  'SelfTest.ps1',
  'LauncherSelfTest.ps1'
)

foreach ($test in $tests) {
  & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path '.\tests' $test)
  if ($LASTEXITCODE -ne 0) { throw "PS5.1 failed: $test" }
}

foreach ($test in $tests) {
  & pwsh.exe -NoLogo -NoProfile -File (Join-Path '.\tests' $test)
  if ($LASTEXITCODE -ne 0) { throw "PS7 failed: $test" }
}
~~~

还应运行 PowerShell AST（抽象语法树）解析、XAML 加载、foreign CWD（外部当前目录）验证和 git diff --check。任何测试失败都应先定位原因，不能通过放宽安全断言来“修绿”。

## Pull Request（拉取请求）说明

请清楚描述：

- 变更解决的问题和明确的非目标；
- 对 Auth、DPAPI、进程门禁、Switch、Quota 和浏览器隔离的影响；
- PS5.1 / PS7 测试结果；
- 是否新增运行时文件、网络访问或敏感数据处理；
- 失败路径和回滚行为。

公开内容不得包含个人路径、真实邮箱、代理配置、内部 URL 或本机环境细节。
