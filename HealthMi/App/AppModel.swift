import Foundation
import HealthKit
import CoreData
import Combine
import os

enum AppError: LocalizedError {
    case noCredentials
    case healthKitUnavailable

    var code: Int {
        switch self {
        case .noCredentials: return 401
        case .healthKitUnavailable: return 503
        }
    }

    var errorDescription: String? {
        switch self {
        case .noCredentials: return "未找到小米凭据，请先在设置页登录。"
        case .healthKitUnavailable: return "当前设备不支持 HealthKit。"
        }
    }
}

/// 应用全局状态（主线程）。
@MainActor
final class AppModel: ObservableObject {
    @Published var isConfigured = false
    @Published var connected = false
    @Published var accountID = ""
    @Published var healthKitAuthorized = false
    @Published var healthKitError: String?
    @Published var isSyncing = false
    @Published var backfillDays = 30
    @Published var statusMessage = ""
    @Published var lastError: String?
    @Published var outcomes: [SyncDataType: SyncOutcome] = [:]
    /// 最近 N 天数据概览（从 HealthKit 读回，用于 App 内回显）。
    @Published var summary: HealthSummary?
    /// 最近 N 天每日趋势（用于 Charts）。
    @Published var trends: [DailyTrend] = []
    /// 当前正在同步的类型索引和总数（用于进度显示）。
    @Published var currentSyncIndex: Int = 0
    @Published var totalSyncCount: Int = 0

    /// 同步进度文字，如 "正在同步 3/9"。
    var syncProgressText: String? {
        guard isSyncing, totalSyncCount > 0 else { return nil }
        return "正在同步 \(currentSyncIndex)/\(totalSyncCount)"
    }

    /// 小米凭据是否已过期/无效（需要用户重新登录获取新 token）。
    @Published var authNeedsRefresh = false

    /// 已启用的同步类别（持久化到 UserDefaults，默认全部启用）。
    @Published var enabledTypes: Set<SyncDataType> = Set(SyncDataType.allCases)

    private var engine: SyncEngine?

    // MARK: - 初始化 / 凭据

    func bootstrap() {
        CredentialStore.migrateIfNeeded()
        loadEnabledTypes()
        if let cred = CredentialStore.load() {
            isConfigured = true
            accountID = mask(cred.userId)
        }
        refreshHealthKitStatus()
    }

    // MARK: - 同步类别开关

    func isTypeEnabled(_ type: SyncDataType) -> Bool {
        enabledTypes.contains(type)
    }

    func setTypeEnabled(_ type: SyncDataType, enabled: Bool) {
        if enabled {
            enabledTypes.insert(type)
        } else {
            enabledTypes.remove(type)
        }
        UserDefaults.standard.set(
            enabledTypes.map(\.rawValue).sorted(),
            forKey: Self.enabledTypesKey
        )
    }

    private static let enabledTypesKey = "enabled_sync_types"

    private func loadEnabledTypes() {
        guard let raw = UserDefaults.standard.array(forKey: Self.enabledTypesKey) as? [String] else {
            return
        }
        let stored = Set(raw.compactMap(SyncDataType.init(rawValue:)))
        if !stored.isEmpty {
            enabledTypes = stored
        }
    }

    func saveCredentials(userId: String, passToken: String) async throws {
        try CredentialStore.save(userId: userId, passToken: passToken)
        let engine = SyncEngine()
        try await engine.connect(userId: userId, passToken: passToken)
        self.engine = engine
        isConfigured = true
        connected = true
        authNeedsRefresh = false
        accountID = mask(userId)
        refreshHealthKitStatus()
    }

    func disconnect(modelContext: NSManagedObjectContext? = nil) {
        engine = nil
        CredentialStore.delete()
        isConfigured = false
        connected = false
        accountID = ""
        outcomes = [:]
        // 清除同步游标和压力记录，防止切换账号时新账号继承上一个账号的数据
        if let modelContext {
            SyncStateStore.clearAll(in: modelContext)
            StressStore.clearAll(in: modelContext)
            SyncLogStore.clearAll(in: modelContext)
        }
    }

