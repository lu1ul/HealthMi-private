import Foundation
import UserNotifications

/// 本地通知管理：后台同步失败时通知用户。
enum NotificationManager {
    static let requestIdentifier = "sync-failed"

    /// 请求通知授权。
    static func requestAuthorization() async {
        let center = UNUserNotificationCenter.current()
        do {
            _ = try await center.requestAuthorization(options: [.alert, .sound])
        } catch {
            // 授权失败时静默跳过，不影响主功能
        }
    }

    /// 检查是否已授权。
    static func isAuthorized() async -> Bool {
        await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                continuation.resume(returning: settings.authorizationStatus == .authorized)
            }
        }
    }

    /// 发送同步失败本地通知。
    static func notifySyncFailure(_ errorDescription: String) async {
        guard await isAuthorized() else { return }

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
        } catch {
            // 通知发送失败不影响主功能
        }
    }

    /// 发送一次运行级同步结果，保留成功/失败类型和具体错误。
    static func notifySyncResult(_ record: SyncRunRecord) async {
        guard await isAuthorized() else { return }

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
        } catch {
            // 通知发送失败不影响已保存的运行结果。
        }
    }
}
