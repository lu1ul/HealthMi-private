# HealthMi 自动诊断日志与 MetricKit 设计

日期：2026-11-27

状态：用户已批准方案 3；实现进行中，尚未触发 GitHub 构建。

## 意图

在现有自动日志基础上补齐应用异常退出后的诊断信息。HealthMi 在启动时自动订阅 MetricKit，并把系统交付的本应用诊断报告保存在本机。应用内查看器和用户主动导出的脱敏诊断包同时显示结构化事件与 MetricKit 报告。

用户遇到的快捷指令错误包含 Shortcuts / 系统启动服务的 `FBSOpenApplication` 错误。HealthMi 自身日志可显示 Intent 是否启动、是否排队以及执行到返回前的哪一步；MetricKit 可提供 HealthMi 自身崩溃、卡顿等诊断，但不能读取 Shortcuts、SpringBoard 或其他系统进程的日志。因此，这项改动提高应用自身故障的可诊断性，不承诺单独解释所有跨进程启动失败。

## 当前实现事实

- `HealthMi/Support/DiagnosticLogging.swift` 定义 JSONL 事件、脱敏、异步串行写入、`os.Logger` 镜像和读取快照。
- 当前事件包含时间、级别、类别、事件名、说明、run ID、数据类型、单层错误域/码、元数据、进程 ID 和主线程标记；没有进程会话 ID、递增事件序号、源文件/函数/行号或结构化底层错误链。
- JSONL 单文件上限 2 MiB、总容量上限 20 MiB、保留 14 天。写入失败只写入 `os.Logger`，应用内快照没有写入失败、轮转或清理计数。
- `SyncHealthDataIntent` 已记录 `invocationID`、运行 ID、排队/复用分支和返回前事件，并在返回时 flush。此类事件不能记录其返回之后 Shortcuts 或系统服务发生的情况。
- `DiagnosticsLogView` 已有搜索、级别/类别过滤、详情、复制、清空和 JSON 分享导出；导出包含应用版本、系统版本、设备型号、事件和同步运行摘要。
- 部署目标为 iOS 16.0，Swift 6.0。当前 GitHub workflow 使用 `macos-15` 构建设备 Release app，制作 unsigned IPA 和 TrollStore HealthKit IPA；不会下载或归档 dSYM。
- 当前应用版本为 `1.1.0 (4)`。本轮拟提升到 `1.1.0 (5)`，保持 Bundle ID、最低系统版本和现有 IPA 类型不变。

## 目标

1. 继续默认自动记录，不新增手动诊断开关或需要用户先开启的步骤。
2. 提高普通事件的关联能力：进程会话、单调递增事件序号、源文件/函数/行号和结构化底层错误链。
3. 自动接收 MetricKit 提供的本应用诊断报告，并持久化适合定位崩溃/卡顿的调用栈数据。
4. 在应用内查看报告详情，并将报告纳入用户主动生成的 JSON 诊断导出。
5. 让日志页面和导出显示诊断存储健康状态，包括记录写入失败、轮转和过期清理情况。
6. 保持 iOS 16 兼容、原 JSONL 文件读取兼容、同步与 App Intent 的既有行为，以及日志不自动上传的隐私边界。
7. 保存与最终 IPA 完全匹配的 dSYM，以便有符号信息时对 MetricKit 调用栈进行符号化。

## 非目标

- 不采集或记录 HealthKit 样本值、睡眠/运动明细、登录凭据、Cookie、Authorization、请求/响应正文、完整带查询参数的 URL 或个人标识符。
- 不自动上传、分享或发送日志及 MetricKit 报告；只有用户主动导出/分享时才离开应用沙盒。
- 不收集 MetricKit 每日性能指标作为本轮功能；只接收诊断 payload。
- 不采集其他进程（包括 Shortcuts、SpringBoard、`linkd`）的 unified log；这需要设备系统日志工具。
- 不保证每次异常退出都会产生 MetricKit 报告，也不将其作为 Swift `fatalError`、进程强杀或跨进程服务错误的必然捕获机制。
- 不改变 HealthKit 授权、登录、数据同步、后台任务、App Intent 返回值或同步历史数据格式。

