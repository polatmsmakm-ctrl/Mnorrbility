import UIKit

/// صورة الكتابة المحددة وإطارها المنقّط. الكتابة المحددة تُرفع من اللوحة وتُعرض كصورة،
/// فيصير سحبها حركة طبقة واحدة على كرت الشاشة (سلسة حتى مع مذكرة ثقيلة).
final class StrokeSelectionView: UIView {
    let imageView = UIImageView()
    private let border = CAShapeLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        imageView.contentMode = .scaleToFill
        addSubview(imageView)
        border.fillColor = UIColor.systemBlue.withAlphaComponent(0.07).cgColor
        border.strokeColor = UIColor.systemBlue.withAlphaComponent(0.9).cgColor
        border.lineWidth = 1.5
        border.lineDashPattern = [6, 4]
        layer.addSublayer(border)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        imageView.frame = bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        border.frame = bounds
        border.path = UIBezierPath(roundedRect: bounds.insetBy(dx: 0.75, dy: 0.75), cornerRadius: 4).cgPath
        CATransaction.commit()
    }
}

/// شريط أوامر صغير يظهر فوق التحديد (نسخ، قص، تكرار، حذف) أو عند النقر على فراغ (لصق).
final class SelectionMenuBar: UIView {
    struct Action {
        let title: String
        let symbol: String
        var destructive = false
        let handler: () -> Void
    }

    private let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemThickMaterial))
    private let stack = UIStackView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerRadius = 14
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.22
        layer.shadowRadius = 8
        layer.shadowOffset = CGSize(width: 0, height: 3)

        blur.layer.cornerRadius = 14
        blur.clipsToBounds = true
        blur.translatesAutoresizingMaskIntoConstraints = false
        addSubview(blur)

        stack.axis = .horizontal
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        blur.contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            blur.leadingAnchor.constraint(equalTo: leadingAnchor),
            blur.trailingAnchor.constraint(equalTo: trailingAnchor),
            blur.topAnchor.constraint(equalTo: topAnchor),
            blur.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: blur.contentView.leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(equalTo: blur.contentView.trailingAnchor, constant: -4),
            stack.topAnchor.constraint(equalTo: blur.contentView.topAnchor, constant: 2),
            stack.bottomAnchor.constraint(equalTo: blur.contentView.bottomAnchor, constant: -2)
        ])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    func set(_ actions: [Action]) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for action in actions {
            var configuration = UIButton.Configuration.plain()
            configuration.title = action.title
            configuration.image = UIImage(systemName: action.symbol)
            configuration.imagePlacement = .top
            configuration.imagePadding = 3
            configuration.baseForegroundColor = action.destructive ? .systemRed : .label
            configuration.contentInsets = NSDirectionalEdgeInsets(top: 7, leading: 12, bottom: 6, trailing: 12)
            configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
                var outgoing = incoming
                outgoing.font = UIFont.systemFont(ofSize: 11, weight: .medium)
                return outgoing
            }
            let button = UIButton(configuration: configuration)
            button.addAction(UIAction { _ in action.handler() }, for: .touchUpInside)
            stack.addArrangedSubview(button)
        }
    }

    var buttons: [UIView] { stack.arrangedSubviews }

    var fittingSize: CGSize {
        layoutIfNeeded()
        return systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
    }
}

/// مفوّض بسيط يقرّر هل يبدأ تعرّف الحركة (يمنع تعارض أسماء الدوال مع UIView نفسها).
final class ClosureGestureDelegate: NSObject, UIGestureRecognizerDelegate {
    var shouldBegin: ((UIGestureRecognizer) -> Bool)?

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        shouldBegin?(gestureRecognizer) ?? true
    }
}
