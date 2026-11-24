import BackgroundTasks
import Foundation
import os

/// BGAppRefreshTask 后台同步（模拟器不会触发，需真机运行验证）。
enum BackgroundSync {
    static let taskIdentifier = "com.healthmi.HealthMi.sync"

    /// BGTask 可能同时收到 expirationHandler 和同步结束回调；保证只完成一次。
    private final class CompletionGate: @unchecked Sendable {
        private let lock = OSAllocatedUnfairLock(initialState: false)

        func run(_ action: () -> Void) {
            let shouldRun = lock.withLock { completed in
                guard !completed else { return false }
                completed = true
                return true
            }
            guard shouldRun else { return }
            action()
        }
    }

    /// 当前后台同步 Task 引用，用于 expirationHandler 取消。
    @MainActor private static var syncTask: Task<Void, Never>?

    /// BGTask 处理器只能注册一次，重复注册同一标识符会抛异常。
    @MainActor private static var didRegister = false

    @MainActor
    static func register(syncHandler: @escaping @MainActor () async -> SyncRunStatus) {
        guard !didRegister else { return }
        didRegister = true
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskIdentifier, using: nil) { task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            try? schedule()
            let completionGate = CompletionGate()
            func complete(_ success: Bool) {
                completionGate.run {
                    refreshTask.setTaskCompleted(success: success)
                }
            }

            refreshTask.expirationHandler = {
                // 系统即将挂起进程，取消正在进行的同步
                Task { @MainActor in
                    syncTask?.cancel()
                }
                complete(false)
            }
            syncTask = Task { @MainActor in
                let status = await syncHandler()
                guard !Task.isCancelled else {
                    complete(false)
                    syncTask = nil
                    return
                }
                complete(status == .succeeded)
                syncTask = nil
            }
        }
    }

    static func schedule(immediate: Bool = false) throws {
        let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: immediate ? 1 : 60 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            AppLog.backgroundSync.error("后台同步调度失败：\(error.localizedDescription)")
            throw error
        }
    }
}
