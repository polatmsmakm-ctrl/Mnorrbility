import CoreData
import Foundation

/// النسخ الاحتياطي: ملف واحد (.sabboura) فيه كل التصنيفات والمواد والمذكرات والصفحات والمرفقات.
///
/// التصميم مستقل عن إصدار التطبيق وعن نموذج قاعدة البيانات:
/// - البيانات الثقيلة (الرسم، المرفقات...) تُكتب كما هي في ملف واحد، وفهرس JSON في آخره يصف كل شيء.
/// - كل حقول الفهرس اختيارية، فتُهمل الحقول الجديدة المجهولة وتُعامل الحقول الناقصة كقيم افتراضية.
/// - الاسترجاع يضيف ما هو ناقص ولا يمسح شيئاً؛ والمذكرة الموجودة تُستبدل فقط إذا كانت نسخة الملف أحدث.
enum BackupService {
    static let fileExtension = "sabboura"
    static let formatVersion = 1

    private static let magic = Data("SBBKUP1\n".utf8)
    private static let endMark = Data("SBKEND1".utf8)
    private static let footerSize = 8 + 7

    // MARK: الفهرس

    struct BlobRef: Codable {
        var offset: UInt64
        var length: UInt64
    }

    struct BCategory: Codable {
        var uuid: String?
        var name: String?
        var sortOrder: Int64?
        var createdAt: Double?
        var isExpanded: Bool?
    }

    struct BSubject: Codable {
        var uuid: String?
        var name: String?
        var colorHex: String?
        var iconName: String?
        var sortOrder: Int64?
        var createdAt: Double?
        var categoryID: String?
    }

    struct BAttachment: Codable {
        var uuid: String?
        var fileName: String?
        var typeIdentifier: String?
        var byteCount: Int64?
        var createdAt: Double?
        var isPageSource: Bool?
        var data: BlobRef?
    }

    struct BPage: Codable {
        var uuid: String?
        var index: Int64?
        var drawing: BlobRef?
        var items: BlobRef?
        var backgroundKind: String?
        var backgroundColorHex: String?
        var lineColorHex: String?
        var lineSpacing: Double?
        var width: Double?
        var height: Double?
        var pdfSourceID: String?
        var pdfPageIndex: Int64?
    }

    struct BNote: Codable {
        var uuid: String?
        var title: String?
        var createdAt: Double?
        var updatedAt: Double?
        var lastPageIndex: Int64?
        var isFavorite: Bool?
        var deletedAt: Double?
        var lastOpenedAt: Double?
        var subjectID: String?
        var study: BlobRef?
        var pages: [BPage]?
        var attachments: [BAttachment]?
    }

    struct Manifest: Codable {
        var formatVersion: Int?
        var appVersion: String?
        var createdAt: Double?
        var categories: [BCategory]?
        var subjects: [BSubject]?
        var notes: [BNote]?
    }

    struct RestoreResult {
        var added = 0
        var replaced = 0
        var skipped = 0
    }

    enum BackupError: LocalizedError {
        case notABackup
        case damaged
        case io(String)

        var errorDescription: String? {
            switch self {
            case .notABackup: return "هذا الملف ليس نسخة احتياطية من التطبيق."
            case .damaged: return "ملف النسخة الاحتياطية تالف أو ناقص."
            case .io(let message): return message
            }
        }
    }

    // MARK: إنشاء النسخة

    /// يكتب كل البيانات في ملف ويعيد عدد المذكرات. يعمل على سياق خلفي فلا يجمّد الواجهة.
    static func export(to url: URL) throws -> Int {
        let context = PersistenceController.shared.container.newBackgroundContext()
        var failure: Error?
        var count = 0
        context.performAndWait {
            do {
                count = try write(context: context, to: url)
            } catch {
                failure = error
            }
        }
        if let failure { throw failure }
        return count
    }

