import CoreData
import PencilKit
import UIKit

// MARK: - رسم خلفية الصفحة (خطوط، مربعات، نقاط، PDF...)
// دالة واحدة تُستخدم في كل مكان: لوحة الرسم (CATiledLayer)، الصور المصغّرة، والتصدير.
// الإحداثيات: نقطة الأصل أعلى يسار الصفحة ومحور y للأسفل (مثل UIKit).

enum PageBackgroundRenderer {
    /// قفل عام لرسم صفحات PDF لأن الطبقة المقسّمة ترسم عدة مربعات على خيوط متوازية.
    private static let pdfLock = NSLock()

    static func draw(_ config: PageBackgroundConfig, pdfPage: CGPDFPage?, in context: CGContext) {
        let pageRect = CGRect(origin: .zero, size: config.pageSize)
        let colors = config.effectiveColors
        context.saveGState()
        context.clip(to: pageRect)

        context.setFillColor(UIColor(hex: colors.paper).cgColor)
        context.fill(pageRect)

        // صفحات PDF في الوضع الداكن: «عكس ذكي» — الورق يصبح داكناً والنص فاتحاً مع بقاء درجة
        // كل لون كما هي (الأزرق يبقى أزرق). نرسم الـPDF مرة واحدة في صورة ثم نركّبها ثلاث مرات.
        if let pdfPage, config.darkContent && config.isPDF,
           let rendered = renderPDFRegion(pdfPage, pageRect: pageRect, context: context) {
            let (image, region) = rendered
            drawImage(image, in: region, context: context)
            drawPattern(config, lineHex: colors.line, marginHex: colors.margin, in: pageRect, context: context)
            context.setBlendMode(.difference)
            context.setFillColor(UIColor.white.cgColor)
            context.fill(pageRect)
            context.setBlendMode(.hue)
            drawImage(image, in: region, context: context)
            context.setBlendMode(.normal)
            context.restoreGState()
            return
        }

        if let pdfPage {
            drawPDF(pdfPage, in: pageRect, context: context)
        }

        drawPattern(config, lineHex: colors.line, marginHex: colors.margin, in: pageRect, context: context)

        // احتياط: عكس بسيط إذا تعذّر تجهيز الصورة
        if config.darkContent && config.isPDF {
            context.setBlendMode(.difference)
            context.setFillColor(UIColor.white.cgColor)
            context.fill(pageRect)
            context.setBlendMode(.normal)
        }
        context.restoreGState()
    }

    /// يرسم الجزء الظاهر من صفحة PDF (حسب منطقة القص الحالية) في صورة بدقة الشاشة.
    private static func renderPDFRegion(_ page: CGPDFPage, pageRect: CGRect,
                                        context: CGContext) -> (CGImage, CGRect)? {
        let region = context.boundingBoxOfClipPath.intersection(pageRect).integral
        guard !region.isNull, region.width >= 1, region.height >= 1 else { return nil }
        let ctm = context.userSpaceToDeviceSpaceTransform
        let scale = min(max(hypot(ctm.a, ctm.b), 0.25), 8)
        let pixelWidth = Int((region.width * scale).rounded(.up))
        let pixelHeight = Int((region.height * scale).rounded(.up))
        guard pixelWidth > 0, pixelHeight > 0, pixelWidth * pixelHeight <= 36_000_000,
              let bitmap = CGContext(data: nil, width: pixelWidth, height: pixelHeight,
                                     bitsPerComponent: 8, bytesPerRow: 0,
                                     space: CGColorSpaceCreateDeviceRGB(),
                                     bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                        | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        // نفس نظام إحداثيات الصفحة: الأصل أعلى اليسار ومحور y للأسفل
        bitmap.translateBy(x: 0, y: CGFloat(pixelHeight))
        bitmap.scaleBy(x: scale, y: -scale)
        bitmap.translateBy(x: -region.minX, y: -region.minY)
        bitmap.setFillColor(UIColor.white.cgColor)
        bitmap.fill(region)
        drawPDF(page, in: pageRect, context: bitmap)
        guard let image = bitmap.makeImage() else { return nil }
        return (image, region)
    }

    /// يرسم صورة في سياق محوره y للأسفل دون أن تنقلب.
    private static func drawImage(_ image: CGImage, in rect: CGRect, context: CGContext) {
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(origin: .zero, size: rect.size))
        context.restoreGState()
    }

