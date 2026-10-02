import Foundation
import Security

// MARK: - إعدادات المراجعة الذكية

enum ReviewSettings {
    private static let autoKey = "sabboura.review.auto"
    private static let modelKey = "sabboura.review.model"

    /// توليد البطاقات والكويز تلقائياً عند تغيّر المذكرة أو استيراد ملف
    static var autoGenerate: Bool {
        get { UserDefaults.standard.object(forKey: autoKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: autoKey) }
    }

    static let fastModel = "claude-haiku-4-5-20251001"
    static let preciseModel = "claude-sonnet-5"

    static var claudeModel: String {
        get { UserDefaults.standard.string(forKey: modelKey) ?? fastModel }
        set { UserDefaults.standard.set(newValue, forKey: modelKey) }
    }

    static var hasClaudeKey: Bool { !(KeychainStore.read(KeychainStore.claudeKey) ?? "").isEmpty }
}

/// حفظ مفتاح Claude في سلسلة مفاتيح الجهاز (مشفّر، لا يخرج من الجهاز إلا لـ Anthropic).
enum KeychainStore {
    static let claudeKey = "claude-api-key"
    private static let service = "com.sabboura.notes"

    static func read(_ account: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ value: String?, for account: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service,
                                   kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        guard let value, !value.isEmpty, let data = value.data(using: .utf8) else { return }
        var attributes = base
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(attributes as CFDictionary, nil)
    }
}

// MARK: - التوليد عبر Claude

/// يرسل نص المذكرة وصور صفحاتها (خط اليد والصور والصفحات الممسوحة) إلى Claude،
/// ويستقبل بطاقات وأسئلة بصيغة JSON محددة.
enum ClaudeStudyGenerator {
    enum Failure: LocalizedError {
        case noKey
        case badKey
        case busy
        case network(String)
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .noKey: return "ما فيه مفتاح Claude"
            case .badKey: return "مفتاح Claude غير صحيح أو انتهى رصيده"
            case .busy: return "خدمة Claude مشغولة الحين، جرّب بعد شوي"
            case .network(let message): return "تعذّر الاتصال بـ Claude: \(message)"
            case .invalidResponse: return "رد Claude ما كان بالشكل المتوقع"
            }
        }
    }

    static func generate(from content: NoteContent, signature: String,
                         key: String, model: String) async throws -> StudySet {
        var blocks: [[String: Any]] = []
        blocks.append(["type": "text", "text": "عنوان المذكرة: \(content.title)"])
        var characters = 0
        for page in content.pages {
            let text = page.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty && characters < 150_000 {
                let clipped = String(text.prefix(150_000 - characters))
                characters += clipped.count
                blocks.append(["type": "text", "text": "— صفحة \(page.number) —\n\(clipped)"])
            }
            if let image = page.imageJPEG {
                blocks.append(["type": "text", "text": "— صورة صفحة \(page.number) (فيها خط يد أو صور) —"])
                blocks.append(["type": "image",
                               "source": ["type": "base64", "media_type": "image/jpeg",
                                          "data": image.base64EncodedString()]])
            }
        }
        blocks.append(["type": "text", "text": instructions])

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 8000,
            "system": "You are a careful study assistant. You turn a student's notes into accurate study materials, using only what is in the notes.",
            "messages": [["role": "user", "content": blocks]],
            "output_config": ["format": ["type": "json_schema", "schema": schema]]
        ]

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, status) = try await send(request)
        switch status {
        case 200: break
        case 401, 403: throw Failure.badKey
        case 400:
            if let message = errorMessage(data), message.lowercased().contains("credit") { throw Failure.badKey }
            throw Failure.network(errorMessage(data) ?? "400")
        case 429, 500...599: throw Failure.busy
        default: throw Failure.network(errorMessage(data) ?? "\(status)")
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]],
              let text = content.first(where: { $0["type"] as? String == "text" })?["text"] as? String,
              let payload = text.data(using: .utf8),
              let result = try? JSONDecoder().decode(Output.self, from: payload) else {
            throw Failure.invalidResponse
        }

        let cards = result.flashcards
            .filter { !$0.front.isEmpty && !$0.back.isEmpty }
            .map { StudyCard(front: $0.front, back: $0.back) }
        let questions = result.questions.compactMap { question -> StudyQuestion? in
            let options = question.options.filter { !$0.isEmpty }
            guard options.count >= 2, options.indices.contains(question.answer_index) else { return nil }
            return StudyQuestion(prompt: question.question, options: options,
                                 answerIndex: question.answer_index, explanation: question.explanation)
        }
        return StudySet(engine: .claude,
                        language: result.language,
                        generatedAt: Date(),
                        signature: signature,
                        summary: result.summary,
                        cards: cards,
                        questions: questions)
    }

    /// طلب صغير جداً للتأكد من أن المفتاح يعمل.
    static func verify(key: String, model: String) async throws {
        let body: [String: Any] = ["model": model, "max_tokens": 5,
                                   "messages": [["role": "user", "content": "Reply with OK"]]]
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, status) = try await send(request)
        switch status {
        case 200: return
        case 401, 403: throw Failure.badKey
        case 429, 500...599: throw Failure.busy
        default: throw Failure.network(errorMessage(data) ?? "خطأ غير معروف")
        }
    }

    private static func send(_ request: URLRequest) async throws -> (Data, Int) {
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        } catch {
            throw Failure.network(error.localizedDescription)
        }
    }

    private static func errorMessage(_ data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = json["error"] as? [String: Any] else { return nil }
        return error["message"] as? String
    }

    private static let instructions = """
    Create study materials from the notes above (typed text, PDF text and the page images, which may contain handwriting).
    Focus only on the most important points. Write everything in the same language the notes are mostly written in (if the notes are mostly Arabic, write in clear Modern Standard Arabic).
    - language: the ISO code of that language, e.g. "ar" or "en".
    - summary: 3 to 8 short sentences with the key points.
    - flashcards: 8 to 20 cards. "front" is a short question or term, "back" is a concise answer (at most about 25 words).
    - questions: 6 to 12 multiple-choice questions. Each has exactly 4 options, exactly one correct option (answer_index is its 0-based position), plausible wrong options, and a one-sentence explanation.
    Use only information that appears in the notes; never invent facts. Skip handwriting you cannot read confidently. If the notes are very short, return fewer items.
    """

    private static let schema: [String: Any] = [
        "type": "object",
        "properties": [
            "language": ["type": "string"],
            "summary": ["type": "array", "items": ["type": "string"]],
            "flashcards": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": ["front": ["type": "string"], "back": ["type": "string"]],
                    "required": ["front", "back"],
                    "additionalProperties": false
                ]
            ],
            "questions": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": [
                        "question": ["type": "string"],
                        "options": ["type": "array", "items": ["type": "string"]],
                        "answer_index": ["type": "integer"],
                        "explanation": ["type": "string"]
                    ],
                    "required": ["question", "options", "answer_index", "explanation"],
                    "additionalProperties": false
                ]
            ]
        ],
        "required": ["language", "summary", "flashcards", "questions"],
        "additionalProperties": false
    ]

    private struct Output: Decodable {
        struct Card: Decodable { let front: String; let back: String }
        struct Question: Decodable {
            let question: String
            let options: [String]
            let answer_index: Int
            let explanation: String?
        }
        let language: String
        let summary: [String]
        let flashcards: [Card]
        let questions: [Question]
    }
}
