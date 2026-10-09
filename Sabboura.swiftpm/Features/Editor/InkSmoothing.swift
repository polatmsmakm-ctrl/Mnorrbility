import PencilKit
import UIKit

// MARK: - الإعداد

/// التنعيم التلقائي للخط أثناء الكتابة: كل خط يتحول لمنحنيات Bézier ناعمة أول ما يرتفع القلم.
enum InkSmoothingLevel: String, CaseIterable, Codable, Identifiable {
    case off
    case light
    case strong

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: return "إيقاف"
        case .light: return "خفيف"
        case .strong: return "قوي"
        }
    }

    /// أقصى ابتعاد مسموح عن الخط الأصلي، بنقاط الشاشة (يُقسم على التكبير).
    var screenTolerance: CGFloat {
        switch self {
        case .off: return 0
        case .light: return 0.9
        case .strong: return 1.8
        }
    }

    private static let key = "sabboura.inkSmoothing"

    static func load() -> InkSmoothingLevel {
        guard let raw = UserDefaults.standard.string(forKey: key),
              let value = InkSmoothingLevel(rawValue: raw) else { return .light }
        return value
    }

    func save() {
        UserDefaults.standard.set(rawValue, forKey: Self.key)
    }
}

// MARK: - منحنى Bézier التكعيبي

struct CubicBezier {
    var p0: CGPoint
    var p1: CGPoint
    var p2: CGPoint
    var p3: CGPoint

    func point(at t: CGFloat) -> CGPoint {
        let mt = 1 - t
        let a = mt * mt * mt, b = 3 * mt * mt * t, c = 3 * mt * t * t, d = t * t * t
        return CGPoint(x: a * p0.x + b * p1.x + c * p2.x + d * p3.x,
                       y: a * p0.y + b * p1.y + c * p2.y + d * p3.y)
    }

    func derivative(at t: CGFloat) -> CGPoint {
        let mt = 1 - t
        let a = 3 * mt * mt, b = 6 * mt * t, c = 3 * t * t
        return CGPoint(x: a * (p1.x - p0.x) + b * (p2.x - p1.x) + c * (p3.x - p2.x),
                       y: a * (p1.y - p0.y) + b * (p2.y - p1.y) + c * (p3.y - p2.y))
    }

    func secondDerivative(at t: CGFloat) -> CGPoint {
        let mt = 1 - t
        return CGPoint(x: 6 * mt * (p2.x - 2 * p1.x + p0.x) + 6 * t * (p3.x - 2 * p2.x + p1.x),
                       y: 6 * mt * (p2.y - 2 * p1.y + p0.y) + 6 * t * (p3.y - 2 * p2.y + p1.y))
    }
}

// MARK: - مطابقة المنحنيات

/// يحوّل سلسلة نقاط لمنحنيات Bézier تكعيبية لا تبتعد عن النقاط أكثر من حد معيّن
/// (خوارزمية Philip J. Schneider من كتاب Graphics Gems، 1990)، مع الحفاظ على الزوايا الحادة.
enum BezierCurveFit {
    struct Piece {
        let curve: CubicBezier
        /// نطاق النقاط الأصلية التي يغطيها هذا المنحنى
        let first: Int
        let last: Int
    }

    private static let maxIterations = 4

    static func fit(_ points: [CGPoint], tolerance: CGFloat, corners: [Int]) -> [Piece] {
        guard points.count >= 2 else { return [] }
        var boundaries = [0] + corners.filter { $0 > 0 && $0 < points.count - 1 } + [points.count - 1]
        boundaries = Array(Set(boundaries)).sorted()
        var pieces: [Piece] = []
        let errorSquared = tolerance * tolerance
        for (first, last) in zip(boundaries, boundaries.dropFirst()) where last > first {
            let left = leftTangent(points, first, last)
            let right = rightTangent(points, first, last)
            fitCubic(points, first, last, left, right, errorSquared, depth: 0, into: &pieces)
        }
        return pieces
    }

    /// الزوايا الحادة: نقاط ينعطف عندها الخط أكثر من ٦٠ درجة (أقوى نقطة في كل منطقة).
    static func corners(_ points: [CGPoint], window: Int) -> [Int] {
        let k = max(2, window)
        guard points.count > 2 * k + 1 else { return [] }
        var candidates: [(index: Int, cosine: CGFloat)] = []
        for index in k..<(points.count - k) {
            let incoming = points[index] - points[index - k]
            let outgoing = points[index + k] - points[index]
            let lengths = incoming.length * outgoing.length
            guard lengths > 0.0001 else { continue }
            let cosine = incoming.dot(outgoing) / lengths
            if cosine < 0.5 { candidates.append((index, cosine)) }
        }
        var result: [Int] = []
        var group: [(index: Int, cosine: CGFloat)] = []
        func flush() {
            if let sharpest = group.min(by: { $0.cosine < $1.cosine }) { result.append(sharpest.index) }
            group.removeAll()
        }
        for candidate in candidates {
            if let previous = group.last, candidate.index - previous.index > k { flush() }
            group.append(candidate)
        }
        flush()
        return result
    }

