# HealthMi iOS 16 最低版本适配研究与实施记录

> 本文随每个有结论的实施里程碑更新，记录仓库现状、设计决定、变更与验证结果。每个阶段先本地提交；为用户要求的 IPA 构建仅推送到个人私有仓库 `lu1ul/HealthMi-private`，不推送到原始仓库。

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

### GitHub Actions 成功构建与 IPA 核验

- workflow run：`45521059911`，提交 `e1e4322`，Xcode 16.4，部署目标 iOS 16.0。
- 构建结果：Swift 6 编译、unsigned IPA 打包、TrollStore HealthKit entitlement 注入和二次校验全部成功。
- TrollStore IPA：`build/HealthMi-trollstore-shortcut-queue-45521059911/HealthMi-trollstore-healthkit.ipa`。
- IPA SHA-256：`34BCB4FCD0CD0CA98140E05CE11EF44828A6D658C34C6224B5731BDB3DB44D9A`。
- 主程序 SHA-256：`F6D5157C0C63CF725432771C0979D8662FB06137CF08D966025A9C30FF4C82C5`。
- entitlement：存在 `LC_CODE_SIGNATURE`、`com.apple.developer.healthkit=true`、TrollStore `keychain-access-groups` 和 `get-task-allow`；无 `embedded.mobileprovision`，符合 TrollStore 路线。
- App Intents 元数据：`Payload/HealthMi.app/Metadata.appintents/root.ssu.yaml` 同时包含 `SyncHealthDataIntent_0`（同步健康数据）和 `QueryLatestSyncStatusIntent_1`（查询最近同步状态）。
- 本地使用 `gh run download` 获取产物，未使用浏览器下载。

### iOS 16.3 真机上仍出现帮助进程退出

安装 run `45521059911` 的 IPA 后，快捷指令仍先出现“无法与帮助程序通信”，再次运行时提示“无法进行操作，因为 App 意外退出”。

Apple 后台任务文档说明：

- `BGTaskScheduler.submit` 提交的必须是已经注册的后台任务；
- 每个标识符只能注册一次，同一进程第二次注册会导致系统终止 App；
- 所有 launch handler 必须在应用启动结束前注册完成。

当前修复据此移除 App Intent 中的 Core Data、Keychain 和 HealthKit 初始化。它们都可能依赖完整 App 启动环境，而且不应出现在轻量排队动作里。App Intent 现在只写 `UserDefaults` 运行记录；只有当前进程已确认 BGTask handler 注册成功时才提交立即调度，否则等待 App 启动时已经排定的周期任务。

资料：

