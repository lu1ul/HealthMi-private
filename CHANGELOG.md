# 更新日志

本文件记录 HealthMi 的版本变更。格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)。

## [未发布]

### 新增

- **增强自动诊断日志**：事件增加进程会话、递增序号、源码位置和脱敏底层错误链；自动接收并本机保存 MetricKit 诊断报告，日志页显示存储健康、报告详情并纳入 JSON 导出
- **应用内诊断日志**：新增结构化 JSONL 日志和系统 `Logger` 镜像，覆盖应用启动、Keychain、小米登录、分页网络请求、HealthKit、同步、快捷指令、后台任务、通知与导出过程；包含运行 ID、错误域/码、HTTP 状态、耗时和数量等诊断信息
- **日志查看、复制与导出**：仪表盘新增诊断日志页面，支持关键词搜索、级别/分类筛选、错误快速筛选、逐条详情查看、一键复制当前筛选结果的脱敏文本，以及导出并分享完整 JSON 诊断文件
- **诊断日志本地保留与脱敏**：日志在本机最多保存 14 天/20 MiB，单文件最多 2 MiB；过滤凭据、Cookie、用户标识、URL 查询参数、请求/响应正文和健康样本值，不自动上传
- **快捷指令直接增量同步**：「同步健康数据」在不打开前台 App 的情况下直接等待游标同步和 HealthKit 写入，返回包含运行状态、数据类别和错误摘要的字符串值；不再依赖本次 BGAppRefresh 请求启动
- **快捷指令有限执行时间**：设置 22 秒应用预算、单网络请求最多 8 秒并关闭自动重试；同步完成的类别立即保存游标，预算用尽时报告部分完成，重复运行可接续同步
- **后台授权和结果反馈**：快捷指令路径不尝试弹出 HealthKit 首次授权，不刷新仪表盘摘要；详细运行记录仍可在 App 内同步历史和诊断日志查看，周期 BGAppRefresh 保留
- **同步状态快捷指令动作**：保留「查询同步状态」动作；为兼容 iOS 16.3 不使用 `ProvidesDialog`，设备动作列表发现情况仍需用户真机确认
- **快捷指令应用内入口**：仪表盘新增 `ShortcutsLink`，可直接打开系统快捷指令中的 HealthMi 页面；应用启动时请求刷新快捷指令信息，并统一查询动作标题
- **快捷指令诊断增强**：每次 Intent 调用都有独立 ID 和结果返回阶段日志；记录同步总耗时、网络请求预算与各类型状态；复制日志文本增加 PID 和主线程标记
- **跨实例并发同步互斥**：前台 UI、快捷指令 Intent、BGTask 后台刷新使用不同 `AppModel` 实例，`syncAll` 用 `OSAllocatedUnfairLock` 保证同一时刻只有一个同步在跑，避免读到相同增量游标造成重复写入

### 修复

- **BGTask 处理器注册时机**：从 `.task`（依赖 UI 出现）移到 `App.init()`，进程被杀后后台拉起时场景不出现也能正确注册，避免后台同步静默失效；`register` 加防重复注册保护
- **App Intent 返回兼容**：同步 Intent 返回 iOS 16 可用的 `ReturnsValue<String>`，不提供 `ProvidesDialog`/`IntentDialog`，避免回归 iOS 16.3 已记录的返回契约崩溃
- **快捷指令运行竞争**：复用旧 queued 运行并直接执行；已有 running 运行时不重复执行，也不把原运行误标为失败

## [1.1.0] - 2026-08-16

### 新增

