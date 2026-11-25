# HealthMi 应用内诊断日志设计

日期：2026-11-25

状态：按用户“你来设计”的授权选定方案，进入实现。

## 意图

为 iOS 16 起的 HealthMi 增加可用于排查真实设备问题的诊断日志功能。用户可在应用内浏览、搜索、筛选日志，并将脱敏诊断包保存到“文件”或通过系统分享面板发送给开发者。日志尤其要覆盖此前难以从快捷指令错误提示定位的 App Intents、后台刷新、Keychain、HealthKit、网络和本地存储链路。

## 当前代码事实

- `HealthMi/Support/AppLog.swift` 已定义少量按类别区分的 `os.Logger`，仅有部分 Core Data、同步调度、重试和 HTTP 错误日志；没有应用可读取的持久化诊断事件文件。
- `AppModel.syncAll` 管理前台与后台共用的完整同步流程，现有运行记录保存最近 30 次运行和按数据类别的结果，但不是逐阶段日志。
- `SyncHealthDataIntent` 只把任务写入 `UserDefaults` 队列；实际同步由 `BackgroundSync` 领取。快捷指令运行阶段、运行队列和后台任务的关键转移需要统一关联到运行 ID。
- 小米凭据存储在 Keychain；同步游标、压力记录和历史记录位于 Core Data。日志持久化不应改变这些现有存储模型。
- `MiAPIClient` 使用 URLSession，目前已手动管理 Cookie；请求/响应正文和 Cookie 都不适合记录。
- `DashboardView` 现有数据 CSV 导出和同步历史入口，可增加“诊断日志”导航入口。
- 项目部署目标是 iOS 16.0、Swift 6，且 GitHub Actions 已负责生成未签名和 TrollStore IPA。

## 目标

1. 持久化详细结构化日志，记录时间、级别、分类、事件名、说明、运行 ID、数据类别、错误域/码和安全白名单元数据。
2. 在文件日志之外镜像日志到 `os.Logger`，供设备 Console 等系统诊断工具读取。
3. 提供应用内日志列表、级别/分类筛选、关键词搜索、错误快速筛选、详情展示、清空和导出/分享。
4. 对文件数量和保留期设上限，避免日志持续占用存储。
5. 重点记录 App 启动/场景切换、数据库启动与迁移、Keychain、登录、HealthKit 授权、快捷指令入队、BGTask 调度/领取/过期、每类同步、网络重试/状态码、HealthKit 写入、Core Data 保存、通知和导出等阶段。
6. 保证 iOS 16 编译，不改变现有同步、快捷指令和 HealthKit 对外行为。

## 非目标

- 不记录健康样本值、睡眠/运动原始数据、请求或响应正文。
- 不上传日志，不接入远程日志平台，不自动发送分享。
- 不捕获或伪装成已捕获 Swift `fatalError`、内存崩溃或系统强杀；此类情况下只保留崩溃前成功落盘的事件。
- 不替代现有同步历史和运行记录；日志用于阶段级诊断，现有记录仍作为业务结果摘要。
- 不导出 CSV 健康数据作为诊断包的一部分。

## 约束与隐私

- 凭据、`passToken`、Cookie、`ssecurity`、Authorization 头、原始用户/设备 ID、请求/响应 body、完整带查询参数的 URL 一律不得写入日志。
- 不记录个人健康指标或原始样本时间；可记录同步类别、数量、页数、耗时和回填天数等排障所需的聚合信息。
- 结构化事件只允许使用已审查的字段；错误描述在本地日志和导出前执行敏感字段与 URL 查询参数脱敏。
- 本地日志存于沙盒 `Application Support/DiagnosticLogs`，排除 iCloud 备份，并采用 `completeUntilFirstUserAuthentication` 文件保护，兼顾首次解锁后的后台任务可读性。
- 文件日志默认保留 14 天，总容量最多 20 MiB；滚动文件每个最多 2 MiB。空间不足、写入错误不得阻断同步主流程，但必须通过 `os.Logger` 记录写入失败。
- 日志 API 采用同步、轻量、串行写入，避免应用/后台任务退出前积压大量未落盘的诊断事件；记录应尽量只含小型结构化字段。

