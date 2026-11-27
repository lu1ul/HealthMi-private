import Foundation

/// 触发一次同步的入口。
enum SyncRunTrigger: String, Codable, Sendable {
    case shortcut
    case background
    case app

    var displayName: String {
        switch self {
        case .shortcut: return "快捷指令"
        case .background: return "后台刷新"
        case .app: return "App"
        }
    }
}

/// 一次同步运行的生命周期状态。
enum SyncRunStatus: String, Codable, Sendable {
    case queued
    case running
    case succeeded
    case partialFailure
    case failed
    case cancelled

    var displayName: String {
        switch self {
        case .queued: return "已排队"
        case .running: return "同步中"
        case .succeeded: return "同步成功"
        case .partialFailure: return "部分失败"
        case .failed: return "同步失败"
        case .cancelled: return "已取消"
        }
    }
}

/// 可跨进程保存的错误详情。
struct SyncErrorDetails: Codable, Hashable, Sendable {
    let domain: String
    let code: Int
    let message: String

    /// 面向快捷指令、通知和同步历史的完整错误文本。
    var summary: String {
        "\(domain) / code=\(code)：\(message)"
    }

    static func make(domain: String, code: Int = 0, message: String) -> Self {
        Self(domain: domain, code: code, message: message)
    }

    /// 将项目内错误和系统 NSError 统一为可持久化结构。
    static func from(_ error: Error) -> Self {
        switch error {
        case let error as AppError:
            return Self(domain: "HealthMi.App", code: error.code, message: error.localizedDescription)

        case let error as MiAPIError:
            switch error {
            case .api(let code, _):
                return Self(domain: "MiAPI", code: code, message: error.localizedDescription)
            case .http(let code):
                return Self(domain: "HTTP", code: code, message: error.localizedDescription)
            case .network(let underlying):
                let nsError = underlying as NSError
                return Self(
                    domain: nsError.domain,
                    code: nsError.code,
                    message: error.localizedDescription
                )
            case .notConnected, .paginationLimit, .cursorLoop:
                return Self(domain: "MiAPI", code: 0, message: error.localizedDescription)
            case .executionDeadlineExceeded:
                return Self(domain: "HealthMi.AppIntent", code: 408, message: error.localizedDescription)
            case .invalidResponse:
                return Self(domain: "MiAPI", code: 0, message: error.localizedDescription)
            }

        case let error as MiLoginError:
            switch error {
            case .loginRejected(let code, _):
                return Self(domain: "MiLogin", code: code ?? 0, message: error.localizedDescription)
            case .network(let underlying):
                let nsError = underlying as NSError
                return Self(
                    domain: nsError.domain,
                    code: nsError.code,
                    message: error.localizedDescription
                )
            case .badPayload:
                return Self(domain: "MiLogin", code: 0, message: error.localizedDescription)
            }

        case let error as CredentialStore.KeychainError:
            return Self(domain: "Security", code: Int(error.status), message: error.localizedDescription)

        default:
            let nsError = error as NSError
            return Self(domain: nsError.domain, code: nsError.code, message: error.localizedDescription)
        }
    }
}

/// 一类同步数据在一次运行中的结果。
struct SyncRunItem: Codable, Hashable, Identifiable, Sendable {
    let typeRawValue: String
    var fetched: Int
    var added: Int
    var success: Bool
    var error: SyncErrorDetails?
    var finishedAt: Date?

    var id: String { typeRawValue }

    var displayName: String {
        SyncDataType(rawValue: typeRawValue)?.displayName ?? typeRawValue
    }
}

