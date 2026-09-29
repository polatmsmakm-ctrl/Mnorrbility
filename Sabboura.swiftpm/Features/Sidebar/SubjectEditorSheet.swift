import CoreData
import SwiftUI

enum SubjectSheetTarget: Identifiable {
    case new(category: CDCategory?)
    case edit(CDSubject)

    var id: String {
        switch self {
        case .new(let category):
            return "new-" + (category?.objectID.uriRepresentation().absoluteString ?? "none")
        case .edit(let subject):
            return "edit-" + subject.objectID.uriRepresentation().absoluteString
        }
    }
}

/// إضافة مادة جديدة أو تعديل مادة: الاسم، اللون، الأيقونة، والتصنيف.
struct SubjectEditorSheet: View {
    let target: SubjectSheetTarget

    @Environment(\.managedObjectContext) private var context
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appState: AppState

    @FetchRequest(fetchRequest: CDCategory.sortedRequest()) private var categories: FetchedResults<CDCategory>

    @State private var name = ""
    @State private var colorHex = ColorPresets.subjects[0]
    @State private var iconName = "book.closed"
    @State private var category: CDCategory? = nil
    @State private var showCustomColor = false
    @State private var didLoad = false

    static let icons: [String] = [
        "book.closed", "text.book.closed", "character.book.closed", "function", "x.squareroot",
        "sum", "percent", "atom", "flask", "testtube.2", "leaf", "globe.europe.africa",
        "building.columns", "brain.head.profile", "heart.text.square", "cross.case",
        "laptopcomputer", "chevron.left.forwardslash.chevron.right", "chart.bar", "chart.pie",
        "paintpalette", "music.note", "pencil.and.ruler", "ruler", "graduationcap",
        "lightbulb", "moon.stars", "quote.bubble", "globe", "note.text"
    ]

    private var isEditing: Bool {
        if case .edit = target { return true }
        return false
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 14) {
                        Image(systemName: iconName)
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 48, height: 48)
                            .background(Color(hex: colorHex), in: RoundedRectangle(cornerRadius: 12))
                        TextField("اسم المجلد", text: $name)
                            .font(.title3)
                            .accessibilityIdentifier("subjectName")
                    }
                    .padding(.vertical, 4)
                }

                Section("اللون") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 12) {
                        ForEach(ColorPresets.subjects, id: \.self) { hex in
                            Button {
                                colorHex = hex
                            } label: {
                                Circle()
                                    .fill(Color(hex: hex))
                                    .frame(width: 32, height: 32)
                                    .overlay(
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 13, weight: .bold))
                                            .foregroundStyle(.white)
                                            .opacity(colorHex.uppercased() == hex ? 1 : 0)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 6)

                    DisclosureGroup("لون مخصّص من دائرة الألوان", isExpanded: $showCustomColor) {
                        ColorWheelPicker(hex: $colorHex, wheelSize: 200)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    }
                }

                Section("الأيقونة") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 12) {
                        ForEach(Self.icons, id: \.self) { icon in
                            Button {
                                iconName = icon
                            } label: {
                                Image(systemName: icon)
                                    .font(.system(size: 18))
                                    .frame(width: 40, height: 40)
                                    .background(
                                        RoundedRectangle(cornerRadius: 10)
                                            .fill(iconName == icon ? Color(hex: colorHex).opacity(0.2) : Color.clear)
                                    )
                                    .foregroundStyle(iconName == icon ? Color(hex: colorHex) : Color.primary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 6)
                }

                Section("القسم") {
                    Picker("القسم", selection: $category) {
                        Text("بدون قسم").tag(CDCategory?.none)
                        ForEach(categories.filter(\.isAlive), id: \.objectID) { item in
                            Text(item.displayName).tag(Optional(item))
                        }
                    }
                }
            }
            .navigationTitle(isEditing ? "تعديل المجلد" : "مجلد جديد")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("إلغاء") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("حفظ") { save() }
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("saveSubject")
                }
            }
        }
        .environment(\.layoutDirection, .rightToLeft)
        .onAppear(perform: load)
    }

    private func load() {
        guard !didLoad else { return }
        didLoad = true
        switch target {
        case .new(let preselected):
            category = preselected
            colorHex = ColorPresets.subjects.randomElement() ?? ColorPresets.subjects[0]
        case .edit(let subject):
            guard subject.isAlive else { return }
            name = subject.displayName
            colorHex = subject.colorValue
            iconName = subject.iconValue
            category = subject.category?.isAlive == true ? subject.category : nil
        }
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        switch target {
        case .new:
            let validCategory = category?.isAlive == true ? category : nil
            let subject = DataStore.createSubject(named: trimmed, colorHex: colorHex, iconName: iconName,
                                                  category: validCategory, in: context)
            validCategory?.isExpanded = true
            DataStore.save(context)
            appState.select(.folder(subject.objectID))
        case .edit(let subject):
            guard subject.isAlive else { break }
            subject.name = trimmed
            subject.colorHex = colorHex
            subject.iconName = iconName
            subject.category = category?.isAlive == true ? category : nil
            DataStore.save(context)
        }
        dismiss()
    }
}
