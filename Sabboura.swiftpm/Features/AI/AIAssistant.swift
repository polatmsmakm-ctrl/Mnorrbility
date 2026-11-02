import Foundation

// MARK: - مساعد الذكاء الاصطناعي العام

/// طلب نصي (مع صور اختيارية) يُرسل لنفس المحرّك الذي اختاره المستخدم في المراجعة الذكية
/// (Gemini المجاني أو Claude) بمفتاحه المحفوظ في سلسلة المفاتيح.
/// يُستخدم في: حل المسائل المكتوبة بخط اليد، و«اسأل مذكرتك».
enum AIAssistant {
    struct Turn: Equatable {
        enum Role: Equatable { case user, assistant }
        let role: Role
        let text: String
    }

    enum Failure: LocalizedError {
        case noProvider
        case badKey(String)
        case busy(String)
        case quota
        case blocked
        case empty
        case network(String)

        var errorDescription: String? {
            switch self {
            case .noProvider:
                return "هذه الميزة تحتاج مفتاح Gemini المجاني أو مفتاح Claude. أضفه من الإعدادات ← المراجعة الذكية."
            case .badKey(let name): return "مفتاح \(name) غير صحيح أو انتهى رصيده"
            case .busy(let name): return "خدمة \(name) مشغولة الحين، جرّب بعد شوي"
            case .quota: return "وصلت للحد المجاني لـ Gemini مؤقتاً، جرّب بعد شوي"
            case .blocked: return "المحرّك رفض الطلب"
            case .empty: return "ما وصل رد من المحرّك"
            case .network(let message): return "تعذّر الاتصال: \(message)"
            }
        }
    }

    /// هل عند المستخدم محرّك متصل (مفتاح Gemini أو Claude)؟
    static var isAvailable: Bool { ReviewSettings.activeProvider != .onDevice }

    static var providerName: String {
        switch ReviewSettings.activeProvider {
        case .gemini: return "Gemini"
        case .claude: return "Claude"
        case .onDevice: return "على الجهاز"
        }
    }

    /// يرسل المحادثة ويرجع نص الرد. الصور (JPEG) تُرفق مع أول رسالة من المستخدم.
    static func ask(system: String, turns: [Turn], images: [Data] = [], maxTokens: Int = 4096) async throws -> String {
        switch ReviewSettings.activeProvider {
        case .claude:
            guard let key = KeychainStore.read(KeychainStore.claudeKey), !key.isEmpty else { throw Failure.noProvider }
            return try await askClaude(system: system, turns: turns, images: images, maxTokens: maxTokens, key: key)
        case .gemini:
            guard let key = KeychainStore.read(KeychainStore.geminiKey), !key.isEmpty else { throw Failure.noProvider }
            return try await askGemini(system: system, turns: turns, images: images, maxTokens: maxTokens, key: key)
        case .onDevice:
            throw Failure.noProvider
        }
    }

    // MARK: Claude

    private static func askClaude(system: String, turns: [Turn], images: [Data],
                                  maxTokens: Int, key: String) async throws -> String {
        var messages: [[String: Any]] = []
        var attached = false
        for turn in turns {
            var blocks: [[String: Any]] = []
            if turn.role == .user && !attached {
                attached = true
                for image in images {
                    blocks.append(["type": "image",
                                   "source": ["type": "base64", "media_type": "image/jpeg",
                                              "data": image.base64EncodedString()]])
                }
            }
            blocks.append(["type": "text", "text": turn.text])
            messages.append(["role": turn.role == .user ? "user" : "assistant", "content": blocks])
        }
        let body: [String: Any] = [
            "model": ReviewSettings.claudeModel,
            "max_tokens": maxTokens,
            "system": system,
            "messages": messages
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
        case 401, 403: throw Failure.badKey("Claude")
        case 429, 500...599: throw Failure.busy("Claude")
        default:
            let message = errorMessage(data) ?? "\(status)"
            if message.lowercased().contains("credit") { throw Failure.badKey("Claude") }
            throw Failure.network(message)
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure.empty }
        if json["stop_reason"] as? String == "refusal" { throw Failure.blocked }
        let parts = json["content"] as? [[String: Any]] ?? []
        let text = parts.filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw Failure.empty }
        return text
    }

    // MARK: Gemini

    private static func askGemini(system: String, turns: [Turn], images: [Data],
                                  maxTokens: Int, key: String) async throws -> String {
        var contents: [[String: Any]] = []
        var attached = false
        for turn in turns {
            var parts: [[String: Any]] = []
            if turn.role == .user && !attached {
                attached = true
                for image in images {
                    parts.append(["inlineData": ["mimeType": "image/jpeg", "data": image.base64EncodedString()]])
                }
            }
            parts.append(["text": turn.text])
            contents.append(["role": turn.role == .user ? "user" : "model", "parts": parts])
        }
        let body: [String: Any] = [
            "systemInstruction": ["parts": [["text": system]]],
            "contents": contents,
            "generationConfig": ["maxOutputTokens": max(maxTokens, 8192)]
        ]
        var model = await GeminiStudyGenerator.resolveModel(key: key, lite: ReviewSettings.geminiLite, refresh: false)
        var triedFallback = false
        while true {
            let (data, status) = try await postGemini(body, model: model, key: key)
            switch status {
            case 200:
                return try geminiText(data)
            case 404 where !triedFallback:
                triedFallback = true
                model = ReviewSettings.geminiLite ? GeminiStudyGenerator.fallbackLiteModel : GeminiStudyGenerator.fallbackModel
            case 400:
                let message = errorMessage(data) ?? "400"
                if message.lowercased().contains("api key") { throw Failure.badKey("Gemini") }
                throw Failure.network(message)
            case 401, 403: throw Failure.badKey("Gemini")
            case 429: throw Failure.quota
            case 500...599: throw Failure.busy("Gemini")
            default: throw Failure.network(errorMessage(data) ?? "\(status)")
            }
        }
    }

    private static func postGemini(_ body: [String: Any], model: String, key: String) async throws -> (Data, Int) {
        let name = model.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? model
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(name):generateContent") else {
            throw Failure.network("model")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await send(request)
    }

    private static func geminiText(_ data: Data) throws -> String {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure.empty }
        if let feedback = json["promptFeedback"] as? [String: Any], feedback["blockReason"] != nil {
            throw Failure.blocked
        }
        guard let candidate = (json["candidates"] as? [[String: Any]])?.first else { throw Failure.empty }
        let pieces = ((candidate["content"] as? [String: Any])?["parts"] as? [[String: Any]]) ?? []
        let text = pieces.filter { ($0["thought"] as? Bool) != true }
            .compactMap { $0["text"] as? String }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            if let reason = candidate["finishReason"] as? String, reason != "STOP" { throw Failure.blocked }
            throw Failure.empty
        }
        return text
    }

    // MARK: مشترك

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
}

/// نص فيه تنسيق Markdown بسيط (عريض، مائل، كود) مع الحفاظ على الأسطر.
func markdownText(_ text: String) -> AttributedString {
    let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
    return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
}
