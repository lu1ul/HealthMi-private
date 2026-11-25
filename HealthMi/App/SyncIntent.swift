import AppIntents
import Foundation

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
        let intentStartedAt = Date()
        DiagnosticLogger.record(
            .info,
            category: .appIntent,
            event: "shortcut.sync.perform.started",
            message: "快捷指令请求同步健康数据"
        )
        do {
            try SyncRunStore.markStale()

            guard let active = try SyncRunStore.active() else {
                let dialog = try enqueueRun()
                DiagnosticLogger.record(
                    .info,
                    category: .appIntent,
                    event: "shortcut.sync.perform.queued",
                    message: "快捷指令同步请求已写入运行队列",
                    metadata: ["durationMs": Self.durationMilliseconds(since: intentStartedAt)]
                )
                return .result(dialog: IntentDialog(stringLiteral: dialog))
            }

            DiagnosticLogger.record(
                .notice,
                category: .appIntent,
                event: "shortcut.sync.perform.reused_active_run",
                message: "已有活动运行，快捷指令没有重复排队",
                runID: active.id,
                metadata: ["status": active.status.rawValue]
            )
            return .result(dialog: IntentDialog(stringLiteral: activeDialog(for: active)))
        } catch {
            let details = SyncErrorDetails.from(error)
            DiagnosticLogger.record(
                .error,
                category: .appIntent,
                event: "shortcut.sync.perform.failed",
                message: "快捷指令处理同步请求失败",
                error: error,
                metadata: [
                    "errorDomain": details.domain,
                    "errorCode": String(details.code),
                    "durationMs": Self.durationMilliseconds(since: intentStartedAt),
                ]
            )
            return .result(dialog: IntentDialog(stringLiteral: details.summary))
        }
    }

    @MainActor
    private func enqueueRun() throws -> String {
        let record = try SyncRunStore.create(trigger: .shortcut)
        DiagnosticLogger.record(
            .info,
            category: .appIntent,
            event: "shortcut.sync.run.created",
            message: "已创建快捷指令同步运行记录",
            runID: record.id,
            metadata: ["status": record.status.rawValue]
        )
        let scheduledImmediately: Bool
        do {
            scheduledImmediately = try BackgroundSync.scheduleFromIntentIfRegistered(
                immediate: true
            )
        } catch {
            let details = SyncErrorDetails.from(error)
            try? SyncRunStore.finish(id: record.id, status: .failed, topLevelError: details)
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
            metadata: ["scheduledImmediately": String(scheduledImmediately)]
        )

        let dialog = [
            "已排队（运行 ID：\(record.shortID)）",
            "排队时间：\(record.queuedAt.formatted(date: .abbreviated, time: .shortened))",
            scheduledImmediately
                ? "已提交立即后台调度请求。完成后会发送详细通知。"
                : "运行已保存在本地队列，将由已有周期后台刷新领取。",
            "可运行“查询最近同步状态”查看排队、成功或具体错误。",
        ].joined(separator: "\n")
        return dialog
    }

    private func activeDialog(for record: SyncRunRecord) -> String {
        [
            "已有同步任务（运行 ID：\(record.shortID)）",
            "当前状态：\(record.status.displayName)",
            "排队时间：\(record.queuedAt.formatted(date: .abbreviated, time: .shortened))",
            "不会重复排队；可运行“查询最近同步状态”查看详细结果。",
        ].joined(separator: "\n")
    }

    private static func durationMilliseconds(since start: Date) -> String {
        String(max(0, Int(Date().timeIntervalSince(start) * 1_000)))
    }
}

/// 查询最近一次同步的运行级状态和详细错误。
struct QueryLatestSyncStatusIntent: AppIntent {
    nonisolated static let title: LocalizedStringResource = "查询最近同步状态"
    nonisolated static let description = IntentDescription("查看 HealthMi 最近一次同步的排队状态、成功类型和详细错误")
    nonisolated static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult {
        defer { DiagnosticLogger.flush() }
        DiagnosticLogger.record(
            .info,
            category: .appIntent,
            event: "shortcut.status_query.started",
            message: "快捷指令请求查询最近同步状态"
        )
        do {
            try SyncRunStore.markStale()
            guard let record = try SyncRunStore.latestThrowing() else {
                DiagnosticLogger.record(
                    .notice,
                    category: .appIntent,
                    event: "shortcut.status_query.empty",
                    message: "当前没有同步运行记录"
                )
                return .result(dialog: IntentDialog(stringLiteral: "暂无同步运行记录。"))
            }
            DiagnosticLogger.record(
                .info,
                category: .appIntent,
                event: "shortcut.status_query.completed",
                message: "已返回最近同步运行状态",
                runID: record.id,
                metadata: ["status": record.status.rawValue]
            )
            return .result(dialog: IntentDialog(stringLiteral: record.dialogText))
        } catch {
            let details = SyncErrorDetails.from(error)
            DiagnosticLogger.record(
                .error,
                category: .appIntent,
                event: "shortcut.status_query.failed",
                message: "快捷指令查询同步状态失败",
                error: error,
                metadata: ["errorDomain": details.domain, "errorCode": String(details.code)]
            )
            return .result(dialog: IntentDialog(stringLiteral: details.summary))
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
                "查询\(.applicationName)最近同步状态",
                "查看\(.applicationName)同步状态",
            ],
            shortTitle: "查询同步状态",
            systemImageName: "info.circle"
        )
    }
}
