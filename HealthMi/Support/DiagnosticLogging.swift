import Foundation
import OSLog
import UIKit

enum DiagnosticLogLevel: String, Codable, CaseIterable, Identifiable, Sendable {
    case trace
    case debug
    case info
    case notice
    case warning
    case error
    case critical

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .trace: return "跟踪"
        case .debug: return "调试"
        case .info: return "信息"
        case .notice: return "提示"
        case .warning: return "警告"
        case .error: return "错误"
        case .critical: return "严重"
        }
    }

    var severity: Int {
        switch self {
        case .trace: return 0
        case .debug: return 1
        case .info: return 2
        case .notice: return 3
        case .warning: return 4
        case .error: return 5
        case .critical: return 6
        }
    }

    fileprivate var osLogType: OSLogType {
        switch self {
        case .trace, .debug: return .debug
        case .info: return .info
        case .notice: return .default
        case .warning: return .default
        case .error: return .error
        case .critical: return .fault
        }
    }
}

enum DiagnosticLogCategory: String, Codable, CaseIterable, Identifiable, Sendable {
    case appLifecycle
    case storage
    case keychain
    case authentication
    case network
    case healthKit
    case sync
    case stress
    case backgroundTask
    case appIntent
    case notification
    case export

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .appLifecycle: return "应用生命周期"
        case .storage: return "本地存储"
        case .keychain: return "Keychain"
        case .authentication: return "小米登录"
        case .network: return "网络请求"
        case .healthKit: return "HealthKit"
        case .sync: return "数据同步"
        case .stress: return "压力数据"
        case .backgroundTask: return "后台任务"
        case .appIntent: return "快捷指令"
        case .notification: return "通知"
        case .export: return "日志导出"
        }
    }
}

struct DiagnosticLogEvent: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    let timestamp: Date
    let level: DiagnosticLogLevel
    let category: DiagnosticLogCategory
    let event: String
    let message: String
    let runID: String?
    let dataType: String?
    let errorDomain: String?
    let errorCode: Int?
    let metadata: [String: String]
    let processID: Int32
    let isMainThread: Bool

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        level: DiagnosticLogLevel,
        category: DiagnosticLogCategory,
        event: String,
        message: String,
        runID: UUID?,
        dataType: String?,
        error: Error?,
        errorDomain: String? = nil,
        errorCode: Int? = nil,
        metadata: [String: String]
    ) {
        let nsError = error.map { $0 as NSError }
        self.id = id
        self.timestamp = timestamp
        self.level = level
        self.category = category
        self.event = DiagnosticRedactor.redact(event, limit: 120)
        self.message = DiagnosticRedactor.redact(message, limit: 1_024)
        self.runID = runID?.uuidString
        self.dataType = dataType.map { DiagnosticRedactor.redact($0, limit: 80) }
        self.errorDomain = (errorDomain ?? nsError?.domain).map {
            DiagnosticRedactor.redact($0, limit: 200)
        }
        self.errorCode = errorCode ?? nsError?.code
        self.metadata = DiagnosticRedactor.safeMetadata(metadata)
        self.processID = ProcessInfo.processInfo.processIdentifier
        self.isMainThread = Thread.isMainThread
    }
}

struct DiagnosticLogSnapshot: Sendable {
    let events: [DiagnosticLogEvent]
    let storageBytes: Int
    let corruptedLineCount: Int

    var oldestEvent: Date? { events.map(\.timestamp).min() }
    var newestEvent: Date? { events.map(\.timestamp).max() }
}

enum DiagnosticLogger {
    private static let subsystem = "com.healthmi.HealthMi"

    static func record(
        _ level: DiagnosticLogLevel,
        category: DiagnosticLogCategory,
        event: String,
        message: String,
        runID: UUID? = nil,
        dataType: String? = nil,
        error: Error? = nil,
        errorDomain: String? = nil,
        errorCode: Int? = nil,
        metadata: [String: String] = [:]
    ) {
        let entry = DiagnosticLogEvent(
            level: level,
            category: category,
            event: event,
            message: message,
            runID: runID,
            dataType: dataType,
            error: error,
            errorDomain: errorDomain,
            errorCode: errorCode,
            metadata: metadata
        )
        let systemLogger = Logger(subsystem: subsystem, category: category.rawValue)
        let fields = entry.metadata.keys.sorted().map { "\($0)=\(entry.metadata[$0] ?? "")" }
        var summary = "\(entry.event): \(entry.message)"
        if let dataType = entry.dataType { summary += " type=\(dataType)" }
        if let runID = entry.runID { summary += " run=\(runID.prefix(8))" }
        if let errorDomain = entry.errorDomain { summary += " error=\(errorDomain)/\(entry.errorCode ?? 0)" }
        if !fields.isEmpty { summary += " {\(fields.joined(separator: ", "))}" }
        systemLogger.log(
            level: level.osLogType,
            "\(entry.event, privacy: .public): \(summary, privacy: .private)"
        )
        DiagnosticLogStore.shared.append(entry)
    }

