import PDFKit
import UIKit
import Vision

/// نص مستخرج من منطقة مطبوعة.
struct PrintedText {
    enum Source { case pdfTextLayer, ocr }

    var text: String
    var source: Source
    /// النص موثوق (طبقة نص سليمة، أو ثقة تعرّف كافية)
    var isReliable: Bool
    /// يبدو معادلة أو تعبيراً علمياً (يُفضّل نسخه كصورة حتى لا تضيع دقته)
    var isMathematical: Bool
    /// نسبة مساحة الأسطر من مساحة التحديد (قليلة = رسم بياني أو شكل فيه نص قليل)
    var coverage: CGFloat

    var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

/// يستخرج النص المطبوع: من طبقة نص الـPDF أولاً (PDFKit)، وبالتعرّف الضوئي (Vision) عند الحاجة فقط.
/// كل الدوال هنا تُستدعى من طابور خلفي واحد (PrintedContentService).
final class PrintedTextExtractor {
    static let shared = PrintedTextExtractor()

    private let lock = NSLock()
    private var documents: [UUID: PDFDocument] = [:]

    /// هل المستند مفتوح مسبقاً (حتى لا نقرأ بياناته من قاعدة البيانات مرة ثانية).
    func hasDocument(for id: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return documents[id] != nil
    }

    private func document(for region: PrintedRegion) -> PDFDocument? {
        guard let id = region.pdfSourceID else { return nil }
        lock.lock()
        let cached = documents[id]
        lock.unlock()
        if let cached { return cached }
        guard let data = region.pdfData, let document = PDFDocument(data: data) else { return nil }
        if document.isLocked {
            _ = document.unlock(withPassword: "")
        }
        guard !document.isLocked else { return nil }
        lock.lock()
        documents[id] = document
        lock.unlock()
        return document
    }

    /// النص داخل المنطقة. `image` هي الصورة المقصوصة (للتعرّف الضوئي إذا لم توجد طبقة نص).
    func extract(from region: PrintedRegion, image: CGImage?, allowOCR: Bool) -> PrintedText? {
        if let embedded = embeddedText(in: region), !embedded.isEmpty {
            return embedded
        }
        guard allowOCR, let image else { return nil }
        return recognizedText(in: image, region: region)
    }

    // MARK: طبقة النص الأصلية (PDFKit)

    private func embeddedText(in region: PrintedRegion) -> PrintedText? {
        guard let cgPage = region.pdfPage,
              let document = document(for: region),
              let page = document.page(at: region.pdfPageIndex),
              let toPage = PrintedGeometry.pdfToPageTransform(cgPage, pageSize: region.pageSize) else { return nil }
        let pdfRect = region.rect.applying(toPage.inverted())
        guard let selection = page.selection(for: pdfRect) else { return nil }

        let lasso = PrintedGeometry.path(from: region.polygon)
        let regionArea = max(region.rect.width * region.rect.height, 1)

        struct Line {
            var text: String
            var bounds: CGRect
            var fonts: Set<String>
            var sizeRatio: CGFloat
        }
        var lines: [Line] = []
        for lineSelection in selection.selectionsByLine() {
            guard let raw = lineSelection.string else { continue }
            let text = raw.trimmingCharacters(in: .newlines)
            guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            let bounds = lineSelection.bounds(for: page).applying(toPage)
            var fonts = Set<String>()
            var minSize = CGFloat.greatestFiniteMagnitude
            var maxSize: CGFloat = 0
            if let attributed = lineSelection.attributedString, attributed.length > 0 {
                attributed.enumerateAttribute(.font, in: NSRange(location: 0, length: attributed.length)) { value, _, _ in
                    guard let font = value as? UIFont else { return }
                    fonts.insert(font.fontName)
                    minSize = min(minSize, font.pointSize)
                    maxSize = max(maxSize, font.pointSize)
                }
            }
            let ratio = (maxSize > 0 && minSize > 0 && minSize < .greatestFiniteMagnitude) ? maxSize / minSize : 1
            lines.append(Line(text: text, bounds: bounds, fonts: fonts, sizeRatio: ratio))
        }
        guard !lines.isEmpty else { return nil }

        // الأسطر التي يقع منتصفها داخل مسار اللاسو فعلاً (وإن لم يقع أي سطر، نأخذ كل ما في المستطيل)
        let inside = lines.filter { lasso.contains(CGPoint(x: $0.bounds.midX, y: $0.bounds.midY)) }
        let chosen = inside.isEmpty ? lines : inside

        let text = Self.normalized(chosen.map(\.text).joined(separator: "\n"))
        let fonts = chosen.reduce(into: Set<String>()) { $0.formUnion($1.fonts) }
        let mixedSizes = chosen.contains { $0.sizeRatio > 1.3 }
        let covered = chosen.reduce(CGFloat(0)) { total, line in
            let overlap = line.bounds.intersection(region.rect)
            return overlap.isNull ? total : total + overlap.width * overlap.height
        }
        return PrintedText(text: text,
                           source: .pdfTextLayer,
                           isReliable: Self.looksReadable(text),
                           isMathematical: mixedSizes || PrintedMath.looksMathematical(text, fontNames: fonts),
                           coverage: min(1, covered / regionArea))
    }

