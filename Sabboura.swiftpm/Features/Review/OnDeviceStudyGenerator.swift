import Foundation
import NaturalLanguage

/// يولّد بطاقات حفظ وكويز من نص المذكرة على الجهاز نفسه، بدون إنترنت.
///
/// الفكرة: نحدد المصطلحات المهمة (الأكثر تكراراً والأقل شيوعاً بين الجمل)، ونرتّب الجمل حسب
/// أهميتها، ثم نصنع من الجمل التعريفية («X هو Y») بطاقات وأسئلة «ما المقصود بـ»، ومن باقي
/// الجمل المهمة بطاقات «أكمل الفراغ» وأسئلة اختيار من متعدد وصح/خطأ وأسئلة الأرقام.
enum OnDeviceStudyGenerator {
    static let maxCards = 16
    static let maxQuestions = 10

    static func generate(from content: NoteContent, signature: String) -> StudySet {
        let text = content.fullText
        let arabic = isMostlyArabic(text)
        var builder = Builder(text: text, arabic: arabic, seed: stableHash(signature + text.prefix(200)))
        builder.analyze()
        return StudySet(engine: .onDevice,
                        language: arabic ? "ar" : (content.language.isEmpty ? "en" : content.language),
                        generatedAt: Date(),
                        signature: signature,
                        summary: builder.summary(),
                        cards: builder.cards(),
                        questions: builder.questions())
    }

    // MARK: - التحليل

    private struct Sentence {
        let index: Int
        let text: String
        let tokens: [Token]
        var score: Double = 0
        var definition: Definition?
    }

    private struct Token {
        let surface: String
        let key: String
        let range: Range<String.Index>
    }

    private struct Definition {
        let term: String
        let body: String
        let plural: Bool
        let isColon: Bool
    }

    private struct Builder {
        let text: String
        let arabic: Bool
        var rng: SeededGenerator
        var sentences: [Sentence] = []
        var weight: [String: Double] = [:]
        var display: [String: String] = [:]
        var rankedTerms: [String] = []
        private var usedForCards = Set<Int>()

        init(text: String, arabic: Bool, seed: UInt64) {
            self.text = text
            self.arabic = arabic
            self.rng = SeededGenerator(seed: seed)
        }

        mutating func analyze() {
            // 1) الجمل
            var index = 0
            for rawLine in text.components(separatedBy: .newlines) {
                let line = stripBullet(rawLine)
                guard !line.isEmpty else { continue }
                let tokenizer = NLTokenizer(unit: .sentence)
                tokenizer.string = line
                tokenizer.enumerateTokens(in: line.startIndex..<line.endIndex) { range, _ in
                    let sentence = String(line[range]).trimmingCharacters(in: .whitespacesAndNewlines)
                    let tokens = OnDeviceStudyGenerator.tokens(in: sentence)
                    if tokens.count >= 3 && tokens.count <= 55 {
                        sentences.append(Sentence(index: index, text: sentence, tokens: tokens))
                        index += 1
                    }
                    return true
                }
            }
            guard !sentences.isEmpty else { return }

            // 2) أوزان المصطلحات
            var frequency: [String: Int] = [:]
            var sentenceFrequency: [String: Int] = [:]
            var surfaces: [String: [String: Int]] = [:]
            for sentence in sentences {
                var seen = Set<String>()
                for token in sentence.tokens where OnDeviceStudyGenerator.isTerm(token) {
                    frequency[token.key, default: 0] += 1
                    surfaces[token.key, default: [:]][token.surface, default: 0] += 1
                    if seen.insert(token.key).inserted {
                        sentenceFrequency[token.key, default: 0] += 1
                    }
                }
            }
            let count = Double(sentences.count)
            for (key, tf) in frequency {
                let sf = Double(sentenceFrequency[key] ?? 1)
                var value = Double(tf) * log(1 + count / sf)
                if key.count >= 5 { value *= 1.15 }
                weight[key] = value
                display[key] = surfaces[key]?.max { $0.value < $1.value || ($0.value == $1.value && $0.key.count > $1.key.count) }?.key ?? key
            }
            rankedTerms = weight.sorted { $0.value > $1.value }.map(\.key)
            let average = weight.values.reduce(0, +) / Double(max(weight.count, 1))

            // 3) تقييم الجمل والتعريفات
            for i in sentences.indices {
                var keys = Set<String>()
                var sum = 0.0
                for token in sentences[i].tokens where OnDeviceStudyGenerator.isTerm(token) {
                    if keys.insert(token.key).inserted { sum += weight[token.key] ?? 0 }
                }
                var score = sum / sqrt(Double(sentences[i].tokens.count))
                let definition = OnDeviceStudyGenerator.definition(in: sentences[i].text, arabic: arabic)
                if definition != nil { score += average * 2.5 }
                if OnDeviceStudyGenerator.number(in: sentences[i].text) != nil { score += average * 0.5 }
                sentences[i].score = score
                sentences[i].definition = definition
            }
        }