## 架构方案比较

### 方案 A：只用系统统一日志

以 `os.Logger` 写入类别与级别，应用界面尝试从系统日志中读取。

- 优点：实现简单，系统可按 subsystem/category 过滤。
- 代价：应用不能稳定地将自有日志历史、运行记录和应用版本组合成一个可分享文件；系统保留策略也由 OS 控制。
- 结论：不满足应用内查看、历史留存和一键导出目标。

### 方案 B：滚动 JSON Lines 文件，并镜像到 `os.Logger`（选定）

应用在沙盒中维护有容量上限的 JSONL 日志；同一条已脱敏事件再镜像到 `os.Logger`。界面读取应用文件；导出生成一个包含 manifest、日志事件和最近同步运行摘要的脱敏 JSON 文件，并通过 UIKit 分享面板交给用户选择目标。

- 优点：离线可用；应用可以控制保留期、筛选和清空；导出完整且易于机器分析；不修改 Core Data schema、不增加第三方包。
- 代价：应用需要实现滚动、脱敏、序列化、列表和文件分享；JSON 导出不压缩。
- 结论：最符合应用内诊断与 iOS 16 兼容要求，避免加入 ZIP 依赖或自制归档器。

### 方案 C：把诊断事件写入 Core Data

新增诊断实体并用 `NSFetchRequest` 查询展示。

- 优点：可复用现有 Core Data 查询和排序。
- 代价：需要数据库模型与迁移；同步每个阶段都会写入数据库；高频诊断和业务数据事务耦合；仍需额外实现导出文件。
- 结论：成本和风险高于需求收益，不选。

## 选定设计

### 事件模型

每条事件包括：

- UTC 时间戳；
- `trace`、`debug`、`info`、`notice`、`warning`、`error`、`critical` 级别；
- `appLifecycle`、`storage`、`keychain`、`authentication`、`network`、`healthKit`、`sync`、`stress`、`backgroundTask`、`appIntent`、`notification`、`export` 分类；
- 稳定事件名、简短说明；
- 可选运行 ID、同步类别、错误域/码；
- 白名单元数据，例如触发来源、尝试次数、页数、计数和耗时毫秒；
- 进程 ID、主线程标记和应用/系统版本由事件或导出 manifest 提供，不采集硬件序列号或广告标识。

文件格式为一条事件一个 JSON 对象的 UTF-8 JSON Lines。写入按时间追加；读取时容忍单条损坏记录并继续显示其余内容。

### 日志级别和输出

- 文件保存所有级别；界面默认显示最近日志，支持级别、分类筛选和关键词搜索。
- `os.Logger` 采用同 subsystem/category；持久化事件内容已通过脱敏后才允许以公开文本镜像，系统级 debug 日志是否被 OS 保留不影响应用文件日志。
- 日志写入失败不应抛到登录、同步、HealthKit 或 App Intent 主流程；通过现有 `os.Logger` 记录失败，并在日志页面展示可读状态。

### 日志保留

- 路径：`Application Support/DiagnosticLogs`。
- 每个文件最大 2 MiB，所有日志最多 20 MiB，日志最长保留 14 天；超限时先移除最旧文件。
- JSONL 事件完整写入后再继续主链路，降低用户遇到帮助进程或后台任务退出时日志丢失概率。
- 清空日志只删除诊断文件并立即创建新的当前文件；不清除同步历史、同步游标或压力记录。

### 应用内界面

在仪表盘增加“诊断日志”导航入口。页面提供：

- 最新事件倒序列表；级别图标/颜色、分类、事件说明、时间和运行 ID；
- 级别/分类筛选、“仅错误”快捷筛选、关键词搜索；
- 展开查看脱敏元数据、错误域码、耗时和线程上下文；
- 日志总量、文件占用和最早/最新记录时间；
- “查看日志”窗口内支持复制当前筛选结果为脱敏纯文本；
- “导出并分享”按钮生成结构化 JSON 文件，复制和文件导出同时保留；
- 清空确认。

使用 iOS 16 可用的 SwiftUI 列表/搜索能力，以及 `UIActivityViewController` 的 `UIViewControllerRepresentable` 包装分享文件。

