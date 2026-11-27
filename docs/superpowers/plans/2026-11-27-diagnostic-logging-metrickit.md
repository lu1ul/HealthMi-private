# HealthMi 自动诊断日志与 MetricKit Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在 iOS 16 兼容范围内增强 HealthMi 自动诊断日志，接收并本机保存 MetricKit 诊断报告，提供应用内查看、复制和主动导出，并生成包含匹配 dSYM 的新 TrollStore IPA。

**Architecture:** 保留现有 JSONL 事件日志和异步串行文件存储；为事件添加进程会话、序号、源码位置和脱敏错误链。通过 iOS 16 可用的 `MXMetricManagerSubscriber` 接收系统诊断 payload，递归脱敏后作为独立 JSON 报告保存，并与事件日志共享容量、保留和健康状态。界面读取同一快照并导出 schema v2；GitHub Actions 构建设备 Release IPA 和对应 dSYM，最终只从 `personal` 仓库下载。

**Tech Stack:** Swift 6、SwiftUI、Foundation、OSLog、MetricKit、CryptoKit、XcodeGen、GitHub Actions、GitHub CLI (`gh`)、`ldid`。

---

## 文件结构与边界

- Modify `HealthMi/Support/DiagnosticLogging.swift`: 事件 schema、错误链、脱敏、队列化存储、存储健康统计、JSONL 与 MetricKit 报告生命周期、schema v2 导出。
- Create `HealthMi/Support/MetricKitDiagnostics.swift`: 任意 JSON 值、MetricKit 报告展示模型、系统订阅者和报告摘要。
- Modify `HealthMi/App/HealthMiApp.swift`: 在进程启动早期注册并强持有 MetricKit 订阅者。
- Modify `HealthMi/App/DiagnosticsLogView.swift`: 显示事件扩展字段、存储健康状态和 MetricKit 报告；提供报告详情与复制。
- Modify `project.yml`: build number 从 4 升至 5，并确保 Release 构建生成 dSYM。
- Modify `.github/workflows/build-unsigned-ipa.yml`: 生成、校验并上传与 IPA 匹配的 dSYM。
- Modify `CHANGELOG.md`, `HealthMi项目代码全面审查报告.md`; create `docs/HealthMi自动诊断日志与MetricKit实施记录.md` 记录研究、每阶段提交和最终构建核验。
- Preserve unrelated existing untracked paths `.playwright-mcp/` and `项目分析-优先关注问题.md`.

## Task 1: 保存实施计划

**Files:**
- Create: `docs/superpowers/plans/2026-11-27-diagnostic-logging-metrickit.md`

- [x] 记录设计决定、代码范围、分阶段验收和官方 MetricKit API 限制。
- [x] Commit: `docs: plan MetricKit diagnostic logging` (`d07ec25`)

## Task 2: 增强事件上下文与日志存储状态

**Files:**
- Modify: `HealthMi/Support/DiagnosticLogging.swift`
- Create: `HealthMi/Support/MetricKitDiagnostics.swift` (JSON payload model and storage-facing report type)

