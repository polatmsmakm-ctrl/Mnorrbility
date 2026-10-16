import CoreGraphics
import UIKit

/// قلب الألوان للوضع الليلي مع الحفاظ على اللون (نفس فكرة Notability: HuePreservingInvert).
///
/// الفكرة: نقلب إضاءة اللون ونُبقي درجته وقوته. الأسود يصبح أبيض، والورق الفاتح يصبح داكناً،
/// والألوان الصريحة (أزرق، أصفر، أحمر) تبقى هي نفسها تقريباً بدل أن تنقلب إلى لونها المعاكس.
///
/// الرياضيات: لكل قناة ناتج = القناة + (1 − أكبر قناة − أصغر قناة).
/// وهي تعادل: قلب RGB، ثم أخذ التشبع والسطوع من الناتج مع إعادة درجة اللون الأصلية.
enum HueInvert {
    /// قلب قيم RGB بين 0 و1.
    @inline(__always)
    static func invert(r: CGFloat, g: CGFloat, b: CGFloat) -> (CGFloat, CGFloat, CGFloat) {
        let shift = 1 - max(r, g, b) - min(r, g, b)
        func clamp(_ v: CGFloat) -> CGFloat { min(max(v, 0), 1) }
        return (clamp(r + shift), clamp(g + shift), clamp(b + shift))
    }

    /// يقلب صورة (غير شفافة) بالكامل. يعيد nil إن تعذّر.
    static func invert(_ image: CGImage) -> CGImage? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }

        // الترتيب في الذاكرة: B, G, R, A (little endian + alpha first)
        pixels.withUnsafeMutableBufferPointer { buffer in
            var i = 0
            let count = width * height
            for _ in 0..<count {
                let alpha = buffer[i + 3]
                if alpha == 255 {
                    let b = Int(buffer[i]), g = Int(buffer[i + 1]), r = Int(buffer[i + 2])
                    let shift = 255 - max(r, g, b) - min(r, g, b)
                    buffer[i] = UInt8(clamping: b + shift)
                    buffer[i + 1] = UInt8(clamping: g + shift)
                    buffer[i + 2] = UInt8(clamping: r + shift)
                }
                i += 4
            }
        }

        return pixels.withUnsafeMutableBytes { buffer -> CGImage? in
            CGContext(data: buffer.baseAddress, width: width, height: height,
                      bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info)?.makeImage()
        }
    }
}

extension UIColor {
    /// اللون بعد القلب الليلي مع الحفاظ على درجته (يحافظ على الشفافية).
    var hueInverted: UIColor {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        if !getRed(&r, green: &g, blue: &b, alpha: &a) {
            var white: CGFloat = 0
            getWhite(&white, alpha: &a)
            r = white; g = white; b = white
        }
        let (nr, ng, nb) = HueInvert.invert(r: r, g: g, b: b)
        return UIColor(red: nr, green: ng, blue: nb, alpha: a)
    }
}
