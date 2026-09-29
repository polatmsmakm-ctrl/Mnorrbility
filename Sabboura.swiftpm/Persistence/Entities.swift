import CoreData
import UIKit

// MARK: - الكيانات (Core Data)
// كل الخصائص النصية والتواريخ والمعرّفات اختيارية في Swift عمداً:
// عند حذف عنصر تبقى الواجهة أحياناً تقرأه للحظة أثناء الحركة، وقراءة نص
// غير اختياري من عنصر محذوف تسبب انهياراً فورياً. نستخدم دائماً الخصائص
// المحسوبة الآمنة (displayName, colorValue, ...) في الواجهة.

/// تصنيف (مثل: الفصل الأول، مواد علمية...) يحتوي على مواد دراسية.
@objc(CDCategory)
class CDCategory: NSManagedObject {
    @NSManaged var uuid: UUID?
    @NSManaged var name: String?
    @NSManaged var sortOrder: Int64
    @NSManaged var createdAt: Date?
    @NSManaged var isExpanded: Bool
    @NSManaged var subjects: NSSet?

    override func awakeFromInsert() {
        super.awakeFromInsert()
        setPrimitiveValue(UUID(), forKey: "uuid")
        setPrimitiveValue(Date(), forKey: "createdAt")
    }
}

/// مادة دراسية تحتوي على مذكرات.
@objc(CDSubject)
class CDSubject: NSManagedObject {
    @NSManaged var uuid: UUID?
    @NSManaged var name: String?
    @NSManaged var colorHex: String?
    @NSManaged var iconName: String?
    @NSManaged var sortOrder: Int64
    @NSManaged var createdAt: Date?
    @NSManaged var category: CDCategory?
    @NSManaged var notes: NSSet?

    override func awakeFromInsert() {
        super.awakeFromInsert()
        setPrimitiveValue(UUID(), forKey: "uuid")
        setPrimitiveValue(Date(), forKey: "createdAt")
    }
}

/// مذكرة (دفتر) مكوّنة من صفحات ومرفقات.
@objc(CDNote)
class CDNote: NSManagedObject {
    @NSManaged var uuid: UUID?
    @NSManaged var title: String?
    @NSManaged var createdAt: Date?
    @NSManaged var updatedAt: Date?
    @NSManaged var lastPageIndex: Int64
    @NSManaged var thumbnailData: Data?
    @NSManaged var isFavorite: Bool
    @NSManaged var deletedAt: Date?
    @NSManaged var lastOpenedAt: Date?
    @NSManaged var subject: CDSubject?
    @NSManaged var pages: NSSet?
    @NSManaged var attachments: NSSet?

    override func awakeFromInsert() {
        super.awakeFromInsert()
        let now = Date()
        setPrimitiveValue(UUID(), forKey: "uuid")
        setPrimitiveValue(now, forKey: "createdAt")
        setPrimitiveValue(now, forKey: "updatedAt")
    }
}

/// صفحة واحدة: رسم PencilKit + إعدادات الخلفية + (اختيارياً) صفحة PDF كخلفية.
@objc(CDPage)
class CDPage: NSManagedObject {
    @NSManaged var uuid: UUID?
    @NSManaged var index: Int64
    @NSManaged var drawingData: Data?
    @NSManaged var backgroundKind: String?
    @NSManaged var backgroundColorHex: String?
    @NSManaged var lineColorHex: String?
    @NSManaged var lineSpacing: Double
    @NSManaged var width: Double
    @NSManaged var height: Double
    @NSManaged var pdfSourceID: UUID?
    @NSManaged var pdfPageIndex: Int64
    @NSManaged var itemsData: Data?
    @NSManaged var note: CDNote?

    override func awakeFromInsert() {
        super.awakeFromInsert()
        setPrimitiveValue(UUID(), forKey: "uuid")
    }
}

/// ملف مرفق (PDF، صورة، Word، ...). ملفات PDF المستوردة كصفحات تُحفظ هنا أيضاً.
@objc(CDAttachment)
class CDAttachment: NSManagedObject {
    @NSManaged var uuid: UUID?
    @NSManaged var fileName: String?
    @NSManaged var typeIdentifier: String?
    @NSManaged var data: Data?
    @NSManaged var byteCount: Int64
    @NSManaged var createdAt: Date?
    @NSManaged var isPageSource: Bool
    @NSManaged var note: CDNote?

    override func awakeFromInsert() {
        super.awakeFromInsert()
        setPrimitiveValue(UUID(), forKey: "uuid")
        setPrimitiveValue(Date(), forKey: "createdAt")
    }
}

// MARK: - حماية من العناصر المحذوفة

extension NSManagedObject {
    /// العنصر ما زال موجوداً ويمكن قراءته بأمان.
    var isAlive: Bool { managedObjectContext != nil && !isDeleted }
}

// MARK: - خصائص آمنة للواجهة

extension CDCategory {
    var displayName: String { isAlive ? (name ?? "") : "" }

    var sortedSubjects: [CDSubject] {
        guard isAlive else { return [] }
        return ((subjects as? Set<CDSubject>) ?? [])
            .filter(\.isAlive)
            .sorted { $0.sortOrder == $1.sortOrder ? $0.displayName < $1.displayName : $0.sortOrder < $1.sortOrder }
    }

    static func sortedRequest() -> NSFetchRequest<CDCategory> {
        let request = NSFetchRequest<CDCategory>(entityName: "CDCategory")
        request.sortDescriptors = [
            NSSortDescriptor(key: "sortOrder", ascending: true),
            NSSortDescriptor(key: "createdAt", ascending: true)
        ]
        return request
    }
}