## 设计方案比较

### 方案 A：保持现状

优点是没有代码或构建风险；当前日志能描述快捷指令正常执行到返回前的路径。代价是应用异常退出仍缺少调用栈，日志文件写入失败也无法在应用内识别。当前用户明确希望自动留下更完整的现场，因此不选。

### 方案 B：只增强应用自有事件

增加进程会话、事件序号、源位置、结构化 NSError 链和日志存储状态。

优点是对 iOS 16 兼容性直接，能改善已捕获错误的前后文和日志完整性。代价是无法提供系统生成的崩溃/卡顿调用栈。

### 方案 C：增强应用事件并接入 MetricKit（选定）

实现方案 B，并订阅 MetricKit 诊断报告，在本机保存、展示和导出经过脱敏的报告；为同次构建保存对应 dSYM。

优点是同时改善应用级事件链与系统收集的应用崩溃/卡顿证据，且不需要远端服务。代价是报告到达受系统控制、不是每次异常都产生；需处理报告文件、UI、导出、dSYM 和隐私过滤。

## 选定设计

### 1. 事件上下文

为新事件增加以下字段：

- `processSessionID`：每个进程生命周期一个随机 UUID；跨进程日志可以分组。
- `sequenceNumber`：进程内单调递增，作为时间戳相同时的稳定顺序。
- `sourceFile`、`sourceFunction`、`sourceLine`：由日志 API 默认参数捕获 `#fileID`、`#function`、`#line`；只存仓库相对文件标识，不存构建机绝对路径。
- `errorChain`：从 `NSError` 及 `NSUnderlyingErrorKey` 递归提取最多 5 层的域、码、脱敏摘要；检测循环引用。仅记录用于诊断的字符串字段，不序列化完整 `userInfo`。

保留当前 `processID`、`isMainThread`、run ID、数据类别和已有元数据。既有 JSONL 的这些新字段均按可选字段解码；旧记录不迁移、不覆盖，仍可查看和导出。导出 manifest 的 schema 版本提升为 2。

`DiagnosticLogger.record` 继续异步写文件并镜像 `os.Logger`，不得因日志失败中断业务操作。快捷指令返回和 BGTask 完成前的显式 flush 继续保留。

### 2. MetricKit 订阅与报告保存

- 在应用生命周期早期创建并强持有一个 `MXMetricManagerSubscriber`，注册 MetricKit。旧 API 使用同一订阅者接口接收每日 metrics 和诊断 reports；metrics 回调保持空操作，不保存或导出每日性能 metrics，只持久化 diagnostic payload。
- 使用与 iOS 16 兼容的 `MXMetricManager` / `MXMetricManagerSubscriber` 作为本轮实现基线。Apple 自 iOS 27 起提供新的 Swift-first `MetricManager` API；本应用需要在 iOS 16.3 上自动接收报告。当前 workflow 使用 `macos-15`，GitHub 官方 runner 清单标出的默认 Xcode 为 16.4，Xcode 27 使用独立 runner，因此本轮不更换 runner 或增加构建额度消耗。旧 API 从 iOS 13 可用，诊断 JSON 表示从 iOS 14 可用，足以覆盖本轮 iOS 16 目标。以后若切换到 Xcode 27 runner，再评估 iOS 27+ 使用新 API、旧系统走兼容实现的双路径。
- 对系统投递的每份 `MXDiagnosticPayload` 调用 `jsonRepresentation()`，解析 JSON 后递归脱敏字符串并移除敏感键，再写入独立的诊断报告 JSON 文件。保留 Apple 报告中的诊断类型、时间、异常/终止信息、调用栈、二进制 UUID 和偏移量等排障字段。
- 对脱敏并规范化后的报告 JSON 计算 SHA-256，用内容摘要去重，避免相同报告重复写盘。
- 每份报告分配本地 UUID 与接收时间；JSONL 记录一条引用事件，包含本地报告 ID、报告类型、字节数和报告数量，不把大型调用栈塞入受单字段长度限制的普通事件。
- 写入失败只增加日志存储健康计数并写入 fallback `os.Logger`，避免通过同一个损坏存储反复记录错误。
- 报告原始数据不会离开沙盒。复制或分享时，将递归过滤后的 JSON 纳入用户主动生成的诊断包。页面需提示导出包含应用崩溃调用栈和系统诊断元数据。