- **多区域支持**：支持中国大陆/俄罗斯/欧洲/国际/新加坡/美国六个区域，自动适配 API 域名和时区，Dashboard 区域选择器
- **Swift Charts 趋势图**：7 天步数/心率/睡眠/HRV 趋势可视化（`HKStatisticsCollectionQuery` 按天查询）
- **每日详情页**：点击趋势图中任一天查看当日全部数据 + 压力记录明细
- **同步历史日志**：持久化每次类型同步的结果（成功/失败/拉取数/新增数），`SyncHistoryView` 列表展示，自动裁剪 200 条
- **同步失败通知**：后台同步失败时发送本地通知，`NotificationManager` 管理授权与发送
- **数据导出**：一键导出最近 7 天每日数据为 CSV，通过系统分享面板发送
- **App Intents / 快捷指令**：通过 Siri 或快捷指令触发同步（"同步 HealthMi 健康数据"）
- **压力数据同步**：新增 `SyncDataType.stress`，从云端拉取压力数据存入 SwiftData，Dashboard 展示 7 天平均压力
- **身体指标补全**：新增写入 BMI（`bodyMassIndex`）、肌肉量（`leanBodyMass`）、基础代谢（`basalEnergyBurned`）
- **运动记录心率**：运动记录关联平均/最大心率样本（`HKWorkoutBuilder` + `store.add(_:to:)`）
- **同步进度文字**：显示"正在同步 3/9"
- **HealthKit 授权实时检测**：每次同步前检查权限状态，被撤销时提示用户
- **统一日志**：`AppLog` 枚举集中管理所有 `os.Logger` 实例
- **SwiftData 迁移策略**：`SchemaV1` + `MigrationPlan`，为未来 schema 变更建立基础设施
- **测试覆盖**：新增 `SyncEngineTests`（窗口计算）、`SyncStateStoreTests`（游标+区域配置）

### 修复

- **后台同步失效**：Info.plist 添加 `BGTaskSchedulerPermittedIdentifiers`，统一 BG Task ID 为 `com.healthmi.HealthMi.sync`，`try?` 改为 do/catch + 日志
- **Sleep 数据重复下载**：SyncEngine 内缓存，sleep/呼吸频率/HRV 共享同一份睡眠原始数据（从 3 次降为 1 次）
- **退出登录不重置游标**：`disconnect()` 清除所有 `SyncState` 游标和压力记录
- **API 无重试/限流**：网络错误指数退避重试（最多 3 次），分页间 200ms 间隔，认证错误不重试，新增 HTTP 状态码检查
- **try? 静默吞错**：`SyncStateStore` 和 `BackgroundSync` 的 save/submit 错误改为 do/catch + Logger
- **睡眠去重边界漏洞**：`HealthWriter` 从 `.strictStartDate/.strictEndDate` 改为软边界
- **Keychain service 迁移**：从旧 `com.example.HealthMi` 一次性迁移到新 `com.healthmi.HealthMi`
- **后台同步任务取消**：存储 sync Task 引用，`expirationHandler` 中 `cancel()`，`syncAll` 检查 `Task.isCancelled`

### 优化

- **HealthKitReader 并行查询**：4 个独立统计查询用 `async let` 并行执行
- **标识符统一**：`project.yml` 的 `bundleIdPrefix` 和测试 bundle ID 从 `com.example` 改为 `com.healthmi`
- **MCP 工具 SQLite 性能**：连接复用 + WAL 模式 + `executemany` 批量插入
- **MCP 工具 0 值修正**：`_optional_float`/`_optional_int` 不再把 0 当 None
- **MCP 工具请求限流**：`iter_*` 方法间 200ms 间隔，可配置 `min_request_interval_seconds`
- **MCP 工具清理死配置**：删除未引用的 `auto_sync_on_start`/`stale_after_minutes`/`store_raw_payloads`

## [1.0.0] - 2026-08-14

### 首次开源发布

- Swift 移植 `mi-fitness-mcp-cn` 取数逻辑
- 8 类数据同步：日常活动、心率、睡眠、血氧、体重/体脂、运动记录
- WebView 登录小米账号 + 手动 Cookie 输入
- 增量同步 + 7/30/90/全部 回填
- 幂等写入（`HKMetadataKeyExternalUUID` 去重）
- Keychain 凭据存储
- `BGAppRefreshTask` 后台同步
- 加密向量单测（RC4/SHA256/SHA1 预言机测试）
