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

    @MainActor
    static func register(syncHandler: @escaping @MainActor () async -> SyncRunStatus) {
        guard !didAttemptRegistration else {
            DiagnosticLogger.record(
                .debug,
                category: .backgroundTask,
                event: "background.register.skipped",
                message: "本进程已尝试注册后台任务处理器"
            )
            return
        }
        didAttemptRegistration = true
        DiagnosticLogger.record(
            .info,
            category: .backgroundTask,
            event: "background.register.started",
            message: "开始注册 BGAppRefreshTask 处理器",
            metadata: ["taskIdentifier": taskIdentifier]
        )
        let registered = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: taskIdentifier,
            using: nil
        ) { task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                DiagnosticLogger.record(
                    .error,
                    category: .backgroundTask,
                    event: "background.handler.invalid_task",
                    message: "后台任务类型不是 BGAppRefreshTask"
                )
                DiagnosticLogger.flush()
                task.setTaskCompleted(success: false)
                return
            }
            DiagnosticLogger.record(
                .info,
                category: .backgroundTask,
                event: "background.handler.started",
                message: "系统启动后台刷新处理器"
            )
            try? schedule()
            let completionGate = CompletionGate()
            func complete(_ success: Bool) {
                completionGate.run {
                    DiagnosticLogger.flush()
                    refreshTask.setTaskCompleted(success: success)
                }
            }

            refreshTask.expirationHandler = {
                // 系统即将挂起进程，取消正在进行的同步
                DiagnosticLogger.record(
                    .warning,
                    category: .backgroundTask,
                    event: "background.task.expired",
                    message: "系统通知后台刷新任务即将过期"
                )
                Task { @MainActor in
                    syncTask?.cancel()
                    if let active = try? SyncRunStore.active(),
                       active.status == .running {
                        DiagnosticLogger.record(
                            .warning,
                            category: .backgroundTask,
                            event: "background.sync.cancelled_by_expiration",
                            message: "后台运行因系统执行时限而取消",
                            runID: active.id
                        )
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
                let activeRunID = (try? SyncRunStore.active())?.id
                let status = await syncHandler()
                guard !Task.isCancelled else {
                    DiagnosticLogger.record(
                        .notice,
                        category: .backgroundTask,
                        event: "background.handler.cancelled",
                        message: "后台刷新处理器任务已取消",
                        runID: activeRunID
                    )
                    complete(false)
                    syncTask = nil
                    return
                }
                DiagnosticLogger.record(
                    status == .succeeded ? .info : .warning,
                    category: .backgroundTask,
                    event: "background.handler.completed",
                    message: "后台刷新处理器完成：\(status.displayName)",
                    runID: activeRunID,
                    metadata: ["status": status.rawValue]
                )
                complete(status == .succeeded)
                syncTask = nil
            }
        }
        DiagnosticLogger.record(
            registered ? .info : .error,
            category: .backgroundTask,
            event: registered ? "background.register.succeeded" : "background.register.failed",
            message: registered ? "后台任务处理器注册成功" : "后台任务处理器注册失败",
            metadata: ["taskIdentifier": taskIdentifier]
        )
        if !registered {
            AppLog.backgroundSync.error(
                "BGTask 注册失败，请检查 BGTaskSchedulerPermittedIdentifiers"
            )
        }
    }

    static func schedule(immediate: Bool = false) throws {
        DiagnosticLogger.record(
            .info,
            category: .backgroundTask,
            event: "background.schedule.started",
            message: "提交后台刷新请求",
            metadata: [
                "taskIdentifier": taskIdentifier,
                "immediate": String(immediate),
                "earliestDelaySeconds": immediate ? "1" : "3600",
            ]
        )
        let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: immediate ? 1 : 60 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
            DiagnosticLogger.record(
                .info,
                category: .backgroundTask,
                event: "background.schedule.completed",
                message: "后台刷新请求提交成功",
                metadata: ["taskIdentifier": taskIdentifier]
            )
        } catch {
            AppLog.backgroundSync.error("后台同步调度失败：\(error.localizedDescription)")
            DiagnosticLogger.record(
                .error,
                category: .backgroundTask,
                event: "background.schedule.failed",
                message: "提交后台刷新请求失败",
                error: error,
                metadata: ["taskIdentifier": taskIdentifier]
            )
            throw error
        }
    }
}
