import CoreData
import NaturalLanguage
import PDFKit
import PencilKit
import UIKit
import Vision

// MARK: - قراءة محتوى المذكرة

/// صفحة بعد قراءتها: نصها وصورتها (للمحرّك الذي يقرأ الصور).
struct ReadPage {
    let number: Int
    var text: String
    /// صورة JPEG للصفحة كاملة (خط اليد والصور) — تُرسل لـ Claude فقط
    var imageJPEG: Data?
}

/// كل ما في المذكرة بعد قراءته.
struct NoteContent {
    let title: String
    var pages: [ReadPage]

    var fullText: String {
        pages.map(\.text).filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    /// لغة المذكرة الغالبة (ar، en …).
    var language: String {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(fullText.prefix(6000)))
        return recognizer.dominantLanguage?.rawValue ?? "ar"
    }
}

/// يقرأ المذكرة: النص المكتوب بلوحة المفاتيح، نص صفحات PDF، والتعرّف على النص في
/// خط اليد والصور وصفحات PDF الممسوحة ضوئياً (Vision على الجهاز).
enum NoteContentReader {
    enum Mode {
        /// للتوليد على الجهاز: كل شيء يتحول لنص (مع التعرّف على خط اليد والصور)
        case textOnly
        /// لـ Claude: النص + صور الصفحات التي فيها خط يد أو صور أو صفحات ممسوحة
        case textAndImages
    }

    /// معلومات صفحة تُجمع على الخيط الرئيسي (Core Data) ثم تُعالج في الخلفية.
    private struct PageSource {
        let number: Int
        let snapshot: PageSnapshot
        let typedText: String
        let pdfSourceID: UUID?
        let pdfPageIndex: Int
        let hasImages: Bool
    }

    static let maxRecognizedPages = 60
    static let maxImagesForClaude = 40

    /// يُستدعى على الخيط الرئيسي ويرجع عملية تُنفَّذ في الخلفية.
    @MainActor
    static func prepare(_ note: CDNote, context: NSManagedObjectContext) -> ((Mode) -> NoteContent)? {
        guard note.isAlive else { return nil }
        let title = note.displayTitle
        var sources: [PageSource] = []
        var pdfData: [UUID: Data] = [:]
        for (offset, page) in note.sortedPages.enumerated() where page.isAlive {
            let snapshot = PageSnapshot.make(for: page, context: context, dark: false, theme: .classic)
            let items = page.items
            let typed = items.filter { $0.kind == .text }
                .sorted { ($0.y, -$0.x) < ($1.y, -$1.x) }
                .map(\.text)
                .joined(separator: "\n")
            if let id = page.pdfSourceID, pdfData[id] == nil,
               let data = DataStore.attachment(with: id, in: context)?.data {
                pdfData[id] = data
            }
            sources.append(PageSource(number: offset + 1,
                                      snapshot: snapshot,
                                      typedText: typed,
                                      pdfSourceID: page.pdfSourceID,
                                      pdfPageIndex: Int(page.pdfPageIndex),
                                      hasImages: items.contains { $0.kind == .image }))
        }
        let captured = sources
        let pdfs = pdfData
        return { mode in read(title: title, sources: captured, pdfData: pdfs, mode: mode) }
    }

