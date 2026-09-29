import Combine
import CoreData
import PencilKit
import SwiftUI
import UniformTypeIdentifiers

/// تفضيلات العرض في المحرر (تُحفظ للتطبيق كله).
enum EditorPreferences {
    private static let seamlessKey = "sabboura.editor.seamless"
    private static let statusBarKey = "sabboura.editor.statusBar"

    static var seamless: Bool {
        get { UserDefaults.standard.object(forKey: seamlessKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: seamlessKey) }
    }

    static var showStatusBar: Bool {
        get { UserDefaults.standard.object(forKey: statusBarKey) as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: statusBarKey) }
    }
}

/// عنصر يُعدَّل في نافذة النص/الصورة.
struct ItemEditTarget: Identifiable {
    var item: PageItem
    let pageID: UUID
    let isNew: Bool
    var id: UUID { item.id }
}

/// "عقل" شاشة الكتابة: الصفحات، الأدوات، الحفظ التلقائي، النصوص والصور، التسجيل، الاستيراد والتصدير.
final class EditorController: ObservableObject {
    let note: CDNote
    let context: NSManagedObjectContext

    @Published private(set) var pages: [CDPage] = []
    @Published private(set) var currentIndex: Int = 0

    @Published var tools: ToolSettings = ToolSettings.load() {
        didSet { if tools != oldValue { tools.save() } }
    }
    @Published var fingerDrawing: Bool = FingerDrawingSetting.load() {
        didSet { if fingerDrawing != oldValue { FingerDrawingSetting.save(fingerDrawing) } }
    }
    @Published var seamless: Bool = EditorPreferences.seamless {
        didSet {
            guard seamless != oldValue else { return }
            EditorPreferences.seamless = seamless
            flush()
            rebuildCanvas(scrollTo: currentIndex)
        }
    }
    @Published var showStatusBar: Bool = EditorPreferences.showStatusBar {
        didSet { EditorPreferences.showStatusBar = showStatusBar }
    }
    @Published var isRulerActive = false
    /// الأشكال الذكية: ارسم شكلاً وثبّت القلم لحظة
    @Published var smartShapes: Bool = SmartShapesSetting.load() {
        didSet { if smartShapes != oldValue { SmartShapesSetting.save(smartShapes) } }
    }
    /// خيارات ترتيب الخط
    @Published var tidyOptions: TidyOptions = TidyOptions.load() {
        didSet { if tidyOptions != oldValue { tidyOptions.save() } }
    }
    @Published var activePopover: EditorPopover? = nil
    @Published var showClearConfirmation = false
    @Published var editingItem: ItemEditTarget? = nil
    /// رقم دائرة اللون التي يُعاد تخصيصها (ضغط مطوّل)
    @Published var editingSwatchIndex: Int? = nil

    @Published private(set) var zoomPercent = 100
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    @Published private(set) var isBusy = false
    @Published private(set) var toast: String? = nil
    @Published private(set) var isRecording = false
    @Published private(set) var recordingStart: Date? = nil

    private(set) var contentDark = false
    private(set) var theme: AppTheme = .darkBlue

    private weak var canvasView: PageCanvasContainerView?
    private var layout: [PageRenderInfo] = []
    private var layoutPages: [CDPage] = []
    private var savedSignatures: [UUID: Int] = [:]
    private var isDirty = false
    private var pendingSave: DispatchWorkItem?
    private var toastWork: DispatchWorkItem?
    private var cancellables = Set<AnyCancellable>()
    private var didRunTestImport = false
    private let recorder = AudioRecorder()

