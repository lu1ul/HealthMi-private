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

/// "同步健康数据" App Intent：只负责把完整同步写入轻量本地队列。
///
/// Intent 返回时同步通常尚未开始。最终结果通过本地通知、同步历史以及
/// `QueryLatestSyncStatusIntent` 查询；这样不会让快捷指令一直等待网络和 HealthKit。
struct SyncHealthDataIntent: AppIntent {
    nonisolated static let title: LocalizedStringResource = "同步健康数据"
    nonisolated static let description = IntentDescription("排队从小米云端拉取最新健康数据并写入 Apple 健康")
    nonisolated static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult {
        defer { DiagnosticLogger.flush() }
        let invocation = ShortcutInvocation()
        DiagnosticLogger.record(
            .info,
            category: .appIntent,
            event: "shortcut.sync.perform.started",
            message: "快捷指令请求同步健康数据",
            metadata: invocation.metadata()
        )
        do {
            try SyncRunStore.markStale(invocationID: invocation.id)

            let record: SyncRunRecord
            let resultBranch: String

            if let active = try SyncRunStore.active() {
                record = active
                resultBranch = active.status == .queued ? "reused_queued" : "reused_running"
                DiagnosticLogger.record(
                    .notice,
                    category: .appIntent,
                    event: "shortcut.sync.perform.reused_active_run",
                    message: "已有活动运行，快捷指令没有重复排队",
                    runID: active.id,
                    metadata: invocation.metadata([
                        "status": active.status.rawValue,
                        "trigger": active.trigger.rawValue,
                        "queuedAtEpochSeconds": String(Int(active.queuedAt.timeIntervalSince1970)),
                        "queueAgeSeconds": String(max(0, Int(Date().timeIntervalSince(active.queuedAt)))),
                    ])
                )

                if active.status == .queued {
                    do {
                        let scheduled = try BackgroundSync.scheduleFromIntentIfRegistered(immediate: true)
                        DiagnosticLogger.record(
                            scheduled ? .info : .notice,
                            category: .appIntent,
                            event: "shortcut.sync.perform.queued_reschedule_attempted",
                            message: scheduled
                                ? "复用中的排队任务已重新提交后台调度请求"
                                : "复用中的排队任务仍在队列中，当前进程未确认后台处理器注册",
                            runID: active.id,
                            metadata: invocation.metadata([
                                "status": active.status.rawValue,
                                "trigger": active.trigger.rawValue,
                                "queueAgeSeconds": String(max(0, Int(Date().timeIntervalSince(active.queuedAt)))),
                                "scheduledImmediately": String(scheduled),
                            ])
                        )
                    } catch {
                        DiagnosticLogger.record(
                            .error,
                            category: .appIntent,
                            event: "shortcut.sync.perform.queued_reschedule_failed",
                            message: "复用中的排队任务重新提交后台调度失败；保留原排队记录",
                            runID: active.id,
                            error: error,
                            metadata: invocation.metadata([
                                "status": active.status.rawValue,
                                "queueAgeSeconds": String(max(0, Int(Date().timeIntervalSince(active.queuedAt)))),
                            ])
                        )
                    }
                }
            } else {
                let enqueueResult = try enqueueRun(invocationID: invocation.id)
                record = enqueueResult.record
                resultBranch = "queued"
                DiagnosticLogger.record(
                    .info,
                    category: .appIntent,
                    event: "shortcut.sync.perform.queued",
                    message: "快捷指令同步请求已写入运行队列",
                    runID: record.id,
                    metadata: invocation.metadata([
                        "status": record.status.rawValue,
                        "scheduledImmediately": String(enqueueResult.scheduledImmediately),
                        "queuedAtEpochSeconds": String(Int(record.queuedAt.timeIntervalSince1970)),
                    ])
                )
            }

            recordIntentReturn(
                eventPrefix: "shortcut.sync.perform",
                invocation: invocation,
                branch: resultBranch,
                status: record.status.rawValue,
                runID: record.id
            )
            return .result()
        } catch {
            let details = SyncErrorDetails.from(error)
            DiagnosticLogger.record(
                .error,
                category: .appIntent,
                event: "shortcut.sync.perform.failed",
                message: "快捷指令处理同步请求失败",
                error: error,
                metadata: invocation.metadata([
                    "errorDomain": details.domain,
                    "errorCode": String(details.code),
                ])
            )
            recordIntentReturn(
                eventPrefix: "shortcut.sync.perform",
                invocation: invocation,
                branch: "error_result",
                status: "failed",
                level: .error,
                error: error
            )
            return .result()
        }
    }

    @MainActor
    private func enqueueRun(invocationID: String) throws -> (record: SyncRunRecord, scheduledImmediately: Bool) {
        let record = try SyncRunStore.create(trigger: .shortcut)
        DiagnosticLogger.record(
            .info,
            category: .appIntent,
            event: "shortcut.sync.run.created",
            message: "已创建快捷指令同步运行记录",
            runID: record.id,
            metadata: [
                "invocationID": invocationID,
                "status": record.status.rawValue,
                "trigger": record.trigger.rawValue,
                "queuedAtEpochSeconds": String(Int(record.queuedAt.timeIntervalSince1970)),
            ]
        )
        let scheduledImmediately: Bool
        do {
            scheduledImmediately = try BackgroundSync.scheduleFromIntentIfRegistered(
                immediate: true
            )
        } catch {
            let details = SyncErrorDetails.from(error)
            try? SyncRunStore.finish(id: record.id, status: .failed, topLevelError: details)
            DiagnosticLogger.record(
                .error,
                category: .appIntent,
                event: "shortcut.sync.run.schedule.failed",
                message: "提交快捷指令后台刷新请求失败",
                runID: record.id,
                error: error,
                metadata: [
                    "invocationID": invocationID,
                    "errorDomain": details.domain,
                    "errorCode": String(details.code),
                ]
            )
            throw error
        }
        DiagnosticLogger.record(
            scheduledImmediately ? .info : .notice,
            category: .appIntent,
            event: "shortcut.sync.run.queue_result",
            message: scheduledImmediately
                ? "运行已排队并提交立即后台调度请求"
                : "运行已排队，等待周期后台刷新领取",
            runID: record.id,
            metadata: [
                "invocationID": invocationID,
                "scheduledImmediately": String(scheduledImmediately),
                "trigger": record.trigger.rawValue,
                "queuedAtEpochSeconds": String(Int(record.queuedAt.timeIntervalSince1970)),
            ]
        )

        return (record, scheduledImmediately)
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