        private var bySCore: [Sentence] {
            sentences.sorted { $0.score > $1.score }
        }

        // MARK: الملخص

        func summary() -> [String] {
            let top = bySCore.prefix(5).sorted { $0.index < $1.index }
            return top.map { shorten($0.text, words: 32) }
        }

        // MARK: البطاقات

        mutating func cards() -> [StudyCard] {
            var result: [StudyCard] = []
            let ranked = bySCore
            for sentence in ranked where result.count < 10 {
                guard let definition = sentence.definition else { continue }
                result.append(StudyCard(front: definitionPrompt(definition), back: capitalized(definition.body)))
                usedForCards.insert(sentence.index)
            }
            for sentence in ranked where result.count < maxCards {
                guard !usedForCards.contains(sentence.index), let cloze = cloze(sentence) else { continue }
                result.append(StudyCard(front: (arabic ? "أكمل الفراغ: " : "Fill in the blank: ") + cloze.text,
                                        back: cloze.answer + "\n\n" + sentence.text))
                usedForCards.insert(sentence.index)
            }
            return result
        }

        // MARK: الأسئلة

        mutating func questions() -> [StudyQuestion] {
            let ranked = bySCore
            var definitionQuestions: [StudyQuestion] = []
            var clozeQuestions: [StudyQuestion] = []
            var numberQuestions: [StudyQuestion] = []
            var truthQuestions: [StudyQuestion] = []

            // ما المقصود بـ …؟ (تحتاج ٤ تعريفات على الأقل للخيارات)
            let definitions = ranked.compactMap { sentence -> (Sentence, Definition)? in
                guard let definition = sentence.definition, !definition.isColon else { return nil }
                return (sentence, definition)
            }
            if definitions.count >= 4 {
                for (sentence, definition) in definitions.prefix(4) {
                    let others = definitions.filter { $0.0.index != sentence.index }
                        .map { shorten($0.1.body, words: 14) }
                    let distractors = Array(others.shuffled(using: &rng).prefix(3))
                    guard distractors.count == 3 else { continue }
                    definitionQuestions.append(makeQuestion(prompt: definitionPrompt(definition),
                                                            answer: shorten(definition.body, words: 14),
                                                            distractors: distractors,
                                                            explanation: sentence.text))
                }
            }

            for sentence in ranked {
                if clozeQuestions.count < 6, sentence.definition == nil || definitions.count < 4,
                   let cloze = cloze(sentence) {
                    let distractors = distractorTerms(for: cloze, in: sentence)
                    if distractors.count == 3 {
                        clozeQuestions.append(makeQuestion(prompt: (arabic ? "اختر الكلمة المناسبة للفراغ:\n" : "Choose the word that fits the blank:\n") + cloze.text,
                                                           answer: cloze.answer,
                                                           distractors: distractors,
                                                           explanation: sentence.text))
                        continue
                    }
                }
                if numberQuestions.count < 3, let numberQuestion = numberQuestion(sentence) {
                    numberQuestions.append(numberQuestion)
                    continue
                }
                if truthQuestions.count < 4, let truth = truthQuestion(sentence, makeFalse: truthQuestions.count % 2 == 0) {
                    truthQuestions.append(truth)
                }
            }

            // مزيج متوازن من الأنواع
            var result: [StudyQuestion] = []
            var pools = [definitionQuestions, clozeQuestions, numberQuestions, truthQuestions]
            while result.count < maxQuestions && pools.contains(where: { !$0.isEmpty }) {
                for i in pools.indices where !pools[i].isEmpty && result.count < maxQuestions {
                    result.append(pools[i].removeFirst())
                }
            }
            return result
        }

        // MARK: صناعة الأسئلة

        private mutating func makeQuestion(prompt: String, answer: String, distractors: [String],
                                           explanation: String) -> StudyQuestion {
            var options = distractors + [answer]
            options.shuffle(using: &rng)
            let index = options.firstIndex(of: answer) ?? 0
            return StudyQuestion(prompt: prompt, options: options, answerIndex: index, explanation: explanation)
        }

