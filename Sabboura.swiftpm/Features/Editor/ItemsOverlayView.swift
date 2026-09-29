import UIKit

/// طبقة النصوص والصور فوق لوحة الرسم. تتحرك وتتكبّر مع اللوحة.
/// عند اختيار أداة النص تصبح العناصر قابلة للنقر (تعديل) والسحب (نقل) والقرص (تكبير الصور).
final class ItemsOverlayView: UIView, UIGestureRecognizerDelegate {
    var onTapItem: ((UUID) -> Void)?
    /// نقرة على مكان فارغ (إحداثيات اللوحة بدون تكبير) لإضافة نص جديد.
    var onTapEmpty: ((CGPoint) -> Void)?
    /// انتهى سحب أو تكبير عنصر: الإطار الجديد بإحداثيات اللوحة.
    var onItemFrameChanged: ((UUID, CGRect) -> Void)?

    var isEditingEnabled = false {
        didSet {
            isUserInteractionEnabled = isEditingEnabled
            for view in itemViews.values { view.showsOutline = isEditingEnabled }
        }
    }

    private var itemViews: [UUID: ItemView] = [:]
    private var contentScale: CGFloat = 1

    /// عناصر النص والصور لتقنيات الإتاحة (VoiceOver واختبارات الواجهة).
    var accessibleItemViews: [UIView] {
        itemViews.values.sorted { $0.frame.minY < $1.frame.minY }
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
        for entry in placed {
            let view: ItemView
            if let existing = itemViews[entry.id] {
                view = existing
            } else {
                view = ItemView()
                view.onMoved = { [weak self] id, frame in self?.onItemFrameChanged?(id, frame) }
                addSubview(view)
                itemViews[entry.id] = view
            }
            let image = entry.item.attachmentID.flatMap { images[$0] }
            view.configure(entry.item, frame: entry.canvasFrame, image: image, dark: dark)
            view.showsOutline = isEditingEnabled
            view.updateContentScale(contentScale)
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
                onTapItem?(id)
                return
            }
        }
        onTapEmpty?(point)
    }
}

/// عرض عنصر واحد (نص أو صورة) مع السحب والقرص.
final class ItemView: UIView, UIGestureRecognizerDelegate {
    private(set) var itemID: UUID?
    var onMoved: ((UUID, CGRect) -> Void)?

    private let label = UILabel()
    private let imageView = UIImageView()
    private let outline = CAShapeLayer()
    private var kind: PageItem.Kind = .text
    private var panStartCenter: CGPoint = .zero
    private var pinchStartBounds: CGRect = .zero

    var showsOutline = false {
        didSet { outline.isHidden = !showsOutline }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        label.numberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        imageView.contentMode = .scaleAspectFit
        imageView.clipsToBounds = true
        addSubview(imageView)
        addSubview(label)

        outline.fillColor = UIColor.clear.cgColor
        outline.strokeColor = UIColor.systemBlue.withAlphaComponent(0.8).cgColor
        outline.lineWidth = 1.5
        outline.lineDashPattern = [5, 4]
        outline.isHidden = true
        layer.addSublayer(outline)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        pan.delegate = self
        addGestureRecognizer(pan)
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        pinch.delegate = self
        addGestureRecognizer(pinch)
        isAccessibilityElement = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func configure(_ item: PageItem, frame: CGRect, image: UIImage?, dark: Bool) {
        itemID = item.id
        kind = item.kind
        self.frame = frame
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
        let screenScale = window?.screen.scale ?? 2
        label.layer.contentsScale = screenScale * max(1, scale)
        label.setNeedsDisplay()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        label.frame = bounds.insetBy(dx: 0, dy: 2)
        imageView.frame = bounds
        outline.path = UIBezierPath(roundedRect: bounds.insetBy(dx: -3, dy: -3), cornerRadius: 4).cgPath
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        other.view === self
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard let superview else { return }
        switch gesture.state {
        case .began:
            panStartCenter = center
        case .changed:
            let translation = gesture.translation(in: superview)
            center = CGPoint(x: panStartCenter.x + translation.x, y: panStartCenter.y + translation.y)
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
