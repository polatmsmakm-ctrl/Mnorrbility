import AVFoundation
import Combine
import SwiftUI

/// جلسة الصوت المشتركة للتشغيل (وايت نويز + نغمة التنبيه): تختلط مع صوت التطبيقات الأخرى
/// وتستمر في الخلفية (UIBackgroundModes = audio).
enum PlaybackSession {
    static func activate() {
        let session = AVAudioSession.sharedInstance()
        do {
            // أثناء تسجيل صوتي تكون الفئة playAndRecord وتكفي للتشغيل، فلا نغيّرها كي لا ينقطع التسجيل
            if session.category != .playAndRecord {
                try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            }
            try session.setActive(true)
        } catch {
            print("⚠️ Audio session failed: \(error)")
        }
    }
}

/// مولّد ضوضاء في الوقت الحقيقي بدون ملفات صوتية: أبيض، وردي، بني.
final class NoiseGenerator {
    /// 0 = أبيض، 1 = وردي، 2 = بني
    var kind: Int = 0
    /// مستوى الصوت المطلوب (0 أو 1) والانتقال إليه تدريجياً لتفادي الطقطقة.
    var targetGain: Float = 0

    private var gain: Float = 0
    private var seed: UInt32 = 2_463_534_242
    private var b0: Float = 0
    private var b1: Float = 0
    private var b2: Float = 0
    private var b3: Float = 0
    private var b4: Float = 0
    private var b5: Float = 0
    private var b6: Float = 0
    private var brown: Float = 0
    private let slew: Float

    init(sampleRate: Double) {
        // انتقال ناعم خلال ~0.6 ثانية
        slew = Float(1.0 / (0.6 * sampleRate))
    }

    @inline(__always)
    private func white() -> Float {
        seed ^= seed << 13
        seed ^= seed >> 17
        seed ^= seed << 5
        return Float(Int32(bitPattern: seed)) / Float(Int32.max)
    }

    @inline(__always)
    private func sample() -> Float {
        let w = white()
        switch kind {
        case 1:
            // وردي (مرشّح Paul Kellet)
            b0 = 0.99886 * b0 + w * 0.0555179
            b1 = 0.99332 * b1 + w * 0.0750759
            b2 = 0.96900 * b2 + w * 0.1538520
            b3 = 0.86650 * b3 + w * 0.3104856
            b4 = 0.55000 * b4 + w * 0.5329522
            b5 = -0.7616 * b5 - w * 0.0168980
            let pink = b0 + b1 + b2 + b3 + b4 + b5 + b6 + w * 0.5362
            b6 = w * 0.115926
            return pink * 0.16
        case 2:
            // بني (تكامل متسرّب)
            brown = (brown + 0.02 * w) / 1.02
            return brown * 3.5
        default:
            return w * 0.5
        }
    }

    func render(frames: Int, into list: UnsafeMutablePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(list)
        let target = targetGain
        for frame in 0..<frames {
            if gain < target {
                gain = min(target, gain + slew)
            } else if gain > target {
                gain = max(target, gain - slew)
            }
            let value = sample() * gain
            for buffer in buffers {
                buffer.mData?.assumingMemoryBound(to: Float.self)[frame] = value
            }
        }
    }
}

/// أصوات التركيز (وايت نويز). تعمل في الخلفية وتتوقف مؤقتاً أثناء التسجيل الصوتي.
final class WhiteNoiseManager: ObservableObject {
    static let shared = WhiteNoiseManager()

    enum Kind: String, CaseIterable, Identifiable {
        case white, pink, brown

        var id: String { rawValue }

        var title: String {
            switch self {
            case .white: return "أبيض"
            case .pink: return "وردي"
            case .brown: return "بني"
            }
        }

        var detail: String {
            switch self {
            case .white: return "ثابت وحاد، يغطي على الأصوات المحيطة"
            case .pink: return "متوازن وأنعم، يشبه المطر والشلال"
            case .brown: return "عميق وهادئ، يشبه الرعد البعيد"
            }
        }

        fileprivate var index: Int {
            switch self {
            case .white: return 0
            case .pink: return 1
            case .brown: return 2
            }
        }
    }

