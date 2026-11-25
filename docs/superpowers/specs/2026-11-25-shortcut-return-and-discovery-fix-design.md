# 快捷指令返回类型与发现入口修复设计

日期：2026-11-25

状态：用户已确认纳入下一版；根据设备统一日志增加了根因修复。

## 背景

用户在 iOS 16.3 + TrollStore 上运行“同步健康数据”时仍看到“无法与帮助程序通信”，有时会提示 App 意外退出；在快捷指令的 HealthMi 操作列表中也只看到同步动作，没有看到查询动作。用户提供了 `D:\debug\shortcut-debug.jsonl`，文件大小约 72.6 MB。本设计记录筛选后的证据和修复范围，不把原始设备日志复制进仓库。

## 设备日志确认的执行崩溃

日志时间戳覆盖约 2026-11-25 14:42:48–14:43:40（设备本地时间字段未带时区）。快捷指令运行器记录的动作标识为 `com.healthmi.HealthMi.SyncHealthDataIntent`，并成功启动 HealthMi 主 App。

关键事件顺序：

1. HealthMi 进程 `82628` 在 14:42:53.421 进入 `shortcut.sync.perform.started`，随后在 14:42:53.423 命中活动运行分支 `shortcut.sync.perform.reused_active_run`。
2. App Intents 在 14:42:53.730 校验返回值时明确报错：`Did not declare ProvidesDialog but provided one`。
3. Swift runtime 随即记录 `Fatal error: perform() returned types not declared in method signature`；快捷指令运行器随后报告 XPC 中断和错误码 1004/4099。
4. 约 5 秒后再次触发同一动作。HealthMi 进程 `82730` 的 Core Data 加载记录为 completed，Intent 再次进入活动运行分支，随后再次发生同一 `ProvidesDialog` fatal error。
5. RunningBoard/FrontBoard 记录该 HealthMi 进程以 `signal(2) code=SIGTRAP(5)` 退出；BackgroundShortcutRunner 随后把 `NSCocoaErrorDomain` 4097 作为动作失败返回。

这与当前代码吻合：两个 `perform()` 都声明返回 `some IntentResult`，但所有返回分支都使用 `.result(dialog:)`。该结果类型提供 `ProvidesDialog`，实现签名必须将其声明出来。对话框结果被 App Intents 校验拒绝并触发 Swift fatal error，才是本日志中“无法与帮助程序通信/App 意外退出”的直接代码根因。XPC 1004/4097 是 Intent 承载进程退出后的连带错误。日志没有显示 Core Data 初始化失败；第二次尝试甚至记录了 `coredata.load.completed`。

因此，`SyncHealthDataIntent` 和 `QueryLatestSyncStatusIntent` 都应改为：

```swift
func perform() async throws -> some IntentResult & ProvidesDialog
```

即使本次崩溃日志来自同步动作，查询动作也走相同的对话框返回模式，必须一起修正。

## “查询同步状态”未显示的已知证据与边界

- 上一版 TrollStore IPA 的 `Metadata.appintents/root.ssu.yaml` 中包含 `SyncHealthDataIntent` 与 `QueryLatestSyncStatusIntent` 两个动作及其短语。源码的 `HealthMiShortcuts.appShortcuts` 也声明了两个 `AppShortcut`；所以查询动作并非从源码和构建元数据中遗漏。
- 本次 72.6 MB 日志仅记录执行了 `SyncHealthDataIntent`，未记录用户搜索或运行 `QueryLatestSyncStatusIntent`，因此无法仅靠这份执行轨迹确定 Shortcuts 操作列表为何隐藏查询动作。
- BackgroundShortcutRunner 中两次出现 `ICAppRegistry` 无法加载 `com.healthmi.HealthMi` 的 app definition；相邻 Launch Services 日志把 `-10813` 记为本地数据库相关错误。Apple 将 `-10813` 定义为 `kLSDataUnavailableErr`（所需类型的数据不可用）。此错误可能与 app action 索引/注册有关，但日志没有证明它特指查询动作，也没有阻止系统读取当前同步动作的直接 Intent metadata；不能将它作为缺少查询动作的确定根因。
- 下一版通过应用启动时通知 `HealthMiShortcuts` 更新系统快捷指令参数、统一查询动作标题、增加 `ShortcutsLink` 应用内入口，并提升 build number，让用户能从 HealthMi 直接打开本应用的 App Shortcuts 页面。该组合用于刷新和检查系统发现入口；iOS 16.3 TrollStore 上的最终显示仍须设备复测。

## 实施内容

1. 修正两个 Intent 的返回签名，明确声明 `ProvidesDialog`，保持“快速排队 + 静默执行”行为不变。
2. 为每次 Intent 调用生成独立 invocation ID。日志覆盖进入、队列复用/创建、结果准备、返回前和错误对话框分支，并记录耗时与结果分支。
3. 活动队列复用日志补充 queued 时间、队列年龄和原触发来源；旧运行失效时记录旧状态、年龄和失效阈值。
4. 一键复制日志文本增加 PID 与主线程标记，和详情页已有字段一致。
5. App 启动时调用 `HealthMiShortcuts.updateAppShortcutParameters()` 并记录清单刷新事件；将查询 Intent 标题和 App Shortcut 短标题统一为“查询同步状态”。
6. 在仪表盘增加 `ShortcutsLink`，直达 HealthMi 的 App Shortcuts 页面；提升 `CURRENT_PROJECT_VERSION` 到 2。
7. 更新全面审查报告、iOS 16 适配记录、CHANGELOG，并完成静态差异检查和 GitHub Actions IPA 构建/包结构核验。按用户要求，每个阶段仅在本地 commit；构建推送目标为用户私有仓库 `lu1ul/HealthMi-private`，不推送到原始仓库。

## 验证边界

- GitHub Actions 编译和 IPA 解包可确认 iOS 16 部署目标、App Intents metadata、版本/构建号以及新增 UI 字符串进入产物。
- 当前 Windows 环境无法代替 iPhone 执行 App Intents runtime。必须在 iOS 16.3 TrollStore 上重新运行同步快捷指令，并从 HealthMi 内 `ShortcutsLink` 进入 App Shortcuts 页面，确认查询动作是否出现且可执行。
- 若查询动作仍缺失，需要再捕获 Shortcuts 操作列表打开期间的系统日志，并和新 IPA 的 metadata 一起核对；本次执行日志无法单独完成这项判断。

## 官方资料

- Apple `ProvidesDialog`：https://developer.apple.com/documentation/appintents/providesdialog
- Apple `AppShortcutsProvider` 的系统注册示例：https://developer.apple.com/documentation/appintents/acceleratingappinteractionswithappintents
- Apple `ShortcutsLink`：https://developer.apple.com/documentation/appintents/shortcutslink
- Apple `kLSDataUnavailableErr`：https://developer.apple.com/documentation/coreservices/klsdataunavailableerr

