import PencilKit
import UIKit
import UniformTypeIdentifiers

/// لوحة الكتابة الأساسية المبنية على PKCanvasView من PencilKit.
///
/// - كل الصفحات مرصوصة عمودياً في لوحة واحدة (وضع التمرير المتصل) أو صفحة واحدة.
/// - الحبر يُرسم بمحرك PencilKit الرسمي (الضغط والميلان والتنبؤ بحركة القلم).
/// - الخلفية طبقة مقسّمة أسفل الحبر، وطبقة النصوص والصور فوقه، وكلها تتكبّر مع اللوحة.
/// - الوضع الداكن: PencilKit يحوّل ألوان الحبر تلقائياً (الأسود يظهر أبيض).
final class PageCanvasContainerView: UIView, PKCanvasViewDelegate, UIPencilInteractionDelegate {
    let canvas = PKCanvasView()
    let itemsOverlay = ItemsOverlayView(frame: .zero)
    /// الصور والنصوص تُعرض هنا (فوق الخلفية وتحت الحبر) حتى تكتب فوقها بالقلم
    private let itemsContentView = UIView()

    var onDrawingChanged: (() -> Void)?
    var onZoomChanged: ((CGFloat) -> Void)?
    var onPencilDoubleTap: (() -> Void)?
    var onVisiblePageChanged: ((Int) -> Void)?
    /// رسالة قصيرة للمستخدم (ترتيب الخط)
    var onMessage: ((String) -> Void)?
    /// تحويل الكتابة المحددة لنص: صورة الكتابة على خلفية بيضاء وإطارها بإحداثيات اللوحة
    var onConvertSelectionToText: ((UIImage, CGRect) -> Void)?
    /// حل المسألة المحددة
    var onSolveSelection: ((UIImage, CGRect) -> Void)?
    /// وضع الاستماع: ضغطة على خط مكتوب ترجع وقت كتابته
    var onReplayTap: ((Date) -> Void)?

    /// مساحة أعلى اللوحة لشريط الأدوات العائم، وأسفلها لمؤشر الصفحات.
    var topInset: CGFloat = 0 {
        didSet {
            guard topInset != oldValue else { return }
            let zoom = max(canvas.zoomScale, 0.0001)
            let anchor = CGPoint(x: (canvas.contentOffset.x + canvas.contentInset.left) / zoom,
                                 y: (canvas.contentOffset.y + canvas.contentInset.top) / zoom)
            syncGeometry()
            restore(anchor: anchor)
        }
    }
    var bottomInset: CGFloat = 0 { didSet { if bottomInset != oldValue { syncGeometry() } } }

    static let pageGap: CGFloat = 18

    private let backgroundView = PageBackgroundView()
    private let lassoLayer = CAShapeLayer()
    private let areaGesture = LassoPathGestureRecognizer(target: nil, action: nil)
    /// مؤشر الليزر: طبقة فوق اللوحة (لا تتحرك مع التمرير) والتقاط لمس مستقل عن ممحاة التحديد
    private let laserView = LaserTrailView()
    private let laserGesture = LassoPathGestureRecognizer(target: nil, action: nil)
    private var laserProcessedPoints = 0

    private var pages: [PageRenderInfo] = []
    private var contentExtent = DataStore.standardPageSize
    private var seamless = true
    private var fitScale: CGFloat = 1
    private var lastLayoutSize: CGSize = .zero
    private var needsFit = true
    private var pendingScrollPage: Int?
    private var isLoading = false
    private var appliedState: CanvasToolState?
    private var savedPanMinimumTouches: Int?
    private var lastReportedPage = -1

    // MARK: التحديد والنقل والنسخ
    /// الكتابة المحددة: تُرفع من اللوحة وتُعرض كصورة تُسحب بسلاسة، وتعود للوحة عند إنهاء التحديد.
    private struct FloatingSelection {
        var strokes: [PKStroke]
        var rest: [PKStroke]
        var rect: CGRect
        var offset: CGPoint = .zero
        /// نسخ جديدة (لصق أو تكرار) لم تكن في اللوحة قبل التحديد
        var isNew = false
    }
    private var selection: FloatingSelection?
    private let selectionPan = UIPanGestureRecognizer()
    private let panDelegate = ClosureGestureDelegate()
    private let selectionView = StrokeSelectionView()
    private let selectionBar = SelectionMenuBar()
    private var pastePoint: CGPoint?
    private static let strokesPasteboardType = "com.sabboura.strokes"

    /// ماذا يفعل مسار التحديد الحر: مسح الكتابة أو ترتيبها
    private enum AreaAction { case erase, tidy, select }
    private var areaAction: AreaAction = .erase
    private let holdObserver = StrokeHoldObserver(target: nil, action: nil)
    private var lastStrokeCount = 0
    private var isReplacing = false

    // MARK: وضع الاستماع (ربط التسجيل بالكتابة)
    private let replayTap = UITapGestureRecognizer()
    private let replayLayer = CAShapeLayer()
    private var replayHighlightDate: Date?
    private(set) var isReplayMode = false
    private var smartShapes = true
    private var tidyOptions = TidyOptions()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        clipsToBounds = true
        accessibilityIdentifier = "canvas"

        canvas.accessibilityIdentifier = "pkcanvas"
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.overrideUserInterfaceStyle = .light
        canvas.contentInsetAdjustmentBehavior = .never
        canvas.delegate = self
        canvas.drawingPolicy = .anyInput
        canvas.bouncesZoom = true
        canvas.alwaysBounceVertical = true
        canvas.showsHorizontalScrollIndicator = false
        canvas.minimumZoomScale = 0.25
        canvas.maximumZoomScale = 6
        canvas.delaysContentTouches = false
        canvas.frame = bounds
        canvas.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(canvas)

        canvas.insertSubview(backgroundView, at: 0)
        itemsContentView.isUserInteractionEnabled = false
        itemsContentView.backgroundColor = .clear
        canvas.insertSubview(itemsContentView, aboveSubview: backgroundView)
        itemsOverlay.contentHost = itemsContentView
        canvas.addSubview(itemsOverlay)

