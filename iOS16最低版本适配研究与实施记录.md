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
- 本地 commit：将在阶段 3 记录。

### 阶段 2：部署目标、项目配置与说明

- 将 XcodeGen 配置和现有工程文件的部署目标改为 iOS 16.0；为新增 Core Data 模型文件加入工程显式源文件列表。因当前没有 XcodeGen，已手动同步现有 `project.pbxproj`。
- 更新 README 的最低系统版本、存储方案与迁移行为。
- 静态验证：`project.yml` 和 `project.pbxproj` 中可见部署版本均为 16.0；README 已注明最低版本和旧数据迁移策略。
- 构建验证：无法在当前 Windows 环境执行；需在 macOS 运行 `xcodegen generate`，再构建 iOS 16 模拟器目标。
- 本地 commit：将在阶段 3 记录。

### 阶段 3：最终核查

- 检查 iOS 17 API 是否仅用于旧库迁移或已由 iOS 16 可用组件替代；检查压力查询范围、失败回滚、迁移标记与改动文件清单。
- 待完成：工作区差异与工程文件结构复核；本地提交；提交后确认原有分析文档仍未改动、未提交且远程无 push。
- macOS 后续验收：执行 `xcodegen generate`、iOS 16 部署目标构建及现有 XCTest；在 iOS 17 旧版安装数据上验证三类 SwiftData 数据导入、重试幂等和旧库保留；在 iOS 16 模拟器或真机验证新安装核心功能。
- 本地 commit：待补充。

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
- [Apple HealthKit `HKWorkoutBuilder` 文档](https://developer.apple.com/documentation/healthkit/hkworkoutbuilder)
- [WWDC22：What’s new in Swift](https://developer.apple.com/videos/play/wwdc2022/110354/)