### 3. 日志存储健康与容量

- 保留当前日志总容量 20 MiB、14 天的约束，并把 MetricKit 报告文件计入同一总容量和保留期限。
- 每个 MetricKit 报告设最大 8 MiB；超过上限时不截断调用栈，跳过该报告并将失败计数和原因记入存储健康状态。
- 维护进程内的安全统计：事件写入失败数、MetricKit 报告写入失败数、轮转文件数、因过期/容量上限移除的文件数和字节数、最近一次存储错误域/码。错误统计由内存快照和 fallback logger 提供，不能依赖再次写入同一文件。
- 日志页显示这些统计与当前文件占用；JSON manifest 同时输出存储统计。计数范围明确标记为“本进程启动以来”，避免误认为跨安装/跨进程的累计值。
- 文件继续位于 Application Support，排除备份，使用 `completeUntilFirstUserAuthentication` 保护。清空功能同时删除 JSONL 和 MetricKit 文件，且保留业务同步历史。

### 4. 查看与导出

- 保留现有日志列表、搜索、分类/级别过滤、复制纯文本、清空和分享流程。
- 日志页增加“系统诊断报告”列表，展示接收时间、报告类型、文件大小和摘要；详情页显示格式化 JSON，可一键复制单份报告。
- 诊断 JSON 导出 schema v2 增加 `processSessionID` 等事件字段、`storageHealth` 和 `metricKitDiagnostics`。MetricKit payload 作为嵌套 JSON 对象导出，并关联本地报告 ID。保留现有 `syncRuns` 摘要。
- 导出继续由用户主动触发，不保存用户选择的分享目标，不新增网络服务。

### 5. dSYM 与 GitHub IPA 构建

- 保持现有 Release IPA 生成和 TrollStore entitlement 校验流程，项目 build number 提升到 5。
- 构建时明确生成 `HealthMi.app.dSYM`，并将它压缩为 `HealthMi-dSYMs.zip` 作为独立 artifact；在 workflow 中核对 app 可执行文件与 dSYM 的 UUID 匹配。
- `gh` 下载 IPA 和 dSYM artifact；最终报告记录 workflow run ID、提交 SHA、IPA 路径、SHA-256、dSYM 匹配结果、Bundle ID、版本、最低系统版本、App Intents metadata 及 TrollStore/HealthKit entitlement 核验。
- 只推送到 `personal`（`lu1ul/HealthMi-private`）以触发 workflow；绝不推送到 `origin`（`ShawnDiego/HealthMi`）。不使用浏览器下载产物。

## 隐私边界

- 现有 metadata key 过滤与字符串脱敏继续生效；新增错误链和 MetricKit 报告也必须经同一脱敏策略。
- MetricKit JSON 采用递归处理：敏感键（凭据、Cookie、token、用户/设备标识、联系方式等）整体剔除；所有字符串执行 token、Bearer 和 URL 查询参数脱敏；限制单个报告最大字节数。
- 不把完整 NSError `userInfo`、网络 body、HealthKit 数据或密钥材料写入文件。
- 本机自动保存是默认行为，用户只有在点“复制”或“导出并分享”时才主动暴露数据；界面说明 MetricKit 报告含调用栈与系统诊断元数据。

## 兼容性与限制