    // MARK: الخوارزمية

    private static func fitCubic(_ d: [CGPoint], _ first: Int, _ last: Int,
                                 _ tHat1: CGPoint, _ tHat2: CGPoint,
                                 _ errorSquared: CGFloat, depth: Int, into pieces: inout [Piece]) {
        let count = last - first + 1
        if count == 2 || depth > 24 {
            let distance = (d[last] - d[first]).length / 3
            let curve = CubicBezier(p0: d[first], p1: d[first] + tHat1 * distance,
                                    p2: d[last] + tHat2 * distance, p3: d[last])
            pieces.append(Piece(curve: curve, first: first, last: last))
            return
        }

        var u = chordLengthParameters(d, first, last)
        var curve = generateBezier(d, first, last, u, tHat1, tHat2)
        var (maxError, split) = maxErrorAndSplit(d, first, last, curve, u)
        if maxError < errorSquared {
            pieces.append(Piece(curve: curve, first: first, last: last))
            return
        }

        if maxError < errorSquared * 4 {
            for _ in 0..<maxIterations {
                let refined = reparameterize(d, first, last, u, curve)
                curve = generateBezier(d, first, last, refined, tHat1, tHat2)
                (maxError, split) = maxErrorAndSplit(d, first, last, curve, refined)
                if maxError < errorSquared {
                    pieces.append(Piece(curve: curve, first: first, last: last))
                    return
                }
                u = refined
            }
        }

        let center = centerTangent(d, split)
        fitCubic(d, first, split, tHat1, center, errorSquared, depth: depth + 1, into: &pieces)
        fitCubic(d, split, last, center * -1, tHat2, errorSquared, depth: depth + 1, into: &pieces)
    }

    private static func generateBezier(_ d: [CGPoint], _ first: Int, _ last: Int, _ u: [CGFloat],
                                       _ tHat1: CGPoint, _ tHat2: CGPoint) -> CubicBezier {
        let start = d[first], end = d[last]
        var c00: CGFloat = 0, c01: CGFloat = 0, c11: CGFloat = 0
        var x0: CGFloat = 0, x1: CGFloat = 0

        for (offset, t) in u.enumerated() {
            let mt = 1 - t
            let b0 = mt * mt * mt, b1 = 3 * mt * mt * t, b2 = 3 * mt * t * t, b3 = t * t * t
            let a1 = tHat1 * b1
            let a2 = tHat2 * b2
            c00 += a1.dot(a1)
            c01 += a1.dot(a2)
            c11 += a2.dot(a2)
            let estimate = start * (b0 + b1) + end * (b2 + b3)
            let difference = d[first + offset] - estimate
            x0 += a1.dot(difference)
            x1 += a2.dot(difference)
        }

        let determinant = c00 * c11 - c01 * c01
        var alphaLeft: CGFloat = 0, alphaRight: CGFloat = 0
        if abs(determinant) > 1e-12 {
            alphaLeft = (x0 * c11 - x1 * c01) / determinant
            alphaRight = (c00 * x1 - c01 * x0) / determinant
        }

        let segmentLength = (end - start).length
        let epsilon = 1e-6 * segmentLength
        // قيم غير منطقية (سالبة أو كبيرة جداً) نستبدلها بتقدير بسيط
        if alphaLeft < epsilon || alphaRight < epsilon
            || alphaLeft > segmentLength * 3 || alphaRight > segmentLength * 3 {
            let distance = segmentLength / 3
            return CubicBezier(p0: start, p1: start + tHat1 * distance, p2: end + tHat2 * distance, p3: end)
        }
        return CubicBezier(p0: start, p1: start + tHat1 * alphaLeft, p2: end + tHat2 * alphaRight, p3: end)
    }

    /// تحسين قيم t لكل نقطة بخطوة Newton–Raphson.
    private static func reparameterize(_ d: [CGPoint], _ first: Int, _ last: Int,
                                       _ u: [CGFloat], _ curve: CubicBezier) -> [CGFloat] {
        u.enumerated().map { offset, t in
            let point = d[first + offset]
            let q = curve.point(at: t)
            let q1 = curve.derivative(at: t)
            let q2 = curve.secondDerivative(at: t)
            let difference = q - point
            let numerator = difference.dot(q1)
            let denominator = q1.dot(q1) + difference.dot(q2)
            guard abs(denominator) > 1e-12 else { return t }
            return min(1, max(0, t - numerator / denominator))
        }
    }

