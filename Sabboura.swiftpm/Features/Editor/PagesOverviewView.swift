import SwiftUI

/// عرض كل صفحات المذكرة كصور مصغّرة: انتقال، تكرار، حذف، وإعادة ترتيب.
struct PagesOverviewView: View {
    @ObservedObject var controller: EditorController
    @Environment(\.dismiss) private var dismiss

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 190), spacing: 18)]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 22) {
                    ForEach(Array(controller.pages.enumerated()).filter { $0.element.isAlive }, id: \.element.objectID) { index, page in
                        PageThumbnailCell(controller: controller,
                                          page: page,
                                          index: index,
                                          isCurrent: index == controller.currentIndex)
                            .onTapGesture {
                                controller.goToPage(index)
                                dismiss()
                            }
                            .contextMenu {
                                Button {
                                    controller.duplicatePage(at: index)
                                } label: {
                                    Label("تكرار", systemImage: "plus.square.on.square")
                                }
                                if index > 0 {
                                    Button {
                                        controller.movePage(from: index, to: index - 1)
                                    } label: {
                                        Label("نقل للأمام", systemImage: "arrow.backward")
                                    }
                                }
                                if index + 1 < controller.pageCount {
                                    Button {
                                        controller.movePage(from: index, to: index + 1)
                                    } label: {
                                        Label("نقل للخلف", systemImage: "arrow.forward")
                                    }
                                }
                                Divider()
                                Button(role: .destructive) {
                                    controller.deletePage(at: index)
                                } label: {
                                    Label("حذف", systemImage: "trash")
                                }
                            }
                    }
                }
                .padding(24)
            }
            .navigationTitle("الصفحات (\(controller.pageCount))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("تم") { dismiss() }
                        .accessibilityIdentifier("pagesDone")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        controller.addPage()
                        dismiss()
                    } label: {
                        Label("صفحة جديدة", systemImage: "doc.badge.plus")
                    }
                }
            }
        }
        .environment(\.layoutDirection, .rightToLeft)
        .onAppear { controller.flush() }
    }
}

private struct PageThumbnailCell: View {
    @ObservedObject var controller: EditorController
    @ObservedObject var page: CDPage
    let index: Int
    let isCurrent: Bool

    @State private var image: UIImage? = nil

    var body: some View {
        VStack(spacing: 8) {
            Color.clear
                .aspectRatio(page.pageSize.width / page.pageSize.height, contentMode: .fit)
                .overlay {
                    if let image {
                        Image(uiImage: image).resizable().scaledToFit()
                    } else {
                        ZStack {
                            Color(hex: page.backgroundHex)
                            ProgressView()
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(isCurrent ? Color.accentColor : Color.primary.opacity(0.12),
                                lineWidth: isCurrent ? 3 : 1)
                )
                .shadow(color: .black.opacity(0.1), radius: 4, y: 2)

            Text("\(index + 1)")
                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                .foregroundStyle(isCurrent ? Color.accentColor : Color.secondary)
        }
        .task(id: renderKey) {
            guard page.isAlive else { return }
            let snapshot = controller.snapshot(of: page, dark: controller.contentDark)
            let rendered = await Task.detached(priority: .userInitiated) {
                PageRenderer.image(for: snapshot, targetWidth: 200, scale: 2)
            }.value
            image = rendered
        }
    }

    private var renderKey: String {
        guard page.isAlive else { return "deleted" }
        return "\(page.objectID.uriRepresentation().absoluteString)-\(page.drawingData?.count ?? 0)-\(page.kind.rawValue)-\(page.backgroundHex)-\(page.lineHex)-\(page.spacingValue)"
    }
}
