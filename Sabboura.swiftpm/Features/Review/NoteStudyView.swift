import CoreData
import SwiftUI

/// شاشة مراجعة المذكرة: بطاقات حفظ، كويز، وملخص لأهم النقاط.
struct NoteStudyView: View {
    @ObservedObject var note: CDNote
    @ObservedObject private var service = StudyService.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var theme

    @State private var tab: StudyTab = .cards

    enum StudyTab: String, CaseIterable, Identifiable {
        case cards, quiz, summary
        var id: String { rawValue }
        var title: String {
            switch self {
            case .cards: return "البطاقات"
            case .quiz: return "الكويز"
            case .summary: return "الملخص"
            }
        }
        var symbol: String {
            switch self {
            case .cards: return "rectangle.on.rectangle.angled"
            case .quiz: return "checklist"
            case .summary: return "text.alignright"
            }
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                tabBar
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 10)
                Divider().overlay(theme.border)
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(theme.background.ignoresSafeArea())
            .navigationTitle(note.displayTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(theme.background, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("إغلاق") { dismiss() }
                        .accessibilityIdentifier("studyClose")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        service.generate(for: note)
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(service.isWorking(on: note))
                    .accessibilityLabel("إعادة التوليد")
                    .accessibilityIdentifier("studyRegenerate")
                }
            }
        }
        .environment(\.layoutDirection, .rightToLeft)
        .accessibilityIdentifier("studySheet")
        .onAppear {
            guard !service.isWorking(on: note) else { return }
            // بدون مفتاح Claude التوليد مجاني وسريع، فنحدّث تلقائياً متى تغيّرت المذكرة
            if note.studySet == nil || (note.isStudyStale && !ReviewSettings.hasClaudeKey) {
                service.generate(for: note)
            }
        }
    }

    // MARK: التبويبات

    private var tabBar: some View {
        HStack(spacing: 6) {
            ForEach(StudyTab.allCases) { item in
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { tab = item }
                } label: {
                    Label(item.title, systemImage: item.symbol)
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .foregroundStyle(tab == item ? Color.white : theme.primaryText)
                        .background(tab == item ? theme.accent : theme.card,
                                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("studyTab.\(item.rawValue)")
            }
        }
    }

    // MARK: المحتوى

    @ViewBuilder
    private var content: some View {
        if let set = note.studySet, !set.isEmpty {
            VStack(spacing: 0) {
                banner(set)
                switch tab {
                case .cards:
                    FlashcardsView(note: note, set: set)
                case .quiz:
                    QuizView(note: note, set: set)
                case .summary:
                    SummaryView(set: set)
                }
            }
        } else if service.isWorking(on: note) || note.studySet == nil {
            working
        } else {
            empty
        }
    }

    @ViewBuilder
    private func banner(_ set: StudySet) -> some View {
        let isWorking = service.isWorking(on: note)
        if isWorking || note.isStudyStale || service.notice(for: note) != nil {
            HStack(spacing: 10) {
                if isWorking {
                    ProgressView()
                    Text(service.status(for: note) ?? "جارٍ التحديث…")
                } else if let notice = service.notice(for: note) {
                    Image(systemName: "info.circle")
                    Text(notice)
                } else {
                    Image(systemName: "arrow.triangle.2.circlepath")
                    Text("المذكرة تغيّرت بعد آخر مراجعة")
                    Spacer(minLength: 4)
                    Button("تحديث") { service.generate(for: note) }
                        .fontWeight(.semibold)
                        .accessibilityIdentifier("studyRefreshBanner")
                }
                Spacer(minLength: 0)
            }
            .font(.footnote)
            .foregroundStyle(theme.secondaryText)
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(theme.card)
        }
    }

    private var working: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            Text(service.status(for: note) ?? "جارٍ قراءة المذكرة…")
                .font(.headline)
                .foregroundStyle(theme.primaryText)
            Text("أقرأ النص المكتوب وملفات PDF وخط اليد والصور، وأطلع منها بطاقات وأسئلة لأهم النقاط.")
                .font(.subheadline)
                .foregroundStyle(theme.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .padding(30)
        .accessibilityIdentifier("studyWorking")
    }

    private var empty: some View {
        VStack(spacing: 14) {
            Image(systemName: "text.magnifyingglass")
                .font(.system(size: 44))
                .foregroundStyle(theme.secondaryText)
            Text("ما لقيت كلام كافي في المذكرة")
                .font(.title3.weight(.semibold))
                .foregroundStyle(theme.primaryText)
            Text(service.notice(for: note) ?? "اكتب ملاحظاتك أو استورد ملف PDF فيه نص، وبعدها أطلع لك بطاقات وكويز تلقائياً.")
                .font(.subheadline)
                .foregroundStyle(theme.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Button {
                service.generate(for: note)
            } label: {
                Label("حاول مرة ثانية", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(30)
        .accessibilityIdentifier("studyEmpty")
    }
}

// MARK: - البطاقات

private struct FlashcardsView: View {
    @ObservedObject var note: CDNote
    let set: StudySet
    @Environment(\.appTheme) private var theme

    @State private var order: [UUID] = []
    @State private var position = 0
    @State private var flipped = false
    @State private var onlyUnknown = false

    private var cards: [StudyCard] {
        let lookup = Dictionary(uniqueKeysWithValues: set.cards.map { ($0.id, $0) })
        return order.compactMap { lookup[$0] }
    }

    var body: some View {
        VStack(spacing: 18) {
            if cards.isEmpty {
                Text("ما فيه بطاقات لهذه المذكرة")
                    .foregroundStyle(theme.secondaryText)
                    .frame(maxHeight: .infinity)
            } else if position >= cards.count {
                finished
            } else {
                progress
                card(cards[position])
                controls
            }
        }
        .padding(20)
        .onAppear(perform: reset)
        .onChange(of: set.signature) { _, _ in reset() }
    }

    private func reset() {
        let source = onlyUnknown ? set.cards.filter { $0.known != true } : set.cards
        order = source.map(\.id)
        position = 0
        flipped = false
    }

    private var progress: some View {
        let known = set.cards.filter { $0.known == true }.count
        return HStack {
            Text("\(position + 1) / \(cards.count)")
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .accessibilityIdentifier("cardProgress")
            Spacer()
            Label("عرفت \(known)", systemImage: "checkmark.circle.fill")
                .font(.subheadline)
                .foregroundStyle(.green)
            Button {
                order.shuffle()
                position = 0
                flipped = false
            } label: {
                Image(systemName: "shuffle")
            }
            .accessibilityLabel("خلط البطاقات")
        }
        .foregroundStyle(theme.secondaryText)
    }

    private func card(_ card: StudyCard) -> some View {
        let text = flipped ? card.back : card.front
        return Button {
            withAnimation(.spring(duration: 0.45)) { flipped.toggle() }
        } label: {
            VStack(spacing: 14) {
                Text(flipped ? "الإجابة" : "السؤال")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(flipped ? Color.green : theme.accent)
                Text(text)
                    .font(.system(size: AppEnvironment.isPhone ? 20 : 24, weight: flipped ? .regular : .semibold))
                    .foregroundStyle(theme.primaryText)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.5)
                    .environment(\.layoutDirection, set.isArabic ? .rightToLeft : .leftToRight)
                Text(flipped ? "اضغط لعرض السؤال" : "اضغط لقلب البطاقة")
                    .font(.caption)
                    .foregroundStyle(theme.secondaryText)
            }
            .padding(26)
            .frame(maxWidth: 640, maxHeight: .infinity)
            .background(theme.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(flipped ? Color.green.opacity(0.6) : theme.border, lineWidth: 1.5))
            .shadow(color: .black.opacity(theme.isDark ? 0.35 : 0.08), radius: 14, y: 6)
            .rotation3DEffect(.degrees(flipped ? 360 : 0), axis: (x: 0, y: 1, z: 0))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(text)
        .accessibilityIdentifier("flashcard")
    }

    private var controls: some View {
        HStack(spacing: 14) {
            Button {
                mark(false)
            } label: {
                Label("ما عرفتها", systemImage: "xmark")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .foregroundStyle(.white)
                    .background(Color.red.opacity(0.85), in: RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("cardUnknown")
            Button {
                mark(true)
            } label: {
                Label("عرفتها", systemImage: "checkmark")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .foregroundStyle(.white)
                    .background(Color.green.opacity(0.85), in: RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("cardKnown")
        }
        .font(.headline)
        .frame(maxWidth: 640)
    }

    private func mark(_ known: Bool) {
        guard position < cards.count else { return }
        let id = cards[position].id
        StudyService.shared.update(note) { set in
            if let index = set.cards.firstIndex(where: { $0.id == id }) {
                set.cards[index].known = known
            }
        }
        withAnimation(.easeInOut(duration: 0.2)) {
            flipped = false
            position += 1
        }
    }

    private var finished: some View {
        let known = set.cards.filter { $0.known == true }.count
        let unknown = set.cards.count - known
        return VStack(spacing: 16) {
            Image(systemName: unknown == 0 ? "star.circle.fill" : "flag.checkered.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(unknown == 0 ? .yellow : theme.accent)
            Text("عرفت \(known) من \(set.cards.count)")
                .font(.title2.weight(.bold))
                .foregroundStyle(theme.primaryText)
                .accessibilityIdentifier("cardsFinished")
            if unknown > 0 {
                Button {
                    onlyUnknown = true
                    reset()
                } label: {
                    Label("راجع اللي ما عرفتها (\(unknown))", systemImage: "arrow.uturn.backward")
                }
                .buttonStyle(.borderedProminent)
            }
            Button {
                onlyUnknown = false
                StudyService.shared.update(note) { set in
                    for index in set.cards.indices { set.cards[index].known = nil }
                }
                reset()
            } label: {
                Label("من البداية", systemImage: "arrow.counterclockwise")
            }
            .buttonStyle(.bordered)
        }
        .frame(maxHeight: .infinity)
    }
}

// MARK: - الكويز

private struct QuizView: View {
    @ObservedObject var note: CDNote
    let set: StudySet
    @Environment(\.appTheme) private var theme

    @State private var position = 0
    @State private var selected: Int?
    @State private var score = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if set.questions.isEmpty {
                    Text("ما فيه أسئلة لهذه المذكرة")
                        .foregroundStyle(theme.secondaryText)
                } else if position >= set.questions.count {
                    finished
                } else {
                    question(set.questions[position])
                }
            }
            .padding(20)
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
        }
        .onChange(of: set.signature) { _, _ in restart() }
    }

    private func question(_ question: StudyQuestion) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("سؤال \(position + 1) من \(set.questions.count)")
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(theme.secondaryText)
                Spacer()
                Text("النتيجة: \(score)")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(theme.secondaryText)
            }
            Text(question.prompt)
                .font(.title3.weight(.semibold))
                .foregroundStyle(theme.primaryText)
                .fixedSize(horizontal: false, vertical: true)
                .environment(\.layoutDirection, set.isArabic ? .rightToLeft : .leftToRight)
                .frame(maxWidth: .infinity, alignment: set.isArabic ? .trailing : .leading)
                .multilineTextAlignment(set.isArabic ? .trailing : .leading)
                .accessibilityIdentifier("quizPrompt")

            ForEach(Array(question.options.enumerated()), id: \.offset) { index, option in
                Button {
                    guard selected == nil else { return }
                    selected = index
                    if index == question.answerIndex { score += 1 }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: icon(for: index, question: question))
                            .font(.title3)
                        Text(option)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(theme.primaryText)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(fill(for: index, question: question), in: RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(stroke(for: index, question: question), lineWidth: 1.5))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("quizOption.\(index)")
            }

            if let selected {
                VStack(alignment: .leading, spacing: 8) {
                    Label(selected == question.answerIndex ? "إجابة صحيحة!" : "الإجابة الصحيحة: \(question.options[question.answerIndex])",
                          systemImage: selected == question.answerIndex ? "checkmark.seal.fill" : "lightbulb.fill")
                        .font(.headline)
                        .foregroundStyle(selected == question.answerIndex ? .green : .orange)
                    if let explanation = question.explanation, !explanation.isEmpty {
                        Text(explanation)
                            .font(.subheadline)
                            .foregroundStyle(theme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityIdentifier("quizFeedback")
                Button {
                    next()
                } label: {
                    Text(position + 1 < set.questions.count ? "السؤال التالي" : "النتيجة")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .foregroundStyle(.white)
                        .background(theme.accent, in: RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("quizNext")
            }
        }
    }

    private func icon(for index: Int, question: StudyQuestion) -> String {
        guard let selected else { return "circle" }
        if index == question.answerIndex { return "checkmark.circle.fill" }
        return index == selected ? "xmark.circle.fill" : "circle"
    }

    private func fill(for index: Int, question: StudyQuestion) -> Color {
        guard let selected else { return theme.card }
        if index == question.answerIndex { return Color.green.opacity(0.18) }
        return index == selected ? Color.red.opacity(0.16) : theme.card
    }

    private func stroke(for index: Int, question: StudyQuestion) -> Color {
        guard let selected else { return theme.border }
        if index == question.answerIndex { return .green }
        return index == selected ? .red : theme.border
    }

    private func next() {
        selected = nil
        position += 1
        if position >= set.questions.count {
            let final = score
            StudyService.shared.update(note) { set in
                set.lastScore = final
                set.bestScore = max(set.bestScore ?? 0, final)
            }
        }
    }

    private func restart() {
        position = 0
        selected = nil
        score = 0
    }

    private var finished: some View {
        let total = set.questions.count
        return VStack(spacing: 16) {
            Image(systemName: score == total ? "trophy.fill" : "chart.bar.fill")
                .font(.system(size: 54))
                .foregroundStyle(score == total ? .yellow : theme.accent)
            Text("\(score) من \(total)")
                .font(.system(size: 40, weight: .heavy).monospacedDigit())
                .foregroundStyle(theme.primaryText)
                .accessibilityIdentifier("quizScore")
            if let best = set.bestScore {
                Text("أفضل نتيجة: \(best) من \(total)")
                    .foregroundStyle(theme.secondaryText)
            }
            Button {
                restart()
            } label: {
                Label("أعد الكويز", systemImage: "arrow.counterclockwise")
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("quizRestart")
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }
}

// MARK: - الملخص

private struct SummaryView: View {
    let set: StudySet
    @Environment(\.appTheme) private var theme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("أهم النقاط")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(theme.primaryText)
                ForEach(Array(set.summary.enumerated()), id: \.offset) { _, point in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Circle().fill(theme.accent).frame(width: 7, height: 7)
                        Text(point)
                            .foregroundStyle(theme.primaryText)
                            .fixedSize(horizontal: false, vertical: true)
                            .environment(\.layoutDirection, set.isArabic ? .rightToLeft : .leftToRight)
                    }
                }
                Divider().padding(.vertical, 6)
                Label {
                    Text("\(set.engine == .claude ? "ولّدها Claude" : "تولّدت على الجهاز") · \(set.generatedAt.formatted(date: .abbreviated, time: .shortened))")
                } icon: {
                    Image(systemName: set.engine == .claude ? "sparkles" : "iphone")
                }
                .font(.footnote)
                .foregroundStyle(theme.secondaryText)
                .accessibilityIdentifier("studyEngine")
                Text("\(set.cards.count) بطاقة · \(set.questions.count) سؤال")
                    .font(.footnote)
                    .foregroundStyle(theme.secondaryText)
            }
            .padding(20)
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .accessibilityIdentifier("studySummary")
    }
}
