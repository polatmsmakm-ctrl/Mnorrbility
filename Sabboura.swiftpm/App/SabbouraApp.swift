import CoreData
import SwiftUI
import UniformTypeIdentifiers

@main
struct SabbouraApp: App {
    private let persistence: PersistenceController
    @StateObject private var themeSettings: ThemeSettings
    @StateObject private var study: StudySessionManager
    @StateObject private var appState = AppState()

    init() {
        AppEnvironment.prepare()
        CrashReporter.install()
        AppFont.registerBundledFonts()
        NotificationPresenter.shared.install()
        persistence = PersistenceController.shared
        _themeSettings = StateObject(wrappedValue: ThemeSettings.shared)
        _study = StateObject(wrappedValue: StudySessionManager.shared)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(\.managedObjectContext, persistence.viewContext)
                .environmentObject(themeSettings)
                .environmentObject(study)
                .environmentObject(appState)
                .preferredColorScheme(themeSettings.preferredScheme)
        }
    }
}

/// عناصر القائمة الجانبية.
enum SidebarItem: Hashable {
    case home
    case notes
    case gallery
    case folder(NSManagedObjectID)
}

/// تبويبات شاشة الملاحظات.
enum NotesTab: String, CaseIterable, Identifiable {
    case all
    case recents
    case favorites
    case unfiled

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "كل الملاحظات"
        case .recents: return "الأخيرة"
        case .favorites: return "المفضلة"
        case .unfiled: return "غير المصنفة"
        }
    }
}

/// حالة التنقّل العامة للتطبيق.
final class AppState: ObservableObject {
    @Published var selection: SidebarItem? = AppEnvironment.isPhone ? nil : .notes {
        didSet {
            guard oldValue != selection else { return }
            let name = selection.map { String(describing: $0) } ?? "nil"
            noteDebug("sel=" + String(name.prefix(14)))
            // عند الرجوع للتطبيق قد تعيد القائمة الجانبية تعيين الاختيار؛ هذا لا يجب أن يغلق المذكرة
            if !isResuming { path = [] }
        }
    }
    @Published var compactColumn: NavigationSplitViewColumn = .sidebar
    @Published var path: [CDNote] = [] {
        didSet {
            guard path.count != oldValue.count else { return }
            noteDebug("path=\(path.count)")
            // إغلاق غير مقصود أثناء الرجوع من الخلفية: نعيد فتح المذكرة نفسها
            if isResuming, path.isEmpty, let note = oldValue.last, note.isAlive {
                noteDebug("restore-note")
                DispatchQueue.main.async {
                    self.path = [note]
                }
                return
            }
        }
    }
    /// شاشة الكتابة تطلب إخفاء شريط الحالة (يُطبَّق من الجذر لأنه لا يعمل من داخل التنقّل)
    @Published var hideStatusBar = false
    @Published var columnVisibility: NavigationSplitViewVisibility = .all

    /// نحو ثانيتين بعد العودة من الخلفية نعتبر أي تغيّر في التنقّل ناتجاً عن النظام لا عن المستخدم.
    private(set) var isResuming = false
    private var resumeNote: CDNote?
    private var resumeTask: DispatchWorkItem?

    /// المستخدم أغلق المذكرة بنفسه (زر الرجوع): لا تُستعاد.
    func userClosedNote() {
        resumeNote = nil
    }

    func sceneWentInactive() {
        resumeTask?.cancel()
        isResuming = true
        resumeNote = path.last
    }

    func sceneBecameActive() {
        isResuming = true
        restoreIfNeeded()
        // النظام قد يعيد بناء التنقّل بعد لحظات؛ نتحقق مرة ثانية قبل إنهاء الحماية
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.restoreIfNeeded() }
        let work = DispatchWorkItem { [weak self] in self?.isResuming = false }
        resumeTask = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: work)
    }

    private func restoreIfNeeded() {
        guard let note = resumeNote, note.isAlive else { return }
        if path.last != note { path = [note] }
    }
    @Published var searchText = ""
    @Published var notesTab: NotesTab = .all
    @Published var showSettings = false
    @Published var showStudySetup = false

    /// سجل تنقّل مختصر يظهر لاختبارات الواجهة فقط (لتشخيص أي خلل في فتح المذكرات).
    @Published private(set) var debugLog = ""
    private var debugLines: [String] = []

    func noteDebug(_ event: String) {
        guard AppEnvironment.isUITest else { return }
        debugLines.append(event)
        if debugLines.count > 16 { debugLines.removeFirst(debugLines.count - 16) }
        let text = debugLines.joined(separator: " | ")
        DispatchQueue.main.async { self.debugLog = text }
    }

    func select(_ item: SidebarItem) {
        selection = item
        compactColumn = .detail
    }

    /// يفتح مذكرة من أي مكان (البحث، الرئيسية، المعرض، ملف PDF وارد).
    func open(_ note: CDNote) {
        if selection == nil { selection = .notes }
        compactColumn = .detail
        path = [note]
    }

    /// يفتح مذكرة أُنشئت للتو من قائمة: ننتظر انتهاء إغلاق القائمة قبل الانتقال،
    /// لأن الانتقال أثناء حركة الإغلاق يُتجاهل أحياناً.
    func openAfterMenu(_ note: CDNote) {
        noteDebug("open-after-menu")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self, note.isAlive else { return }
            if self.path.last != note {
                self.path.append(note)
            }
        }
    }
}

