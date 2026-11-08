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
        case .explain: return "اشرح المعادلة"
        case .latex: return "نسخ LaTeX"
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
        case .translate: return "Gemini يترجم التحديد…"
        case .explain: return "Gemini يشرح المعادلة خطوة بخطوة…"
        case .latex: return "Gemini يحوّل المعادلة إلى LaTeX…"
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

/// يرسل المقتطف إلى Gemini بمفتاح المستخدم (نفس مفتاح «المراجعة الذكية» المحفوظ في سلسلة المفاتيح).
enum PrintedAIService {
    private static let base = "https://generativelanguage.googleapis.com/v1beta"

    static var savedKey: String? {
        let key = (KeychainStore.read(KeychainStore.geminiKey) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty ? nil : key
    }

    static func saveKey(_ key: String) {
        KeychainStore.write(key.trimmingCharacters(in: .whitespacesAndNewlines), for: KeychainStore.geminiKey)
    }

    static func run(_ request: PrintedAIRequest, key: String) async throws -> String {
        let lite = ReviewSettings.geminiLite
        var model = await GeminiStudyGenerator.resolveModel(key: key, lite: lite, refresh: false)
        var refreshed = false
        var triedLite = lite
        var lastError: Error = GeminiStudyGenerator.Failure.invalidResponse
        for _ in 0..<3 {
            do {
                let text = try await send(request, model: model, key: key)
                return cleaned(text, task: request.task)
            } catch GeminiStudyGenerator.Failure.modelMissing where !refreshed {
                refreshed = true
                lastError = GeminiStudyGenerator.Failure.modelMissing
                let next = await GeminiStudyGenerator.resolveModel(key: key, lite: lite, refresh: true)
                model = next == model
                    ? (lite ? GeminiStudyGenerator.fallbackLiteModel : GeminiStudyGenerator.fallbackModel)
                    : next
            } catch GeminiStudyGenerator.Failure.quota where !triedLite {
                // لكل نموذج حدّه المجاني الخاص، فنجرّب Flash-Lite
                triedLite = true
                lastError = GeminiStudyGenerator.Failure.quota
                model = await GeminiStudyGenerator.resolveModel(key: key, lite: true, refresh: false)
            }
        }
        throw lastError
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

    // MARK: الطلب

    private static func send(_ request: PrintedAIRequest, model: String, key: String) async throws -> String {
        var parts: [[String: Any]] = [
            ["inlineData": ["mimeType": "image/jpeg", "data": request.imageJPEG.base64EncodedString()]]
        ]
        if let text = request.text, !text.isEmpty {
            parts.append(["text": "Extracted text (for reference only):\n\(text.prefix(6000))"])
        }
        parts.append(["text": instructions(for: request.task)])
        let body: [String: Any] = [
            "contents": [["role": "user", "parts": parts]],
            "generationConfig": ["maxOutputTokens": 8192, "temperature": 0.2]
        ]

        let name = model.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? model
        guard let url = URL(string: "\(base)/models/\(name):generateContent") else {
            throw GeminiStudyGenerator.Failure.modelMissing
        }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 120
        urlRequest.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let status: Int
        do {
            let (responseData, response) = try await URLSession.shared.data(for: urlRequest)
            data = responseData
            status = (response as? HTTPURLResponse)?.statusCode ?? 0
        } catch {
            if (error as? URLError)?.code == .notConnectedToInternet {
                throw GeminiStudyGenerator.Failure.network("ما فيه اتصال بالإنترنت")
            }
            throw GeminiStudyGenerator.Failure.network(error.localizedDescription)
        }
        guard status == 200 else { throw failure(status: status, data: data) }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GeminiStudyGenerator.Failure.invalidResponse
        }
        if let feedback = json["promptFeedback"] as? [String: Any], feedback["blockReason"] != nil {
            throw GeminiStudyGenerator.Failure.blocked
        }
        guard let candidate = (json["candidates"] as? [[String: Any]])?.first else {
            throw GeminiStudyGenerator.Failure.invalidResponse
        }
        let pieces = ((candidate["content"] as? [String: Any])?["parts"] as? [[String: Any]]) ?? []
        // نتجاهل أجزاء «التفكير» ونأخذ الرد نفسه
        let text = pieces.filter { ($0["thought"] as? Bool) != true }
            .compactMap { $0["text"] as? String }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            if let reason = candidate["finishReason"] as? String,
               ["SAFETY", "PROHIBITED_CONTENT", "BLOCKLIST", "SPII", "RECITATION"].contains(reason) {
                throw GeminiStudyGenerator.Failure.blocked
            }
            throw GeminiStudyGenerator.Failure.invalidResponse
        }
        return text
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

    // MARK: الأخطاء

    private static func failure(status: Int, data: Data) -> GeminiStudyGenerator.Failure {
        var message = ""
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = json["error"] as? [String: Any] {
            message = error["message"] as? String ?? ""
        }
        let lower = message.lowercased()
        let raw = (String(data: data, encoding: .utf8) ?? "").lowercased()
        let regionProblem = lower.contains("location") || lower.contains("region") || lower.contains("country")
        switch status {
        case 400:
            if raw.contains("api_key_invalid") || lower.contains("api key") { return .badKey }
            if regionProblem { return .region }
            return .network(message.isEmpty ? "400" : message)
        case 401:
            return .badKey
        case 403:
            if regionProblem { return .region }
            if lower.contains("model") && !lower.contains("api key") { return .modelMissing }
            return .badKey
        case 404:
            return .modelMissing
        case 429:
            return .quota
        case 500...599:
            return .busy
        default:
            return .network(message.isEmpty ? "\(status)" : message)
        }
    }
}
