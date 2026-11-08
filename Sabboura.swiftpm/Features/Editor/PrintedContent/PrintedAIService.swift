import UIKit

/// ما يطلبه المستخدم من Gemini على مقتطف مطبوع.
enum PrintedAITask {
    case translate
    case explain
    case latex

    var title: String {
        switch self {
        case .translate: return "الترجمة"
        case .explain: return "شرح المعادلة"
        case .latex: return "LaTeX"
        }
    }

    /// اسم الخيار في قائمة التحديد
    var menuTitle: String {
        switch self {
        case .translate: return "ترجمة"
        case .explain: return "اشرح"
        case .latex: return "LaTeX"
        }
    }

    var symbol: String {
        switch self {
        case .translate: return "character.book.closed"
        case .explain: return "function"
        case .latex: return "chevron.left.forwardslash.chevron.right"
        }
    }

    var loadingText: String {
        switch self {
        case .translate: return "جارٍ ترجمة التحديد…"
        case .explain: return "جارٍ شرح المعادلة خطوة بخطوة…"
        case .latex: return "جارٍ تحويل المعادلة إلى LaTeX…"
        }
    }
}

/// طلب جاهز للإرسال: صورة المقتطف ونصه (إن وُجد) ومكانه في الصفحة لإدراج النتيجة تحته.
struct PrintedAIRequest: Identifiable {
    let id = UUID()
    let task: PrintedAITask
    let image: UIImage
    let imageJPEG: Data
    let text: String?
    let pageID: UUID
    /// مكان المقتطف على الصفحة (لإدراج النتيجة أسفله)
    let anchor: CGRect
}

/// يرسل المقتطف لنفس المحرّك الذي اختاره المستخدم في «المراجعة الذكية» (Gemini المجاني أو Claude).
enum PrintedAIService {
    /// هل عند المستخدم محرّك متصل؟
    static var isAvailable: Bool { AIAssistant.isAvailable }

    /// يحفظ مفتاح Gemini المجاني (نفس مفتاح المراجعة الذكية).
    static func saveGeminiKey(_ key: String) {
        KeychainStore.write(key.trimmingCharacters(in: .whitespacesAndNewlines), for: KeychainStore.geminiKey)
    }

    static func run(_ request: PrintedAIRequest) async throws -> String {
        var prompt = ""
        if let text = request.text, !text.isEmpty {
            prompt += "Extracted text (for reference only, may contain recognition errors):\n\(text.prefix(6000))\n\n"
        }
        prompt += instructions(for: request.task)
        let answer = try await AIAssistant.ask(system: system(for: request.task),
                                               turns: [.init(role: .user, text: prompt)],
                                               images: [request.imageJPEG],
                                               maxTokens: 8192)
        return cleaned(answer, task: request.task)
    }

    private static func system(for task: PrintedAITask) -> String {
        switch task {
        case .translate: return "You are a precise professional translator for students."
        case .explain: return "أنت معلم رياضيات وعلوم صبور يشرح للطلاب بالعربية بوضوح."
        case .latex: return "You convert printed mathematics into exact LaTeX source."
        }
    }

    // MARK: التعليمات

    private static func instructions(for task: PrintedAITask) -> String {
        switch task {
        case .translate:
            return """
            You are a precise translator. Translate the printed content shown in the image.
            The extracted text (if provided) may contain recognition errors; always trust the image.
            If the content is mainly Arabic, translate it into English. Otherwise translate it into Arabic.
            Keep numbers, symbols, formulas, chemical notation and line breaks as they are.
            Output only the translation, with no notes, titles or quotation marks.
            """
        case .explain:
            return """
            أنت معلم ممتاز. اشرح المعادلة أو التعبير العلمي الموجود في الصورة باللغة العربية خطوة بخطوة:
            ١) ما الذي تمثله المعادلة باختصار.
            ٢) معنى كل رمز ووحدته إن وُجدت.
            ٣) الفكرة أو طريقة الاشتقاق أو الحل بخطوات مرقمة.
            ٤) مثال رقمي قصير إن كان مناسباً.
            اكتب الرموز الرياضية بحروف يونيكود مقروءة (مثل x² و √ و ∫ و ≤ و π) ولا تستخدم LaTeX.
            استخدم عناوين قصيرة بخط عريض **هكذا** وقوائم مرقمة، ولا تستخدم علامة # للعناوين.
            إذا لم تكن في الصورة معادلة فاشرح المحتوى العلمي الموجود فيها بنفس الطريقة.
            """
        case .latex:
            return """
            Convert the mathematical content in the image into LaTeX.
            Output only the LaTeX source, without $ or \\[ \\] delimiters, without code fences and without explanation.
            For several lines or a system of equations use \\begin{aligned} ... \\end{aligned} with \\\\ between lines.
            Write ordinary words with \\text{...}. Reproduce every symbol, index and exponent exactly.
            """
        }
    }

    /// يزيل أسوار الكود وعلامات $ من LaTeX، ويحوّل عناوين # إلى خط عريض في الشرح.
    private static func cleaned(_ text: String, task: PrintedAITask) -> String {
        var lines = text.components(separatedBy: "\n")
        switch task {
        case .latex:
            lines = lines.filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }
            var result = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            for (open, close) in [("$$", "$$"), ("\\[", "\\]"), ("$", "$")]
            where result.hasPrefix(open) && result.hasSuffix(close) && result.count > open.count + close.count {
                result = String(result.dropFirst(open.count).dropLast(close.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
            return result
        case .explain:
            lines = lines.map { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("#") else { return line }
                let heading = trimmed.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
                return heading.isEmpty ? "" : "**\(heading)**"
            }
            return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        case .translate:
            return text
        }
    }
}
