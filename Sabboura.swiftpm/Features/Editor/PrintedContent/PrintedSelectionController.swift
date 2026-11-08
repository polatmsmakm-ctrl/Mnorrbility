import UIKit

/// تحديد المحتوى المطبوع بأداة التحديد الحر الموجودة:
/// إذا رسم المستخدم مساراً لا يحتوي كتابة يد، يُفحص ما تحته من PDF أو مستند ممسوح أو صورة،
/// فإن وُجد محتوى يُظلَّل ويظهر نفس شريط أوامر التحديد بأوامر المحتوى المطبوع.
final class PrintedSelectionController {
    enum Action {
        /// يختار الأنسب تلقائياً (نص أو صورة)
        case copySmart
        case copyText
        case copyImage
        /// يرفع نسخة من المحتوى كعنصر يُسحب لأي مكان
        case lift
        /// ترجمة، شرح معادلة، تحويل إلى LaTeX
        case ai(PrintedAITask)
    }

    /// يحوّل مسار اللاسو (إحداثيات اللوحة بدون تكبير) إلى منطقة مطبوعة، أو nil إن لم يكن تحته محتوى مطبوع.
    var resolveRegion: (([CGPoint]) -> PrintedRegion?)?
    var onAction: ((Action, PrintedRegion) -> Void)?

    private weak var host: PageCanvasContainerView?
    private let highlight = CAShapeLayer()
    private(set) var region: PrintedRegion?
    private var requestID = 0

    var isActive: Bool { region != nil }

    func install(in host: PageCanvasContainerView) {
        self.host = host
        highlight.fillColor = UIColor.systemBlue.withAlphaComponent(0.12).cgColor
        highlight.strokeColor = UIColor.systemBlue.withAlphaComponent(0.85).cgColor
        highlight.lineDashPattern = [6, 4]
        highlight.lineJoin = .round
        highlight.zPosition = 900
        highlight.opacity = 0
    }

    // MARK: اللاسو

    /// انتهى مسار لاسو لا يحتوي كتابة يد (النقاط بإحداثيات اللوحة بدون تكبير).
    /// `onNothing` يُستدعى إن لم يكن تحت المسار محتوى مطبوع.
    func handleLasso(_ points: [CGPoint], onNothing: @escaping () -> Void) {
        guard let candidate = resolveRegion?(points) else {
            onNothing()
            return
        }
        requestID += 1
        let request = requestID
        PrintedContentService.shared.analyze(candidate) { [weak self] refined in
            guard let self, request == self.requestID else { return }
            guard let refined else {
                onNothing()
                return
            }
            self.present(refined)
        }
    }

    /// يلغي التحديد الظاهر أو قيد التحليل.
    func dismiss() {
        requestID += 1
        guard region != nil else { return }
        region = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        highlight.opacity = 0
        highlight.path = nil
        CATransaction.commit()
        host?.hidePrintedSelectionBar()
    }

    /// التمرير أو التكبير غيّر مكان التحديد على الشاشة.
    func contentDidMove() {
        guard let region, let host else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        highlight.lineWidth = 1.5 / max(host.zoomScale, 0.05)
        CATransaction.commit()
        host.layoutPrintedSelectionBar(around: region.canvasRect)
    }

    // MARK: العرض

    private func present(_ region: PrintedRegion) {
        guard let host else { return }
        self.region = region
        let overlay = host.itemsOverlay
        if highlight.superlayer !== overlay.layer {
            highlight.removeFromSuperlayer()
            overlay.layer.addSublayer(highlight)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let zoom = max(host.zoomScale, 0.05)
        highlight.lineWidth = 1.5 / zoom
        highlight.lineDashPattern = [NSNumber(value: Double(6 / zoom)), NSNumber(value: Double(4 / zoom))]
        highlight.path = UIBezierPath(roundedRect: region.canvasRect, cornerRadius: 4).cgPath
        highlight.opacity = 1
        CATransaction.commit()
        showMainActions()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func showMainActions() {
        guard let region, let host else { return }
        host.showPrintedSelectionBar([
            .init(title: "نسخ", symbol: "doc.on.doc") { [weak self] in self?.fire(.copySmart) },
            .init(title: "نص", symbol: "text.quote") { [weak self] in self?.fire(.copyText) },
            .init(title: "صورة", symbol: "photo") { [weak self] in self?.fire(.copyImage) },
            .init(title: "رفع", symbol: "arrow.up.and.down.and.arrow.left.and.right") { [weak self] in self?.fire(.lift) },
            .init(title: "ذكاء", symbol: "sparkles") { [weak self] in self?.showAIActions() }
        ], around: region.canvasRect)
    }

    private func showAIActions() {
        guard let region, let host else { return }
        var actions: [SelectionMenuBar.Action] = [PrintedAITask.translate, .explain, .latex].map { task in
            SelectionMenuBar.Action(title: task.menuTitle, symbol: task.symbol) { [weak self] in
                self?.fire(.ai(task))
            }
        }
        actions.append(.init(title: "رجوع", symbol: "arrow.uturn.backward") { [weak self] in self?.showMainActions() })
        host.showPrintedSelectionBar(actions, around: region.canvasRect)
    }

    private func fire(_ action: Action) {
        guard let current = region else { return }
        dismiss()
        onAction?(action, current)
    }
}
