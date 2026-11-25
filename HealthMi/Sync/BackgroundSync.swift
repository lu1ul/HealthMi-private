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

    /// BGTask 处理器只能注册一次；系统会在同一进程内第二次注册时终止 App。
    @MainActor private static var didAttemptRegistration = false
    @MainActor private static var isLaunchHandlerRegistered = false

    @MainActor
    static func register(syncHandler: @escaping @MainActor () async -> SyncRunStatus) {
        guard !didAttemptRegistration else { return }
        didAttemptRegistration = true
        let registered = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: taskIdentifier,
            using: nil
        ) { task in
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
                    if let active = try? SyncRunStore.active(),
                       active.status == .running {
                        try? SyncRunStore.finish(
                            id: active.id,
                            status: .cancelled,
                            topLevelError: SyncErrorDetails.make(
                                domain: "HealthMi.BackgroundTasks",
                                code: 1,
                                message: "后台任务在完成前到达系统执行时限。"
                            )
                        )
                    }
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
        isLaunchHandlerRegistered = registered
        if !registered {
            AppLog.backgroundSync.error(
                "BGTask 注册失败，请检查 BGTaskSchedulerPermittedIdentifiers"
            )
        }
    }

    /// App Intent 进程不保证走完主 App 启动流程。只有本进程已确认注册 handler
    /// 时才提交立即调度；否则把运行保留在本地队列，由已有周期请求稍后领取。
    @MainActor
    static func scheduleFromIntentIfRegistered(immediate: Bool) throws -> Bool {
        guard isLaunchHandlerRegistered else { return false }
        try schedule(immediate: immediate)
        return true
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
