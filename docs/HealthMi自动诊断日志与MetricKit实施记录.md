# HealthMi 自动诊断日志与 MetricKit 实施记录

日期：2026-11-27
状态：日志与 MetricKit 功能、dSYM workflow 已本地提交并推送到 `personal`；首次 GitHub 编译失败，已修复源码类型检查问题，待重跑。

## 目标

在现有自动日志上增加进程会话和事件序号、源码位置、脱敏底层错误链、MetricKit 诊断报告本地保存、存储健康统计、报告详情和复制，并把报告纳入用户主动导出的 JSON。最终生成 build 5 的 unsigned 与 TrollStore IPA，并保留与应用二进制 UUID 匹配的 dSYM。

保持 iOS 16.0 最低版本、Bundle ID、HealthKit/TrollStore entitlements、同步行为和快捷指令返回行为。诊断材料不会自动上传；只有用户主动导出或分享时才离开应用沙盒。

## API 与系统限制研究

查阅日期：2026-11-27。以下接口说明来自 Apple MetricKit 官方文档：

- `MXMetricManager.shared.add(_:)` 注册 `MXMetricManagerSubscriber`。MetricKit 为 iOS 13 及以上提供 manager 注册能力，诊断 payload 的序列化接口从 iOS 14 起可用。
- 订阅者需实现 `didReceive(_ payloads: [MXDiagnosticPayload])` 和 `didReceive(_ payloads: [MXMetricPayload])`。诊断 payload 可能在 iOS 15 及以上即时投递；投递时间和报告是否生成由系统控制。
- `MXDiagnosticPayload.jsonRepresentation()` 返回 `Data`。应用可以保存完整结构化诊断 JSON，再递归过滤敏感字段后显示或导出。
- `pastDiagnosticPayloads` 只能在注册订阅者并收到至少一次回调后读取，且只包含当前共享 manager 实例生命周期内的报告，不会回放之前应用进程留下的报告。因此本实现依赖持续订阅并在回调时持久化，不把该属性当成跨重启恢复机制。
- 这些旧版 `MXMetricManager`/`MXMetricManagerSubscriber` 接口在当前 Apple 文档中已标为弃用，但兼容 iOS 16 部署目标。Apple 将 Swift-first `MetricManager` 异步序列 API 标为 iOS 27 及以上；本轮保持 iOS 16 可用的旧接口，不提高最低版本或更换 runner。
- 诊断报告通常即时投递，但 MetricKit 不会为每一次诊断事件都生成报告。实际投递需真实设备验证；GitHub Actions 只能验证编译、报告处理代码、IPA 内容和 dSYM 匹配，不能证明设备一定收到报告。

### 官方资料

