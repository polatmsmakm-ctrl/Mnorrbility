import UIKit

// MARK: - تحديد المحتوى المطبوع (صفحات PDF والمستندات الممسوحة والصور)
// هذا الملف يجهّز المنطقة المحددة باللاسو: يقصّها بدقة عالية ويحدد حدود المحتوى الفعلي فيها.
// الإحداثيات كلها بنقاط الصفحة (عرض الصفحة القياسي 820، الأصل أعلى اليسار ومحور y للأسفل).

/// صورة موضوعة على الصفحة (عنصر صورة) تُرسم مع المحتوى المطبوع عند القص.
struct PrintedImageOverlay {
    let image: CGImage
    let frame: CGRect
}

/// المنطقة التي حددها المستخدم باللاسو فوق محتوى مطبوع.
struct PrintedRegion {
    let pageID: UUID
    let pageSize: CGSize
    let pageOriginY: CGFloat
    let pdfPage: CGPDFPage?
    let pdfSourceID: UUID?
    let pdfPageIndex: Int
    /// بيانات ملف PDF (تُمرَّر فقط إذا لم يُفتح المستند بـ PDFKit بعد)
    let pdfData: Data?
    let overlays: [PrintedImageOverlay]
    /// مسار اللاسو بإحداثيات الصفحة
    let polygon: [CGPoint]
    /// المستطيل المقصوص بإحداثيات الصفحة (يُضيَّق على المحتوى الفعلي بعد التحليل)
    var rect: CGRect

    /// المستطيل نفسه بإحداثيات اللوحة (كل الصفحات مرصوصة).
    var canvasRect: CGRect { rect.offsetBy(dx: 0, dy: pageOriginY) }
}

// MARK: - هندسة مشتركة