    private static func drawPDF(_ page: CGPDFPage, in rect: CGRect, context: CGContext) {
        let box = page.getBoxRect(.cropBox)
        guard box.width > 0, box.height > 0 else { return }
        let rotation = ((Int(page.rotationAngle) % 360) + 360) % 360
        let rotatedSize = (rotation == 90 || rotation == 270)
            ? CGSize(width: box.height, height: box.width)
            : box.size
        let scale = min(rect.width / rotatedSize.width, rect.height / rotatedSize.height)

        pdfLock.lock()
        defer { pdfLock.unlock() }

        context.saveGState()
        // تحويل من إحداثيات UIKit (y للأسفل) إلى إحداثيات PDF (y للأعلى)
        context.translateBy(x: 0, y: rect.height)
        context.scaleBy(x: 1, y: -1)
        context.translateBy(x: rect.midX, y: rect.height - rect.midY)
        context.scaleBy(x: scale, y: scale)
        context.rotate(by: -CGFloat(rotation) * .pi / 180)
        context.translateBy(x: -box.midX, y: -box.midY)
        context.clip(to: box)
        context.interpolationQuality = .high
        context.setRenderingIntent(.defaultIntent)
        context.drawPDFPage(page)
        context.restoreGState()
    }

    private static func drawPattern(_ config: PageBackgroundConfig, lineHex: String, marginHex: String?,
                                    in rect: CGRect, context: CGContext) {
        let spacing = max(8, config.spacing)
        let lineColor = UIColor(hex: lineHex)
        let width = rect.width
        let height = rect.height

        context.setStrokeColor(lineColor.cgColor)
        context.setFillColor(lineColor.cgColor)
        context.setLineCap(.butt)

        switch config.kind {
        case .blank:
            break

        case .lined:
            let top = spacing * 3
            context.setLineWidth(0.9)
            var y = top
            while y < height - spacing * 0.5 {
                context.move(to: CGPoint(x: 0, y: y))
                context.addLine(to: CGPoint(x: width, y: y))
                y += spacing
            }
            context.strokePath()
            if let marginHex {
                context.setStrokeColor(UIColor(hex: marginHex).withAlphaComponent(0.8).cgColor)
                context.setLineWidth(1.4)
                let marginX = spacing * 2.2
                context.move(to: CGPoint(x: marginX, y: 0))
                context.addLine(to: CGPoint(x: marginX, y: height))
                context.strokePath()
            }

        case .grid:
            context.setLineWidth(0.6)
            var x = spacing
            while x < width {
                context.move(to: CGPoint(x: x, y: 0))
                context.addLine(to: CGPoint(x: x, y: height))
                x += spacing
            }
            var y = spacing
            while y < height {
                context.move(to: CGPoint(x: 0, y: y))
                context.addLine(to: CGPoint(x: width, y: y))
                y += spacing
            }
            context.strokePath()

        case .dots:
            let radius: CGFloat = 1.4
            var y = spacing
            while y < height {
                var x = spacing
                while x < width {
                    context.addEllipse(in: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
                    x += spacing
                }
                y += spacing
            }
            context.fillPath()

        case .cornell:
            let header = spacing * 3
            let summaryTop = height - spacing * 6
            let cueX = width * 0.3
            context.setLineWidth(0.8)
            var y = header + spacing
            while y < height - spacing * 0.5 {
                if abs(y - summaryTop) > 1 {
                    let startX: CGFloat = y < summaryTop ? cueX : 0
                    context.move(to: CGPoint(x: startX, y: y))
                    context.addLine(to: CGPoint(x: width, y: y))
                }
                y += spacing
            }
            context.strokePath()
            context.setLineWidth(2)
            context.move(to: CGPoint(x: 0, y: header))
            context.addLine(to: CGPoint(x: width, y: header))
            context.move(to: CGPoint(x: cueX, y: header))
            context.addLine(to: CGPoint(x: cueX, y: summaryTop))
            context.move(to: CGPoint(x: 0, y: summaryTop))
            context.addLine(to: CGPoint(x: width, y: summaryTop))
            context.strokePath()

        case .music:
            let gap = max(6, spacing / 4)
            let staffHeight = gap * 4
            let staffSpacing = staffHeight + gap * 6
            let side: CGFloat = 40
            context.setLineWidth(0.9)
            var top = spacing * 2
            while top + staffHeight < height - side {
                for line in 0..<5 {
                    let y = top + CGFloat(line) * gap
                    context.move(to: CGPoint(x: side, y: y))
                    context.addLine(to: CGPoint(x: width - side, y: y))
                }
                top += staffSpacing
            }
            context.strokePath()
        }
    }
}

// MARK: - النصوص والصور على الصفحة

enum ItemRenderer {
    /// لون النص كما يظهر (في الوضع الداكن يتحول الأسود إلى أبيض مثل الحبر).
    static func displayColor(_ hex: String, dark: Bool) -> UIColor {
        let color = UIColor(hex: hex)
        return dark ? PKInkingTool.convertColor(color, from: .light, to: .dark) : color
    }

