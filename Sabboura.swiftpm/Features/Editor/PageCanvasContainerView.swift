import PencilKit
import UIKit

/// لوحة الكتابة الأساسية المبنية على PKCanvasView من PencilKit.
///
/// - كل الصفحات مرصوصة عمودياً في لوحة واحدة (وضع التمرير المتصل) أو صفحة واحدة.
/// - الحبر يُرسم بمحرك PencilKit الرسمي (الضغط والميلان والتنبؤ بحركة القلم).
/// - الخلفية طبقة مقسّمة أسفل الحبر، وطبقة النصوص والصور فوقه، وكلها تتكبّر مع اللوحة.
/// - الوضع الداكن: PencilKit يحوّل ألوان الحبر تلقائياً (الأسود يظهر أبيض).
final class PageCanvasContainerView: UIView, PKCanvasViewDelegate, UIPencilInteractionDelegate {
    let canvas = PKCanvasView()
    let itemsOverlay = ItemsOverlayView(frame: .zero)

    var onDrawingChanged: (() -> Void)?
    var onZoomChanged: ((CGFloat) -> Void)?
    var onPencilDoubleTap: (() -> Void)?
    var onVisiblePageChanged: ((Int) -> Void)?
    /// رسالة قصيرة للمستخدم (ترتيب الخط)
    var onMessage: ((String) -> Void)?

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

    /// ماذا يفعل مسار التحديد الحر: مسح الكتابة أو ترتيبها
    private enum AreaAction { case erase, tidy }
    private var areaAction: AreaAction = .erase
    private let holdObserver = StrokeHoldObserver(target: nil, action: nil)
    private var lastStrokeCount = 0
    private var isReplacing = false
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
        canvas.addSubview(itemsOverlay)

        lassoLayer.fillColor = UIColor(red: 0.86, green: 0.15, blue: 0.15, alpha: 0.08).cgColor
        lassoLayer.strokeColor = UIColor(red: 0.86, green: 0.15, blue: 0.15, alpha: 0.9).cgColor
        lassoLayer.lineWidth = 1.5
        lassoLayer.lineDashPattern = [6, 4]
        lassoLayer.lineJoin = .round
        lassoLayer.zPosition = 1000
        canvas.layer.addSublayer(lassoLayer)

        canvas.addGestureRecognizer(holdObserver)

        areaGesture.addTarget(self, action: #selector(handleAreaGesture(_:)))
        areaGesture.isEnabled = false
        areaGesture.cancelsTouchesInView = true
        canvas.addGestureRecognizer(areaGesture)

        let pencilInteraction = UIPencilInteraction()
        pencilInteraction.delegate = self
        addInteraction(pencilInteraction)
    }

    // لوحة PencilKit تخفي ما بداخلها عن تقنيات الإتاحة، فنعرض النصوص والصور بجانبها صراحةً.
    override var accessibilityElements: [Any]? {
        get { [canvas] + itemsOverlay.accessibleItemViews }
        set { }
    }

    // MARK: عرض الصفحات

    /// يعرض الصفحات مع رسمها المجمّع (إحداثيات اللوحة).
    func configure(pages: [PageRenderInfo], drawing: PKDrawing, deskColor: UIColor, dark: Bool,
                   seamless: Bool, scrollToPage: Int?) {
        isLoading = true
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

    private static func extent(of pages: [PageRenderInfo]) -> CGSize {
        guard let last = pages.last else { return DataStore.standardPageSize }
        let width = pages.map(\.size.width).max() ?? DataStore.standardPageSize.width
        return CGSize(width: width, height: last.originY + last.size.height)
    }

    var currentDrawing: PKDrawing { canvas.drawing }

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
        let areaMode = tidyMode || (state.tools.kind == .eraser && state.tools.eraserMode == .area)
        areaAction = tidyMode ? .tidy : .erase
        let tint = tidyMode ? UIColor.systemIndigo : UIColor(red: 0.86, green: 0.15, blue: 0.15, alpha: 1)
        lassoLayer.strokeColor = tint.withAlphaComponent(0.9).cgColor
        lassoLayer.fillColor = tint.withAlphaComponent(0.08).cgColor
        itemsOverlay.isEditingEnabled = textMode
        setAreaEraseActive(areaMode, allowFinger: state.fingerDrawing)
        canvas.drawingGestureRecognizer.isEnabled = !(areaMode || textMode)
        if !areaMode && !textMode {
            canvas.tool = state.tools.makePKTool()
        }
    }

    private func setAreaEraseActive(_ active: Bool, allowFinger: Bool) {
        areaGesture.isEnabled = active
        var touchTypes = [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
        if allowFinger {
            touchTypes.append(NSNumber(value: UITouch.TouchType.direct.rawValue))
        }
        areaGesture.allowedTouchTypes = touchTypes

        if active && allowFinger {
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

    func undo() { canvas.undoManager?.undo() }
    func redo() { canvas.undoManager?.redo() }

    /// يستبدل الرسم كاملاً مع تسجيل خطوة تراجع (تُستخدم لمسح الصفحة وممحاة التحديد).
    func replaceDrawing(_ newDrawing: PKDrawing, actionName: String) {
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
        for view in [backgroundView as UIView, itemsOverlay as UIView] {
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

        canvas.sendSubviewToBack(backgroundView)
        canvas.bringSubviewToFront(itemsOverlay)
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
        let count = canvas.drawing.strokes.count
        let strokeAdded = count == lastStrokeCount + 1
        lastStrokeCount = count
        onDrawingChanged?()
        // الأشكال الذكية: خط جديد انتهى والقلم ثابت لحظة
        if strokeAdded && smartShapes && !isReplacing && (appliedState?.tools.kind.isInk ?? false) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { [weak self] in
                self?.snapLastStrokeIfHeld(expectedCount: count)
            }
        }
    }

    private func snapLastStrokeIfHeld(expectedCount: Int) {
        guard CACurrentMediaTime() - holdObserver.lastHoldEndTime < 0.9 else { return }
        let drawing = canvas.drawing
        guard drawing.strokes.count == expectedCount, let last = drawing.strokes.last,
              Date().timeIntervalSince(last.path.creationDate) < 30,
              let shape = ShapeRecognizer.snapped(last) else { return }
        holdObserver.lastHoldEndTime = 0
        var strokes = drawing.strokes
        strokes[strokes.count - 1] = shape
        replaceDrawing(PKDrawing(strokes: strokes), actionName: "شكل مضبوط")
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        if AppEnvironment.isUITest { onMessage?("shape-snapped") }
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        syncGeometry()
    }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        syncGeometry()
        reportZoom()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
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
            }
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.25)
            lassoLayer.opacity = 0
            CATransaction.commit()
        default:
            lassoLayer.path = nil
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
        let selected = canvas.drawing.strokes.indices.filter {
            let bounds = canvas.drawing.strokes[$0].renderBounds
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
