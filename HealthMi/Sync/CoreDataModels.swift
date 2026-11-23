import CoreData

@objc(SyncStateEntity)
final class SyncStateEntity: NSManagedObject {
    @NSManaged var typeRawValue: String
    @NSManaged var lastSyncedEnd: Date?
    @NSManaged var lastSyncAt: Date?
    @NSManaged var lastAddedCount: Int64

    static func fetchRequest() -> NSFetchRequest<SyncStateEntity> {
        NSFetchRequest(entityName: "SyncStateEntity")
    }
}

@objc(StressRecordEntity)
final class StressRecordEntity: NSManagedObject {
    @NSManaged var externalID: String
    @NSManaged var timestamp: Date
    @NSManaged var stressScore: Int64

    static func fetchRequest() -> NSFetchRequest<StressRecordEntity> {
        NSFetchRequest(entityName: "StressRecordEntity")
    }
}

@objc(SyncLogEntryEntity)
final class SyncLogEntryEntity: NSManagedObject {
    @NSManaged var timestamp: Date
    @NSManaged var typeRawValue: String
    @NSManaged var fetched: Int64
    @NSManaged var added: Int64
    @NSManaged var success: Bool
    @NSManaged var errorMessage: String?

    var displayName: String {
        SyncDataType(rawValue: typeRawValue)?.displayName ?? typeRawValue
    }

    static func fetchRequest() -> NSFetchRequest<SyncLogEntryEntity> {
        NSFetchRequest(entityName: "SyncLogEntryEntity")
    }
}

@objc(StoreMetadataEntity)
final class StoreMetadataEntity: NSManagedObject {
    @NSManaged var key: String
    @NSManaged var value: String

    static func fetchRequest() -> NSFetchRequest<StoreMetadataEntity> {
        NSFetchRequest(entityName: "StoreMetadataEntity")
    }
}

enum CoreDataSchema {
    static func makeModel() -> NSManagedObjectModel {
        let stateType = attribute("typeRawValue", type: .stringAttributeType)
        let state = entity(
            "SyncStateEntity", class: SyncStateEntity.self,
            attributes: [
                stateType,
                attribute("lastSyncedEnd", type: .dateAttributeType, optional: true),
                attribute("lastSyncAt", type: .dateAttributeType, optional: true),
                attribute("lastAddedCount", type: .integer64AttributeType),
            ],
            uniqueKeys: [["typeRawValue"]]
        )

        let stressID = attribute("externalID", type: .stringAttributeType)
        let stress = entity(
            "StressRecordEntity", class: StressRecordEntity.self,
            attributes: [
                stressID,
                attribute("timestamp", type: .dateAttributeType),
                attribute("stressScore", type: .integer64AttributeType),
            ],
            uniqueKeys: [["externalID"]]
        )

        let log = entity(
            "SyncLogEntryEntity", class: SyncLogEntryEntity.self,
            attributes: [
                attribute("timestamp", type: .dateAttributeType),
                attribute("typeRawValue", type: .stringAttributeType),
                attribute("fetched", type: .integer64AttributeType),
                attribute("added", type: .integer64AttributeType),
                attribute("success", type: .booleanAttributeType),
                attribute("errorMessage", type: .stringAttributeType, optional: true),
            ]
        )

        let metadataKey = attribute("key", type: .stringAttributeType)
        let metadata = entity(
            "StoreMetadataEntity", class: StoreMetadataEntity.self,
            attributes: [
                metadataKey,
                attribute("value", type: .stringAttributeType),
            ],
            uniqueKeys: [["key"]]
        )

        let model = NSManagedObjectModel()
        model.entities = [state, stress, log, metadata]
        return model
    }

    private static func entity(
        _ name: String,
        class managedObjectClass: NSManagedObject.Type,
        attributes: [NSAttributeDescription],
        uniqueKeys: [[String]] = []
    ) -> NSEntityDescription {
        let entity = NSEntityDescription()
        entity.name = name
        entity.managedObjectClassName = NSStringFromClass(managedObjectClass)
        entity.properties = attributes
        entity.uniquenessConstraints = uniqueKeys
        return entity
    }

    private static func attribute(
        _ name: String,
        type: NSAttributeType,
        optional: Bool = false
    ) -> NSAttributeDescription {
        let attribute = NSAttributeDescription()
        attribute.name = name
        attribute.attributeType = type
        attribute.isOptional = optional
        return attribute
    }

    static func makePreviewContainer() -> NSPersistentContainer {
        let container = NSPersistentContainer(
            name: "HealthMiPreview",
            managedObjectModel: makeModel()
        )
        let description = NSPersistentStoreDescription()
        description.type = NSInMemoryStoreType
        description.shouldAddStoreAsynchronously = false
        container.persistentStoreDescriptions = [description]
        container.loadPersistentStores { _, error in
            if let error {
                assertionFailure("无法初始化预览数据库：\(error.localizedDescription)")
            }
        }
        return container
    }
}
