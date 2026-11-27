import AppIntents
import CoreData
import SwiftUI

/// 前台、后台刷新和快捷指令共用的 Core Data 数据库。
@MainActor
final class AppDatabase {
    static let shared = AppDatabase()

    private(set) var container: NSPersistentContainer?
    private var preparationTask: Task<Void, Error>?

    private init() {}

    func prepare() async throws -> NSPersistentContainer {
        if let container { return container }
        if let preparationTask {
            do {
                try await preparationTask.value
                self.preparationTask = nil
                guard let container else { throw AppDatabaseError.containerNotReady }
                return container
            } catch {
                self.preparationTask = nil
                throw error
            }
        }

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            self.container = try await Self.loadContainer()
        }
        preparationTask = task
        do {
            try await task.value
            preparationTask = nil
            guard let container else { throw AppDatabaseError.containerNotReady }
            return container
        } catch {
            preparationTask = nil
            throw error
        }
    }

    private static func loadContainer() async throws -> NSPersistentContainer {
        DiagnosticLogger.record(
            .info,
            category: .storage,
            event: "coredata.load.started",
            message: "开始加载 Core Data 持久化存储"
        )
        let container = NSPersistentContainer(
            name: "HealthMiCoreData",
            managedObjectModel: CoreDataSchema.makeModel()
        )

        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                container.loadPersistentStores { _, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            }
            DiagnosticLogger.record(
                .info,
                category: .storage,
                event: "coredata.load.completed",
                message: "Core Data 持久化存储加载完成"
            )
        } catch {
            DiagnosticLogger.record(
                .error,
                category: .storage,
                event: "coredata.load.failed",
                message: "Core Data 持久化存储加载失败",
                error: error
            )
            throw error
        }

        container.viewContext.mergePolicy = NSMergePolicy(
            merge: .mergeByPropertyObjectTrumpMergePolicyType
        )
        container.viewContext.automaticallyMergesChangesFromParent = true

        if #available(iOS 17.0, *) {
            DiagnosticLogger.record(
                .info,
                category: .storage,
                event: "migration.swiftdata.check.started",
                message: "检查是否需要导入旧版 SwiftData 记录"
            )
            do {
                try LegacySwiftDataImporter.importIfNeeded(into: container.viewContext)
                DiagnosticLogger.record(
                    .info,
                    category: .storage,
                    event: "migration.swiftdata.check.completed",
                    message: "旧版 SwiftData 导入检查完成"
                )
            } catch {
                DiagnosticLogger.record(
                    .error,
                    category: .storage,
                    event: "migration.swiftdata.failed",
                    message: "旧版 SwiftData 导入失败",
                    error: error
                )
                throw error
            }
        }

        return container
    }
}

private enum AppDatabaseError: LocalizedError {
    case containerNotReady

    var errorDescription: String? {
        "本地数据库准备未完成，请重试。"
    }
}

@main
@MainActor
struct HealthMiApp: App {
    @StateObject private var model = AppModel()
    @State private var databaseReady = false
    @State private var databaseError: String?
    @Environment(\.scenePhase) private var scenePhase

