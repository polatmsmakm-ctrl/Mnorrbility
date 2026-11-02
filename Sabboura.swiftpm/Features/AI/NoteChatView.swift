import CoreData
import SwiftUI

// MARK: - اسأل مذكرتك

/// محادثة عن محتوى المذكرة: الطالب يسأل والمحرّك يجاوب من كلام المذكرة نفسها
/// (النص المكتوب، نص ملفات PDF، وصور الصفحات المكتوبة بخط اليد).
struct NoteChatView: View {
    @ObservedObject var note: CDNote
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var theme

    @State private var turns: [AIAssistant.Turn] = []
    @State private var question = ""
    @State private var working = false
    @State private var preparing = true
    @State private var error: String?
    @State private var noteText = ""
    @State private var images: [Data] = []

    /// أقصى عدد صفحات تُرسل كصور (خط اليد) مع كل سؤال
    private static let maxImages = 8

    private let suggestions = ["لخّص لي المذكرة في خمس نقاط",
                               "اشرح لي أصعب فكرة فيها بأسلوب بسيط",
                               "اسألني ثلاثة أسئلة عشان أختبر نفسي",
                               "وش الأشياء اللي لازم أحفظها للاختبار؟"]

    var body: some View {
        NavigationStack {
            Group {
                if !AIAssistant.isAvailable {
                    unavailable
                } else {
                    conversation
                }
            }
            .background(theme.background.ignoresSafeArea())
            .navigationTitle("اسأل مذكرتك")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("إغلاق") { dismiss() }
                        .accessibilityIdentifier("chatClose")
                }
                if !turns.isEmpty {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            turns = []
                            error = nil
                        } label: {
                            Image(systemName: "square.and.pencil")
                        }
                        .accessibilityLabel("محادثة جديدة")
                    }
                }
            }
        }
        .environment(\.layoutDirection, .rightToLeft)
        .accessibilityIdentifier("chatSheet")
        .task { await prepare() }
    }

    private var unavailable: some View {
        VStack(spacing: 14) {
            Image(systemName: "key.fill")
                .font(.system(size: 40))
                .foregroundStyle(theme.accent)
            Text("أضف مفتاح Gemini المجاني أو مفتاح Claude")
                .font(.inter(.headline))
                .foregroundStyle(theme.primaryText)
            Text("من الإعدادات ← المراجعة الذكية. المذكرة ما تُرسل لأي جهة إلا بعد ما تحط المفتاح بنفسك.")
                .font(.inter(.subheadline))
                .foregroundStyle(theme.secondaryText)
                .multilineTextAlignment(.center)
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if turns.isEmpty {
                        intro
                    }
                    ForEach(Array(turns.enumerated()), id: \.offset) { index, turn in
                        bubble(turn).id(index)
                    }
                    if working {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("\(AIAssistant.providerName) يقرأ المذكرة…")
                                .foregroundStyle(theme.secondaryText)
                        }
                        .id("working")
                    }
                    if let error {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.inter(.callout))
                    }
                }
                .padding(18)
            }
            .onChange(of: turns.count) { _, count in
                withAnimation { proxy.scrollTo(count - 1, anchor: .bottom) }
            }
            .safeAreaInset(edge: .bottom) { askBar }
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("اسأل أي سؤال عن «\(note.displayTitle)»", systemImage: "sparkles")
                .font(.inter(.headline))
                .foregroundStyle(theme.primaryText)
            Text("الإجابة تكون من محتوى المذكرة نفسها، وإذا ما كان الجواب فيها يقول لك.")
                .font(.inter(.subheadline))
                .foregroundStyle(theme.secondaryText)
            if preparing {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("جارٍ قراءة المذكرة…").foregroundStyle(theme.secondaryText)
                }
            }
            ForEach(suggestions, id: \.self) { suggestion in
                Button {
                    question = suggestion
                    send()
                } label: {
                    Text(suggestion)
                        .font(.inter(.callout))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(theme.border))
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.primaryText)
                .disabled(preparing || working)
            }
        }
    }

    private func bubble(_ turn: AIAssistant.Turn) -> some View {
        let mine = turn.role == .user
        return HStack {
            if mine { Spacer(minLength: 40) }
            Text(markdownText(turn.text))
                .font(.inter(.body))
                .foregroundStyle(mine ? Color.white : theme.primaryText)
                .textSelection(.enabled)
                .padding(13)
                .background(mine ? theme.accent : theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .environment(\.layoutDirection,
                             OnDeviceStudyGenerator.isMostlyArabic(turn.text) ? .rightToLeft : .leftToRight)
            if !mine { Spacer(minLength: 40) }
        }
    }

    private var askBar: some View {
        HStack(spacing: 10) {
            TextField("اكتب سؤالك…", text: $question, axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.roundedBorder)
                .submitLabel(.send)
                .onSubmit(send)
                .accessibilityIdentifier("chatInput")
            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill").font(.system(size: 30))
            }
            .disabled(!canSend)
            .accessibilityLabel("إرسال")
            .accessibilityIdentifier("chatSend")
        }
        .padding(12)
        .background(.bar)
    }

    private var canSend: Bool {
        AIAssistant.isAvailable && !working && !preparing
            && !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: المنطق

    private var system: String {
        """
        أنت مساعد مذاكرة لطالب. عندك محتوى مذكرة عنوانها «\(note.displayTitle)»: نصها مكتوب أدناه، \
        وصور بعض صفحاتها المكتوبة بخط اليد مرفقة مع أول رسالة.
        - جاوب من محتوى المذكرة. إذا ما كان الجواب فيها قل ذلك بوضوح، ثم جاوب من معرفتك العامة مع التنبيه.
        - استخدم لغة السؤال، وجمل واضحة وقصيرة، ونقاط عند الحاجة.
        - إذا طلب الطالب أن تختبره، اسأله سؤالاً واحداً كل مرة وانتظر جوابه ثم صحّحه.

        محتوى المذكرة:
        \(noteText.isEmpty ? "(لا يوجد نص مكتوب؛ اعتمد على الصور)" : noteText)
        """
    }

    @MainActor
    private func prepare() async {
        guard preparing else { return }
        let context = note.managedObjectContext ?? PersistenceController.shared.viewContext
        guard let read = NoteContentReader.prepare(note, context: context) else {
            preparing = false
            return
        }
        let content = await Task.detached(priority: .userInitiated) { read(.textAndImages) }.value
        var budget = 150_000
        var parts: [String] = []
        for page in content.pages {
            if let text = StudyPrompt.pageText(page, budget: &budget) { parts.append(text) }
        }
        noteText = parts.joined(separator: "\n\n")
        images = Array(content.pages.compactMap(\.imageJPEG).prefix(Self.maxImages))
        preparing = false
    }

    private func send() {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !working, !preparing else { return }
        question = ""
        error = nil
        let history = turns + [.init(role: .user, text: text)]
        turns = history
        working = true
        let systemPrompt = system
        let pageImages = images
        Task {
            do {
                let answer = try await AIAssistant.ask(system: systemPrompt, turns: history,
                                                       images: pageImages, maxTokens: 4096)
                await MainActor.run {
                    turns.append(.init(role: .assistant, text: answer))
                    working = false
                }
            } catch {
                await MainActor.run {
                    self.error = error.localizedDescription
                    working = false
                }
            }
        }
    }
}
