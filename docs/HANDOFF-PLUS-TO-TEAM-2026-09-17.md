# qiehaoqu 增量交接：Plus → Team（2026-09-17）

本文档是从 Team 切换至 Plus 后产生的增量交接，只记录基础交接之后的变化，不复制项目的完整架构与历史说明。

- 基础交接：[HANDOFF-TEAM-TO-PLUS-2026-09-17.md](HANDOFF-TEAM-TO-PLUS-2026-09-17.md)
- 增量基线：`42e1a4ea docs-team-to-plus-handoff`
- 当前分支：`feature/gui-v1`
- 本文档创建前的最新 HEAD：`d65ffcbb native-codex-quit`

## 1. Plus 接手后的提交链

| Commit | Message | 主要变化 |
| --- | --- | --- |
| `49221d29` | `fix-exit-prefs-polling` | 修正正常退出目标筛选、主题偏好路径与读写行为；常规进程探测改为 5 秒；GUI 关闭时停止探测。 |
| `6f7154ca` | `fix-theme-persistence-real-event` | 修复真实 WPF `SelectionChanged` 生命周期中的主题持久化写入链。 |
| `9c3211ac` | `fix-exit-wait-timer-closure` | 修复退出等待计时器的闭包生命周期、异常隔离与幂等清理。 |
| `d65ffcbb` | `native-codex-quit` | 将自动退出主逻辑从 `CloseMainWindow` 改为 Windows UI Automation（Windows UI 自动化）触发 Codex 原生 Quit。 |

## 2. 已经真人实机 PASS

- Team → Plus 的 GUI Switch 已成功完成，过程无报错。
- 从账号管理器启动 Codex 已成功。
- 主题切换可以在界面中即时生效。
- `state/ui-preferences.json` 已确认能在真实运行中立即覆盖保存。
- 关闭 GUI 后重新打开，可以恢复先前选择的主题。
- 使用 Codex 自己的官方 Exit/Quit（退出）后，真人验收结果为：
  - Codex 客户端：已退出；
  - 当前身份确认：已确认；
  - “验证账号”按钮：恢复可用；
  - 点击验证后：已验证。

## 3. 已经真人实机 FAIL / 尚未解决

“正常退出 Codex”自动退出功能仍未通过真人验收。

最新的 `d65ffcbb` 已把主逻辑从 `CloseMainWindow` 改为 Windows UI Automation Native Quit（Windows UI 自动化原生退出）。该提交的自动测试通过，但在真实 Codex Desktop `26.908.9136.0` 上，UIA Quit 菜单查找失败。

真人点击“正常退出 Codex”后的提示为：

> 未找到 Codex 原生退出菜单，请使用 Codex 的退出功能或系统托盘退出后重试

因此当前结论是：

- `d65ffcbb` 自动测试 PASS，但真实 Codex `26.908.9136.0` 的 UIA Quit 查找 FAIL；
- Native Quit 不能标记为已完成；
- 不得恢复使用 `CloseMainWindow`，把关闭可见窗口伪装成正常退出；
- 不得强制终止 Codex 进程。

## 4. 已确认的退出事实

- `CloseMainWindow` 只能关闭当前可见窗口，Codex 后台仍会继续运行，因此它不等价于官方 Exit/Quit。
- 使用 Codex 自己的官方 Exit/Quit 会让 Codex 完全退出，现有 process gate（进程门控）随后能正确显示 `Stopped`。
- 现有 process gate 仍应作为退出是否真正完成的最终判断依据。

## 5. 下一步最高优先级

只研究“如何可靠触发当前 Codex Desktop 的原生 Quit”。在 Native Quit 通过真人实机验收之前，不进入大规模 UI 美化阶段。

建议下一任 Codex 先做只读诊断：确认真实 `26.908.9136.0` 的 UI Automation 树、菜单呈现方式、控件类型、可访问名称及触发模式，再对现有 Native Quit 定位逻辑做最小修改。诊断期间不得真实退出当前 Codex，除非用户明确安排一次受控真人验收。

## 6. 持续有效的安全边界

- 不强杀 Codex，不使用强制终止进程的方式冒充正常退出。
- 不触碰 Chrome/Edge、浏览器 PWA 或 extension-host（扩展宿主）。
- 不修改真实认证内容，不记录或输出认证令牌、账号标识、邮箱地址、Cookie、DPAPI 明文、密钥或其他认证秘密。
- 不修改网络或代理设置。
- 不使用真实 Plus/Team 主账号对 Add、Delete、Rename 做破坏性测试；相关自动测试继续使用 fake `CODEX_HOME` 和 dependency injection（依赖注入）。

## 7. Native Quit 真人 PASS 后的 UI 待办

- 真正的玻璃拟态效果；
- DataGrid 行高；
- 字体上下空间；
- 功能按钮语义色；
- 背景素材重新设计；
- 最终快捷方式或 EXE。

## 8. 接管核验顺序

下一任 Codex 开始工作时，应先只读执行：

1. 确认工作目录、当前分支和当前 HEAD；
2. 检查 `git status --short` 与最近提交；
3. 阅读基础交接和本增量交接；
4. 确认没有来源不明的未提交修改；
5. 围绕 Native Quit 做只读诊断和 fake 测试设计，不擅自进行真实账号或真实进程操作。

## 9. 冲突处理原则

如果本增量交接、基础交接、旧聊天记录与仓库实际状态存在冲突，以当前 Git 仓库代码、当前 HEAD 和真人实机验收结果为准。