    init() {
        DiagnosticLogger.record(
            .info,
            category: .appLifecycle,
            event: "app.launch",
            message: "HealthMi 应用进程启动",
            metadata: [
                "appVersion": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
                "buildNumber": Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown",
                "systemVersion": ProcessInfo.processInfo.operatingSystemVersionString,
            ]
        )
        MetricKitDiagnosticsSubscriber.shared.start()
        HealthMiShortcuts.updateAppShortcutParameters()
        DiagnosticLogger.record(
            .info,
            category: .appIntent,
            event: "shortcut.discovery.refresh.requested",
            message: "应用启动时已请求系统刷新 HealthMi 快捷指令信息"
        )
        // BGTask 处理器必须在进程启动时注册，不能依赖 SwiftUI 场景先出现。
        BackgroundSync.register {
            let claim: (record: SyncRunRecord, shouldRun: Bool)
            do {
                claim = try SyncRunStore.claimForBackground()
            } catch {
                AppLog.backgroundSync.error("创建后台同步运行记录失败：\(error.localizedDescription)")
                DiagnosticLogger.record(
                    .critical,
                    category: .backgroundTask,
                    event: "background.run.claim.failed",
                    message: "领取或创建后台同步运行记录失败",
                    error: error
                )
                return .failed
            }

            guard claim.shouldRun else {
                DiagnosticLogger.record(
                    .notice,
                    category: .backgroundTask,
                    event: "background.run.claim.skipped",
                    message: "已有后台同步处于运行状态，本次任务没有重复执行",
                    runID: claim.record.id,
                    metadata: ["status": claim.record.status.rawValue]
                )
                return .succeeded
            }
            let run = claim.record
            DiagnosticLogger.record(
                .info,
                category: .backgroundTask,
                event: "background.run.claimed",
                message: "后台刷新已领取同步运行",
                runID: run.id,
                metadata: ["trigger": run.trigger.rawValue, "status": run.status.rawValue]
            )
            try? SyncRunStore.markRunning(run.id)

            do {
                let container = try await AppDatabase.shared.prepare()
                let backgroundModel = AppModel()
                backgroundModel.bootstrap()
                let status = await backgroundModel.syncAll(
                    modelContext: container.viewContext,
                    executionContext: .background,
                    runID: run.id
                )
                return status
            } catch {
                AppLog.backgroundSync.error("后台数据库准备失败：\(error.localizedDescription)")
                let details = SyncErrorDetails.from(error)
                DiagnosticLogger.record(
                    .critical,
                    category: .backgroundTask,
                    event: "background.run.failed_before_sync",
                    message: "后台同步在进入数据处理前失败",
                    runID: run.id,
                    error: error,
                    metadata: ["errorDomain": details.domain, "errorCode": String(details.code)]
                )
                try? SyncRunStore.finish(id: run.id, status: .failed, topLevelError: details)
                if let record = SyncRunStore.record(for: run.id) {
                    await NotificationManager.notifySyncResult(record)
                }
                return .failed
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if databaseReady, let container = AppDatabase.shared.container {
                    RootView()
                        .environmentObject(model)
                        .environment(\.managedObjectContext, container.viewContext)
                } else {
                    DatabaseBootstrapView(error: databaseError) {
                        await prepareDatabase()
                    }
                }
            }
            .task {
                await prepareDatabase()
            }
            .onChange(of: scenePhase) { phase in
                let phaseName: String
                switch phase {
                case .active: phaseName = "active"
                case .inactive: phaseName = "inactive"
                case .background: phaseName = "background"
                @unknown default: phaseName = "unknown"
                }
                DiagnosticLogger.record(
                    .info,
                    category: .appLifecycle,
                    event: "app.scene_phase.changed",
                    message: "应用场景状态发生变化",
                    metadata: ["phase": phaseName]
                )
            }
        }
    }

    @MainActor
    private func prepareDatabase() async {
        guard !databaseReady else { return }
        databaseError = nil
        DiagnosticLogger.record(
            .info,
            category: .storage,
            event: "app.database.prepare.started",
            message: "开始准备应用数据库"
        )
        do {
            _ = try await AppDatabase.shared.prepare()
            model.bootstrap()
            await NotificationManager.requestAuthorization()
            databaseReady = true
            let hasQueuedRun = (try? SyncRunStore.active()?.status == .queued) ?? false
            try? BackgroundSync.schedule(immediate: hasQueuedRun)
            DiagnosticLogger.record(
                .info,
                category: .storage,
                event: "app.database.prepare.completed",
                message: "应用数据库和启动服务准备完成",
                metadata: ["hasQueuedRun": String(hasQueuedRun)]
            )
        } catch {
            databaseError = error.localizedDescription
            DiagnosticLogger.record(
                .critical,
                category: .storage,
                event: "app.database.prepare.failed",
                message: "应用启动时数据库准备失败",
                error: error
            )
        }
    }
}

private struct DatabaseBootstrapView: View {
    let error: String?
    let retry: @MainActor () async -> Void

    var body: some View {
        VStack(spacing: 16) {
            if let error {
                Image(systemName: "externaldrive.badge.exclamationmark")
                    .font(.largeTitle)
                    .foregroundStyle(.red)
                Text("无法准备本地数据")
                    .font(.headline)
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("重试") {
                    Task { await retry() }
                }
                .buttonStyle(.borderedProminent)
            } else {
                ProgressView("正在准备本地数据…")
            }
        }
        .padding(32)
    }
}