    static func flush() {
        DiagnosticLogStore.shared.flush()
    }
}

private enum DiagnosticRedactor {
    private static let sensitiveKeyFragments = [
        "authorization", "cookie", "password", "passwd", "passtoken",
        "token", "ssecurity", "servicetoken", "userid", "accountid",
        "deviceid", "email", "phone", "mobile",
    ]
    private static let maximumMetadataCount = 64

    static func safeMetadata(_ values: [String: String]) -> [String: String] {
        var safe: [String: String] = [:]
        for key in values.keys.sorted().prefix(maximumMetadataCount) {
            let normalizedKey = key.lowercased().filter { $0.isLetter || $0.isNumber }
            guard !sensitiveKeyFragments.contains(where: { normalizedKey.contains($0) }),
                  let value = values[key]
            else { continue }
            safe[redact(key, limit: 80)] = redact(value, limit: 512)
        }
        return safe
    }

    static func redact(_ input: String, limit: Int) -> String {
        var value = input
            .replacingOccurrences(of: "\0", with: "")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
        value = replacing(
            pattern: "(?i)\\b(passToken|password|passwd|authorization|set-cookie|cookie|ssecurity|serviceToken|token|userId|accountId|deviceId|email|phone|mobile)\\b\\s*[:=]\\s*(\\\"[^\\\"]*\\\"|'[^']*'|[^\\s,;]+)",
            in: value,
            template: "$1=[REDACTED]"
        )
        value = replacing(
            pattern: "(?i)\\b(bearer)\\s+[^\\s,;]+",
            in: value,
            template: "$1 [REDACTED]"
        )
        value = replacing(
            pattern: "(?i)(https?://[^\\s?#]+)\\?[^\\s]*",
            in: value,
            template: "$1?[REDACTED]"
        )
        return String(value.prefix(limit))
    }

    private static func replacing(pattern: String, in value: String, template: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return value }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return expression.stringByReplacingMatches(
            in: value,
            range: range,
            withTemplate: template
        )
    }
}

private enum DiagnosticLogFileAttributes {
    static func excludeFromBackup(_ url: URL) {
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        try? url.setResourceValues(resourceValues)
    }
}

final class DiagnosticLogStore: @unchecked Sendable {
    static let shared = DiagnosticLogStore()

    private static let maximumFileBytes = 2 * 1_024 * 1_024
    private static let maximumTotalBytes = 20 * 1_024 * 1_024
    private static let retentionInterval: TimeInterval = 14 * 24 * 60 * 60
    private static let currentFileName = "diagnostics-current.jsonl"
    private static let fallbackLogger = Logger(
        subsystem: "com.healthmi.HealthMi",
        category: "DiagnosticLogStore"
    )

    private let ioQueue = DispatchQueue(
        label: "com.healthmi.HealthMi.diagnostic-log-store",
        qos: .utility
    )
    private let fileManager = FileManager.default
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    private init() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    func append(_ event: DiagnosticLogEvent) {
        ioQueue.async { [weak self] in
            self?.appendOnQueue(event)
        }
    }

    func flush() {
        ioQueue.sync {}
    }

    private func appendOnQueue(_ event: DiagnosticLogEvent) {
        do {
            var data = try encoder.encode(event)
            data.append(0x0A)
            try ensureDirectory()
            _ = try rotateCurrentFileIfNeeded(incomingBytes: data.count)
            let url = currentFileURL
            guard fileManager.fileExists(atPath: url.path) else {
                try createCurrentFile()
                try write(data, to: currentFileURL)
                return
            }
            try write(data, to: url)
            try pruneOldFiles(now: Date())
        } catch {
            Self.fallbackLogger.error(
                "Could not persist diagnostic event: \(String(reflecting: error), privacy: .private)"
            )
        }
    }

