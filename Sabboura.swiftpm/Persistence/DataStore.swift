import CoreData
import UIKit
import UniformTypeIdentifiers

extension Notification.Name {
    /// يُرسل عند انتقال التطبيق للخلفية حتى يحفظ المحرر الرسم الحالي فوراً.
    static let sabbouraFlushRequested = Notification.Name("sabbouraFlushRequested")
}

/// عمليات الإنشاء والتعديل والحذف على قاعدة البيانات.
enum DataStore {
    /// حجم الصفحة القياسي (نسبة A4) بالنقاط. كل الصفحات تُطبّع على هذا العرض
    /// حتى تبقى سماكة الأقلام متسقة بين الصفحات العادية وصفحات PDF.
    static let standardPageSize = CGSize(width: 820, height: 1160)

    // MARK: حفظ وحذف

    static func save(_ context: NSManagedObjectContext) {
        guard context.hasChanges else { return }
        do {
            try context.save()
        } catch {
            print("⚠️ Save failed: \(error)")
        }
    }

    static func insert<T: NSManagedObject>(_ type: T.Type, into context: NSManagedObjectContext) -> T {
        let name = String(describing: type)
        let object = NSEntityDescription.insertNewObject(forEntityName: name, into: context)
        guard let typed = object as? T else {
            fatalError("Core Data entity \(name) is not mapped to \(T.self)")
        }
        return typed
    }

    /// حذف مؤجَّل لدورة لاحقة: تُغلق الواجهة ما يعرض العنصر أولاً ثم يُحذف.
    static func deleteLater(_ object: NSManagedObject, context: NSManagedObjectContext) {
        DispatchQueue.main.async {
            guard object.isAlive else { return }
            context.delete(object)
            save(context)
        }
    }

    // MARK: التصنيفات والمواد

    @discardableResult
    static func createCategory(named name: String, in context: NSManagedObjectContext) -> CDCategory {
        let category = insert(CDCategory.self, into: context)
        category.name = name
        category.isExpanded = true
        let count = (try? context.count(for: NSFetchRequest<CDCategory>(entityName: "CDCategory"))) ?? 1
        category.sortOrder = Int64(count)
        save(context)
        return category
    }

    @discardableResult
    static func createSubject(named name: String,
                              colorHex: String,
                              iconName: String,
                              category: CDCategory?,
                              in context: NSManagedObjectContext) -> CDSubject {
        let subject = insert(CDSubject.self, into: context)
        subject.name = name
        subject.colorHex = colorHex
        subject.iconName = iconName
        subject.category = category
        let count = (try? context.count(for: NSFetchRequest<CDSubject>(entityName: "CDSubject"))) ?? 1
        subject.sortOrder = Int64(count)
        save(context)
        return subject
    }

    // MARK: المذكرات والصفحات

