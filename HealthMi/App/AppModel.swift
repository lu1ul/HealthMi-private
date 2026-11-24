import Foundation
import HealthKit
import CoreData
import Combine
import os

enum AppError: LocalizedError {
    case noCredentials
    case healthKitUnavailable

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
    ///   - isBackground: 是否为后台同步触发（失败时发送本地通知）。
    func syncAll(modelContext: NSManagedObjectContext, forceBackfill: Bool = false, isBackground: Bool = false) async {
        guard Self.syncActivity.withLock({ state in
            if state { return false }
            state = true
            return true
        }) else {
            statusMessage = "已有同步在进行中，已跳过本次触发"
            return
        }
        defer { Self.syncActivity.withLock { $0 = false } }

        isSyncing = true
        lastError = nil
        defer { isSyncing = false }

        // 新增类型（如呼吸频率）可能还没授权，先补齐授权，否则写入会被 HealthKit 拒绝
        await ensureHealthKitAuthorization()
        // 检查用户是否在系统设置中撤销了权限
        refreshHealthKitStatus()
        guard healthKitAuthorized else {
            lastError = "HealthKit 写入权限未授权，请在 设置 → 健康 → 数据访问 中允许 HealthMi"
            statusMessage = "❌ HealthKit 权限未授权"
            return
        }

        do {
            try await ensureEngine()
        } catch {
            lastError = error.localizedDescription
            statusMessage = "❌ \(error.localizedDescription)"
            return
        }

        var messages: [String] = []
        let types = SyncDataType.allCases.filter { enabledTypes.contains($0) }
        totalSyncCount = types.count
        currentSyncIndex = 0
        await engine?.clearCache()
        for type in types {
            currentSyncIndex += 1
            // 后台同步被系统取消时，尽早退出
            if Task.isCancelled { break }
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
                        SyncLogStore.append(
                            type: type, fetched: outcome.fetched,
                            added: outcome.added, success: true, in: modelContext
                        )
                    }
                }
            } catch {
                let message = "\(type.displayName)：\(Self.describeSyncError(error))"
                lastError = message
                messages.append("\(type.displayName) ❌")
                SyncLogStore.append(
                    type: type, fetched: 0, added: 0,
                    success: false, errorMessage: Self.describeSyncError(error), in: modelContext
                )
            }
        }
        statusMessage = messages.joined(separator: "  ")
        refreshHealthKitStatus()
        // 同步完成后刷新 App 内数据概览
        await refreshSummary()
        // 后台同步失败时发送本地通知
        if isBackground, let lastError {
            await NotificationManager.notifySyncFailure(lastError)
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