- 部署目标继续为 iOS 16.0。MetricKit 报告依赖系统投递；模拟器无法证明真实设备报告到达，因此最终 workflow 只验证编译、链接、产物和 dSYM UUID。
- Apple 文档说明 MetricKit 诊断报告在 iOS 15 及以上可立即投递，但系统并不为每次诊断事件都生成报告。此功能不应把“没有 MetricKit 报告”解释为“没有崩溃”。
- dSYM 可把匹配二进制的地址偏移映射到符号；如果报告只有系统库栈、报告不含对应二进制 UUID，或用户使用了不同 build，HealthMi 代码帧仍可能无法符号化。
- `FBSOpenApplication` / XPC 错误若只发生于 Shortcuts 或系统启动服务，MetricKit 不会代替 `pymobiledevice3` 等设备 unified log 采集。
- 本轮不运行测试套件；按用户要求通过 GitHub Actions 设备 Release 编译并执行 IPA 静态核验。iOS 16.3 TrollStore 真机上的报告投递仍需设备运行后才能验证。

## 验收标准

1. GitHub Actions 对 iOS 16.0 deployment target 成功构建 unsigned IPA 和 TrollStore HealthKit IPA。
2. 两个 IPA 的版本为 `1.1.0 (5)`、Bundle ID 为 `com.healthmi.HealthMi`、最低版本为 iOS 16.0；TrollStore 包的 HealthKit entitlement、TrollStore entitlement 和 Keychain groups 核验通过。
3. 构建 artifact 含 dSYM ZIP，且其 UUID 与 IPA 内可执行文件的 UUID 匹配。
4. IPA 中的 App Intents metadata 仍可见；同步快捷指令的既有返回与入队行为没有被日志改动。
5. 源码静态检查确认旧 JSONL 记录可解码，敏感键/文本过滤覆盖 MetricKit 与错误链路径，日志失败不改变业务流程。
6. 日志页面可浏览事件、存储健康和 MetricKit 报告；导出 JSON 含报告、事件、同步摘要和 schema v2；清空覆盖全部诊断文件。
7. 文档记录 GitHub run ID、commit SHA、artifact 本地路径、IPA 与 dSYM 的 SHA-256，以及包级核验结果与设备端限制。

## 官方资料

- Apple MetricKit 总览：<https://developer.apple.com/documentation/metrickit>
- Apple `MXMetricManager`：<https://developer.apple.com/documentation/metrickit/mxmetricmanager>
- Apple `MXMetricManagerSubscriber`：<https://developer.apple.com/documentation/metrickit/mxmetricmanagersubscriber>
- Apple `MXMetricManager.pastDiagnosticPayloads`：<https://developer.apple.com/documentation/metrickit/mxmetricmanager/pastdiagnosticpayloads>
- Apple `MXDiagnosticPayload.jsonRepresentation()`：<https://developer.apple.com/documentation/metrickit/mxdiagnosticpayload/jsonrepresentation()>
- Apple `MXCallStackTree.jsonRepresentation()`：<https://developer.apple.com/documentation/metrickit/mxcallstacktree/jsonrepresentation()>
- Apple 新 `MetricManager` API：<https://developer.apple.com/documentation/metrickit/metricmanager>
- Apple 新 `DiagnosticReport` API：<https://developer.apple.com/documentation/metrickit/diagnosticreport>
- Apple Xcode 崩溃报告符号化说明：<https://developer.apple.com/documentation/xcode/adding-identifiable-symbol-names-to-a-crash-report>
- Apple MetricKit 更新说明（2026 年 6 月）：<https://developer.apple.com/documentation/updates/metrickit>
- Apple MetricKit 文档说明：`MXMetricManager` 在 iOS 13 及以上可用；`MXDiagnosticPayload.jsonRepresentation()` 从 iOS 14 可用；诊断报告在 iOS 15 及以上可即时投递；`pastDiagnosticPayloads` 只包含当前 manager 实例生命周期内的诊断。iOS 27 起的新 `MetricManager` 使用异步序列 API，且新的 `DiagnosticReport` 不保证每个诊断事件都产生报告。`CallStackTree` 的帧包含二进制 UUID 和文本段偏移量，可用于匹配符号文件。
- GitHub 官方 macOS 15 runner 软件清单：<https://github.com/actions/runner-images/blob/main/images/macos/macos-15-Readme.md>。查阅时标注 Xcode 16.4 为默认版本。
- GitHub Actions 工作流 runner 变更可核对：<https://github.blog/changelog/2026-10-15-xcode-27-runner-image-generally-available/>。资料于 2026-11-27 查阅。
