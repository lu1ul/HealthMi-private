import Foundation

/// 按同步入口限制副作用与执行时间。
enum SyncExecutionContext {
    case foreground
    case background
    case shortcut(deadline: Date)

    static let shortcutBudget: TimeInterval = 22

    static func shortcut(startedAt: Date) -> Self {
        .shortcut(deadline: startedAt.addingTimeInterval(shortcutBudget))
    }

    var trigger: SyncRunTrigger {
        switch self {
        case .foreground: return .app
        case .background: return .background
        case .shortcut: return .shortcut
        }
    }

    var requestPolicy: MiRequestPolicy {
        switch self {
        case .foreground, .background:
            return .standard
        case .shortcut(let deadline):
            return .shortcut(deadline: deadline)
        }
    }

    var mayRequestHealthKitAuthorization: Bool {
        if case .shortcut = self { return false }
        return true
    }

    var refreshesDashboard: Bool {
        if case .shortcut = self { return false }
        return true
    }

    var sendsBackgroundNotification: Bool {
        if case .background = self { return true }
        return false
    }

    var isShortcut: Bool {
        if case .shortcut = self { return true }
        return false
    }

    var deadline: Date? {
        guard case .shortcut(let deadline) = self else { return nil }
        return deadline
    }

    /// 在总预算截止前一秒停止启动新工作。
    var hasReachedSafetyDeadline: Bool {
        guard let deadline else { return false }
        return Date() >= deadline.addingTimeInterval(-1)
    }
}
