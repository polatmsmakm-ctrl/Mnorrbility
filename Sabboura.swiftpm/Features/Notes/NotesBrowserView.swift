import CoreData
import SwiftUI
import UniformTypeIdentifiers

/// طريقة عرض الملاحظات وترتيبها (تُحفظ).
enum NotesViewMode: String, CaseIterable, Identifiable {
    case grid, list
    var id: String { rawValue }
    var title: String { self == .grid ? "شبكة" : "قائمة" }
    var symbol: String { self == .grid ? "square.grid.2x2" : "list.bullet" }
}

enum NotesSort: String, CaseIterable, Identifiable {
    case modified, created, title
    var id: String { rawValue }
    var title: String {
        switch self {
        case .modified: return "تاريخ التعديل"
        case .created: return "تاريخ الإنشاء"
        case .title: return "العنوان"
        }
    }
}

/// شاشة الملاحظات: كل الملاحظات بتبويبات، أو ملاحظات مجلد واحد.
struct NotesBrowserView: View {
    let folder: CDSubject?

    @Environment(\.managedObjectContext) private var context
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var themeSettings: ThemeSettings
    @Environment(\.appTheme) private var theme

    @FetchRequest(fetchRequest: CDNote.liveRequest(), animation: .default)
    private var notes: FetchedResults<CDNote>
    @FetchRequest(fetchRequest: CDSubject.sortedRequest()) private var folders: FetchedResults<CDSubject>

    @AppStorage("sabboura.notes.viewMode") private var viewModeRaw = NotesViewMode.grid.rawValue
    @AppStorage("sabboura.notes.sort") private var sortRaw = NotesSort.modified.rawValue

    @State private var isSelecting = false
    @State private var selected: Set<NSManagedObjectID> = []
    @State private var renameTarget: CDNote? = nil
    @State private var renameText = ""
    @State private var trashTarget: [CDNote] = []
    @State private var showPDFImporter = false
    @State private var folderSheet: SubjectSheetTarget? = nil
    @State private var confirmDeleteFolder = false

    private var viewMode: NotesViewMode { NotesViewMode(rawValue: viewModeRaw) ?? .grid }
    private var sort: NotesSort { NotesSort(rawValue: sortRaw) ?? .modified }