    // MARK: التعرّف الضوئي (Vision)

    private static let arabicOCRSupported: Bool = {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        let languages = (try? request.supportedRecognitionLanguages()) ?? []
        return languages.contains { $0.hasPrefix("ar") }
    }()

    private func recognizedText(in image: CGImage, region: PrintedRegion) -> PrintedText? {
        let latin = runOCR(on: image, languages: ["en-US", "fr-FR"], region: region)
            ?? runOCR(on: image, languages: ["en-US"], region: region)
        guard Self.arabicOCRSupported else { return latin }
        let arabic = runOCR(on: image, languages: ["ar-SA", "en-US"], region: region)
            ?? runOCR(on: image, languages: ["ar-SA"], region: region)
        if let arabic, PrintedMath.arabicRatio(arabic.text) >= 0.3 {
            return arabic
        }
        return latin ?? arabic
    }

    private func runOCR(on image: CGImage, languages: [String], region: PrintedRegion) -> PrintedText? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = languages
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        guard let observations = request.results, !observations.isEmpty else { return nil }

        struct Piece {
            var text: String
            var confidence: Float
            var box: CGRect
        }
        let lasso = PrintedGeometry.path(from: region.polygon)
        let rect = region.rect
        var pieces: [Piece] = []
        for observation in observations {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let box = observation.boundingBox
            // مركز السطر بإحداثيات الصفحة (Vision: الأصل أسفل اليسار وقيم من 0 إلى 1)
            let center = CGPoint(x: rect.minX + box.midX * rect.width,
                                 y: rect.minY + (1 - box.midY) * rect.height)
            guard lasso.contains(center) else { continue }
            let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            pieces.append(Piece(text: text, confidence: candidate.confidence, box: box))
        }
        guard !pieces.isEmpty else { return nil }

        // تجميع القطع في أسطر من الأعلى للأسفل
        var lines: [[Piece]] = []
        for piece in pieces.sorted(by: { $0.box.midY > $1.box.midY }) {
            if let reference = lines.last?.first,
               abs(reference.box.midY - piece.box.midY) < min(reference.box.height, piece.box.height) * 0.5 {
                lines[lines.count - 1].append(piece)
            } else {
                lines.append([piece])
            }
        }
        let lineTexts: [String] = lines.map { line in
            let rightToLeft = PrintedMath.arabicRatio(line.map(\.text).joined()) > 0.5
            let ordered = line.sorted { rightToLeft ? $0.box.minX > $1.box.minX : $0.box.minX < $1.box.minX }
            return ordered.map(\.text).joined(separator: " ")
        }
        let text = Self.normalized(lineTexts.joined(separator: "\n"))
        let confidence = pieces.reduce(Float(0)) { $0 + $1.confidence } / Float(pieces.count)
        let coverage = pieces.reduce(CGFloat(0)) { $0 + $1.box.width * $1.box.height }
        return PrintedText(text: text,
                           source: .ocr,
                           isReliable: confidence >= 0.5 && Self.looksReadable(text),
                           isMathematical: PrintedMath.looksMathematical(text, fontNames: []),
                           coverage: min(1, coverage))
    }