enum PrintedGeometry {
    static func boundingRect(of points: [CGPoint]) -> CGRect {
        guard let first = points.first else { return .null }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for point in points {
            minX = min(minX, point.x); maxX = max(maxX, point.x)
            minY = min(minY, point.y); maxY = max(maxY, point.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    static func path(from points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard points.count > 1 else { return path }
        path.addLines(between: points)
        path.closeSubpath()
        return path
    }

    /// يحوّل من إحداثيات صفحة PDF الأصلية إلى إحداثيات الصفحة في التطبيق.
    /// نفس التحويل الذي يستخدمه رسم الخلفية حرفياً، فيتطابق القص والنص مع ما يظهر على الشاشة.
    static func pdfToPageTransform(_ page: CGPDFPage, pageSize: CGSize) -> CGAffineTransform? {
        let box = page.getBoxRect(.cropBox)
        guard box.width > 0, box.height > 0, pageSize.width > 0, pageSize.height > 0 else { return nil }
        let rotation = ((Int(page.rotationAngle) % 360) + 360) % 360
        let rotatedSize = (rotation == 90 || rotation == 270)
            ? CGSize(width: box.height, height: box.width)
            : box.size
        let rect = CGRect(origin: .zero, size: pageSize)
        let scale = min(rect.width / rotatedSize.width, rect.height / rotatedSize.height)
        var transform = CGAffineTransform.identity
        transform = transform.translatedBy(x: 0, y: rect.height)
        transform = transform.scaledBy(x: 1, y: -1)
        transform = transform.translatedBy(x: rect.midX, y: rect.height - rect.midY)
        transform = transform.scaledBy(x: scale, y: scale)
        transform = transform.rotated(by: -CGFloat(rotation) * .pi / 180)
        transform = transform.translatedBy(x: -box.midX, y: -box.midY)
        return transform
    }

    /// أكبر مستطيل بنفس نسبة الصورة داخل الإطار (مثل contentMode = scaleAspectFit).
    static func aspectFit(_ size: CGSize, in frame: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0, frame.width > 0, frame.height > 0 else { return frame }
        let scale = min(frame.width / size.width, frame.height / size.height)
        let fitted = CGSize(width: size.width * scale, height: size.height * scale)
        return CGRect(x: frame.midX - fitted.width / 2, y: frame.midY - fitted.height / 2,
                      width: fitted.width, height: fitted.height)
    }
}

// MARK: - القص بدقة عالية

enum PrintedRegionRenderer {
    /// يرسم المحتوى المطبوع للصفحة (PDF ثم الصور فوقه) بإحداثيات الصفحة.
    static func drawContent(of region: PrintedRegion, in context: CGContext) {
        let pageRect = CGRect(origin: .zero, size: region.pageSize)
        if let pdfPage = region.pdfPage {
            PageBackgroundRenderer.drawPDF(pdfPage, in: pageRect, context: context)
        }
        for overlay in region.overlays {
            let fitted = PrintedGeometry.aspectFit(CGSize(width: overlay.image.width, height: overlay.image.height),
                                                   in: overlay.frame)
            context.saveGState()
            context.clip(to: overlay.frame)
            context.translateBy(x: fitted.minX, y: fitted.maxY)
            context.scaleBy(x: 1, y: -1)
            context.interpolationQuality = .high
            context.draw(overlay.image, in: CGRect(origin: .zero, size: fitted.size))
            context.restoreGState()
        }
    }

    /// سياق رسم RGBA أبيض الخلفية، محوّل بحيث يُرسم المستطيل المطلوب بالمقياس المطلوب.
    static func makeContext(for region: PrintedRegion, rect: CGRect, scale: CGFloat) -> CGContext? {
        let pixelWidth = max(1, Int((rect.width * scale).rounded(.up)))
        let pixelHeight = max(1, Int((rect.height * scale).rounded(.up)))
        guard pixelWidth * pixelHeight <= 20_000_000,
              let context = CGContext(data: nil, width: pixelWidth, height: pixelHeight,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.setShouldAntialias(true)
        // نفس نظام إحداثيات الصفحة: الأصل أعلى اليسار ومحور y للأسفل
        context.translateBy(x: 0, y: CGFloat(pixelHeight))
        context.scaleBy(x: scale, y: -scale)
        context.translateBy(x: -rect.minX, y: -rect.minY)
        context.setFillColor(UIColor.white.cgColor)
        context.fill(rect)
        drawContent(of: region, in: context)
        return context
    }

    /// صورة عالية الدقة للمنطقة المحددة بألوانها ونسبها الأصلية (بغض النظر عن الوضع الداكن).
    /// حجم الصورة بالنقاط = حجم المنطقة على الصفحة، فتبقى حادة عند التكبير.
    static func captureImage(of region: PrintedRegion) -> UIImage? {
        let rect = region.rect
        guard rect.width >= 1, rect.height >= 1 else { return nil }
        let longest = max(rect.width, rect.height)
        var scale = min(4, 4096 / longest, (16_000_000 / max(rect.width * rect.height, 1)).squareRoot())
        scale = max(scale, 0.5)
        guard let context = makeContext(for: region, rect: rect, scale: scale),
              let image = context.makeImage() else { return nil }
        return UIImage(cgImage: image, scale: scale, orientation: .up)
    }

    /// يفحص المنطقة بدقة منخفضة: إن كانت فارغة يعيد nil، وإلا يضيّق المستطيل على المحتوى
    /// الموجود داخل مسار اللاسو فعلاً (حتى يكون القص دقيقاً ولا يحمل فراغاً زائداً).
    static func refined(_ region: PrintedRegion) -> PrintedRegion? {
        let pageRect = CGRect(origin: .zero, size: region.pageSize)
        let area = region.rect.intersection(pageRect)
        guard !area.isNull, area.width >= 4, area.height >= 4 else { return nil }
        let scale = max(0.25, min(2, 700 / max(area.width, area.height)))
        guard let color = makeContext(for: region, rect: area, scale: scale),
              let pixels = color.data else { return nil }
        let width = color.width
        let height = color.height
        let colorRow = color.bytesPerRow

        // قناع مسار اللاسو بنفس أبعاد الصورة
        guard let mask = CGContext(data: nil, width: width, height: height,
                                   bitsPerComponent: 8, bytesPerRow: 0,
                                   space: CGColorSpaceCreateDeviceGray(),
                                   bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let maskPixels = mask.data else { return nil }
        mask.translateBy(x: 0, y: CGFloat(height))
        mask.scaleBy(x: scale, y: -scale)
        mask.translateBy(x: -area.minX, y: -area.minY)
        mask.setFillColor(gray: 1, alpha: 1)
        mask.addPath(PrintedGeometry.path(from: region.polygon))
        mask.fillPath()
        let maskRow = mask.bytesPerRow

        let colorBytes = pixels.bindMemory(to: UInt8.self, capacity: colorRow * height)
        let maskBytes = maskPixels.bindMemory(to: UInt8.self, capacity: maskRow * height)

        // لون الورق = الوسيط داخل التحديد (يدعم الصفحات الممسوحة ذات الخلفية الرمادية)
        var histogram = [Int](repeating: 0, count: 256)
        var maskCount = 0
        for y in 0..<height {
            for x in 0..<width where maskBytes[y * maskRow + x] > 127 {
                let offset = y * colorRow + x * 4
                let lum = (Int(colorBytes[offset]) * 299 + Int(colorBytes[offset + 1]) * 587
                           + Int(colorBytes[offset + 2]) * 114) / 1000
                histogram[min(255, max(0, lum))] += 1
                maskCount += 1
            }
        }
        guard maskCount > 0 else { return nil }
        var median = 255
        var running = 0
        for value in 0..<256 {
            running += histogram[value]
            if running * 2 >= maskCount {
                median = value
                break
            }
        }
        let threshold = median - max(40, median * 18 / 100)
        guard threshold > 0 else { return nil }

        var inkCount = 0
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width where maskBytes[y * maskRow + x] > 127 {
                let offset = y * colorRow + x * 4
                let lum = (Int(colorBytes[offset]) * 299 + Int(colorBytes[offset + 1]) * 587
                           + Int(colorBytes[offset + 2]) * 114) / 1000
                if lum < threshold {
                    inkCount += 1
                    minX = min(minX, x); maxX = max(maxX, x)
                    minY = min(minY, y); maxY = max(maxY, y)
                }
            }
        }
        guard inkCount >= max(3, maskCount / 1250), maxX >= minX, maxY >= minY else { return nil }

        let padding: CGFloat = 4
        var content = CGRect(x: area.minX + CGFloat(minX) / scale,
                             y: area.minY + CGFloat(minY) / scale,
                             width: CGFloat(maxX - minX + 1) / scale,
                             height: CGFloat(maxY - minY + 1) / scale)
        content = content.insetBy(dx: -padding, dy: -padding).integral.intersection(pageRect)
        guard !content.isNull, content.width >= 2, content.height >= 2 else { return nil }
        var result = region
        result.rect = content
        return result
    }
}