- [Apple `BGTaskScheduler.register`](https://developer.apple.com/documentation/backgroundtasks/bgtaskscheduler/register(fortaskwithidentifier:using:launchhandler:))
- [Apple `BGTaskScheduler.submit`](https://developer.apple.com/documentation/backgroundtasks/bgtaskscheduler/submit(_:))

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

## 2026-11-25 最新静默排队版本：GitHub 构建与 IPA 独立核验

### 构建结果

- 远程仓库：`lu1ul/HealthMi-private`
- GitHub Actions run：`45522292408`
- 提交：`ab414c15773a7ba7a50c61d4dd2f3c4e3a4aad32`（`fix: make shortcut queue independent of app launch`）
- Runner：`macos-15`，Xcode 16.4，部署目标 iOS 16.0
- 结果：成功。Swift 编译、XcodeGen 工程生成、unsigned IPA、TrollStore IPA、entitlement 注入和解包后二次校验全部通过。
- 下载方式：使用 `gh run download 45522292408 --repo lu1ul/HealthMi-private`，未使用浏览器。

### IPA 文件与校验值

- TrollStore IPA：`build/HealthMi-trollstore-shortcut-queue-45522292408/HealthMi-trollstore-healthkit-ipa/HealthMi-trollstore-healthkit.ipa`
- TrollStore IPA SHA-256：`885ACBCA4A3E90EB4468D4A5321C4248F5FA23350475412E8B856857B034879B`
- unsigned 对照 IPA：`build/HealthMi-trollstore-shortcut-queue-45522292408/HealthMi-unsigned-ipa/HealthMi-unsigned.ipa`
- unsigned IPA SHA-256：`057242D2975FDDCF2FEF9466296E6523C3166F474EDF7AA6957E351146F867F4`

### 本地解包检查

对 TrollStore IPA 解包到 `build/ipa-inspect-45522292408/` 后，确认：

- `Payload/HealthMi.app/HealthMi` 存在；
- `Metadata.appintents/root.ssu.yaml`、`version.json` 和动作元数据存在；
- `root.ssu.yaml` 包含 `SyncHealthDataIntent_0`（同步健康数据）和 `QueryLatestSyncStatusIntent_1`（查询最近同步状态）；
- `Info.plist` 的 `MinimumOSVersion` 为 `16.0`；
- `CFBundleIdentifier` 为 `com.healthmi.HealthMi`，版本为 `1.1.0`；
- `BGTaskSchedulerPermittedIdentifiers` 包含 `com.healthmi.HealthMi.sync`；
- `UIBackgroundModes` 包含 `fetch`；
- HealthKit 读写用途说明均存在；
- `LC_CODE_SIGNATURE` 存在；
- `com.apple.developer.healthkit = true`；
- TrollStore 所需 `application-identifier = TROLLTROLL.*`、`com.apple.developer.team-identifier = TROLLTROLL`、`get-task-allow = true` 和 `keychain-access-groups = [TROLLTROLL.*, com.apple.token]` 均存在；
- 包内没有 `embedded.mobileprovision`，符合当前 TrollStore 伪签名产物路线。

### 结论与真机步骤

这次构建已经证明最新源码进入了可安装 IPA，且包级别同时具备 HealthKit 和 TrollStore Keychain entitlement。它不能在 Windows 上替代 iOS 16.3 真机对快捷指令帮助进程、BGTask 实际调度和系统回收行为的验证。

安装测试应使用上述 `HealthMi-trollstore-healthkit.ipa`，不要使用 unsigned 对照包。为避免旧 App Intent 元数据和旧运行记录干扰，建议先删除旧版 HealthMi，安装新包后打开主 App 一次，确认账号和 HealthKit 仍可用，再从 HealthMi 重新添加“同步健康数据”和“查询最近同步状态”两个动作。快捷指令动作预期立即返回“已排队”，同步完成后再通过查询动作或通知读取结果。

若新包仍显示“无法与帮助程序通信”或“App 意外退出”，下一步必须收集 iPhone 的 `HealthMi-*.ips` 或 `Shortcuts-*.ips`，重点查看 `Exception Type`、`Termination Reason` 和崩溃线程；静态代码和 IPA 包级分析已经不足以判断下一层原因。

独立解析最终 IPA 的 Mach-O 签名 SuperBlob 后，确认 entitlement blob 中包含上述 HealthKit、TrollStore application/team identifier、`get-task-allow` 与 Keychain access groups。主程序 SHA-256：`7d7171b55d8ed693355d8b3eccc073718d73e4495fb584e01d358d088494d300`。

## 2026-11-25 应用内诊断日志、复制和查看器

### 已完成源码

- 已加入应用内诊断日志页面：仪表盘“问题诊断”入口打开独立日志查看页，支持按关键字搜索、级别/分类筛选、仅看警告和错误、逐条详情查看、刷新和清空确认。
- 用户要求的一键复制已经实现：按钮将当前筛选结果复制为脱敏纯文本并显示复制条数；复制上限为最近 10,000 条，界面列表显示最近 2,000 条。
- 文件导出继续保留：导出独立 JSON 诊断包，包含全部保留日志和最近同步摘要，文件名使用 UTC 时间与唯一 ID，通过系统分享面板交给用户选择目标。
- 埋点覆盖应用启动、存储迁移、Keychain、小米登录、HealthKit 授权状态/摘要/趋势/写入、API 状态/重试/分页、同步过程、快捷指令、后台任务、通知与导出。日志不含凭据、Cookie、请求/响应正文或健康样本值。
- JSONL 文件日志位于 Application Support，排除备份，使用文件保护；单文件最多 2 MiB，总容量最多 20 MiB，保留 14 天。写入通过串行后台队列执行，App Intent 返回和 BGTask 完成前会 flush。
- 设计与用户新增的复制/查看要求分别记录于 `docs/superpowers/specs/2026-11-25-diagnostic-logging-design.md` 和此前设计补充提交中。

### 本地验证与限制

- `git diff --check` 已通过；未运行 XCTest。当前 Windows 环境没有 `swift` 或 `xcodebuild`，需要 GitHub Actions Xcode 16.4 Release build 验证 iOS 16 编译。
- `gh auth status` 确认登录账号为 `lu1ul`。为生成 IPA，当前阶段会按既有授权推送到 `lu1ul/HealthMi-private`，绝不推送到 `ShawnDiego/HealthMi`。
- 日志查看/复制/导出界面实现提交：`db32c9e`；详细埋点提交：`176c2d0`；README、CHANGELOG 和设计/实施记录已在 `8e34e73` 等文档提交中同步。
- 初次记录时 IPA 构建与解包核验尚未完成；最终 GitHub Actions 构建和 IPA 核验结果见下方“日志功能构建与产物核验”。

### GitHub Actions 构建排错记录（2026-11-25）

- 日志功能提交后首次构建 run `45547199421` 在 Swift 编译阶段因调用不存在的 `URL.setResourceValue` 失败；改用 `URL.setResourceValues` 后，第二次 run `45547761743` 因 URL 参数不可变而失败。
- 失败位置为 `HealthMi/Support/DiagnosticLogging.swift`：`URL.setResourceValues(_:)` 是 mutating 方法，而方法参数 `url` 默认不可变。修复为接收初始 URL 后复制到局部 `var url`，再设置排除备份属性。
- 修复提交：`9c0ac3c fix: make diagnostic log URLs mutable`。最终构建结果和 IPA 校验已由 run `45548504889` 验证，见下一节；整个流程只推送至 `lu1ul/HealthMi-private`，没有推送 `origin`。

### 日志功能构建与产物核验（2026-11-25）

- GitHub Actions run `45548504889`（Xcode 16.4，macOS runner，iOS deployment target 16.0）成功完成。Release 编译、unsigned IPA 打包、TrollStore entitlement 注入、IPA 解包复核和两个 artifact 上传步骤全部通过。构建源码提交为 `9c0ac3c7f03b5c044a3df4eebf4e1c04cba03017`。
- 两个产物均通过 `gh run download` 下载到仓库忽略目录 `build/diagnostic-logging-45548504889/`；未使用浏览器。TrollStore 包大小 2,089,000 字节，SHA-256 `7C3E631F099FB131865D712199F3CBBAE6B5A6BC48803B1982AE4D4295788B8D`；unsigned 包大小 2,030,601 字节，SHA-256 `9BC35A0F15D067087A8DE60D41C2CF0F74FB56AF0118B2B522E8ACF59567B7EF`。
- 对两个 IPA 本地解包检查确认：`MinimumOSVersion=16.0`、Bundle ID `com.healthmi.HealthMi`、版本 `1.1.0`；HealthKit 用途说明、后台任务标识与 `fetch` 模式存在；`Metadata.appintents` 存在，并含“同步健康数据”和“查询最近同步状态”动作元数据。主程序中也能找到诊断日志页面、复制按钮和 JSON 文件导出的界面文本。
- TrollStore artifact 的工作流 entitlement 报告确认 `LC_CODE_SIGNATURE` 存在、HealthKit entitlement 为 true、TrollStore application/team identifier、`get-task-allow` 与 Keychain access groups 已注入，且无 `embedded.mobileprovision`。该包主程序 SHA-256 为 `13A2260C8800EFBD17E60B86114009B85974B99D38BC7E7D461E30AE5A48FE6D`。unsigned IPA 保持未签名用途，供后续自行签名路线使用。
- 本次验证覆盖云端编译和包结构，不等同于 iPhone 真机运行验证；诊断页面交互、日志实际采集、复制/分享和 iOS 16.3 真机行为仍需设备验证。

### iOS 16.3 快捷指令日志复核（2026-11-25）

用户提供的 2026-11-25 06:16:55Z–06:17:24Z 设备日志显示，快捷指令三次进入 `perform()`，均复用了同一个状态为 `queued` 的运行记录；两次应用启动均成功注册 BGTask handler，并检测到待处理队列、成功提交调度请求，但日志中没有后台 handler 开始或领取队列的记录。现有证据表明问题已越过“快捷指令动作未运行”阶段，停在队列派发/执行，或 Intent 结果返回边界，尚不能仅凭此日志确认系统报错根因。

诊断日志需要补强：一键复制文本应包含结构化日志已有的 PID/主线程字段；每次 Intent 需要独立调用 ID 和明确的结果准备/返回前事件；队列复用日志应记录排队时间、年龄和触发来源。详细证据与代码路径分析见《HealthMi项目代码全面审查报告.md》9.22 节。此次仅更新分析文档，没有修改程序行为，也没有生成新 IPA。

## 2026-11-25 快捷指令仍提示通信失败/应用退出：根因重排

用户反馈最新快捷指令仍显示“无法与帮助程序通信”，再次执行出现“因为 App 意外退出”。路线二已经把同步 Intent 主体缩减为轻量运行记录和可选 BGTask 提交；因此此前“Intent 直接执行九类完整同步导致超时”的解释不能再作为主结论。

代码检查发现：

- Intent 在 `UserDefaults` 中写入 `.queued` 记录后才可能提交 `BGAppRefreshTaskRequest`；第二次运行如果能读取到 `.queued`，会走已有任务分支，不再提交新的 BGTask。
- `HealthMiApp.init()` 直接注册 BGTask handler；项目没有显式 `UIApplicationDelegateAdaptor` 启动回调。Apple 当前的传统 `BGTaskScheduler.register(forTaskWithIdentifier:using:launchHandler:)` 文档要求在 `applicationDidFinishLaunching(_:)` 结束前完成注册，并说明重复注册同一标识符会导致系统杀 App。SwiftUI App 初始化是否在 iOS 16.3 所有相关启动路径满足时限，需要用设备 `.ips` 确认。
- 项目没有独立 App Intents extension target。Apple 文档说明 Intent 可在 App 前台或后台运行；仅当 Intent 类型放在 app extension 时才明确是与主 App 分开的扩展进程。因此 `openAppWhenRun = false` 不能单独证明当前 Intent 一定运行在“帮助进程”。
- 当前 Intent 的 `do/catch` 会将普通 Swift 错误转成对话。通用通信错误或“App 意外退出”更符合未捕获的系统级终止、Intent 入口/返回阶段异常，或 Intent 提交后异步 BGTask 的独立崩溃；但缺少 `.ips` 时无法判定具体代码位置。

优先执行的设备区分实验：先单独运行“查询最近同步状态”，记录它能否执行及显示的运行状态；若显示“已排队”，说明首次触发至少写入过队列，调查重点转向排队后的 BGTask 提交、后台执行或结果返回；若查询动作本身也崩，则优先查冷启动、App Intents runtime 和共享状态读取。随后从 iPhone“设置 → 隐私与安全性 → 分析与改进 → 分析数据”导出故障时间附近的 `HealthMi-*.ips`、`Shortcuts-*.ips` 或 `AppIntents-*.ips`，重点看进程名、`Exception Type`、`Termination Reason` 和崩溃线程。

这次只更新诊断，不改变静默执行路线。正式修复须按 `.ips` 定位；若报告不可获得，下一版应使用只返回固定文本的最小 Intent 探针，再逐步恢复 UserDefaults 与 BGTask 步骤。详细控制流、假设排序和验证步骤见 `HealthMi项目代码全面审查报告.md` 第 9.18 节。

Apple 官方来源：

- [Creating your first app intent](https://developer.apple.com/documentation/appintents/creating-your-first-app-intent)
- [`openAppWhenRun`](https://developer.apple.com/documentation/appintents/appintent/openappwhenrun-223b1)
- [`BGTaskScheduler.register`](https://developer.apple.com/documentation/backgroundtasks/bgtaskscheduler/register%28fortaskwithidentifier%3Ausing%3Alaunchhandler%3A%29)

## 2026-11-27 快捷指令直接增量同步设计

已根据用户要求启动实施：快捷指令将直接调用现有增量同步引擎并等待运行结果，不再把该次动作仅作为 BGAppRefresh 队列请求。Intent 仍不打开前台界面；iOS 会临时启动执行 Intent 所需的后台进程，因此不需要 App 事先运行或常驻后台。

iOS 16 的 App Intent 后台执行受系统时限约束；Apple 文档当前说明可延长后台时间的 `LongRunningIntent` 从 iOS 27 起提供，不能用于最低支持 iOS 16 的构建。设计采用 22 秒应用内预算、快捷路径单请求最多 8 秒、不自动重试、在每个类别之间检查预算，并跳过不必要的 HealthKit 授权请求和仪表盘摘要查询。每类同步已有独立游标，已完成类别先提交；未完成类别不前移游标，后续再次运行可继续/重试。

若没有凭据或需要首次 HealthKit 授权，快捷指令不尝试弹出交互界面，而以明确失败返回。首次无游标类别仍按现有默认回填窗口执行，可能较慢；超出预算时明确报告部分完成。22 秒为实现选择的保护预算，不是 Apple 对 Intent 完成时间的保证。方案、权衡和实施步骤见 `docs/superpowers/specs/2026-11-27-shortcut-direct-incremental-sync-design.md` 与 `docs/superpowers/plans/2026-11-27-shortcut-direct-incremental-sync.md`。

官方资料：

- [Creating your first app intent](https://developer.apple.com/documentation/appintents/creating-your-first-app-intent)
- [`openAppWhenRun`](https://developer.apple.com/documentation/appintents/appintent/openappwhenrun)
- [`ReturnsValue`](https://developer.apple.com/documentation/appintents/returnsvalue)
- [`LongRunningIntent`](https://developer.apple.com/documentation/appintents/longrunningintent)
- [WWDC26 App Intents 2027 更新](https://developer.apple.com/videos/play/wwdc2026/345/)

## 2026-11-25 build 3 快捷指令兼容修复记录

### 代码检查与决定

build 2 的 iOS 16.3 真机日志明确出现 `Did not declare ProvidesDialog but provided one`，尽管源码已声明 `some IntentResult & ProvidesDialog`。因此 build 3 移除两个 Intent 的对话框返回能力，统一返回 `some IntentResult` 和 `.result()`。快捷指令不直接显示状态文字；查询、失败原因和同步结果仍由 App 内同步历史、通知与诊断日志提供。

活动任务复用逻辑现对 `.queued` 记录重提立即后台调度请求，不创建重复运行；如果当前 Intent 进程没有注册 handler，记录 deferred 状态；若提交失败，保存原 queued 记录并记录错误。`.running` 任务不重复调度。24 小时 stale 阈值保留，避免把 iOS 后台刷新被系统延迟执行误判成短期失败。请求提交成功不能作为 handler 已启动的证据。

### 变更及本阶段验证

- `HealthMi/App/SyncIntent.swift`：删除 `ProvidesDialog`、`IntentDialog`、`.result(dialog:)` 和对应对话框文案；添加 queued 重调度与结构化日志；状态查询描述改为说明详细结果在 App 内查看。
- `HealthMi/Sync/SyncRunStore.swift`：更新 `dialogText` 注释，明确其用于本地通知与同步历史。
- `project.yml`：版本为 `1.1.0 (3)`，最低部署目标仍为 iOS 16.0。
- `rg` 静态扫描确认快捷指令源码中无 `ProvidesDialog`、`IntentDialog` 或 `.result(dialog:)`；`git diff --check` 通过。GitHub Actions run `45579734642` 使用 Xcode 16.4 成功构建，两个 IPA 的包内版本、最低系统版本和动作 metadata 均已检查；详见《HealthMi项目代码全面审查报告.md》9.27 节。该构建不替代 iOS 16.3 设备运行验证。
- 本地源码提交：`5a89e82`、`62c0694`、`f25d3a2`；Actions 构建源码提交：`9f28829174af7a4d4a14eca426e81157530ba6e9`。IPA 路径和哈希见全面审查报告 9.27 节。

### 验收边界

GitHub Actions run `45579734642` 已成功并通过 IPA 静态核验，TrollStore entitlement 报告也通过。用户安装后还需删除旧快捷指令动作、重建动作，再检查系统日志中没有 `ProvidesDialog` fatal / `SIGTRAP`，并查看新的 queued reschedule 事件。BGTask 是否真正启动仍需观察 `background.handler.started` 或运行状态变化。

## 2026-11-25 App Intents 返回契约与快捷指令发现入口

用户从 iPhone iOS 16.3 + TrollStore 收集的 `pymobiledevice3` 系统日志直接指出：App Intents 返回 `.result(dialog:)` 后，运行时发现 `perform()` 签名未声明 `ProvidesDialog`；随后 Swift runtime fatal error，进程以 `SIGTRAP(5)` 退出，Shortcuts runner 才报告 XPC 1004/4097。两个 Intent 已改为 `some IntentResult & ProvidesDialog`。Apple `ProvidesDialog` 文档和官方 App Intent 模板均要求方法签名表达这项返回能力。

同一日志中 Core Data 已成功加载；因此该故障的直接代码根因不是 TrollStore entitlement 或数据库，而是 Intent 返回类型契约。

查询动作未显示是独立问题：上一版 IPA 的 App Intents `root.ssu.yaml` 有同步和查询两个动作，但本次运行日志只执行同步动作，不能单独说明 Shortcuts 列表为何隐藏查询动作。下一版在 App 启动时调用 `HealthMiShortcuts.updateAppShortcutParameters()`、将查询标题统一成“查询同步状态”、在仪表盘增加 `ShortcutsLink` 并把 build number 提升至 2，用于刷新和直达系统 App Shortcuts 页面；iOS 16.3 TrollStore 上仍需真机检查最终索引展示。

日志采集增强包括 invocation ID、Intent 结果准备/返回前事件、队列年龄/来源、stale 运行迁移细节，以及复制文本内的 PID/主线程标记。源码提交为 `9ad9c87`、`8846299`、`41390eb`；完整设备日志分析和设计见 `HealthMi项目代码全面审查报告.md` 9.23–9.24 节和 `docs/superpowers/specs/2026-11-25-shortcut-return-and-discovery-fix-design.md`。

参考 Apple 官方资料：

- [App Intents `ProvidesDialog`](https://developer.apple.com/documentation/appintents/providesdialog)
- [在 App 初始化时更新 App Shortcuts](https://developer.apple.com/documentation/appintents/acceleratingappinteractionswithappintents)
- [`ShortcutsLink`](https://developer.apple.com/documentation/appintents/shortcutslink)

GitHub Actions run `45567273417` 已成功，构建源码 SHA 为 `14a61fd636dcb18f13defa3213c606910fe64fa2`。TrollStore IPA：`build/shortcut-return-fix-45567273417/HealthMi-trollstore-healthkit-ipa/HealthMi-trollstore-healthkit.ipa`，SHA-256 `21C14D8CBEC6C54A5C5087FC7F5141CBD87BF2291B9F77E3DD9728D85942FD48`；unsigned 对照 IPA：`build/shortcut-return-fix-45567273417/HealthMi-unsigned-ipa/HealthMi-unsigned.ipa`，SHA-256 `6982A2ECD0A6B9AB985E8F813F1C14930FA1F949CCC4A838C8AE82A4B84FA9FA`。两个包均静态核验为 build 2、最低系统版本 16.0，并含同步和查询 Intent metadata。TrollStore 包的 HealthKit entitlement、TrollStore 标识和 Keychain access groups 也已核验。

包级构建验证已经完成，但之后的 iOS 16.3 TrollStore 复测失败：build 2 系统日志再次报告 `Did not declare ProvidesDialog but provided one`，HealthMi 以 `SIGTRAP(5)` 退出。详见下方新日志分析；不能把返回类型修正视为已在真机修复。

## 2026-11-25 build 3 iOS 16.3 快捷指令首轮复测

用户提供的 HealthMi 应用内日志显示 iOS `16.3 (20D47)`、应用 `1.1.0 (3)`、PID `83334`。快捷指令在 `2026-11-25 09:04:00Z` 创建运行 ID `A52E4AA5-0E8C-4414-868D-6B5FAA0DF6EC`，状态为 `queued`，并提交 `BGAppRefreshTaskRequest`；`background.schedule.completed` 与 `scheduledImmediately=true` 均记录成功，`SyncHealthDataIntent.perform()` 到达 `result_prepared` 和 `returning`，日志中没有 `.perform.failed`。设备本地显示时间为 17:04，与 UTC +08:00 一致。

这证明 build 3 的“同步健康数据”Intent 本次已成功完成排队并正常返回，截取内容没有复现此前 `ProvidesDialog` fatal/SIGTRAP。它**不证明同步已开始或成功**：日志中没有 `background.handler.started`、`background.run.claimed`、`sync.run.started` 或该运行 ID 的完成事件。因此同步历史显示“已排队”是快速排队设计下的即时状态；只有之后出现 `running` 和终态，才能判定后台同步结果。`earliestBeginDate=1 秒` 不是保证启动时间。

本次同一 PID 后续进入 active 并执行仪表盘 HealthKit 摘要/趋势查询。HRV 查询有 `com.apple.healthkit/11` 错误，但事件 `run=-`，不属于上述同步运行。该日志也没有用户报告的 `FBSOpenApplication Code=5` 系统日志文本，不能确认 Code 5 与本次排队调用属于同一次事件。

### 入口与两个 App Intent 的区别

- 仪表盘“快捷指令”按钮是 SwiftUI `ShortcutsLink`，用途是打开系统快捷指令 App 中 HealthMi 的 App Shortcuts 页面；它不是可在快捷指令动作列表中添加或执行的第三个动作。日志记录了 `shortcut.discovery.link.tapped`，随后 HealthMi 进入 background，行为符合页面跳转。
- “同步健康数据”是 `SyncHealthDataIntent`：写入/复用运行记录、提交后台刷新请求、立即以无对话框结果返回。
- “查询同步状态”是 `QueryLatestSyncStatusIntent`：读取最近同步记录并写日志，但当前也只返回无内容的 `.result()`，快捷指令本身不会显示状态文本。详细状态需在 HealthMi 同步历史/诊断页查看。
- build 3 源码和 IPA App Intents metadata 都包含同步与查询两个 Intent；但 iOS 16.3 用户实际在“添加操作 → App → HealthMi”只看到同步动作。该动作发现差异不是设计目标，原因仍未确定；应用启动时确有 `updateAppShortcutParameters()` 调用，但包内 metadata 不能证明设备 runtime 已完成索引。

FBS 错误文本的目标是 `com.healthmi.HealthMi`，而 `ShortcutsLink` 的目的地是系统快捷指令 App；本次应用诊断日志没有对应 FBS/XPC 事件，也没有显示当前进程崩溃。因此不能仅凭错误文本把它归因于页面链接，需用错误发生时间附近的 `pymobiledevice3` 系统日志与具体操作、进程号进行关联。

参考 Apple 官方资料：[`ShortcutsLink`](https://developer.apple.com/documentation/appintents/shortcutslink)、[`AppShortcutsProvider`](https://developer.apple.com/documentation/appintents/appshortcutsprovider)、[`BGTaskRequest.earliestBeginDate`](https://developer.apple.com/documentation/backgroundtasks/bgtaskrequest/earliestbegindate)。该属性定义最早运行时刻，系统不承诺按此时刻启动任务。

## 2026-11-25 build 3 系统日志二次关联：同步动作成功，入口发现连接失败

用户提供 `D:\debug\shortcut-debug-4.jsonl` 和对应应用日志，设备运行 build `1.1.0 (3)`。系统日志先记录 `ShortcutsLink` 成功打开 `com.apple.shortcuts`（17:17:16.452 发起，17:17:16.573 成功）；Shortcuts 随后在 `17:17:18.520` 检索 HealthMi action/phrase，`linkd` 通过 `LNEmbeddedApplicationConnection` 尝试连接 HealthMi，但在 `17:17:18.535` 收到 FBS Code 5 / XPC Code 3，Shortcuts 同时记 `Unable to run Auto Shortcut`。这与快捷指令发现/入口加载过程相关，不是后来同步 `perform()` 的错误。

`17:17:29.566`，BackgroundShortcutRunner 对同步动作再次打开 HealthMi 成功，`SyncHealthDataIntent` 开始并复用运行 `A52E4AA5-0E8C-4414-868D-6B5FAA0DF6EC`；应用日志确认该 run 仍 queued、年龄 808 秒，并成功重提 BGTask 请求。系统日志确认 operation/action/workflow 均完成，`RunActionFinish` 和 `RunShortcutFinish` 为 `completed=1`，workflow `success: yes`，输出 0 项符合无值 `.result()`。本次没有 `ProvidesDialog` fatal 或 SIGTRAP。

因此：“同步健康数据”快捷指令本身在 Shortcuts 框架中运行成功，但只成功排队；后台 handler 启动和同步结果仍未知。`17:17:48.531` 的 `LNConnectionErrorDomain Code=1002 RequestTimeout` 发生在 discovery Code 5 后约 30 秒、同步 operation 成功结束后约 19 秒，比较像先前发现连接的延迟超时清理；系统隐藏连接标识，暂不能完全确认。系统记录中的 “There was a problem running the shortcut.” 是 `CFBundle` 对本地化字符串的 DEBUG 查询，而同一 workflow 明确 success，因此不能把这个字符串单独当作失败。

这次系统证据强化“App Shortcuts 发现/入口连接”和“运行已有 SyncHealthDataIntent”是两个路径：前者失败，后者成功。查询动作未显示可能与发现异常同域，但系统隐藏 phrase，不能证明 FBS 错误具体对应 `QueryLatestSyncStatusIntent`。详细时序见《HealthMi项目代码全面审查报告.md》9.29 节。

## 2026-11-25 build 2 新设备日志分析：返回契约仍崩溃

用户提供 `D:\debug\shortcut-debug-3.jsonl`（约 164 MB）以及 App 内日志文本。设备侧确认运行版本 `1.1.0 (2)`、iOS 16.3 (20D47)。App 内日志为 UTC，系统日志时间按设备本地时钟显示。系统 JSONL 第 78055–78056 行在 `15:45:49.635` 记录 App Intents 返回类型错误与 fatal error；第 82173、82194 行在 `15:45:49.745` 记录 PID `82873` 以 `SIGTRAP(5)` 退出。第 159364–159380 行在 `15:45:56.497–.498` 由 `linkd` 和 Shortcuts 记录 FBS open Code 5 / XPC Code 3 / Unable to run Auto Shortcut。

时间顺序表明 Code 5 是 HealthMi fatal 退出之后的打开/连接响应失败；首先要处理的仍是 `ProvidesDialog` runtime 契约错误，而不是单独修 FBS 或 XPC。

虽然源码签名已改为 `some IntentResult & ProvidesDialog`，build 2 使用 Xcode 16.4 并通过 Actions 构建，IPA 含 App Intents metadata 和相关框架符号，真机仍然认定 perform 未声明 `ProvidesDialog`。`root.ssu.yaml` / `extract.actionsdata` 的包检查不包含可直接确认 perform 返回能力的字段；此前包级检查不足以证明设备 runtime 正确识别返回签名。原因仍待区分：设备上的旧动作/定义缓存，或当前构建与 iOS 16.3 App Intents runtime 对返回能力的处理不一致。

同一 App 日志还揭示一个独立队列问题：多个调用都复用 `run=3AC440E1`、状态 `queued`，队列年龄约 24,521–24,564 秒（约 6 小时 48 分–6 小时 49 分）。代码对 queued 记录采用 24 小时 stale 阈值。启动时虽然成功提交 BGTask request，但日志没有 handler 启动或 run claimed 事件；复用活动队列的快捷指令分支也不重新提交立即调度。建议将 queued 失效时限缩短到 10–15 分钟初值，并在复用旧 queued 记录时重新调度或先结束旧记录再创建新任务。

下一版建议先做无对话框返回的最小兼容验证：两个 Intent 返回 `.result()`，不再提供 `ProvidesDialog`，保持静默快速排队；详细结果先通过同步历史、诊断日志和通知读取。若查询动作需要向快捷指令后续步骤输出文本，可另行评估 `ReturnsValue<String>` 并做真机验证。重新打包后删除旧快捷指令动作，干净重装新 build，并通过系统日志确认不再出现 ProvidesDialog fatal / SIGTRAP；随后单独验收队列能否从 queued 前进。

日志中的 Core Data load、Keychain 凭据读取、HealthKit available 和通知授权均成功；HRV 统计 `com.apple.healthkit/11` 没有同步 run ID，与快捷指令进程崩溃无直接关联。BackgroundShortcutRunner 的 `ICAppRegistry` / `-10813` 是动作发现警告，可能与查询动作可见性相关，但本日志不证明它是本次崩溃根因。

本次只更新诊断文档，没有改源码、生成 build 3 或声称已修复。原始设备系统日志没有复制进仓库。
