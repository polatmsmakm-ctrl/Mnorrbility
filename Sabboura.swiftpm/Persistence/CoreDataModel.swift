import CoreData
import UIKit

/// نموذج Core Data مبني بالكود — يُنشأ مرة واحدة فقط لكامل التطبيق.
/// كل الخصائص اختيارية في النموذج حتى لا يفشل الحفظ أبداً بسبب قيمة ناقصة.
enum CoreDataModel {
    static let shared: NSManagedObjectModel = build()

    private static func build() -> NSManagedObjectModel {
        let category = entity("CDCategory")
        let subject = entity("CDSubject")
        let note = entity("CDNote")
        let page = entity("CDPage")
        let attachment = entity("CDAttachment")

        category.properties = [
            attribute("uuid", .UUIDAttributeType),
            attribute("name", .stringAttributeType, defaultValue: ""),
            attribute("sortOrder", .integer64AttributeType, defaultValue: 0),
            attribute("createdAt", .dateAttributeType),
            attribute("isExpanded", .booleanAttributeType, defaultValue: true)
        ]

        subject.properties = [
            attribute("uuid", .UUIDAttributeType),
            attribute("name", .stringAttributeType, defaultValue: ""),
            attribute("colorHex", .stringAttributeType, defaultValue: "#2563EB"),
            attribute("iconName", .stringAttributeType, defaultValue: "book.closed"),
            attribute("sortOrder", .integer64AttributeType, defaultValue: 0),
            attribute("createdAt", .dateAttributeType)
        ]

        note.properties = [
            attribute("uuid", .UUIDAttributeType),
            attribute("title", .stringAttributeType, defaultValue: ""),
            attribute("createdAt", .dateAttributeType),
            attribute("updatedAt", .dateAttributeType),
            attribute("lastPageIndex", .integer64AttributeType, defaultValue: 0),
            attribute("thumbnailData", .binaryDataAttributeType, externalStorage: true),
            attribute("isFavorite", .booleanAttributeType, defaultValue: false),
            attribute("deletedAt", .dateAttributeType),
            attribute("lastOpenedAt", .dateAttributeType)
        ]

        page.properties = [
            attribute("uuid", .UUIDAttributeType),
            attribute("index", .integer64AttributeType, defaultValue: 0),
            attribute("drawingData", .binaryDataAttributeType, externalStorage: true),
            attribute("backgroundKind", .stringAttributeType, defaultValue: BackgroundKind.lined.rawValue),
            attribute("backgroundColorHex", .stringAttributeType, defaultValue: "#FFFFFF"),
            attribute("lineColorHex", .stringAttributeType, defaultValue: "#C7D3E3"),
            attribute("lineSpacing", .doubleAttributeType, defaultValue: 34.0),
            attribute("width", .doubleAttributeType, defaultValue: Double(DataStore.standardPageSize.width)),
            attribute("height", .doubleAttributeType, defaultValue: Double(DataStore.standardPageSize.height)),
            attribute("pdfSourceID", .UUIDAttributeType),
            attribute("pdfPageIndex", .integer64AttributeType, defaultValue: 0),
            attribute("itemsData", .binaryDataAttributeType, externalStorage: true)
        ]

        attachment.properties = [
            attribute("uuid", .UUIDAttributeType),
            attribute("fileName", .stringAttributeType, defaultValue: ""),
            attribute("typeIdentifier", .stringAttributeType, defaultValue: "public.data"),
            attribute("data", .binaryDataAttributeType, externalStorage: true),
            attribute("byteCount", .integer64AttributeType, defaultValue: 0),
            attribute("createdAt", .dateAttributeType),
            attribute("isPageSource", .booleanAttributeType, defaultValue: false)
        ]

        // تصنيف ←→ مواد (حذف التصنيف يترك المواد بدون تصنيف)
        relate(category, "subjects", toMany: true, rule: .nullifyDeleteRule,
               subject, "category", toMany: false, rule: .nullifyDeleteRule)
        // مادة ←→ مذكرات (حذف المادة يحذف مذكراتها)
        relate(subject, "notes", toMany: true, rule: .cascadeDeleteRule,
               note, "subject", toMany: false, rule: .nullifyDeleteRule)
        // مذكرة ←→ صفحات
        relate(note, "pages", toMany: true, rule: .cascadeDeleteRule,
               page, "note", toMany: false, rule: .nullifyDeleteRule)
        // مذكرة ←→ مرفقات
        relate(note, "attachments", toMany: true, rule: .cascadeDeleteRule,
               attachment, "note", toMany: false, rule: .nullifyDeleteRule)

        let model = NSManagedObjectModel()
        model.entities = [category, subject, note, page, attachment]
        return model
    }

