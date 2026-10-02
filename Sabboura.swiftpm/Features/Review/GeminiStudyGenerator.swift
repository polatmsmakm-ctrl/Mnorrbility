import Foundation

// MARK: - التوليد عبر Gemini (Google)

/// يرسل نص المذكرة وصور صفحاتها إلى Gemini بمفتاح المستخدم (مفتاح مجاني من Google AI Studio)،
/// ويستقبل الملخص والبطاقات والأسئلة بنفس صيغة JSON.
///
/// أسماء نماذج Gemini تتغير مع كل إصدار، فالتطبيق يسأل Google عن النماذج المتاحة للمفتاح
/// ويختار أحدث نموذج Flash مستقر بنفسه، ولو خلص الحد المجاني لنموذج جرّب Flash-Lite.
enum GeminiStudyGenerator {
    enum Failure: LocalizedError {
        case badKey
        case quota
        case busy
        case region
        case blocked
        case invalidResponse
        case modelMissing
        case schemaRejected
        case network(String)

        var errorDescription: String? {
            switch self {
            case .badKey: return "مفتاح Gemini غير صحيح"
            case .quota: return "وصلت للحد المجاني لـ Gemini مؤقتاً، جرّب بعد شوي"
            case .busy: return "خدمة Gemini مشغولة الحين، جرّب بعد شوي"
            case .region: return "Gemini غير متاح في منطقتك حالياً"
            case .blocked: return "Gemini رفض محتوى المذكرة"
            case .invalidResponse: return "رد Gemini ما كان بالشكل المتوقع"
            case .modelMissing: return "نموذج Gemini غير متاح لهذا المفتاح"
            case .schemaRejected: return "Gemini ما قبل صيغة الطلب"
            case .network(let message): return "تعذّر الاتصال بـ Gemini: \(message)"
            }
        }
    }

    private static let base = "https://generativelanguage.googleapis.com/v1beta"
    /// صفحة إنشاء المفتاح المجاني
    static let keyPage = URL(string: "https://aistudio.google.com/apikey")!
    /// أسماء بديلة من Google تشير دائماً لأحدث Flash (إن تعذّر جلب قائمة النماذج)
    static let fallbackModel = "gemini-flash-latest"
    static let fallbackLiteModel = "gemini-flash-lite-latest"

    private static let modelsCacheKey = "sabboura.review.geminiModels"
    private static let modelsDateKey = "sabboura.review.geminiModelsDate"

    // MARK: التوليد

    static func generate(from content: NoteContent, signature: String,
                         key: String, lite: Bool) async throws -> StudySet {
        let parts = parts(for: content)
        var model = await resolveModel(key: key, lite: lite, refresh: false)
        var useSchema = true
        var refreshed = false
        var triedLite = lite
        for _ in 0..<4 {
            do {
                let output = try await request(parts: parts, model: model, key: key, schema: useSchema)
                return StudyPrompt.makeSet(output, engine: .gemini, signature: signature,
                                           fallbackLanguage: content.language)
            } catch Failure.schemaRejected where useSchema {
                // نموذج لا يقبل صيغة الرد المحددة: نطلب JSON حسب التعليمات فقط
                useSchema = false
            } catch Failure.modelMissing where !refreshed {
                refreshed = true
                let next = await resolveModel(key: key, lite: lite, refresh: true)
                model = next == model ? (lite ? fallbackLiteModel : fallbackModel) : next
            } catch Failure.quota where !triedLite {
                // لكل نموذج حدّه المجاني الخاص، فنجرّب Flash-Lite
                triedLite = true
                model = await resolveModel(key: key, lite: true, refresh: false)
            }
        }
        throw Failure.invalidResponse
    }

    /// يتأكد من المفتاح ويرجع اسم النموذج الذي سيُستخدم.
    static func verify(key: String, lite: Bool) async throws -> String {
        let ids = try await listModels(key: key)
        cache(ids)
        let model = pick(from: ids, lite: lite) ?? (lite ? fallbackLiteModel : fallbackModel)
        let body: [String: Any] = ["contents": [["role": "user", "parts": [["text": "Reply with OK"]]]]]
        let (data, status) = try await post(body, model: model, key: key, timeout: 60)
        guard status == 200 else {
            let problem = failure(status: status, data: data)
            if case .modelMissing = problem, let other = pick(from: ids.filter { $0 != model }, lite: lite) {
                return other
            }
            throw problem
        }
        return model
    }

    // MARK: الطلب

    private static func parts(for content: NoteContent) -> [[String: Any]] {
        var parts: [[String: Any]] = [["text": "عنوان المذكرة: \(content.title)"]]
        var budget = 200_000
        for page in content.pages {
            if let text = StudyPrompt.pageText(page, budget: &budget) {
                parts.append(["text": text])
            }
            if let image = page.imageJPEG {
                parts.append(["text": StudyPrompt.imageLabel(page)])
                parts.append(["inlineData": ["mimeType": "image/jpeg", "data": image.base64EncodedString()]])
            }
        }
        parts.append(["text": StudyPrompt.instructions])
        return parts
    }

