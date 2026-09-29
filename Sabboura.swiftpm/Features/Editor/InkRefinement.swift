import PencilKit
import UIKit
import UIKit.UIGestureRecognizerSubclass

// MARK: - الإعدادات

/// خيارات «ترتيب الخط» (تُحفظ للتطبيق كله).
struct TidyOptions: Codable, Equatable {
    /// تعديل ميلان السطر ليصبح أفقياً
    var straighten = true
    /// إنزال الكتابة على أقرب خط من خطوط الصفحة
    var snapToLines = true
    /// توحيد المسافات بين الكلمات
    var evenSpacing = true
    /// تنعيم الرجفة الصغيرة في الخط
    var smooth = true

    private static let key = "sabboura.tidyOptions"

    static func load() -> TidyOptions {
        guard let data = UserDefaults.standard.data(forKey: key),
              let value = try? JSONDecoder().decode(TidyOptions.self, from: data) else { return TidyOptions() }
        return value
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}

/// «الأشكال الذكية»: ارسم شكلاً وثبّت القلم لحظة فيتحول إلى شكل مضبوط.
enum SmartShapesSetting {
    private static let key = "sabboura.smartShapes"

    static func load() -> Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
    static func save(_ value: Bool) { UserDefaults.standard.set(value, forKey: key) }
}

// MARK: - أدوات هندسية مشتركة

private extension CGPoint {
    func distance(to other: CGPoint) -> CGFloat { hypot(x - other.x, y - other.y) }
}

enum InkGeometry {
    /// نقاط الخط بإحداثيات الرسم (بعد تطبيق تحويل الخط).
    static func points(of stroke: PKStroke, spacing: CGFloat = 2) -> [CGPoint] {
        var result: [CGPoint] = []
        for point in stroke.path.interpolatedPoints(by: .distance(spacing)) {
            result.append(point.location.applying(stroke.transform))
        }
        if result.isEmpty {
            result = [CGPoint(x: stroke.renderBounds.midX, y: stroke.renderBounds.midY)]
        }
        return result
    }