- [x] 给 `DiagnosticLogEvent` 增加可选字段 `processSessionID`, `sequenceNumber`, `sourceFile`, `sourceFunction`, `sourceLine`, `errorChain`。新字段可选以兼容此前 JSONL 行；旧记录不重写。
- [x] 给 `DiagnosticLogger.record` 增加调用点默认参数 `file: String = #fileID`, `function: String = #function`, `line: UInt = #line`。由线程安全序号器生成进程级 UUID 与递增序号，记录 PID、线程标志仍保留。
- [x] 新增可编码的错误详情类型，沿 `NSUnderlyingErrorKey` 读取最多 5 层，仅保存经过脱敏的 domain、code 和 localized description；检测重复 NSError 身份以避免循环。
- [x] 增加 MetricKit JSON 的递归隐私过滤：剔除敏感键，对字符串执行现有 token/Bearer/URL 查询参数规则，拒绝无效 JSON 或超过 8 MiB 的报告，不落盘原始 payload。
- [x] 将存储统计限制在本进程启动以来：事件写入失败、MetricKit 写入失败、清理维护失败、JSONL 轮转、过期/容量清理的文件数与字节数、最近错误域/码/脱敏说明。统计在串行 I/O 队列内更新，写入失败同时走 fallback `os.Logger`，不能中断业务路径。
- [x] 将 MetricKit JSON 文件纳入共享的 20 MiB / 14 天保留策略；每份不超过 8 MiB，去重以脱敏 JSON 的 SHA-256 为键。保留 JSONL 每文件 2 MiB 上限。清空操作移除 JSONL 与 MetricKit 报告。
- [x] 更新快照使其包含总存储字节数、损坏记录数、存储健康统计和可读 MetricKit 报告；snapshot、append、clear、prune 均继续串行化，保留旧 JSONL 解码行为。
- [x] 完成代码静态检查后 Commit: `feat: enrich diagnostic event context and storage health`

## Task 3: 接入 iOS 16 MetricKit 报告

**Files:**
- Create: `HealthMi/Support/MetricKitDiagnostics.swift`
- Modify: `HealthMi/App/HealthMiApp.swift`

- [x] 定义 `DiagnosticJSONValue`，支持 object、array、string、number、boolean、null 的 Codable 表示，以便应用内展示及将报告 payload 作为真正的嵌套 JSON 导出，而不是 base64 字符串。
- [x] 定义报告模型：稳定 ID、接收时间、字节数、简短摘要、脱敏后的 JSON payload。摘要只展示诊断类别/顶层键和系统报告时间，不解析或展示 HealthKit 数据。
- [x] 创建强持有的 `NSObject` + `MXMetricManagerSubscriber` 实例；`HealthMiApp.init()` 记录启动事件后尽早注册 `MXMetricManager.shared.add(_:)`。诊断 payload 回调转为 `Data` 后交给串行存储；每日 metrics 回调不保存、不导出。
- [x] 根据部署目标 iOS 16 使用旧版 `MXMetricManagerSubscriber`/`MXDiagnosticPayload.jsonRepresentation()` 兼容 API；不调用 iOS 27+ 专用类型。MetricKit 报告系统投递时间和是否生成由系统决定。
- [x] 静态检查 callback 签名、iOS availability、Swift 6 Sendable 边界和存储失败不影响应用启动后 Commit: `feat: persist MetricKit diagnostic reports locally`

## Task 4: 增强查看、复制和导出

**Files:**
- Modify: `HealthMi/App/DiagnosticsLogView.swift`
- Modify: `HealthMi/Support/DiagnosticLogging.swift`

- [ ] 在诊断日志页面展示本进程的写入/报告失败计数、轮转与清理计数、最近存储错误、总占用和损坏行数。
- [ ] 增加“系统诊断报告”区，列出接收时间、大小和摘要；报告详情显示可选择复制的格式化脱敏 JSON，并提供一键复制。
- [ ] 事件详情与纯文本复制增加进程会话 ID、序号、源码位置和错误链；搜索支持新字段。
- [ ] 导出 manifest schema 升至 2，新增 `storageHealth`、`metricKitDiagnostics`，报告 payload 保持 JSON 对象嵌套；继续保留事件、设备/系统版本和同步运行摘要。
- [ ] 更新界面隐私提示，明确 MetricKit 调用栈会留在本地，只有用户主动导出/分享才离开沙盒；清空确认明确会删除 MetricKit 报告。
- [ ] 静态检查旧事件可解码、JSON 报告已脱敏且导出结构与 schema 一致后 Commit: `feat: view and export MetricKit diagnostics`

## Task 5: 更新 build number 并产出匹配 dSYM

**Files:**
- Modify: `project.yml`
- Modify: `.github/workflows/build-unsigned-ipa.yml`
- Modify: `CHANGELOG.md`

