# HealthMi iOS 16 最低版本适配研究与实施记录

> 本文随每个有结论的实施里程碑更新，记录仓库现状、设计决定、变更与验证结果。仅在本地仓库提交，不推送到远程。

## 目标与已确认决定

- 最低部署目标设为 iOS 16.0，同时保留当前同步、HealthKit 写入、快捷指令、后台刷新、压力记录、同步历史、趋势图和 CSV 导出。
- 使用 Core Data 作为所有支持版本的统一本地存储。
- iOS 17 及以上首次启动新版本时，将旧 SwiftData 数据迁移到新的 Core Data store；迁移成功前保留旧库，迁移失败时不得继续使用空库。
- 保留 SwiftData 中的同步游标、压力记录和同步日志。
- 压力数据回填只替换所选时间范围内的记录，并在同一事务中提交。
- 每个可审查的实施里程碑单独本地 commit；不执行 `git push`。

## 仓库现状（2026-11-23）

- `project.yml` 的 iOS 部署目标为 17.0；生成工程 `HealthMi.xcodeproj/project.pbxproj` 中 App Debug/Release 目标也为 17.0；`README.md` 写明 iOS 17.0+，并记录了 XcodeGen 生成流程。
- SwiftData v1 包含三类数据：`SyncState`（同步游标）、`StressRecord`（压力记录）、`SyncLogEntry`（同步日志）。Schema 定义在 `HealthMi/Sync/MigrationPlan.swift`，当前无版本迁移阶段。
- `HealthMi/App/AppModel.swift` 使用 Observation `@Observable`；SwiftUI 视图使用类型化环境注入、`@Bindable` 和 `@Query`。同步快捷指令和后台任务都访问共享 SwiftData 容器。
- `SyncHistoryView` 使用 iOS 17 起的 `ContentUnavailableView`。趋势图使用 Charts；快捷指令使用 App Intents。
- 压力强制回填在 `AppModel` 中调用 `StressStore.clearAll`，会清空所选范围外的全部压力历史；`StressStore.deleteRange` 已存在，可用于范围替换。
- 仪表盘以降序查询全部压力记录，但界面平均值、导出和单日详情都只消费最近 7 天。
- 当前工作区原本有未跟踪文件 `项目分析-优先关注问题.md`；本任务不会覆盖或提交该文件。
- 当前执行环境为 Windows；未找到 `xcodegen`、`xcodebuild` 或 `swift` 命令。因此需要继续完成静态检查和本地提交，并在具备 Xcode 的 macOS 环境执行 iOS 构建与模拟器验证。

## API 兼容性核查

| 组件 | 结论 | 处理 |
|---|---|---|
| SwiftData | iOS 17+ | 保留仅供旧库读取的 legacy schema；产品存储迁到 Core Data |
| Observation `@Observable`、SwiftUI typed environment / `@Bindable` | iOS 17+ | AppModel 改为 `ObservableObject`，视图使用 iOS 16 可用的对象注入 |
| `ContentUnavailableView` | iOS 17+ | 改为普通 SwiftUI 空状态视图 |
| Swift Charts `Chart` | iOS 16+ | 保留 |
| App Intents / App Shortcuts | iOS 16+ | 保留 |
| HealthKit `HKWorkoutBuilder` 异步收集/保存调用 | 原始 API iOS 12+；Swift 并发运行时可回部署到 iOS 13+ | 保留并纳入 iOS 16 构建检查 |

## 实施记录

### 阶段 0：研究记录初始化

- 建立本文件，汇总现状、兼容性结论、用户决定及验证环境限制。
- 验证：确认原有未跟踪的 `项目分析-优先关注问题.md` 未改动、未暂存。
- 本地 commit：`bdc8ed7 docs: 记录 iOS 16 适配研究与实施方案`。

### 阶段 1：Core Data 存储、迁移与调用方转换