    private var visibleNotes: [CDNote] {
        var result = notes.filter(\.isAlive)
        if let folder {
            result = result.filter { $0.subject == folder }
        } else {
            switch appState.notesTab {
            case .all:
                break
            case .recents:
                let limit = Date().addingTimeInterval(-14 * 24 * 3600)
                result = result.filter { ($0.lastOpenedAt ?? $0.updatedAt ?? .distantPast) > limit }
                result.sort { ($0.lastOpenedAt ?? .distantPast) > ($1.lastOpenedAt ?? .distantPast) }
                return result
            case .favorites:
                result = result.filter(\.isFavorite)
            case .unfiled:
                result = result.filter { $0.subject == nil || $0.subject?.isAlive == false }
            }
        }
        switch sort {
        case .modified:
            result.sort { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
        case .created:
            result.sort { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
        case .title:
            result.sort { $0.displayTitle.localizedStandardCompare($1.displayTitle) == .orderedAscending }
        }
        return result
    }

    private var title: String {
        if let folder { return folder.displayName }
        switch appState.notesTab {
        case .all: return "الملاحظات"
        case .recents: return "الأخيرة"
        case .favorites: return "المفضلة"
        case .unfiled: return "غير المصنفة"
        }
    }

    private var columns: [GridItem] {
        let minimum: CGFloat = AppEnvironment.isPhone ? 150 : 210
        return [GridItem(.adaptive(minimum: minimum, maximum: 300), spacing: AppEnvironment.isPhone ? 14 : 26)]
    }

    var body: some View {
        let items = visibleNotes
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                headerBlock
                if items.isEmpty {
                    emptyState
                } else if viewMode == .grid {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 26) {
                        ForEach(items, id: \.objectID) { note in
                            noteButton(note) { NoteCardView(note: note, isSelecting: isSelecting, isSelected: selected.contains(note.objectID)) }
                        }
                    }
                } else {
                    LazyVStack(spacing: 10) {
                        ForEach(items, id: \.objectID) { note in
                            noteButton(note) { NoteRowView(note: note, isSelecting: isSelecting, isSelected: selected.contains(note.objectID)) }
                        }
                    }
                }
            }
            .padding(.horizontal, AppEnvironment.isPhone ? 16 : 30)
            .padding(.top, 8)
            .padding(.bottom, isSelecting ? 90 : 40)
        }
        .background(theme.background.ignoresSafeArea())
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(theme.background, for: .navigationBar)
        .toolbar { toolbarContent }
        .safeAreaInset(edge: .bottom) {
            if isSelecting { selectionBar }
        }
        .fileImporter(isPresented: $showPDFImporter, allowedContentTypes: [.pdf], allowsMultipleSelection: false) { result in
            importPDF(result)
        }
        .alert("إعادة تسمية المذكرة",
               isPresented: Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })) {
            TextField("العنوان", text: $renameText)
            Button("حفظ") {
                let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                if let note = renameTarget, note.isAlive, !trimmed.isEmpty {
                    note.title = trimmed
                    note.updatedAt = Date()
                    DataStore.save(context)
                }
                renameTarget = nil
            }
            Button("إلغاء", role: .cancel) { renameTarget = nil }
        }
        .confirmationDialog("نقل إلى «المحذوفة مؤخراً»؟",
                            isPresented: Binding(get: { !trashTarget.isEmpty }, set: { if !$0 { trashTarget = [] } }),
                            titleVisibility: .visible) {
            Button("حذف", role: .destructive) {
                let targets = trashTarget
                appState.path.removeAll { targets.contains($0) }
                DataStore.moveToTrash(targets, context: context)
                trashTarget = []
                selected = []
                isSelecting = false
            }
        } message: {
            Text("يمكنك استرجاعها من الإعدادات خلال 30 يوماً.")
        }
        .confirmationDialog("حذف المجلد؟", isPresented: $confirmDeleteFolder, titleVisibility: .visible) {
            Button("حذف نهائياً", role: .destructive) {
                if let folder {
                    appState.selection = .notes
                    let target = folder
                    DispatchQueue.main.async { DataStore.deleteFolder(target, context: context) }
                }
            }
        } message: {
            Text("ستنتقل ملاحظاته إلى «المحذوفة مؤخراً».")
        }
        .sheet(item: $folderSheet) { target in
            ThemedContainer {
                SubjectEditorSheet(target: target)
            }
            .environment(\.managedObjectContext, context)
            .environmentObject(appState)
            .environmentObject(themeSettings)
        }
    }

    // MARK: العنوان والتبويبات

    private var headerBlock: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                if let folder {
                    Circle().fill(Color(hex: folder.colorValue)).frame(width: 18, height: 18)
                }
                Text(title)
                    .font(.system(size: AppEnvironment.isPhone ? 30 : 40, weight: .heavy))
                    .foregroundStyle(theme.primaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .accessibilityIdentifier("notesTitle")
            }
            if folder == nil {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 26) {
                        ForEach(NotesTab.allCases) { tab in
                            Button {
                                appState.notesTab = tab
                            } label: {
                                VStack(spacing: 6) {
                                    Text(tab.title)
                                        .font(.system(size: 17, weight: .semibold))
                                        .foregroundStyle(appState.notesTab == tab ? theme.primaryText : theme.secondaryText)
                                    Capsule()
                                        .fill(appState.notesTab == tab ? theme.accent : Color.clear)
                                        .frame(height: 3)
                                }
                                .fixedSize()
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("tab.\(tab.rawValue)")
                        }
                    }
                }
            }
        }
        .padding(.top, 6)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: appState.notesTab == .favorites && folder == nil ? "star" : "square.and.pencil")
                .font(.system(size: 44))
                .foregroundStyle(theme.secondaryText)
            Text(appState.notesTab == .favorites && folder == nil ? "لا توجد ملاحظات مفضلة" : "لا توجد ملاحظات بعد")
                .font(.title3.weight(.semibold))
                .foregroundStyle(theme.primaryText)
            Text("اضغط «جديد» لإنشاء مذكرة أو استيراد ملف PDF والكتابة عليه.")
                .font(.subheadline)
                .foregroundStyle(theme.secondaryText)
                .multilineTextAlignment(.center)
            HStack(spacing: 12) {
                Button {
                    createNote()
                } label: {
                    Label("إنشاء مذكرة", systemImage: "plus")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .background(theme.accent, in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("emptyNewNote")
                Button {
                    showPDFImporter = true
                } label: {
                    Label("فتح ملف PDF", systemImage: "doc.richtext")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(theme.accent)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .background(theme.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("emptyImportPDF")
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }

    // MARK: شريط الأدوات

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            if isSelecting {
                Button("تم") {
                    isSelecting = false
                    selected = []
                }
                .fontWeight(.semibold)
                .accessibilityIdentifier("doneSelecting")
            } else {
                optionsMenu
                newMenu
            }
        }
    }

    private var optionsMenu: some View {
        Menu {
            Picker(selection: $viewModeRaw) {
                ForEach(NotesViewMode.allCases) { mode in
                    Label(mode.title, systemImage: mode.symbol).tag(mode.rawValue)
                }
            } label: {
                Label("العرض (\(viewMode.title))", systemImage: viewMode.symbol)
            }
            .pickerStyle(.menu)

            Button {
                isSelecting = true
            } label: {
                Label("تحديد الملاحظات", systemImage: "checkmark.circle")
            }

            Picker(selection: $sortRaw) {
                ForEach(NotesSort.allCases) { option in
                    Text(option.title).tag(option.rawValue)
                }
            } label: {
                Label("الترتيب (\(sort.title))", systemImage: "arrow.up.arrow.down")
            }
            .pickerStyle(.menu)

            if let folder {
                Divider()
                Button {
                    folderSheet = .edit(folder)
                } label: {
                    Label("تعديل المجلد", systemImage: "pencil")
                }
                Button(role: .destructive) {
                    confirmDeleteFolder = true
                } label: {
                    Label("حذف المجلد", systemImage: "trash")
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 20))
                .foregroundStyle(theme.primaryText)
        }
        .accessibilityLabel("خيارات")
        .accessibilityIdentifier("notesOptions")
    }

    private var newMenu: some View {
        Menu {
            Button {
                createNote()
            } label: {
                Label("مذكرة جديدة", systemImage: "square.and.pencil")
            }
            Button {
                showPDFImporter = true
            } label: {
                Label("استيراد PDF والكتابة عليه", systemImage: "doc.richtext")
            }
            Divider()
            Button {
                appState.showStudySetup = true
            } label: {
                Label("جلسة مذاكرة", systemImage: "timer")
            }
        } label: {
            Label("جديد", systemImage: "plus")
                .font(.system(size: 17, weight: .semibold))
                .labelStyle(.titleAndIcon)
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(theme.accent, in: RoundedRectangle(cornerRadius: 10))
        }
        .accessibilityLabel("جديد")
        .accessibilityIdentifier("newButton")
    }

    // MARK: البطاقات

    private func noteButton<Content: View>(_ note: CDNote, @ViewBuilder content: () -> Content) -> some View {
        Button {
            if isSelecting {
                if selected.contains(note.objectID) {
                    selected.remove(note.objectID)
                } else {
                    selected.insert(note.objectID)
                }
            } else {
                appState.path.append(note)
            }
        } label: {
            content()
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("noteCard")
        .contextMenu {
            if !isSelecting { contextMenu(for: note) }
        }
    }

    @ViewBuilder
    private func contextMenu(for note: CDNote) -> some View {
        Button {
            DataStore.toggleFavorite(note, context: context)
        } label: {
            Label(note.isFavorite ? "إزالة من المفضلة" : "إضافة للمفضلة", systemImage: note.isFavorite ? "star.slash" : "star")
        }
        Button {
            renameText = note.titleText
            renameTarget = note
        } label: {
            Label("إعادة تسمية", systemImage: "pencil")
        }
        Menu {
            Button("غير مصنفة") {
                guard note.isAlive else { return }
                note.subject = nil
                DataStore.save(context)
            }
            ForEach(folders.filter { $0.isAlive && $0 != note.subject }, id: \.objectID) { other in
                Button(other.displayName) {
                    guard note.isAlive, other.isAlive else { return }
                    note.subject = other
                    DataStore.save(context)
                }
            }
        } label: {
            Label("نقل إلى مجلد", systemImage: "folder")
        }
        Button {
            guard note.isAlive else { return }
            DataStore.duplicateNote(note, context: context)
        } label: {
            Label("تكرار", systemImage: "plus.square.on.square")
        }
        Divider()
        Button(role: .destructive) {
            trashTarget = [note]
        } label: {
            Label("حذف", systemImage: "trash")
        }
    }

    private var selectionBar: some View {
        let chosen = notes.filter { selected.contains($0.objectID) && $0.isAlive }
        return HStack(spacing: 18) {
            Text("\(chosen.count) محددة")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(theme.primaryText)
            Spacer()
            Menu {
                Button("غير مصنفة") { move(chosen, to: nil) }
                ForEach(folders.filter(\.isAlive), id: \.objectID) { target in
                    Button(target.displayName) { move(chosen, to: target) }
                }
            } label: {
                Label("نقل", systemImage: "folder")
            }
            .disabled(chosen.isEmpty)
            Button {
                for note in chosen where !note.isFavorite { note.isFavorite = true }
                DataStore.save(context)
                isSelecting = false
                selected = []
            } label: {
                Label("مفضلة", systemImage: "star")
            }
            .disabled(chosen.isEmpty)
            Button(role: .destructive) {
                trashTarget = chosen
            } label: {
                Label("حذف", systemImage: "trash")
            }
            .disabled(chosen.isEmpty)
            .accessibilityIdentifier("deleteSelected")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(theme.card)
        .overlay(alignment: .top) { Rectangle().fill(theme.border).frame(height: 1) }
    }

    // MARK: إجراءات

    private func createNote() {
        let target = folder?.isAlive == true ? folder : nil
        let note = DataStore.createNote(in: target, title: DataStore.defaultNoteTitle(), context: context)
        appState.openAfterMenu(note)
    }

    private func importPDF(_ result: Result<[URL], Error>) {
        guard let file = FileImportReader.read(result).first else { return }
        let target = folder?.isAlive == true ? folder : nil
        if let note = DataStore.createNote(fromPDF: file.data, fileName: file.name, in: target, context: context) {
            appState.path.append(note)
        }
    }

    private func move(_ notes: [CDNote], to target: CDSubject?) {
        for note in notes where note.isAlive {
            note.subject = target?.isAlive == true ? target : nil
        }
        DataStore.save(context)
        isSelecting = false
        selected = []
    }
}

// MARK: - بطاقة مذكرة

struct NoteThumbnail: View {
    @ObservedObject var note: CDNote
    @Environment(\.appTheme) private var theme
    @Environment(\.contentDark) private var contentDark

    @State private var image: UIImage? = nil

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else {
                Color(hex: contentDark ? theme.darkPaperHex : "#FFFFFF")
            }
        }
        .clipped()
        .task(id: renderKey) {
            guard note.isAlive else { return }
            if let cached = ThumbnailCache.shared.cached(for: note, dark: contentDark, theme: theme) {
                image = cached
                return
            }
            ThumbnailCache.shared.render(note, dark: contentDark, theme: theme) { rendered in
                image = rendered
            }
        }
    }

    private var renderKey: String {
        guard note.isAlive else { return "deleted" }
        return "\(note.objectID.uriRepresentation().absoluteString)|\(note.updatedAt?.timeIntervalSince1970 ?? 0)|\(contentDark)|\(theme.rawValue)"
    }
}

struct NoteCardView: View {
    @ObservedObject var note: CDNote
    var isSelecting = false
    var isSelected = false

    @Environment(\.appTheme) private var theme

    var body: some View {
        if note.isAlive {
            VStack(alignment: .leading, spacing: 0) {
                NoteThumbnail(note: note)
                    .aspectRatio(1.0, contentMode: .fit)
                    .overlay(alignment: .topLeading) {
                        if note.isFavorite {
                            Image(systemName: "star.fill")
                                .font(.caption)
                                .foregroundStyle(.yellow)
                                .padding(8)
                        }
                    }
                Rectangle().fill(theme.border).frame(height: 1)
                VStack(alignment: .leading, spacing: 4) {
                    Text(note.displayTitle)
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(theme.primaryText)
                        .lineLimit(1)
                    Text(note.updatedAt ?? Date(), format: .dateTime.day().month(.abbreviated).year())
                        .font(.system(size: 14))
                        .foregroundStyle(theme.secondaryText)
                        .environment(\.locale, Locale(identifier: "ar"))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.card)
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(isSelected ? theme.accent : theme.border, lineWidth: isSelected ? 3 : 1))
            .overlay(alignment: .topTrailing) {
                if isSelecting {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 24))
                        .foregroundStyle(isSelected ? theme.accent : Color.white)
                        .shadow(radius: 2)
                        .padding(10)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 14))
        } else {
            Color.clear.frame(height: 1)
        }
    }
}

