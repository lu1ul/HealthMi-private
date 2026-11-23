import CoreData
import SwiftData

/// 旧 SwiftData 数据库的 v1 schema。模型和字段必须与上线版本保持一致。
@available(iOS 17.0, *)
enum SchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }
    static var models: [any PersistentModel.Type] {
        [SyncState.self, StressRecord.self, SyncLogEntry.self]
    }
}

/// 旧 SwiftData 数据库的迁移计划。
@available(iOS 17.0, *)
enum MigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [SchemaV1.self]
    }
    static var stages: [MigrationStage] { [] }
}

/// 首次启动时将旧 SwiftData 记录导入 Core Data。
@available(iOS 17.0, *)
@MainActor
enum LegacySwiftDataImporter {
    private static let migrationKey = "legacy-swiftdata-v1-imported"

    static func importIfNeeded(into targetContext: NSManagedObjectContext) throws {
        let markerRequest = StoreMetadataEntity.fetchRequest()
        markerRequest.predicate = NSPredicate(format: "key == %@", migrationKey)
        if try targetContext.fetch(markerRequest).first != nil { return }

        let schema = Schema([SyncState.self, StressRecord.self, SyncLogEntry.self])
        let configuration = ModelConfiguration(schema: schema)
        let legacyContainer = try ModelContainer(
            for: schema,
            migrationPlan: MigrationPlan.self,
            configurations: [configuration]
        )
        try importRecords(from: legacyContainer.mainContext, into: targetContext)
    }

    static func importRecords(from legacyContext: ModelContext, into targetContext: NSManagedObjectContext) throws {
        let markerRequest = StoreMetadataEntity.fetchRequest()
        markerRequest.predicate = NSPredicate(format: "key == %@", migrationKey)
        if try targetContext.fetch(markerRequest).first != nil { return }

        let states = try legacyContext.fetch(FetchDescriptor<SyncState>())
        let stressRecords = try legacyContext.fetch(FetchDescriptor<StressRecord>())
        let logEntries = try legacyContext.fetch(FetchDescriptor<SyncLogEntry>())

        do {
            for state in states {
                let imported = NSEntityDescription.insertNewObject(
                    forEntityName: "SyncStateEntity", into: targetContext
                ) as! SyncStateEntity
                imported.typeRawValue = state.typeRawValue
                imported.lastSyncedEnd = state.lastSyncedEnd
                imported.lastSyncAt = state.lastSyncAt
                imported.lastAddedCount = Int64(state.lastAddedCount)
            }

            for record in stressRecords {
                let imported = NSEntityDescription.insertNewObject(
                    forEntityName: "StressRecordEntity", into: targetContext
                ) as! StressRecordEntity
                imported.externalID = record.externalID
                imported.timestamp = record.timestamp
                imported.stressScore = Int64(record.stressScore)
            }

            for entry in logEntries {
                let imported = NSEntityDescription.insertNewObject(
                    forEntityName: "SyncLogEntryEntity", into: targetContext
                ) as! SyncLogEntryEntity
                imported.timestamp = entry.timestamp
                imported.typeRawValue = entry.typeRawValue
                imported.fetched = Int64(entry.fetched)
                imported.added = Int64(entry.added)
                imported.success = entry.success
                imported.errorMessage = entry.errorMessage
            }

            let marker = NSEntityDescription.insertNewObject(
                forEntityName: "StoreMetadataEntity", into: targetContext
            ) as! StoreMetadataEntity
            marker.key = migrationKey
            marker.value = "complete"

            // 记录和迁移完成标记在同一次保存中提交，避免崩溃后部分导入。
            try targetContext.save()
        } catch {
            targetContext.rollback()
            throw error
        }
    }
}