- 新增程序化 Core Data 模型，实体覆盖同步游标、压力记录、同步日志和迁移元数据；唯一约束沿用游标类型及压力 externalID。
- 用共享 `NSPersistentContainer` 代替 SwiftData 运行时存储。iOS 17+ 通过原 v1 schema 读取旧库，并将三类记录及导入标记放在一次 Core Data 保存中；保留 SwiftData 源库。数据库准备或迁移失败时，前台显示错误与重试入口，后台任务和快捷指令必须等待准备完成。
- AppModel 改为 `ObservableObject`，视图改用 `@EnvironmentObject` 和 Core Data `@FetchRequest`；空状态改为普通 SwiftUI 视图，预览改用 `PreviewProvider`。
- 压力同步返回 API 请求的日历日边界；成功后只替换该范围，保存失败会回滚；网络或压力记录解析失败时不会触及旧记录。仪表盘的 Core Data 查询增加最近 7 天谓词。
- 更新现有游标存储测试，并增加压力范围替换、畸形压力数据拒绝、SwiftData 导入重试幂等及源库保留检查。
- 静态验证：搜索确认运行时视图不再使用 `@Query`、typed environment、`@Bindable` 或 `ContentUnavailableView`；Core Data 新源文件已加入显式 Xcode 工程；`git diff --check` 无空白错误。
- 构建/测试验证：已尝试 `xcodegen generate` 和 `xcodebuild test -project "HealthMi.xcodeproj" -scheme "HealthMi" -destination "generic/platform=iOS Simulator"`，两者均因当前 Windows 主机没有对应 Apple 工具而无法启动；`swift` 同样不可用，不能在此编译或运行 XCTest。
- 本地 commit：`565cd71 feat: adapt HealthMi storage for iOS 16`。

### 阶段 2：部署目标、项目配置与说明

- 将 XcodeGen 配置和现有工程文件的部署目标改为 iOS 16.0；为新增 Core Data 模型文件加入工程显式源文件列表。因当前没有 XcodeGen，已手动同步现有 `project.pbxproj`。
- 更新 README 的最低系统版本、存储方案与迁移行为。
- 静态验证：`project.yml` 和 `project.pbxproj` 中可见部署版本均为 16.0；README 已注明最低版本和旧数据迁移策略。
- 构建验证：无法在当前 Windows 环境执行；需在 macOS 运行 `xcodegen generate`，再构建 iOS 16 模拟器目标。
- 本地 commit：`565cd71 feat: adapt HealthMi storage for iOS 16`。

### 阶段 3：最终核查

- 检查 iOS 17 API 是否仅用于旧库迁移或已由 iOS 16 可用组件替代；检查压力查询范围、失败回滚、迁移标记与改动文件清单。
- 静态核查：提交前 `git diff --check` 通过；部署版本检查结果为 `project.yml` 与 `project.pbxproj` 均为 16.0；旧分析文档没有出现在暂存清单中。
- 本地 commit：实施代码与配置为 `565cd71 feat: adapt HealthMi storage for iOS 16`；本阶段最终核查记录随本地文档提交保存。
- 远程状态：本地提交，没有执行 push；原有未跟踪的 `项目分析-优先关注问题.md` 仍保留在工作区。
- macOS 后续验收：执行 `xcodegen generate`、iOS 16 部署目标构建及现有 XCTest；在 iOS 17 旧版安装数据上验证三类 SwiftData 数据导入、重试幂等和旧库保留；在 iOS 16 模拟器或真机验证新安装核心功能。
- 本地 commit：待补充。

## 2026-11-25 快捷指令静默排队与详细错误反馈

用户选择保留 `openAppWhenRun = false` 的静默路线，但将完整同步从 App Intent 请求中移出，改为“快速排队 + 后台持久化结果”。

### 已实施内容

- 新增 `HealthMi/Sync/SyncRunStore.swift`：运行记录使用共享 `UserDefaults` 保存最近 30 次运行，状态包括 `queued`、`running`、`succeeded`、`partialFailure`、`failed` 和 `cancelled`。
- 错误保存为域、错误码和描述；已覆盖 `MiAPIError`、`MiLoginError`、Keychain `OSStatus`、HealthKit/系统 `NSError` 和应用前置错误。
- `AppModel.syncAll` 增加可选运行 ID；每类数据成功、失败、取消及顶层前置错误都会写回同一运行记录。
- `BackgroundSync` 领取排队运行；周期刷新没有排队记录时创建后台运行。过期回调和同步完成回调通过一次性门控，避免重复完成同一个 `BGTask`。
- 网络重试和分页等待不再吞掉取消信号；BGTask 过期、URLSession 取消或 Task 取消都会明确标记为 `cancelled`，不会伪装成普通网络失败。
- `SyncHealthDataIntent` 不再等待完整同步，只执行数据库、Keychain、HealthKit 可用性检查，创建排队记录并提交约一秒后的 `BGAppRefreshTaskRequest`。
- 新增 `QueryLatestSyncStatusIntent`，快捷指令可以在稍后读取完整运行文本；后台完成后发送包含成功/失败类型和错误域/错误码的本地通知。
- 同步历史页面增加最近一次后台运行摘要和完整运行 ID。

