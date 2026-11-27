import AppIntents
import Foundation

private struct ShortcutInvocation {
    let id = UUID().uuidString
    let startedAt = Date()

    var durationMilliseconds: String {
        String(max(0, Int(Date().timeIntervalSince(startedAt) * 1_000)))
    }

    func metadata(_ values: [String: String] = [:]) -> [String: String] {
        var result = values
        result["invocationID"] = id
        result["durationMs"] = durationMilliseconds
        return result
    }
}

private func recordIntentReturn(
    eventPrefix: String,
    invocation: ShortcutInvocation,
    branch: String,
    status: String? = nil,
    runID: UUID? = nil,
    level: DiagnosticLogLevel = .info,
    error: Error? = nil
) {
    var metadata = ["resultBranch": branch]
    if let status { metadata["status"] = status }
    let values = invocation.metadata(metadata)
    DiagnosticLogger.record(
        level,
        category: .appIntent,
        event: "\(eventPrefix).result_prepared",
        message: "已准备快捷指令结果",
        runID: runID,
        error: error,
        metadata: values
    )
    DiagnosticLogger.record(
        level,
        category: .appIntent,
        event: "\(eventPrefix).returning",
        message: "即将返回快捷指令结果",
        runID: runID,
        error: error,
        metadata: values
    )
}

/// "同步健康数据" App Intent：在后台直接执行一次增量同步，并返回运行结果文本。
struct SyncHealthDataIntent: AppIntent {
    nonisolated static let title: LocalizedStringResource = "同步健康数据"
    nonisolated static let description = IntentDescription("立即增量同步小米健康数据并写入 Apple 健康")
    nonisolated static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        defer { DiagnosticLogger.flush() }
        let invocation = ShortcutInvocation()
        let executionContext = SyncExecutionContext.shortcut(startedAt: invocation.startedAt)
        var runID: UUID?
        DiagnosticLogger.record(
            .info,
            category: .appIntent,
            event: "shortcut.sync.perform.started",
            message: "快捷指令开始直接执行增量同步",
            metadata: invocation.metadata([
                "executionBudgetSeconds": String(Int(SyncExecutionContext.shortcutBudget)),
                "requestTimeoutSeconds": String(Int(executionContext.requestPolicy.requestTimeoutInterval)),
                "automaticRetries": String(executionContext.requestPolicy.maxRetries),
            ])
        )
        do {
            try SyncRunStore.markStale(invocationID: invocation.id)
            if let active = try SyncRunStore.active() {
                if active.status == .running {
                    DiagnosticLogger.record(
                        .notice,
                        category: .appIntent,
                        event: "shortcut.sync.perform.reused_running",
                        message: "已有同步正在运行，快捷指令不会重复启动",
                        runID: active.id,
                        metadata: invocation.metadata([
                            "status": active.status.rawValue,
                            "trigger": active.trigger.rawValue,
                        ])
                    )
                    recordIntentReturn(
                        eventPrefix: "shortcut.sync.perform",
                        invocation: invocation,
                        branch: "reused_running",
                        status: active.status.rawValue,
                        runID: active.id
                    )
                    return .result(value: active.dialogText)
                }

                runID = active.id
                DiagnosticLogger.record(
                    .notice,
                    category: .appIntent,
                    event: "shortcut.sync.perform.resumed_queued_directly",
                    message: "快捷指令直接领取已有排队运行并开始同步",
                    runID: active.id,
                    metadata: invocation.metadata([
                        "status": active.status.rawValue,
                        "trigger": active.trigger.rawValue,
                    ])
                )
            } else {
                let record = try SyncRunStore.create(trigger: .shortcut)
                runID = record.id
                DiagnosticLogger.record(
                    .info,
                    category: .appIntent,
                    event: "shortcut.sync.run.created",
                    message: "已创建快捷指令直接同步运行记录",
                    runID: record.id,
                    metadata: invocation.metadata([
                        "status": record.status.rawValue,
                        "trigger": record.trigger.rawValue,
                    ])
                )
            }

            guard let runID else {
                throw NSError(domain: "HealthMi.SyncRun", code: 500, userInfo: [
                    NSLocalizedDescriptionKey: "未能创建快捷指令同步运行记录。",
                ])
            }
            let container = try await AppDatabase.shared.prepare()
            let model = AppModel()
            model.bootstrap()
            let status = await model.syncAll(
                modelContext: container.viewContext,
                executionContext: executionContext,
                runID: runID
            )
            let record = SyncRunStore.record(for: runID)
            let fallbackResult = [
                "同步结束：\(status.displayName)（运行 ID：\(String(runID.uuidString.prefix(8)))）。",
                model.lastError ?? model.statusMessage,
            ].filter { !$0.isEmpty }.joined(separator: "\n")
            let resultText = record?.dialogText ?? fallbackResult
            DiagnosticLogger.record(
                status == .succeeded ? .info : .warning,
                category: .appIntent,
                event: "shortcut.sync.perform.direct_completed",
                message: "快捷指令直接同步执行结束",
                runID: runID,
                metadata: invocation.metadata([
                    "status": record?.status.rawValue ?? status.rawValue,
                    "executionDurationMs": String(
                        max(0, Int(Date().timeIntervalSince(invocation.startedAt) * 1_000))
                    ),
                    "completedTypeCount": String(record?.successfulItems.count ?? 0),
                    "failedTypeCount": String(record?.failedItems.count ?? 0),
                ])
            )
            recordIntentReturn(
                eventPrefix: "shortcut.sync.perform",
                invocation: invocation,
                branch: "direct_completed",
                status: record?.status.rawValue ?? status.rawValue,
                runID: runID,
                level: status == .succeeded ? .info : .warning
            )
            return .result(value: resultText)
        } catch {
            let details = SyncErrorDetails.from(error)
            var resultText = "同步启动失败：\(details.summary)"
            if let runID {
                if SyncRunStore.record(for: runID)?.status != .running {
                    do {
                        try SyncRunStore.finish(id: runID, status: .failed, topLevelError: details)
                        resultText = SyncRunStore.record(for: runID)?.dialogText ?? resultText
                    } catch {
                        resultText += "\n运行状态保存失败：\(error.localizedDescription)"
                    }
                }
            }
            DiagnosticLogger.record(
                .error,
                category: .appIntent,
                event: "shortcut.sync.perform.failed",
                message: "快捷指令直接同步失败",
                runID: runID,
                error: error,
                metadata: invocation.metadata([
                    "errorDomain": details.domain,
                    "errorCode": String(details.code),
                ])
            )
            recordIntentReturn(
                eventPrefix: "shortcut.sync.perform",
                invocation: invocation,
                branch: "direct_failed",
                status: "failed",
                runID: runID,
                level: .error,
                error: error
            )
            return .result(value: resultText)
        }
    }
}