    static func defaultNoteTitle() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ar")
        formatter.dateFormat = "d MMMM"
        return "مذكرة \(formatter.string(from: Date()))"
    }

    /// مذكرة جديدة داخل مجلد، أو بدون مجلد («غير مصنفة»).
    @discardableResult
    static func createNote(in subject: CDSubject?, title: String, context: NSManagedObjectContext) -> CDNote {
        let note = insert(CDNote.self, into: context)
        note.title = title
        note.subject = subject?.isAlive == true ? subject : nil
        note.lastOpenedAt = Date()
        insertPage(into: note, at: 0, template: PageTemplate.savedDefault, context: context)
        save(context)
        return note
    }

    /// مذكرة جديدة من ملف PDF: كل صفحة من الملف تصبح صفحة يُكتب عليها.
    static func createNote(fromPDF data: Data, fileName: String, in subject: CDSubject?,
                           context: NSManagedObjectContext) -> CDNote? {
        guard PDFSourceCache.makeDocument(from: data) != nil else { return nil }
        let note = insert(CDNote.self, into: context)
        let title = (fileName as NSString).deletingPathExtension
        note.title = title.isEmpty ? defaultNoteTitle() : title
        note.subject = subject?.isAlive == true ? subject : nil
        note.lastOpenedAt = Date()
        let count = importPDFPages(data: data, fileName: fileName, into: note, at: 0, context: context)
        if count == 0 {
            context.delete(note)
            save(context)
            return nil
        }
        save(context)
        return note
    }

    // MARK: سلة المحذوفات والمفضلة

    static func moveToTrash(_ notes: [CDNote], context: NSManagedObjectContext) {
        let now = Date()
        for note in notes where note.isAlive {
            note.deletedAt = now
        }
        save(context)
    }

    static func restore(_ note: CDNote, context: NSManagedObjectContext) {
        guard note.isAlive else { return }
        note.deletedAt = nil
        if note.subject?.isAlive != true { note.subject = nil }
        note.updatedAt = Date()
        save(context)
    }

    static func deletePermanently(_ notes: [CDNote], context: NSManagedObjectContext) {
        for note in notes where note.isAlive {
            context.delete(note)
        }
        save(context)
    }

    /// حذف المذكرات التي مضى على وجودها في السلة أكثر من 30 يوماً.
    static func purgeOldTrash(_ context: NSManagedObjectContext) {
        let request = NSFetchRequest<CDNote>(entityName: "CDNote")
        let limit = Date().addingTimeInterval(-30 * 24 * 3600)
        request.predicate = NSPredicate(format: "deletedAt != nil AND deletedAt < %@", limit as NSDate)
        let old = (try? context.fetch(request)) ?? []
        guard !old.isEmpty else { return }
        deletePermanently(old, context: context)
    }

    /// حذف مجلد: مذكراته تنتقل إلى «المحذوفة مؤخراً».
    static func deleteFolder(_ subject: CDSubject, context: NSManagedObjectContext) {
        guard subject.isAlive else { return }
        let notes = ((subject.notes as? Set<CDNote>) ?? []).filter(\.isAlive)
        let now = Date()
        for note in notes {
            if note.deletedAt == nil { note.deletedAt = now }
            note.subject = nil
        }
        context.delete(subject)
        save(context)
    }

    static func toggleFavorite(_ note: CDNote, context: NSManagedObjectContext) {
        guard note.isAlive else { return }
        note.isFavorite.toggle()
        save(context)
    }

    @discardableResult
    static func insertPage(into note: CDNote,
                           at index: Int,
                           template: PageTemplate,
                           size: CGSize = standardPageSize,
                           context: NSManagedObjectContext) -> CDPage {
        var pages = note.sortedPages
        let page = insert(CDPage.self, into: context)
        page.apply(template)
        page.width = Double(size.width)
        page.height = Double(size.height)
        page.note = note
        pages.insert(page, at: min(max(0, index), pages.count))
        reindex(pages)
        note.updatedAt = Date()
        return page
    }

    @discardableResult
    static func duplicatePage(_ source: CDPage, in note: CDNote, context: NSManagedObjectContext) -> CDPage {
        var pages = note.sortedPages
        let copy = insert(CDPage.self, into: context)
        copy.drawingData = source.drawingData
        copy.backgroundKind = source.backgroundKind
        copy.backgroundColorHex = source.backgroundColorHex
        copy.lineColorHex = source.lineColorHex
        copy.lineSpacing = source.lineSpacing
        copy.width = source.width
        copy.height = source.height
        copy.pdfSourceID = source.pdfSourceID
        copy.pdfPageIndex = source.pdfPageIndex
        copy.itemsData = source.itemsData
        copy.note = note
        let position = (pages.firstIndex(of: source) ?? pages.count - 1) + 1
        pages.insert(copy, at: min(max(0, position), pages.count))
        reindex(pages)
        note.updatedAt = Date()
        save(context)
        return copy
    }

    static func deletePage(_ page: CDPage, from note: CDNote, context: NSManagedObjectContext) {
        let remaining = note.sortedPages.filter { $0 != page }
        context.delete(page)
        reindex(remaining)
        note.updatedAt = Date()
        save(context)
    }

    static func movePage(in note: CDNote, from source: Int, to destination: Int, context: NSManagedObjectContext) {
        var pages = note.sortedPages
        guard pages.indices.contains(source), pages.indices.contains(destination) else { return }
        let page = pages.remove(at: source)
        pages.insert(page, at: destination)
        reindex(pages)
        note.updatedAt = Date()
        save(context)
    }

    static func reindex(_ pages: [CDPage]) {
        for (offset, page) in pages.enumerated() where page.index != Int64(offset) {
            page.index = Int64(offset)
        }
    }

    @discardableResult
    static func duplicateNote(_ source: CDNote, context: NSManagedObjectContext) -> CDNote {
        let copy = insert(CDNote.self, into: context)
        copy.title = source.titleText + " (نسخة)"
        copy.subject = source.subject
        copy.thumbnailData = source.thumbnailData
        copy.isFavorite = source.isFavorite
        var idMap: [UUID: UUID] = [:]
        for attachment in source.sortedAttachments {
            let newAttachment = addAttachment(data: attachment.data ?? Data(),
                                              fileName: attachment.displayName,
                                              typeIdentifier: attachment.typeValue,
                                              isPageSource: attachment.isPageSource,
                                              to: copy,
                                              context: context)
            if let old = attachment.uuid, let new = newAttachment.uuid { idMap[old] = new }
        }
        for page in source.sortedPages {
            let newPage = insert(CDPage.self, into: context)
            newPage.index = page.index
            newPage.drawingData = page.drawingData
            newPage.backgroundKind = page.backgroundKind
            newPage.backgroundColorHex = page.backgroundColorHex
            newPage.lineColorHex = page.lineColorHex
            newPage.lineSpacing = page.lineSpacing
            newPage.width = page.width
            newPage.height = page.height
            newPage.pdfSourceID = page.pdfSourceID.map { idMap[$0] ?? $0 }
            newPage.pdfPageIndex = page.pdfPageIndex
            newPage.items = page.items.map { item in
                var copyItem = item
                copyItem.id = UUID()
                copyItem.attachmentID = item.attachmentID.map { idMap[$0] ?? $0 }
                return copyItem
            }
            newPage.note = copy
        }
        save(context)
        return copy
    }

    // MARK: المرفقات و PDF

    @discardableResult
    static func addAttachment(data: Data,
                              fileName: String,
                              typeIdentifier: String,
                              isPageSource: Bool,
                              to note: CDNote,
                              context: NSManagedObjectContext) -> CDAttachment {
        let attachment = insert(CDAttachment.self, into: context)
        attachment.data = data
        attachment.fileName = fileName
        attachment.typeIdentifier = typeIdentifier
        attachment.byteCount = Int64(data.count)
        attachment.isPageSource = isPageSource
        attachment.note = note
        note.updatedAt = Date()
        return attachment
    }

    static func attachment(with id: UUID, in context: NSManagedObjectContext) -> CDAttachment? {
        let request = NSFetchRequest<CDAttachment>(entityName: "CDAttachment")
        request.predicate = NSPredicate(format: "uuid == %@", id as NSUUID)
        request.fetchLimit = 1
        return (try? context.fetch(request))?.first
    }

    /// يحوّل ملف PDF إلى صفحات قابلة للكتابة عليها، ويُدرجها في الموضع المحدد.
    /// يعيد عدد الصفحات المضافة (صفر إن لم يكن الملف PDF صالحاً).
    @discardableResult
    static func importPDFPages(data: Data,
                               fileName: String,
                               into note: CDNote,
                               at index: Int,
                               context: NSManagedObjectContext) -> Int {
        guard let document = PDFSourceCache.makeDocument(from: data), document.numberOfPages > 0 else {
            return 0
        }
        var pages = note.sortedPages
        let source = addAttachment(data: data,
                                   fileName: fileName,
                                   typeIdentifier: UTType.pdf.identifier,
                                   isPageSource: true,
                                   to: note,
                                   context: context)
        if let id = source.uuid {
            PDFSourceCache.shared.store(document, for: id)
        }

        var newPages: [CDPage] = []
        for pageNumber in 1...document.numberOfPages {
            guard let pdfPage = document.page(at: pageNumber) else { continue }
            let page = insert(CDPage.self, into: context)
            let size = normalizedSize(of: pdfPage)
            page.width = Double(size.width)
            page.height = Double(size.height)
            page.backgroundKind = BackgroundKind.blank.rawValue
            page.backgroundColorHex = "#FFFFFF"
            page.lineColorHex = PageTemplate.factory.lineHex
            page.lineSpacing = PageTemplate.factory.spacing
            page.pdfSourceID = source.uuid
            page.pdfPageIndex = Int64(pageNumber - 1)
            page.note = note
            newPages.append(page)
        }

        pages.insert(contentsOf: newPages, at: min(max(0, index), pages.count))
        reindex(pages)
        note.updatedAt = Date()
        save(context)
        return newPages.count
    }

    /// حجم صفحة PDF بعد تطبيعها على العرض القياسي مع مراعاة التدوير.
    static func normalizedSize(of page: CGPDFPage) -> CGSize {
        let box = page.getBoxRect(.cropBox)
        let rotation = ((Int(page.rotationAngle) % 360) + 360) % 360
        var width = box.width
        var height = box.height
        if rotation == 90 || rotation == 270 {
            swap(&width, &height)
        }
        guard width > 0, height > 0 else { return standardPageSize }
        let scale = standardPageSize.width / width
        let normalizedHeight = min(max((height * scale).rounded(), 200), 6000)
        return CGSize(width: standardPageSize.width, height: normalizedHeight)
    }

    /// يحوّل صورة إلى ملف PDF بصفحة واحدة حتى تُعامل مثل صفحات PDF.
    static func pdfData(fromImageData data: Data) -> Data? {
        guard let image = UIImage(data: data), image.size.width > 0, image.size.height > 0 else { return nil }
        let width = standardPageSize.width
        let height = min((width * image.size.height / image.size.width).rounded(), 6000)
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        let renderer = UIGraphicsPDFRenderer(bounds: rect)
        return renderer.pdfData { context in
            context.beginPage()
            image.draw(in: rect)
        }
    }

    /// ملف PDF تجريبي من صفحتين (يُستخدم في الاختبار الآلي).
    static func samplePDF() -> Data {
        let bounds = CGRect(x: 0, y: 0, width: 595, height: 842)
        let pages: [(title: String, lines: [String], arabic: Bool)] = [
            ("Sample PDF — page 1", [
                "Photosynthesis is the process plants use to turn sunlight into chemical energy.",
                "Chlorophyll is the green pigment that absorbs light in the leaves.",
                "The Calvin cycle produces glucose from carbon dioxide.",
                "Stomata are tiny openings that allow gas exchange in leaves.",
                "Plants release oxygen as a by-product of photosynthesis."
            ], false),
            ("Sample PDF — page 2", [
                "الخلية هي الوحدة الأساسية لبناء الكائنات الحية.",
                "النواة هي مركز التحكم في الخلية وتحتوي على المادة الوراثية.",
                "الميتوكوندريا هي مصنع الطاقة في الخلية.",
                "الغشاء الخلوي يتحكم في دخول المواد وخروجها من الخلية.",
                "اكتشف العالم روبرت هوك الخلية عام 1665."
            ], true)
        ]
        return UIGraphicsPDFRenderer(bounds: bounds).pdfData { context in
            for page in pages {
                context.beginPage()
                (page.title as NSString).draw(at: CGPoint(x: 60, y: 70),
                                             withAttributes: [.font: UIFont.boldSystemFont(ofSize: 30),
                                                              .foregroundColor: UIColor.black])
                UIColor.systemTeal.withAlphaComponent(0.35).setFill()
                UIBezierPath(roundedRect: CGRect(x: 60, y: 140, width: 475, height: 220), cornerRadius: 18).fill()
                let paragraph = NSMutableParagraphStyle()
                paragraph.alignment = page.arabic ? .right : .left
                paragraph.baseWritingDirection = page.arabic ? .rightToLeft : .leftToRight
                paragraph.lineSpacing = 4
                let body = page.lines.joined(separator: "\n")
                (body as NSString).draw(in: CGRect(x: 76, y: 152, width: 443, height: 200),
                                        withAttributes: [.font: UIFont.systemFont(ofSize: 15),
                                                         .foregroundColor: UIColor.black,
                                                         .paragraphStyle: paragraph])
                UIColor.darkGray.setStroke()
                for line in 0..<12 {
                    let y = 420 + CGFloat(line) * 30
                    let path = UIBezierPath()
                    path.move(to: CGPoint(x: 60, y: y))
                    path.addLine(to: CGPoint(x: 535, y: y))
                    path.lineWidth = 1
                    path.stroke()
                }
            }
        }
    }

    // MARK: بيانات أولية

    static func seedIfNeeded(_ context: NSManagedObjectContext) {
        let key = "sabboura.didSeed.v1"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)

        let existing = (try? context.count(for: NSFetchRequest<CDSubject>(entityName: "CDSubject"))) ?? 0
        guard existing == 0 else { return }

        let term = createCategory(named: "الفصل الدراسي الحالي", in: context)
        createSubject(named: "الرياضيات", colorHex: "#2563EB", iconName: "function", category: term, in: context)
        createSubject(named: "الفيزياء", colorHex: "#7C3AED", iconName: "atom", category: term, in: context)
        createSubject(named: "الكيمياء", colorHex: "#059669", iconName: "flask", category: term, in: context)
        createSubject(named: "اللغة العربية", colorHex: "#B45309", iconName: "character.book.closed", category: term, in: context)

        let general = createCategory(named: "عام", in: context)
        createSubject(named: "ملاحظات سريعة", colorHex: "#F59E0B", iconName: "note.text", category: general, in: context)
        // الحفظ فوراً يثبّت معرّفات المجلدات (المعرّف المؤقت يتغيّر عند أول حفظ فيربك التنقّل)
        save(context)
    }
}

