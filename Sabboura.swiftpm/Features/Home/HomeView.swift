import CoreData
import SwiftUI

/// الرئيسية: اختصارات سريعة، آخر الملاحظات، المفضلة، والمجلدات.
struct HomeView: View {
    @Environment(\.managedObjectContext) private var context
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var study: StudySessionManager
    @Environment(\.appTheme) private var theme

    @FetchRequest(fetchRequest: CDNote.liveRequest(), animation: .default)
    private var notes: FetchedResults<CDNote>
    @FetchRequest(fetchRequest: CDSubject.sortedRequest(), animation: .default)
    private var folders: FetchedResults<CDSubject>

    @State private var showPDFImporter = false

    private var recent: [CDNote] {
        Array(notes.filter(\.isAlive)
            .sorted { ($0.lastOpenedAt ?? $0.updatedAt ?? .distantPast) > ($1.lastOpenedAt ?? $1.updatedAt ?? .distantPast) }
            .prefix(10))
    }

    private var favorites: [CDNote] {
        notes.filter { $0.isAlive && $0.isFavorite }
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        return hour < 12 ? "صباح الخير" : "مساء الخير"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("الرئيسية")
                        .font(.system(size: AppEnvironment.isPhone ? 30 : 40, weight: .heavy))
                        .foregroundStyle(theme.primaryText)
                    Text(greeting)
                        .font(.title3)
                        .foregroundStyle(theme.secondaryText)
                }

                quickActions

                if study.minutesToday > 0 || study.isActive {
                    Label(study.isActive
                          ? "جلسة مذاكرة جارية — \(study.running?.phase.title ?? "") \(study.remainingText)"
                          : "درست اليوم \(study.minutesToday) دقيقة",
                          systemImage: "timer")
                        .font(.headline)
                        .foregroundStyle(theme.primaryText)
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(theme.card, in: RoundedRectangle(cornerRadius: 14))
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(theme.border, lineWidth: 1))
                }

                if !recent.isEmpty {
                    section("آخر الملاحظات") { noteStrip(recent) }
                }
                if !favorites.isEmpty {
                    section("المفضلة") { noteStrip(favorites) }
                }

                section("المجلدات") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 14)], spacing: 14) {
                        ForEach(folders.filter(\.isAlive), id: \.objectID) { folder in
                            Button {
                                appState.select(.folder(folder.objectID))
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: "folder.fill")
                                        .foregroundStyle(Color(hex: folder.colorValue))
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(folder.displayName)
                                            .font(.subheadline.weight(.semibold))
                                            .foregroundStyle(theme.primaryText)
                                            .lineLimit(1)
                                        Text("\(folder.notesCount) ملاحظة")
                                            .font(.caption)
                                            .foregroundStyle(theme.secondaryText)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .padding(14)
                                .background(theme.card, in: RoundedRectangle(cornerRadius: 12))
                                .overlay(RoundedRectangle(cornerRadius: 12).stroke(theme.border, lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(.horizontal, AppEnvironment.isPhone ? 16 : 30)
            .padding(.vertical, 12)
        }
        .background(theme.background.ignoresSafeArea())
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(theme.background, for: .navigationBar)
        .fileImporter(isPresented: $showPDFImporter, allowedContentTypes: [.pdf], allowsMultipleSelection: false) { result in
            guard let file = FileImportReader.read(result).first,
                  let note = DataStore.createNote(fromPDF: file.data, fileName: file.name, in: nil, context: context) else { return }
            appState.select(.notes)
            appState.path.append(note)
        }
    }

    private var quickActions: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                actionTile("مذكرة جديدة", symbol: "square.and.pencil", color: theme.accent, id: "home.newNote") {
                    let note = DataStore.createNote(in: nil, title: DataStore.defaultNoteTitle(), context: context)
                    appState.select(.notes)
                    appState.path.append(note)
                }
                actionTile("استيراد PDF", symbol: "doc.richtext", color: .orange, id: "home.importPDF") {
                    showPDFImporter = true
                }
                actionTile("جلسة مذاكرة", symbol: "timer", color: .green, id: "home.study") {
                    appState.showStudySetup = true
                }
            }
        }
    }

    private func actionTile(_ title: String, symbol: String, color: Color, id: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 14) {
                Image(systemName: symbol)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(color)
                    .frame(width: 48, height: 48)
                    .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
                Text(title)
                    .font(.headline)
                    .foregroundStyle(theme.primaryText)
            }
            .frame(width: 170, alignment: .leading)
            .padding(16)
            .background(theme.card, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(theme.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.title3.weight(.bold))
                .foregroundStyle(theme.primaryText)
            content()
        }
    }

    private func noteStrip(_ items: [CDNote]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 16) {
                ForEach(items, id: \.objectID) { note in
                    Button {
                        appState.select(.notes)
                        appState.path.append(note)
                    } label: {
                        NoteCardView(note: note)
                            .frame(width: AppEnvironment.isPhone ? 150 : 190)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}
