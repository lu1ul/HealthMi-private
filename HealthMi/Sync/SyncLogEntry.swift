import Foundation
import CoreData
import SwiftData
import os

/// iOS 17 旧库中的 SwiftData 同步日志模型，仅供迁移器读取。
@available(iOS 17.0, *)
@Model
final class SyncLogEntry {
    var timestamp: Date
    var typeRawValue: String
    var fetched: Int
    var added: Int
    var success: Bool
    var errorMessage: String?

    init(timestamp: Date, typeRawValue: String, fetched: Int, added: Int, success: Bool, errorMessage: String? = nil) {
        self.timestamp = timestamp
        self.typeRawValue = typeRawValue
        self.fetched = fetched
        self.added = added
        self.success = success
        self.errorMessage = errorMessage
    }

    var displayName: String {
        SyncDataType(rawValue: typeRawValue)?.displayName ?? typeRawValue
    }
}

/// 同步日志存取。
@MainActor
enum SyncLogStore {

    static func append(
        type: SyncDataType, fetched: Int, added: Int,
        success: Bool, errorMessage: String? = nil, in context: NSManagedObjectContext
    ) {
        let entry = NSEntityDescription.insertNewObject(
            forEntityName: "SyncLogEntryEntity", into: context
        ) as! SyncLogEntryEntity
        entry.timestamp = Date()
        entry.typeRawValue = type.rawValue
        entry.fetched = Int64(fetched)
        entry.added = Int64(added)
        entry.success = success
        entry.errorMessage = errorMessage
        do {
            try context.save()
        } catch {
            AppLog.syncLogStore.error("保存同步日志失败：\(error.localizedDescription)")
            context.rollback()
        }
        pruneOldEntries(in: context)
    }

    /// 保留最近 200 条日志，避免无限增长。
    private static func pruneOldEntries(in context: NSManagedObjectContext) {
        let request = SyncLogEntryEntity.fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: false)]
        guard let all = try? context.fetch(request) else { return }
        let limit = 200
        if all.count > limit {
            for entry in all.dropFirst(limit) {
                context.delete(entry)
            }
            do {
                try context.save()
            } catch {
                context.rollback()
                AppLog.syncLogStore.error("清理旧同步日志失败：\(error.localizedDescription)")
            }
        }
    }

    static func clearAll(in context: NSManagedObjectContext) {
        let request = SyncLogEntryEntity.fetchRequest()
        if let entries = try? context.fetch(request) {
            for entry in entries {
                context.delete(entry)
            }
            do {
                try context.save()
            } catch {
                context.rollback()
                AppLog.syncLogStore.error("清除同步日志失败：\(error.localizedDescription)")
            }
        }
    }
}
