import UIKit
import UniformTypeIdentifiers

// MARK: - المحتوى المطبوع داخل المحرر: تحديد، نسخ، لصق، ورفع للتحريك

extension EditorController {
    /// يربط تحديد المحتوى المطبوع باللوحة (يُستدعى مرة عند ربط اللوحة).
    func attachPrintedContent(_ view: PageCanvasContainerView) {
        view.printedSelection.resolveRegion = { [weak self] points in
            self?.printedRegion(enclosing: points)
        }
        view.printedSelection.onAction = { [weak self] action, region in
            self?.performPrintedAction(action, on: region)
        }
    }

    // MARK: تحديد المنطقة

    /// المنطقة المطبوعة تحت مسار اللاسو (إحداثيات اللوحة بدون تكبير)، أو nil إن لم يكن تحته PDF أو صورة.
    private func printedRegion(enclosing points: [CGPoint]) -> PrintedRegion? {
        guard note.isAlive, !layout.isEmpty, points.count > 2 else { return nil }
        let bounds = PrintedGeometry.boundingRect(of: points)
        guard !bounds.isNull else { return nil }
        let index = layoutIndex(forY: bounds.midY)
        guard layout.indices.contains(index), layoutPages.indices.contains(index) else { return nil }
        let info = layout[index]
        let page = layoutPages[index]
        guard page.isAlive else { return nil }

        let local = points.map { CGPoint(x: $0.x, y: $0.y - info.originY) }
        let pageRect = CGRect(origin: .zero, size: info.size)
        let rect = PrintedGeometry.boundingRect(of: local).intersection(pageRect)
        guard !rect.isNull, rect.width >= 4, rect.height >= 4 else { return nil }

        // الصور الموضوعة على الصفحة (صور مستندات أو لقطات) تُعامل كمحتوى مطبوع أيضاً
        var overlays: [PrintedImageOverlay] = []
        for item in page.items where item.kind == .image && item.frame.intersects(rect) {
            guard let id = item.attachmentID,
                  let image = ImageStore.shared.image(for: id, context: context)?.cgImage else { continue }
            overlays.append(PrintedImageOverlay(image: image, frame: item.frame))
        }
        let pdfPage = page.isPDFPage ? info.pdfPage : nil
        guard pdfPage != nil || !overlays.isEmpty else { return nil }

        var pdfData: Data?
        if pdfPage != nil, let sourceID = page.pdfSourceID,
           !PrintedTextExtractor.shared.hasDocument(for: sourceID) {
            pdfData = DataStore.attachment(with: sourceID, in: context)?.data
        }
        return PrintedRegion(pageID: info.id,
                             pageSize: info.size,
                             pageOriginY: info.originY,
                             pdfPage: pdfPage,
                             pdfSourceID: page.pdfSourceID,
                             pdfPageIndex: Int(page.pdfPageIndex),
                             pdfData: pdfData,
                             overlays: overlays,
                             polygon: local,
                             rect: rect)
    }

    // MARK: الإجراءات

    private func performPrintedAction(_ action: PrintedSelectionController.Action, on region: PrintedRegion) {
        let service = PrintedContentService.shared
        switch action {
        case .copySmart:
            service.capture(region, text: .full) { [weak self] capture in
                guard let self else { return }
                guard let capture else { return self.showToast("تعذّر نسخ التحديد") }
                if capture.prefersText, let text = capture.text?.text {
                    PrintedClipboard.copyText(text)
                    self.showToast("نُسخ النص — الصقه في أي مكان")
                } else {
                    PrintedClipboard.copyImage(capture)
                    self.showToast(capture.text?.isMathematical == true
                                   ? "نُسخ كصورة عالية الدقة حتى تبقى المعادلة مضبوطة"
                                   : "نُسخ كصورة عالية الدقة — الصقه في أي مكان")
                }
            }
        case .copyText:
            service.capture(region, text: .full) { [weak self] capture in
                guard let self else { return }
                guard let capture else { return self.showToast("تعذّر نسخ التحديد") }
                if let text = capture.text, !text.isEmpty {
                    PrintedClipboard.copyText(text.text)
                    self.showToast(text.isMathematical
                                   ? "نُسخ النص — للمعادلات انسخها كصورة حتى تبقى رموزها مضبوطة"
                                   : "نُسخ النص — الصقه في أي مكان")
                } else {
                    PrintedClipboard.copyImage(capture)
                    self.showToast("ما قدرت أقرأ نص واضح هنا — نسخته كصورة")
                }
            }
        case .copyImage:
            service.capture(region, text: .embeddedOnly) { [weak self] capture in
                guard let self else { return }
                guard let capture else { return self.showToast("تعذّر نسخ التحديد") }
                PrintedClipboard.copyImage(capture)
                self.showToast("نُسخ كصورة عالية الدقة — الصقه في أي مكان")
            }
        case .lift:
            service.capture(region, text: .embeddedOnly) { [weak self] capture in
                guard let self else { return }
                guard let capture else { return self.showToast("تعذّر رفع التحديد") }
                // المقتطف يوضع فوق الأصل تماماً، فيبدو كأنه رُفع من الصفحة ويُسحب مباشرة
                let placed = self.insertPrintedClip(image: capture.image,
                                                    pngData: capture.pngData,
                                                    text: capture.plainText,
                                                    frame: region.rect,
                                                    pageID: region.pageID,
                                                    actionName: "رفع مقتطف")
                if placed {
                    self.showToast("اسحب المقتطف لأي مكان — حتى لصفحة ثانية")
                }
            }
        }
    }