    private static func write(context: NSManagedObjectContext, to url: URL) throws -> Int {
        try? FileManager.default.removeItem(at: url)
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw BackupError.io("تعذّر إنشاء ملف النسخة الاحتياطية.")
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.write(contentsOf: magic)
        var position = UInt64(magic.count)

        func put(_ data: Data?) throws -> BlobRef? {
            guard let data, !data.isEmpty else { return nil }
            try handle.write(contentsOf: data)
            let ref = BlobRef(offset: position, length: UInt64(data.count))
            position += UInt64(data.count)
            return ref
        }

        var manifest = Manifest(formatVersion: formatVersion,
                                appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
                                createdAt: Date().timeIntervalSince1970,
                                categories: [], subjects: [], notes: [])

        let categories = try context.fetch(NSFetchRequest<CDCategory>(entityName: "CDCategory"))
        for category in categories where category.isAlive {
            manifest.categories?.append(BCategory(uuid: category.uuid?.uuidString,
                                                  name: category.name,
                                                  sortOrder: category.sortOrder,
                                                  createdAt: category.createdAt?.timeIntervalSince1970,
                                                  isExpanded: category.isExpanded))
        }

        let subjects = try context.fetch(NSFetchRequest<CDSubject>(entityName: "CDSubject"))
        for subject in subjects where subject.isAlive {
            manifest.subjects?.append(BSubject(uuid: subject.uuid?.uuidString,
                                               name: subject.name,
                                               colorHex: subject.colorHex,
                                               iconName: subject.iconName,
                                               sortOrder: subject.sortOrder,
                                               createdAt: subject.createdAt?.timeIntervalSince1970,
                                               categoryID: subject.category?.uuid?.uuidString))
        }

        let notes = try context.fetch(NSFetchRequest<CDNote>(entityName: "CDNote"))
        var count = 0
        for note in notes where note.isAlive {
            try autoreleasepool {
                var item = BNote(uuid: note.uuid?.uuidString,
                                 title: note.title,
                                 createdAt: note.createdAt?.timeIntervalSince1970,
                                 updatedAt: note.updatedAt?.timeIntervalSince1970,
                                 lastPageIndex: note.lastPageIndex,
                                 isFavorite: note.isFavorite,
                                 deletedAt: note.deletedAt?.timeIntervalSince1970,
                                 lastOpenedAt: note.lastOpenedAt?.timeIntervalSince1970,
                                 subjectID: note.subject?.uuid?.uuidString,
                                 study: try put(note.studyData),
                                 pages: [],
                                 attachments: [])
                for page in note.sortedPages {
                    item.pages?.append(BPage(uuid: page.uuid?.uuidString,
                                             index: page.index,
                                             drawing: try put(page.drawingData),
                                             items: try put(page.itemsData),
                                             backgroundKind: page.backgroundKind,
                                             backgroundColorHex: page.backgroundColorHex,
                                             lineColorHex: page.lineColorHex,
                                             lineSpacing: page.lineSpacing,
                                             width: page.width,
                                             height: page.height,
                                             pdfSourceID: page.pdfSourceID?.uuidString,
                                             pdfPageIndex: page.pdfPageIndex))
                    context.refresh(page, mergeChanges: false)
                }
                for attachment in note.sortedAttachments {
                    item.attachments?.append(BAttachment(uuid: attachment.uuid?.uuidString,
                                                         fileName: attachment.fileName,
                                                         typeIdentifier: attachment.typeIdentifier,
                                                         byteCount: attachment.byteCount,
                                                         createdAt: attachment.createdAt?.timeIntervalSince1970,
                                                         isPageSource: attachment.isPageSource,
                                                         data: try put(attachment.data)))
                    context.refresh(attachment, mergeChanges: false)
                }
                manifest.notes?.append(item)
                context.refresh(note, mergeChanges: false)
                count += 1
            }
        }

        let json = try JSONEncoder().encode(manifest)
        try handle.write(contentsOf: json)
        var length = UInt64(json.count).bigEndian
        try handle.write(contentsOf: Data(bytes: &length, count: 8))
        try handle.write(contentsOf: endMark)
        return count
    }

    // MARK: الاسترجاع

    static func restore(from url: URL) throws -> RestoreResult {
        let context = PersistenceController.shared.container.newBackgroundContext()
        context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        var failure: Error?
        var result = RestoreResult()
        context.performAndWait {
            do {
                result = try read(url: url, into: context)
            } catch {
                failure = error
            }
        }
        if let failure { throw failure }
        return result
    }

    private static func date(_ value: Double?) -> Date? {
        value.map { Date(timeIntervalSince1970: $0) }
    }

    private static func read(url: URL, into context: NSManagedObjectContext) throws -> RestoreResult {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw BackupError.io("تعذّر فتح الملف.")
        }
        defer { try? handle.close() }

        let size = try handle.seekToEnd()
        guard size >= UInt64(magic.count + footerSize) else { throw BackupError.notABackup }
        try handle.seek(toOffset: 0)
        guard try handle.read(upToCount: magic.count) == magic else { throw BackupError.notABackup }