        private func definitionPrompt(_ definition: Definition) -> String {
            if definition.isColon {
                return definition.term
            }
            if arabic {
                return "ما المقصود بـ «\(definition.term)»؟"
            }
            return definition.plural ? "What are \(definition.term)?" : "What is \(definition.term)?"
        }

        private struct Cloze {
            let text: String
            let answer: String
            let key: String
        }

        /// يخفي أهم مصطلح في الجملة.
        private func cloze(_ sentence: Sentence) -> Cloze? {
            let candidates = sentence.tokens.filter { OnDeviceStudyGenerator.isTerm($0) && $0.surface.count >= 3 }
            guard let best = candidates.max(by: { (weight[$0.key] ?? 0) < (weight[$1.key] ?? 0) }),
                  (weight[best.key] ?? 0) > 0 else { return nil }
            var range = best.range
            var answer = best.surface
            // «والخلية» ← نخفي «الخلية» ونترك الواو حتى لا تكشف الإجابة
            if arabic, let first = answer.first, first == "و" || first == "ف",
               answer.dropFirst().hasPrefix("ال") {
                range = sentence.text.index(after: range.lowerBound)..<range.upperBound
                answer = String(answer.dropFirst())
            }
            var masked = sentence.text
            masked.replaceSubrange(range, with: "_____")
            return Cloze(text: masked, answer: answer, key: best.key)
        }

        /// مصطلحات أخرى من نفس المذكرة كخيارات خاطئة.
        private mutating func distractorTerms(for cloze: Cloze, in sentence: Sentence) -> [String] {
            let sentenceKeys = Set(sentence.tokens.map(\.key))
            let answerArabic = OnDeviceStudyGenerator.isArabicWord(cloze.answer)
            let wantsArticle = cloze.answer.hasPrefix("ال")
            var pool: [String] = []
            for key in rankedTerms.prefix(40) where key != cloze.key && !sentenceKeys.contains(key) {
                guard var word = display[key], OnDeviceStudyGenerator.isArabicWord(word) == answerArabic else { continue }
                if answerArabic {
                    if let first = word.first, first == "و" || first == "ف", word.dropFirst().hasPrefix("ال") {
                        word = String(word.dropFirst())
                    }
                    if wantsArticle && !word.hasPrefix("ال") { word = "ال" + word }
                    if !wantsArticle && word.hasPrefix("ال") { word = String(word.dropFirst(2)) }
                }
                if !pool.contains(word) && word != cloze.answer { pool.append(word) }
            }
            let near = Array(pool.prefix(8)).shuffled(using: &rng)
            return Array(near.prefix(3))
        }

        private mutating func numberQuestion(_ sentence: Sentence) -> StudyQuestion? {
            guard let found = OnDeviceStudyGenerator.number(in: sentence.text) else { return nil }
            let value = found.value
            var variants = Set<Int>()
            let isYear = value >= 1000 && value <= 2100
            var attempts = 0
            while variants.count < 3 && attempts < 40 {
                attempts += 1
                let delta: Int
                if isYear {
                    delta = Int.random(in: 2...25, using: &rng) * (Bool.random(using: &rng) ? 1 : -1)
                } else if value < 10 {
                    delta = Int.random(in: 1...4, using: &rng) * (Bool.random(using: &rng) ? 1 : -1)
                } else {
                    delta = max(1, value / Int.random(in: 3...6, using: &rng)) * (Bool.random(using: &rng) ? 1 : -1)
                }
                let candidate = value + delta
                if candidate > 0 && candidate != value { variants.insert(candidate) }
            }
            guard variants.count == 3 else { return nil }
            var masked = sentence.text
            masked.replaceSubrange(found.range, with: "_____")
            let format: (Int) -> String = { found.arabicDigits ? OnDeviceStudyGenerator.arabicIndic($0) : String($0) }
            return makeQuestion(prompt: (arabic ? "ما الرقم الصحيح؟\n" : "Which number is correct?\n") + masked,
                                answer: format(value),
                                distractors: variants.sorted().map(format),
                                explanation: sentence.text)
        }

        private mutating func truthQuestion(_ sentence: Sentence, makeFalse: Bool) -> StudyQuestion? {
            let options = arabic ? ["صح", "خطأ"] : ["True", "False"]
            let prompt = arabic ? "صح أم خطأ؟\n" : "True or false?\n"
            guard makeFalse else {
                return StudyQuestion(prompt: prompt + sentence.text, options: options, answerIndex: 0,
                                     explanation: sentence.text)
            }
            guard let cloze = cloze(sentence) else { return nil }
            let distractors = distractorTerms(for: cloze, in: sentence)
            guard let wrong = distractors.first else { return nil }
            let altered = cloze.text.replacingOccurrences(of: "_____", with: wrong)
            return StudyQuestion(prompt: prompt + altered, options: options, answerIndex: 1,
                                 explanation: (arabic ? "الصحيح: " : "Correct: ") + sentence.text)
        }

