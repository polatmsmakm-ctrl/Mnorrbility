import UIKit

/// طبقة النصوص والصور فوق لوحة الرسم. تتحرك وتتكبّر مع اللوحة.
/// عند اختيار أداة «النص والصور» تصبح العناصر قابلة للتحديد والسحب وتغيير الحجم.
final class ItemsOverlayView: UIView, UIGestureRecognizerDelegate {
    var onTapItem: ((UUID) -> Void)?
    /// نقرة على مكان فارغ (إحداثيات اللوحة بدون تكبير) لإضافة نص جديد.
    var onTapEmpty: ((CGPoint) -> Void)?
    /// انتهى سحب أو تغيير حجم عنصر: الإطار الجديد بإحداثيات اللوحة.
    var onItemFrameChanged: ((UUID, CGRect) -> Void)?
    /// زر الحذف على العنصر المحدد.
    var onDeleteItem: ((UUID) -> Void)?

    var isEditingEnabled = false {
        didSet {
            isUserInteractionEnabled = isEditingEnabled
            if !isEditingEnabled { selectedID = nil }
            refreshSelection()
        }
    }

    /// العنصر المحدد حالياً (يظهر عليه مقبض الحجم وزر الحذف).
    private(set) var selectedID: UUID?

    private var itemViews: [UUID: ItemView] = [:]
    private var contentScale: CGFloat = 1

    /// عناصر النص والصور ومقابض العنصر المحدد لتقنيات الإتاحة (VoiceOver واختبارات الواجهة).
    var accessibleItemViews: [UIView] {
        var result: [UIView] = itemViews.values.sorted { $0.frame.minY < $1.frame.minY }
        if let selectedID, let view = itemViews[selectedID] {
            result.append(contentsOf: view.controlViews)
        }
        return result
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isUserInteractionEnabled = false
        accessibilityIdentifier = "itemsOverlay"
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        addGestureRecognizer(tap)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func setItems(_ placed: [PlacedItem], images: [UUID: UIImage], dark: Bool) {
        let incoming = Set(placed.map(\.id))
        for (id, view) in itemViews where !incoming.contains(id) {
            view.removeFromSuperview()
            itemViews[id] = nil
        }
        if let selectedID, !incoming.contains(selectedID) { self.selectedID = nil }
        for entry in placed {
            let view: ItemView
            if let existing = itemViews[entry.id] {
                view = existing
            } else {
                view = ItemView()
                view.onMoved = { [weak self] id, frame in self?.onItemFrameChanged?(id, frame) }
                view.onBeganInteraction = { [weak self] id in self?.select(id) }
                view.onDelete = { [weak self] id in
                    self?.select(nil)
                    self?.onDeleteItem?(id)
                }
                addSubview(view)
                itemViews[entry.id] = view
            }
            let image = entry.item.attachmentID.flatMap { images[$0] }
            view.configure(entry.item, frame: entry.canvasFrame, image: image, dark: dark)
            view.updateContentScale(contentScale)
        }
        refreshSelection()
    }

    func select(_ id: UUID?) {
        selectedID = id
        if let id, let view = itemViews[id] { bringSubviewToFront(view) }
        refreshSelection()
    }

    private func refreshSelection() {
        for (id, view) in itemViews {
            view.showsOutline = isEditingEnabled
            view.isSelected = isEditingEnabled && id == selectedID
        }
    }

    func updateContentScale(_ scale: CGFloat) {
        contentScale = scale
        for view in itemViews.values { view.updateContentScale(scale) }
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        let point = gesture.location(in: self)
        for view in subviews.reversed() {
            if let itemView = view as? ItemView, itemView.frame.insetBy(dx: -8, dy: -8).contains(point),
               let id = itemView.itemID {
                // الصورة: أول نقرة تحددها، والثانية تفتح خياراتها. النص: النقرة تفتح التعديل.
                if itemView.kind == .image && selectedID != id {
                    select(id)
                } else {
                    onTapItem?(id)
                }
                return
            }
        }
        if selectedID != nil {
            select(nil)
            return
        }
        onTapEmpty?(point)
    }
}

/// عرض عنصر واحد (نص أو صورة) مع السحب ومقبض الحجم وزر الحذف.
final class ItemView: UIView, UIGestureRecognizerDelegate {
    private(set) var itemID: UUID?
    private(set) var kind: PageItem.Kind = .text
    var onMoved: ((UUID, CGRect) -> Void)?
    var onBeganInteraction: ((UUID) -> Void)?
    var onDelete: ((UUID) -> Void)?

