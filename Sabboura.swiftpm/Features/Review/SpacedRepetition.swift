import Foundation

// MARK: - المراجعة المتباعدة (على طريقة Anki)

/// جدول مراجعة بطاقة واحدة حسب خوارزمية SM-2:
/// كل ما عرفت البطاقة تطول المدة قبل ما ترجع لك، ولو نسيتها ترجع بكرة.
struct CardSchedule: Codable, Equatable {
    /// المدة الحالية بالأيام
    var interval: Int = 0
    /// معامل السهولة (يبدأ 2.5 وينزل مع النسيان)
    var ease: Double = 2.5
    /// عدد مرات المعرفة المتتالية
    var streak: Int = 0
    /// موعد المراجعة القادمة
    var due: Date = .distantPast
    var lastReviewed: Date?

    var isDue: Bool { due <= Date() }

    /// يحدّث الجدول بعد المراجعة: عرفتها أو لا.
    mutating func review(known: Bool, now: Date = Date()) {
        lastReviewed = now
        if known {
            streak += 1
            switch streak {
            case 1: interval = 1
            case 2: interval = 3
            default: interval = max(interval + 1, Int((Double(interval) * ease).rounded()))
            }
            ease = min(3.0, ease + 0.05)
        } else {
            streak = 0
            interval = 0
            ease = max(1.3, ease - 0.2)
        }
        // البطاقة المنسية ترجع بعد عشر دقائق في نفس الجلسة، وغيرها بعد عدد الأيام
        let calendar = Calendar.current
        if interval == 0 {
            due = now.addingTimeInterval(10 * 60)
        } else {
            let start = calendar.startOfDay(for: now)
            due = calendar.date(byAdding: .day, value: interval, to: start) ?? now.addingTimeInterval(Double(interval) * 86_400)
        }
    }
}

/// يحفظ جداول البطاقات لكل مذكرة. المفتاح نص وجه البطاقة (بعد التنظيف)،
/// فيبقى التقدّم محفوظاً حتى لو أُعيد توليد البطاقات وبقي السؤال نفسه.
final class SpacedRepetitionStore {
    static let shared = SpacedRepetitionStore()

    private let defaults = UserDefaults.standard
    private let prefix = "sabboura.srs."
    private var cache: [String: [String: CardSchedule]] = [:]

    private init() {}

    static func cardKey(_ card: StudyCard) -> String {
        let folded = card.front.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil)
        let compact = folded.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        return String(compact.prefix(300))
    }

    private func schedules(for noteID: UUID) -> [String: CardSchedule] {
        let key = prefix + noteID.uuidString
        if let cached = cache[key] { return cached }
        var loaded: [String: CardSchedule] = [:]
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode([String: CardSchedule].self, from: data) {
            loaded = decoded
        }
        cache[key] = loaded
        return loaded
    }

    private func save(_ schedules: [String: CardSchedule], for noteID: UUID) {
        let key = prefix + noteID.uuidString
        cache[key] = schedules
        if let data = try? JSONEncoder().encode(schedules) {
            defaults.set(data, forKey: key)
        }
    }

    func schedule(for card: StudyCard, in noteID: UUID) -> CardSchedule {
        schedules(for: noteID)[Self.cardKey(card)] ?? CardSchedule()
    }

    func review(_ card: StudyCard, in noteID: UUID, known: Bool) {
        var all = schedules(for: noteID)
        var schedule = all[Self.cardKey(card)] ?? CardSchedule()
        schedule.review(known: known)
        all[Self.cardKey(card)] = schedule
        save(all, for: noteID)
    }

    /// البطاقات المستحقة الآن (الجديدة اللي ما انراجعت أبداً تُحسب مستحقة).
    func dueCards(_ cards: [StudyCard], in noteID: UUID) -> [StudyCard] {
        let all = schedules(for: noteID)
        return cards.filter { (all[Self.cardKey($0)] ?? CardSchedule()).isDue }
    }

    /// أقرب موعد مراجعة قادم (لما ما يكون فيه شي مستحق).
    func nextDue(_ cards: [StudyCard], in noteID: UUID) -> Date? {
        let all = schedules(for: noteID)
        return cards.compactMap { all[Self.cardKey($0)]?.due }.filter { $0 > Date() }.min()
    }

    /// عدد البطاقات المستحقة في كل المذكرات (للشاشة الرئيسية).
    func totalDue(in notes: [CDNote]) -> Int {
        notes.reduce(0) { total, note in
            guard let id = note.uuid, let set = note.studySet else { return total }
            return total + dueCards(set.cards, in: id).count
        }
    }

    func reset(_ noteID: UUID) {
        let key = prefix + noteID.uuidString
        cache[key] = [:]
        defaults.removeObject(forKey: key)
    }
}

extension Date {
    /// «بكرة»، «بعد ٣ أيام» …
    var arabicRelativeDay: String {
        let calendar = Calendar.current
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: Date()),
                                           to: calendar.startOfDay(for: self)).day ?? 0
        switch days {
        case ..<1: return "اليوم"
        case 1: return "بكرة"
        case 2: return "بعد يومين"
        case 3...10: return "بعد \(days) أيام"
        default: return "بعد \(days) يوم"
        }
    }
}