- [MXMetricManager](https://developer.apple.com/documentation/metrickit/mxmetricmanager)
- [MXMetricManagerSubscriber](https://developer.apple.com/documentation/metrickit/mxmetricmanagersubscriber)
- [MXMetricManagerSubscriber.didReceive(_:)](https://developer.apple.com/documentation/metrickit/mxmetricmanagersubscriber/didreceive%28_%3A%29-9yd4u)
- [MXMetricManager.pastDiagnosticPayloads](https://developer.apple.com/documentation/metrickit/mxmetricmanager/pastdiagnosticpayloads)
- [MXDiagnosticPayload.jsonRepresentation()](https://developer.apple.com/documentation/metrickit/mxdiagnosticpayload/jsonrepresentation%28%29)
- [Apple MetricKit overview](https://developer.apple.com/documentation/metrickit)

## 实施设计

GitHub CLI 官方命令手册：[`gh run view`](https://cli.github.com/manual/gh_run_view)、[`gh run download`](https://cli.github.com/manual/gh_run_download)。

- 事件新增 `processSessionID`、单调递增 `sequenceNumber`、`#fileID`/`#function`/`#line` 和最多 5 层 `NSUnderlyingErrorKey` 链。新字段可选，旧 JSONL 记录无需迁移。
- MetricKit JSON 在入库前递归删除凭据、令牌、用户/设备标识和联系方式字段；字符串仍执行凭据、Bearer、邮箱和 URL 查询参数脱敏。原始未过滤 payload 不写入磁盘。
- 使用 SHA-256 对脱敏报告去重。单份报告最多 8 MiB；事件日志仍为每文件 2 MiB；事件与报告共用 20 MiB 和 14 天保留限制。
- 报告和 JSONL 都存放在受文件保护、排除备份的 Application Support 目录。清空功能同时删除两类诊断数据，但保留同步业务数据。
- 存储健康计数只统计当前进程启动以来的事件/报告写入失败、维护失败、轮转和清理结果，并保留最近错误域/码/脱敏说明；写入失败走 fallback `os.Logger`，不影响同步与 App Intent 行为。
- 导出 schema 升为 2，报告作为嵌套 JSON 对象保存，不编码成 Base64；报告详情支持查看和一键复制。
- GitHub workflow 继续在 `macos-15` 构建设备 Release app，增加独立 dSYM artifact，并按架构核对 app 与 dSYM 的 UUID。
- GitHub CLI 文档确认可用 `gh run view <run-id> --json status,conclusion,headSha` 查询运行状态与提交，再用 `gh run download <run-id> --repo lu1ul/HealthMi-private --name <artifact> --dir <目录>` 按 run ID 下载并解压指定 artifact。

## 过程记录

- `d07ec25 docs: plan MetricKit diagnostic logging`：保存实施计划和验收步骤。
- `273a648 feat: enrich diagnostic event context and storage health`：提交进程上下文、脱敏错误链、MetricKit JSON 模型/本地存储、错误统计、共用保留策略、schema v2 导出底层和 build 5/dSYM 项目设置。
- `abdbbaf feat: persist MetricKit diagnostic reports locally`：应用启动时注册 MetricKit 订阅，并记录 API 限制和当前仓库状态。
- `744bfc9 feat: view and export MetricKit diagnostics`：诊断日志页增加存储健康、MetricKit 报告查看/复制和事件上下文详情。
- `22f8392 build: archive matching dSYM for diagnostic IPA`：Release 输出启用 dSYM，校验 source app、unsigned IPA、TrollStore IPA 与 dSYM 的 UUID，并上传独立 dSYM artifact。
- 2026-11-27 GitHub CLI 检查：当前登录用户为 `lu1ul`；`lu1ul/HealthMi-private` 的默认分支是 `main`，仓库当前公开（`isPrivate=false`）。
- 当前阶段：提交上述编译修复后，重新触发 `personal` 远程的 GitHub Actions；通过后再由 `gh` 下载并核验 IPA 与 dSYM。
- 2026-11-27 workflow run `45933997852`（提交 `22f83925ea63f1f1e4bfdcf632b378be5fd0485d`）已通过 checkout、Xcode 16.4 工具安装与 XcodeGen 工程生成，但 Swift 编译失败：`DiagnosticsLogView.swift:29` 的搜索字段数组表达式触发编译器“unable to type-check this expression in reasonable time”。无 IPA/dSYM artifact 生成。
- 修复：把事件搜索字段拼接移入 `matchesSearch(_:query:)`，拆开错误链与 metadata 字段追加；移除 `DiagnosticJSONValue` 单值 JSON null 检查上的冗余 `try`。待新 run 验证。
- 下一阶段：完成 MetricKit 订阅启动、workflow dSYM 归档与 build number 5，提交后通过 `personal` 远程触发构建。
- 构建下载固定使用 GitHub CLI `gh`，不使用浏览器；推送目标固定为 `personal`（`lu1ul/HealthMi-private`），不得推送 `origin`（`ShawnDiego/HealthMi`）。
- 本机为 Windows，当前没有 `xcodebuild`；不新增、不运行测试套件。验收使用 GitHub Actions 构建和 IPA/dSYM 静态核验。

## 构建与产物核验

尚未开始。构建完成后在此记录 workflow run ID、提交 SHA、IPA/dSYM 本地路径和 SHA-256、Bundle ID、版本、最低系统版本、App Intents metadata、entitlements 与 dSYM UUID 比对结果。
