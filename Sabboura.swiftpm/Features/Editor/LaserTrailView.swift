import UIKit

/// مؤشر الليزر: نقطة متوهجة تتبع اللمس مع ذيل يتلاشى بسرعة (مثل Notability).
/// يُرسم فوق اللوحة ولا يلتقط اللمسات ولا يُحفظ في الصفحة.
final class LaserTrailView: UIView {
    private struct Sample {
        var point: CGPoint
        var time: CFTimeInterval
    }

    var color: UIColor = UIColor(red: 1, green: 0.18, blue: 0.18, alpha: 1)
    /// قطر النقطة المتوهجة
    var dotSize: CGFloat = 12

    private var samples: [Sample] = []
    private var head: CGPoint?
    /// وقت رفع الإصبع (nil أثناء اللمس): بعده تتلاشى النقطة تدريجياً
    private var releaseTime: CFTimeInterval?
    private var displayLink: CADisplayLink?
    private var lastDirty: CGRect = .null

    private let trailLifetime: CFTimeInterval = 0.6
    private let headFadeDuration: CFTimeInterval = 0.35

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isOpaque = false
        backgroundColor = .clear
        contentMode = .redraw
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        isUserInteractionEnabled = false
        isOpaque = false
        backgroundColor = .clear
    }

    // MARK: التحكم

    /// بداية لمسة جديدة.
    func begin(at point: CGPoint) {
        releaseTime = nil
        head = point
        samples.append(Sample(point: point, time: CACurrentMediaTime()))
        startDisplayLink()
        redrawDirtyArea()
    }

    /// نقاط جديدة من اللمس (بإحداثيات هذه الطبقة).
    func append(_ points: [CGPoint]) {
        guard !points.isEmpty else { return }
        let now = CACurrentMediaTime()
        for point in points {
            samples.append(Sample(point: point, time: now))
        }
        head = points.last
        releaseTime = nil
        startDisplayLink()
        redrawDirtyArea()
    }

    /// رفع الإصبع: النقطة والذيل يتلاشيان.
    func end() {
        guard head != nil, releaseTime == nil else { return }
        releaseTime = CACurrentMediaTime()
        startDisplayLink()
    }

    /// إزالة كل شيء فوراً (تغيير الأداة).
    func clear() {
        samples.removeAll()
        head = nil
        releaseTime = nil
        stopDisplayLink()
        if !lastDirty.isNull {
            setNeedsDisplay(lastDirty)
        }
        lastDirty = .null
    }

    override func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        if newWindow == nil { clear() }
    }

    // MARK: التحريك

    private func startDisplayLink() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func tick() {
        let now = CACurrentMediaTime()
        samples.removeAll { now - $0.time > trailLifetime }
        if let released = releaseTime, now - released > headFadeDuration {
            head = nil
            releaseTime = nil
        }
        redrawDirtyArea()
        if samples.isEmpty && head == nil {
            stopDisplayLink()
        }
    }

    private func currentBounds() -> CGRect {
        var rect = CGRect.null
        for sample in samples {
            rect = rect.union(CGRect(origin: sample.point, size: .zero))
        }
        if let head {
            rect = rect.union(CGRect(origin: head, size: .zero))
        }
        guard !rect.isNull else { return .null }
        return rect.insetBy(dx: -(dotSize * 2 + 14), dy: -(dotSize * 2 + 14))
    }

    /// نعيد رسم المنطقة المتأثرة فقط (القديمة والجديدة) حتى يبقى الرسم سريعاً على الشاشات الكبيرة.
    private func redrawDirtyArea() {
        let current = currentBounds()
        let dirty = lastDirty.union(current)
        if !dirty.isNull {
            setNeedsDisplay(dirty)
        }
        lastDirty = current
    }

    // MARK: الرسم

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        let now = CACurrentMediaTime()

        // الذيل: كل مقطع يخفت حسب عمره
        if samples.count > 1 {
            context.setLineCap(.round)
            context.setLineJoin(.round)
            for index in 1..<samples.count {
                let age = now - samples[index].time
                let strength = CGFloat(max(0, 1 - age / trailLifetime))
                guard strength > 0.01 else { continue }
                context.setStrokeColor(color.withAlphaComponent(0.8 * strength).cgColor)
                context.setLineWidth(max(1.5, dotSize * 0.55 * strength))
                context.move(to: samples[index - 1].point)
                context.addLine(to: samples[index].point)
                context.strokePath()
            }
        }

        // النقطة المتوهجة
        guard let head else { return }
        var alpha: CGFloat = 1
        if let released = releaseTime {
            alpha = CGFloat(max(0, 1 - (now - released) / headFadeDuration))
        }
        guard alpha > 0.01 else { return }

        let glowRadius = dotSize * 1.9
        let colors = [color.withAlphaComponent(0.55 * alpha).cgColor,
                      color.withAlphaComponent(0).cgColor] as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
            context.drawRadialGradient(gradient,
                                       startCenter: head, startRadius: 0,
                                       endCenter: head, endRadius: glowRadius,
                                       options: [])
        }
        let radius = dotSize / 2
        context.setFillColor(color.withAlphaComponent(alpha).cgColor)
        context.fillEllipse(in: CGRect(x: head.x - radius, y: head.y - radius, width: dotSize, height: dotSize))
        let coreRadius = radius * 0.42
        context.setFillColor(UIColor.white.withAlphaComponent(0.9 * alpha).cgColor)
        context.fillEllipse(in: CGRect(x: head.x - coreRadius, y: head.y - coreRadius,
                                       width: coreRadius * 2, height: coreRadius * 2))
    }
}