    // MARK: - HealthKit

    func requestHealthKit() async throws {
        healthKitError = nil
        do {
            guard HealthKitManager.isAvailable else { throw AppError.healthKitUnavailable }
            try await HealthKitManager.requestAuthorization()
            refreshHealthKitStatus()
        } catch {
            healthKitError = Self.describeHealthKitError(error)
            throw error
        }
    }

    func refreshHealthKitStatus() {
        guard HealthKitManager.isAvailable else {
            healthKitAuthorized = false
            return
        }
        let status = HealthKitManager.healthStore.authorizationStatus(
            for: HKQuantityType(.stepCount)
        )
        healthKitAuthorized = (status == .sharingAuthorized)
    }

    // MARK: - 同步

    /// 读取最近 N 天健康摘要和趋势数据用于 App 内回显。
    func refreshSummary(days: Int = 7) async {
        summary = await HealthKitReader.summary(days: days)
        trends = await HealthKitReader.trendSeries(days: days)
    }

    /// 若存在尚未请求过授权的类型（如后来新增的呼吸频率），先弹出 HealthKit 授权。
    func ensureHealthKitAuthorization() async {
        guard HealthKitManager.isAvailable else { return }
        let notDetermined = HealthKitManager.typesToShare.contains { type in
            HealthKitManager.healthStore.authorizationStatus(for: type) == .notDetermined
        }
        guard notDetermined else { return }
        do {
            try await HealthKitManager.requestAuthorization()
            refreshHealthKitStatus()
        } catch {
            let message = Self.describeHealthKitError(error)
            healthKitError = message
            lastError = message
        }
    }

    /// 跨实例并发同步互斥：前台 UI、快捷指令 Intent、BGTask 后台刷新可能用不同的
    /// AppModel 实例，同时跑会读到相同的增量游标导致重复写入。
    private static let syncActivity = OSAllocatedUnfairLock(initialState: false)

