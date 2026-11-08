import UIKit
import UniformTypeIdentifiers

/// نتيجة التقاط منطقة مطبوعة: صورة عالية الدقة + النص (إن وُجد).
struct PrintedCapture {
    let image: UIImage
    let pngData: Data
    let text: PrintedText?

    /// الطريقة الأنسب تلقائياً: نص قابل للتعديل إذا كان موثوقاً وليس معادلة أو رسماً، وإلا صورة.
    var prefersText: Bool {
        guard let text, !text.isEmpty, text.isReliable, !text.isMathematical else { return false }
        let size = image.size
        if size.width * size.height > 150 * 150 && text.coverage < 0.2 { return false }
        return true
    }

    /// النص المرافق للعنصر (للإتاحة) بدون فراغات زائدة.
    var plainText: String? {
        guard let value = text?.text.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}

/// كل العمليات الثقيلة (القص والتعرّف الضوئي وترميز الصور) على طابور خلفي واحد، والنتائج تعود للخيط الرئيسي.
final class PrintedContentService {
    static let shared = PrintedContentService()

    enum TextMode {
        /// بدون نص
        case none
        /// طبقة نص الـPDF فقط (سريع)
        case embeddedOnly
        /// طبقة النص، ثم التعرّف الضوئي إن لم توجد
        case full
    }

    private let queue = DispatchQueue(label: "com.sabboura.printed-content", qos: .userInitiated)

    /// يتأكد أن المنطقة فيها محتوى ويضيّقها عليه.
    func analyze(_ region: PrintedRegion, completion: @escaping (PrintedRegion?) -> Void) {
        queue.async {
            let refined = PrintedRegionRenderer.refined(region)
            DispatchQueue.main.async { completion(refined) }
        }
    }

    /// يجهّز المقتطف للإرسال إلى Gemini: صورة واضحة بحجم معقول (JPEG) ونص طبقة الـPDF إن وُجد.
    func prepareAIRequest(_ region: PrintedRegion, task: PrintedAITask,
                          completion: @escaping (PrintedAIRequest?) -> Void) {
        queue.async {
            let rect = region.rect
            let longest = max(rect.width, rect.height, 1)
            let scale = max(1, min(3, 1600 / longest))
            guard let context = PrintedRegionRenderer.makeContext(for: region, rect: rect, scale: scale),
                  let cgImage = context.makeImage() else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            let image = UIImage(cgImage: cgImage, scale: scale, orientation: .up)
            guard let jpeg = image.jpegData(compressionQuality: 0.9) else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            let text = PrintedTextExtractor.shared.extract(from: region, image: nil, allowOCR: false)
            let request = PrintedAIRequest(task: task,
                                           image: image,
                                           imageJPEG: jpeg,
                                           text: text.map(\.text),
                                           pageID: region.pageID,
                                           anchor: rect)
            DispatchQueue.main.async { completion(request) }
        }
    }

    func capture(_ region: PrintedRegion, text mode: TextMode, completion: @escaping (PrintedCapture?) -> Void) {
        queue.async {
            guard let image = PrintedRegionRenderer.captureImage(of: region),
                  let png = image.pngData() else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            let text: PrintedText?
            switch mode {
            case .none:
                text = nil
            case .embeddedOnly:
                text = PrintedTextExtractor.shared.extract(from: region, image: nil, allowOCR: false)
            case .full:
                text = PrintedTextExtractor.shared.extract(from: region, image: image.cgImage, allowOCR: true)
            }
            let result = PrintedCapture(image: image, pngData: png, text: text)
            DispatchQueue.main.async { completion(result) }
        }
    }
}

// MARK: - الحافظة

/// نسخ المحتوى المطبوع للحافظة العامة، مع علامة خاصة تحفظ حجمه الأصلي عند اللصق داخل التطبيق.
enum PrintedClipboard {
    static let markerType = "com.sabboura.printed-content"

    private struct Marker: Codable {
        var width: Double
        var height: Double
        var text: String?
    }

    struct Content {
        let image: UIImage
        let pngData: Data
        let size: CGSize
        let text: String?
    }

    static func copyText(_ text: String) {
        UIPasteboard.general.string = text
    }

    static func copyImage(_ capture: PrintedCapture) {
        var item: [String: Any] = [UTType.png.identifier: capture.pngData]
        let marker = Marker(width: Double(capture.image.size.width),
                            height: Double(capture.image.size.height),
                            text: capture.plainText)
        if let data = try? JSONEncoder().encode(marker) {
            item[markerType] = data
        }
        UIPasteboard.general.setItems([item])
    }

    /// المحتوى المطبوع المنسوخ من التطبيق (إن وُجد في الحافظة).
    static func printedContent() -> Content? {
        let board = UIPasteboard.general
        guard board.contains(pasteboardTypes: [markerType]),
              let markerData = board.data(forPasteboardType: markerType),
              let marker = try? JSONDecoder().decode(Marker.self, from: markerData),
              marker.width > 0, marker.height > 0,
              let png = board.data(forPasteboardType: UTType.png.identifier),
              let image = UIImage(data: png) else { return nil }
        return Content(image: image, pngData: png,
                       size: CGSize(width: marker.width, height: marker.height),
                       text: marker.text)
    }
}