    init(note: CDNote) {
        self.note = note
        self.context = note.managedObjectContext ?? PersistenceController.shared.viewContext
        // لا حفظ ولا تعديل لقاعدة البيانات هنا: هذا يُنفَّذ أثناء بناء الواجهة (انتقال فتح المذكرة)،
        // وأي حفظ هنا يحدّث القوائم في منتصف الانتقال فيُلغيه أحياناً. التعديلات في didAppear().
        reloadPages()
        currentIndex = min(max(0, Int(note.lastPageIndex)), max(0, pages.count - 1))

        NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)
            .merge(with: NotificationCenter.default.publisher(for: .sabbouraFlushRequested))
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.flush() }
            .store(in: &cancellables)

        // تحديث زري التراجع والإعادة كلما تغيّر سجل التراجع (PencilKit يسجّل الخطوة بعد انتهاء الخط)
        let undoNotifications: [Notification.Name] = [.NSUndoManagerDidCloseUndoGroup,
                                                      .NSUndoManagerDidUndoChange,
                                                      .NSUndoManagerDidRedoChange,
                                                      .NSUndoManagerCheckpoint]
        Publishers.MergeMany(undoNotifications.map { NotificationCenter.default.publisher(for: $0) })
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshUndoState() }
            .store(in: &cancellables)
    }

    /// يُستدعى بعد ظهور شاشة الكتابة: تجهيز الصفحة الأولى وتسجيل وقت الفتح.
    func didAppear() {
        guard note.isAlive else { return }
        var needsRebuild = false
        if note.sortedPages.isEmpty {
            DataStore.insertPage(into: note, at: 0, template: PageTemplate.savedDefault, context: context)
            needsRebuild = true
        }
        note.lastOpenedAt = Date()
        DataStore.save(context)
        if needsRebuild {
            reloadPages()
            rebuildCanvas(scrollTo: 0)
        }
    }

    // MARK: - ربط اللوحة

    func attach(_ view: PageCanvasContainerView) {
        canvasView = view
        view.onDrawingChanged = { [weak self] in self?.drawingDidChange() }
        view.onZoomChanged = { [weak self] relative in self?.zoomDidChange(relative) }
        view.onPencilDoubleTap = { [weak self] in self?.handlePencilDoubleTap() }
        view.onVisiblePageChanged = { [weak self] index in self?.visiblePageChanged(index) }
        view.onMessage = { [weak self] message in self?.showToast(message) }
        view.itemsOverlay.onTapEmpty = { [weak self] point in self?.createTextItem(at: point) }
        view.itemsOverlay.onTapItem = { [weak self] id in self?.editItem(id) }
        view.itemsOverlay.onItemFrameChanged = { [weak self] id, frame in self?.moveItem(id, to: frame) }
        view.itemsOverlay.onDeleteItem = { [weak self] id in self?.deleteItem(id: id) }
        view.apply(canvasToolState)
        rebuildCanvas(scrollTo: currentIndex)
    }

    var canvasToolState: CanvasToolState {
        CanvasToolState(tools: tools, fingerDrawing: fingerDrawing, rulerActive: isRulerActive,
                        smartShapes: smartShapes, tidy: tidyOptions)
    }

    /// يُستدعى من الواجهة عند تغيّر الثيم أو الوضع الداكن.
    func setAppearance(dark: Bool, theme: AppTheme) {
        guard dark != contentDark || theme != self.theme else { return }
        contentDark = dark
        self.theme = theme
        guard let view = canvasView else { return }
        layout = buildLayout(for: layoutPages)
        view.updateBackgrounds(pages: layout, deskColor: UIColor(hex: theme.deskHex), dark: dark)
        refreshItems()
    }

    // MARK: - الصفحات والتخطيط

    var pageCount: Int { pages.count }

    var currentPage: CDPage? {
        guard pages.indices.contains(currentIndex) else { return nil }
        let page = pages[currentIndex]
        return page.isAlive ? page : nil
    }

    func reloadPages() {
        pages = note.sortedPages
        for page in pages where page.uuid == nil {
            page.uuid = UUID()
        }
    }

    private func buildLayout(for displayPages: [CDPage]) -> [PageRenderInfo] {
        var result: [PageRenderInfo] = []
        var y: CGFloat = 0
        for page in displayPages where page.isAlive {
            let index = pages.firstIndex(of: page) ?? result.count
            let size = page.pageSize
            result.append(PageRenderInfo(id: page.uuid ?? UUID(),
                                         index: index,
                                         size: size,
                                         originY: y,
                                         background: page.backgroundConfig.themed(dark: contentDark, theme: theme),
                                         pdfPage: PDFSourceCache.shared.page(for: page, context: context)))
            y += size.height + PageCanvasContainerView.pageGap
        }
        return result
    }

    /// يعيد بناء اللوحة كاملة (بعد إضافة/حذف/استيراد صفحات أو تغيير وضع العرض).
    func rebuildCanvas(scrollTo pageIndex: Int?) {
        guard let view = canvasView else { return }
        let displayPages: [CDPage]
        if seamless {
            displayPages = pages
        } else if let page = currentPage {
            displayPages = [page]
        } else {
            displayPages = []
        }
        layoutPages = displayPages
        layout = buildLayout(for: displayPages)

        var combined = PKDrawing()
        savedSignatures = [:]
        for (info, page) in zip(layout, displayPages) {
            let drawing = page.drawingData.flatMap { try? PKDrawing(data: $0) } ?? PKDrawing()
            savedSignatures[info.id] = Self.signature(drawing)
            if !drawing.strokes.isEmpty {
                combined.append(drawing.transformed(using: CGAffineTransform(translationX: 0, y: info.originY)))
            }
        }
        isDirty = false
        view.configure(pages: layout,
                       drawing: combined,
                       deskColor: UIColor(hex: theme.deskHex),
                       dark: contentDark,
                       seamless: seamless,
                       scrollToPage: seamless ? pageIndex : nil)
        refreshItems()
        refreshUndoState()
    }

    private func visiblePageChanged(_ index: Int) {
        guard seamless, pages.indices.contains(index), index != currentIndex else { return }
        currentIndex = index
        if note.isAlive { note.lastPageIndex = Int64(index) }
    }

    func goToPage(_ index: Int) {
        guard pages.indices.contains(index) else { return }
        if seamless {
            currentIndex = index
            canvasView?.scrollToPage(index, animated: true)
        } else {
            flush()
            currentIndex = index
            rebuildCanvas(scrollTo: index)
        }
        if note.isAlive { note.lastPageIndex = Int64(index) }
    }

    func nextPage() {
        if currentIndex + 1 < pages.count { goToPage(currentIndex + 1) }
    }

    func previousPage() {
        if currentIndex > 0 { goToPage(currentIndex - 1) }
    }

    func addPage() {
        guard note.isAlive else { return }
        flush()
        var template = currentPage?.template ?? PageTemplate.savedDefault
        if currentPage?.isPDFPage == true {
            template = PageTemplate.savedDefault
        }
        DataStore.insertPage(into: note, at: currentIndex + 1, template: template, context: context)
        DataStore.save(context)
        reloadPages()
        currentIndex = min(currentIndex + 1, pages.count - 1)
        rebuildCanvas(scrollTo: currentIndex)
        showToast("تمت إضافة صفحة جديدة")
    }

    func duplicatePage(at index: Int) {
        guard note.isAlive, pages.indices.contains(index) else { return }
        flush()
        DataStore.duplicatePage(pages[index], in: note, context: context)
        reloadPages()
        currentIndex = min(index + 1, pages.count - 1)
        rebuildCanvas(scrollTo: currentIndex)
        showToast("تم تكرار الصفحة")
    }

    func deletePage(at index: Int) {
        guard note.isAlive, pages.indices.contains(index) else { return }
        flush()
        if pages.count == 1 {
            let page = pages[0]
            page.drawingData = nil
            page.items = []
            DataStore.save(context)
            rebuildCanvas(scrollTo: 0)
            showToast("تم مسح الصفحة الوحيدة")
            return
        }
        DataStore.deletePage(pages[index], from: note, context: context)
        reloadPages()
        currentIndex = min(max(0, index > 0 ? index - 1 : 0), max(0, pages.count - 1))
        note.lastPageIndex = Int64(currentIndex)
        DataStore.save(context)
        rebuildCanvas(scrollTo: currentIndex)
        showToast("تم حذف الصفحة")
    }

    func movePage(from source: Int, to destination: Int) {
        guard source != destination, note.isAlive else { return }
        flush()
        let current = currentPage
        DataStore.movePage(in: note, from: source, to: destination, context: context)
        reloadPages()
        if let current, let index = pages.firstIndex(of: current) {
            currentIndex = index
            note.lastPageIndex = Int64(index)
        }
        rebuildCanvas(scrollTo: currentIndex)
    }

    func snapshot(of page: CDPage, dark: Bool = false) -> PageSnapshot {
        PageSnapshot.make(for: page, context: context, dark: dark, theme: theme)
    }

    // MARK: - الحفظ التلقائي (تقسيم الحبر على الصفحات)

    private func drawingDidChange() {
        isDirty = true
        refreshUndoState()
        // PencilKit يغلق مجموعة التراجع في نهاية دورة الأحداث، لذلك نعيد الفحص بعدها
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.refreshUndoState()
        }
        scheduleSave()
    }

    private func scheduleSave() {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.flush() }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    /// يكتب الرسم الحالي في قاعدة البيانات فوراً: كل خط يُنسب للصفحة التي يقع فيها.
    func flush() {
        pendingSave?.cancel()
        pendingSave = nil
        guard note.isAlive else { return }
        if isDirty, let view = canvasView, !layout.isEmpty {
            var buckets = Array(repeating: [PKStroke](), count: layout.count)
            for stroke in view.currentDrawing.strokes {
                let index = layoutIndex(forY: stroke.renderBounds.midY)
                var moved = stroke
                moved.transform = stroke.transform.concatenating(
                    CGAffineTransform(translationX: 0, y: -layout[index].originY))
                buckets[index].append(moved)
            }
            var changed = false
            for (index, info) in layout.enumerated() {
                guard layoutPages.indices.contains(index) else { continue }
                let page = layoutPages[index]
                guard page.isAlive else { continue }
                let drawing = PKDrawing(strokes: buckets[index])
                let signature = Self.signature(drawing)
                if savedSignatures[info.id] != signature {
                    page.drawingData = drawing.strokes.isEmpty ? nil : drawing.dataRepresentation()
                    savedSignatures[info.id] = signature
                    changed = true
                }
            }
            if changed { note.updatedAt = Date() }
            isDirty = false
        }
        DataStore.save(context)
    }

    private func layoutIndex(forY y: CGFloat) -> Int {
        var best = 0
        for (index, info) in layout.enumerated() where info.originY - PageCanvasContainerView.pageGap / 2 <= y {
            best = index
        }
        return best
    }

    /// بصمة مختصرة للرسم لمعرفة الصفحات التي تغيّرت فعلاً.
    static func signature(_ drawing: PKDrawing) -> Int {
        var hasher = Hasher()
        hasher.combine(drawing.strokes.count)
        for stroke in drawing.strokes {
            hasher.combine(stroke.path.creationDate.timeIntervalSinceReferenceDate)
            hasher.combine(stroke.path.count)
            let bounds = stroke.renderBounds
            hasher.combine(Int(bounds.minX * 4))
            hasher.combine(Int(bounds.minY * 4))
            hasher.combine(Int(bounds.maxX * 4))
            hasher.combine(Int(bounds.maxY * 4))
            hasher.combine(stroke.ink.inkType.rawValue)
            if let mask = stroke.mask {
                let maskBounds = mask.bounds
                hasher.combine(Int(maskBounds.width * 4))
                hasher.combine(Int(maskBounds.height * 4))
            }
        }
        return hasher.finalize()
    }

    // MARK: - الأدوات

    var activeInkKind: ToolKind { tools.kind.isInk ? tools.kind : tools.lastInkKind }

    /// الضغط على أداة: يختارها، وإن كانت مختارة يفتح خياراتها.
    func toolTapped(_ kind: ToolKind) {
        if tools.kind == kind {
            if kind != .text { activePopover = .tool(kind) }
            return
        }
        tools.previousKind = tools.kind
        tools.kind = kind
        if kind.isInk { tools.lastInkKind = kind }
        if kind == .text {
            showToast("انقر على الصفحة لإضافة نص — واسحب الصور والنصوص لتحريكها")
        } else if kind == .tidy {
            showToast("ارسم دائرة حول الكتابة لترتيبها — اضغط الأداة مرة ثانية للخيارات")
        }
    }

    func toggleEraser() {
        if tools.kind == .eraser {
            let back = tools.previousKind == .eraser ? tools.lastInkKind : tools.previousKind
            tools.previousKind = .eraser
            tools.kind = back
        } else {
            tools.previousKind = tools.kind
            tools.kind = .eraser
        }
    }

    func switchToPreviousTool() {
        let previous = tools.previousKind
        tools.previousKind = tools.kind
        tools.kind = previous
        if previous.isInk { tools.lastInkKind = previous }
    }

    /// النقر المزدوج على قلم أبل (الجيل الثاني / Pro) حسب إعداد المستخدم في النظام.
    private func handlePencilDoubleTap() {
        switch UIPencilInteraction.preferredTapAction {
        case .ignore:
            break
        case .switchPrevious:
            switchToPreviousTool()
        case .showColorPalette:
            activePopover = .color
        case .showInkAttributes:
            activePopover = .tool(activeInkKind)
        default:
            toggleEraser()
        }
    }

    var currentColorHex: String {
        get { tools.color(for: activeInkKind) }
        set {
            let kind = activeInkKind
            tools.colors[kind.rawValue] = newValue
            if !tools.kind.isInk {
                tools.previousKind = tools.kind
                tools.kind = kind
            }
        }
    }

    /// لون كما يظهر على الشاشة حالياً (في الوضع الداكن يظهر الأسود أبيض).
    func displayColor(_ hex: String) -> Color {
        Color(uiColor: ItemRenderer.displayColor(hex, dark: contentDark))
    }

    func selectSwatch(_ hex: String) {
        currentColorHex = hex
    }

    func setSwatch(at index: Int, to hex: String) {
        guard tools.swatches.indices.contains(index) else { return }
        tools.swatches[index] = hex
        currentColorHex = hex
    }

    func setColor(_ hex: String, for kind: ToolKind) {
        tools.colors[kind.rawValue] = hex
    }

    func width(for kind: ToolKind) -> Double { tools.width(for: kind) }

    func setWidth(_ width: Double, for kind: ToolKind) {
        tools.setWidth(width, for: kind)
    }

    func popoverBinding(_ popover: EditorPopover) -> Binding<Bool> {
        Binding(
            get: { [weak self] in self?.activePopover == popover },
            set: { [weak self] isPresented in
                guard let self else { return }
                if isPresented {
                    self.activePopover = popover
                } else if self.activePopover == popover {
                    self.activePopover = nil
                }
            }
        )
    }

    /// يغلق النافذة الحالية ثم ينفّذ الإجراء بعد انتهاء حركة الإغلاق.
    func closePopover(then action: (() -> Void)? = nil) {
        activePopover = nil
        guard let action else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: action)
    }

    // MARK: - التراجع / المسح / التكبير

    func undo() {
        canvasView?.undo()
        refreshUndoState()
    }

    func redo() {
        canvasView?.redo()
        refreshUndoState()
    }

    private func refreshUndoState() {
        let undo = canvasView?.canUndo ?? false
        let redo = canvasView?.canRedo ?? false
        if undo != canUndo { canUndo = undo }
        if redo != canRedo { canRedo = redo }
    }

    /// يمسح حبر الصفحة الحالية فقط (مع إمكانية التراجع).
    func clearPage() {
        guard let view = canvasView, let info = layout.first(where: { $0.index == currentIndex }) ?? layout.first else { return }
        let lower = info.originY - PageCanvasContainerView.pageGap / 2
        let upper = info.originY + info.size.height + PageCanvasContainerView.pageGap / 2
        let remaining = view.currentDrawing.strokes.filter {
            let midY = $0.renderBounds.midY
            return midY < lower || midY >= upper
        }
        view.replaceDrawing(PKDrawing(strokes: remaining), actionName: "مسح الصفحة")
        showToast("تم مسح الصفحة — يمكنك التراجع")
    }

    func zoomIn() { canvasView?.zoom(by: 1.25) }

    /// يرتّب كل الكتابة في الصفحة الحالية.
    func tidyCurrentPage() {
        closePopover { [weak self] in
            guard let self else { return }
            self.canvasView?.tidyPage(self.currentIndex)
        }
    }
    func zoomOut() { canvasView?.zoom(by: 0.8) }
    func zoomToFit() { canvasView?.zoomToFit() }

    private func zoomDidChange(_ relative: CGFloat) {
        let percent = Int((relative * 100).rounded())
        DispatchQueue.main.async { [weak self] in
            guard let self, percent != self.zoomPercent else { return }
            self.zoomPercent = percent
        }
    }

    // MARK: - الخلفيات

    var currentTemplate: PageTemplate {
        currentPage?.template ?? PageTemplate.savedDefault
    }

    func applyBackground(_ template: PageTemplate, toAllPages: Bool) {
        guard note.isAlive else { return }
        let wasDark = UIColor(hex: currentTemplate.backgroundHex).isDark
        if toAllPages {
            for page in pages where page.isAlive { page.apply(template, includePattern: false) }
        } else {
            currentPage?.apply(template)
        }
        layout = buildLayout(for: layoutPages)
        canvasView?.updateBackgrounds(pages: layout, deskColor: UIColor(hex: theme.deskHex), dark: contentDark)
        note.updatedAt = Date()
        scheduleSave()
        let isDark = UIColor(hex: template.backgroundHex).isDark
        if isDark != wasDark && !contentDark {
            adaptInk(toDarkBackground: isDark)
        } else if toAllPages {
            showToast("تم تطبيق الخلفية على كل الصفحات")
        }
    }

    /// على السبورة الداكنة يصبح الحبر الأسود أبيض (مثل الطباشير) والعكس.
    private func adaptInk(toDarkBackground dark: Bool) {
        var changed = false
        for kind in [ToolKind.pen, .pencil, .fountainPen, .monoline] {
            let current = tools.color(for: kind)
            if dark && UIColor(hex: current).isDark {
                tools.colors[kind.rawValue] = "#FFFFFF"
                changed = true
            } else if !dark && current.uppercased() == "#FFFFFF" {
                tools.colors[kind.rawValue] = "#1C1C1E"
                changed = true
            }
        }
        if changed {
            showToast(dark ? "تم تحويل الحبر إلى الأبيض ليظهر على السبورة" : "تمت إعادة الحبر إلى الأسود")
        }
    }

    func makeDefault(_ template: PageTemplate) {
        template.saveAsDefault()
        showToast("ستستخدم الصفحات الجديدة هذه الخلفية")
    }

    // MARK: - النصوص والصور

    private func refreshItems() {
        guard let view = canvasView else { return }
        var placed: [PlacedItem] = []
        var images: [UUID: UIImage] = [:]
        for (info, page) in zip(layout, layoutPages) where page.isAlive {
            for item in page.items {
                placed.append(PlacedItem(item: item, pageID: info.id, pageOriginY: info.originY))
                if item.kind == .image, let id = item.attachmentID,
                   let image = ImageStore.shared.image(for: id, context: context) {
                    images[id] = image
                }
            }
        }
        view.itemsOverlay.setItems(placed, images: images, dark: contentDark)
    }

    private func page(withID id: UUID) -> CDPage? {
        guard let index = layout.firstIndex(where: { $0.id == id }), layoutPages.indices.contains(index) else { return nil }
        return layoutPages[index]
    }

    private func createTextItem(at canvasPoint: CGPoint) {
        guard let info = layout.first(where: { $0.frame.contains(canvasPoint) }) else { return }
        let local = CGPoint(x: canvasPoint.x, y: canvasPoint.y - info.originY)
        let color = tools.color(for: tools.lastInkKind)
        let item = PageItem.newText(at: local, pageWidth: info.size.width, colorHex: color)
        editingItem = ItemEditTarget(item: item, pageID: info.id, isNew: true)
    }

    private func editItem(_ id: UUID) {
        for info in layout {
            guard let page = page(withID: info.id), let item = page.items.first(where: { $0.id == id }) else { continue }
            editingItem = ItemEditTarget(item: item, pageID: info.id, isNew: false)
            return
        }
    }

    func saveItem(_ target: ItemEditTarget) {
        guard let page = page(withID: target.pageID) else { return }
        var item = target.item
        if item.kind == .text {
            item.text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if item.text.isEmpty {
                deleteItem(target)
                return
            }
            item.fitTextHeight()
        }
        let before = [(page, page.items)]
        var items = page.items
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            items[index] = item
        } else {
            items.append(item)
        }
        page.items = items
        commitItemChange(before, actionName: item.kind == .text ? "نص" : "صورة")
    }

    func deleteItem(_ target: ItemEditTarget) {
        deleteItem(id: target.item.id)
    }

    /// حذف نص أو صورة (يمكن التراجع عنه بزر التراجع).
    func deleteItem(id: UUID) {
        guard let page = layoutPages.first(where: { $0.isAlive && $0.items.contains(where: { $0.id == id }) }) else { return }
        let before = [(page, page.items)]
        let wasImage = page.items.first(where: { $0.id == id })?.kind == .image
        page.items = page.items.filter { $0.id != id }
        commitItemChange(before, actionName: "حذف")
        showToast(wasImage ? "حُذفت الصورة — تقدر تتراجع" : "حُذف النص — تقدر تتراجع")
    }

    /// عنصر سُحب أو تغيّر حجمه (قد ينتقل لصفحة أخرى في وضع التمرير المتصل).
    private func moveItem(_ id: UUID, to canvasFrame: CGRect) {
        guard let sourcePage = layoutPages.first(where: { $0.isAlive && $0.items.contains(where: { $0.id == id }) }),
              var moved = sourcePage.items.first(where: { $0.id == id }) else { return }
        let targetIndex = layoutIndex(forY: canvasFrame.midY)
        guard layoutPages.indices.contains(targetIndex) else { return }
        let target = layoutPages[targetIndex]
        let info = layout[targetIndex]
        var local = canvasFrame.offsetBy(dx: 0, dy: -info.originY)
        local.origin.x = min(max(local.origin.x, -local.width * 0.5), info.size.width - local.width * 0.5)
        local.origin.y = min(max(local.origin.y, -local.height * 0.5), info.size.height - local.height * 0.5)
        moved.frame = local
        if moved.kind == .text { moved.fitTextHeight() }

        var before = [(sourcePage, sourcePage.items)]
        if target !== sourcePage { before.append((target, target.items)) }
        sourcePage.items = sourcePage.items.filter { $0.id != id }
        target.items = target.items + [moved]
        commitItemChange(before, actionName: "نقل")
        canvasView?.itemsOverlay.select(id)
    }

    // MARK: - التراجع عن تعديلات النصوص والصور

    /// يحفظ التعديل ويسجّل خطوة تراجع في نفس سجل الكتابة (زر التراجع يشمل الصور والنصوص).
    private func commitItemChange(_ before: [(CDPage, [PageItem])], actionName: String) {
        let after = before.map { ($0.0, $0.0.items) }
        note.updatedAt = Date()
        DataStore.save(context)
        refreshItems()
        registerItemsUndo(restore: before, redo: after, actionName: actionName)
    }

    private func registerItemsUndo(restore: [(CDPage, [PageItem])], redo: [(CDPage, [PageItem])], actionName: String) {
        guard let undoManager = canvasView?.itemsUndoManager else { return }
        undoManager.registerUndo(withTarget: self) { target in
            for (page, items) in restore where page.isAlive {
                page.items = items
            }
            target.note.updatedAt = Date()
            DataStore.save(target.context)
            target.refreshItems()
            target.registerItemsUndo(restore: redo, redo: restore, actionName: actionName)
        }
        undoManager.setActionName(actionName)
        DispatchQueue.main.async { [weak self] in self?.refreshUndoState() }
    }

    // MARK: - الصور داخل الصفحات

    /// يدرج صورة كعنصر قابل للتحريك في الصفحة الظاهرة.
    func insertImage(_ data: Data) {
        insertImages([data])
    }

    /// يدرج صورة أو أكثر في وسط الجزء الظاهر من الصفحة (مذكرة عادية أو صفحة PDF).
    func insertImages(_ datas: [Data]) {
        guard note.isAlive, !datas.isEmpty, let view = canvasView, !layout.isEmpty else { return }
        let center = view.visibleContentCenter
        let index = layoutIndex(forY: center.y)
        guard layoutPages.indices.contains(index) else { return }
        let info = layout[index]
        let page = layoutPages[index]
        guard page.isAlive else { return }

        let before = [(page, page.items)]
        var items = page.items
        var lastID: UUID?
        let localCenterY = min(max(center.y - info.originY, info.size.height * 0.2), info.size.height * 0.8)
        let localCenterX = min(max(center.x, info.size.width * 0.25), info.size.width * 0.75)

        for data in datas {
            guard let original = UIImage(data: data) else { continue }
            let image = Self.prepared(original, maxDimension: 2000)
            guard let jpeg = image.jpegData(compressionQuality: 0.85) else { continue }
            let attachment = DataStore.addAttachment(data: jpeg, fileName: "صورة.jpg",
                                                     typeIdentifier: UTType.jpeg.identifier,
                                                     isPageSource: false, to: note, context: context)
            guard let attachmentID = attachment.uuid else { continue }
            ImageStore.shared.store(image, for: attachmentID)

            let aspect = image.size.height / max(image.size.width, 1)
            var width = min(info.size.width * (datas.count > 1 ? 0.45 : 0.6), max(image.size.width, 120))
            var height = width * aspect
            if height > info.size.height * 0.55 {
                height = info.size.height * 0.55
                width = height / max(aspect, 0.01)
            }
            let offset = CGFloat(items.count - before[0].1.count) * 28
            var item = PageItem(kind: .image, x: 0, y: 0, width: Double(width), height: Double(height))
            item.x = Double(min(max(localCenterX - width / 2 + offset, 8), info.size.width - width - 8))
            item.y = Double(min(max(localCenterY - height / 2 + offset, 8), info.size.height - height - 8))
            item.attachmentID = attachmentID
            items.append(item)
            lastID = item.id
        }

        let added = items.count - before[0].1.count
        guard added > 0 else {
            showToast("تعذّر قراءة الصورة")
            return
        }
        page.items = items
        commitItemChange(before, actionName: added > 1 ? "إدراج صور" : "إدراج صورة")
        if tools.kind != .text {
            tools.previousKind = tools.kind
            tools.kind = .text
        }
        // التحديد بعد تطبيق أداة «النص والصور» على اللوحة
        DispatchQueue.main.async { [weak self] in
            self?.canvasView?.itemsOverlay.select(lastID)
        }
        showToast(added > 1
                  ? "أُضيفت \(added) صور — اسحب أي صورة لتحريكها، والمقبض الأزرق لتكبيرها"
                  : "أُضيفت الصورة — اسحبها لتحريكها، والمقبض الأزرق لتكبيرها")
    }

    /// لصق صورة منسوخة (من الصور أو المتصفح أو لقطة شاشة).
    func pasteImage() {
        let board = UIPasteboard.general
        guard board.hasImages, let images = board.images, !images.isEmpty else {
            showToast("ما فيه صورة منسوخة — انسخ صورة أولاً ثم الصقها هنا")
            return
        }
        insertImages(images.compactMap { $0.pngData() })
    }

    /// يصغّر الصورة الكبيرة ويثبّت اتجاهها (صور الكاميرا تحمل اتجاهاً مخزّناً).
    private static func prepared(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let longest = max(image.size.width, image.size.height)
        guard longest > maxDimension || image.imageOrientation != .up else { return image }
        let factor = min(1, maxDimension / longest)
        let size = CGSize(width: image.size.width * factor, height: image.size.height * factor)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    // MARK: - التسجيل الصوتي

    func toggleRecording() {
        if isRecording {
            guard let result = recorder.stop() else {
                isRecording = false
                recordingStart = nil
                return
            }
            isRecording = false
            recordingStart = nil
            guard let data = try? Data(contentsOf: result.url), note.isAlive else { return }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "ar")
            formatter.dateFormat = "d MMM h:mm a"
            DataStore.addAttachment(data: data,
                                    fileName: "تسجيل \(formatter.string(from: Date())).m4a",
                                    typeIdentifier: UTType.mpeg4Audio.identifier,
                                    isPageSource: false, to: note, context: context)
            DataStore.save(context)
            try? FileManager.default.removeItem(at: result.url)
            let seconds = Int(result.duration)
            showToast("تم حفظ التسجيل (\(seconds / 60):\(String(format: "%02d", seconds % 60))) في المرفقات")
        } else {
            recorder.start { [weak self] started in
                guard let self else { return }
                if started {
                    self.isRecording = true
                    self.recordingStart = Date()
                } else {
                    self.showToast("اسمح للتطبيق باستخدام الميكروفون من الإعدادات")
                }
            }
        }
    }

    func stopRecordingIfNeeded() {
        if isRecording { toggleRecording() }
    }

    // MARK: - الاستيراد

    /// يُدرج ملفات PDF والصور كصفحات يمكن الكتابة فوقها، وبقية الملفات كمرفقات.
    func importFiles(_ files: [ImportedFile], asPages: Bool) {
        guard !files.isEmpty, note.isAlive else { return }
        flush()
        var insertIndex = currentIndex + 1
        var firstNewPage: Int?
        var addedPages = 0
        var addedAttachments = 0

        for file in files {
            var handled = false
            if asPages && (file.isPDF || file.isImage) {
                let pdfData = file.isPDF ? file.data : DataStore.pdfData(fromImageData: file.data)
                if let pdfData {
                    let count = DataStore.importPDFPages(data: pdfData, fileName: file.name, into: note,
                                                         at: insertIndex, context: context)
                    if count > 0 {
                        if firstNewPage == nil { firstNewPage = insertIndex }
                        insertIndex += count
                        addedPages += count
                        handled = true
                    }
                }
            }
            if !handled {
                DataStore.addAttachment(data: file.data, fileName: file.name, typeIdentifier: file.typeIdentifier,
                                        isPageSource: false, to: note, context: context)
                addedAttachments += 1
            }
        }

        DataStore.save(context)
        reloadPages()
        if let firstNewPage {
            currentIndex = min(firstNewPage, pages.count - 1)
        }
        rebuildCanvas(scrollTo: currentIndex)

        var parts: [String] = []
        if addedPages > 0 { parts.append("أُضيفت \(addedPages) صفحة") }
        if addedAttachments > 0 { parts.append("أُضيف \(addedAttachments) مرفق") }
        showToast(parts.isEmpty ? "تعذّر قراءة الملف" : parts.joined(separator: " و"))
    }

    /// يحوّل مرفق PDF أو صورة موجود إلى صفحات قابلة للكتابة.
    func insertAttachmentAsPages(_ attachment: CDAttachment) {
        guard attachment.isAlive, let data = attachment.data else { return }
        let file = ImportedFile(name: attachment.displayName, data: data, typeIdentifier: attachment.typeValue)
        guard file.isPDF || file.isImage else { return }
        importFiles([file], asPages: true)
    }

    /// للاختبار الآلي فقط: يستورد ملف PDF تجريبياً مرة واحدة.
    func runTestImportIfNeeded() {
        guard AppEnvironment.importSamplePDF || AppEnvironment.insertSampleImage, !didRunTestImport else { return }
        didRunTestImport = true
        if AppEnvironment.importSamplePDF {
            let file = ImportedFile(name: "Sample.pdf", data: DataStore.samplePDF(), typeIdentifier: UTType.pdf.identifier)
            importFiles([file], asPages: true)
        }
        if AppEnvironment.insertSampleImage {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                self?.insertImages([Self.sampleImageData()])
            }
        }
    }

    /// صورة تجريبية لاختبارات الواجهة.
    private static func sampleImageData() -> Data {
        let size = CGSize(width: 600, height: 400)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor(red: 0.98, green: 0.85, blue: 0.55, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1).setFill()
            UIBezierPath(ovalIn: CGRect(x: 60, y: 60, width: 220, height: 220)).fill()
            UIColor(red: 0.85, green: 0.25, blue: 0.3, alpha: 1).setFill()
            UIBezierPath(roundedRect: CGRect(x: 320, y: 120, width: 220, height: 200), cornerRadius: 24).fill()
        }
        return image.pngData() ?? Data()
    }

    // MARK: - المفضلة والاسم

    func toggleFavorite() {
        DataStore.toggleFavorite(note, context: context)
        objectWillChange.send()
        showToast(note.isFavorite ? "أُضيفت إلى المفضلة" : "أُزيلت من المفضلة")
    }

    // MARK: - التصدير

    func exportNoteAsPDF() {
        guard note.isAlive else { return }
        flush()
        let snapshots = pages.filter(\.isAlive).map { self.snapshot(of: $0) }
        let title = note.displayTitle
        let url = TemporaryFiles.directory("Export").appending(path: TemporaryFiles.safeFileName(title) + ".pdf")
        runExport {
            try PageRenderer.writePDF(snapshots, title: title, to: url)
            return [url]
        }
    }

    func exportCurrentPageAsImage() {
        guard let page = currentPage else { return }
        flush()
        let pageSnapshot = self.snapshot(of: page)
        let name = TemporaryFiles.safeFileName(note.displayTitle) + " - صفحة \(currentIndex + 1).png"
        let url = TemporaryFiles.directory("Export").appending(path: name)
        runExport {
            let image = PageRenderer.image(for: pageSnapshot, scale: 2)
            guard let data = image.pngData() else { return [] }
            try data.write(to: url, options: .atomic)
            return [url]
        }
    }

    func exportCurrentPageAsPDF() {
        guard let page = currentPage else { return }
        flush()
        let pageSnapshot = self.snapshot(of: page)
        let name = TemporaryFiles.safeFileName(note.displayTitle) + " - صفحة \(currentIndex + 1).pdf"
        let url = TemporaryFiles.directory("Export").appending(path: name)
        let title = note.displayTitle
        runExport {
            try PageRenderer.writePDF([pageSnapshot], title: title, to: url)
            return [url]
        }
    }

    func shareAttachments(_ attachments: [CDAttachment]) {
        let urls = attachments.compactMap { TemporaryFiles.url(for: $0) }
        guard !urls.isEmpty else {
            showToast("لا توجد ملفات للمشاركة")
            return
        }
        SharePresenter.share(urls)
    }

    private func runExport(_ work: @escaping () throws -> [URL]) {
        isBusy = true
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try work() }
            DispatchQueue.main.async {
                self.isBusy = false
                switch result {
                case .success(let urls) where !urls.isEmpty:
                    SharePresenter.share(urls)
                default:
                    self.showToast("تعذّر إنشاء الملف")
                }
            }
        }
    }

    // MARK: - رسائل قصيرة

    func showToast(_ message: String) {
        guard !message.isEmpty else { return }
        toastWork?.cancel()
        toast = message
        let work = DispatchWorkItem { [weak self] in
            self?.toast = nil
        }
        toastWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.6, execute: work)
    }
}