    // MARK: اللصق

    /// يلصق مقتطفاً مطبوعاً منسوخاً من التطبيق بحجمه الأصلي. يعيد false إن لم يوجد.
    func pastePrintedContent() -> Bool {
        guard let content = PrintedClipboard.printedContent(),
              note.isAlive, let view = canvasView, !layout.isEmpty else { return false }
        let center = view.visibleContentCenter
        let index = layoutIndex(forY: center.y)
        guard layout.indices.contains(index) else { return false }
        let info = layout[index]

        var size = content.size
        let maxWidth = info.size.width - 16
        let maxHeight = info.size.height - 16
        if size.width > maxWidth || size.height > maxHeight {
            let factor = min(maxWidth / size.width, maxHeight / size.height)
            size = CGSize(width: size.width * factor, height: size.height * factor)
        }
        let localY = center.y - info.originY
        let origin = CGPoint(x: min(max(center.x - size.width / 2, 8), info.size.width - size.width - 8),
                             y: min(max(localY - size.height / 2, 8), info.size.height - size.height - 8))
        let placed = insertPrintedClip(image: content.image,
                                       pngData: content.pngData,
                                       text: content.text,
                                       frame: CGRect(origin: origin, size: size),
                                       pageID: info.id,
                                       actionName: "لصق مقتطف")
        if placed {
            showToast("لُصق المقتطف بحجمه الأصلي — اسحبه لأي مكان")
        }
        return placed
    }

    /// يلصق نصاً منسوخاً كمربع نص قابل للتعديل. يعيد false إن لم يوجد نص.
    func pasteCopiedText() -> Bool {
        let board = UIPasteboard.general
        guard board.hasStrings, let raw = board.string else { return false }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, note.isAlive, let view = canvasView, !layout.isEmpty else { return false }
        let center = view.visibleContentCenter
        let index = layoutIndex(forY: center.y)
        guard layout.indices.contains(index), layoutPages.indices.contains(index) else { return false }
        let info = layout[index]
        let page = layoutPages[index]
        guard page.isAlive else { return false }

        let width = max(160, min(560, info.size.width - 48))
        let x = min(max(center.x - width / 2, 24), max(24, info.size.width - width - 24))
        let y = min(max(center.y - info.originY, 24), max(24, info.size.height - 80))
        var item = PageItem.newText(at: CGPoint(x: x, y: y), pageWidth: info.size.width,
                                    colorHex: tools.color(for: tools.lastInkKind))
        item.width = Double(width)
        item.text = text
        item.fitTextHeight()
        if item.y + item.height > Double(info.size.height) - 8 {
            item.y = max(8, Double(info.size.height) - 8 - item.height)
        }

        let before = [(page, page.items)]
        page.items = page.items + [item]
        commitItemChange(before, actionName: "لصق نص")
        selectInsertedItem(item.id)
        showToast("لُصق النص — اضغط عليه لتعديله")
        return true
    }

    // MARK: الإدراج

    /// يضيف مقتطفاً مطبوعاً كعنصر صورة عالية الدقة (PNG بدون ضغط) في الصفحة المحددة.
    @discardableResult
    private func insertPrintedClip(image: UIImage, pngData: Data, text: String?, frame: CGRect,
                                   pageID: UUID, actionName: String) -> Bool {
        guard note.isAlive,
              let index = layout.firstIndex(where: { $0.id == pageID }),
              layoutPages.indices.contains(index) else { return false }
        let page = layoutPages[index]
        guard page.isAlive, frame.width >= 1, frame.height >= 1 else { return false }

        let attachment = DataStore.addAttachment(data: pngData, fileName: "مقتطف.png",
                                                 typeIdentifier: UTType.png.identifier,
                                                 isPageSource: false, to: note, context: context)
        guard let attachmentID = attachment.uuid else { return false }
        // فك ترميز الصورة مسبقاً حتى لا يتأخر أول ظهور أو أول سحب
        ImageStore.shared.store(image.preparingForDisplay() ?? image, for: attachmentID)

        var item = PageItem(kind: .image,
                            x: Double(frame.minX),
                            y: Double(frame.minY),
                            width: Double(frame.width),
                            height: Double(frame.height))
        item.attachmentID = attachmentID
        item.printedText = text ?? ""

        let before = [(page, page.items)]
        page.items = page.items + [item]
        commitItemChange(before, actionName: actionName)
        selectInsertedItem(item.id)
        return true
    }

    /// يحدد العنصر الجديد بأداة «النص والصور» (نفس سلوك إدراج الصور) حتى يُسحب ويُكبَّر فوراً.
    private func selectInsertedItem(_ id: UUID) {
        if tools.kind != .text {
            tools.previousKind = tools.kind
            tools.kind = .text
        }
        DispatchQueue.main.async { [weak self] in
            self?.canvasView?.itemsOverlay.select(id)
        }
    }
}