        lassoLayer.fillColor = UIColor(red: 0.86, green: 0.15, blue: 0.15, alpha: 0.08).cgColor
        lassoLayer.strokeColor = UIColor(red: 0.86, green: 0.15, blue: 0.15, alpha: 0.9).cgColor
        lassoLayer.lineWidth = 1.5
        lassoLayer.lineDashPattern = [6, 4]
        lassoLayer.lineJoin = .round
        lassoLayer.zPosition = 1000
        canvas.layer.addSublayer(lassoLayer)

        canvas.addGestureRecognizer(holdObserver)

        replayLayer.fillColor = UIColor.systemYellow.withAlphaComponent(0.32).cgColor
        replayLayer.strokeColor = UIColor.systemOrange.withAlphaComponent(0.7).cgColor
        replayLayer.lineWidth = 1
        replayLayer.zPosition = 999
        canvas.layer.addSublayer(replayLayer)
        replayTap.addTarget(self, action: #selector(handleReplayTap(_:)))
        replayTap.isEnabled = false
        canvas.addGestureRecognizer(replayTap)

        selectionPan.addTarget(self, action: #selector(handleSelectionPan(_:)))
        panDelegate.shouldBegin = { [weak self] gesture in self?.selectionPanShouldBegin(gesture) ?? false }
        selectionPan.delegate = panDelegate
        selectionPan.isEnabled = false
        selectionPan.maximumNumberOfTouches = 1
        selectionPan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue),
                                          NSNumber(value: UITouch.TouchType.pencil.rawValue)]
        canvas.addGestureRecognizer(selectionPan)
        canvas.panGestureRecognizer.require(toFail: selectionPan)
        areaGesture.shouldBeginAt = { [weak self] point in !(self?.isInsideSelection(point) ?? false) }

        selectionView.isHidden = true
        selectionBar.isHidden = true
        addSubview(selectionView)
        addSubview(selectionBar)

