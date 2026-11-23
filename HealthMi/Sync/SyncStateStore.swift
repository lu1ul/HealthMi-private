import Foundation
import CoreData
import SwiftData
import os

/// 可同步的数据类型。stress 无 HealthKit 对应类型，存 App 内展示。
/// abnormal_heart_beat 暂不纳入。
enum SyncDataType: String, CaseIterable, Identifiable, Sendable {
    case dailyActivity = "daily_activity"
    case heartRate = "heart_rate"
    case sleep = "sleep"
    case spo2 = "spo2"
    case respiratoryRate = "respiratory_rate"
    case hrv = "hrv"
    case bodyMeasurements = "body_measurements"
    case workouts = "workouts"
    case stress = "stress"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .dailyActivity: return "日常活动"
        case .heartRate: return "心率"
        case .sleep: return "睡眠"
        case .spo2: return "血氧"
        case .respiratoryRate: return "呼吸频率"
        case .hrv: return "心率变异性"
        case .bodyMeasurements: return "体重/体脂"
        case .workouts: return "运动记录"
        case .stress: return "压力"
        }
    }
}

/// iOS 17 旧库中的 SwiftData 同步游标模型，仅供迁移器读取。
@available(iOS 17.0, *)
@Model
final class SyncState {
    @Attribute(.unique) var typeRawValue: String
    /// 已同步到的最晚时间，用于增量拉取。
    var lastSyncedEnd: Date?
    var lastSyncAt: Date?
    var lastAddedCount: Int

    init(typeRawValue: String, lastSyncedEnd: Date? = nil, lastSyncAt: Date? = nil, lastAddedCount: Int = 0) {
        self.typeRawValue = typeRawValue
        self.lastSyncedEnd = lastSyncedEnd
        self.lastSyncAt = lastSyncAt
        self.lastAddedCount = lastAddedCount
    }
}

/// Core Data 存取同步游标。
@MainActor
enum SyncStateStore {

    static func state(for type: SyncDataType, in context: NSManagedObjectContext) throws -> SyncStateEntity? {
        let request = SyncStateEntity.fetchRequest()
        request.predicate = NSPredicate(format: "typeRawValue == %@", type.rawValue)
        request.fetchLimit = 1
        return try context.fetch(request).first
    }

    static func ensureState(for type: SyncDataType, in context: NSManagedObjectContext) throws -> SyncStateEntity {
        if let existing = try state(for: type, in: context) { return existing }
        let created = NSEntityDescription.insertNewObject(
            forEntityName: "SyncStateEntity", into: context
        ) as! SyncStateEntity
        created.typeRawValue = type.rawValue
        created.lastAddedCount = 0
        return created
    }

    static func record(
        type: SyncDataType, highWater: Date?, added: Int, in context: NSManagedObjectContext
    ) throws {
        let state = try ensureState(for: type, in: context)
        state.lastSyncedEnd = highWater
        state.lastSyncAt = Date()
        state.lastAddedCount = Int64(added)
        do {
            try context.save()
        } catch {
            AppLog.syncStateStore.error("保存同步游标失败 (\(type.rawValue))：\(error.localizedDescription)")
            context.rollback()
            throw error
        }
    }

    /// 清除所有同步游标（退出登录或切换账号时调用，防止新账号继承旧进度）。
    static func clearAll(in context: NSManagedObjectContext) {
        let request = SyncStateEntity.fetchRequest()
        do {
            let all = try context.fetch(request)
            for state in all {
                context.delete(state)
            }
            try context.save()
        } catch {
            AppLog.syncStateStore.error("清除同步游标失败：\(error.localizedDescription)")
            context.rollback()
        }
    }
}