    // MARK: تنظيف النص

    /// يحوّل أشكال الحروف العربية المعروضة (Presentation Forms) لحروفها الأصلية، ويترك باقي الرموز كما هي
    /// (حتى لا تتحول الأسس مثل ² إلى أرقام عادية).
    private static func normalized(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0xFB50...0xFDFF, 0xFE70...0xFEFF:
                result += String(scalar).precomposedStringWithCompatibilityMapping
            default:
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }

    private static func looksReadable(_ text: String) -> Bool {
        var visible = 0
        var broken = 0
        var meaningful = 0
        for scalar in text.unicodeScalars where !CharacterSet.whitespacesAndNewlines.contains(scalar) {
            visible += 1
            if scalar.value == 0xFFFD || CharacterSet.controlCharacters.contains(scalar) {
                broken += 1
            } else if CharacterSet.alphanumerics.contains(scalar) {
                meaningful += 1
            }
        }
        guard visible > 0, meaningful > 0 else { return false }
        return Double(broken) / Double(visible) < 0.02
    }
}

// MARK: - كشف المعادلات والرموز العلمية

enum PrintedMath {
    /// خطوط المعادلات الشائعة (LaTeX و Word و MathType)
    private static let mathFontHints = ["math", "cmmi", "cmsy", "cmex", "msbm", "msam", "stix", "symbol",
                                        "mtextra", "mt extra", "euclid", "esint", "rsfs", "eufm", "eusm"]

    static func looksMathematical(_ text: String, fontNames: Set<String>) -> Bool {
        if fontNames.contains(where: { name in
            let lower = name.lowercased()
            return mathFontHints.contains { lower.contains($0) }
        }) {
            return true
        }

        var strong = 0
        var weak = 0
        var visible = 0
        for scalar in text.unicodeScalars where !CharacterSet.whitespacesAndNewlines.contains(scalar) {
            visible += 1
            switch scalar.value {
            case 0x2200...0x22FF, // عوامل رياضية (∫ ∑ √ ≤ ≠ ∞ …)
                 0x2A00...0x2AFF, // عوامل إضافية
                 0x27C0...0x27EF, 0x2980...0x29FF, // رموز رياضية متنوعة
                 0x1D400...0x1D7FF, // حروف رياضية
                 0x2070...0x209F, // أسس وأدلة سفلية
                 0x00B2, 0x00B3, 0x00B9, // ² ³ ¹
                 0x00D7, 0x00F7, // × ÷
                 0x2032...0x2037, // ′ ″
                 0x2308...0x230B: // ⌈ ⌉ ⌊ ⌋
                strong += 1
            case 0x0391...0x03A9, 0x03B1...0x03C9, 0x03D1, 0x03D5, 0x03F5, // حروف يونانية
                 0x2190...0x21FF, // أسهم (المعادلات الكيميائية)
                 0x3D, 0x5E, 0x2B, 0x3C, 0x3E, 0x7C, 0x5F: // = ^ + < > | _
                weak += 1
            default:
                break
            }
        }
        if strong > 0 { return true }
        guard visible > 0 else { return false }
        if text.contains("=") && visible <= 60 { return true }
        return Double(weak) / Double(visible) > 0.12
    }

    static func arabicRatio(_ text: String) -> Double {
        var letters = 0
        var arabic = 0
        for scalar in text.unicodeScalars where CharacterSet.letters.contains(scalar) {
            letters += 1
            switch scalar.value {
            case 0x0600...0x06FF, 0x0750...0x077F, 0x08A0...0x08FF, 0xFB50...0xFDFF, 0xFE70...0xFEFF:
                arabic += 1
            default:
                break
            }
        }
        return letters == 0 ? 0 : Double(arabic) / Double(letters)
    }
}
