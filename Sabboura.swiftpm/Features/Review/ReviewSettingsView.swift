import SwiftUI

/// إعدادات «المراجعة الذكية»: التوليد التلقائي ومفتاح Claude الاختياري.
struct ReviewSettingsView: View {
    @Environment(\.appTheme) private var theme
    @AppStorage("sabboura.review.auto") private var autoGenerate = true
    @AppStorage("sabboura.review.model") private var model = ReviewSettings.fastModel

    @State private var keyInput = ""
    @State private var hasKey = ReviewSettings.hasClaudeKey
    @State private var checking = false
    @State private var checkResult: String?

    var body: some View {
        Form {
            Section {
                Toggle("تجهيز البطاقات والكويز تلقائياً", isOn: $autoGenerate)
                    .accessibilityIdentifier("reviewAutoToggle")
            } footer: {
                Text("كل ما تغيّرت مذكرة أو استوردت ملف PDF، يقرأها التطبيق ويطلع منها بطاقات حفظ وكويز لأهم النقاط. تلقاها من زر «مراجعة» داخل المذكرة.")
            }

            Section {
                Label("بدون إنترنت ومجاني", systemImage: "iphone")
                    .foregroundStyle(theme.primaryText)
            } header: {
                Text("على الجهاز")
            } footer: {
                Text("يقرأ النص المكتوب وملفات PDF، ويتعرّف على النص في الصور وخط اليد بقدر الإمكان، ثم يطلع بطاقات «أكمل الفراغ» وتعريفات وأسئلة اختيار من متعدد وصح أو خطأ.")
            }

            Section {
                if hasKey {
                    Label("المفتاح محفوظ على هذا الجهاز", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                    Button("تحقق من المفتاح") { verify() }
                        .disabled(checking)
                    Button("حذف المفتاح", role: .destructive) {
                        KeychainStore.write(nil, for: KeychainStore.claudeKey)
                        hasKey = false
                        checkResult = nil
                    }
                } else {
                    SecureField("sk-ant-…", text: $keyInput)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .environment(\.layoutDirection, .leftToRight)
                        .accessibilityIdentifier("claudeKeyField")
                    Button("حفظ المفتاح") {
                        let trimmed = keyInput.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        KeychainStore.write(trimmed, for: KeychainStore.claudeKey)
                        keyInput = ""
                        hasKey = true
                        verify()
                    }
                    .disabled(keyInput.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Picker("النموذج", selection: $model) {
                    Text("Haiku 4.5 — أسرع وأرخص").tag(ReviewSettings.fastModel)
                    Text("Sonnet 5 — أدق").tag(ReviewSettings.preciseModel)
                }
                if checking {
                    HStack { ProgressView(); Text("جارٍ التحقق…") }
                } else if let checkResult {
                    Text(checkResult)
                        .font(.footnote)
                        .foregroundStyle(theme.secondaryText)
                }
            } header: {
                Text("Claude (اختياري — أدق، ويقرأ خط اليد العربي)")
            } footer: {
                Text("مع مفتاح Claude API (من console.anthropic.com) تنرسل محتويات المذكرة وصور صفحاتها إلى Anthropic وقت التوليد فقط، وتطلع أسئلة أدق حتى من خط اليد. التكلفة على حسابك وعادة أقل من سنت إلى بضع سنتات للمذكرة. المفتاح يُحفظ مشفّراً في سلسلة مفاتيح الجهاز.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(theme.background.ignoresSafeArea())
        .navigationTitle("المراجعة الذكية")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func verify() {
        guard let key = KeychainStore.read(KeychainStore.claudeKey) else { return }
        checking = true
        checkResult = nil
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