// MARK: - ذاكرة مؤقتة لمستندات PDF

/// يحتفظ بمستندات PDF المفتوحة حتى لا يُعاد تحليلها عند كل تنقّل بين الصفحات.
final class PDFSourceCache {
    static let shared = PDFSourceCache()

    private let lock = NSLock()
    private var documents: [UUID: CGPDFDocument] = [:]

    static func makeDocument(from data: Data) -> CGPDFDocument? {
        guard let provider = CGDataProvider(data: data as CFData),
              let document = CGPDFDocument(provider) else { return nil }
        if document.isEncrypted && !document.isUnlocked {
            _ = document.unlockWithPassword("")
        }
        return document.isUnlocked ? document : nil
    }

    func store(_ document: CGPDFDocument, for id: UUID) {
        lock.lock()
        documents[id] = document
        lock.unlock()
    }

    func document(for id: UUID, context: NSManagedObjectContext) -> CGPDFDocument? {
        lock.lock()
        let cached = documents[id]
        lock.unlock()
        if let cached { return cached }
        guard let attachment = DataStore.attachment(with: id, in: context),
              let data = attachment.data,
              let document = Self.makeDocument(from: data) else { return nil }
        store(document, for: id)
        return document
    }

    func page(for page: CDPage, context: NSManagedObjectContext) -> CGPDFPage? {
        guard page.isAlive, let id = page.pdfSourceID,
              let document = document(for: id, context: context) else { return nil }
        let number = Int(page.pdfPageIndex) + 1
        guard number >= 1, number <= document.numberOfPages else { return nil }
        return document.page(at: number)
    }
}