    private static func read(title: String, sources: [PageSource], pdfData: [UUID: Data], mode: Mode) -> NoteContent {
        var documents: [UUID: PDFDocument] = [:]
        for (id, data) in pdfData {
            documents[id] = PDFDocument(data: data)
        }
        var recognized = 0
        var images = 0
        var pages: [ReadPage] = []

        for source in sources {
            var parts: [String] = []
            if !source.typedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                parts.append(source.typedText)
            }
            var pdfText = ""
            if let id = source.pdfSourceID, let page = documents[id]?.page(at: source.pdfPageIndex) {
                pdfText = clean(page.string ?? "")
                // بعض ملفات PDF العربية تخرج حروفها مشوّهة عند القراءة؛ نقرأ صورة الصفحة بدلاً منها
                if looksGarbled(pdfText) { pdfText = "" }
                if !pdfText.isEmpty { parts.append(pdfText) }
            }
            let hasInk = hasStrokes(source.snapshot.drawingData)
            let isScanned = source.pdfSourceID != nil && pdfText.count < 25
            let needsLook = hasInk || source.hasImages || isScanned

            var imageJPEG: Data?
            switch mode {
            case .textOnly:
                if needsLook && recognized < maxRecognizedPages {
                    recognized += 1
                    // خط اليد وحده على ورقة بيضاء، حتى لا يتكرر نص PDF
                    if hasInk, let ink = inkImage(source.snapshot) {
                        let text = TextRecognizer.recognize(ink)
                        if !text.isEmpty { parts.append(text) }
                    }
                    for item in source.snapshot.items where item.kind == .image {
                        if let id = item.attachmentID, let image = source.snapshot.images[id]?.cgImage {
                            let text = TextRecognizer.recognize(image)
                            if !text.isEmpty { parts.append(text) }
                        }
                    }
                    if isScanned, let page = backgroundImage(source.snapshot) {
                        let text = TextRecognizer.recognize(page)
                        if !text.isEmpty { parts.append(text) }
                    }
                }
            case .textAndImages:
                if needsLook && images < maxImagesForClaude {
                    images += 1
                    let image = PageRenderer.image(for: source.snapshot, targetWidth: 1150, scale: 1)
                    imageJPEG = image.jpegData(compressionQuality: 0.72)
                }
            }
            pages.append(ReadPage(number: source.number,
                                  text: parts.joined(separator: "\n"),
                                  imageJPEG: imageJPEG))
        }
        return NoteContent(title: title, pages: pages)
    }

    // MARK: مساعدات

    private static func hasStrokes(_ data: Data?) -> Bool {
        guard let data, !data.isEmpty, let drawing = try? PKDrawing(data: data) else { return false }
        return !drawing.strokes.isEmpty
    }

    /// صورة الحبر فقط على خلفية بيضاء، مقصوصة على المنطقة المكتوبة (أسرع بكثير في التعرّف).
    private static func inkImage(_ snapshot: PageSnapshot) -> CGImage? {
        guard let data = snapshot.drawingData, let drawing = try? PKDrawing(data: data),
              !drawing.strokes.isEmpty else { return nil }
        let page = CGRect(origin: .zero, size: snapshot.size)
        let area = drawing.bounds.insetBy(dx: -16, dy: -16).intersection(page)
        guard !area.isNull, area.width > 8, area.height > 8 else { return nil }
        let scale = min(2, 2200 / max(area.width, area.height))
        var ink: UIImage?
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            ink = drawing.image(from: area, scale: scale)
        }
        guard let ink else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let size = CGSize(width: (area.width * scale).rounded(), height: (area.height * scale).rounded())
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            ink.draw(in: CGRect(origin: .zero, size: size))
        }
        return image.cgImage
    }

    /// صفحة PDF وحدها (بدون الحبر) — للصفحات الممسوحة ضوئياً.
    private static func backgroundImage(_ snapshot: PageSnapshot) -> CGImage? {
        let bare = PageSnapshot(size: snapshot.size, background: snapshot.background, pdfPage: snapshot.pdfPage,
                                drawingData: nil, items: [], images: [:])
        return PageRenderer.image(for: bare, targetWidth: 1500, scale: 1).cgImage
    }

    /// نص عربي مستخرج بشكل خاطئ: كلمات عربية تختلط فيها حروف لاتينية أو أرقام أو رموز.
    static func looksGarbled(_ text: String) -> Bool {
        var arabicWords = 0
        var mixed = 0
        for word in text.split(whereSeparator: { $0 == " " || $0 == "\n" }) {
            let scalars = Array(word.unicodeScalars)
            guard scalars.contains(where: { (0x0600...0x06FF).contains($0.value) }) else { continue }
            arabicWords += 1
            let inner = scalars.count > 2 ? Array(scalars[1..<(scalars.count - 1)]) : scalars
            let foreign = scalars.contains { (0x41...0x5A).contains($0.value) || (0x61...0x7A).contains($0.value) || (0x30...0x39).contains($0.value) }
                || inner.contains { CharacterSet.punctuationCharacters.contains($0) || CharacterSet.symbols.contains($0) }
            if foreign { mixed += 1 }
        }
        return arabicWords >= 5 && Double(mixed) / Double(arabicWords) > 0.12
    }

    /// تنظيف نص PDF: أشكال الحروف العربية المتصلة تتحول لحروفها الأصلية، والمسافات تتوحد.
    static func clean(_ text: String) -> String {
        let normalized = text.precomposedStringWithCompatibilityMapping
        let lines = normalized.components(separatedBy: .newlines).map {
            $0.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
        }
        return lines.filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

// MARK: - التعرّف على النص في الصور (Vision)

enum TextRecognizer {
    /// يتعرّف على النص العربي والإنجليزي (المطبوع وخط اليد بقدر الإمكان).
    static func recognize(_ image: CGImage) -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        if let supported = try? request.supportedRecognitionLanguages() {
            let wanted = ["ar-SA", "ars-SA", "en-US"].filter { supported.contains($0) }
            if !wanted.isEmpty { request.recognitionLanguages = wanted }
        }
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return ""
        }
        let observations = (request.results ?? []).filter { ($0.topCandidates(1).first?.confidence ?? 0) > 0.3 }
        // من الأعلى للأسفل (إحداثيات Vision تبدأ من الأسفل)
        let sorted = observations.sorted { $0.boundingBox.midY > $1.boundingBox.midY }
        let lines = sorted.compactMap { $0.topCandidates(1).first?.string }
        return NoteContentReader.clean(lines.joined(separator: "\n"))
    }
}