/// الهيكل الرئيسي: قائمة جانبية على اليسار + منطقة الملاحظات والكتابة.
/// على الآيفون يتحول تلقائياً إلى تنقّل متدرّج.
struct RootView: View {
    @Environment(\.managedObjectContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var themeSettings: ThemeSettings
    @EnvironmentObject private var study: StudySessionManager

    var body: some View {
        ThemedContainer {
            NavigationSplitView(columnVisibility: $appState.columnVisibility,
                                preferredCompactColumn: $appState.compactColumn) {
                SidebarView()
                    .navigationSplitViewColumnWidth(min: 270, ideal: 300, max: 380)
                    .environment(\.layoutDirection, .rightToLeft)
            } detail: {
                DetailRootView()
                    .environment(\.layoutDirection, .rightToLeft)
            }
            .navigationSplitViewStyle(.balanced)
            // القائمة الجانبية تبقى على اليسار كما هو مطلوب، والمحتوى الداخلي بالعربية
            .environment(\.layoutDirection, .leftToRight)
            .overlay {
                if AppEnvironment.isPad { PadEditorLayer() }
            }
            .overlay(alignment: .bottom) {
                StudyTimerPill()
                    .padding(.bottom, 18)
                    .environment(\.layoutDirection, .rightToLeft)
            }
            .overlay(alignment: .top) {
                StudyEndBanner()
                    .environment(\.layoutDirection, .rightToLeft)
            }
            .overlay(alignment: .bottomLeading) {
                if AppEnvironment.isUITest {
                    Text(appState.debugLog.isEmpty ? "-" : appState.debugLog)
                        .font(.system(size: 2))
                        .frame(width: 4, height: 4)
                        .opacity(0.03)
                        .allowsHitTesting(false)
                        .accessibilityIdentifier("debugLog")
                }
            }
            .sheet(isPresented: $appState.showSettings) {
                ThemedContainer {
                    SettingsView()
                }
                .environment(\.managedObjectContext, context)
                .environmentObject(themeSettings)
                .environmentObject(appState)
                .environmentObject(study)
                .environment(\.layoutDirection, .rightToLeft)
            }
            .sheet(isPresented: $appState.showStudySetup) {
                ThemedContainer {
                    StudySetupView()
                }
                .environmentObject(themeSettings)
                .environmentObject(study)
                .environment(\.layoutDirection, .rightToLeft)
            }
        }
        .statusBarHidden(appState.hideStatusBar)
        .task {
            DataStore.seedIfNeeded(context)
            DataStore.purgeOldTrash(context)
            themeSettings.applyKeepAwake()
            study.refresh()
            // المذكرات التي تغيّرت ولم تُجهَّز مراجعتها بعد
            if !AppEnvironment.isUITest {
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                StudyService.shared.sweep()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                appState.sceneWentInactive()
                NotificationCenter.default.post(name: .sabbouraFlushRequested, object: nil)
                DataStore.save(context)
            } else {
                appState.sceneBecameActive()
                study.refresh()
            }
        }
        .onOpenURL { url in
            openIncomingFile(url)
        }
    }

    /// ملف PDF أو صورة مشاركة من تطبيق آخر («فتح في سبّورة») تتحول إلى مذكرة.
    private func openIncomingFile(_ url: URL) {
        let granted = url.startAccessingSecurityScopedResource()
        defer { if granted { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return }
        let name = url.lastPathComponent
        let pdfData = name.lowercased().hasSuffix(".pdf") ? data : DataStore.pdfData(fromImageData: data)
        guard let pdfData,
              let note = DataStore.createNote(fromPDF: pdfData, fileName: name, in: nil, context: context) else { return }
        appState.selection = .notes
        appState.open(note)
        StudyService.shared.noteDidChange(note, delay: 2)
    }
}

/// عمود التفاصيل حسب العنصر المختار في القائمة الجانبية.
struct DetailRootView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.managedObjectContext) private var context
    @Environment(\.appTheme) private var theme
    /// على الآيباد تُعرض المذكرة من الطبقة العليا، فلا ندفعها داخل هذا التنقّل أبداً
    @State private var unusedPadPath: [CDNote] = []

    var body: some View {
        NavigationStack(path: AppEnvironment.isPad ? $unusedPadPath : $appState.path) {
            ZStack {
                switch appState.selection {
                case .home:
                    HomeView()
                case .gallery:
                    GalleryView()
                case .folder(let id):
                    if let subject = try? context.existingObject(with: id) as? CDSubject, subject.isAlive {
                        NotesBrowserView(folder: subject)
                            .id(id)
                    } else {
                        NotesBrowserView(folder: nil)
                    }
                case .notes, .none:
                    NotesBrowserView(folder: nil)
                }
            }
            .navigationDestination(for: CDNote.self) { note in
                if note.isAlive {
                    EditorView(note: note)
                        .id(note.objectID)
                } else {
                    ContentUnavailableView("المذكرة غير موجودة", systemImage: "exclamationmark.triangle")
                }
            }
        }
        .background(theme.background.ignoresSafeArea())
    }
}


/// الآيباد: المذكرة المفتوحة تظهر فوق القائمة والمعرض بحركة تكبير ناعمة مع تلاشٍ (دخول وخروج).
struct PadEditorLayer: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.appTheme) private var theme

    var body: some View {
        ZStack {
            if let note = appState.path.last, note.isAlive {
                EditorView(note: note)
                    .id(note.objectID)
                    .environment(\.layoutDirection, .rightToLeft)
                    .background(theme.desk.ignoresSafeArea())
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.94)),
                        removal: .opacity.combined(with: .scale(scale: 1.05))))
            }
        }
        .animation(.spring(response: 0.42, dampingFraction: 0.9), value: appState.path.last?.objectID)
    }
}
