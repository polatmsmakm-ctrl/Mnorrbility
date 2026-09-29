import QuickLook
import SwiftUI
import UniformTypeIdentifiers

/// الملفات المرفقة بالمذكرة (PDF، صور، Word، عروض...) مع معاينة ومشاركة وحذف.
struct AttachmentsView: View {
    @ObservedObject var note: CDNote
    @ObservedObject var controller: EditorController
    @Environment(\.dismiss) private var dismiss

    @State private var previewURL: URL? = nil
    @State private var showImporter = false
    @State private var pendingDelete: CDAttachment? = nil

    var body: some View {
        NavigationStack {
            Group {
                if note.sortedAttachments.isEmpty {
                    ContentUnavailableView {
                        Label("لا توجد مرفقات", systemImage: "paperclip")
                    } description: {
                        Text("أرفق ملفات PDF أو صوراً أو مستندات Word وغيرها لتبقى مع هذه المذكرة.")
                    } actions: {
                        Button("إرفاق ملف") { showImporter = true }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    List {
                        ForEach(note.sortedAttachments, id: \.objectID) { attachment in
                            AttachmentRow(attachment: attachment)
                                .contentShape(Rectangle())
                                .onTapGesture { previewURL = TemporaryFiles.url(for: attachment) }
                                .contextMenu { menu(for: attachment) }
                                .swipeActions {
                                    Button(role: .destructive) {
                                        pendingDelete = attachment
                                    } label: {
                                        Label("حذف", systemImage: "trash")
                                    }
                                    Button {
                                        controller.shareAttachments([attachment])
                                    } label: {
                                        Label("مشاركة", systemImage: "square.and.arrow.up")
                                    }
                                    .tint(.blue)
                                }
                        }
                    }
                }
            }
            .navigationTitle("المرفقات")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("تم") { dismiss() }
                        .accessibilityIdentifier("attachmentsDone")
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    if !note.sortedAttachments.isEmpty {
                        Button {
                            controller.shareAttachments(note.sortedAttachments)
                        } label: {
                            Label("تصدير الكل", systemImage: "square.and.arrow.up.on.square")
                        }
                    }
                    Button {
                        showImporter = true
                    } label: {
                        Label("إرفاق", systemImage: "plus")
                    }
                }
            }
            .fileImporter(isPresented: $showImporter,
                          allowedContentTypes: [.item],
                          allowsMultipleSelection: true) { result in
                let files = FileImportReader.read(result)
                controller.importFiles(files, asPages: false)
            }
            .confirmationDialog("حذف المرفق؟",
                                isPresented: Binding(get: { pendingDelete != nil },
                                                     set: { if !$0 { pendingDelete = nil } }),
                                titleVisibility: .visible) {
                Button("حذف", role: .destructive) {
                    if let attachment = pendingDelete {
                        if let context = attachment.managedObjectContext {
                            DataStore.deleteLater(attachment, context: context)
                        }
                    }
                    pendingDelete = nil
                }
            } message: {
                Text("الصفحات المستوردة من هذا الملف ستفقد خلفية PDF الخاصة بها.")
            }
            .quickLookPreview($previewURL)
        }
        .environment(\.layoutDirection, .rightToLeft)
    }

    @ViewBuilder
    private func menu(for attachment: CDAttachment) -> some View {
        Button {
            previewURL = TemporaryFiles.url(for: attachment)
        } label: {
            Label("معاينة", systemImage: "eye")
        }
        Button {
            controller.shareAttachments([attachment])
        } label: {
            Label("مشاركة / حفظ في الملفات", systemImage: "square.and.arrow.up")
        }
        let file = ImportedFile(name: attachment.displayName, data: Data(), typeIdentifier: attachment.typeValue)
        if file.isPDF || file.isImage {
            Button {
                controller.insertAttachmentAsPages(attachment)
                dismiss()
            } label: {
                Label("إدراج كصفحات للكتابة عليها", systemImage: "doc.on.doc")
            }
        }
        Divider()
        Button(role: .destructive) {
            pendingDelete = attachment
        } label: {
            Label("حذف", systemImage: "trash")
        }
    }
}

private struct AttachmentRow: View {
    @ObservedObject var attachment: CDAttachment

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: iconName)
                .font(.system(size: 22))
                .foregroundStyle(Color.accentColor)
                .frame(width: 40, height: 40)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 3) {
                Text(attachment.displayName).lineLimit(1)
                HStack(spacing: 6) {
                    Text(ByteCountFormatter.string(fromByteCount: attachment.byteCount, countStyle: .file))
                    if attachment.isPageSource {
                        Text("• مصدر صفحات")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }

    private var iconName: String {
        guard let type = UTType(attachment.typeValue) else { return "doc" }
        if type.conforms(to: .pdf) { return "doc.richtext" }
        if type.conforms(to: .image) { return "photo" }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return "film" }
        if type.conforms(to: .audio) { return "waveform" }
        if type.conforms(to: .presentation) { return "rectangle.on.rectangle" }
        if type.conforms(to: .spreadsheet) { return "tablecells" }
        if type.conforms(to: .archive) { return "doc.zipper" }
        if type.conforms(to: .text) { return "doc.text" }
        return "doc"
    }
}