        // MARK: مساعدات النص

        private func shorten(_ text: String, words limit: Int) -> String {
            let words = text.split(separator: " ")
            guard words.count > limit else { return text }
            return words.prefix(limit).joined(separator: " ") + "…"
        }

        private func capitalized(_ text: String) -> String {
            guard !arabic, let first = text.first else { return text }
            return first.uppercased() + text.dropFirst()
        }

        private func stripBullet(_ line: String) -> String {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let pattern = "^([•●▪◦\\-–—*]+|\\(?[0-9٠-٩]{1,2}[\\.\\)\\-:]|[a-zA-Zأ-ي][\\)\\.])\\s+"
            return trimmed.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
    }

    // MARK: - أدوات لغوية

    private static func tokens(in sentence: String) -> [Token] {
        var result: [Token] = []
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = sentence
        tokenizer.enumerateTokens(in: sentence.startIndex..<sentence.endIndex) { range, _ in
            let surface = String(sentence[range])
            result.append(Token(surface: surface, key: normalizedKey(surface), range: range))
            return true
        }
        return result
    }

    private static func isTerm(_ token: Token) -> Bool {
        let key = token.key
        guard key.count >= 3, !stopwords.contains(key), !stopwords.contains(token.surface.lowercased()) else { return false }
        return key.contains { $0.isLetter }
    }

    static func isArabicWord(_ word: String) -> Bool {
        word.unicodeScalars.contains { (0x0600...0x06FF).contains($0.value) }
    }

    static func isMostlyArabic(_ text: String) -> Bool {
        var arabic = 0, latin = 0
        for scalar in text.unicodeScalars.prefix(20_000) {
            if (0x0600...0x06FF).contains(scalar.value) { arabic += 1 }
            else if (0x41...0x5A).contains(scalar.value) || (0x61...0x7A).contains(scalar.value) { latin += 1 }
        }
        return arabic > 0 && Double(arabic) >= Double(latin) * 0.6
    }

    /// مفتاح موحّد للكلمة: بدون تشكيل، والألف موحدة، وبدون «ال» والواو والباء…
    static func normalizedKey(_ word: String) -> String {
        var w = word.lowercased()
        guard isArabicWord(w) else {
            if w.hasSuffix("'s") { w.removeLast(2) }
            if w.count > 4, w.hasSuffix("s"), !w.hasSuffix("ss") { w.removeLast() }
            return w
        }
        w = String(w.unicodeScalars.filter { !(0x064B...0x0652).contains($0.value) && $0.value != 0x0670 && $0.value != 0x0640 }
            .map(Character.init))
        w = w.replacingOccurrences(of: "أ", with: "ا")
            .replacingOccurrences(of: "إ", with: "ا")
            .replacingOccurrences(of: "آ", with: "ا")
            .replacingOccurrences(of: "ى", with: "ي")
            .replacingOccurrences(of: "ة", with: "ه")
        for prefix in ["وال", "فال", "بال", "كال", "لل", "ال"] where w.hasPrefix(prefix) && w.count - prefix.count >= 3 {
            return String(w.dropFirst(prefix.count))
        }
        if w.count > 4, let first = w.first, first == "و" || first == "ف" {
            return String(w.dropFirst())
        }
        return w
    }

    private static func definition(in sentence: String, arabic: Bool) -> Definition? {
        let patterns: [(String, Bool)] = arabic ? [
            ("^(.{2,45}?)\\s+(هو|هي|هم|يُعرف بأنه|تُعرف بأنها|يعرف بأنه|تعرف بأنها|عبارة عن|يسمى|تسمى|يُسمى|تُسمى|يقصد به|يقصد بها|يُقصد به|يُقصد بها|يعني|تعني)\\s+(.{6,})$", false)
        ] : [
            ("^(.{2,60}?)\\s+(is defined as|refers to|is called|are called|is|are|means)\\s+(.{6,})$", false)
        ]
        for (pattern, _) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let range = NSRange(sentence.startIndex..., in: sentence)
            guard let match = regex.firstMatch(in: sentence, range: range),
                  let termRange = Range(match.range(at: 1), in: sentence),
                  let verbRange = Range(match.range(at: 2), in: sentence),
                  let bodyRange = Range(match.range(at: 3), in: sentence) else { continue }
            var term = String(sentence[termRange]).trimmingCharacters(in: .whitespaces)
            let words = term.split(separator: " ")
            guard words.count <= (arabic ? 5 : 7) else { continue }
            if !arabic {
                for article in ["The ", "A ", "An "] where term.hasPrefix(article) { term.removeFirst(article.count) }
            }
            let body = String(sentence[bodyRange]).trimmingCharacters(in: CharacterSet(charactersIn: " .،.؛"))
            let verb = String(sentence[verbRange]).lowercased()
            return Definition(term: term, body: body, plural: verb == "are" || verb == "are called", isColon: false)
        }
        // «المصطلح: الشرح»
        if let colon = sentence.firstIndex(where: { $0 == ":" || $0 == "：" }) {
            let term = sentence[..<colon].trimmingCharacters(in: .whitespaces)
            let body = sentence[sentence.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if (1...5).contains(term.split(separator: " ").count), body.split(separator: " ").count >= 3 {
                return Definition(term: term, body: body, plural: false, isColon: true)
            }
        }
        return nil
    }