        areaGesture.addTarget(self, action: #selector(handleAreaGesture(_:)))
        areaGesture.isEnabled = false
        areaGesture.cancelsTouchesInView = true
        canvas.addGestureRecognizer(areaGesture)

        laserGesture.addTarget(self, action: #selector(handleLaserGesture(_:)))
        laserGesture.isEnabled = false
        laserGesture.cancelsTouchesInView = true
        canvas.addGestureRecognizer(laserGesture)

        laserView.frame = bounds
        laserView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(laserView)

        let pencilInteraction = UIPencilInteraction()
        pencilInteraction.delegate = self
        addInteraction(pencilInteraction)
    }

    // لوحة PencilKit تخفي ما بداخلها عن تقنيات الإتاحة، فنعرض النصوص والصور بجانبها صراحةً.
    override var accessibilityElements: [Any]? {
        get {
            var elements: [Any] = [canvas] + itemsOverlay.accessibleItemViews
            // أزرار شريط التحديد (نسخ، نص، حل …) تظهر لـ VoiceOver واختبارات الواجهة
            if !selectionBar.isHidden { elements.append(contentsOf: selectionBar.buttons) }
            return elements
        }
        set { }
    }

    // MARK: عرض الصفحات

    /// يعرض الصفحات مع رسمها المجمّع (إحداثيات اللوحة).
    func configure(pages: [PageRenderInfo], drawing: PKDrawing, deskColor: UIColor, dark: Bool,
                   seamless: Bool, scrollToPage: Int?) {
        isLoading = true
        dropSelectionUI()
        self.pages = pages
        self.seamless = seamless
        backgroundColor = deskColor
        contentExtent = Self.extent(of: pages)
        canvas.overrideUserInterfaceStyle = dark ? .dark : .light
        backgroundView.configure(pages: pages, deskColor: deskColor)
        canvas.drawing = drawing
        lastStrokeCount = drawing.strokes.count
        canvas.undoManager?.removeAllActions()
        isLoading = false
        pendingScrollPage = scrollToPage
        lastReportedPage = -1
        needsFit = true
        updateZoomRange(forceFit: true)
    }

    /// تحديث الخلفيات فقط (نوع الورقة أو اللون أو الوضع الداكن) دون المساس بالرسم.
    func updateBackgrounds(pages: [PageRenderInfo], deskColor: UIColor, dark: Bool) {
        self.pages = pages
        backgroundColor = deskColor
        canvas.overrideUserInterfaceStyle = dark ? .dark : .light
        backgroundView.configure(pages: pages, deskColor: deskColor)
    }

    /// يضيف صفحات في آخر اللوحة دون المساس بالرسم أو التكبير أو مكان التمرير.
    func extendPages(_ newPages: [PageRenderInfo], deskColor: UIColor, dark: Bool) {
        pages = newPages
        contentExtent = Self.extent(of: newPages)
        backgroundView.configure(pages: newPages, deskColor: deskColor)
        syncGeometry()
        itemsOverlay.setNeedsLayout()
    }

    private static func extent(of pages: [PageRenderInfo]) -> CGSize {
        guard let last = pages.last else { return DataStore.standardPageSize }
        let width = pages.map(\.size.width).max() ?? DataStore.standardPageSize.width
        return CGSize(width: width, height: last.originY + last.size.height)
    }

    /// الرسم الكامل بما فيه الكتابة المحددة حالياً (المرفوعة مؤقتاً من اللوحة).
    var currentDrawing: PKDrawing {
        guard let selection else { return canvas.drawing }
        return PKDrawing(strokes: canvas.drawing.strokes + movedStrokes(of: selection))
    }

    /// سجل التراجع المشترك بين الكتابة والنصوص والصور.
    var itemsUndoManager: UndoManager? { canvas.undoManager }

    /// وسط الجزء الظاهر من الصفحات (بإحداثيات الرسم) — مكان إدراج الصور.
    var visibleContentCenter: CGPoint {
        let zoom = max(canvas.zoomScale, 0.0001)
        let visibleTop = canvas.contentOffset.y + canvas.contentInset.top
        let visibleHeight = max(1, canvas.bounds.height - canvas.contentInset.top - bottomInset)
        let x = (canvas.contentOffset.x + canvas.bounds.width / 2) / zoom
        let y = (visibleTop + visibleHeight / 2) / zoom
        return CGPoint(x: min(max(x, 0), contentExtent.width), y: min(max(y, 0), contentExtent.height))
    }
    var zoomScale: CGFloat { canvas.zoomScale }

    // MARK: الأدوات

    func apply(_ state: CanvasToolState) {
        guard state != appliedState else { return }
        appliedState = state
        canvas.drawingPolicy = state.fingerDrawing ? .anyInput : .pencilOnly
        canvas.isRulerActive = state.rulerActive

        smartShapes = state.smartShapes
        tidyOptions = state.tidy
        let textMode = state.tools.kind == .text
        let tidyMode = state.tools.kind == .tidy
        let selectMode = state.tools.kind == .lasso
        let areaMode = tidyMode || selectMode || (state.tools.kind == .eraser && state.tools.eraserMode == .area)
        areaAction = tidyMode ? .tidy : (selectMode ? .select : .erase)
        if !selectMode { commitSelection() }
        let tint = tidyMode ? UIColor.systemIndigo
            : (selectMode ? UIColor.systemBlue : UIColor(red: 0.86, green: 0.15, blue: 0.15, alpha: 1))
        lassoLayer.strokeColor = tint.withAlphaComponent(0.9).cgColor
        lassoLayer.fillColor = tint.withAlphaComponent(0.08).cgColor
        itemsOverlay.isEditingEnabled = textMode
        let laserMode = state.tools.kind == .laser
        laserView.color = UIColor(hex: state.tools.color(for: .laser))
        laserView.dotSize = CGFloat(state.tools.width(for: .laser))
        setAreaEraseActive(areaMode, laser: laserMode, allowFinger: state.fingerDrawing)
        canvas.drawingGestureRecognizer.isEnabled = !(areaMode || textMode || laserMode)
        if !areaMode && !textMode && !laserMode {
            canvas.tool = state.tools.makePKTool()
        }
        if isReplayMode { disableEditingForReplay() }
    }

    private func setAreaEraseActive(_ active: Bool, laser: Bool = false, allowFinger: Bool) {
        areaGesture.isEnabled = active
        laserGesture.isEnabled = laser
        var touchTypes = [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
        if allowFinger {
            touchTypes.append(NSNumber(value: UITouch.TouchType.direct.rawValue))
        }
        areaGesture.allowedTouchTypes = touchTypes
        laserGesture.allowedTouchTypes = touchTypes
        if !laser {
            laserView.clear()
            laserProcessedPoints = 0
        }

        if (active || laser) && allowFinger {
            if savedPanMinimumTouches == nil {
                savedPanMinimumTouches = canvas.panGestureRecognizer.minimumNumberOfTouches
            }
            canvas.panGestureRecognizer.minimumNumberOfTouches = 2
        } else if let saved = savedPanMinimumTouches {
            canvas.panGestureRecognizer.minimumNumberOfTouches = saved
            savedPanMinimumTouches = nil
        }
        if !active {
            lassoLayer.path = nil
        }
    }

    // MARK: التراجع والإعادة

    var canUndo: Bool { canvas.undoManager?.canUndo ?? false }
    var canRedo: Bool { canvas.undoManager?.canRedo ?? false }

    func undo() { commitSelection(); canvas.undoManager?.undo() }
    func redo() { commitSelection(); canvas.undoManager?.redo() }

    /// يستبدل الرسم كاملاً مع تسجيل خطوة تراجع (تُستخدم لمسح الصفحة وممحاة التحديد).
    func replaceDrawing(_ newDrawing: PKDrawing, actionName: String) {
        commitSelection()
        let oldDrawing = canvas.drawing
        isReplacing = true
        canvas.drawing = newDrawing
        lastStrokeCount = newDrawing.strokes.count
        isReplacing = false
        if let undoManager = canvas.undoManager {
            undoManager.registerUndo(withTarget: self) { target in
                target.replaceDrawing(oldDrawing, actionName: actionName)
            }
            undoManager.setActionName(actionName)
        }
        onDrawingChanged?()
    }

    // MARK: التكبير والتمرير

    func zoom(by factor: CGFloat) {
        let target = min(max(canvas.zoomScale * factor, canvas.minimumZoomScale), canvas.maximumZoomScale)
        canvas.setZoomScale(target, animated: true)
    }

    func zoomToFit() {
        canvas.setZoomScale(fitScale, animated: true)
    }

    func scrollToPage(_ index: Int, animated: Bool) {
        guard let page = pages.first(where: { $0.index == index }) ?? pages.first else { return }
        let zoom = canvas.zoomScale
        let maxOffset = max(-canvas.contentInset.top,
                            canvas.contentSize.height + canvas.contentInset.bottom - canvas.bounds.height)
        let target = min(page.originY * zoom - canvas.contentInset.top + (seamless ? 0 : 0), maxOffset)
        canvas.setContentOffset(CGPoint(x: canvas.contentOffset.x, y: max(-canvas.contentInset.top, target)),
                                animated: animated)
        lastReportedPage = page.index
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if canvas.frame != bounds {
            canvas.frame = bounds
        }
        if bounds.size != lastLayoutSize || needsFit {
            lastLayoutSize = bounds.size
            updateZoomRange(forceFit: needsFit)
        }
    }

    private func updateZoomRange(forceFit: Bool) {
        let available = canvas.bounds.size
        guard available.width > 40, available.height > 40, contentExtent.width > 0 else { return }

        let wasAtFit = abs(canvas.zoomScale - fitScale) < 0.005
        // النقطة الظاهرة أعلى الشاشة (بإحداثيات الصفحات) لنحافظ عليها بعد تغيّر الحجم
        // (مثلاً عند إخفاء القائمة الجانبية في الآيباد أو تدوير الجهاز)
        let oldZoom = max(canvas.zoomScale, 0.0001)
        let anchor = CGPoint(x: (canvas.contentOffset.x + canvas.contentInset.left) / oldZoom,
                             y: (canvas.contentOffset.y + canvas.contentInset.top) / oldZoom)
        let margin: CGFloat = seamless ? 0 : 16
        let widthFit = (available.width - margin * 2) / contentExtent.width
        fitScale = max(0.1, widthFit)

        canvas.minimumZoomScale = max(0.1, fitScale * 0.5)
        canvas.maximumZoomScale = max(fitScale * 6, 2)

        if forceFit || wasAtFit {
            canvas.setZoomScale(fitScale, animated: false)
        } else {
            let clamped = min(max(canvas.zoomScale, canvas.minimumZoomScale), canvas.maximumZoomScale)
            if clamped != canvas.zoomScale {
                canvas.setZoomScale(clamped, animated: false)
            }
        }
        needsFit = false
        syncGeometry()
        if forceFit {
            if let page = pendingScrollPage {
                pendingScrollPage = nil
                scrollToPage(page, animated: false)
            } else {
                canvas.setContentOffset(CGPoint(x: -canvas.contentInset.left, y: -canvas.contentInset.top), animated: false)
            }
            reportVisiblePage()
        } else {
            restore(anchor: anchor)
        }
        reportZoom()
    }

    /// يعيد التمرير بحيث تبقى النقطة نفسها من الصفحات أعلى المنطقة الظاهرة.
    private func restore(anchor: CGPoint) {
        let zoom = canvas.zoomScale
        let inset = canvas.contentInset
        let size = canvas.contentSize
        let bounds = canvas.bounds.size
        let maxX = max(-inset.left, size.width + inset.right - bounds.width)
        let maxY = max(-inset.top, size.height + inset.bottom - bounds.height)
        let x = min(max(anchor.x * zoom - inset.left, -inset.left), maxX)
        let y = min(max(anchor.y * zoom - inset.top, -inset.top), maxY)
        let target = CGPoint(x: x, y: y)
        if abs(target.x - canvas.contentOffset.x) > 0.5 || abs(target.y - canvas.contentOffset.y) > 0.5 {
            canvas.setContentOffset(target, animated: false)
        }
    }

    private func reportZoom() {
        onZoomChanged?(canvas.zoomScale / max(fitScale, 0.0001))
        itemsOverlay.updateContentScale(canvas.zoomScale)
    }

    /// يطابق حجم المحتوى والخلفية مع مستوى التكبير الحالي ويوسّط الصفحات.
    private func syncGeometry() {
        let zoom = canvas.zoomScale
        let scaled = CGSize(width: contentExtent.width * zoom, height: contentExtent.height * zoom)

        if abs(canvas.contentSize.width - scaled.width) > 0.5 || abs(canvas.contentSize.height - scaled.height) > 0.5 {
            canvas.contentSize = scaled
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let extentBounds = CGRect(origin: .zero, size: contentExtent)
        for view in [backgroundView as UIView, itemsContentView, itemsOverlay as UIView] {
            if view.bounds != extentBounds { view.bounds = extentBounds }
            view.transform = CGAffineTransform(scaleX: zoom, y: zoom)
            view.center = CGPoint(x: scaled.width / 2, y: scaled.height / 2)
        }
        CATransaction.commit()

        let margin: CGFloat = seamless ? 0 : 16
        let insetX = max(margin, (canvas.bounds.width - scaled.width) / 2)
        let insetTop = max(topInset + (seamless ? 0 : 12), (canvas.bounds.height - scaled.height) / 2)
        let insets = UIEdgeInsets(top: insetTop, left: insetX, bottom: bottomInset + 24, right: insetX)
        if canvas.contentInset != insets {
            canvas.contentInset = insets
        }

        // نعيد ترتيب الطبقات فقط إن اختل ترتيبها (هذه الدالة تُستدعى في كل إطار أثناء التكبير)
        if canvas.subviews.first !== backgroundView {
            canvas.sendSubviewToBack(backgroundView)
        }
        if canvas.subviews.dropFirst().first !== itemsContentView {
            canvas.insertSubview(itemsContentView, aboveSubview: backgroundView)
        }
        if canvas.subviews.last !== itemsOverlay {
            canvas.bringSubviewToFront(itemsOverlay)
        }
    }

    private func reportVisiblePage() {
        guard !pages.isEmpty else { return }
        let zoom = max(canvas.zoomScale, 0.0001)
        let visibleTop = canvas.contentOffset.y + canvas.contentInset.top
        let visibleHeight = canvas.bounds.height - canvas.contentInset.top - bottomInset
        let centerY = (visibleTop + visibleHeight * 0.4) / zoom
        var best = pages[0]
        for page in pages where page.originY - Self.pageGap / 2 <= centerY {
            best = page
        }
        if best.index != lastReportedPage {
            lastReportedPage = best.index
            onVisiblePageChanged?(best.index)
        }
    }

    // MARK: PKCanvasViewDelegate / UIScrollViewDelegate

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        guard !isLoading else { return }
        // لا نقرأ canvas.drawing هنا أبداً: قراءته نسخ كامل للرسم (تثقل مع الكتابة الكثيرة والممحاة)
        // وقد تُلغي التحديد الجاري بأداة التحديد الحر.
        onDrawingChanged?()
        // الأشكال الذكية: خط جديد انتهى والقلم ثابت لحظة
        if smartShapes && !isReplacing && (appliedState?.tools.kind.isInk ?? false) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { [weak self] in
                self?.snapLastStrokeIfHeld()
            }
        }
    }

    private func snapLastStrokeIfHeld() {
        // التثبيت لا يُستهلك إلا مرة واحدة، فلا يتأثر التراجع أو الخطوط التي بعده
        guard CACurrentMediaTime() - holdObserver.lastHoldEndTime < 0.9 else { return }
        holdObserver.lastHoldEndTime = 0
        let drawing = canvas.drawing
        guard let last = drawing.strokes.last,
              Date().timeIntervalSince(last.path.creationDate) < 30,
              let shape = ShapeRecognizer.snapped(last) else { return }
        var strokes = drawing.strokes
        strokes[strokes.count - 1] = shape
        replaceDrawing(PKDrawing(strokes: strokes), actionName: "شكل مضبوط")
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        if AppEnvironment.isUITest { onMessage?("shape-snapped") }
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        syncGeometry()
        layoutSelectionUI()
        updateReplayHighlight()
    }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        syncGeometry()
        reportZoom()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        layoutSelectionUI()
        if seamless { reportVisiblePage() }
    }