    private static func chordLengthParameters(_ d: [CGPoint], _ first: Int, _ last: Int) -> [CGFloat] {
        var u: [CGFloat] = [0]
        u.reserveCapacity(last - first + 1)
        for index in (first + 1)...last {
            u.append(u[u.count - 1] + (d[index] - d[index - 1]).length)
        }
        let total = u[u.count - 1]
        guard total > 0 else {
            return (0...(last - first)).map { CGFloat($0) / CGFloat(max(1, last - first)) }
        }
        return u.map { $0 / total }
    }

    private static func maxErrorAndSplit(_ d: [CGPoint], _ first: Int, _ last: Int,
                                         _ curve: CubicBezier, _ u: [CGFloat]) -> (CGFloat, Int) {
        var maxDistance: CGFloat = 0
        var split = (first + last + 1) / 2
        for index in (first + 1)..<last {
            let distance = (curve.point(at: u[index - first]) - d[index]).lengthSquared
            if distance >= maxDistance {
                maxDistance = distance
                split = index
            }
        }
        return (maxDistance, min(max(split, first + 1), last - 1))
    }

    // اتجاهات المماس تُقدّر من نقطتين أو ثلاث للأمام (أثبت من نقطة واحدة مع الرجفة)
    private static func leftTangent(_ d: [CGPoint], _ first: Int, _ last: Int) -> CGPoint {
        let target = min(first + 2, last)
        return (d[target] - d[first]).normalized(fallback: CGPoint(x: 1, y: 0))
    }

    private static func rightTangent(_ d: [CGPoint], _ first: Int, _ last: Int) -> CGPoint {
        let target = max(last - 2, first)
        return (d[target] - d[last]).normalized(fallback: CGPoint(x: -1, y: 0))
    }

    private static func centerTangent(_ d: [CGPoint], _ center: Int) -> CGPoint {
        let v1 = d[center - 1] - d[center]
        let v2 = d[center] - d[center + 1]
        let average = (v1 + v2) * 0.5
        return average.normalized(fallback: v1.normalized(fallback: CGPoint(x: -1, y: 0)))
    }
}

// MARK: - تنعيم خط PencilKit

enum InkSmoother {
    /// المسافة بين النقاط عند قراءة الخط وإعادة بنائه (بإحداثيات الخط)
    private static let spacing: CGFloat = 1.5

    /// يعيد الخط بعد تحويله لمنحنيات ناعمة، مع الحفاظ على الضغط والسماكة والميلان والزوايا.
    /// - Parameter tolerance: أقصى ابتعاد عن الخط الأصلي بإحداثيات الرسم.
    static func smoothed(_ stroke: PKStroke, tolerance: CGFloat) -> PKStroke? {
        guard tolerance > 0.05, stroke.mask == nil else { return nil }
        // التحويل (تكبير أو تدوير بعد التحديد) يغيّر المقياس: نحوّل الحد لإحداثيات المسار نفسه
        let t = stroke.transform
        let scale = sqrt(abs(t.a * t.d - t.b * t.c))
        guard scale > 0.0001 else { return nil }
        let localTolerance = tolerance / scale
        let localSpacing = spacing / max(scale, 0.5)

        var samples: [PKStrokePoint] = []
        for point in stroke.path.interpolatedPoints(by: .distance(localSpacing)) {
            if let previous = samples.last, (point.location - previous.location).length < localSpacing * 0.3 {
                continue
            }
            samples.append(point)
        }
        guard samples.count >= 8 else { return nil }
        let locations = samples.map(\.location)
        var cumulative: [CGFloat] = [0]
        cumulative.reserveCapacity(locations.count)
        for index in 1..<locations.count {
            cumulative.append(cumulative[index - 1] + (locations[index] - locations[index - 1]).length)
        }
        // النقاط والتشكيل الصغيرة تبقى كما هي
        guard let total = cumulative.last, total * scale > 6 else { return nil }

        // نافذة كشف الزوايا ≈ ٤٫٥ نقطة: أصغر من كذا تحسب رجفة اليد زوايا
        let window = max(2, Int((max(4.5 / scale, localTolerance * 3) / localSpacing).rounded()))
        let corners = BezierCurveFit.corners(locations, window: window)
        let pieces = BezierCurveFit.fit(locations, tolerance: localTolerance, corners: corners)
        guard !pieces.isEmpty else { return nil }

        var output: [PKStrokePoint] = []
        output.reserveCapacity(samples.count + corners.count)
        for (pieceIndex, piece) in pieces.enumerated() {
            let sourceStart = cumulative[piece.first]
            let sourceLength = cumulative[piece.last] - sourceStart

            // نقاط كثيفة على المنحنى، ثم نوزّعها بمسافات متساوية تقريباً
            let dense = 24
            var curvePoints: [CGPoint] = []
            var curveLengths: [CGFloat] = [0]
            for step in 0...dense {
                let point = piece.curve.point(at: CGFloat(step) / CGFloat(dense))
                if let previous = curvePoints.last {
                    curveLengths.append(curveLengths[curveLengths.count - 1] + (point - previous).length)
                }
                curvePoints.append(point)
            }
            let curveLength = curveLengths[curveLengths.count - 1]
            let count = max(1, Int((curveLength / localSpacing).rounded(.up)))
            // نقطة البداية تُضاف للمنحنى الأول فقط (بقية المنحنيات تبدأ من نهاية السابق)
            let firstStep = pieceIndex == 0 ? 0 : 1
            guard firstStep <= count else { continue }
            var cursor = 0
            for step in firstStep...count {
                let fraction = CGFloat(step) / CGFloat(count)
                let target = fraction * curveLength
                while cursor < curveLengths.count - 2 && curveLengths[cursor + 1] < target { cursor += 1 }
                let segment = max(curveLengths[cursor + 1] - curveLengths[cursor], 0.0001)
                let local = min(max((target - curveLengths[cursor]) / segment, 0), 1)
                let location = curvePoints[cursor] + (curvePoints[cursor + 1] - curvePoints[cursor]) * local
                let attributes = interpolate(samples, cumulative, at: sourceStart + fraction * sourceLength)
                output.append(PKStrokePoint(location: location,
                                            timeOffset: attributes.timeOffset,
                                            size: attributes.size,
                                            opacity: attributes.opacity,
                                            force: attributes.force,
                                            azimuth: attributes.azimuth,
                                            altitude: attributes.altitude,
                                            secondaryScale: attributes.secondaryScale))
            }
        }
        guard output.count >= 2 else { return nil }

        var copy = stroke
        copy.path = PKStrokePath(controlPoints: output, creationDate: stroke.path.creationDate)
        return copy
    }

