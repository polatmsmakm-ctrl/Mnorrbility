import UIKit

/// يربط أداة التحديد الحر (اللاسو) الموجودة بالمحتوى المطبوع:
/// يراقب مسار اللاسو دون أن يتدخل في PencilKit، وإذا حوّط المسار نصاً مطبوعاً (وليس كتابة يد)
/// يُظهر قائمة iOS المعتادة: نسخ، نسخ كنص، نسخ كصورة، رفع وتحريك.
final class PrintedSelectionController: NSObject, UIGestureRecognizerDelegate, UIEditMenuInteractionDelegate {
    enum Action {
        /// يختار الأنسب تلقائياً (نص أو صورة)
        case copySmart
        case copyText
        case copyImage
        /// يرفع نسخة من المحتوى كعنصر يُسحب لأي مكان
        case lift
        /// Gemini: ترجمة، شرح معادلة، تحويل إلى LaTeX
        case ai(PrintedAITask)
    }

    /// يحوّل مسار اللاسو (إحداثيات اللوحة بدون تكبير) إلى منطقة مطبوعة، أو nil إن لم يكن تحته محتوى مطبوع.
    var resolveRegion: (([CGPoint]) -> PrintedRegion?)?
    var onAction: ((Action, PrintedRegion) -> Void)?

    private weak var host: PageCanvasContainerView?
    private var menuInteraction: UIEditMenuInteraction?
    private let highlight = CAShapeLayer()
    private var region: PrintedRegion?
    private var requestID = 0
    private var presentationID = 0

    func install(in host: PageCanvasContainerView) {
        self.host = host
        let interaction = UIEditMenuInteraction(delegate: self)
        host.addInteraction(interaction)
        menuInteraction = interaction

        highlight.fillColor = UIColor.systemBlue.withAlphaComponent(0.14).cgColor
        highlight.strokeColor = UIColor.systemBlue.withAlphaComponent(0.85).cgColor
        highlight.lineJoin = .round
        highlight.zPosition = 900
        highlight.opacity = 0
    }

    // MARK: اللاسو

    /// مسار مغلق تقريباً (رسم دائرة حول المحتوى) وليس سحباً لتحديد موجود.
    static func isClosedLasso(_ points: [CGPoint]) -> Bool {
        guard points.count >= 6, let first = points.first, let last = points.last else { return false }
        let bounds = PrintedGeometry.boundingRect(of: points)
        let size = max(bounds.width, bounds.height)
        guard size >= 14 else { return false }
        var length: CGFloat = 0
        for index in 1..<points.count {
            length += hypot(points[index].x - points[index - 1].x, points[index].y - points[index - 1].y)
        }
        let gap = hypot(first.x - last.x, first.y - last.y)
        return gap <= max(size * 0.6, 30) && length >= size * 1.6
    }

    /// انتهى مسار لاسو لا يحتوي كتابة يد (النقاط بإحداثيات اللوحة بدون تكبير).
    func handleLasso(_ points: [CGPoint]) {
        guard Self.isClosedLasso(points), let candidate = resolveRegion?(points) else { return }
        requestID += 1
        let request = requestID
        PrintedContentService.shared.analyze(candidate) { [weak self] refined in
            guard let self, request == self.requestID, let refined else { return }
            self.present(refined)
        }
    }

    /// يلغي أي تحديد ظاهر أو قيد التحليل.
    func dismiss() {
        requestID += 1
        if region != nil {
            menuInteraction?.dismissMenu()
        }
        clearHighlight()
    }

    /// التمرير أو التكبير غيّر مكان التحديد على الشاشة.
    func contentDidMove() {
        guard region != nil, let host else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        highlight.lineWidth = 1.5 / max(host.zoomScale, 0.05)
        CATransaction.commit()
        menuInteraction?.updateVisibleMenuPosition(animated: false)
    }

    private func present(_ region: PrintedRegion) {
        guard let host else { return }
        presentationID += 1
        self.region = region
        let overlay = host.itemsOverlay
        if highlight.superlayer !== overlay.layer {
            highlight.removeFromSuperlayer()
            overlay.layer.addSublayer(highlight)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        highlight.lineWidth = 1.5 / max(host.zoomScale, 0.05)
        highlight.path = UIBezierPath(roundedRect: region.canvasRect, cornerRadius: 3).cgPath
        highlight.opacity = 1
        CATransaction.commit()

        let rect = region.canvasRect
        let anchor = overlay.convert(CGPoint(x: rect.midX, y: rect.minY), to: host)
        menuInteraction?.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: anchor))
        UISelectionFeedbackGenerator().selectionChanged()
    }

    private func clearHighlight() {
        region = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        highlight.opacity = 0
        highlight.path = nil
        CATransaction.commit()
    }

    // MARK: UIGestureRecognizerDelegate

    /// مراقب اللاسو يعمل جنباً إلى جنب مع PencilKit ولا يمنع أي إيماءة.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        true
    }

    // MARK: UIEditMenuInteractionDelegate

    func editMenuInteraction(_ interaction: UIEditMenuInteraction,
                             menuFor configuration: UIEditMenuConfiguration,
                             suggestedActions: [UIMenuElement]) -> UIMenu? {
        guard let current = region else { return nil }
        let copySmart = UIAction(title: "نسخ", image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in
            self?.onAction?(.copySmart, current)
        }
        let copyText = UIAction(title: "نسخ كنص", image: UIImage(systemName: "text.quote")) { [weak self] _ in
            self?.onAction?(.copyText, current)
        }
        let copyImage = UIAction(title: "نسخ كصورة", image: UIImage(systemName: "photo")) { [weak self] _ in
            self?.onAction?(.copyImage, current)
        }
        let lift = UIAction(title: "رفع وتحريك",
                            image: UIImage(systemName: "arrow.up.and.down.and.arrow.left.and.right")) { [weak self] _ in
            self?.onAction?(.lift, current)
        }
        let aiActions = [PrintedAITask.translate, .explain, .latex].map { task in
            UIAction(title: task.menuTitle, image: UIImage(systemName: task.symbol)) { [weak self] _ in
                self?.onAction?(.ai(task), current)
            }
        }
        let ai = UIMenu(title: "Gemini", image: UIImage(systemName: "sparkles"), children: aiActions)
        return UIMenu(children: [copySmart, copyText, copyImage, lift, ai])
    }

    func editMenuInteraction(_ interaction: UIEditMenuInteraction,
                             targetRectFor configuration: UIEditMenuConfiguration) -> CGRect {
        guard let host, let region else { return .null }
        return host.itemsOverlay.convert(region.canvasRect, to: host)
    }

    func editMenuInteraction(_ interaction: UIEditMenuInteraction,
                             willDismissMenuFor configuration: UIEditMenuConfiguration,
                             animator: any UIEditMenuInteractionAnimating) {
        let dismissed = presentationID
        animator.addCompletion { [weak self] in
            // لا نمسح تحديداً جديداً ظهر أثناء حركة الإخفاء
            guard let self, self.presentationID == dismissed else { return }
            self.clearHighlight()
        }
    }
}
