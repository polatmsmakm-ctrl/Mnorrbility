import CoreData
import SwiftUI

/// الإعدادات: المظهر، محرر الملاحظات، المحذوفة مؤخراً، حول التطبيق.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var theme

    enum Page: String, CaseIterable, Identifiable {
        case appearance, editor, trash, about
        var id: String { rawValue }
        var title: String {
            switch self {
            case .appearance: return "المظهر"
            case .editor: return "محرر الملاحظات"
            case .trash: return "المحذوفة مؤخراً"
            case .about: return "حول التطبيق"
            }
        }
        var symbol: String {
            switch self {
            case .appearance: return "paintbrush"
            case .editor: return "pencil.and.outline"
            case .trash: return "trash"
            case .about: return "info.circle"
            }
        }
    }

    @State private var page: Page? = AppEnvironment.isPad ? .appearance : nil

    var body: some View {
        NavigationSplitView {
            List(Page.allCases, selection: $page) { item in
                Label(item.title, systemImage: item.symbol)
                    .foregroundStyle(theme.primaryText)
                    .tag(item)
                    .accessibilityIdentifier("settings.\(item.rawValue)")
            }
            .scrollContentBackground(.hidden)
            .background(theme.sidebar)
            .navigationTitle("الإعدادات")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("إغلاق") { dismiss() }
                        .accessibilityIdentifier("closeSettings")
                }
            }
        } detail: {
            Group {
                switch page {
                case .appearance: AppearanceSettingsView()
                case .editor: EditorSettingsView()
                case .trash: TrashView()
                case .about: AboutView()
                case .none: AppearanceSettingsView()
                }
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("إغلاق") { dismiss() }
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .environment(\.layoutDirection, .rightToLeft)
    }
}

// MARK: - المظهر

struct AppearanceSettingsView: View {
    @EnvironmentObject private var settings: ThemeSettings
    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                group {
                    toggleRow("مطابقة مظهر الجهاز", isOn: $settings.matchSystem, id: "matchSystem")
                    Divider().overlay(theme.border)
                    toggleRow("المحتوى يطابق الثيم", isOn: $settings.contentMatchesTheme, id: "contentMatches")
                }
                if !settings.matchSystem {
                    group {
                        Picker("الوضع", selection: $settings.preferDark) {
                            Text("داكن").tag(true)
                            Text("فاتح").tag(false)
                        }
                        .pickerStyle(.segmented)
                        .padding(14)
                        .accessibilityIdentifier("darkLightPicker")
                    }
                }
                group {
                    toggleRow("مجلدات ملوّنة", isOn: $settings.colorfulFolders, id: "colorfulFolders")
                }
                VStack(alignment: .leading, spacing: 6) {
                    group {
                        toggleRow("إبقاء الشاشة مضاءة", isOn: $settings.keepAwake, id: "keepAwake")
                    }
                    Text("يتجاهل التطبيق مؤقت قفل الشاشة عند التفعيل.")
                        .font(.caption)
                        .foregroundStyle(theme.secondaryText)
                        .padding(.horizontal, 6)
                }

                Text("الثيمات الداكنة").font(.headline).foregroundStyle(theme.primaryText)
                themeRow(AppTheme.darkThemes)
                Text("الثيمات الفاتحة").font(.headline).foregroundStyle(theme.primaryText)
                themeRow(AppTheme.lightThemes)
            }
            .padding(22)
        }
        .background(theme.background.ignoresSafeArea())
        .navigationTitle("المظهر")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func group<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) { content() }
            .background(theme.card, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(theme.border, lineWidth: 1))
    }

    private func toggleRow(_ title: String, isOn: Binding<Bool>, id: String) -> some View {
        Toggle(isOn: isOn) {
            Text(title).foregroundStyle(theme.primaryText)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .accessibilityIdentifier(id)
    }

    private func themeRow(_ themes: [AppTheme]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 18) {
                ForEach(themes) { item in
                    Button {
                        settings.select(item)
                    } label: {
                        VStack(spacing: 10) {
                            ThemePreview(theme: item, selected: isChosen(item))
                            Text(item.title)
                                .font(.subheadline)
                                .foregroundStyle(theme.primaryText)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("theme.\(item.rawValue)")
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func isChosen(_ item: AppTheme) -> Bool {
        item.isDark ? settings.darkTheme == item : settings.lightTheme == item
    }
}

/// معاينة مصغّرة لثيم (مثل شاشة التطبيق).
struct ThemePreview: View {
    let theme: AppTheme
    let selected: Bool

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 9) {
                ForEach(0..<3, id: \.self) { _ in
                    HStack(spacing: 6) {
                        Circle().fill(theme.accent).frame(width: 12, height: 12)
                        Capsule().fill(theme.secondaryText.opacity(0.5)).frame(width: 36, height: 6)
                    }
                }
                Spacer()
            }
            .padding(.top, 34)
            .padding(.horizontal, 10)
            .frame(width: 76, height: 130)
            .background(theme.sidebar)
            ZStack(alignment: .topTrailing) {
                theme.background
                RoundedRectangle(cornerRadius: 4).fill(theme.accent)
                    .frame(width: 36, height: 14)
                    .padding(8)
            }
            .frame(width: 104, height: 130)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(selected ? theme.accent : theme.border, lineWidth: selected ? 3 : 1))
        .overlay(alignment: .bottomTrailing) {
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 22))
                .foregroundStyle(selected ? theme.accent : theme.secondaryText)
                .background(Circle().fill(theme.background))
                .padding(8)
        }
        .environment(\.layoutDirection, .leftToRight)
    }
}

// MARK: - المحرر

