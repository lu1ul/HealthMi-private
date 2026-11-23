import CoreData
import SwiftData
import XCTest
@testable import HealthMi

@MainActor
final class SyncStateStoreTests: XCTestCase {
    private var container: NSPersistentContainer!
    private var context: NSManagedObjectContext!

    override func setUp() {
        super.setUp()
        container = CoreDataSchema.makePreviewContainer()
        context = container.viewContext
    }

    func testRecordUpdatesState() throws {
        let type: SyncDataType = .heartRate
        let highWater = Date()
        try SyncStateStore.record(type: type, highWater: highWater, added: 42, in: context)

        let state = try SyncStateStore.state(for: type, in: context)
        XCTAssertNotNil(state)
        XCTAssertEqual(state?.lastSyncedEnd?.timeIntervalSince(highWater) ?? -1, 0, accuracy: 1)
        XCTAssertEqual(state?.lastAddedCount, 42)
    }

    func testClearAllRemovesAllStates() throws {
        try SyncStateStore.record(type: .heartRate, highWater: Date(), added: 10, in: context)
        try SyncStateStore.record(type: .sleep, highWater: Date(), added: 5, in: context)
        try SyncStateStore.record(type: .spo2, highWater: Date(), added: 3, in: context)

        SyncStateStore.clearAll(in: context)

        for type in SyncDataType.allCases {
            let state = try SyncStateStore.state(for: type, in: context)
            XCTAssertNil(state)
        }
    }

    func testRecordTwiceUpdatesSameRow() throws {
        let type: SyncDataType = .heartRate
        try SyncStateStore.record(type: type, highWater: Date(timeIntervalSinceNow: -3600), added: 10, in: context)
        try SyncStateStore.record(type: type, highWater: Date(), added: 20, in: context)

        let state = try SyncStateStore.state(for: type, in: context)
        XCTAssertEqual(state?.lastAddedCount, 20)
    }
}

@MainActor
final class StressStoreTests: XCTestCase {
    private var container: NSPersistentContainer!
    private var context: NSManagedObjectContext!

    override func setUp() {
        super.setUp()
        container = CoreDataSchema.makePreviewContainer()
        context = container.viewContext
    }

    func testReplaceRangePreservesRecordsOutsideQueriedRange() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let end = start.addingTimeInterval(10_000)
        let before = MiStressSample(timestamp: start.addingTimeInterval(-60), stressScore: 10)
        let oldInside = MiStressSample(timestamp: start.addingTimeInterval(60), stressScore: 20)
        let after = MiStressSample(timestamp: end.addingTimeInterval(60), stressScore: 30)
        _ = try StressStore.save(samples: [before, oldInside, after], in: context)

        let replacement = MiStressSample(timestamp: start.addingTimeInterval(120), stressScore: 45)
        let outOfRangeResult = MiStressSample(timestamp: end.addingTimeInterval(120), stressScore: 55)
        let added = try StressStore.replaceRange(
            start: start,
            end: end,
            samples: [replacement, outOfRangeResult],
            in: context
        )

        let request = StressRecordEntity.fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: true)]
        let records = try context.fetch(request)
        XCTAssertEqual(added, 1)
        XCTAssertEqual(records.map(\.externalID), [before.id, replacement.id, after.id])
    }
}

@MainActor
final class LegacySwiftDataImporterTests: XCTestCase {
    func testImportPreservesRowsAndCanBeRetriedWithoutDuplicates() throws {
        guard #available(iOS 17.0, *) else {
            throw XCTSkip("SwiftData 旧库导入仅在 iOS 17 及以上可用")
        }
        try verifyImportIsIdempotent()
    }

    @available(iOS 17.0, *)
    private func verifyImportIsIdempotent() throws {
        let schema = Schema([SyncState.self, StressRecord.self, SyncLogEntry.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let legacyContainer = try ModelContainer(
            for: schema,
            migrationPlan: MigrationPlan.self,
            configurations: [configuration]
        )
        let legacyContext = legacyContainer.mainContext
        let timestamp = Date(timeIntervalSince1970: 1_800_000_000)
        legacyContext.insert(SyncState(
            typeRawValue: SyncDataType.heartRate.rawValue,
            lastSyncedEnd: timestamp,
            lastSyncAt: timestamp,
            lastAddedCount: 17
        ))
        legacyContext.insert(StressRecord(externalID: "stress-1", timestamp: timestamp, stressScore: 48))
        legacyContext.insert(SyncLogEntry(
            timestamp: timestamp,
            typeRawValue: SyncDataType.stress.rawValue,
            fetched: 5,
            added: 2,
            success: false,
            errorMessage: "保留的历史错误"
        ))
        try legacyContext.save()

        let targetContainer = CoreDataSchema.makePreviewContainer()
        let targetContext = targetContainer.viewContext
        try LegacySwiftDataImporter.importRecords(from: legacyContext, into: targetContext)
        try LegacySwiftDataImporter.importRecords(from: legacyContext, into: targetContext)

        let states = try targetContext.fetch(SyncStateEntity.fetchRequest())
        let stressRecords = try targetContext.fetch(StressRecordEntity.fetchRequest())
        let logs = try targetContext.fetch(SyncLogEntryEntity.fetchRequest())
        let markers = try targetContext.fetch(StoreMetadataEntity.fetchRequest())
        XCTAssertEqual(states.count, 1)
        XCTAssertEqual(states.first?.lastSyncedEnd, timestamp)
        XCTAssertEqual(states.first?.lastSyncAt, timestamp)
        XCTAssertEqual(states.first?.lastAddedCount, 17)
        XCTAssertEqual(stressRecords.count, 1)
        XCTAssertEqual(stressRecords.first?.externalID, "stress-1")
        XCTAssertEqual(stressRecords.first?.stressScore, 48)
        XCTAssertEqual(logs.count, 1)
        XCTAssertEqual(logs.first?.timestamp, timestamp)
        XCTAssertEqual(logs.first?.typeRawValue, SyncDataType.stress.rawValue)
        XCTAssertEqual(logs.first?.fetched, 5)
        XCTAssertEqual(logs.first?.added, 2)
        XCTAssertEqual(logs.first?.errorMessage, "保留的历史错误")
        XCTAssertEqual(logs.first?.success, false)
        XCTAssertEqual(markers.count, 1)
        let remainingLegacyStates = try legacyContext.fetch(FetchDescriptor<SyncState>())
        let remainingLegacyStress = try legacyContext.fetch(FetchDescriptor<StressRecord>())
        let remainingLegacyLogs = try legacyContext.fetch(FetchDescriptor<SyncLogEntry>())
        XCTAssertEqual(remainingLegacyStates.count, 1)
        XCTAssertEqual(remainingLegacyStress.count, 1)
        XCTAssertEqual(remainingLegacyLogs.count, 1)
    }
}