    func snapshot() throws -> DiagnosticLogSnapshot {
        try ioQueue.sync {
            try snapshotOnQueue()
        }
    }

    private func snapshotOnQueue() throws -> DiagnosticLogSnapshot {
        guard fileManager.fileExists(atPath: directoryURL.path) else {
            return DiagnosticLogSnapshot(events: [], storageBytes: 0, corruptedLineCount: 0)
        }

        try pruneOldFiles(now: Date())
        let files = try logFiles()
        var events: [DiagnosticLogEvent] = []
        var storageBytes = 0
        var corruptedLineCount = 0

        for url in files {
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            storageBytes += data.count
            guard let contents = String(data: data, encoding: .utf8) else {
                corruptedLineCount += 1
                continue
            }
            for line in contents.split(whereSeparator: \.isNewline) {
                guard let lineData = String(line).data(using: .utf8) else { continue }
                do {
                    events.append(try decoder.decode(DiagnosticLogEvent.self, from: lineData))
                } catch {
                    corruptedLineCount += 1
                }
            }
        }

        events.sort { $0.timestamp > $1.timestamp }
        return DiagnosticLogSnapshot(
            events: events,
            storageBytes: storageBytes,
            corruptedLineCount: corruptedLineCount
        )
    }

    func clear() throws {
        try ioQueue.sync {
            try clearOnQueue()
        }
    }

    private func clearOnQueue() throws {
        guard fileManager.fileExists(atPath: directoryURL.path) else { return }
        for url in try logFiles() {
            try fileManager.removeItem(at: url)
        }
        try createCurrentFile()
    }

    private var directoryURL: URL {
        let supportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return supportURL.appendingPathComponent("DiagnosticLogs", isDirectory: true)
    }

    private var currentFileURL: URL {
        directoryURL.appendingPathComponent(Self.currentFileName)
    }