/// 一次快捷指令或后台同步的持久化运行记录。
struct SyncRunRecord: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    let trigger: SyncRunTrigger
    let queuedAt: Date
    var startedAt: Date?
    var finishedAt: Date?
    var status: SyncRunStatus
    var items: [String: SyncRunItem]
    var topLevelError: SyncErrorDetails?
    var lastUpdatedAt: Date

    var shortID: String {
        String(id.uuidString.prefix(8))
    }

    var sortedItems: [SyncRunItem] {
        let order = Dictionary(uniqueKeysWithValues: SyncDataType.allCases.enumerated().map {
            ($1.rawValue, $0)
        })
        return items.values.sorted {
            (order[$0.typeRawValue] ?? Int.max) < (order[$1.typeRawValue] ?? Int.max)
        }
    }

    var successfulItems: [SyncRunItem] {
        sortedItems.filter { $0.success }
    }

    var failedItems: [SyncRunItem] {
        sortedItems.filter { !$0.success }
    }

    /// 用于本地通知和同步历史摘要的详细文本。
    var dialogText: String {
        var lines = [
            "\(status.displayName)（运行 ID：\(shortID)）",
            "触发方式：\(trigger.displayName)",
            "\(trigger == .shortcut ? "请求时间" : "排队时间")：\(queuedAt.formatted(date: .abbreviated, time: .shortened))",
        ]

        if let startedAt {
            lines.append("开始时间：\(startedAt.formatted(date: .abbreviated, time: .shortened))")
        }

        if !successfulItems.isEmpty {
            let text = successfulItems.map { "\($0.displayName) +\($0.added)" }.joined(separator: "、")
            lines.append("已完成：\(text)")
        }

        if !failedItems.isEmpty {
            lines.append("失败详情：")
            for item in failedItems {
                let detail = item.error?.summary ?? "未知错误"
                lines.append("- \(item.displayName)：\(detail)")
            }
        }

        if let topLevelError {
            lines.append("运行错误：\(topLevelError.summary)")
        }

        return lines.joined(separator: "\n")
    }
}

enum SyncRunStoreError: LocalizedError {
    case encoding(Error)
    case decoding(Error)

    var errorDescription: String? {
        switch self {
        case .encoding(let error):
            return "保存同步运行记录失败：\(error.localizedDescription)"
        case .decoding(let error):
            return "读取同步运行记录失败：\(error.localizedDescription)"
        }
    }
}

/// 使用共享 UserDefaults 保存运行记录，供 App、BGTask 和 App Intent 读取。
@MainActor
enum SyncRunStore {
    private static let storageKey = "healthmi.sync-runs.v1"
    private static let maximumRecordCount = 30
    private static let staleQueuedInterval: TimeInterval = 24 * 60 * 60
    private static let staleRunningInterval: TimeInterval = 6 * 60 * 60

    static func create(trigger: SyncRunTrigger, now: Date = Date()) throws -> SyncRunRecord {
        let record = SyncRunRecord(
            id: UUID(),
            trigger: trigger,
            queuedAt: now,
            startedAt: nil,
            finishedAt: nil,
            status: .queued,
            items: [:],
            topLevelError: nil,
            lastUpdatedAt: now
        )
        var records = try load()
        records.insert(record, at: 0)
        try save(Array(records.prefix(maximumRecordCount)))
        return record
    }

    static func latest() -> SyncRunRecord? {
        (try? load())?.first
    }

    static func latestThrowing() throws -> SyncRunRecord? {
        try load().first
    }

    static func allThrowing() throws -> [SyncRunRecord] {
        try load()
    }

    static func record(for id: UUID) -> SyncRunRecord? {
        (try? load())?.first { $0.id == id }
    }

    static func active() throws -> SyncRunRecord? {
        try load().first { record in
            record.status == .queued || record.status == .running
        }
    }

    /// 后台任务领取已有排队运行；周期刷新没有排队请求时创建新的运行。
    /// 已有运行中的任务不会被第二个 BGTask 重复执行。
    static func claimForBackground(now: Date = Date()) throws -> (record: SyncRunRecord, shouldRun: Bool) {
        try markStale(now: now)
        if let active = try active() {
            return (active, active.status == .queued)
        }
        return (try create(trigger: .background, now: now), true)
    }

