# 快捷指令直接增量同步设计

日期：2026-11-27  
状态：已按用户“直接开始实施”指示批准；实施中

## 意图

用户运行“同步健康数据”后，无需先打开 HealthMi，也无需让它预先留在后台；快捷指令自身等待增量同步结束，并把实际结果返回给快捷指令。现有快捷指令只创建排队记录并请求 BGAppRefresh，不能保证本次同步启动或结束。

这里的“不需要 App 在后台运行”指不要求用户预先启动或常驻 App。iOS 仍须启动承载 App Intent 代码的执行进程；本实现不要求把 App 界面带到前台。

## 已知实现与约束

- `SyncEngine` 已支持逐数据类型读取 `lastSyncedEnd`，从游标前重叠一天查询，成功后由 `AppModel` 保存该类型游标；普通同步不传 `forceBackfill`。
- `SyncHealthDataIntent` 当前只创建/复用队列、尝试提交 BGTask 并立即返回；本次改为直接调用 `AppModel.syncAll`，不把本次快捷指令交给 BGTask。
- iOS 16 的 App Intent 后台执行时间有限。Apple 文档说明 iOS 后台 Intent 默认约 30 秒；`LongRunningIntent` 从 iOS 27 起提供延长能力，不能用于 iOS 16.3。采用 22 秒内部预算并留出返回结果余量。
- 所有快捷指令运行要求小米账号凭据、本地数据库和 HealthKit 写入权限已提前配置。Intent 后台不主动请求可能弹出界面的 HealthKit 首次授权；缺少授权时返回明确失败记录。
- 不使用 `ProvidesDialog`/`IntentDialog`，避免回归项目之前在 iOS 16.3 出现的 App Intent 返回契约问题；返回 iOS 16 可用的字符串值供后续快捷指令动作读取。

## 实施方案与取舍

### 方案 A：Intent 内直接等待增量同步（选定）

在 `perform()` 中准备数据库、复用或新建运行记录，直接等待现有同步引擎；关闭该路径的授权弹窗和仪表盘摘要查询。快捷指令网络请求无重试、单请求最长 8 秒且受总截止时间约束；逐类检查剩余预算。已完成类型的游标先落盘；时间预算耗尽或单类失败时返回非成功状态及同步记录摘要，用户再次运行即可从已完成类型的游标继续。

优点是本次快捷指令可以等待真实写入结束；不需要已有 App 进程或 BGTask 启动。代价是大回填、慢网络或系统取消可能导致部分完成，iOS 16 不提供无限后台时长。

### 方案 B：保持快速排队

继续使用 BGAppRefresh，在请求后立即返回。它执行很快，但系统决定实际启动时间，不能满足快捷指令结束前确认同步完成的要求；只保留给现有周期后台刷新。

### 方案 C：增加 App Intents Extension

把 Intent 代码移动到独立扩展进程。它仍不能绕过 iOS 16 的后台时间限制，并额外要求共享数据库、Keychain、HealthKit 权限和签名配置；本轮不采用。

## 行为细节

1. `perform()` 记录启动时间并设置 22 秒总截止时间。
2. 若已有 `running` 运行，返回该运行状态且不重复同步；若有 `queued` 运行，直接消费其原运行 ID；否则创建新的 `shortcut` 运行记录。
3. 准备 Core Data 并执行 `AppModel.bootstrap()`，然后用 `forceBackfill: false` 的普通游标路径同步。
4. 快捷指令模式不弹 HealthKit 权限界面、不刷新仪表盘摘要、不提交 BGTask。快捷指令网络请求使用受总截止时间约束的请求超时且不自动重试，以便尽量在系统运行预算内完成更多类别。
5. 每一类完成后按现有流程写 HealthKit/压力本地数据、记录日志和游标。截止时间用完时保留已完成类别结果，并以失败或部分失败返回；未完成类别不前移游标，重跑可安全重试。
6. 返回字符串值而非对话框，包含状态、运行 ID、已完成/失败类别和错误详情；详细历史仍保存在 App 内同步历史与诊断日志。
7. BGAppRefresh 继续独立工作，用于系统择时的周期刷新。

## 非目标

- 不改变 Xiaomi API 协议、数据映射、HealthKit 写入格式、去重算法或游标定义。
- 不改变显式“重新回填”按钮。
- 不声称所有网络条件、首次 30 天回填或任意大量分页都能在 iOS 16 的单次 Intent 时限内结束。
- 不推送到原始 `origin` 仓库；最终 IPA 由用户的 `personal` 私有仓库现有 workflow 构建并用 `gh` 下载。

## 验收与交付

- 保持 iOS 16.0 部署目标并将 `CFBundleVersion` 提升到 6。
- 构建并下载 unsigned IPA 与 TrollStore HealthKit IPA；独立核验最低系统版本、build number、App Intent 元数据、HealthKit/TrollStore entitlement 和 SHA-256。
- 构建结果只能证明编译与 IPA 静态结构。真实 iOS 16.3 Shortcuts 执行速度和系统行为仍需安装后的设备验证；内部 22 秒预算不等于 Apple 对完整任务的保证。

## 官方资料

- App Intents 后台与前台运行模式：<https://developer.apple.com/documentation/appintents/getting-started-with-the-app-intents-framework>
- `openAppWhenRun`：<https://developer.apple.com/documentation/appintents/appintent/openappwhenrun>
- `ReturnsValue`（iOS 16.0+）：<https://developer.apple.com/documentation/appintents/returnsvalue>
- `LongRunningIntent`：<https://developer.apple.com/documentation/appintents/longrunningintent>
- Apple WWDC26 App Intents 2027 更新：<https://developer.apple.com/videos/play/wwdc2026/345/>