    private func ensureDirectory() throws {
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        )
        DiagnosticLogFileAttributes.excludeFromBackup(directoryURL)
    }

    private func createCurrentFile() throws {
        let created = fileManager.createFile(
            atPath: currentFileURL.path,
            contents: Data(),
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        )
        guard created || fileManager.fileExists(atPath: currentFileURL.path) else {
            throw CocoaError(.fileWriteUnknown)
        }
        DiagnosticLogFileAttributes.excludeFromBackup(currentFileURL)
    }

    private func write(_ data: Data, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try handle.synchronize()
    }

    @discardableResult
    private func rotateCurrentFileIfNeeded(incomingBytes: Int) throws -> Bool {
        guard fileManager.fileExists(atPath: currentFileURL.path) else {
            try createCurrentFile()
            return false
        }

        let attributes = try fileManager.attributesOfItem(atPath: currentFileURL.path)
        let currentBytes = (attributes[.size] as? NSNumber)?.intValue ?? 0
        guard currentBytes + incomingBytes > Self.maximumFileBytes else { return false }

        let rotatedURL = uniqueRotatedFileURL(now: Date())
        try fileManager.moveItem(at: currentFileURL, to: rotatedURL)
        try createCurrentFile()
        return true
    }

    private func uniqueRotatedFileURL(now: Date) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmssSSS'Z'"
        let stem = "diagnostics-\(formatter.string(from: now))"
        var candidate = directoryURL.appendingPathComponent("\(stem).jsonl")
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = directoryURL.appendingPathComponent("\(stem)-\(UUID().uuidString).jsonl")
        }
        return candidate
    }

    private func logFiles() throws -> [URL] {
        try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension == "jsonl" && $0.lastPathComponent.hasPrefix("diagnostics-") }
        .sorted { modificationDate(of: $0) < modificationDate(of: $1) }
    }

    private func modificationDate(of url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    private func pruneOldFiles(now: Date) throws {
        var files = try logFiles()
        let cutoff = now.addingTimeInterval(-Self.retentionInterval)
        for url in files where modificationDate(of: url) < cutoff {
            try fileManager.removeItem(at: url)
        }
        files = try logFiles()

        var totalBytes = try files.reduce(into: 0) { total, url in
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            total += values.fileSize ?? 0
        }
        while totalBytes > Self.maximumTotalBytes,
              let oldest = files.first(where: { $0 != currentFileURL }) {
            let size = (try? oldest.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            try fileManager.removeItem(at: oldest)
            totalBytes -= size
            files.removeAll { $0 == oldest }
        }
    }
}

private struct DiagnosticExportManifest: Encodable {
    let schemaVersion: Int
    let generatedAt: Date
    let bundleIdentifier: String
    let appVersion: String
    let buildNumber: String
    let operatingSystem: String
    let deviceModel: String
    let eventCount: Int
    let oldestEvent: Date?
    let newestEvent: Date?
    let logStorageBytes: Int
    let corruptedLineCount: Int
}

private struct DiagnosticExportError: Encodable {
    let domain: String
    let code: Int
    let message: String

    init(_ error: SyncErrorDetails) {
        domain = DiagnosticRedactor.redact(error.domain, limit: 200)
        code = error.code
        message = DiagnosticRedactor.redact(error.message, limit: 1_024)
    }
}

private struct DiagnosticExportRunItem: Encodable {
    let dataType: String
    let fetched: Int
    let added: Int
    let success: Bool
    let error: DiagnosticExportError?
}

private struct DiagnosticExportRun: Encodable {
    let id: String
    let trigger: String
    let status: String
    let queuedAt: Date
    let startedAt: Date?
    let finishedAt: Date?
    let items: [DiagnosticExportRunItem]
    let topLevelError: DiagnosticExportError?

    init(_ record: SyncRunRecord) {
        id = record.id.uuidString
        trigger = record.trigger.rawValue
        status = record.status.rawValue
        queuedAt = record.queuedAt
        startedAt = record.startedAt
        finishedAt = record.finishedAt
        items = record.sortedItems.map {
            DiagnosticExportRunItem(
                dataType: $0.typeRawValue,
                fetched: $0.fetched,
                added: $0.added,
                success: $0.success,
                error: $0.error.map(DiagnosticExportError.init)
            )
        }
        topLevelError = record.topLevelError.map(DiagnosticExportError.init)
    }
}

private struct DiagnosticExportBundle: Encodable {
    let manifest: DiagnosticExportManifest
    let events: [DiagnosticLogEvent]
    let syncRuns: [DiagnosticExportRun]
}

enum DiagnosticLogExporter {
    static func writeBundle(
        syncRuns: [SyncRunRecord],
        deviceModel: String,
        systemVersion: String
    ) throws -> (url: URL, eventCount: Int, byteCount: Int) {
        let snapshot = try DiagnosticLogStore.shared.snapshot()
        let info = Bundle.main.infoDictionary ?? [:]
        let bundle = DiagnosticExportBundle(
            manifest: DiagnosticExportManifest(
                schemaVersion: 1,
                generatedAt: Date(),
                bundleIdentifier: Bundle.main.bundleIdentifier ?? "com.healthmi.HealthMi",
                appVersion: info["CFBundleShortVersionString"] as? String ?? "unknown",
                buildNumber: info["CFBundleVersion"] as? String ?? "unknown",
                operatingSystem: "iOS \(systemVersion)",
                deviceModel: deviceModel,
                eventCount: snapshot.events.count,
                oldestEvent: snapshot.oldestEvent,
                newestEvent: snapshot.newestEvent,
                logStorageBytes: snapshot.storageBytes,
                corruptedLineCount: snapshot.corruptedLineCount
            ),
            events: snapshot.events,
            syncRuns: syncRuns.map(DiagnosticExportRun.init)
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(bundle)
        let exportDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HealthMi-Diagnostics", isDirectory: true)
        try FileManager.default.createDirectory(
            at: exportDirectory,
            withIntermediateDirectories: true
        )
        removeExpiredExports(in: exportDirectory)

        let filename = "HealthMi-Diagnostics-\(timestamp(Date()))-\(UUID().uuidString).json"
        let url = exportDirectory.appendingPathComponent(filename)
        try data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
        DiagnosticLogFileAttributes.excludeFromBackup(url)
        return (url, snapshot.events.count, data.count)
    }

    private static func removeExpiredExports(in directory: URL) {
        let cutoff = Date().addingTimeInterval(-3 * 24 * 60 * 60)
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        for url in urls {
            let modifiedAt = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                ?? .distantPast
            if modifiedAt < cutoff { try? FileManager.default.removeItem(at: url) }
        }
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter.string(from: date)
    }
}