### 行为限制

- “已排队”只表示请求已写入本地并提交给系统调度，不代表后台同步已经开始；iOS 仍可能延迟启动 `BGAppRefreshTask`。
- 后台产生的网络、登录、HealthKit 或单类数据错误不能回写到已经结束的原快捷指令动作，必须通过通知、同步历史或“查询最近同步状态”读取。
- 当前工作区为 Windows，无法运行 Xcode、`xcodebuild` 或 XCTest；本阶段只完成静态检查和 `git diff --check`。需在 macOS/GitHub Actions 上做 iOS 16 构建验证。

### 本地提交

- `6e9818a docs: design shortcut quick queue and detailed status`
- `0e524ed feat: persist detailed sync run results`
- `75b07f6 feat: queue shortcut sync in background`

### GitHub Actions 首次编译诊断

- run `45520859520`（Xcode 16.4、iOS 16 部署目标）在 Swift 编译阶段失败，尚未进入 IPA 打包。
- `SyncIntent.swift` 的 `CredentialStore.loadThrowing()` 是可抛错调用，必须使用 `try`；已修正。
- `AppShortcutsProvider.appShortcuts` 在 Xcode 16.4 使用结果构建器，多个快捷方式应依次列出 `AppShortcut` 表达式，不能手写 `[AppShortcut]` 数组字面量；已修正。
- 修正后需要重新推送并观察下一次 workflow，确认进入 IPA 打包和 entitlement 校验阶段。

## 官方资料

