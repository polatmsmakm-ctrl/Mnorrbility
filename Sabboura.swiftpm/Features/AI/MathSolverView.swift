import SwiftUI
import UIKit

// MARK: - حل المسائل المكتوبة بخط اليد

/// مسألة محددة من الصفحة (صورة الكتابة) تُرسل للمحرّك ليشرح حلها خطوة بخطوة.
struct MathProblem: Identifiable {
    let id = UUID()
    let image: UIImage
    /// مكان المسألة في الصفحة (إحداثيات اللوحة) لإدراج الحل تحتها
    let canvasRect: CGRect
}

enum MathSolver {
    static let system = """
    أنت معلم رياضيات وعلوم صبور. تصلك صورة مسألة مكتوبة بخط اليد من دفتر طالب.
    - اكتب أولاً المسألة كما فهمتها في سطر واحد.
    - ثم حلّها خطوة بخطوة، كل خطوة في سطر مستقل ومرقّمة، مع سبب مختصر لكل خطوة.
    - اكتب الناتج النهائي في سطر أخير يبدأ بـ «الجواب:».
    - إذا كان الطالب قد كتب حلاً في الصورة فراجعه وبيّن مكان الخطأ إن وُجد.
    - استخدم لغة المسألة نفسها (العربية افتراضياً)، ورموزاً رياضية نصية بسيطة مثل x² و √ و ÷ بدل LaTeX.
    - إذا لم تكن الصورة مسألة، صف ما فيها باختصار واطلب من الطالب تحديد المسألة.
    """

    static func solve(_ image: UIImage) async throws -> String {
        guard let jpeg = image.jpegData(compressionQuality: 0.85) else { throw AIAssistant.Failure.empty }
        return try await AIAssistant.ask(system: system,
                                         turns: [.init(role: .user, text: "حل هذه المسألة واشرح الخطوات.")],
                                         images: [jpeg],
                                         maxTokens: 4096)
    }

    /// سؤال متابعة عن نفس المسألة.
    static func followUp(_ image: UIImage, history: [AIAssistant.Turn]) async throws -> String {
        guard let jpeg = image.jpegData(compressionQuality: 0.85) else { throw AIAssistant.Failure.empty }
        return try await AIAssistant.ask(system: system, turns: history, images: [jpeg], maxTokens: 4096)
    }
}

struct MathSolverView: View {
    let problem: MathProblem
    /// يدرج الحل كنص داخل الصفحة تحت المسألة
    var onInsert: ((String) -> Void)?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var theme

    @State private var turns: [AIAssistant.Turn] = []
    @State private var working = false
    @State private var error: String?
    @State private var question = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Image(uiImage: problem.image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 180)
                        .frame(maxWidth: .infinity)
                        .padding(10)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(theme.border))

                    ForEach(Array(turns.enumerated()), id: \.offset) { index, turn in
                        if index > 0 || turn.role == .assistant {
                            bubble(turn)
                        }
                    }

                    if working {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("\(AIAssistant.providerName) يحل المسألة…")
                                .foregroundStyle(theme.secondaryText)
                        }
                        .padding(.vertical, 8)
                    }
                    if let error {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.inter(.callout))
                        Button("إعادة المحاولة") { start() }
                            .buttonStyle(.bordered)
                    }
                }
                .padding(18)
            }
            .safeAreaInset(edge: .bottom) {
                if !turns.isEmpty { askBar }
            }
            .background(theme.background.ignoresSafeArea())
            .navigationTitle("حل المسألة")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("إغلاق") { dismiss() }
                        .accessibilityIdentifier("mathClose")
                }
                if let onInsert, let answer = turns.last(where: { $0.role == .assistant })?.text {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            onInsert(answer)
                            dismiss()
                        } label: {
                            Label("أضف للصفحة", systemImage: "text.badge.plus")
                        }
                    }
                }
            }
        }
        .environment(\.layoutDirection, .rightToLeft)
        .accessibilityIdentifier("mathSheet")
        .onAppear { if turns.isEmpty && !working { start() } }
    }

    private func bubble(_ turn: AIAssistant.Turn) -> some View {
        let mine = turn.role == .user
        return Text(markdownText(turn.text))
            .font(.inter(.body))
            .foregroundStyle(mine ? Color.white : theme.primaryText)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(mine ? theme.accent : theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .environment(\.layoutDirection,
                         OnDeviceStudyGenerator.isMostlyArabic(turn.text) ? .rightToLeft : .leftToRight)
    }

    private var askBar: some View {
        HStack(spacing: 10) {
            TextField("اسأل عن الحل…", text: $question, axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.roundedBorder)
                .submitLabel(.send)
                .onSubmit(send)
            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill").font(.system(size: 30))
            }
            .disabled(working || question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(12)
        .background(.bar)
    }

    private func start() {
        error = nil
        working = true
        Task {
            do {
                let answer = try await MathSolver.solve(problem.image)
                await MainActor.run {
                    turns = [.init(role: .user, text: "حل هذه المسألة واشرح الخطوات."),
                             .init(role: .assistant, text: answer)]
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

    private func send() {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !working else { return }
        question = ""
        let history = turns + [.init(role: .user, text: text)]
        turns = history
        error = nil
        working = true
        Task {
            do {
                let answer = try await MathSolver.followUp(problem.image, history: history)
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