    // MARK: قلم أبل — النقر المزدوج

    func pencilInteractionDidTap(_ interaction: UIPencilInteraction) {
        onPencilDoubleTap?()
    }

    // MARK: ممحاة التحديد (مسح كتلة كاملة)

    @objc private func handleAreaGesture(_ gesture: LassoPathGestureRecognizer) {
        switch gesture.state {
        case .began, .changed:
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            lassoLayer.opacity = 1
            lassoLayer.path = Self.path(from: gesture.points, closed: false).cgPath
            CATransaction.commit()
        case .ended:
            let points = gesture.points
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            lassoLayer.path = Self.path(from: points, closed: true).cgPath
            CATransaction.commit()
            switch areaAction {
            case .erase: eraseStrokes(enclosedBy: points)
            case .tidy: tidyStrokes(enclosedBy: points)
            case .select: selectStrokes(enclosedBy: points)
            }
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.25)
            lassoLayer.opacity = 0
            CATransaction.commit()
        default:
            lassoLayer.path = nil
        }
    }

    // MARK: مؤشر الليزر

    @objc private func handleLaserGesture(_ gesture: LassoPathGestureRecognizer) {
        switch gesture.state {
        case .began, .changed:
            // نقاط اللمس بإحداثيات اللوحة (محتوى مُمرَّر)، فنحوّلها لإحداثيات الشاشة
            let points = gesture.points
            guard laserProcessedPoints < points.count else { return }
            let fresh = points[laserProcessedPoints...].map { canvas.convert($0, to: laserView) }
            if laserProcessedPoints == 0, let first = fresh.first {
                laserView.begin(at: first)
                laserView.append(Array(fresh.dropFirst()))
            } else {
                laserView.append(fresh)
            }
            laserProcessedPoints = points.count
        default:
            laserProcessedPoints = 0
            laserView.end()
        }
    }

    private func eraseStrokes(enclosedBy contentPoints: [CGPoint]) {
        guard let lastContentPoint = contentPoints.last else { return }
        let zoom = max(canvas.zoomScale, 0.0001)
        let canvasPoints = contentPoints.map { CGPoint(x: $0.x / zoom, y: $0.y / zoom) }
        let contentBounds = Self.boundingRect(of: contentPoints)
        let drawing = canvas.drawing

        var remaining: [PKStroke] = []
        var removedCount = 0

        if contentBounds.width < 10 && contentBounds.height < 10 {
            // نقرة: احذف الخط الموجود تحت نقطة اللمس
            let point = CGPoint(x: lastContentPoint.x / zoom, y: lastContentPoint.y / zoom)
            let tolerance = 12 / zoom
            for stroke in drawing.strokes {
                if Self.stroke(stroke, passesNear: point, tolerance: tolerance) {
                    removedCount += 1
                } else {
                    remaining.append(stroke)
                }
            }
        } else {
            let lasso = Self.path(from: canvasPoints, closed: true)
            let lassoBounds = Self.boundingRect(of: canvasPoints)
            for stroke in drawing.strokes {
                if Self.stroke(stroke, isInside: lasso, bounds: lassoBounds) {
                    removedCount += 1
                } else {
                    remaining.append(stroke)
                }
            }
        }

        guard removedCount > 0 else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        replaceDrawing(PKDrawing(strokes: remaining), actionName: "مسح التحديد")
    }

    // MARK: ترتيب الخط

    private func tidyStrokes(enclosedBy contentPoints: [CGPoint]) {
        let zoom = max(canvas.zoomScale, 0.0001)
        let canvasPoints = contentPoints.map { CGPoint(x: $0.x / zoom, y: $0.y / zoom) }
        let area = Self.boundingRect(of: canvasPoints)
        guard area.width > 12 || area.height > 12 else {
            onMessage?("ارسم دائرة حول الكتابة اللي تبي ترتبها")
            return
        }
        let lasso = Self.path(from: canvasPoints, closed: true)
        let drawing = canvas.drawing
        var selected: [Int] = []
        for (index, stroke) in drawing.strokes.enumerated() where stroke.renderBounds.intersects(area) {
            let points = InkGeometry.points(of: stroke, spacing: 4)
            let inside = points.filter { lasso.contains($0) }.count
            if CGFloat(inside) >= CGFloat(points.count) * 0.5 {
                selected.append(index)
            }
        }
        applyTidy(to: selected)
    }

    /// يرتّب كل كتابة الصفحة المحددة.
    func tidyPage(_ pageIndex: Int) {
        guard let page = pages.first(where: { $0.index == pageIndex }) ?? pages.first else { return }
        let band = page.frame.insetBy(dx: -40, dy: -Self.pageGap / 2)
        // نقرأ الرسم مرة واحدة (القراءة نسخ كامل، وكانت تتكرر لكل خط)
        let strokes = canvas.drawing.strokes
        let selected = strokes.indices.filter {
            let bounds = strokes[$0].renderBounds
            return band.contains(CGPoint(x: bounds.midX, y: bounds.midY))
        }
        applyTidy(to: selected)
    }

    private func applyTidy(to indices: [Int]) {
        guard !indices.isEmpty else {
            onMessage?("ما لقيت كتابة داخل التحديد")
            return
        }
        let guides = pages.map { PageGuides(page: $0) }
        guard let tidied = HandwritingTidy.tidy(canvas.drawing, selecting: indices, guides: guides, options: tidyOptions) else {
            onMessage?("الكتابة مرتبة أصلاً ✨")
            return
        }
        replaceDrawing(tidied, actionName: "ترتيب الخط")
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        onMessage?("تم ترتيب الخط — تقدر تتراجع إذا ما عجبك")
    }

    private static func stroke(_ stroke: PKStroke, isInside lasso: UIBezierPath, bounds: CGRect) -> Bool {
        guard stroke.renderBounds.intersects(bounds) else { return false }
        for point in stroke.path.interpolatedPoints(by: .distance(4)) {
            if lasso.contains(point.location.applying(stroke.transform)) {
                return true
            }
        }
        return false
    }

    private static func stroke(_ stroke: PKStroke, passesNear target: CGPoint, tolerance: CGFloat) -> Bool {
        guard stroke.renderBounds.insetBy(dx: -tolerance, dy: -tolerance).contains(target) else { return false }
        for point in stroke.path.interpolatedPoints(by: .distance(2)) {
            let location = point.location.applying(stroke.transform)
            let reach = tolerance + point.size.width / 2
            if hypot(location.x - target.x, location.y - target.y) <= reach {
                return true
            }
        }
        return false
    }

    private static func path(from points: [CGPoint], closed: Bool) -> UIBezierPath {
        let path = UIBezierPath()
        guard let first = points.first else { return path }
        path.move(to: first)
        for point in points.dropFirst() {
            path.addLine(to: point)
        }
        if closed { path.close() }
        return path
    }

    private static func boundingRect(of points: [CGPoint]) -> CGRect {
        guard let first = points.first else { return .zero }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for point in points {
            minX = min(minX, point.x); maxX = max(maxX, point.x)
            minY = min(minY, point.y); maxY = max(maxY, point.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

// MARK: - تحديد الكتابة ونقلها ونسخها

extension PageCanvasContainerView {
    // MARK: أدوات مساعدة

    private func movedStrokes(of sel: FloatingSelection) -> [PKStroke] {
        guard sel.offset != .zero else { return sel.strokes }
        let shift = CGAffineTransform(translationX: sel.offset.x, y: sel.offset.y)
        return sel.strokes.map { stroke in
            var moved = stroke
            moved.transform = stroke.transform.concatenating(shift)
            return moved
        }
    }

    /// إطار التحديد بإحداثيات المحتوى (مكبّر مع التكبير الحالي)
    private func selectionContentRect(_ sel: FloatingSelection) -> CGRect {
        let zoom = max(canvas.zoomScale, 0.0001)
        return CGRect(x: (sel.rect.minX + sel.offset.x) * zoom,
                      y: (sel.rect.minY + sel.offset.y) * zoom,
                      width: sel.rect.width * zoom,
                      height: sel.rect.height * zoom)
    }

    fileprivate func isInsideSelection(_ contentPoint: CGPoint) -> Bool {
        guard let sel = selection else { return false }
        return selectionContentRect(sel).insetBy(dx: -10, dy: -10).contains(contentPoint)
    }

    // MARK: بدء التحديد

    func selectStrokes(enclosedBy contentPoints: [CGPoint]) {
        commitSelection()
        hideBar()
        let zoom = max(canvas.zoomScale, 0.0001)
        let canvasPoints = contentPoints.map { CGPoint(x: $0.x / zoom, y: $0.y / zoom) }
        let area = Self.boundingRect(of: canvasPoints)
        let isTap = area.width < 10 && area.height < 10

        let strokes = canvas.drawing.strokes
        var picked: [PKStroke] = []
        var rest: [PKStroke] = []

        if isTap, let point = canvasPoints.last {
            // نقرة: نحدد أعلى خط تحت الإصبع
            let tolerance = 12 / zoom
            var hitIndex: Int?
            for index in strokes.indices.reversed()
            where Self.stroke(strokes[index], passesNear: point, tolerance: tolerance) {
                hitIndex = index
                break
            }
            for (index, stroke) in strokes.enumerated() {
                if index == hitIndex { picked.append(stroke) } else { rest.append(stroke) }
            }
            if picked.isEmpty {
                showPasteBarIfPossible(at: point)
                return
            }
        } else {
            let lasso = Self.path(from: canvasPoints, closed: true)
            for stroke in strokes {
                var inside = false
                if stroke.renderBounds.intersects(area) {
                    let points = InkGeometry.points(of: stroke, spacing: 4)
                    let count = points.reduce(0) { $0 + (lasso.contains($1) ? 1 : 0) }
                    inside = CGFloat(count) >= CGFloat(points.count) * 0.5
                }
                if inside { picked.append(stroke) } else { rest.append(stroke) }
            }
            if picked.isEmpty {
                onMessage?("ما لقيت كتابة داخل التحديد — ارسم حولها بالكامل")
                return
            }
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        beginSelection(strokes: picked, rest: rest, isNew: false)
    }

    /// يرفع الكتابة المحددة من اللوحة ويعرضها كصورة قابلة للسحب.
    private func beginSelection(strokes: [PKStroke], rest: [PKStroke], isNew: Bool) {
        let selected = PKDrawing(strokes: strokes)
        let rect = selected.bounds.insetBy(dx: -8, dy: -8)
        guard rect.width > 1, rect.height > 1 else { return }
        let zoom = max(canvas.zoomScale, 0.0001)
        let scale = max(0.5, min(zoom * UIScreen.main.scale, 4096 / max(rect.width, rect.height)))
        var image: UIImage?
        canvas.traitCollection.performAsCurrent {
            image = selected.image(from: rect, scale: scale)
        }

        isReplacing = true
        canvas.drawing = PKDrawing(strokes: rest)
        lastStrokeCount = rest.count
        isReplacing = false

        selection = FloatingSelection(strokes: strokes, rest: rest, rect: rect, offset: .zero, isNew: isNew)
        selectionView.imageView.image = image
        selectionView.isHidden = false
        selectionPan.isEnabled = true
        showSelectionBar()
        layoutSelectionUI()
        onDrawingChanged?()
    }

    // MARK: عرض التحديد

    func layoutSelectionUI() {
        guard let sel = selection else { return }
        let frame = canvas.convert(selectionContentRect(sel), to: self)
        if selectionView.frame != frame { selectionView.frame = frame }
        placeBar(around: frame)
    }

    private func placeBar(around frame: CGRect) {
        guard !selectionBar.isHidden else { return }
        let size = selectionBar.fittingSize
        var x = frame.midX - size.width / 2
        x = min(max(x, 8), max(8, bounds.width - size.width - 8))
        var y = frame.minY - size.height - 10
        if y < topInset + 4 { y = frame.maxY + 10 }
        y = min(max(y, topInset + 4), max(topInset + 4, bounds.height - size.height - 8))
        selectionBar.frame = CGRect(x: x, y: y, width: size.width, height: size.height)
    }

    private func showSelectionBar() {
        selectionBar.set([
            .init(title: "نسخ", symbol: "doc.on.doc") { [weak self] in self?.copySelection() },
            .init(title: "قص", symbol: "scissors") { [weak self] in self?.cutSelection() },
            .init(title: "تكرار", symbol: "plus.square.on.square") { [weak self] in self?.duplicateSelection() },
            .init(title: "نص", symbol: "character.textbox") { [weak self] in self?.convertSelectionToText() },
            .init(title: "حل", symbol: "function") { [weak self] in self?.solveSelection() },
            .init(title: "حذف", symbol: "trash", destructive: true) { [weak self] in self?.deleteSelection() }
        ])
        selectionBar.isHidden = false
        selectionBar.alpha = 1
    }

    private func hideBar() {
        selectionBar.isHidden = true
        pastePoint = nil
    }

    /// نقرة على فراغ: إن كان في الحافظة كتابة منسوخة من التطبيق يظهر زر اللصق.
    private func showPasteBarIfPossible(at canvasPoint: CGPoint) {
        guard UIPasteboard.general.contains(pasteboardTypes: [Self.strokesPasteboardType]) else { return }
        pastePoint = canvasPoint
        selectionBar.set([
            .init(title: "لصق", symbol: "doc.on.clipboard") { [weak self] in self?.pasteFromClipboard() }
        ])
        selectionBar.isHidden = false
        selectionBar.alpha = 1
        let zoom = max(canvas.zoomScale, 0.0001)
        let anchor = canvas.convert(CGPoint(x: canvasPoint.x * zoom, y: canvasPoint.y * zoom), to: self)
        placeBar(around: CGRect(x: anchor.x - 1, y: anchor.y - 1, width: 2, height: 2))
    }

    // MARK: السحب

    @objc func handleSelectionPan(_ gesture: UIPanGestureRecognizer) {
        guard var sel = selection else { return }
        let zoom = max(canvas.zoomScale, 0.0001)
        switch gesture.state {
        case .began:
            selectionBar.alpha = 0
        case .changed:
            let translation = gesture.translation(in: canvas)
            gesture.setTranslation(.zero, in: canvas)
            sel.offset.x += translation.x / zoom
            sel.offset.y += translation.y / zoom
            selection = sel
            layoutSelectionUI()
        case .ended, .cancelled, .failed:
            selectionBar.alpha = 1
            layoutSelectionUI()
            onDrawingChanged?()
        default:
            break
        }
    }

    fileprivate func selectionPanShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        let location = gestureRecognizer.location(in: canvas)
        let translation = selectionPan.translation(in: canvas)
        return isInsideSelection(CGPoint(x: location.x - translation.x, y: location.y - translation.y))
    }

    // MARK: إنهاء التحديد

    /// يعيد الكتابة المحددة إلى اللوحة في مكانها الجديد (خطوة تراجع واحدة).
    func commitSelection() {
        guard let sel = selection else { return }
        selection = nil
        dropSelectionUI()

        let final = PKDrawing(strokes: sel.rest + movedStrokes(of: sel))
        let changed = sel.offset != .zero || sel.isNew
        let old = PKDrawing(strokes: sel.isNew ? sel.rest : sel.rest + sel.strokes)

        isReplacing = true
        canvas.drawing = final
        lastStrokeCount = final.strokes.count
        isReplacing = false
        if changed, let undoManager = canvas.undoManager {
            let name = sel.isNew ? "لصق" : "نقل التحديد"
            undoManager.registerUndo(withTarget: self) { target in
                target.replaceDrawing(old, actionName: name)
            }
            undoManager.setActionName(name)
        }
        onDrawingChanged?()
    }

    /// يخفي واجهة التحديد دون المساس بالرسم (قبل إعادة بناء اللوحة).
    func dropSelectionUI() {
        selection = nil
        selectionPan.isEnabled = false
        selectionView.isHidden = true
        selectionView.imageView.image = nil
        selectionBar.isHidden = true
        pastePoint = nil
    }

    // MARK: الأوامر

    private func copySelection() {
        guard let sel = selection else { return }
        let drawing = PKDrawing(strokes: movedStrokes(of: sel))
        let bounds = drawing.bounds.insetBy(dx: -12, dy: -12)
        guard bounds.width > 1, bounds.height > 1 else { return }

        // صورة بخلفية بيضاء وحبر داكن مهما كان الوضع، حتى تظهر صحيحة في أي تطبيق
        var png: Data?
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            let ink = drawing.image(from: bounds, scale: 3)
            let format = UIGraphicsImageRendererFormat()
            format.scale = 3
            format.opaque = true
            png = UIGraphicsImageRenderer(size: bounds.size, format: format).image { context in
                UIColor.white.setFill()
                context.fill(CGRect(origin: .zero, size: bounds.size))
                ink.draw(in: CGRect(origin: .zero, size: bounds.size))
            }.pngData()
        }
        var item: [String: Any] = [Self.strokesPasteboardType: drawing.dataRepresentation()]
        if let png { item[UTType.png.identifier] = png }
        UIPasteboard.general.setItems([item], options: [:])
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        onMessage?("تم النسخ — الصق الصورة في أي تطبيق، أو اضغط على فراغ هنا للصق الكتابة")
    }

    private func cutSelection() {
        copySelection()
        deleteSelection()
    }

    private func deleteSelection() {
        guard let sel = selection else { return }
        selection = nil
        dropSelectionUI()
        let old = PKDrawing(strokes: sel.isNew ? sel.rest : sel.rest + sel.strokes)
        isReplacing = true
        canvas.drawing = PKDrawing(strokes: sel.rest)
        lastStrokeCount = sel.rest.count
        isReplacing = false
        if let undoManager = canvas.undoManager {
            undoManager.registerUndo(withTarget: self) { target in
                target.replaceDrawing(old, actionName: "حذف التحديد")
            }
            undoManager.setActionName("حذف التحديد")
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        onDrawingChanged?()
    }

    private func duplicateSelection() {
        guard let sel = selection else { return }
        let originals = movedStrokes(of: sel)
        let shift = CGAffineTransform(translationX: 28, y: 28)
        let copies = originals.map { stroke -> PKStroke in
            var copy = stroke
            copy.transform = stroke.transform.concatenating(shift)
            return copy
        }
        // الأصل يرجع للوحة في مكانه، والنسخة تصير هي المحددة
        let base = sel.rest + originals
        selection = nil
        dropSelectionUI()
        isReplacing = true
        canvas.drawing = PKDrawing(strokes: base)
        lastStrokeCount = base.count
        isReplacing = false
        beginSelection(strokes: copies, rest: base, isNew: true)
    }

    private func pasteFromClipboard() {
        guard let data = UIPasteboard.general.data(forPasteboardType: Self.strokesPasteboardType),
              let pasted = try? PKDrawing(data: data), !pasted.strokes.isEmpty else {
            onMessage?("ما فيه كتابة منسوخة للصقها")
            return
        }
        let center = pastePoint ?? CGPoint(x: contentExtent.width / 2, y: contentExtent.height / 2)
        hideBar()
        let bounds = pasted.bounds
        let shift = CGAffineTransform(translationX: center.x - bounds.midX, y: center.y - bounds.midY)
        let strokes = pasted.strokes.map { stroke -> PKStroke in
            var moved = stroke
            moved.transform = stroke.transform.concatenating(shift)
            return moved
        }
        beginSelection(strokes: strokes, rest: canvas.drawing.strokes, isNew: true)
    }
}


// MARK: - الذكاء: تحويل الكتابة لنص وحل المسائل، ووضع الاستماع

extension PageCanvasContainerView {
    /// صورة الكتابة المحددة بحبر داكن على خلفية بيضاء (للتعرّف على النص وللمحرّك)، مع إطارها.
    private func selectionSnapshot() -> (image: UIImage, rect: CGRect)? {
        guard let sel = selection else { return nil }
        let drawing = PKDrawing(strokes: movedStrokes(of: sel))
        let bounds = drawing.bounds.insetBy(dx: -16, dy: -16)
        guard bounds.width > 4, bounds.height > 4 else { return nil }
        let scale = min(3, 2400 / max(bounds.width, bounds.height))
        var result: UIImage?
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            let ink = drawing.image(from: bounds, scale: scale)
            let format = UIGraphicsImageRendererFormat()
            format.scale = scale
            format.opaque = true
            result = UIGraphicsImageRenderer(size: bounds.size, format: format).image { context in
                UIColor.white.setFill()
                context.fill(CGRect(origin: .zero, size: bounds.size))
                ink.draw(in: CGRect(origin: .zero, size: bounds.size))
            }
        }
        guard let result else { return nil }
        return (result, bounds)
    }

    fileprivate func convertSelectionToText() {
        guard let snapshot = selectionSnapshot() else { return }
        onConvertSelectionToText?(snapshot.image, snapshot.rect)
    }

    fileprivate func solveSelection() {
        guard let snapshot = selectionSnapshot() else { return }
        commitSelection()
        onSolveSelection?(snapshot.image, snapshot.rect)
    }

    /// يحذف الكتابة المحددة بعد تحويلها لنص (خطوة تراجع واحدة).
    func removeSelectedStrokes() {
        guard selection != nil else { return }
        deleteSelection()
    }

    // MARK: وضع الاستماع

    func setReplayMode(_ on: Bool) {
        guard on != isReplayMode else { return }
        isReplayMode = on
        replayTap.isEnabled = on
        if on {
            commitSelection()
            disableEditingForReplay()
            onMessage?("اضغط على أي كلمة كتبتها أثناء التسجيل لتسمع ما قيل وقتها")
        } else {
            replayHighlightDate = nil
            replayLayer.path = nil
            replayTap.isEnabled = false
            // نعيد تطبيق الأداة الحالية كما هي (الرسم والتحديد والليزر)
            if let state = appliedState {
                appliedState = nil
                apply(state)
            }
        }
    }

    fileprivate func disableEditingForReplay() {
        canvas.drawingGestureRecognizer.isEnabled = false
        areaGesture.isEnabled = false
        laserGesture.isEnabled = false
        lassoLayer.path = nil
        itemsOverlay.isEditingEnabled = false
        // التمرير بإصبع واحد في وضع الاستماع
        if let saved = savedPanMinimumTouches {
            canvas.panGestureRecognizer.minimumNumberOfTouches = saved
            savedPanMinimumTouches = nil
        }
    }

    private func nearestStroke(to point: CGPoint, tolerance: CGFloat) -> PKStroke? {
        let strokes = canvas.drawing.strokes
        for index in strokes.indices.reversed()
        where Self.stroke(strokes[index], passesNear: point, tolerance: tolerance) {
            return strokes[index]
        }
        return nil
    }

    @objc fileprivate func handleReplayTap(_ gesture: UITapGestureRecognizer) {
        guard isReplayMode, gesture.state == .ended else { return }
        let zoom = max(canvas.zoomScale, 0.0001)
        let location = gesture.location(in: canvas)
        let point = CGPoint(x: location.x / zoom, y: location.y / zoom)
        guard let stroke = nearestStroke(to: point, tolerance: 16 / zoom) else {
            onMessage?("اضغط على كلمة مكتوبة")
            return
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        onReplayTap?(stroke.path.creationDate)
    }

    /// يظلّل الكلمات التي كُتبت في الثواني الأخيرة قبل لحظة التشغيل الحالية.
    func highlightReplay(at date: Date?) {
        replayHighlightDate = date
        updateReplayHighlight()
    }

    fileprivate func updateReplayHighlight() {
        guard isReplayMode, let date = replayHighlightDate else {
            replayLayer.path = nil
            return
        }
        let zoom = max(canvas.zoomScale, 0.0001)
        let path = UIBezierPath()
        for stroke in canvas.drawing.strokes {
            let age = date.timeIntervalSince(stroke.path.creationDate)
            guard age >= 0, age <= 3 else { continue }
            let box = stroke.renderBounds.insetBy(dx: -4, dy: -4)
            let scaled = CGRect(x: box.minX * zoom, y: box.minY * zoom, width: box.width * zoom, height: box.height * zoom)
            path.append(UIBezierPath(roundedRect: scaled, cornerRadius: 6))
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        replayLayer.path = path.isEmpty ? nil : path.cgPath
        CATransaction.commit()
    }
}