    static func bounds(of points: [CGPoint]) -> CGRect {
        guard let first = points.first else { return .zero }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for point in points {
            minX = min(minX, point.x); maxX = max(maxX, point.x)
            minY = min(minY, point.y); maxY = max(maxY, point.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    static func length(of points: [CGPoint]) -> CGFloat {
        guard points.count > 1 else { return 0 }
        var total: CGFloat = 0
        for index in 1..<points.count {
            total += points[index].distance(to: points[index - 1])
        }
        return total
    }

    static func median(_ values: [CGFloat]) -> CGFloat {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }

    static func percentile(_ values: [CGFloat], _ fraction: CGFloat) -> CGFloat {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let position = Int((CGFloat(sorted.count - 1) * min(max(fraction, 0), 1)).rounded())
        return sorted[position]
    }

    /// بُعد نقطة عن قطعة مستقيمة.
    static func distance(from point: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0.0001 else { return point.distance(to: a) }
        let t = max(0, min(1, ((point.x - a.x) * dx + (point.y - a.y) * dy) / lengthSquared))
        return point.distance(to: CGPoint(x: a.x + t * dx, y: a.y + t * dy))
    }

    /// تبسيط مسار مفتوح (Ramer–Douglas–Peucker).
    static func simplify(_ points: [CGPoint], epsilon: CGFloat) -> [CGPoint] {
        guard points.count > 2 else { return points }
        var keep = [Bool](repeating: false, count: points.count)
        keep[0] = true
        keep[points.count - 1] = true
        var stack: [(Int, Int)] = [(0, points.count - 1)]
        while let (start, end) = stack.popLast() {
            guard end > start + 1 else { continue }
            var farthest = start
            var maxDistance: CGFloat = 0
            for index in (start + 1)..<end {
                let d = distance(from: points[index], toSegment: points[start], points[end])
                if d > maxDistance {
                    maxDistance = d
                    farthest = index
                }
            }
            if maxDistance > epsilon {
                keep[farthest] = true
                stack.append((start, farthest))
                stack.append((farthest, end))
            }
        }
        return points.indices.filter { keep[$0] }.map { points[$0] }
    }

    /// ميل خط الانحدار (y على x) لمجموعة نقاط.
    static func regressionSlope(_ points: [CGPoint]) -> CGFloat? {
        guard points.count >= 8 else { return nil }
        let count = CGFloat(points.count)
        let meanX = points.reduce(0) { $0 + $1.x } / count
        let meanY = points.reduce(0) { $0 + $1.y } / count
        var sxy: CGFloat = 0, sxx: CGFloat = 0
        for point in points {
            sxy += (point.x - meanX) * (point.y - meanY)
            sxx += (point.x - meanX) * (point.x - meanX)
        }
        guard sxx > 1 else { return nil }
        return sxy / sxx
    }

    static func rotation(about center: CGPoint, angle: CGFloat) -> CGAffineTransform {
        CGAffineTransform(translationX: -center.x, y: -center.y)
            .concatenating(CGAffineTransform(rotationAngle: angle))
            .concatenating(CGAffineTransform(translationX: center.x, y: center.y))
    }
}

// MARK: - مراقبة تثبيت القلم في نهاية الخط

/// يراقب اللمسات دون أن يتدخل فيها، ويسجّل إن انتهى الخط والقلم ثابت لحظة (للأشكال الذكية).
final class StrokeHoldObserver: UIGestureRecognizer, UIGestureRecognizerDelegate {
    /// وقت انتهاء آخر خط انتهى بتثبيت (CACurrentMediaTime)
    var lastHoldEndTime: CFTimeInterval = 0
    var holdDuration: TimeInterval = 0.4
    var tolerance: CGFloat = 5

    private weak var trackedTouch: UITouch?
    private var anchor: CGPoint = .zero
    private var anchorTime: TimeInterval = 0
    private var isValid = false

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        delegate = self
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        if trackedTouch != nil || touches.count != 1 || (event.allTouches?.count ?? 1) > 1 {
            // لمسة ثانية (تكبير أو تمرير) — لا يُعدّ رسماً
            isValid = false
            return
        }
        guard let touch = touches.first else { return }
        trackedTouch = touch
        isValid = true
        anchor = touch.location(in: view)
        anchorTime = touch.timestamp
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = trackedTouch, touches.contains(touch) else { return }
        for sample in event.coalescedTouches(for: touch) ?? [touch] {
            let point = sample.location(in: view)
            if point.distance(to: anchor) > tolerance {
                anchor = point
                anchorTime = sample.timestamp
            }
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        if let touch = trackedTouch, touches.contains(touch), isValid {
            let point = touch.location(in: view)
            if point.distance(to: anchor) <= tolerance && touch.timestamp - anchorTime >= holdDuration {
                lastHoldEndTime = CACurrentMediaTime()
            }
        }
        let allDone = (event.allTouches ?? touches).allSatisfy { $0.phase == .ended || $0.phase == .cancelled }
        if allDone { state = .failed }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        state = .failed
    }

    override func reset() {
        super.reset()
        trackedTouch = nil
        isValid = false
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        true
    }
}

// MARK: - الأشكال الذكية

/// يتعرف على خط مستقيم، خطوط متصلة (مثل ✓ والأسهم)، مثلث، مستطيل، دائرة وشكل بيضاوي،
/// ويعيد رسمها بنفس نوع الحبر ولونه وسماكته بشكل مضبوط.
enum ShapeRecognizer {
    enum Shape {
        case polyline([CGPoint])
        case polygon([CGPoint])
        case ellipse(center: CGPoint, radiusX: CGFloat, radiusY: CGFloat, startAngle: CGFloat, clockwise: Bool)
    }

    static func snapped(_ stroke: PKStroke) -> PKStroke? {
        let points = InkGeometry.points(of: stroke, spacing: 2)
        guard let shape = recognize(points) else { return nil }
        return makeStroke(shape, like: stroke)
    }

    static func recognize(_ raw: [CGPoint]) -> Shape? {
        guard raw.count >= 6 else { return nil }
        // نتجاهل الرجفة عند التثبيت في نهاية الخط
        var points = raw
        if let last = points.last {
            while points.count > 6, let previous = points.dropLast().last, previous.distance(to: last) < 3 {
                points.removeLast(2)
                points.append(last)
            }
        }
        let bounds = InkGeometry.bounds(of: points)
        let diagonal = hypot(bounds.width, bounds.height)
        guard diagonal >= 24, let first = points.first, let last = points.last else { return nil }
        let length = InkGeometry.length(of: points)
        let closingGap = first.distance(to: last)
        let isClosed = closingGap < max(14, diagonal * 0.22) && length > diagonal * 1.8

        if !isClosed {
            return recognizeOpen(points, first: first, last: last, length: length, diagonal: diagonal)
        }
        return recognizeClosed(points, bounds: bounds, diagonal: diagonal)
    }

    private static func recognizeOpen(_ points: [CGPoint], first: CGPoint, last: CGPoint,
                                      length: CGFloat, diagonal: CGFloat) -> Shape? {
        let chord = first.distance(to: last)
        let maxDeviation = points.map { InkGeometry.distance(from: $0, toSegment: first, last) }.max() ?? 0
        if chord > 20, maxDeviation < max(3.5, chord * 0.055), length < chord * 1.15 {
            let (a, b) = snapAngle(first, last)
            return .polyline([a, b])
        }
        // خطوط متصلة: ✓، زاوية، سهم، خط متعرج بسيط
        let epsilon = max(4, diagonal * 0.06)
        let vertices = InkGeometry.simplify(points, epsilon: epsilon)
        guard (3...6).contains(vertices.count) else { return nil }
        let segmentsAreShort = zip(vertices, vertices.dropFirst()).allSatisfy { $0.distance(to: $1) > 10 }
        guard segmentsAreShort else { return nil }
        return .polyline(vertices)
    }

    private static func recognizeClosed(_ points: [CGPoint], bounds: CGRect, diagonal: CGFloat) -> Shape? {
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let radiusX = bounds.width / 2
        let radiusY = bounds.height / 2
        guard radiusX > 6, radiusY > 6 else {
            // شكل مسطّح جداً: خط مستقيم ذهاباً وإياباً
            return nil
        }
        var ellipseError: CGFloat = 0
        for point in points {
            let nx = (point.x - center.x) / radiusX
            let ny = (point.y - center.y) / radiusY
            ellipseError += abs(sqrt(nx * nx + ny * ny) - 1)
        }
        ellipseError /= CGFloat(points.count)

        let vertices = closedVertices(points, epsilon: max(5, diagonal * 0.07))

        if vertices.count == 3 && ellipseError > 0.07 {
            return .polygon(vertices)
        }
        if vertices.count == 4 && ellipseError > 0.055 {
            return .polygon(regularizedQuad(vertices, points: points))
        }
        if ellipseError < 0.14 {
            // الاتجاه ونقطة البداية كما رسمها المستخدم
            var signedArea: CGFloat = 0
            for index in points.indices {
                let a = points[index], b = points[(index + 1) % points.count]
                signedArea += a.x * b.y - b.x * a.y
            }
            let start = points[0]
            let startAngle = atan2((start.y - center.y) / radiusY, (start.x - center.x) / radiusX)
            var rx = radiusX, ry = radiusY
            if abs(rx - ry) < max(rx, ry) * 0.12 {
                let r = (rx + ry) / 2
                rx = r
                ry = r
            }
            return .ellipse(center: center, radiusX: rx, radiusY: ry, startAngle: startAngle, clockwise: signedArea > 0)
        }
        return nil
    }

    /// رؤوس شكل مغلق: نقسم المسار عند أبعد نقطة عن البداية ثم نبسّط كل نصف.
    private static func closedVertices(_ points: [CGPoint], epsilon: CGFloat) -> [CGPoint] {
        guard let first = points.first else { return [] }
        var farIndex = 0
        var farDistance: CGFloat = 0
        for (index, point) in points.enumerated() where point.distance(to: first) > farDistance {
            farDistance = point.distance(to: first)
            farIndex = index
        }
        guard farIndex > 0 else { return [] }
        let firstHalf = InkGeometry.simplify(Array(points[0...farIndex]), epsilon: epsilon)
        let secondHalf = InkGeometry.simplify(Array(points[farIndex...]) + [first], epsilon: epsilon)
        var vertices = firstHalf + secondHalf.dropFirst().dropLast()
        // إزالة الرؤوس الواقعة على خط مستقيم (مثل نقطة البداية في منتصف ضلع)
        var changed = true
        while changed && vertices.count > 3 {
            changed = false
            for index in vertices.indices {
                let previous = vertices[(index + vertices.count - 1) % vertices.count]
                let next = vertices[(index + 1) % vertices.count]
                if InkGeometry.distance(from: vertices[index], toSegment: previous, next) < epsilon * 0.8 {
                    vertices.remove(at: index)
                    changed = true
                    break
                }
            }
        }
        // دمج الرؤوس المتقاربة جداً
        var merged: [CGPoint] = []
        for vertex in vertices where merged.last.map({ $0.distance(to: vertex) > epsilon }) ?? true {
            merged.append(vertex)
        }
        if merged.count > 2, let head = merged.first, let tail = merged.last, head.distance(to: tail) <= epsilon {
            merged.removeLast()
        }
        return merged
    }

    /// شكل رباعي: إن كانت زواياه قريبة من القائمة يصبح مستطيلاً مضبوطاً.
    private static func regularizedQuad(_ vertices: [CGPoint], points: [CGPoint]) -> [CGPoint] {
        func angle(at index: Int) -> CGFloat {
            let a = vertices[(index + 3) % 4], b = vertices[index], c = vertices[(index + 1) % 4]
            let v1 = CGPoint(x: a.x - b.x, y: a.y - b.y), v2 = CGPoint(x: c.x - b.x, y: c.y - b.y)
            let dot = v1.x * v2.x + v1.y * v2.y
            let magnitude = max(0.0001, hypot(v1.x, v1.y) * hypot(v2.x, v2.y))
            return acos(max(-1, min(1, dot / magnitude)))
        }
        let isRectangle = (0..<4).allSatisfy { abs(angle(at: $0) - .pi / 2) < 0.32 }
        guard isRectangle else { return vertices }

        // اتجاه المستطيل من أطول ضلع، ويُقرّب للأفقي إن كان قريباً منه
        var longest = (CGPoint.zero, CGPoint.zero)
        var longestLength: CGFloat = 0
        for index in 0..<4 {
            let a = vertices[index], b = vertices[(index + 1) % 4]
            if a.distance(to: b) > longestLength {
                longestLength = a.distance(to: b)
                longest = (a, b)
            }
        }
        var theta = atan2(longest.1.y - longest.0.y, longest.1.x - longest.0.x)
        let quarter = CGFloat.pi / 2
        let nearestAxis = (theta / quarter).rounded() * quarter
        if abs(theta - nearestAxis) < 0.14 { theta = nearestAxis }

        let center = CGPoint(x: vertices.reduce(0) { $0 + $1.x } / 4, y: vertices.reduce(0) { $0 + $1.y } / 4)
        let toLocal = InkGeometry.rotation(about: center, angle: -theta)
        let local = InkGeometry.bounds(of: points.map { $0.applying(toLocal) })
        let back = InkGeometry.rotation(about: center, angle: theta)
        var corners = [CGPoint(x: local.minX, y: local.minY), CGPoint(x: local.maxX, y: local.minY),
                       CGPoint(x: local.maxX, y: local.maxY), CGPoint(x: local.minX, y: local.maxY)]
            .map { $0.applying(back) }
        // نبدأ من الركن الأقرب لبداية رسم المستخدم
        if let start = points.first,
           let nearest = corners.indices.min(by: { corners[$0].distance(to: start) < corners[$1].distance(to: start) }) {
            corners = Array(corners[nearest...] + corners[..<nearest])
        }
        return corners
    }

    private static func snapAngle(_ a: CGPoint, _ b: CGPoint) -> (CGPoint, CGPoint) {
        let angle = atan2(b.y - a.y, b.x - a.x)
        let step = CGFloat.pi / 4
        let nearest = (angle / step).rounded() * step
        guard abs(angle - nearest) < 0.09 else { return (a, b) }
        let length = a.distance(to: b)
        let middle = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        let dx = cos(nearest) * length / 2, dy = sin(nearest) * length / 2
        return (CGPoint(x: middle.x - dx, y: middle.y - dy), CGPoint(x: middle.x + dx, y: middle.y + dy))
    }

    // بناء خط PencilKit جديد يمر بالمسار المضبوط
    private static func makeStroke(_ shape: Shape, like original: PKStroke) -> PKStroke? {
        var path: [CGPoint] = []
        switch shape {
        case .polyline(let vertices):
            path = densify(vertices, closed: false)
        case .polygon(let vertices):
            path = densify(vertices, closed: true)
        case let .ellipse(center, rx, ry, start, clockwise):
            let perimeter = 2 * .pi * sqrt((rx * rx + ry * ry) / 2)
            let steps = max(48, Int(perimeter / 2.5))
            for step in 0...steps {
                let t = start + (clockwise ? 1 : -1) * 2 * .pi * CGFloat(step) / CGFloat(steps)
                path.append(CGPoint(x: center.x + rx * cos(t), y: center.y + ry * sin(t)))
            }
        }
        guard path.count >= 2 else { return nil }

        let samples = Array(original.path)
        guard !samples.isEmpty else { return nil }
        let size = CGSize(width: InkGeometry.median(samples.map(\.size.width)),
                          height: InkGeometry.median(samples.map(\.size.height)))
        let force = InkGeometry.median(samples.map(\.force))
        let opacity = InkGeometry.median(samples.map(\.opacity))
        let reference = samples[samples.count / 2]

        var controlPoints: [PKStrokePoint] = []
        controlPoints.reserveCapacity(path.count)
        for (index, location) in path.enumerated() {
            controlPoints.append(PKStrokePoint(location: location,
                                               timeOffset: TimeInterval(index) * 0.004,
                                               size: size,
                                               opacity: opacity,
                                               force: force,
                                               azimuth: reference.azimuth,
                                               altitude: reference.altitude,
                                               secondaryScale: reference.secondaryScale))
        }
        let strokePath = PKStrokePath(controlPoints: controlPoints, creationDate: original.path.creationDate)
        return PKStroke(ink: original.ink, path: strokePath, transform: .identity, mask: nil)
    }

    /// نقاط متقاربة على الأضلاع؛ الرؤوس تتكرر لتبقى الزوايا حادة.
    private static func densify(_ vertices: [CGPoint], closed: Bool) -> [CGPoint] {
        var corners = vertices
        if closed, let first = vertices.first { corners.append(first) }
        var result: [CGPoint] = []
        for index in 0..<(corners.count - 1) {
            let a = corners[index], b = corners[index + 1]
            let steps = max(1, Int(a.distance(to: b) / 2.5))
            result.append(contentsOf: [a, a])
            for step in 0..<steps {
                let t = CGFloat(step) / CGFloat(steps)
                result.append(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
            }
        }
        if let end = corners.last { result.append(contentsOf: [end, end, end]) }
        return result
    }
}

// MARK: - ترتيب الخط

/// خطوط الصفحة لمحاذاة الكتابة عليها.
struct PageGuides {
    let frame: CGRect
    let lineYs: [CGFloat]
    let spacing: CGFloat

    init(page: PageRenderInfo) {
        frame = page.frame
        let config = page.background
        let s = max(8, config.spacing)
        spacing = s
        var start: CGFloat?
        switch config.kind {
        case .lined: start = s * 3
        case .grid, .dots: start = s
        case .cornell: start = s * 4
        case .blank, .music: start = nil
        }
        var ys: [CGFloat] = []
        if var y = start, !config.isPDF {
            while y < page.size.height - s * 0.5 {
                ys.append(page.originY + y)
                y += s
            }
        }
        lineYs = ys
    }
}

/// ترتيب الكتابة اليدوية مع الحفاظ على أسلوب صاحبها: تعديل ميلان كل سطر،
/// إنزاله على خط الصفحة، توحيد المسافات بين الكلمات، وتنعيم الرجفة.
enum HandwritingTidy {
    private struct Piece {
        let index: Int
        let points: [CGPoint]
        let bounds: CGRect
    }

    static func tidy(_ drawing: PKDrawing, selecting indices: [Int], guides: [PageGuides],
                     options: TidyOptions) -> PKDrawing? {
        var strokes = drawing.strokes
        let pieces = indices.filter { strokes.indices.contains($0) }.map { index -> Piece in
            let points = InkGeometry.points(of: strokes[index], spacing: 2)
            return Piece(index: index, points: points, bounds: InkGeometry.bounds(of: points))
        }
        let sizable = pieces.filter { max($0.bounds.width, $0.bounds.height) > 4 }
        guard !sizable.isEmpty else { return nil }
        // الحجم التقريبي للحرف: وسيط ارتفاعات الخطوط
        let unit = max(8, InkGeometry.median(sizable.map(\.bounds.height)))
        let lines = groupIntoLines(pieces, unit: unit)

        var changed = false
        for line in lines {
            let main = line.filter { !isSmall($0, unit: unit) }
            let reference = main.isEmpty ? line : main
            let referencePoints = reference.flatMap(\.points)
            let lineBounds = line.map(\.bounds).reduce(CGRect.null) { $0.union($1) }
            let center = CGPoint(x: lineBounds.midX, y: lineBounds.midY)
            let guide = guides.first(where: { $0.frame.insetBy(dx: -30, dy: 0).contains(center) })
            var transform = CGAffineTransform.identity

            // 1) ميلان السطر
            if options.straighten, lineBounds.width > unit * 2.5,
               let slope = InkGeometry.regressionSlope(referencePoints) {
                let angle = atan(slope)
                if abs(angle) > 0.012 && abs(angle) < 0.35 {
                    transform = InkGeometry.rotation(about: center, angle: -angle)
                }
            }

            // 2) الإنزال على خط الصفحة
            if options.snapToLines, let guide, !guide.lineYs.isEmpty {
                let baseline = InkGeometry.percentile(referencePoints.map { $0.applying(transform).y }, 0.82)
                if let target = guide.lineYs.min(by: { abs($0 - baseline) < abs($1 - baseline) }) {
                    let dy = target - baseline - 1
                    if abs(dy) > 0.8 && abs(dy) < guide.spacing * 0.6 {
                        transform = transform.concatenating(CGAffineTransform(translationX: 0, y: dy))
                    }
                }
            }

            // 3) المسافات بين الكلمات
            let shifts = options.evenSpacing ? wordShifts(line, transform: transform, unit: unit, page: guide?.frame) : [:]

            for piece in line {
                var step = transform
                if let dx = shifts[piece.index] {
                    step = step.concatenating(CGAffineTransform(translationX: dx, y: 0))
                }
                if !step.isIdentity {
                    strokes[piece.index].transform = strokes[piece.index].transform.concatenating(step)
                    changed = true
                }
            }
        }

        // 4) التنعيم
        if options.smooth {
            for piece in pieces {
                if let smoothed = smooth(strokes[piece.index]) {
                    strokes[piece.index] = smoothed
                    changed = true
                }
            }
        }
        return changed ? PKDrawing(strokes: strokes) : nil
    }

    private static func isSmall(_ piece: Piece, unit: CGFloat) -> Bool {
        max(piece.bounds.width, piece.bounds.height) < unit * 0.45
    }

    /// تقسيم الخطوط إلى أسطر حسب موضعها العمودي؛ النقاط والتشكيل تلحق بأقرب سطر.
    private static func groupIntoLines(_ pieces: [Piece], unit: CGFloat) -> [[Piece]] {
        let main = pieces.filter { !isSmall($0, unit: unit) }.sorted { $0.bounds.midY < $1.bounds.midY }
        let small = pieces.filter { isSmall($0, unit: unit) }
        guard !main.isEmpty else { return [pieces] }

        var lines: [[Piece]] = []
        var means: [CGFloat] = []
        for piece in main {
            if let mean = means.last, piece.bounds.midY - mean < unit * 0.9 {
                lines[lines.count - 1].append(piece)
                let group = lines[lines.count - 1]
                means[means.count - 1] = group.reduce(0) { $0 + $1.bounds.midY } / CGFloat(group.count)
            } else {
                lines.append([piece])
                means.append(piece.bounds.midY)
            }
        }
        for piece in small {
            if let nearest = means.indices.min(by: { abs(means[$0] - piece.bounds.midY) < abs(means[$1] - piece.bounds.midY) }) {
                lines[nearest].append(piece)
            }
        }
        return lines
    }

    /// إزاحات أفقية تقرّب المسافات بين الكلمات من مسافة موحّدة (مع تثبيت بداية السطر).
    private static func wordShifts(_ line: [Piece], transform: CGAffineTransform, unit: CGFloat,
                                   page: CGRect?) -> [Int: CGFloat] {
        struct Word { var minX: CGFloat; var maxX: CGFloat; var indices: [Int] }
        let extents = line.map { piece -> (Int, CGFloat, CGFloat) in
            let xs = piece.points.map { $0.applying(transform).x }
            return (piece.index, xs.min() ?? 0, xs.max() ?? 0)
        }.sorted { $0.1 < $1.1 }

        var words: [Word] = []
        let joinGap = unit * 0.55
        for (index, minX, maxX) in extents {
            if var last = words.last, minX - last.maxX < joinGap {
                last.maxX = max(last.maxX, maxX)
                last.indices.append(index)
                words[words.count - 1] = last
            } else {
                words.append(Word(minX: minX, maxX: maxX, indices: [index]))
            }
        }
        guard words.count >= 3 else { return [:] }

        let gaps = zip(words, words.dropFirst()).map { $1.minX - $0.maxX }
        let target = min(max(InkGeometry.median(gaps), unit * 0.6), unit * 1.6)
        let adjusted = gaps.map { $0 + (target - $0) * 0.7 }
        let limit = unit * 1.5

        // الكتابة العربية تبدأ من اليمين: نثبّت الطرف الأقرب لحافة الصفحة التي بدأ منها السطر
        let startsFromRight: Bool
        if let page, let first = words.first, let last = words.last {
            startsFromRight = (page.maxX - last.maxX) <= (first.minX - page.minX)
        } else {
            startsFromRight = true
        }

        var shifts: [Int: CGFloat] = [:]
        var offsets = [CGFloat](repeating: 0, count: words.count)
        if startsFromRight {
            for index in stride(from: words.count - 2, through: 0, by: -1) {
                let newMaxX = words[index + 1].minX + offsets[index + 1] - adjusted[index]
                offsets[index] = max(-limit, min(limit, newMaxX - words[index].maxX))
            }
        } else {
            for index in 1..<words.count {
                let newMinX = words[index - 1].maxX + offsets[index - 1] + adjusted[index - 1]
                offsets[index] = max(-limit, min(limit, newMinX - words[index].minX))
            }
        }
        for (word, offset) in zip(words, offsets) where abs(offset) > 0.5 {
            for index in word.indices { shifts[index] = offset }
        }
        return shifts
    }

    /// تنعيم خفيف لنقاط التحكم المتقاربة فقط (لا يغيّر شكل الحروف).
    private static func smooth(_ stroke: PKStroke) -> PKStroke? {
        guard stroke.mask == nil else { return nil }
        let points = Array(stroke.path)
        guard points.count >= 5 else { return nil }
        var result: [PKStrokePoint] = []
        result.reserveCapacity(points.count)
        var moved = false
        for index in points.indices {
            let point = points[index]
            guard index > 0, index < points.count - 1 else {
                result.append(point)
                continue
            }
            let a = points[index - 1].location, b = point.location, c = points[index + 1].location
            guard a.distance(to: b) < 4, b.distance(to: c) < 4 else {
                result.append(point)
                continue
            }
            let average = CGPoint(x: (a.x + c.x) / 2, y: (a.y + c.y) / 2)
            let location = CGPoint(x: b.x + (average.x - b.x) * 0.4, y: b.y + (average.y - b.y) * 0.4)
            if location.distance(to: b) > 0.05 { moved = true }
            result.append(PKStrokePoint(location: location,
                                        timeOffset: point.timeOffset,
                                        size: point.size,
                                        opacity: point.opacity,
                                        force: point.force,
                                        azimuth: point.azimuth,
                                        altitude: point.altitude,
                                        secondaryScale: point.secondaryScale))
        }
        guard moved else { return nil }
        var copy = stroke
        copy.path = PKStrokePath(controlPoints: result, creationDate: stroke.path.creationDate)
        return copy
    }
}