    /// - Parameters:
    ///   - forceBackfill: 为 true 时忽略增量游标，按 `backfillDays` 重新回填历史。
    ///   - isBackground: 是否为后台同步触发（完成后发送本地通知）。
    ///   - runID: 后台或快捷指令排队创建的运行 ID；前台手动同步可以不传。
    @discardableResult
    func syncAll(
        modelContext: NSManagedObjectContext,
        forceBackfill: Bool = false,
        isBackground: Bool = false,
        runID: UUID? = nil
    ) async -> SyncRunStatus {
        guard Self.syncActivity.withLock({ state in
            if state { return false }
            state = true
            return true
        }) else {
            statusMessage = "已有同步在进行中，已跳过本次触发"
            let error = SyncErrorDetails.make(
                domain: "HealthMi.Sync",
                code: 409,
                message: "已有同步在进行中，已跳过本次触发"
            )
            finishRun(runID, status: .failed, topLevelError: error)
            return .failed
        }
        defer { Self.syncActivity.withLock { $0 = false } }

        markRunRunning(runID)
        isSyncing = true
        lastError = nil
        defer { isSyncing = false }

        // 新增类型（如呼吸频率）可能还没授权，先补齐授权，否则写入会被 HealthKit 拒绝
        await ensureHealthKitAuthorization()
        // 检查用户是否在系统设置中撤销了权限
        refreshHealthKitStatus()
        guard healthKitAuthorized else {
            let message = "HealthKit 写入权限未授权，请在 设置 → 健康 → 数据访问 中允许 HealthMi"
            let error = SyncErrorDetails.make(
                domain: HKErrorDomain,
                code: HKError.Code.errorAuthorizationDenied.rawValue,
                message: message
            )
            lastError = message
            statusMessage = "❌ HealthKit 权限未授权"
            finishRun(runID, status: .failed, topLevelError: error)
            await notifyRunIfNeeded(runID: runID, fallbackError: message, isBackground: isBackground)
            return .failed
        }

        do {
            try await ensureEngine()
        } catch {
            let details = SyncErrorDetails.from(error)
            lastError = details.message
            statusMessage = "❌ \(details.message)"
            finishRun(runID, status: .failed, topLevelError: details)
            await notifyRunIfNeeded(runID: runID, fallbackError: details.message, isBackground: isBackground)
            return .failed
        }

        var messages: [String] = []
        let types = SyncDataType.allCases.filter { enabledTypes.contains($0) }
        totalSyncCount = types.count
        currentSyncIndex = 0
        await engine?.clearCache()
        var successCount = 0
        var failureCount = 0
        var cancelled = false
        for type in types {
            currentSyncIndex += 1
            // 后台同步被系统取消时，尽早退出
            if Task.isCancelled {
                cancelled = true
                break
            }
            do {
                let highWater = try SyncStateStore.state(for: type, in: modelContext)?.lastSyncedEnd
                if type == .stress {
                    // 压力数据不走 HealthKit，存入 Core Data 供 App 内展示
                    let result = try await engine?.syncStress(
                        highWater: highWater, backfillDays: backfillDays,
                        forceBackfill: forceBackfill
                    )
                    if let result {
                        let added = try StressStore.replaceRange(
                            start: result.queriedStart,
                            end: result.queriedEnd,
                            samples: result.samples,
                            in: modelContext
                        )
                        let outcome = SyncOutcome(
                            type: .stress, fetched: result.samples.count,
                            added: added, highWater: result.outcome.highWater
                        )
                        try SyncStateStore.record(
                            type: .stress, highWater: outcome.highWater,
                            added: added, in: modelContext
                        )
                        outcomes[.stress] = outcome
                        messages.append("压力 +\(added)")
                        successCount += 1
                        recordRunSuccess(runID, type: .stress, fetched: result.samples.count, added: added)
                        SyncLogStore.append(
                            type: .stress, fetched: result.samples.count,
                            added: added, success: true, in: modelContext
                        )
                    }
                } else {
                    let outcome = try await engine?.sync(
                        type: type, highWater: highWater, backfillDays: backfillDays,
                        forceBackfill: forceBackfill
                    )
                    if let outcome {
                        try SyncStateStore.record(
                            type: type, highWater: outcome.highWater,
                            added: outcome.added, in: modelContext
                        )
                        outcomes[type] = outcome
                        messages.append("\(type.displayName) +\(outcome.added)")
                        successCount += 1
                        recordRunSuccess(runID, type: type, fetched: outcome.fetched, added: outcome.added)
                        SyncLogStore.append(
                            type: type, fetched: outcome.fetched,
                            added: outcome.added, success: true, in: modelContext
                        )
                    }
                }
            } catch {
                if Task.isCancelled || Self.isCancellation(error) {
                    cancelled = true
                    break
                }
                let message = "\(type.displayName)：\(Self.describeSyncError(error))"
                lastError = message
                messages.append("\(type.displayName) ❌")
                failureCount += 1
                recordRunFailure(runID, type: type, error: SyncErrorDetails.from(error))
                SyncLogStore.append(
                    type: type, fetched: 0, added: 0,
                    success: false, errorMessage: Self.describeSyncError(error), in: modelContext
                )
            }
        }
        statusMessage = messages.joined(separator: "  ")
        refreshHealthKitStatus()
        // 被系统取消时及时结束，避免额外 HealthKit 查询拖延后台过期处理。
        if !cancelled {
            await refreshSummary()
        }
        let finalStatus: SyncRunStatus
        if cancelled {
            statusMessage = statusMessage.isEmpty ? "同步已取消" : "\(statusMessage)  已取消"
            finalStatus = .cancelled
        } else if failureCount == 0 {
            finalStatus = .succeeded
        } else if successCount > 0 {
            finalStatus = .partialFailure
        } else {
            finalStatus = .failed
        }
        let topLevelError = cancelled
            ? SyncErrorDetails.make(
                domain: "HealthMi.Sync",
                code: 499,
                message: "同步任务在完成前被取消。"
            )
            : nil
        finishRun(runID, status: finalStatus, topLevelError: topLevelError)
        await notifyRunIfNeeded(runID: runID, fallbackError: lastError, isBackground: isBackground)
        return finalStatus
    }

    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let apiError = error as? MiAPIError {
            return apiError.isCancellation
        }
        if let loginError = error as? MiLoginError,
           case .network(let underlying) = loginError {
            let nsError = underlying as NSError
            return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
        }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }

    private func markRunRunning(_ runID: UUID?) {
        guard let runID else { return }
        do {
            try SyncRunStore.markRunning(runID)
        } catch {
            AppLog.syncRunStore.error("更新同步运行状态失败：\(error.localizedDescription)")
        }
    }

    private func recordRunSuccess(_ runID: UUID?, type: SyncDataType, fetched: Int, added: Int) {
        guard let runID else { return }
        do {
            try SyncRunStore.recordSuccess(id: runID, type: type, fetched: fetched, added: added)
        } catch {
            AppLog.syncRunStore.error("保存同步成功结果失败：\(error.localizedDescription)")
        }
    }

    private func recordRunFailure(_ runID: UUID?, type: SyncDataType, error: SyncErrorDetails) {
        guard let runID else { return }
        do {
            try SyncRunStore.recordFailure(id: runID, type: type, error: error)
        } catch {
            AppLog.syncRunStore.error("保存同步失败结果失败：\(error.localizedDescription)")
        }
    }

    private func finishRun(_ runID: UUID?, status: SyncRunStatus, topLevelError: SyncErrorDetails? = nil) {
        guard let runID else { return }
        do {
            try SyncRunStore.finish(id: runID, status: status, topLevelError: topLevelError)
        } catch {
            AppLog.syncRunStore.error("保存同步运行终态失败：\(error.localizedDescription)")
        }
    }

    private func notifyRunIfNeeded(runID: UUID?, fallbackError: String?, isBackground: Bool) async {
        guard isBackground else { return }
        if let runID, let record = SyncRunStore.record(for: runID) {
            await NotificationManager.notifySyncResult(record)
        } else if let fallbackError {
            await NotificationManager.notifySyncFailure(fallbackError)
        }
    }

    /// 把同步错误转成可读信息，健康权限被拒时给出设置引导。
    private static func describeSyncError(_ error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == HKErrorDomain {
            if nsError.code == HKError.Code.errorAuthorizationDenied.rawValue
                || nsError.code == HKError.Code.errorAuthorizationNotDetermined.rawValue {
                return "健康权限未允许（请在 设置 → 健康 → 数据访问 中允许 HealthMi）"
            }
        }
        return error.localizedDescription
    }

    /// 把授权请求错误转成可定位的消息，同时保留系统提供的错误文本。
    private static func describeHealthKitError(_ error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == HKErrorDomain {
            if nsError.code == HKError.Code.errorAuthorizationDenied.rawValue
                || nsError.code == HKError.Code.errorAuthorizationNotDetermined.rawValue {
                return "HealthKit 授权失败（HKError code=\(nsError.code)）：授权被拒绝或尚未决定。请在“健康”App 的“来源”中检查 HealthMi。"
            }
            return "HealthKit 授权失败（HKError code=\(nsError.code)）：\(error.localizedDescription)"
        }
        return "HealthKit 授权失败（\(nsError.domain) / code=\(nsError.code)）：\(error.localizedDescription)"
    }

    private func ensureEngine() async throws {
        if engine != nil { return }
        guard let cred = CredentialStore.load() else { throw AppError.noCredentials }
        let newEngine = SyncEngine()
        do {
            try await newEngine.connect(userId: cred.userId, passToken: cred.passToken)
            engine = newEngine
            connected = true
            authNeedsRefresh = false
            accountID = mask(cred.userId)
        } catch {
            if Self.isAuthError(error) {
                authNeedsRefresh = true
                lastError = "小米凭据已过期或无效，请更新凭据后重试。"
            }
            throw error
        }
    }

    /// 是否小米登录认证错误（passToken 过期 / 无效等）。
    private static func isAuthError(_ error: Error) -> Bool {
        if case MiLoginError.loginRejected = error { return true }
        return false
    }

    // MARK: - 工具

    private func mask(_ value: String) -> String {
        guard value.count > 4 else { return "****" }
        return value.prefix(4) + "****"
    }
}
