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
- 验证：待补充。
- 本地 commit：待补充。

### 后续阶段

- Core Data 数据模型、共享容器及 SwiftData 一次性迁移：待实施。
- AppModel 与 SwiftUI 状态、数据查询转换：待实施。
- 压力范围回填和仪表盘查询优化：待实施。
- iOS 16 配置、兼容性检查及可用环境验证：待实施。

## 官方资料

- [Apple SwiftData 文档](https://developer.apple.com/documentation/swiftdata)
- [Apple Observation 文档](https://developer.apple.com/documentation/observation)
- [SwiftUI `Bindable` 文档](https://developer.apple.com/documentation/swiftui/bindable)
- [SwiftUI `ContentUnavailableView` 文档](https://developer.apple.com/documentation/swiftui/contentunavailableview)
- [Swift Charts `Chart` 文档](https://developer.apple.com/documentation/charts/chart)
- [Apple App Intents 文档](https://developer.apple.com/documentation/appintents)
- [Apple Core Data stack 指南](https://developer.apple.com/documentation/coredata/setting-up-a-core-data-stack)
- [Apple HealthKit `HKWorkoutBuilder` 文档](https://developer.apple.com/documentation/healthkit/hkworkoutbuilder)
- [WWDC22：What’s new in Swift](https://developer.apple.com/videos/play/wwdc2022/110354/)
