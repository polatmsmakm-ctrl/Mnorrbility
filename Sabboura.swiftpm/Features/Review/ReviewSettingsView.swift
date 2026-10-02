import SwiftUI

/// إعدادات «المراجعة الذكية»: التوليد التلقائي، ومن يولّد الأسئلة (على الجهاز، Gemini المجاني، أو Claude).
struct ReviewSettingsView: View {
    @Environment(\.appTheme) private var theme
    @Environment(\.openURL) private var openURL
    @AppStorage("sabboura.review.auto") private var autoGenerate = true
    @AppStorage("sabboura.review.model") private var claudeModel = ReviewSettings.fastModel
    @AppStorage("sabboura.review.geminiLite") private var geminiLite = false

    @State private var provider = ReviewSettings.provider
    @State private var geminiInput = ""
    @State private var claudeInput = ""
    @State private var hasGeminiKey = ReviewSettings.hasGeminiKey
    @State private var hasClaudeKey = ReviewSettings.hasClaudeKey
    @State private var checking = false
    @State private var checkResult: String?

    var body: some View {
        Form {
            Section {
                Toggle("تجهيز البطاقات والكويز تلقائياً", isOn: $autoGenerate)
                    .accessibilityIdentifier("reviewAutoToggle")
            } footer: {
                Text("كل ما تغيّرت مذكرة أو استوردت ملف PDF، يقرأها التطبيق ويطلع منها ملخص وبطاقات حفظ وكويز لأهم النقاط. تلقاها من زر «مراجعة» داخل المذكرة.")
            }

            Section {
                providerRow(.gemini, title: "Gemini — مجاني", subtitle: "من Google بمفتاحك المجاني، يقرأ خط اليد والصور", symbol: "sparkles")
                providerRow(.onDevice, title: "على الجهاز", subtitle: "بدون إنترنت، والمذكرة ما تطلع من جهازك", symbol: "iphone")
                providerRow(.claude, title: "Claude", subtitle: "الأدق، بمفتاح مدفوع من Anthropic", symbol: "brain.head.profile")
            } header: {
                Text("من يطلّع الأسئلة؟")
            } footer: {
                Text("إذا ما فيه إنترنت أو تعذّرت الخدمة، يرجع التطبيق تلقائياً للتوليد على الجهاز.")
            }

            switch provider {
            case .gemini: geminiSection
            case .claude: claudeSection
            case .onDevice: onDeviceSection
            }
        }
        .scrollContentBackground(.hidden)
        .background(theme.background.ignoresSafeArea())
        .navigationTitle("المراجعة الذكية")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: اختيار المحرّك

    private func providerRow(_ value: ReviewProvider, title: String, subtitle: String, symbol: String) -> some View {
        Button {
            provider = value
            ReviewSettings.provider = value
            checkResult = nil
        } label: {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.title3)
                    .foregroundStyle(theme.accent)
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(theme.primaryText)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if provider == value {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(theme.accent)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("provider.\(value.rawValue)")
        .accessibilityAddTraits(provider == value ? .isSelected : [])
    }

    // MARK: Gemini

    @ViewBuilder
    private var geminiSection: some View {
        Section {
            if hasGeminiKey {
                Label("المفتاح محفوظ على هذا الجهاز", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                Button("تحقق من المفتاح") { verifyGemini() }
                    .disabled(checking)
                Button("حذف المفتاح", role: .destructive) {
                    KeychainStore.write(nil, for: KeychainStore.geminiKey)
                    hasGeminiKey = false
                    checkResult = nil
                }
            } else {
                Button {
                    openURL(GeminiStudyGenerator.keyPage)
                } label: {
                    Label("احصل على مفتاح مجاني من Google AI Studio", systemImage: "key.fill")
                }
                .accessibilityIdentifier("geminiGetKey")
                SecureField("الصق المفتاح هنا (AIza…)", text: $geminiInput)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("geminiKeyField")
                Button("حفظ المفتاح") {
                    let trimmed = geminiInput.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    KeychainStore.write(trimmed, for: KeychainStore.geminiKey)
                    geminiInput = ""
                    hasGeminiKey = true
                    verifyGemini()
                }
                .disabled(geminiInput.trimmingCharacters(in: .whitespaces).isEmpty)
                .accessibilityIdentifier("geminiSaveKey")
            }
            Picker("النموذج", selection: $geminiLite) {
                Text("Flash — أدق").tag(false)
                Text("Flash-Lite — أسرع وحدّه المجاني أعلى").tag(true)
            }
            status
        } header: {
            Text("Gemini")
        } footer: {
            Text("""
            طريقة المفتاح المجاني: افتح الرابط وسجّل بحساب Google، اضغط «Create API key»، انسخ المفتاح والصقه هنا. ما يحتاج بطاقة.
            الخطة المجانية لها حد يومي للطلبات؛ إذا خلص يرجع التطبيق للتوليد على الجهاز ويرجع Gemini بعد ما يتجدد الحد.
            تنبيه: في الخطة المجانية قد تستخدم Google محتوى المذكرات المرسلة لتحسين خدماتها، فلا تستخدمه لمذكرات فيها معلومات خاصة. المفتاح يُحفظ مشفّراً في سلسلة مفاتيح الجهاز.
            """)
        }
    }

    // MARK: Claude

    @ViewBuilder
    private var claudeSection: some View {
        Section {
            if hasClaudeKey {
                Label("المفتاح محفوظ على هذا الجهاز", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                Button("تحقق من المفتاح") { verifyClaude() }
                    .disabled(checking)
                Button("حذف المفتاح", role: .destructive) {
                    KeychainStore.write(nil, for: KeychainStore.claudeKey)
                    hasClaudeKey = false
                    checkResult = nil
                }
            } else {
                SecureField("sk-ant-…", text: $claudeInput)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .environment(\.layoutDirection, .leftToRight)
                    .accessibilityIdentifier("claudeKeyField")
                Button("حفظ المفتاح") {
                    let trimmed = claudeInput.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    KeychainStore.write(trimmed, for: KeychainStore.claudeKey)
                    claudeInput = ""
                    hasClaudeKey = true
                    verifyClaude()
                }
                .disabled(claudeInput.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Picker("النموذج", selection: $claudeModel) {
                Text("Haiku 4.5 — أسرع وأرخص").tag(ReviewSettings.fastModel)
                Text("Sonnet 5 — أدق").tag(ReviewSettings.preciseModel)
            }
            status
        } header: {
            Text("Claude")
        } footer: {
            Text("مع مفتاح Claude API (من console.anthropic.com) تنرسل محتويات المذكرة وصور صفحاتها إلى Anthropic وقت التوليد فقط. التكلفة على حسابك وعادة أقل من سنت إلى بضع سنتات للمذكرة. المفتاح يُحفظ مشفّراً في سلسلة مفاتيح الجهاز.")
        }
    }

    // MARK: على الجهاز

    private var onDeviceSection: some View {
        Section {
            Label("بدون إنترنت ومجاني", systemImage: "iphone")
                .foregroundStyle(theme.primaryText)
        } footer: {
            Text("يقرأ النص المكتوب وملفات PDF، ويتعرّف على النص في الصور وخط اليد بقدر الإمكان، ثم يطلع ملخص بجمل كاملة ومصطلحات وبطاقات «أكمل الفراغ» وأسئلة اختيار من متعدد وصح أو خطأ.")
        }
    }

    @ViewBuilder
    private var status: some View {
        if checking {
            HStack {
                ProgressView()
                Text("جارٍ التحقق…")
            }
        } else if let checkResult {
            Text(checkResult)
                .font(.footnote)
                .foregroundStyle(theme.secondaryText)
                .accessibilityIdentifier("keyCheckResult")
        }
    }

    // MARK: التحقق

    private func verifyGemini() {
        guard let key = KeychainStore.read(KeychainStore.geminiKey) else { return }
        checking = true
        checkResult = nil
        let lite = geminiLite
        Task {
            do {
                let model = try await GeminiStudyGenerator.verify(key: key, lite: lite)
                checkResult = "المفتاح يعمل ✓ — النموذج: \(model)"
            } catch {
                checkResult = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            checking = false
        }
    }

    private func verifyClaude() {
        guard let key = KeychainStore.read(KeychainStore.claudeKey) else { return }
        checking = true
        checkResult = nil
        let model = claudeModel
        Task {
            do {
                try await ClaudeStudyGenerator.verify(key: key, model: model)
                checkResult = "المفتاح يعمل ✓"
            } catch {
                checkResult = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            checking = false
        }
    }
}