extension CDSubject {
    var displayName: String { isAlive ? (name ?? "") : "" }
    var colorValue: String { isAlive ? (colorHex ?? "#2563EB") : "#2563EB" }
    var iconValue: String {
        guard isAlive, let iconName, !iconName.isEmpty else { return "book.closed" }
        return iconName
    }
    var notesCount: Int {
        guard isAlive else { return 0 }
        return ((notes as? Set<CDNote>) ?? []).filter { $0.isAlive && $0.deletedAt == nil }.count
    }

    static func sortedRequest() -> NSFetchRequest<CDSubject> {
        let request = NSFetchRequest<CDSubject>(entityName: "CDSubject")
        request.sortDescriptors = [
            NSSortDescriptor(key: "sortOrder", ascending: true),
            NSSortDescriptor(key: "createdAt", ascending: true)
        ]
        return request
    }
}

extension CDNote {
    var titleText: String { isAlive ? (title ?? "") : "" }

    var displayTitle: String {
        let text = titleText.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? "بدون عنوان" : text
    }

    var sortedPages: [CDPage] {
        guard isAlive else { return [] }
        return ((pages as? Set<CDPage>) ?? [])
            .filter(\.isAlive)
            .sorted { $0.index < $1.index }
    }

    var sortedAttachments: [CDAttachment] {
        guard isAlive else { return [] }
        return ((attachments as? Set<CDAttachment>) ?? [])
            .filter(\.isAlive)
            .sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
    }

    var pageCount: Int { isAlive ? (pages?.count ?? 0) : 0 }
    var attachmentCount: Int { isAlive ? (attachments?.count ?? 0) : 0 }
    var isTrashed: Bool { isAlive && deletedAt != nil }

    /// كل المذكرات غير المحذوفة، الأحدث تعديلاً أولاً.
    static func liveRequest() -> NSFetchRequest<CDNote> {
        let request = NSFetchRequest<CDNote>(entityName: "CDNote")
        request.predicate = NSPredicate(format: "deletedAt == nil")
        request.sortDescriptors = [NSSortDescriptor(key: "updatedAt", ascending: false)]
        return request
    }

    /// المذكرات في سلة المحذوفات.
    static func trashRequest() -> NSFetchRequest<CDNote> {
        let request = NSFetchRequest<CDNote>(entityName: "CDNote")
        request.predicate = NSPredicate(format: "deletedAt != nil")
        request.sortDescriptors = [NSSortDescriptor(key: "deletedAt", ascending: false)]
        return request
    }

    /// المذكرات الخاصة بمادة معيّنة، الأحدث تعديلاً أولاً.
    static func request(for subject: CDSubject) -> NSFetchRequest<CDNote> {
        let request = NSFetchRequest<CDNote>(entityName: "CDNote")
        request.predicate = NSPredicate(format: "subject == %@ AND deletedAt == nil", subject)
        request.sortDescriptors = [NSSortDescriptor(key: "updatedAt", ascending: false)]
        return request
    }
}

extension CDPage {
    var pageSize: CGSize {
        guard isAlive else { return DataStore.standardPageSize }
        return CGSize(width: width > 1 ? width : DataStore.standardPageSize.width,
                      height: height > 1 ? height : DataStore.standardPageSize.height)
    }

    var kind: BackgroundKind {
        guard isAlive, let raw = backgroundKind else { return .blank }
        return BackgroundKind(rawValue: raw) ?? .blank
    }

    var backgroundHex: String { isAlive ? (backgroundColorHex ?? "#FFFFFF") : "#FFFFFF" }
    var lineHex: String { isAlive ? (lineColorHex ?? PageTemplate.factory.lineHex) : PageTemplate.factory.lineHex }
    var spacingValue: Double {
        guard isAlive, lineSpacing >= 8 else { return PageTemplate.factory.spacing }
        return lineSpacing
    }

    var backgroundConfig: PageBackgroundConfig {
        var config = PageBackgroundConfig(kind: kind,
                                          backgroundHex: backgroundHex,
                                          lineHex: lineHex,
                                          spacing: CGFloat(spacingValue),
                                          pageSize: pageSize)
        config.isPDF = isPDFPage
        return config
    }

    var template: PageTemplate {
        PageTemplate(kind: kind, backgroundHex: backgroundHex, lineHex: lineHex, spacing: spacingValue)
    }

    var isPDFPage: Bool { isAlive && pdfSourceID != nil }

    /// النصوص والصور الموضوعة على الصفحة.
    var items: [PageItem] {
        get {
            guard isAlive, let itemsData, !itemsData.isEmpty else { return [] }
            return (try? JSONDecoder().decode([PageItem].self, from: itemsData)) ?? []
        }
        set {
            guard isAlive else { return }
            itemsData = newValue.isEmpty ? nil : (try? JSONEncoder().encode(newValue))
        }
    }

    /// يطبّق قالب خلفية على الصفحة. صفحات PDF تحتفظ بنمطها الفارغ عند التطبيق الجماعي.
    func apply(_ template: PageTemplate, includePattern: Bool = true) {
        guard isAlive else { return }
        if includePattern || pdfSourceID == nil {
            backgroundKind = template.kind.rawValue
        }
        backgroundColorHex = template.backgroundHex
        lineColorHex = template.lineHex
        lineSpacing = template.spacing
    }
}

extension CDAttachment {
    var displayName: String {
        guard isAlive, let fileName, !fileName.isEmpty else { return "ملف" }
        return fileName
    }

    var typeValue: String { isAlive ? (typeIdentifier ?? "public.data") : "public.data" }
}