struct NoteRowView: View {
    @ObservedObject var note: CDNote
    var isSelecting = false
    var isSelected = false

    @Environment(\.appTheme) private var theme

    var body: some View {
        if note.isAlive {
            HStack(spacing: 14) {
                if isSelecting {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 22))
                        .foregroundStyle(isSelected ? theme.accent : theme.secondaryText)
                }
                NoteThumbnail(note: note)
                    .frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.border, lineWidth: 1))
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(note.displayTitle).font(.headline).foregroundStyle(theme.primaryText).lineLimit(1)
                        if note.isFavorite {
                            Image(systemName: "star.fill").font(.caption).foregroundStyle(.yellow)
                        }
                    }
                    HStack(spacing: 6) {
                        Text(note.updatedAt ?? Date(), format: .dateTime.day().month(.abbreviated).year())
                        if let folder = note.subject, folder.isAlive {
                            Text("•")
                            Text(folder.displayName)
                        }
                        Text("•")
                        Text("\(note.pageCount) ص")
                    }
                    .font(.caption)
                    .foregroundStyle(theme.secondaryText)
                    .environment(\.locale, Locale(identifier: "ar"))
                }
                Spacer()
            }
            .padding(10)
            .background(theme.card, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(isSelected ? theme.accent : theme.border, lineWidth: isSelected ? 2 : 1))
            .contentShape(Rectangle())
        } else {
            Color.clear.frame(height: 1)
        }
    }
}

/// قراءة الملفات المختارة من تطبيق الملفات مع صلاحيات الوصول الآمن.
enum FileImportReader {
    static func read(_ result: Result<[URL], Error>) -> [ImportedFile] {
        guard case .success(let urls) = result else { return [] }
        var files: [ImportedFile] = []
        for url in urls {
            let granted = url.startAccessingSecurityScopedResource()
            defer {
                if granted { url.stopAccessingSecurityScopedResource() }
            }
            guard let data = try? Data(contentsOf: url) else { continue }
            let type = UTType(filenameExtension: url.pathExtension) ?? .data
            files.append(ImportedFile(name: url.lastPathComponent, data: data, typeIdentifier: type.identifier))
        }
        return files
    }
}