struct EditorSettingsView: View {
    @Environment(\.appTheme) private var theme
    @AppStorage("sabboura.editor.seamless") private var seamless = true
    @AppStorage("sabboura.editor.statusBar") private var statusBar = false
    @AppStorage("sabboura.fingerDrawing") private var fingerDrawing = true
    @State private var template = PageTemplate.savedDefault

    var body: some View {
        Form {
            Section("طريقة العرض") {
                Picker("العرض", selection: $seamless) {
                    Text("متصل (تمرير متواصل)").tag(true)
                    Text("صفحة واحدة").tag(false)
                }
                Toggle("إظهار شريط الحالة أثناء الكتابة", isOn: $statusBar)
            }
            Section {
                Toggle("الكتابة بالإصبع وبأي قلم", isOn: $fingerDrawing)
            } header: {
                Text("الكتابة")
            } footer: {
                Text("عند الإيقاف يكتب قلم أبل فقط ويصبح الإصبع للتمرير والتكبير (رفض كامل لراحة اليد). يمكن تغييرها أيضاً من زر اليد في شريط الأدوات.")
            }
            Section("الورقة الافتراضية للصفحات الجديدة") {
                Picker("نوع الورقة", selection: $template.kind) {
                    ForEach(BackgroundKind.allCases) { kind in
                        Text(kind.title).tag(kind)
                    }
                }
                Picker("اللون", selection: Binding(
                    get: { template.backgroundHex },
                    set: { newValue in
                        if let preset = BoardPreset.all.first(where: { $0.backgroundHex == newValue }) {
                            template.backgroundHex = preset.backgroundHex
                            template.lineHex = preset.lineHex
                        }
                    }
                )) {
                    ForEach(BoardPreset.all) { preset in
                        Text(preset.name).tag(preset.backgroundHex)
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(theme.background.ignoresSafeArea())
        .navigationTitle("محرر الملاحظات")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: template) { _, newValue in
            newValue.saveAsDefault()
        }
    }
}

// MARK: - المحذوفة مؤخراً

struct TrashView: View {
    @Environment(\.managedObjectContext) private var context
    @Environment(\.appTheme) private var theme

    @FetchRequest(fetchRequest: CDNote.trashRequest(), animation: .default)
    private var trashed: FetchedResults<CDNote>

    @State private var confirmEmpty = false

    var body: some View {
        List {
            if trashed.filter(\.isAlive).isEmpty {
                Text("لا توجد ملاحظات محذوفة")
                    .foregroundStyle(theme.secondaryText)
            } else {
                Section {
                    ForEach(trashed.filter(\.isAlive), id: \.objectID) { note in
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(note.displayTitle).foregroundStyle(theme.primaryText)
                                if let deleted = note.deletedAt {
                                    Text("تُحذف نهائياً بعد \(max(0, 30 - (Calendar.current.dateComponents([.day], from: deleted, to: Date()).day ?? 0))) يوماً")
                                        .font(.caption)
                                        .foregroundStyle(theme.secondaryText)
                                }
                            }
                            Spacer()
                            Button("استرجاع") {
                                DataStore.restore(note, context: context)
                            }
                            .buttonStyle(.bordered)
                            .accessibilityIdentifier("restoreNote")
                        }
                        .swipeActions {
                            Button(role: .destructive) {
                                DataStore.deletePermanently([note], context: context)
                            } label: {
                                Label("حذف نهائياً", systemImage: "trash")
                            }
                        }
                    }
                } footer: {
                    Text("تبقى الملاحظات هنا 30 يوماً ثم تُحذف تلقائياً.")
                }
                Section {
                    Button("إفراغ المحذوفة", role: .destructive) { confirmEmpty = true }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(theme.background.ignoresSafeArea())
        .navigationTitle("المحذوفة مؤخراً")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("حذف كل الملاحظات نهائياً؟", isPresented: $confirmEmpty, titleVisibility: .visible) {
            Button("حذف نهائياً", role: .destructive) {
                DataStore.deletePermanently(Array(trashed.filter(\.isAlive)), context: context)
            }
        }
    }
}

// MARK: - حول

struct AboutView: View {
    @Environment(\.appTheme) private var theme

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "الإصدار \(short) (\(build))"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Image(systemName: "pencil.and.scribble")
                    .font(.system(size: 56))
                    .foregroundStyle(theme.accent)
                    .padding(.top, 30)
                Text("Mnorrbility")
                    .font(.largeTitle.weight(.heavy))
                    .foregroundStyle(theme.primaryText)
                Text(version)
                    .foregroundStyle(theme.secondaryText)
                Text("من إعداد وتطوير راشد الشمري")
                    .font(.headline)
                    .foregroundStyle(theme.primaryText)
                VStack(alignment: .leading, spacing: 10) {
                    feature("pencil.tip", "كتابة بقلم أبل وبالإصبع وبأي قلم عبر PencilKit")
                    feature("doc.richtext", "استيراد PDF والكتابة عليه وتصديره")
                    feature("moon.stars", "وضع داكن كامل يشمل الصفحات والحبر")
                    feature("timer", "جلسات مذاكرة بمؤقت دراسة واستراحة")
                    feature("lock.shield", "كل البيانات محفوظة على جهازك فقط")
                }
                .padding(20)
                .background(theme.card, in: RoundedRectangle(cornerRadius: 14))
            }
            .padding(24)
        }
        .background(theme.background.ignoresSafeArea())
        .navigationTitle("حول التطبيق")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func feature(_ symbol: String, _ text: String) -> some View {
        Label {
            Text(text).foregroundStyle(theme.primaryText)
        } icon: {
            Image(systemName: symbol).foregroundStyle(theme.accent)
        }
    }
}
