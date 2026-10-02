import Foundation
import Security

// MARK: - إعدادات المراجعة الذكية

/// من يولّد البطاقات والأسئلة.
enum ReviewProvider: String, CaseIterable, Identifiable {
    case onDevice
    case gemini
    case claude

    var id: String { rawValue }
}

enum ReviewSettings {
    private static let autoKey = "sabboura.review.auto"
    private static let modelKey = "sabboura.review.model"
    private static let providerKey = "sabboura.review.provider"
    private static let geminiLiteKey = "sabboura.review.geminiLite"

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

    /// Gemini Flash-Lite بدل Flash (أسرع، وحدّه المجاني أعلى)
    static var geminiLite: Bool {
        get { UserDefaults.standard.bool(forKey: geminiLiteKey) }
        set { UserDefaults.standard.set(newValue, forKey: geminiLiteKey) }
    }

    static var hasClaudeKey: Bool { !(KeychainStore.read(KeychainStore.claudeKey) ?? "").isEmpty }
    static var hasGeminiKey: Bool { !(KeychainStore.read(KeychainStore.geminiKey) ?? "").isEmpty }

    /// المحرّك الذي اختاره المستخدم (الافتراضي Gemini المجاني، إلا لو عنده مفتاح Claude فقط).
    static var provider: ReviewProvider {
        get {
            if let raw = UserDefaults.standard.string(forKey: providerKey), let value = ReviewProvider(rawValue: raw) {
                return value
            }
            return hasClaudeKey && !hasGeminiKey ? .claude : .gemini
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: providerKey) }
    }

    /// المحرّك الفعلي: المختار إن كان مفتاحه محفوظاً، وإلا التوليد على الجهاز.
    static var activeProvider: ReviewProvider {
        switch provider {
        case .gemini: return hasGeminiKey ? .gemini : .onDevice
        case .claude: return hasClaudeKey ? .claude : .onDevice
        case .onDevice: return .onDevice
        }
    }

    static var usesOnline: Bool { activeProvider != .onDevice }
}

/// حفظ مفاتيح الخدمات في سلسلة مفاتيح الجهاز (مشفّرة، ولا تخرج إلا للخدمة نفسها).
enum KeychainStore {
    static let claudeKey = "claude-api-key"
    static let geminiKey = "gemini-api-key"
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
        var budget = 150_000
        for page in content.pages {
            if let text = StudyPrompt.pageText(page, budget: &budget) {
                blocks.append(["type": "text", "text": text])
            }
            if let image = page.imageJPEG {
                blocks.append(["type": "text", "text": StudyPrompt.imageLabel(page)])
                blocks.append(["type": "image",
                               "source": ["type": "base64", "media_type": "image/jpeg",
                                          "data": image.base64EncodedString()]])
            }
        }
        blocks.append(["type": "text", "text": StudyPrompt.instructions])

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 12000,
            "system": StudyPrompt.system,
            "messages": [["role": "user", "content": blocks]],
            "output_config": ["format": ["type": "json_schema", "schema": StudyPrompt.jsonSchema]]
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
              let parts = json["content"] as? [[String: Any]],
              let text = parts.first(where: { $0["type"] as? String == "text" })?["text"] as? String,
              let output = StudyPrompt.decode(text) else {
            throw Failure.invalidResponse
        }
        return StudyPrompt.makeSet(output, engine: .claude, signature: signature, fallbackLanguage: content.language)
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
}
