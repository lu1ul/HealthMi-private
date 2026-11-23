import Foundation
import CoreData
import SwiftData
import os

/// iOS 17 旧库中的 SwiftData 压力模型，仅供迁移器读取。
@available(iOS 17.0, *)
@Model
final class StressRecord {
    @Attribute(.unique) var externalID: String
    var timestamp: Date
    var stressScore: Int

    init(externalID: String, timestamp: Date, stressScore: Int) {
        self.externalID = externalID
        self.timestamp = timestamp
        self.stressScore = stressScore
    }
}

/// 压力数据存取。
@MainActor
enum StressStore {

    /// 批量写入压力记录，按 externalID 去重，返回新增条数。
    @discardableResult
    static func save(samples: [MiStressSample], in context: NSManagedObjectContext) throws -> Int {
        guard !samples.isEmpty else { return 0 }
        let samplesByID = Dictionary(samples.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        let existing = try fetchExistingIDs(ids: Set(samplesByID.keys), in: context)
        var added = 0
        for sample in samplesByID.values where !existing.contains(sample.id) {
            let record = NSEntityDescription.insertNewObject(
                forEntityName: "StressRecordEntity", into: context
            ) as! StressRecordEntity
            record.externalID = sample.id
            record.timestamp = sample.timestamp
            record.stressScore = Int64(sample.stressScore)
            added += 1
        }
        if added > 0 {
            do {
                try context.save()
            } catch {
                AppLog.stressStore.error("保存压力记录失败：\(error.localizedDescription)")
                context.rollback()
                throw error
            }
        }
        return added
    }

    /// 仅替换成功查询范围内的压力记录；删除与插入在一次 Core Data 保存中提交。
    @discardableResult
    static func replaceRange(
        start: Date, end: Date, samples: [MiStressSample], in context: NSManagedObjectContext
    ) throws -> Int {
        guard start <= end else { return 0 }
        let request = StressRecordEntity.fetchRequest()
        request.predicate = NSPredicate(format: "timestamp >= %@ AND timestamp <= %@", start as NSDate, end as NSDate)
        do {
            let existingInRange = try context.fetch(request)
            let inRangeByID = Dictionary(
                samples.filter { $0.timestamp >= start && $0.timestamp <= end }.map { ($0.id, $0) },
                uniquingKeysWith: { _, latest in latest }
            )
            let existingByID = Dictionary(
                try fetchRecords(ids: Set(inRangeByID.keys), in: context).map { ($0.externalID, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            var replacedIDs = Set<String>()

            for record in existingInRange {
                if let sample = inRangeByID[record.externalID] {
                    record.timestamp = sample.timestamp
                    record.stressScore = Int64(sample.stressScore)
                    replacedIDs.insert(sample.id)
                } else {
                    context.delete(record)
                }
            }

            var added = 0
            for sample in inRangeByID.values where !replacedIDs.contains(sample.id) {
                // 同一 externalID 已存在于查询范围外时保留那条旧记录，避免改动范围外数据。
                if let existing = existingByID[sample.id],
                   (existing.timestamp < start || existing.timestamp > end) {
                    continue
                }
                let record = NSEntityDescription.insertNewObject(
                    forEntityName: "StressRecordEntity", into: context
                ) as! StressRecordEntity
                record.externalID = sample.id
                record.timestamp = sample.timestamp
                record.stressScore = Int64(sample.stressScore)
                added += 1
            }
            try context.save()
            return added
        } catch {
            context.rollback()
            AppLog.stressStore.error("替换压力记录失败：\(error.localizedDescription)")
            throw error
        }
    }

    /// 清除所有压力记录（退出登录时调用）。
    static func clearAll(in context: NSManagedObjectContext) {
        let request = StressRecordEntity.fetchRequest()
        do {
            let records = try context.fetch(request)
            for record in records {
                context.delete(record)
            }
            try context.save()
        } catch {
            context.rollback()
            AppLog.stressStore.error("清除压力记录失败：\(error.localizedDescription)")
        }
    }

    /// 查询最近 N 天的压力记录（按时间排序）。
    static func recent(days: Int, in context: NSManagedObjectContext) -> [StressRecordEntity] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        let request = StressRecordEntity.fetchRequest()
        request.predicate = NSPredicate(format: "timestamp >= %@", cutoff as NSDate)
        request.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: false)]
        return (try? context.fetch(request)) ?? []
    }

    private static func fetchExistingIDs(ids: Set<String>, in context: NSManagedObjectContext) throws -> Set<String> {
        Set(try fetchRecords(ids: ids, in: context).map(\.externalID))
    }

    private static func fetchRecords(ids: Set<String>, in context: NSManagedObjectContext) throws -> [StressRecordEntity] {
        guard !ids.isEmpty else { return [] }
        let request = StressRecordEntity.fetchRequest()
        request.predicate = NSPredicate(format: "externalID IN %@", Array(ids))
        return try context.fetch(request)
    }
}
