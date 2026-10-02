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

/// من أين جاءت البطاقات والأسئلة.
enum StudyEngineKind: String, Codable {
    /// على الجهاز، بدون إنترنت
    case onDevice
    /// Claude عبر مفتاح المستخدم
    case claude

    var title: String {
        switch self {
        case .onDevice: return "على الجهاز"
        case .claude: return "Claude"
        }
    }
}

/// مواد المراجعة لمذكرة واحدة (تُحفظ مع المذكرة).
struct StudySet: Codable, Equatable {
    var engine: StudyEngineKind
    /// لغة المذكرة الغالبة: ar أو en …
    var language: String
    var generatedAt: Date
    /// بصمة محتوى المذكرة وقت التوليد (لمعرفة إن تغيّرت بعده)
    var signature: String
    var summary: [String]
    var cards: [StudyCard]
    var questions: [StudyQuestion]
    var lastScore: Int? = nil
    var bestScore: Int? = nil

    var isEmpty: Bool { cards.isEmpty && questions.isEmpty }
    var isArabic: Bool { language.hasPrefix("ar") }
}
