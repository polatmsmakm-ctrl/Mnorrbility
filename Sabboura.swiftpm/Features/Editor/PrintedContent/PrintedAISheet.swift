import SwiftUI

/// حالة طلب الذكاء الاصطناعي على مقتطف مطبوع.
final class PrintedAIModel: ObservableObject {
    enum Phase {
        case needsKey
        case loading
        case done(String)
        case failed(String)
    }

    @Published private(set) var phase: Phase
    let request: PrintedAIRequest
    private var work: Task<Void, Never>?

    init(request: PrintedAIRequest) {
        self.request = request
        phase = PrintedAIService.isAvailable ? .loading : .needsKey
    }

    func start() {
        guard PrintedAIService.isAvailable else {
            phase = .needsKey
            return
        }
        phase = .loading
        work?.cancel()
        let request = self.request
        work = Task { [weak self] in
            let outcome: Result<String, Error>
            do {
                outcome = .success(try await PrintedAIService.run(request))
            } catch {
                outcome = .failure(error)
            }
            let cancelled = Task.isCancelled
            await MainActor.run {
                guard let self, !cancelled else { return }
                switch outcome {
                case .success(let text):
                    self.phase = .done(text)
                    if request.task == .latex {
                        UIPasteboard.general.string = text
                    }
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                case .failure(let error):
                    let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    self.phase = .failed(message)
                    UINotificationFeedbackGenerator().notificationOccurred(.error)
                }
            }
        }
    }

    func cancel() {
        work?.cancel()
        work = nil
    }
}

/// نافذة نتيجة الذكاء الاصطناعي: ترجمة المقتطف، أو شرح المعادلة، أو كود LaTeX — مع النسخ والإدراج في الصفحة.
struct PrintedAISheet: View {
    let request: PrintedAIRequest
    @ObservedObject var controller: EditorController
    @StateObject private var model: PrintedAIModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.appTheme) private var theme
    @State private var keyInput = ""
    @State private var copied = false
    @FocusState private var keyFocused: Bool

    init(request: PrintedAIRequest, controller: EditorController) {
        self.request = request
        self.controller = controller
        _model = StateObject(wrappedValue: PrintedAIModel(request: request))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    snippet
                    content
                }
                .padding(20)
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom) { actions }
            .navigationTitle(request.task.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("إغلاق") { dismiss() }
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("تم") { keyFocused = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .tint(theme.accent)
        .environment(\.layoutDirection, .rightToLeft)
        .onAppear {
            if case .loading = model.phase { model.start() }
        }
        .onDisappear { model.cancel() }
    }

    // MARK: المقتطف

    private var snippet: some View {
        Image(uiImage: request.image)
            .resizable()
            .scaledToFit()
            .frame(maxHeight: 130)
            .padding(8)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.primary.opacity(0.12), lineWidth: 1)
            )
            .frame(maxWidth: .infinity)
            .accessibilityLabel("المقتطف المحدد")
    }

    // MARK: المحتوى

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .needsKey:
            keyForm
        case .loading:
            HStack(spacing: 12) {
                ProgressView()
                Text(request.task.loadingText)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 120)
        case .done(let text):
            result(text)
        case .failed(let message):
            VStack(spacing: 14) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                Button {
                    model.start()
                } label: {
                    Label("إعادة المحاولة", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity, minHeight: 120)
        }
    }

    @ViewBuilder
    private func result(_ text: String) -> some View {
        if request.task == .latex {
            VStack(alignment: .leading, spacing: 10) {
                Text(text)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(Color(.secondarySystemBackground),
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .environment(\.layoutDirection, .leftToRight)
                Label("نُسخ الكود للحافظة — الصقه في أي محرر LaTeX", systemImage: "checkmark.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(.green)
            }
        } else {
            let leftToRight = PrintedMath.arabicRatio(text) < 0.3
            Text(markdownText(text))
                .font(.body)
                .lineSpacing(6)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .environment(\.layoutDirection, leftToRight ? .leftToRight : .rightToLeft)
        }
    }

    private var keyForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("يحتاج مفتاح Gemini المجاني", systemImage: "key.fill")
                .font(.headline)
            Text("الترجمة والشرح وتحويل LaTeX تتم عبر المحرّك المختار في «المراجعة الذكية» (Gemini المجاني أو Claude). الصق مفتاح Gemini هنا، ويُحفظ على جهازك فقط.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button {
                openURL(GeminiStudyGenerator.keyPage)
            } label: {
                Label("احصل على مفتاح مجاني من Google AI Studio", systemImage: "arrow.up.forward.square")
            }
            SecureField("الصق المفتاح هنا (AIza…)", text: $keyInput)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($keyFocused)
                .submitLabel(.done)
                .onSubmit(saveKey)
                .padding(12)
                .background(Color(.secondarySystemBackground),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .environment(\.layoutDirection, .leftToRight)
            Button("حفظ ومتابعة", action: saveKey)
                .buttonStyle(.borderedProminent)
                .disabled(keyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    // MARK: الأزرار

    @ViewBuilder
    private var actions: some View {
        switch model.phase {
        case .done(let text):
            HStack(spacing: 12) {
                Button {
                    UIPasteboard.general.string = text.replacingOccurrences(of: "**", with: "")
                    copied = true
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                } label: {
                    Label(copied ? "نُسخ" : "نسخ", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                if request.task != .latex {
                    Button {
                        controller.insertPrintedAIResult(text, for: request)
                        dismiss()
                    } label: {
                        Label("إدراج في الصفحة", systemImage: "text.badge.plus")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .controlSize(.large)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.bar)
        default:
            EmptyView()
        }
    }

    private func saveKey() {
        let trimmed = keyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        PrintedAIService.saveGeminiKey(trimmed)
        ReviewSettings.provider = .gemini
        keyInput = ""
        keyFocused = false
        model.start()
    }
}