    /// خصائص الخط (الضغط، السماكة، الميلان...) عند مسافة معيّنة على الخط الأصلي.
    private static func interpolate(_ samples: [PKStrokePoint], _ cumulative: [CGFloat],
                                    at distance: CGFloat) -> PKStrokePoint {
        guard let total = cumulative.last, samples.count > 1 else { return samples[0] }
        let target = min(max(distance, 0), total)
        var low = 0, high = cumulative.count - 1
        while high - low > 1 {
            let middle = (low + high) / 2
            if cumulative[middle] <= target { low = middle } else { high = middle }
        }
        let a = samples[low], b = samples[high]
        let span = cumulative[high] - cumulative[low]
        let f = span > 0.0001 ? (target - cumulative[low]) / span : 0
        func mix(_ x: CGFloat, _ y: CGFloat) -> CGFloat { x + (y - x) * f }
        var azimuthDelta = b.azimuth - a.azimuth
        if azimuthDelta > .pi { azimuthDelta -= 2 * .pi }
        if azimuthDelta < -.pi { azimuthDelta += 2 * .pi }
        return PKStrokePoint(location: .zero,
                             timeOffset: a.timeOffset + (b.timeOffset - a.timeOffset) * Double(f),
                             size: CGSize(width: mix(a.size.width, b.size.width),
                                          height: mix(a.size.height, b.size.height)),
                             opacity: mix(a.opacity, b.opacity),
                             force: mix(a.force, b.force),
                             azimuth: a.azimuth + azimuthDelta * f,
                             altitude: mix(a.altitude, b.altitude),
                             secondaryScale: mix(a.secondaryScale, b.secondaryScale))
    }
}

// MARK: - عمليات النقاط

private extension CGPoint {
    static func + (lhs: CGPoint, rhs: CGPoint) -> CGPoint { CGPoint(x: lhs.x + rhs.x, y: lhs.y + rhs.y) }
    static func - (lhs: CGPoint, rhs: CGPoint) -> CGPoint { CGPoint(x: lhs.x - rhs.x, y: lhs.y - rhs.y) }
    static func * (lhs: CGPoint, rhs: CGFloat) -> CGPoint { CGPoint(x: lhs.x * rhs, y: lhs.y * rhs) }

    func dot(_ other: CGPoint) -> CGFloat { x * other.x + y * other.y }
    var lengthSquared: CGFloat { x * x + y * y }
    var length: CGFloat { sqrt(lengthSquared) }

    func normalized(fallback: CGPoint) -> CGPoint {
        let l = length
        return l > 1e-9 ? CGPoint(x: x / l, y: y / l) : fallback
    }
}