    private let label = UILabel()
    private let imageView = UIImageView()
    private let outline = CAShapeLayer()
    private let resizeHandle = UIView()
    private let deleteButton = UIButton(type: .custom)
    private var panStartCenter: CGPoint = .zero
    private var pinchStartBounds: CGRect = .zero
    private var resizeStartFrame: CGRect = .zero
    private var aspectRatio: CGFloat = 1
    private var contentScale: CGFloat = 1

    var showsOutline = false {
        didSet { updateDecorations() }
    }

    var isSelected = false {
        didSet { updateDecorations() }
    }

    /// المقابض الظاهرة للعنصر المحدد (لتقنيات الإتاحة).
    var controlViews: [UIView] { isSelected ? [resizeHandle, deleteButton] : [] }

    override init(frame: CGRect) {
        super.init(frame: frame)
        label.numberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        imageView.contentMode = .scaleAspectFit
        imageView.clipsToBounds = true
        imageView.layer.cornerRadius = 2
        addSubview(imageView)
        addSubview(label)

        outline.fillColor = UIColor.clear.cgColor
        outline.strokeColor = UIColor.systemBlue.withAlphaComponent(0.8).cgColor
        outline.lineWidth = 1.5
        outline.lineDashPattern = [5, 4]
        outline.isHidden = true
        layer.addSublayer(outline)

        // مقبض تغيير الحجم (الركن السفلي) — يعمل بالقلم والإصبع
        resizeHandle.bounds = CGRect(x: 0, y: 0, width: 26, height: 26)
        resizeHandle.backgroundColor = .white
        resizeHandle.layer.cornerRadius = 13
        resizeHandle.layer.borderColor = UIColor.systemBlue.cgColor
        resizeHandle.layer.borderWidth = 3
        resizeHandle.layer.shadowColor = UIColor.black.cgColor
        resizeHandle.layer.shadowOpacity = 0.25
        resizeHandle.layer.shadowRadius = 3
        resizeHandle.layer.shadowOffset = CGSize(width: 0, height: 1)
        resizeHandle.isAccessibilityElement = true
        resizeHandle.accessibilityIdentifier = "resizeHandle"
        resizeHandle.accessibilityLabel = "تغيير الحجم"
        resizeHandle.accessibilityTraits = .adjustable
        let resizePan = UIPanGestureRecognizer(target: self, action: #selector(handleResize(_:)))
        resizePan.maximumNumberOfTouches = 1
        resizePan.delegate = self
        resizeHandle.addGestureRecognizer(resizePan)
        addSubview(resizeHandle)

        // زر الحذف (الركن العلوي)
        deleteButton.bounds = CGRect(x: 0, y: 0, width: 28, height: 28)
        deleteButton.backgroundColor = .systemRed
        deleteButton.layer.cornerRadius = 14
        deleteButton.setImage(UIImage(systemName: "xmark",
                                      withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .bold)),
                              for: .normal)
        deleteButton.tintColor = .white
        deleteButton.accessibilityIdentifier = "deleteItem"
        deleteButton.accessibilityLabel = "حذف"
        deleteButton.addTarget(self, action: #selector(deleteTapped), for: .touchUpInside)
        addSubview(deleteButton)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        pan.delegate = self
        addGestureRecognizer(pan)
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        pinch.delegate = self
        addGestureRecognizer(pinch)
        isAccessibilityElement = true
        updateDecorations()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func configure(_ item: PageItem, frame: CGRect, image: UIImage?, dark: Bool) {
        itemID = item.id
        kind = item.kind
        self.frame = frame
        aspectRatio = frame.height / max(frame.width, 1)
        accessibilityIdentifier = item.kind == .text ? "textItem" : "imageItem"
        accessibilityLabel = item.kind == .text ? item.text : "صورة"
        switch item.kind {
        case .text:
            label.isHidden = false
            imageView.isHidden = true
            label.font = item.font
            label.textColor = ItemRenderer.displayColor(item.colorHex, dark: dark)
            label.text = item.text
            label.textAlignment = .natural
        case .image:
            label.isHidden = true
            imageView.isHidden = false
            imageView.image = image
        }
        setNeedsLayout()
    }

    func updateContentScale(_ scale: CGFloat) {
        contentScale = max(scale, 0.05)
        let screenScale = window?.screen.scale ?? 2
        label.layer.contentsScale = screenScale * max(1, scale)
        label.setNeedsDisplay()
        // المقابض بحجم ثابت على الشاشة مهما كان التكبير
        let inverse = CGAffineTransform(scaleX: 1 / contentScale, y: 1 / contentScale)
        resizeHandle.transform = inverse
        deleteButton.transform = inverse
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        label.frame = bounds.insetBy(dx: 0, dy: 2)
        imageView.frame = bounds
        outline.path = UIBezierPath(roundedRect: bounds.insetBy(dx: -3, dy: -3), cornerRadius: 4).cgPath
        resizeHandle.center = CGPoint(x: bounds.maxX, y: bounds.maxY)
        deleteButton.center = CGPoint(x: bounds.minX, y: bounds.minY)
    }

    private func updateDecorations() {
        outline.isHidden = !(showsOutline || isSelected)
        outline.strokeColor = (isSelected ? UIColor.systemBlue : UIColor.systemBlue.withAlphaComponent(0.6)).cgColor
        outline.lineDashPattern = isSelected ? nil : [5, 4]
        outline.lineWidth = isSelected ? 2 : 1.5
        resizeHandle.isHidden = !isSelected
        deleteButton.isHidden = !isSelected
    }

    /// المقابض تبرز خارج حدود العنصر، فنوسّع منطقة اللمس لتشملها.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        if super.point(inside: point, with: event) { return true }
        guard isSelected else { return false }
        return resizeHandle.frame.insetBy(dx: -8, dy: -8).contains(point)
            || deleteButton.frame.insetBy(dx: -8, dy: -8).contains(point)
    }

    // MARK: الإيماءات

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        other.view === self && gestureRecognizer.view === self
    }