    static func draw(_ items: [PageItem], images: [UUID: UIImage], dark: Bool, in context: CGContext) {
        UIGraphicsPushContext(context)
        defer { UIGraphicsPopContext() }
        for item in items {
            switch item.kind {
            case .text:
                let style = NSMutableParagraphStyle()
                style.alignment = .natural
                style.baseWritingDirection = .natural
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: item.font,
                    .foregroundColor: displayColor(item.colorHex, dark: dark),
                    .paragraphStyle: style
                ]
                (item.text as NSString).draw(with: item.frame.insetBy(dx: 0, dy: 2),
                                             options: [.usesLineFragmentOrigin, .usesFontLeading],
                                             attributes: attributes,
                                             context: nil)
            case .image:
                if let id = item.attachmentID, let image = images[id] {
                    image.draw(in: item.frame)
                }
            }
        }
    }
}

// MARK: - لقطة صفحة للتصدير والصور المصغّرة (آمنة للاستخدام في الخلفية)

struct PageSnapshot {
    let size: CGSize
    let background: PageBackgroundConfig
    let pdfPage: CGPDFPage?
    let drawingData: Data?
    var items: [PageItem] = []
    var images: [UUID: UIImage] = [:]

    /// صورة الحبر فقط بخلفية شفافة. في الوضع الداكن يحوّل PencilKit ألوان الحبر تلقائياً.
    func drawingImage(scale: CGFloat) -> UIImage? {
        guard let drawingData, !drawingData.isEmpty,
              let drawing = try? PKDrawing(data: drawingData),
              !drawing.strokes.isEmpty else { return nil }
        var image: UIImage?
        let style: UIUserInterfaceStyle = background.darkContent ? .dark : .light
        UITraitCollection(userInterfaceStyle: style).performAsCurrent {
            image = drawing.image(from: CGRect(origin: .zero, size: size), scale: scale)
        }
        return image
    }
}

enum PageRenderer {
    /// صورة كاملة للصفحة (خلفية + PDF + نصوص وصور + حبر).
    static func image(for snapshot: PageSnapshot, targetWidth: CGFloat? = nil, scale: CGFloat = 2) -> UIImage {
        let factor = targetWidth.map { $0 / snapshot.size.width } ?? 1
        let outputSize = CGSize(width: (snapshot.size.width * factor).rounded(),
                                height: (snapshot.size.height * factor).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        let ink = snapshot.drawingImage(scale: factor * scale)
        return UIGraphicsImageRenderer(size: outputSize, format: format).image { context in
            let cg = context.cgContext
            cg.saveGState()
            cg.scaleBy(x: factor, y: factor)
            PageBackgroundRenderer.draw(snapshot.background, pdfPage: snapshot.pdfPage, in: cg)
            ItemRenderer.draw(snapshot.items, images: snapshot.images, dark: snapshot.background.darkContent, in: cg)
            cg.restoreGState()
            ink?.draw(in: CGRect(origin: .zero, size: outputSize))
        }
    }

    private static let previewCache = NSCache<NSString, UIImage>()

    /// معاينة صغيرة لنوع خلفية (تُستخدم في لوحة اختيار الخلفيات) مع ذاكرة مؤقتة.
    static func backgroundPreview(_ config: PageBackgroundConfig, width: CGFloat) -> UIImage {
        let key = "\(config.kind.rawValue)|\(config.backgroundHex)|\(config.lineHex)|\(Int(config.spacing))|\(Int(width))|\(config.darkContent)" as NSString
        if let cached = previewCache.object(forKey: key) { return cached }
        let snapshot = PageSnapshot(size: config.pageSize, background: config, pdfPage: nil, drawingData: nil)
        let rendered = image(for: snapshot, targetWidth: width, scale: 2)
        previewCache.setObject(rendered, forKey: key)
        return rendered
    }

    /// يكتب المذكرة كاملة في ملف PDF — الخلفيات وصفحات PDF الأصلية تبقى متجهة (Vector).
    static func writePDF(_ snapshots: [PageSnapshot], title: String, to url: URL) throws {
        let firstSize = snapshots.first?.size ?? DataStore.standardPageSize
        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [
            kCGPDFContextTitle as String: title,
            kCGPDFContextCreator as String: "Sabboura"
        ]
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: firstSize), format: format)
        try renderer.writePDF(to: url) { context in
            for snapshot in snapshots {
                autoreleasepool {
                    let rect = CGRect(origin: .zero, size: snapshot.size)
                    context.beginPage(withBounds: rect, pageInfo: [:])
                    PageBackgroundRenderer.draw(snapshot.background, pdfPage: snapshot.pdfPage, in: context.cgContext)
                    ItemRenderer.draw(snapshot.items, images: snapshot.images, dark: false, in: context.cgContext)
                    snapshot.drawingImage(scale: 2.5)?.draw(in: rect)
                }
            }
        }
    }
}