- [Apple SwiftData 文档](https://developer.apple.com/documentation/swiftdata)
- [Apple Observation 文档](https://developer.apple.com/documentation/observation)
- [SwiftUI `Bindable` 文档](https://developer.apple.com/documentation/swiftui/bindable)
- [SwiftUI `ContentUnavailableView` 文档](https://developer.apple.com/documentation/swiftui/contentunavailableview)
- [Swift Charts `Chart` 文档](https://developer.apple.com/documentation/charts/chart)
- [Apple App Intents 文档](https://developer.apple.com/documentation/appintents)
- [Apple Core Data stack 指南](https://developer.apple.com/documentation/coredata/setting-up-a-core-data-stack)
- [Apple `NSPersistentContainer.loadPersistentStores` 文档](https://developer.apple.com/documentation/coredata/nspersistentcontainer/loadpersistentstores(completionhandler:))
- [Apple SwiftUI `FetchRequest` 文档](https://developer.apple.com/documentation/swiftui/fetchrequest)
- [Apple SwiftData `ModelContainer` 文档](https://developer.apple.com/documentation/swiftdata/modelcontainer)
- [Apple SwiftData `ModelConfiguration.url` 文档](https://developer.apple.com/documentation/swiftdata/modelconfiguration/url)
- [Apple `NSPersistentStoreDescription.shouldAddStoreAsynchronously` 文档](https://developer.apple.com/documentation/coredata/nspersistentstoredescription/shouldaddstoreasynchronously)
- [Apple HealthKit `HKWorkoutBuilder` 文档](https://developer.apple.com/documentation/healthkit/hkworkoutbuilder)
- [WWDC22：What’s new in Swift](https://developer.apple.com/videos/play/wwdc2022/110354/)

## iOS 16.4 模拟器启动故障

- 运行 `45146100153` 使用 Xcode 16.4、iPhone 14、iOS 16.4 runtime；构建、安装和 launch 命令通过，但 20 秒后应用进程退出。
- `.ips` 报告指出 dyld 在启动时找不到 `SwiftData.framework`，引用方为 `HealthMi.debug.dylib`。SwiftData 只用于 iOS 17+ 旧库导入，但 `import SwiftData` 仍让 framework 成为启动时强依赖；仅给迁移类型添加 `@available(iOS 17, *)` 不会解除该链接依赖。
- 已在 XcodeGen 配置与当前工程的 Debug/Release 项目设置中加入 `SWIFT_SKIP_AUTOLINKING_FRAMEWORKS = SwiftData` 和 `-weak_framework SwiftData`。此配置用于让 iOS 16 加载 Core Data 主流程，同时保留 iOS 17+ 旧库导入代码。
- 验证通过：GitHub Actions 运行 `45148900597` 在 Xcode 16.4 / iPhone 14 / iOS 16.4 成功构建、安装和启动，20 秒后进程仍存活；日志确认有弱链接参数且没有崩溃报告。运行 `45149953346` 在 iPhone 16 Pro / iOS 18.5 也成功构建并启动，20 秒后进程仍存活。
- 这次诊断只提取了崩溃类型、DYLD 终止原因及相关镜像名，没有读取健康记录。仍需在有真实旧 SwiftData 库的数据上验证迁移；模拟器启动成功不证明 iOS 16.3 真机或最终签名 IPA 的所有行为。
- 本地提交：诊断结论 `6144017 docs: record iOS 16 simulator crash cause`；弱链接修复 `82fef0f fix: weak link SwiftData for iOS 16`；复测结果本次单独提交。
- 设备版构建验证：修复提交的 push 还触发了 Release IPA 工作流，运行 `45148687288` 成功，生成未签名 IPA。文件 SHA-256 为 `88198DBF1A140E88553CC9A6B2B7584127456888EF23264F5DA80E6027083716`；包内无 `_CodeSignature` 和 provisioning profile。文件位于忽略的 `build/HealthMi-unsigned-ipa-after-ios16-fix/`，需用户用自己的证书签名。
- 资料：[Apple Xcode Build Settings Reference](https://developer.apple.com/documentation/xcode/build-settings-reference)、[Apple Frameworks and Weak Linking](https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPFrameworks/Concepts/WeakLinking.html)。

## 2026-11-24 真机验收与快捷指令后续问题

### 已完成的 iOS 16.3 真机验收

用户使用 GitHub Actions run `45340198351` 生成的 `HealthMi-trollstore-healthkit.ipa`，在 iPhone iOS 16.3 + TrollStore 上完成验证：

- IPA 安装并启动成功；
- HealthKit 授权按钮可以触发系统授权流程；
- 健康 App 中可以出现 HealthMi 来源；
- 小米账号可以登录；
- 小米云端数据可以同步写入 Apple 健康；
- 之前的 Keychain `-34018` 不再出现。

因此，本次 iOS 16 最低版本适配的主流程已经有真机证据支持。原文中关于“尚未在 iOS 16.3 真机验证”的状态属于实施过程记录，当前应以本节结果为准。

### 新发现：快捷指令无法与帮助程序通信

快捷指令中可以找到“同步健康数据”，但执行时显示“无法与帮助程序通信”。当前代码在 `HealthMi/App/SyncIntent.swift` 中将 `openAppWhenRun` 设为 `false`，并在 `perform()` 内直接执行完整同步。该调用会在一次 App Intent 请求中初始化 Core Data、读取 Keychain、登录小米服务、拉取最多九类数据、写入 HealthKit、保存同步游标并刷新摘要，最长等待 55 秒。

初步判断优先级：

1. 帮助进程在动作返回前因执行时间、网络重试、分页或 HealthKit 写入开销被系统终止；
2. 帮助进程初始化 Core Data 或访问安全存储时抛出未包装异常；
3. App Intent 执行上下文中的 Keychain/HealthKit 权限与主 App 路径存在差异；
4. 动作成功后额外刷新摘要、查询通知权限，扩大了帮助进程的执行窗口。

IPA 已包含 `Metadata.appintents`，因此这不是动作注册失败。旧提交 `fa08a1c` 的快捷指令只设置触发标记并打开主 App，当前版本将完整同步移入 `openAppWhenRun = false` 的帮助进程，这一执行模型变化是最重要的回归线索。

当前未修改代码，等待选择修复路线：

- **可靠路线：**恢复 `openAppWhenRun = true`，由主 App 执行已经验证成功的同步流程；
- **静默路线：**保留 `openAppWhenRun = false`，将 Intent 改为快速提交任务，完整同步交给后台任务，并返回“已排队/已完成/失败”的明确状态。

详细分析、证据和最小化实验步骤见 `HealthMi项目代码全面审查报告.md` 第 9.14 节。