    /// إيماءات التمرير والتكبير في اللوحة تنتظر إيماءات العنصر، فاللمس على صورة يحرّكها ولا يحرّك الصفحة.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
        other.view is UIScrollView
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        // لمس المقابض لا يحرّك العنصر نفسه
        if gestureRecognizer.view === self,
           let view = touch.view, view === resizeHandle || view.isDescendant(of: deleteButton) {
            return false
        }
        return true
    }

    @objc private func deleteTapped() {
        guard let itemID else { return }
        onDelete?(itemID)
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard let superview else { return }
        switch gesture.state {
        case .began:
            panStartCenter = center
            if let itemID { onBeganInteraction?(itemID) }
        case .changed:
            let translation = gesture.translation(in: superview)
            center = CGPoint(x: panStartCenter.x + translation.x, y: panStartCenter.y + translation.y)
        case .ended, .cancelled:
            if let itemID { onMoved?(itemID, frame) }
        default:
            break
        }
    }

    @objc private func handleResize(_ gesture: UIPanGestureRecognizer) {
        guard let superview else { return }
        switch gesture.state {
        case .began:
            resizeStartFrame = frame
        case .changed:
            let translation = gesture.translation(in: superview)
            var size = resizeStartFrame.size
            switch kind {
            case .image:
                // تكبير متناسب: نأخذ الحركة الأكبر بين الأفقية والعمودية
                let byWidth = resizeStartFrame.width + translation.x
                let byHeight = (resizeStartFrame.height + translation.y) / max(aspectRatio, 0.01)
                let width = max(40, max(byWidth, byHeight))
                size = CGSize(width: width, height: width * aspectRatio)
            case .text:
                size.width = max(60, resizeStartFrame.width + translation.x)
            }
            frame = CGRect(origin: resizeStartFrame.origin, size: size)
            setNeedsLayout()
        case .ended, .cancelled:
            if let itemID { onMoved?(itemID, frame) }
        default:
            break
        }
    }

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        guard kind == .image else { return }
        switch gesture.state {
        case .began:
            pinchStartBounds = bounds
            if let itemID { onBeganInteraction?(itemID) }
        case .changed:
            let scale = max(0.2, min(gesture.scale, 6))
            let newSize = CGSize(width: max(40, pinchStartBounds.width * scale),
                                 height: max(40, pinchStartBounds.height * scale))
            let oldCenter = center
            bounds = CGRect(origin: .zero, size: newSize)
            center = oldCenter
        case .ended, .cancelled:
            if let itemID { onMoved?(itemID, frame) }
        default:
            break
        }
    }
}
