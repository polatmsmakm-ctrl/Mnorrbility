import AVFoundation
import UIKit
import UserNotifications

/// تنبيه انتهاء فترة المذاكرة: نغمة جرس مولّدة بالكود + اهتزاز.
/// يُستخدم والتطبيق مفتوح؛ وفي الخلفية يتولى الأمر إشعار النظام.
enum TimerAlert {
    static let key = "sabboura.study.alert"

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? true
    }

    private static var player: AVAudioPlayer?
    private static let chime: Data = makeChime()

    /// ينبّه فقط إن كان التنبيه مفعّلاً في الإعدادات.
    static func fire() {
        guard isEnabled else { return }
        preview()
    }

    /// يشغّل النغمة والاهتزاز (يُستخدم أيضاً لتجربة التنبيه من الإعدادات).
    static func preview() {
        guard !AppEnvironment.isUITest else { return }
        vibrate()
        PlaybackSession.activate()
        do {
            let chimePlayer = try AVAudioPlayer(data: chime)
            chimePlayer.volume = 1
            chimePlayer.prepareToPlay()
            chimePlayer.play()
            player = chimePlayer
        } catch {
            print("⚠️ Chime failed: \(error)")
        }
    }

    private static func vibrate() {
        for delay in [0.0, 0.6, 1.2] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            }
        }
    }

    /// أربع نغمات صاعدة (لا – دو# – مي – لا عالية) بتلاشي ناعم، بصيغة WAV أحادية 16 بت.
    private static func makeChime() -> Data {
        let sampleRate = 44_100
        let duration = 2.8
        let count = Int(Double(sampleRate) * duration)
        var mix = [Double](repeating: 0, count: count)
        let notes: [(frequency: Double, start: Double)] = [
            (880.00, 0.00), (1108.73, 0.35), (1318.51, 0.70), (1760.00, 1.15)
        ]
        for note in notes {
            let offset = Int(note.start * Double(sampleRate))
            guard offset < count else { continue }
            for i in 0..<(count - offset) {
                let t = Double(i) / Double(sampleRate)
                let attack = min(1.0, t / 0.005)
                let envelope = attack * exp(-2.6 * t)
                let tone = sin(2 * Double.pi * note.frequency * t)
                    + 0.35 * sin(2 * Double.pi * note.frequency * 2 * t)
                    + 0.12 * sin(2 * Double.pi * note.frequency * 3 * t)
                mix[offset + i] += tone * envelope * 0.22
            }
        }
        var samples = [Int16](repeating: 0, count: count)
        for i in 0..<count {
            let clamped = max(-1.0, min(1.0, mix[i]))
            samples[i] = Int16(clamped * 32_000)
        }

        var data = Data()
        func append32(_ value: UInt32) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        func append16(_ value: UInt16) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        let byteCount = UInt32(count * 2)
        data.append(Data("RIFF".utf8))
        append32(36 + byteCount)
        data.append(Data("WAVE".utf8))
        data.append(Data("fmt ".utf8))
        append32(16)
        append16(1)                       // PCM
        append16(1)                       // قناة واحدة
        append32(UInt32(sampleRate))
        append32(UInt32(sampleRate * 2))
        append16(2)
        append16(16)
        data.append(Data("data".utf8))
        append32(byteCount)
        samples.withUnsafeBytes { data.append(contentsOf: $0) }
        return data
    }
}

/// يعرض إشعارات التطبيق (بانر) حتى والتطبيق مفتوح؛ بدونه لا يظهر إشعار انتهاء المؤقت أثناء الاستخدام.
final class NotificationPresenter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationPresenter()

    func install() {
        UNUserNotificationCenter.current().delegate = self
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        // نغمتنا الخاصة تُشغَّل من التطبيق؛ فإن عُطّلت نترك صوت النظام
        completionHandler(TimerAlert.isEnabled ? [.banner, .list] : [.banner, .list, .sound])
    }
}