        try handle.seek(toOffset: size - UInt64(footerSize))
        guard let footer = try handle.read(upToCount: footerSize), footer.count == footerSize,
              footer.suffix(endMark.count) == endMark else { throw BackupError.damaged }
        let manifestLength = footer.prefix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        let blobEnd = size - UInt64(footerSize)
        guard manifestLength > 0, manifestLength <= blobEnd - UInt64(magic.count) else { throw BackupError.damaged }
        try handle.seek(toOffset: blobEnd - manifestLength)
        guard let json = try handle.read(upToCount: Int(manifestLength)), json.count == Int(manifestLength),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: json) else { throw BackupError.damaged }
        let dataLimit = blobEnd - manifestLength

        func blob(_ ref: BlobRef?) -> Data? {
            guard let ref, ref.length > 0, ref.offset >= UInt64(magic.count),
                  ref.offset + ref.length <= dataLimit,
                  (try? handle.seek(toOffset: ref.offset)) != nil else { return nil }
            return try? handle.read(upToCount: Int(ref.length))
        }

        // التصنيفات والمواد: تُستخدم الموجودة (بنفس المعرّف) وتُضاف الناقصة
        var categories: [String: CDCategory] = [:]
        for existing in try context.fetch(NSFetchRequest<CDCategory>(entityName: "CDCategory")) {
            if let id = existing.uuid?.uuidString { categories[id] = existing }
        }
        for item in manifest.categories ?? [] {
            guard let id = item.uuid, categories[id] == nil else { continue }
            let category = DataStore.insert(CDCategory.self, into: context)
            category.uuid = UUID(uuidString: id) ?? UUID()
            category.name = item.name ?? ""
            category.sortOrder = item.sortOrder ?? 0
            category.createdAt = date(item.createdAt) ?? Date()
            category.isExpanded = item.isExpanded ?? true
            categories[id] = category
        }

        var subjects: [String: CDSubject] = [:]
        for existing in try context.fetch(NSFetchRequest<CDSubject>(entityName: "CDSubject")) {
            if let id = existing.uuid?.uuidString { subjects[id] = existing }
        }
        for item in manifest.subjects ?? [] {
            guard let id = item.uuid, subjects[id] == nil else { continue }
            let subject = DataStore.insert(CDSubject.self, into: context)
            subject.uuid = UUID(uuidString: id) ?? UUID()
            subject.name = item.name ?? ""
            subject.colorHex = item.colorHex ?? "#2563EB"
            subject.iconName = item.iconName ?? "book.closed"
            subject.sortOrder = item.sortOrder ?? 0
            subject.createdAt = date(item.createdAt) ?? Date()
            subject.category = item.categoryID.flatMap { categories[$0] }
            subjects[id] = subject
        }

        var existingNotes: [String: CDNote] = [:]
        for existing in try context.fetch(NSFetchRequest<CDNote>(entityName: "CDNote")) {
            if let id = existing.uuid?.uuidString { existingNotes[id] = existing }
        }

        var result = RestoreResult()
        for item in manifest.notes ?? [] {
            try autoreleasepool {
                if let id = item.uuid, let current = existingNotes[id] {
                    let currentStamp = current.updatedAt?.timeIntervalSince1970 ?? 0
                    if currentStamp >= (item.updatedAt ?? 0) {
                        result.skipped += 1
                        return
                    }
                    context.delete(current)
                    result.replaced += 1
                } else {
                    result.added += 1
                }

                let note = DataStore.insert(CDNote.self, into: context)
                note.uuid = item.uuid.flatMap { UUID(uuidString: $0) } ?? UUID()
                note.title = item.title ?? ""
                note.createdAt = date(item.createdAt) ?? Date()
                note.updatedAt = date(item.updatedAt) ?? note.createdAt
                note.lastPageIndex = item.lastPageIndex ?? 0
                note.isFavorite = item.isFavorite ?? false
                note.deletedAt = date(item.deletedAt)
                note.lastOpenedAt = date(item.lastOpenedAt)
                note.subject = item.subjectID.flatMap { subjects[$0] }
                note.studyData = blob(item.study)

                for (offset, source) in (item.pages ?? []).enumerated() {
                    let page = DataStore.insert(CDPage.self, into: context)
                    page.uuid = source.uuid.flatMap { UUID(uuidString: $0) } ?? UUID()
                    page.index = source.index ?? Int64(offset)
                    page.drawingData = blob(source.drawing)
                    page.itemsData = blob(source.items)
                    page.backgroundKind = source.backgroundKind ?? BackgroundKind.lined.rawValue
                    page.backgroundColorHex = source.backgroundColorHex ?? "#FFFFFF"
                    page.lineColorHex = source.lineColorHex ?? "#C7D3E3"
                    page.lineSpacing = source.lineSpacing ?? 34
                    page.width = source.width ?? Double(DataStore.standardPageSize.width)
                    page.height = source.height ?? Double(DataStore.standardPageSize.height)
                    page.pdfSourceID = source.pdfSourceID.flatMap { UUID(uuidString: $0) }
                    page.pdfPageIndex = source.pdfPageIndex ?? 0
                    page.note = note
                }

                for source in item.attachments ?? [] {
                    let attachment = DataStore.insert(CDAttachment.self, into: context)
                    attachment.uuid = source.uuid.flatMap { UUID(uuidString: $0) } ?? UUID()
                    attachment.fileName = source.fileName ?? ""
                    attachment.typeIdentifier = source.typeIdentifier ?? "public.data"
                    let data = blob(source.data)
                    attachment.data = data
                    attachment.byteCount = source.byteCount ?? Int64(data?.count ?? 0)
                    attachment.createdAt = date(source.createdAt) ?? Date()
                    attachment.isPageSource = source.isPageSource ?? false
                    attachment.note = note
                }

                try context.save()
                context.refreshAllObjects()
            }
        }
        if context.hasChanges { try context.save() }
        return result
    }
}
