import Foundation
import UserNotifications

/// 本地通知管理：后台同步失败时通知用户。
enum NotificationManager {
    static let requestIdentifier = "sync-failed"

    /// 请求通知授权。
    static func requestAuthorization() async {
        let center = UNUserNotificationCenter.current()
        DiagnosticLogger.record(
            .debug,
            category: .notification,
            event: "notification.authorization.request.started",
            message: "开始请求系统通知权限",
            metadata: ["options": "alert,sound"]
        )
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound])
            DiagnosticLogger.record(
                granted ? .info : .notice,
                category: .notification,
                event: "notification.authorization.request.completed",
                message: granted ? "系统通知权限请求已允许" : "系统通知权限请求未允许",
                metadata: ["granted": String(granted)]
            )
        } catch {
            DiagnosticLogger.record(
                .warning,
                category: .notification,
                event: "notification.authorization.request.failed",
                message: "请求系统通知权限失败，不影响主要同步功能",
                error: error
            )
        }
    }

    /// 检查是否已授权。
    static func isAuthorized() async -> Bool {
        let status = await withCheckedContinuation { (continuation: CheckedContinuation<UNAuthorizationStatus, Never>) in
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                continuation.resume(returning: settings.authorizationStatus)
            }
        }
        let authorized = status == .authorized
        DiagnosticLogger.record(
            .debug,
            category: .notification,
            event: "notification.authorization.status.checked",
            message: "已读取系统通知授权状态",
            metadata: [
                "status": String(status.rawValue),
                "authorized": String(authorized),
            ]
        )
        return authorized
    }

    /// 发送同步失败本地通知。
    static func notifySyncFailure(_ errorDescription: String) async {
        guard await isAuthorized() else {
            DiagnosticLogger.record(
                .notice,
                category: .notification,
                event: "notification.sync_failure.skipped",
                message: "系统通知未授权，未提交同步失败通知"
            )
            return
        }

        let content = UNMutableNotificationContent()
        content.title = "HealthMi 同步失败"
        content.body = "同步出错：\(errorDescription)，请打开 App 查看"
        content.sound = .default

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let request = UNNotificationRequest(
            identifier: requestIdentifier, content: content, trigger: trigger
        )
        do {
            try await UNUserNotificationCenter.current().add(request)
            DiagnosticLogger.record(
                .info,
                category: .notification,
                event: "notification.sync_failure.submitted",
                message: "同步失败通知已提交系统",
                metadata: ["identifier": requestIdentifier]
            )
        } catch {
            DiagnosticLogger.record(
                .error,
                category: .notification,
                event: "notification.sync_failure.submit_failed",
                message: "提交同步失败通知失败",
                error: error
            )
        }
    }

    /// 发送一次运行级同步结果，保留成功/失败类型和具体错误。
    static func notifySyncResult(_ record: SyncRunRecord) async {
        guard await isAuthorized() else {
            DiagnosticLogger.record(
                .notice,
                category: .notification,
                event: "notification.sync_result.skipped",
                message: "系统通知未授权，未提交同步运行结果通知",
                runID: record.id,
                metadata: ["status": record.status.rawValue]
            )
            return
        }

        let content = UNMutableNotificationContent()
        switch record.status {
        case .succeeded:
            content.title = "HealthMi 同步完成"
        case .partialFailure:
            content.title = "HealthMi 同步部分失败"
        case .failed:
            content.title = "HealthMi 同步失败"
        case .cancelled:
            content.title = "HealthMi 同步已取消"
        case .queued, .running:
            content.title = "HealthMi 同步状态更新"
        }
        content.body = record.dialogText
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "sync-run-\(record.id.uuidString)",
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        )
        do {
            try await UNUserNotificationCenter.current().add(request)
            DiagnosticLogger.record(
                .info,
                category: .notification,
                event: "notification.sync_result.submitted",
                message: "同步运行结果通知已提交系统",
                runID: record.id,
                metadata: [
                    "status": record.status.rawValue,
                    "failedItemCount": String(record.failedItems.count),
                ]
            )
        } catch {
            DiagnosticLogger.record(
                .error,
                category: .notification,
                event: "notification.sync_result.submit_failed",
                message: "提交同步运行结果通知失败",
                runID: record.id,
                error: error,
                metadata: ["status": record.status.rawValue]
            )
        }
    }
}