    @Published var kind: Kind {
        didSet {
            defaults.set(kind.rawValue, forKey: Keys.kind)
            generator?.kind = kind.index
        }
    }
    @Published var volume: Double {
        didSet {
            defaults.set(volume, forKey: Keys.volume)
            engine?.mainMixerNode.outputVolume = Float(volume)
        }
    }
    /// تشغيل الصوت تلقائياً مع فترات الدراسة وإيقافه في الاستراحة.
    @Published var playWithStudy: Bool {
        didSet { defaults.set(playWithStudy, forKey: Keys.withStudy) }
    }
    @Published private(set) var isPlaying = false

    private let defaults = UserDefaults.standard
    private var engine: AVAudioEngine?
    private var generator: NoiseGenerator?
    private var wantsPlaying = false
    private var suspendedForRecording = false
    private var stopWork: DispatchWorkItem?

    private enum Keys {
        static let kind = "sabboura.noise.kind"
        static let volume = "sabboura.noise.volume"
        static let withStudy = "sabboura.noise.withStudy"
    }

    init() {
        kind = Kind(rawValue: defaults.string(forKey: Keys.kind) ?? "") ?? .brown
        volume = defaults.object(forKey: Keys.volume) as? Double ?? 0.5
        playWithStudy = defaults.object(forKey: Keys.withStudy) as? Bool ?? false

        let center = NotificationCenter.default
        center.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) { [weak self] _ in
            self?.restartIfNeeded()
        }
        center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            self?.handleInterruption(note)
        }
    }

    // MARK: التحكم

    func play() {
        guard !AppEnvironment.isUITest else { return }
        wantsPlaying = true
        stopWork?.cancel()
        stopWork = nil
        startEngine()
    }

    func stop() {
        wantsPlaying = false
        isPlaying = false
        generator?.targetGain = 0
        stopWork?.cancel()
        // نترك نصف ثانية للتلاشي ثم نوقف المحرك لتوفير البطارية
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.wantsPlaying else { return }
            self.engine?.stop()
        }
        stopWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    func toggle() {
        isPlaying ? stop() : play()
    }

    /// التسجيل الصوتي يحتاج جلسة صوت خاصة به: نوقف الصوت مؤقتاً ثم نكمل بعده.
    func suspendForRecording() {
        guard wantsPlaying else { return }
        suspendedForRecording = true
        engine?.stop()
        isPlaying = false
    }

    func resumeAfterRecording() {
        guard suspendedForRecording else { return }
        suspendedForRecording = false
        if wantsPlaying { startEngine() }
    }

    // MARK: داخلي

    private func buildEngine() {
        let engine = AVAudioEngine()
        let outputRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        let rate = outputRate > 0 ? outputRate : 44_100
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2) else { return }
        let generator = NoiseGenerator(sampleRate: rate)
        let node = AVAudioSourceNode(format: format) { _, _, frames, list -> OSStatus in
            generator.render(frames: Int(frames), into: list)
            return noErr
        }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        self.engine = engine
        self.generator = generator
    }

    private func startEngine() {
        guard !suspendedForRecording else { return }
        PlaybackSession.activate()
        if engine == nil { buildEngine() }
        guard let engine, let generator else { return }
        generator.kind = kind.index
        generator.targetGain = 1
        engine.mainMixerNode.outputVolume = Float(volume)
        if !engine.isRunning {
            do {
                try engine.start()
            } catch {
                print("⚠️ White noise failed: \(error)")
                wantsPlaying = false
                isPlaying = false
                return
            }
        }
        isPlaying = true
    }

    /// تغيّر مسار الصوت (سماعات، بلوتوث…) يوقف المحرك: نعيد تشغيله.
    private func restartIfNeeded() {
        guard wantsPlaying, !suspendedForRecording else { return }
        startEngine()
    }

    private func handleInterruption(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            isPlaying = false
        case .ended:
            let optionsRaw = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsRaw)
            if options.contains(.shouldResume), wantsPlaying, !suspendedForRecording {
                startEngine()
            }
        @unknown default:
            break
        }
    }
}