### 导出内容

创建单个 `HealthMi-Diagnostics-<UTC时间>.json` 文件，包含：

1. `manifest`：导出时间、App 版本/构建号、iOS 版本、设备型号、日志 schema 版本、日志数量及覆盖时间；
2. `events`：当前保留期内已脱敏的结构化事件；
3. `syncRuns`：最近 30 次运行的脱敏摘要、状态、触发方式、类别成功/失败信息及错误域码。

诊断包不包含同步健康 CSV、原始 HealthKit 样本或 Keychain 数据。文件由用户主动选择分享目标。

复制日志文本只包含当前筛选后的事件，按时间倒序排列，并以人类可读文本呈现级别、分类、事件、时间、运行短 ID、错误域码和安全元数据；复制不会替代结构化 JSON 导出。

### 关键埋点清单

- 生命周期：应用启动、前后台切换、数据库准备开始/成功/失败、旧 SwiftData 迁移开始/结果；
- Keychain/登录：凭据迁移/读取/写入开始结果、OSStatus、登录请求与重定向阶段、认证错误；不含账号或 cookie 值；
- HealthKit：请求授权开始/成功/失败、权限状态检查、摘要读取、样本查询分页数、写入批次数/对象数和错误域码；不含健康样本值；
- App Intents：intent 进入/退出、查询或创建运行、运行短 ID、队列写入、BGTask 是否成功提交；
- 后台任务：注册结果、schedule、handler 启动、领取运行、取消/过期、完成结果；
- 同步：每类开始/结束、回填天数、fetch/parse/write 阶段耗时、条目数、去重新增数、错误域码/错误码；
- 网络：请求 path（不含 query）、尝试编号、耗时、HTTP 状态、返回条数、解析/重试/取消结果；不含 headers、body、cookie 或原始 payload；
- 本地持久化和通知：Core Data save/clear、同步运行记录写入、通知请求结果；
- 导出：导出开始/完成、事件/运行数量、文件字节数、分享面板调用结果；不记录分享对象或用户选择的目的地。

## 验收方式

- GitHub Actions Xcode 16.4 设备 Release build 成功，并生成 unsigned 与 TrollStore IPA；不运行测试套件（本任务未要求测试）。
- 下载并独立检查 IPA 的 `MinimumOSVersion`、HealthKit/TrollStore entitlement、App Intents metadata 和新增日志视图/资源已编入应用。
- 静态检查确认凭据/Cookie/body/健康样本值没有被加入日志调用；检查滚动上限、脱敏和用户清空行为的代码路径。
- 真机上的 App Intents、后台任务和 HealthKit 运行时日志需要用户安装后才能产生；GitHub 编译无法替代 iOS 16.3 TrollStore 设备验证。

## 实施步骤

1. 新增事件模型、脱敏器、滚动 JSONL 存储和 `os.Logger` 双写入口；本地提交。
2. 在启动、凭据、登录、HealthKit、网络、每类同步、Core Data、App Intents、BGTask 与通知链路接入安全埋点；本地提交。
3. 新增诊断日志页面、搜索筛选、清空和 JSON 导出分享；本地提交。
4. 更新 README/CHANGELOG、iOS 16 适配记录和全面审查报告；本地提交。
5. 仅推送 `personal` 远程以触发现有 GitHub Actions；用 `gh` 下载两种 IPA，做包级核验并记录 run ID、SHA-256 和限制；本地提交构建结果记录。

## 官方资料

- Apple `Logger`：https://developer.apple.com/documentation/os/logger
- Apple `UIActivityViewController`：https://developer.apple.com/documentation/uikit/uiactivityviewcontroller
- Apple `FileManager.urls(for:in:)`：https://developer.apple.com/documentation/foundation/filemanager/urls(for:in:)
- Apple Application Support 目录：https://developer.apple.com/documentation/foundation/url/applicationsupportdirectory

资料于 2026-11-25 查阅。Apple `Logger` 用于系统统一日志，Application Support 是应用沙盒内持久支持文件的标准位置；分享由 `UIActivityViewController` 提供系统服务入口。应用仍维护自有文件日志以获得稳定的应用内读取、保留和导出能力。
