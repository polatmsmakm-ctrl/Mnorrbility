import Foundation

// MARK: - بطاقات الحفظ والكويز لكل مذكرة

/// بطاقة حفظ: وجه (سؤال أو مصطلح) وظهر (الإجابة).
struct StudyCard: Codable, Identifiable, Equatable {
    var id = UUID()
    var front: String
    var back: String
    /// هل عرفها الطالب في آخر مراجعة
    var known: Bool? = nil
}

/// سؤال اختيار من متعدد (أو صح/خطأ).
struct StudyQuestion: Codable, Identifiable, Equatable {
    var id = UUID()
    var prompt: String
    var options: [String]
    var answerIndex: Int
    var explanation: String? = nil
}

/// مصطلح وتعريفه (في الملخص).
struct StudyTerm: Codable, Identifiable, Equatable {
    var id = UUID()
    var term: String
    var definition: String
}

/// من أين جاءت البطاقات والأسئلة.
enum StudyEngineKind: String, Codable {
    /// على الجهاز، بدون إنترنت
    case onDevice
    /// Gemini من Google عبر مفتاح المستخدم (مجاني)
    case gemini
    /// Claude عبر مفتاح المستخدم
    case claude

    var title: String {
        switch self {
        case .onDevice: return "على الجهاز"
        case .gemini: return "Gemini"
        case .claude: return "Claude"
        }
    }

    var isOnline: Bool { self != .onDevice }
}

/// مواد المراجعة لمذكرة واحدة (تُحفظ مع المذكرة).
struct StudySet: Codable, Equatable {
    var engine: StudyEngineKind
    /// لغة المذكرة الغالبة: ar أو en …
    var language: String
    var generatedAt: Date
    /// بصمة محتوى المذكرة وقت التوليد (لمعرفة إن تغيّرت بعده)
    var signature: String
    /// أهم النقاط بجمل كاملة
    var summary: [String]
    var cards: [StudyCard]
    var questions: [StudyQuestion]
    var lastScore: Int? = nil
    var bestScore: Int? = nil
    /// المصطلحات وتعريفاتها
    var keyTerms: [StudyTerm]? = nil
    /// أرقام وتواريخ مهمة
    var facts: [String]? = nil
    /// إصدار طريقة التوليد (لإعادة التوليد تلقائياً بعد التحسينات)
    var version: Int? = nil

    static let currentVersion = 2

    var isEmpty: Bool { cards.isEmpty && questions.isEmpty }
    var isArabic: Bool { language.hasPrefix("ar") }
}
