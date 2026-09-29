import CoreData
import SwiftUI

/// القائمة الجانبية: الإعدادات، البحث، الرئيسية، الملاحظات، المعرض، والمجلدات.
struct SidebarView: View {
    @Environment(\.managedObjectContext) private var context
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var themeSettings: ThemeSettings
    @Environment(\.appTheme) private var theme

    @FetchRequest(fetchRequest: CDCategory.sortedRequest(), animation: .default)
    private var categories: FetchedResults<CDCategory>

    @FetchRequest(fetchRequest: CDSubject.sortedRequest(), animation: .default)
    private var subjects: FetchedResults<CDSubject>

    @FetchRequest(fetchRequest: CDNote.liveRequest(), animation: .default)
    private var notes: FetchedResults<CDNote>

    @State private var folderSheet: SubjectSheetTarget? = nil
    @State private var categoryEditing: CDCategory? = nil
    @State private var isCategoryAlertPresented = false
    @State private var categoryName = ""
    @State private var folderToDelete: CDSubject? = nil
    @State private var categoryToDelete: CDCategory? = nil
    @State private var crashReports: [URL] = CrashReporter.pendingReports()
    @State private var collapsed: Set<NSManagedObjectID> = []

    private var liveCategories: [CDCategory] { categories.filter(\.isAlive) }
    private var liveFolders: [CDSubject] { subjects.filter(\.isAlive) }
    private var liveNotes: [CDNote] { notes.filter(\.isAlive) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                header
                searchField
                    .padding(.bottom, 10)

                if !appState.searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                    searchResults
                } else {
                    if !crashReports.isEmpty { crashBanner }

                    navRow(.home, title: "الرئيسية", symbol: "house", id: "nav.home")
                    navRow(.notes, title: "الملاحظات", symbol: "square.and.pencil", count: liveNotes.count, id: "nav.notes")
                    navRow(.gallery, title: "المعرض", symbol: "photo.on.rectangle.angled", id: "nav.gallery")

                    foldersHeader
                        .padding(.top, 18)

                    ForEach(liveFolders.filter { $0.category == nil || $0.category?.isAlive == false }, id: \.objectID) { folder in
                        folderRow(folder)
                    }

                    ForEach(liveCategories, id: \.objectID) { category in
                        dividerSection(category)
                    }

                    if liveFolders.isEmpty {
                        Button {
                            folderSheet = .new(category: nil)
                        } label: {
                            Label("أنشئ أول مجلد", systemImage: "folder.badge.plus")
                                .foregroundStyle(theme.accent)
                                .padding(.vertical, 10)
                                .padding(.horizontal, 14)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 30)
        }
        .scrollIndicators(.hidden)
        .safeAreaInset(edge: .bottom) {
            Text("من إعداد وتطوير راشد الشمري")
                .font(.caption)
                .foregroundStyle(theme.secondaryText)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(theme.sidebar)
                .accessibilityIdentifier("developerCredit")
        }
        .background(theme.sidebar.ignoresSafeArea())
        .navigationTitle("Mnorrbility")
        .toolbar(.hidden, for: .navigationBar)
        .sheet(item: $folderSheet) { target in
            ThemedContainer {
                SubjectEditorSheet(target: target)
            }
            .environment(\.managedObjectContext, context)
            .environmentObject(appState)
            .environmentObject(themeSettings)
        }
        .alert(categoryAlertTitle, isPresented: $isCategoryAlertPresented) {
            TextField("اسم القسم", text: $categoryName)
            Button("حفظ") { saveCategory() }
            Button("إلغاء", role: .cancel) {}
        } message: {
            Text("الأقسام تجمع المجلدات، مثل: الفصل الأول، المواد العلمية")
        }
        .confirmationDialog("حذف المجلد؟",
                            isPresented: Binding(get: { folderToDelete != nil }, set: { if !$0 { folderToDelete = nil } }),
                            titleVisibility: .visible) {
            Button("حذف نهائياً", role: .destructive) { deleteFolder() }
        } message: {
            Text("ستنتقل ملاحظاته إلى «المحذوفة مؤخراً» ويمكنك استرجاعها خلال 30 يوماً.")
        }
        .confirmationDialog("حذف القسم؟",
                            isPresented: Binding(get: { categoryToDelete != nil }, set: { if !$0 { categoryToDelete = nil } }),
                            titleVisibility: .visible) {
            Button("حذف القسم", role: .destructive) { deleteCategory() }
        } message: {
            Text("المجلدات داخله لن تُحذف.")
        }
        .onReceive(NotificationCenter.default.publisher(for: .sabbouraCrashReportsChanged)) { _ in
            crashReports = CrashReporter.pendingReports()
        }
    }