    /// 把超过合理执行时间的运行标成明确失败，避免永久阻塞后续排队。
    static func markStale(now: Date = Date(), invocationID: String? = nil) throws {
        var records = try load()
        var changed = false
        var staleChanges: [(record: SyncRunRecord, ageSeconds: Int, thresholdSeconds: Int)] = []
        for index in records.indices {
            let record = records[index]
            let age = now.timeIntervalSince(record.lastUpdatedAt)
            let threshold: TimeInterval
            switch record.status {
            case .queued:
                threshold = staleQueuedInterval
            case .running:
                threshold = staleRunningInterval
            default:
                continue
            }
            guard age > threshold else { continue }
            staleChanges.append((record, Int(age), Int(threshold)))
            records[index].status = .failed
            records[index].finishedAt = now
            records[index].topLevelError = SyncErrorDetails.make(
                domain: "HealthMi.SyncRun",
                code: 408,
                message: "后台任务未在预期时间内启动或完成，请重新排队。"
            )
            records[index].lastUpdatedAt = now
            changed = true
        }
        if changed {
            try save(records)
            for change in staleChanges {
                var metadata = [
                    "previousStatus": change.record.status.rawValue,
                    "newStatus": SyncRunStatus.failed.rawValue,
                    "trigger": change.record.trigger.rawValue,
                    "queuedAtEpochSeconds": String(Int(change.record.queuedAt.timeIntervalSince1970)),
                    "ageSeconds": String(change.ageSeconds),
                    "staleAfterSeconds": String(change.thresholdSeconds),
                ]
                if let invocationID { metadata["invocationID"] = invocationID }
                DiagnosticLogger.record(
                    .warning,
                    category: .sync,
                    event: "sync.run.marked_stale",
                    message: "超时同步运行已标记为失败",
                    runID: change.record.id,
                    metadata: metadata
                )
            }
        }
    }

    static func update(
        id: UUID,
        now: Date = Date(),
        _ body: (inout SyncRunRecord) -> Void
    ) throws {
        var records = try load()
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        body(&records[index])
        records[index].lastUpdatedAt = now
        try save(records)
    }

    static func markRunning(_ id: UUID, now: Date = Date()) throws {
        try update(id: id, now: now) { record in
            guard record.status == .queued else { return }
            record.status = .running
            record.startedAt = now
        }
    }

    static func recordSuccess(
        id: UUID,
        type: SyncDataType,
        fetched: Int,
        added: Int,
        now: Date = Date()
    ) throws {
        try update(id: id, now: now) { record in
            record.items[type.rawValue] = SyncRunItem(
                typeRawValue: type.rawValue,
                fetched: fetched,
                added: added,
                success: true,
                error: nil,
                finishedAt: now
            )
        }
    }

    static func recordFailure(
        id: UUID,
        type: SyncDataType,
        error: SyncErrorDetails,
        now: Date = Date()
    ) throws {
        try update(id: id, now: now) { record in
            record.items[type.rawValue] = SyncRunItem(
                typeRawValue: type.rawValue,
                fetched: 0,
                added: 0,
                success: false,
                error: error,
                finishedAt: now
            )
        }
    }

    static func finish(
        id: UUID,
        status: SyncRunStatus,
        topLevelError: SyncErrorDetails? = nil,
        now: Date = Date()
    ) throws {
        try update(id: id, now: now) { record in
            guard record.status == .queued || record.status == .running else { return }
            record.status = status
            record.finishedAt = now
            record.topLevelError = topLevelError
        }
    }

    private static func load() throws -> [SyncRunRecord] {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else { return [] }
        do {
            return try JSONDecoder().decode([SyncRunRecord].self, from: data)
        } catch {
            throw SyncRunStoreError.decoding(error)
        }
    }

    private static func save(_ records: [SyncRunRecord]) throws {
        do {
            let data = try JSONEncoder().encode(records)
            UserDefaults.standard.set(data, forKey: storageKey)
        } catch {
            throw SyncRunStoreError.encoding(error)
        }
    }
}
