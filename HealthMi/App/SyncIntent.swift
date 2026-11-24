import AppIntents
import Foundation

/// "同步健康数据" App Intent：只负责快速校验并把完整同步排入后台。
///
/// Intent 返回时同步通常尚未开始。最终结果通过本地通知、同步历史以及
/// `QueryLatestSyncStatusIntent` 查询；这样不会让快捷指令一直等待网络和 HealthKit。
struct SyncHealthDataIntent: AppIntent {
    nonisolated static let title: LocalizedStringResource = "同步健康数据"
    nonisolated static let description = IntentDescription("排队从小米云端拉取最新健康数据并写入 Apple 健康")
    nonisolated static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult {
        do {
            CredentialStore.migrateIfNeeded()
            _ = try await AppDatabase.shared.prepare()
            try SyncRunStore.markStale()

            guard let active = try SyncRunStore.active() else {
                let dialog = try enqueueRun()
                return .result(dialog: IntentDialog(stringLiteral: dialog))
            }

            return .result(dialog: IntentDialog(stringLiteral: activeDialog(for: active)))
        } catch {
            let details = SyncErrorDetails.from(error)
            return .result(dialog: IntentDialog(stringLiteral: details.summary))
        }
    }

    @MainActor
    private func enqueueRun() throws -> String {
        guard CredentialStore.loadThrowing() != nil else {
            throw AppError.noCredentials
        }
        guard HealthKitManager.isAvailable else {
            throw AppError.healthKitUnavailable
        }

        let record = try SyncRunStore.create(trigger: .shortcut)
        do {
            try BackgroundSync.schedule(immediate: true)
        } catch {
            let details = SyncErrorDetails.from(error)
            try? SyncRunStore.finish(id: record.id, status: .failed, topLevelError: details)
            throw error
        }

        let dialog = [
            "已排队（运行 ID：\(record.shortID)）",
            "排队时间：\(record.queuedAt.formatted(date: .abbreviated, time: .shortened))",
            "后台同步由系统稍后执行。完成后会发送详细通知；可运行“查询最近同步状态”查看结果。",
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
}

/// 查询最近一次同步的运行级状态和详细错误。
struct QueryLatestSyncStatusIntent: AppIntent {
    nonisolated static let title: LocalizedStringResource = "查询最近同步状态"
    nonisolated static let description = IntentDescription("查看 HealthMi 最近一次同步的排队状态、成功类型和详细错误")
    nonisolated static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult {
        do {
            try SyncRunStore.markStale()
            guard let record = try SyncRunStore.latestThrowing() else {
                return .result(dialog: IntentDialog(stringLiteral: "暂无同步运行记录。"))
            }
            return .result(dialog: IntentDialog(stringLiteral: record.dialogText))
        } catch {
            let details = SyncErrorDetails.from(error)
            return .result(dialog: IntentDialog(stringLiteral: details.summary))
        }
    }
}

/// 快捷指令注册：Siri / 快捷指令 App 中可搜索到同步和状态查询动作。
struct HealthMiShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        [
            AppShortcut(
                intent: SyncHealthDataIntent(),
                phrases: [
                    "同步\(.applicationName)健康数据",
                    "同步\(.applicationName)",
                    "\(.applicationName)健康同步",
                ],
                shortTitle: "同步健康数据",
                systemImageName: "arrow.triangle.2.circlepath"
            ),
            AppShortcut(
                intent: QueryLatestSyncStatusIntent(),
                phrases: [
                    "查询\(.applicationName)最近同步状态",
                    "查看\(.applicationName)同步状态",
                ],
                shortTitle: "查询同步状态",
                systemImageName: "info.circle"
            ),
        ]
    }
}
