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
        let container = NSPersistentContainer(
            name: "HealthMiCoreData",
            managedObjectModel: CoreDataSchema.makeModel()
        )

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            container.loadPersistentStores { _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }

        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        container.viewContext.automaticallyMergesChangesFromParent = true

        if #available(iOS 17.0, *) {
            try LegacySwiftDataImporter.importIfNeeded(into: container.viewContext)
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

    init() {
        // BGTask 处理器必须在进程启动时注册，不能依赖 SwiftUI 场景先出现。
        BackgroundSync.register {
            do {
                let container = try await AppDatabase.shared.prepare()
                let backgroundModel = AppModel()
                backgroundModel.bootstrap()
                await backgroundModel.syncAll(modelContext: container.viewContext, isBackground: true)
                return backgroundModel.lastError == nil
            } catch {
                AppLog.backgroundSync.error("后台数据库准备失败：\(error.localizedDescription)")
                return false
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
        }
    }

    @MainActor
    private func prepareDatabase() async {
        guard !databaseReady else { return }
        databaseError = nil
        do {
            _ = try await AppDatabase.shared.prepare()
            model.bootstrap()
            await NotificationManager.requestAuthorization()
            databaseReady = true
            BackgroundSync.schedule()
        } catch {
            databaseError = error.localizedDescription
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