// MARK: - الصور المصغّرة للمذكرات (بحسب الوضع الحالي فاتح/داكن)

final class ThumbnailCache {
    static let shared = ThumbnailCache()

    private let cache = NSCache<NSString, UIImage>()
    private let queue = DispatchQueue(label: "sabboura.thumbnails", qos: .userInitiated, attributes: .concurrent)

    private func key(_ note: CDNote, dark: Bool, theme: AppTheme) -> NSString {
        let stamp = note.updatedAt?.timeIntervalSince1970 ?? 0
        return "\(note.objectID.uriRepresentation().absoluteString)|\(stamp)|\(dark)|\(theme.rawValue)" as NSString
    }

    func cached(for note: CDNote, dark: Bool, theme: AppTheme) -> UIImage? {
        guard note.isAlive else { return nil }
        return cache.object(forKey: key(note, dark: dark, theme: theme))
    }

    /// يرسم الصفحة الأولى في الخلفية ثم يعيدها على الخيط الرئيسي.
    func render(_ note: CDNote, dark: Bool, theme: AppTheme, width: CGFloat = 360,
                completion: @escaping (UIImage?) -> Void) {
        guard note.isAlive, let page = note.sortedPages.first, let context = note.managedObjectContext else {
            completion(nil)
            return
        }
        let cacheKey = key(note, dark: dark, theme: theme)
        if let cached = cache.object(forKey: cacheKey) {
            completion(cached)
            return
        }
        let snapshot = PageSnapshot.make(for: page, context: context, dark: dark, theme: theme)
        queue.async {
            let image = PageRenderer.image(for: snapshot, targetWidth: width, scale: 2)
            self.cache.setObject(image, forKey: cacheKey)
            DispatchQueue.main.async { completion(image) }
        }
    }
}

extension PageSnapshot {
    /// يجمع كل ما يلزم لرسم صفحة من قاعدة البيانات (على الخيط الرئيسي).
    static func make(for page: CDPage, context: NSManagedObjectContext, dark: Bool, theme: AppTheme,
                     drawingData overrideData: Data? = nil) -> PageSnapshot {
        let items = page.items
        var images: [UUID: UIImage] = [:]
        for item in items where item.kind == .image {
            if let id = item.attachmentID, let image = ImageStore.shared.image(for: id, context: context) {
                images[id] = image
            }
        }
        return PageSnapshot(size: page.pageSize,
                            background: page.backgroundConfig.themed(dark: dark, theme: theme),
                            pdfPage: PDFSourceCache.shared.page(for: page, context: context),
                            drawingData: overrideData ?? (page.isAlive ? page.drawingData : nil),
                            items: items,
                            images: images)
    }
}

/// ذاكرة مؤقتة لصور العناصر (محفوظة كمرفقات).
final class ImageStore {
    static let shared = ImageStore()
    private let cache = NSCache<NSUUID, UIImage>()

    func image(for id: UUID, context: NSManagedObjectContext) -> UIImage? {
        if let cached = cache.object(forKey: id as NSUUID) { return cached }
        guard let attachment = DataStore.attachment(with: id, in: context),
              let data = attachment.data,
              let image = UIImage(data: data) else { return nil }
        cache.setObject(image, forKey: id as NSUUID)
        return image
    }

    func store(_ image: UIImage, for id: UUID) {
        cache.setObject(image, forKey: id as NSUUID)
    }
}

// MARK: - ملفات مؤقتة للمشاركة والمعاينة

enum TemporaryFiles {
    static func directory(_ name: String) -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: name, directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func safeFileName(_ name: String, fallback: String = "مذكرة") -> String {
        let invalid = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let cleaned = name.components(separatedBy: invalid).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? fallback : cleaned
    }

    /// يكتب المرفق في ملف مؤقت ليُعرض بـ QuickLook أو يُشارك.
    static func url(for attachment: CDAttachment) -> URL? {
        guard attachment.isAlive, let data = attachment.data, let id = attachment.uuid else { return nil }
        let folder = directory("Attachments/\(id.uuidString)")
        let url = folder.appending(path: safeFileName(attachment.displayName, fallback: "file"))
        do {
            if !FileManager.default.fileExists(atPath: url.path) {
                try data.write(to: url, options: .atomic)
            }
            return url
        } catch {
            return nil
        }
    }
}