    private struct FoundNumber {
        let value: Int
        let range: Range<String.Index>
        let arabicDigits: Bool
    }

    private static func number(in sentence: String) -> FoundNumber? {
        guard let regex = try? NSRegularExpression(pattern: "(?<![0-9٠-٩.,])([0-9]{2,4}|[٠-٩]{2,4})(?![0-9٠-٩.,])") else { return nil }
        let range = NSRange(sentence.startIndex..., in: sentence)
        guard let match = regex.firstMatch(in: sentence, range: range),
              let found = Range(match.range(at: 1), in: sentence) else { return nil }
        let digits = String(sentence[found])
        let arabicDigits = digits.unicodeScalars.contains { (0x0660...0x0669).contains($0.value) }
        let western = String(digits.unicodeScalars.map { scalar -> Character in
            if (0x0660...0x0669).contains(scalar.value), let converted = UnicodeScalar(scalar.value - 0x0660 + 0x30) {
                return Character(converted)
            }
            return Character(scalar)
        })
        guard let value = Int(western), value >= 10 else { return nil }
        return FoundNumber(value: value, range: found, arabicDigits: arabicDigits)
    }

    static func arabicIndic(_ value: Int) -> String {
        String(String(value).unicodeScalars.map { scalar -> Character in
            if (0x30...0x39).contains(scalar.value), let converted = UnicodeScalar(scalar.value - 0x30 + 0x0660) {
                return Character(converted)
            }
            return Character(scalar)
        })
    }

    private static func stableHash<S: StringProtocol>(_ text: S) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return hash
    }

    static let stopwords: Set<String> = {
        let arabic = """
        من في على الى إلى عن مع ان أن إن كان كانت يكون تكون كانوا هذا هذه ذلك تلك هذان هاتان هؤلاء الذي التي الذين اللذين اللتين اللاتي ما ماذا لماذا كيف متى اين أين هو هي هم هن انا أنا نحن انت أنت انتم كل بعض او أو ثم لا لم لن قد لقد كما اي أي اذا إذا حتى بين عند عندما بعد قبل فوق تحت حيث ليس ليست غير اكثر أكثر اقل أقل جدا جداً ايضا أيضا أيضاً به بها له لها لهم فيه فيها منه منها عليه عليها اليه إليه اليها إليها ذات ذو وهو وهي يتم تم خلال ضمن لكن ولكن بل اما أما اما إما سوف هناك هنا لدى لذلك لذا عبر نحو مثل منذ حول دون يمكن يجب كذلك وكذلك التى الى هذة وفي ومن وعلى وعن ومع اذ إذ لان لأن بأن بان كي لكي فقط أيضًا اول أول ثاني ثالث اخر آخر اخرى أخرى نفس كلا كلتا عدة عده بعضها بعضهم جميع جميعا معظم تكون يكونون وهذا وهذه هي هو
        """
        let english = """
        the a an and or but if then than of to in on at by for with from as is are was were be been being this that these those it its into about over under between through during before after above below up down out off again further once here there when where why how all any both each few more most other some such no nor not only own same so too very can will just should now also may might must could would do does did doing have has had having he she they them his her their what which who whom we you your our i me my
        """
        var set = Set<String>()
        for word in (arabic + " " + english).split(whereSeparator: { $0 == " " || $0 == "\n" }) {
            set.insert(normalizedKey(String(word)))
            set.insert(String(word).lowercased())
        }
        return set
    }()
}

/// مولّد أرقام عشوائية ثابت (نفس المذكرة ← نفس الأسئلة).
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed == 0 ? 0x9E3779B97F4A7C15 : seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
