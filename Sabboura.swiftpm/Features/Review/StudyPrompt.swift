import Foundation

// MARK: - التعليمات وصيغة الرد المشتركة بين Gemini و Claude

enum StudyPrompt {
    static let system = "You are a careful study assistant. You turn a student's notes into accurate, complete study materials, using only what is in the notes."

    static let instructions = """
    Create study materials from the notes above (typed text, PDF text and the page images, which may contain handwriting).
    Focus on the most important points and cover the whole document in order. Write everything in the same language the notes are mostly written in (if the notes are mostly Arabic, write in clear Modern Standard Arabic).
    Return one JSON object with exactly these keys:
    - "language": the ISO code of that language, e.g. "ar" or "en".
    - "summary": 5 to 10 key points, each one or two complete, self-contained sentences that a student can understand without the notes.
    - "key_terms": the important terms or concepts (up to 14), each as {"term": ..., "definition": ...} with its complete definition as given in the notes.
    - "facts": important numbers, dates, quantities or formulas from the notes as complete sentences (an empty array if there are none).
    - "flashcards": 8 to 20 cards, each as {"front": ..., "back": ...}. "front" is a clear question or term, "back" is the complete answer in one to three full sentences.
    - "questions": 6 to 12 multiple-choice questions, each as {"question": ..., "options": [...], "answer_index": ..., "explanation": ...}. Each has exactly 4 options, exactly one correct option (answer_index is its 0-based position), plausible wrong options, and a one-sentence explanation.
    Always write complete sentences: never cut a sentence short, never use "..." or "…", and never leave a thought unfinished.
    Use only information that appears in the notes; never invent facts. Skip handwriting you cannot read confidently. If the notes are very short, return fewer items.
    """

    static let keys = ["language", "summary", "key_terms", "facts", "flashcards", "questions"]

    /// JSON Schema (Claude).
    static let jsonSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "language": ["type": "string"],
            "summary": ["type": "array", "items": ["type": "string"]],
            "key_terms": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": ["term": ["type": "string"], "definition": ["type": "string"]],
                    "required": ["term", "definition"],
                    "additionalProperties": false
                ]
            ],
            "facts": ["type": "array", "items": ["type": "string"]],
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
        "required": keys,
        "additionalProperties": false
    ]

    /// نفس الصيغة بأسلوب OpenAPI الذي يفهمه Gemini (responseSchema).
    static let openAPISchema: [String: Any] = {
        func object(_ properties: [String: Any], _ order: [String]) -> [String: Any] {
            ["type": "OBJECT", "properties": properties, "required": order, "propertyOrdering": order]
        }
        let string: [String: Any] = ["type": "STRING"]
        let strings: [String: Any] = ["type": "ARRAY", "items": string]
        return object([
            "language": string,
            "summary": strings,
            "key_terms": ["type": "ARRAY", "items": object(["term": string, "definition": string], ["term", "definition"])],
            "facts": strings,
            "flashcards": ["type": "ARRAY", "items": object(["front": string, "back": string], ["front", "back"])],
            "questions": ["type": "ARRAY",
                          "items": object(["question": string, "options": strings,
                                           "answer_index": ["type": "INTEGER"], "explanation": string],
                                          ["question", "options", "answer_index", "explanation"])]
        ], keys)
    }()

    /// رد النموذج (كل الحقول اختيارية حتى لا يضيع الرد كله بسبب حقل ناقص).
    struct Output: Decodable {
        struct Card: Decodable { let front: String; let back: String }
        struct Term: Decodable { let term: String; let definition: String }
        struct Question: Decodable {
            let question: String
            let options: [String]
            let answer_index: Int
            let explanation: String?
        }
        let language: String?
        let summary: [String]?
        let key_terms: [Term]?
        let facts: [String]?
        let flashcards: [Card]?
        let questions: [Question]?
    }

    /// يقرأ JSON من نص الرد (حتى لو أحاطه النموذج بعلامات ```json).
    static func decode(_ text: String) -> Output? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end,
              let data = String(text[start...end]).data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Output.self, from: data)
    }

    static func makeSet(_ output: Output, engine: StudyEngineKind, signature: String, fallbackLanguage: String) -> StudySet {
        func clean(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
        let cards = (output.flashcards ?? [])
            .map { StudyCard(front: clean($0.front), back: clean($0.back)) }
            .filter { !$0.front.isEmpty && !$0.back.isEmpty }
        let questions = (output.questions ?? []).compactMap { question -> StudyQuestion? in
            let options = question.options.map(clean)
            guard options.count >= 2, !options.contains(where: \.isEmpty),
                  options.indices.contains(question.answer_index),
                  !clean(question.question).isEmpty else { return nil }
            return StudyQuestion(prompt: clean(question.question), options: options,
                                 answerIndex: question.answer_index,
                                 explanation: question.explanation.map(clean))
        }
        var set = StudySet(engine: engine,
                           language: output.language.map(clean).flatMap { $0.isEmpty ? nil : $0 } ?? fallbackLanguage,
                           generatedAt: Date(),
                           signature: signature,
                           summary: (output.summary ?? []).map(clean).filter { !$0.isEmpty },
                           cards: cards,
                           questions: questions)
        set.keyTerms = (output.key_terms ?? [])
            .map { StudyTerm(term: clean($0.term), definition: clean($0.definition)) }
            .filter { !$0.term.isEmpty && !$0.definition.isEmpty }
        set.facts = (output.facts ?? []).map(clean).filter { !$0.isEmpty }
        set.version = StudySet.currentVersion
        return set
    }

    /// كتل النص للصفحات (مع أرقامها)، والصور تُضاف حسب صيغة كل خدمة.
    static func pageText(_ page: ReadPage, budget: inout Int) -> String? {
        let text = page.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, budget > 0 else { return nil }
        let clipped = String(text.prefix(budget))
        budget -= clipped.count
        return "— صفحة \(page.number) —\n\(clipped)"
    }

    static func imageLabel(_ page: ReadPage) -> String {
        "— صورة صفحة \(page.number) (فيها خط يد أو صور) —"
    }
}