    private static func request(parts: [[String: Any]], model: String, key: String,
                                schema: Bool) async throws -> StudyPrompt.Output {
        var config: [String: Any] = ["responseMimeType": "application/json", "maxOutputTokens": 32768]
        if schema { config["responseSchema"] = StudyPrompt.openAPISchema }
        let body: [String: Any] = [
            "systemInstruction": ["parts": [["text": StudyPrompt.system]]],
            "contents": [["role": "user", "parts": parts]],
            "generationConfig": config
        ]
        let (data, status) = try await post(body, model: model, key: key, timeout: 240)
        guard status == 200 else { throw failure(status: status, data: data) }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure.invalidResponse
        }
        if let feedback = json["promptFeedback"] as? [String: Any], feedback["blockReason"] != nil {
            throw Failure.blocked
        }
        guard let candidate = (json["candidates"] as? [[String: Any]])?.first else {
            throw Failure.invalidResponse
        }
        let pieces = ((candidate["content"] as? [String: Any])?["parts"] as? [[String: Any]]) ?? []
        // نتجاهل أجزاء «التفكير» ونأخذ الرد نفسه
        let text = pieces.filter { ($0["thought"] as? Bool) != true }
            .compactMap { $0["text"] as? String }
            .joined()
        if let output = StudyPrompt.decode(text) { return output }
        if let reason = candidate["finishReason"] as? String,
           ["SAFETY", "PROHIBITED_CONTENT", "BLOCKLIST", "SPII", "RECITATION"].contains(reason) {
            throw Failure.blocked
        }
        throw Failure.invalidResponse
    }

    private static func post(_ body: [String: Any], model: String, key: String,
                             timeout: TimeInterval) async throws -> (Data, Int) {
        let name = model.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? model
        guard let url = URL(string: "\(base)/models/\(name):generateContent") else { throw Failure.modelMissing }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await send(request)
    }

    // MARK: اختيار النموذج

    /// أحدث نموذج Flash متاح للمفتاح (القائمة تُحفظ ٣ أيام).
    static func resolveModel(key: String, lite: Bool, refresh: Bool) async -> String {
        let defaults = UserDefaults.standard
        var ids = defaults.stringArray(forKey: modelsCacheKey) ?? []
        let date = defaults.object(forKey: modelsDateKey) as? Date ?? .distantPast
        if refresh || ids.isEmpty || Date().timeIntervalSince(date) > 3 * 86_400 {
            if let fresh = try? await listModels(key: key), !fresh.isEmpty {
                ids = fresh
                cache(fresh)
            }
        }
        return pick(from: ids, lite: lite) ?? (lite ? fallbackLiteModel : fallbackModel)
    }

    private static func cache(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        UserDefaults.standard.set(ids, forKey: modelsCacheKey)
        UserDefaults.standard.set(Date(), forKey: modelsDateKey)
    }

    static func listModels(key: String) async throws -> [String] {
        guard let url = URL(string: "\(base)/models?pageSize=1000") else { return [] }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        let (data, status) = try await send(request)
        guard status == 200 else { throw failure(status: status, data: data) }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [[String: Any]] else { throw Failure.invalidResponse }
        return models.compactMap { model -> String? in
            guard let name = model["name"] as? String,
                  let methods = model["supportedGenerationMethods"] as? [String],
                  methods.contains("generateContent") else { return nil }
            return name.hasPrefix("models/") ? String(name.dropFirst("models/".count)) : name
        }
    }

    /// يختار أحدث نسخة Flash (أو Flash-Lite) للنصوص، ويفضّل المستقرة على التجريبية.
    static func pick(from ids: [String], lite: Bool) -> String? {
        let excluded = ["tts", "image", "live", "audio", "transcribe", "embedding", "omni", "robotics",
                        "translate", "computer", "native", "exp", "thinking", "latest", "learnlm", "nano", "8b"]
        var best: (stable: Bool, version: Double, id: String)?
        for id in ids {
            let lower = id.lowercased()
            guard lower.hasPrefix("gemini-"), lower.contains("flash"), lower.contains("lite") == lite,
                  !excluded.contains(where: { lower.contains($0) }) else { continue }
            let pieces = lower.split(separator: "-")
            guard pieces.count >= 3, let version = Double(pieces[1]) else { continue }
            let candidate = (stable: !lower.contains("preview"), version: version, id: id)
            guard let current = best else {
                best = candidate
                continue
            }
            if candidate.stable != current.stable {
                if candidate.stable { best = candidate }
            } else if candidate.version != current.version {
                if candidate.version > current.version { best = candidate }
            } else if candidate.id.count < current.id.count {
                best = candidate
            }
        }
        return best?.id
    }

    // MARK: الأخطاء

    private static func failure(status: Int, data: Data) -> Failure {
        let message = errorMessage(data) ?? ""
        let lower = message.lowercased()
        let raw = (String(data: data, encoding: .utf8) ?? "").lowercased()
        let regionProblem = lower.contains("location") || lower.contains("region") || lower.contains("country")
        switch status {
        case 400:
            if raw.contains("api_key_invalid") || lower.contains("api key") { return .badKey }
            if regionProblem { return .region }
            if lower.contains("schema") || lower.contains("unknown name") || lower.contains("invalid json payload") {
                return .schemaRejected
            }
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
