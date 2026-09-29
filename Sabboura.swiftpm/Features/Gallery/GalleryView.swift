import CoreData
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

/// المعرض: كل ملفات PDF والصور والتسجيلات المرفقة في الملاحظات.
struct GalleryView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.appTheme) private var theme

    @FetchRequest(fetchRequest: GalleryView.request(), animation: .default)
    private var attachments: FetchedResults<CDAttachment>

    @State private var filter: GalleryFilter = .all
    @State private var previewURL: URL? = nil

    enum GalleryFilter: String, CaseIterable, Identifiable {
        case all, pdf, images, audio
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: return "الكل"
            case .pdf: return "PDF"
            case .images: return "الصور"
            case .audio: return "التسجيلات"
            }
        }
    }

    static func request() -> NSFetchRequest<CDAttachment> {
        let request = NSFetchRequest<CDAttachment>(entityName: "CDAttachment")
        request.predicate = NSPredicate(format: "note != nil AND note.deletedAt == nil")
        request.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: false)]
        return request
    }

    private var items: [CDAttachment] {
        attachments.filter { attachment in
            guard attachment.isAlive else { return false }
            let type = UTType(attachment.typeValue) ?? .data
            switch filter {
            case .all: return true
            case .pdf: return type.conforms(to: .pdf)
            case .images: return type.conforms(to: .image)
            case .audio: return type.conforms(to: .audio)
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("المعرض")
                    .font(.system(size: AppEnvironment.isPhone ? 30 : 40, weight: .heavy))
                    .foregroundStyle(theme.primaryText)
                Picker("التصنيف", selection: $filter) {
                    ForEach(GalleryFilter.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 460)

                if items.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 44))
                            .foregroundStyle(theme.secondaryText)
                        Text("لا توجد ملفات بعد")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(theme.primaryText)
                        Text("ملفات PDF والصور والتسجيلات التي تضيفها للملاحظات تظهر هنا.")
                            .font(.subheadline)
                            .foregroundStyle(theme.secondaryText)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 80)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: AppEnvironment.isPhone ? 150 : 200), spacing: 18)], spacing: 18) {
                        ForEach(items, id: \.objectID) { attachment in
                            GalleryTile(attachment: attachment)
                                .onTapGesture {
                                    if let note = attachment.note, note.isAlive {
                                        appState.select(.notes)
                                        appState.path.append(note)
                                    }
                                }
                                .contextMenu {
                                    Button {
                                        previewURL = TemporaryFiles.url(for: attachment)
                                    } label: {
                                        Label("معاينة", systemImage: "eye")
                                    }
                                    Button {
                                        if let url = TemporaryFiles.url(for: attachment) { SharePresenter.share([url]) }
                                    } label: {
                                        Label("مشاركة", systemImage: "square.and.arrow.up")
                                    }
                                }
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
        .quickLookPreview($previewURL)
    }
}

private struct GalleryTile: View {
    @ObservedObject var attachment: CDAttachment
    @Environment(\.appTheme) private var theme
    @State private var image: UIImage? = nil

    private var type: UTType { UTType(attachment.typeValue) ?? .data }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                theme.card
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: type.conforms(to: .audio) ? "waveform" : (type.conforms(to: .pdf) ? "doc.richtext" : "doc"))
                        .font(.system(size: 40))
                        .foregroundStyle(theme.accent)
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .clipped()
            Rectangle().fill(theme.border).frame(height: 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(attachment.displayName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(theme.primaryText)
                    .lineLimit(1)
                Text(attachment.note?.displayTitle ?? "")
                    .font(.caption)
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(1)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.card)
        }
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(theme.border, lineWidth: 1))
        .task(id: attachment.objectID) {
            guard attachment.isAlive, let data = attachment.data else { return }
            let isPDF = type.conforms(to: .pdf)
            let isImage = type.conforms(to: .image)
            guard isPDF || isImage else { return }
            let rendered = await Task.detached(priority: .utility) { () -> UIImage? in
                if isImage {
                    return UIImage(data: data)?.preparingThumbnail(of: CGSize(width: 400, height: 400))
                }
                guard let document = PDFSourceCache.makeDocument(from: data), let page = document.page(at: 1) else { return nil }
                let size = DataStore.normalizedSize(of: page)
                var config = PageBackgroundConfig(kind: .blank, backgroundHex: "#FFFFFF", lineHex: "#FFFFFF", spacing: 30, pageSize: size)
                config.isPDF = true
                let snapshot = PageSnapshot(size: size, background: config, pdfPage: page, drawingData: nil)
                return PageRenderer.image(for: snapshot, targetWidth: 300, scale: 2)
            }.value
            image = rendered
        }
    }
}