    private static func entity(_ name: String) -> NSEntityDescription {
        let entity = NSEntityDescription()
        entity.name = name
        entity.managedObjectClassName = name   // يطابق @objc(Name) في الأصناف
        return entity
    }

    private static func attribute(_ name: String,
                                  _ type: NSAttributeType,
                                  defaultValue: Any? = nil,
                                  externalStorage: Bool = false) -> NSAttributeDescription {
        let attribute = NSAttributeDescription()
        attribute.name = name
        attribute.attributeType = type
        attribute.isOptional = true
        if let defaultValue {
            attribute.defaultValue = defaultValue
        }
        attribute.allowsExternalBinaryDataStorage = externalStorage
        return attribute
    }

    private static func relate(_ source: NSEntityDescription, _ sourceName: String,
                               toMany sourceToMany: Bool, rule sourceRule: NSDeleteRule,
                               _ destination: NSEntityDescription, _ destinationName: String,
                               toMany destinationToMany: Bool, rule destinationRule: NSDeleteRule) {
        let forward = NSRelationshipDescription()
        forward.name = sourceName
        forward.destinationEntity = destination
        forward.minCount = 0
        forward.maxCount = sourceToMany ? 0 : 1
        forward.isOptional = true
        forward.deleteRule = sourceRule

        let inverse = NSRelationshipDescription()
        inverse.name = destinationName
        inverse.destinationEntity = source
        inverse.minCount = 0
        inverse.maxCount = destinationToMany ? 0 : 1
        inverse.isOptional = true
        inverse.deleteRule = destinationRule

        forward.inverseRelationship = inverse
        inverse.inverseRelationship = forward

        source.properties.append(forward)
        destination.properties.append(inverse)
    }
}

/// حاوية Core Data: قاعدة SQLite في مجلد Application Support مع ترحيل تلقائي
/// واستعادة تلقائية إذا تعذّر فتح قاعدة بيانات قديمة أو تالفة.
final class PersistenceController {
    static let shared = PersistenceController()

    let container: NSPersistentContainer

    var viewContext: NSManagedObjectContext { container.viewContext }

    init() {
        container = NSPersistentContainer(name: "Sabboura", managedObjectModel: CoreDataModel.shared)

        let storeURL = Self.storeDirectory().appending(path: "Sabboura.sqlite")
        container.persistentStoreDescriptions = [Self.description(for: storeURL)]

        var loadError: Error?
        container.loadPersistentStores { _, error in loadError = error }

        if let loadError {
            print("⚠️ Core Data store failed to load, recreating: \(loadError)")
            Self.moveAside(storeURL)
            container.persistentStoreDescriptions = [Self.description(for: storeURL)]
            container.loadPersistentStores { _, error in
                if let error { print("⚠️ Core Data store failed again: \(error)") }
            }
        }

        if container.persistentStoreCoordinator.persistentStores.isEmpty {
            // الملاذ الأخير: ذاكرة مؤقتة حتى لا ينهار التطبيق
            let memory = NSPersistentStoreDescription()
            memory.type = NSInMemoryStoreType
            container.persistentStoreDescriptions = [memory]
            container.loadPersistentStores { _, _ in }
        }

        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        container.viewContext.undoManager = nil
    }

    private static func description(for url: URL) -> NSPersistentStoreDescription {
        let description = NSPersistentStoreDescription(url: url)
        description.shouldMigrateStoreAutomatically = true
        description.shouldInferMappingModelAutomatically = true
        description.shouldAddStoreAsynchronously = false
        return description
    }

    private static func storeDirectory() -> URL {
        let name = AppEnvironment.isUITest ? "Sabboura-UITest" : "Sabboura"
        let directory = URL.applicationSupportDirectory.appending(path: name, directoryHint: .isDirectory)
        if AppEnvironment.isUITest && AppEnvironment.resetData {
            try? FileManager.default.removeItem(at: directory)
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func moveAside(_ storeURL: URL) {
        let stamp = Int(Date().timeIntervalSince1970)
        let manager = FileManager.default
        for suffix in ["", "-wal", "-shm"] {
            let source = URL(fileURLWithPath: storeURL.path + suffix)
            guard manager.fileExists(atPath: source.path) else { continue }
            let target = storeURL.deletingLastPathComponent().appending(path: "Sabboura-old-\(stamp).sqlite\(suffix)")
            try? manager.moveItem(at: source, to: target)
        }
    }

    func save() {
        DataStore.save(container.viewContext)
    }
}