    private var categoryAlertTitle: String {
        categoryEditing == nil ? "قسم جديد" : "إعادة تسمية القسم"
    }

    // MARK: الأعلى

    private var header: some View {
        HStack {
            Button {
                appState.showSettings = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(theme.primaryText)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("الإعدادات")
            .accessibilityIdentifier("settingsButton")
            Spacer()
            Text("Mnorrbility")
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .foregroundStyle(theme.secondaryText)
        }
        .padding(.top, 6)
        .environment(\.layoutDirection, .leftToRight)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(theme.secondaryText)
            TextField("بحث", text: $appState.searchText)
                .textFieldStyle(.plain)
                .foregroundStyle(theme.primaryText)
                .accessibilityIdentifier("sidebarSearch")
            if !appState.searchText.isEmpty {
                Button {
                    appState.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(theme.secondaryText)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background(theme.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(theme.border, lineWidth: 1))
    }

    private var searchResults: some View {
        let query = appState.searchText.trimmingCharacters(in: .whitespaces)
        let matches = liveNotes.filter {
            $0.titleText.localizedCaseInsensitiveContains(query)
                || ($0.subject?.displayName.localizedCaseInsensitiveContains(query) ?? false)
        }
        return VStack(alignment: .leading, spacing: 4) {
            Text(matches.isEmpty ? "لا توجد نتائج" : "النتائج (\(matches.count))")
                .font(.caption.weight(.semibold))
                .foregroundStyle(theme.secondaryText)
                .padding(.horizontal, 12)
            ForEach(matches, id: \.objectID) { note in
                Button {
                    appState.open(note)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "doc.text")
                            .foregroundStyle(theme.secondaryText)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(note.displayTitle).foregroundStyle(theme.primaryText).lineLimit(1)
                            if let folder = note.subject, folder.isAlive {
                                Text(folder.displayName).font(.caption).foregroundStyle(theme.secondaryText)
                            }
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: عناصر التنقل

    private func isSelected(_ item: SidebarItem) -> Bool {
        appState.selection == item
    }

    private func navRow(_ item: SidebarItem, title: String, symbol: String, count: Int? = nil, id: String) -> some View {
        Button {
            appState.select(item)
        } label: {
            HStack(spacing: 14) {
                Image(systemName: symbol)
                    .font(.system(size: 20))
                    .frame(width: 28)
                Text(title)
                    .font(.system(size: 17, weight: isSelected(item) ? .semibold : .regular))
                Spacer()
                if let count {
                    Text("\(count)")
                        .font(.system(size: 16, weight: .semibold))
                        .monospacedDigit()
                }
            }
            .foregroundStyle(theme.primaryText)
            .padding(.horizontal, 14)
            .frame(height: 52)
            .background(RoundedRectangle(cornerRadius: 12).fill(isSelected(item) ? theme.selection : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }

    private var foldersHeader: some View {
        HStack {
            Text("المجلدات")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(theme.secondaryText)
            Spacer()
            Menu {
                Button {
                    folderSheet = .new(category: nil)
                } label: {
                    Label("مجلد جديد", systemImage: "folder.badge.plus")
                }
                Button {
                    categoryEditing = nil
                    categoryName = ""
                    isCategoryAlertPresented = true
                } label: {
                    Label("قسم جديد", systemImage: "rectangle.stack.badge.plus")
                }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 20, weight: .regular))
                    .foregroundStyle(theme.primaryText)
                    .frame(width: 40, height: 36)
            }
            .accessibilityLabel("إضافة مجلد")
            .accessibilityIdentifier("addFolderMenu")
        }
        .padding(.horizontal, 6)
    }

    private func dividerSection(_ category: CDCategory) -> some View {
        let folders = liveFolders.filter { $0.category == category }
        let isCollapsed = collapsed.contains(category.objectID)
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Button {
                    if isCollapsed {
                        collapsed.remove(category.objectID)
                    } else {
                        collapsed.insert(category.objectID)
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: isCollapsed ? "chevron.left" : "chevron.down")
                            .font(.system(size: 11, weight: .bold))
                        Text(category.displayName)
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(theme.secondaryText)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Spacer()
                Menu {
                    Button {
                        folderSheet = .new(category: category)
                    } label: {
                        Label("مجلد جديد هنا", systemImage: "folder.badge.plus")
                    }
                    Button {
                        categoryEditing = category
                        categoryName = category.displayName
                        isCategoryAlertPresented = true
                    } label: {
                        Label("إعادة تسمية", systemImage: "pencil")
                    }
                    Divider()
                    Button(role: .destructive) {
                        categoryToDelete = category
                    } label: {
                        Label("حذف القسم", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .foregroundStyle(theme.secondaryText)
                        .frame(width: 32, height: 28)
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 12)

            if !isCollapsed {
                ForEach(folders, id: \.objectID) { folder in
                    folderRow(folder)
                }
            }
        }
    }

    private func folderRow(_ folder: CDSubject) -> some View {
        let item = SidebarItem.folder(folder.objectID)
        let selected = isSelected(item)
        return Button {
            appState.select(item)
        } label: {
            HStack(spacing: 14) {
                if themeSettings.colorfulFolders {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(Color(hex: folder.colorValue))
                        .frame(width: 26)
                } else {
                    Circle()
                        .fill(Color(hex: folder.colorValue))
                        .frame(width: 24, height: 24)
                        .frame(width: 26)
                }
                Text(folder.displayName)
                    .font(.system(size: 17, weight: selected ? .semibold : .regular))
                    .foregroundStyle(theme.primaryText)
                    .lineLimit(1)
                Spacer()
                if folder.notesCount > 0 {
                    Text("\(folder.notesCount)")
                        .font(.system(size: 14))
                        .monospacedDigit()
                        .foregroundStyle(theme.secondaryText)
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 50)
            .background(RoundedRectangle(cornerRadius: 12).fill(selected
                ? (themeSettings.colorfulFolders ? Color(hex: folder.colorValue).opacity(0.22) : theme.selection)
                : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("folder.\(folder.displayName)")
        .contextMenu { folderMenu(folder) }
    }

    @ViewBuilder
    private func folderMenu(_ folder: CDSubject) -> some View {
        let siblings = liveFolders.filter { $0.category == folder.category }
        let position = siblings.firstIndex(of: folder) ?? 0
        Button {
            folderSheet = .edit(folder)
        } label: {
            Label("تعديل المجلد", systemImage: "pencil")
        }
        if position > 0 {
            Button {
                move(siblings, from: position, to: position - 1)
            } label: {
                Label("تحريك لأعلى", systemImage: "arrow.up")
            }
        }
        if position + 1 < siblings.count {
            Button {
                move(siblings, from: position, to: position + 1)
            } label: {
                Label("تحريك لأسفل", systemImage: "arrow.down")
            }
        }
        Menu {
            Button("بدون قسم") {
                guard folder.isAlive else { return }
                folder.category = nil
                DataStore.save(context)
            }
            ForEach(liveCategories, id: \.objectID) { category in
                Button(category.displayName) {
                    guard folder.isAlive, category.isAlive else { return }
                    folder.category = category
                    DataStore.save(context)
                }
            }
        } label: {
            Label("نقل إلى قسم", systemImage: "rectangle.stack")
        }
        Divider()
        Button(role: .destructive) {
            folderToDelete = folder
        } label: {
            Label("حذف", systemImage: "trash")
        }
    }

    // MARK: تقرير الأعطال

    private var crashBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("حدث عطل في تشغيل سابق", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.subheadline.weight(.semibold))
            Text("أرسل التقرير للمطوّر ليتم إصلاحه.")
                .font(.caption)
                .foregroundStyle(theme.secondaryText)
            HStack {
                Button("مشاركة التقرير") { SharePresenter.share(crashReports) }
                    .buttonStyle(.borderedProminent)
                Button("إخفاء") { CrashReporter.markAllSeen() }
                    .buttonStyle(.bordered)
            }
            .font(.caption)
        }
        .padding(12)
        .background(theme.card, in: RoundedRectangle(cornerRadius: 12))
        .padding(.bottom, 8)
    }

    // MARK: إجراءات

    private func saveCategory() {
        let name = categoryName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        if let category = categoryEditing, category.isAlive {
            category.name = name
            DataStore.save(context)
        } else {
            DataStore.createCategory(named: name, in: context)
        }
        categoryEditing = nil
    }

    private func deleteFolder() {
        guard let folder = folderToDelete else { return }
        folderToDelete = nil
        if appState.selection == .folder(folder.objectID) {
            appState.selection = .notes
        }
        DispatchQueue.main.async {
            DataStore.deleteFolder(folder, context: context)
        }
    }

    private func deleteCategory() {
        guard let category = categoryToDelete else { return }
        categoryToDelete = nil
        DataStore.deleteLater(category, context: context)
    }

    private func move(_ items: [CDSubject], from source: Int, to destination: Int) {
        guard items.indices.contains(source), items.indices.contains(destination) else { return }
        var reordered = items
        reordered.swapAt(source, destination)
        for (index, folder) in reordered.enumerated() where folder.isAlive {
            folder.sortOrder = Int64(index)
        }
        DataStore.save(context)
    }
}