/// 查询最近一次同步的运行级状态和详细错误。
struct QueryLatestSyncStatusIntent: AppIntent {
    nonisolated static let title: LocalizedStringResource = "查询同步状态"
    nonisolated static let description = IntentDescription("记录 HealthMi 最近一次同步状态查询；详细结果请在应用内查看")
    nonisolated static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult {
        defer { DiagnosticLogger.flush() }
        let invocation = ShortcutInvocation()
        DiagnosticLogger.record(
            .info,
            category: .appIntent,
            event: "shortcut.status_query.started",
            message: "快捷指令请求查询同步状态",
            metadata: invocation.metadata()
        )
        do {
            try SyncRunStore.markStale(invocationID: invocation.id)
            guard let record = try SyncRunStore.latestThrowing() else {
                DiagnosticLogger.record(
                    .notice,
                    category: .appIntent,
                    event: "shortcut.status_query.empty",
                    message: "当前没有同步运行记录",
                    metadata: invocation.metadata()
                )
                recordIntentReturn(
                    eventPrefix: "shortcut.status_query.perform",
                    invocation: invocation,
                    branch: "empty"
                )
                return .result()
            }
            DiagnosticLogger.record(
                .info,
                category: .appIntent,
                event: "shortcut.status_query.completed",
                message: "已读取最近同步运行状态，详细内容可在应用内查看",
                runID: record.id,
                metadata: invocation.metadata([
                    "status": record.status.rawValue,
                    "trigger": record.trigger.rawValue,
                    "queuedAtEpochSeconds": String(Int(record.queuedAt.timeIntervalSince1970)),
                    "queueAgeSeconds": String(max(0, Int(Date().timeIntervalSince(record.queuedAt)))),
                ])
            )
            recordIntentReturn(
                eventPrefix: "shortcut.status_query.perform",
                invocation: invocation,
                branch: "record_found",
                status: record.status.rawValue,
                runID: record.id
            )
            return .result()
        } catch {
            let details = SyncErrorDetails.from(error)
            DiagnosticLogger.record(
                .error,
                category: .appIntent,
                event: "shortcut.status_query.failed",
                message: "快捷指令查询同步状态失败",
                error: error,
                metadata: invocation.metadata([
                    "errorDomain": details.domain,
                    "errorCode": String(details.code),
                ])
            )
            recordIntentReturn(
                eventPrefix: "shortcut.status_query.perform",
                invocation: invocation,
                branch: "error_result",
                status: "failed",
                level: .error,
                error: error
            )
            return .result()
        }
    }
}

/// 快捷指令注册：Siri / 快捷指令 App 中可搜索到同步和状态查询动作。
struct HealthMiShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SyncHealthDataIntent(),
            phrases: [
                "同步\(.applicationName)健康数据",
                "同步\(.applicationName)",
                "\(.applicationName)健康同步",
            ],
            shortTitle: "同步健康数据",
            systemImageName: "arrow.triangle.2.circlepath"
        )
        AppShortcut(
            intent: QueryLatestSyncStatusIntent(),
            phrases: [
                "查询\(.applicationName)同步状态",
                "查询\(.applicationName)最近同步状态",
                "查看\(.applicationName)同步结果",
            ],
            shortTitle: "查询同步状态",
            systemImageName: "info.circle"
        )
    }
}