- [ ] 将 build number 更新为 `5`，保持版本 `1.1.0`、Bundle ID、iOS 16.0 deployment target、现有 unsigned 和 TrollStore IPA 路径。
- [ ] Release `xcodebuild` 明确启用 `dwarf-with-dsym`，从 `Release-iphoneos/HealthMi.app.dSYM` 生成 `HealthMi-dSYMs.zip`。
- [ ] 在 workflow 中使用 `dwarfdump --uuid` 提取 app 可执行文件与 dSYM 的架构 UUID 集合，逐架构比较，不匹配则失败；上传独立 dSYM artifact。
- [ ] 在 changelog 记录日志上下文、MetricKit、本地查看与导出、build 5 的变更；不改变 HealthKit entitlement、TrollStore 签名和快捷指令行为。
- [ ] 静态核对 workflow 条件、输出路径和 shell 变量后 Commit: `build: archive matching dSYM for diagnostic IPA`

## Task 6: 构建、下载、核验与归档记录

**Files:**
- Create/update: `docs/HealthMi自动诊断日志与MetricKit实施记录.md`
- Modify: `HealthMi项目代码全面审查报告.md`
- Update: this plan's checkboxes

- [ ] 记录 Apple 官方文档中旧订阅接口、JSON 序列化和 past payload 生命周期限制；记录设计、每个本地 commit SHA、静态核查结果。
- [ ] 仅对 `personal` 远程 `lu1ul/HealthMi-private` 推送已提交代码以触发 `main` workflow；确认实际 push URL 后再执行，绝不 push `origin`。
- [ ] 使用已认证的 GitHub CLI `gh` 查看运行状态和日志，并下载 `HealthMi-trollstore-healthkit-ipa` 与 dSYM artifact；不使用浏览器下载。
- [ ] 核验 IPA 的 `com.healthmi.HealthMi`、版本 `1.1.0 (5)`、`MinimumOSVersion` 16.0、arm64、HealthKit/TrollStore/Keychain entitlements、HealthKit usage strings、App Intents metadata；核验 dSYM UUID 与 IPA 内可执行文件一致。
- [ ] 对 IPA 与 dSYM 计算 SHA-256，记录 workflow run ID、提交 SHA、产物路径、哈希、核验结果和 MetricKit 设备投递限制。
- [ ] Commit: `docs: record MetricKit IPA build verification`

## 验收限制

- 不新增或运行测试套件；用户要求的是构建 IPA，验收使用 GitHub Actions Release 编译、workflow 产物检查、IPA 静态审阅和 dSYM UUID 比对。
- Windows 本机不具备 Xcode；通过 GitHub `macos-15` runner 构建设备 Release app。
- MetricKit 报告由 iOS 投递，不保证每次异常退出都生成报告；其报告仅覆盖 HealthMi 进程，不能替代 Shortcuts、SpringBoard 或其他系统进程 unified logs。
- `pastDiagnosticPayloads` 只反映当前共享 manager 实例生命周期，并且须在注册订阅者且收到回调后访问；不把它当作跨重启的报告回放机制。

## API 研究来源

- Apple `MXMetricManagerSubscriber.didReceive(_:)`: <https://developer.apple.com/documentation/metrickit/mxmetricmanagersubscriber/didreceive%28_%3A%29-9yd4u>
- Apple `MXDiagnosticPayload.jsonRepresentation()`: <https://developer.apple.com/documentation/metrickit/mxdiagnosticpayload/jsonrepresentation%28%29>
- Apple `MXMetricManager.pastDiagnosticPayloads`: <https://developer.apple.com/documentation/metrickit/mxmetricmanager/pastdiagnosticpayloads>
- 上述兼容 API 已标注 deprecated，替代的新报告 API 不属于当前 iOS 16.3 设备基线；保持 Xcode 16.4/macOS 15 workflow 以构建 iOS 16 部署目标。
