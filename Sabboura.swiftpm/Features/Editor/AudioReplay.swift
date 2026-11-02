import AVFoundation
import Combine
import Foundation

// MARK: - ربط التسجيل الصوتي بالكتابة

/// تسجيل صوتي في المذكرة مع وقت بدايته ونهايته.
/// كل خط يُكتب يحفظ وقت كتابته (PencilKit)، فنعرف أي جزء من التسجيل كان يُقال وقتها.
struct TimedRecording: Identifiable, Equatable {
    let id: UUID
    let name: String
    let data: Data
    let start: Date
    let duration: TimeInterval

    var end: Date { start.addingTimeInterval(duration) }

    func contains(_ date: Date) -> Bool {
        date >= start.addingTimeInterval(-1) && date <= end.addingTimeInterval(1)
    }

    /// تسجيلات المذكرة. التسجيل يُحفظ كمرفق لحظة إيقافه، فبدايته = وقت الحفظ − مدته.
    static func all(in note: CDNote) -> [TimedRecording] {
        note.sortedAttachments.compactMap { attachment -> TimedRecording? in
            guard attachment.isAlive, AudioReplayController.isAudio(attachment),
                  let data = attachment.data, let saved = attachment.createdAt,
                  let player = try? AVAudioPlayer(data: data), player.duration > 0.5 else { return nil }
            return TimedRecording(id: attachment.uuid ?? UUID(),
                                  name: (attachment.fileName ?? "تسجيل").replacingOccurrences(of: ".m4a", with: ""),
                                  data: data,
                                  start: saved.addingTimeInterval(-player.duration),
                                  duration: player.duration)
        }
        .sorted { $0.start < $1.start }
    }
}

/// وضع الاستماع: اضغط على أي كلمة كتبتها أثناء التسجيل ويشتغل الصوت من لحظة كتابتها.
final class AudioReplayController: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var recordings: [TimedRecording]
    @Published private(set) var current: TimedRecording?
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: TimeInterval = 0

    private var player: AVAudioPlayer?
    private var timer: AnyCancellable?

    /// يُبلَّغ بوقت التشغيل الحالي (كتاريخ مطلق) لتظليل الكتابة التي قيلت حتى الآن
    var onTimeChanged: ((Date?) -> Void)?

    init(recordings: [TimedRecording]) {
        self.recordings = recordings
        super.init()
    }

    static func isAudio(_ attachment: CDAttachment) -> Bool {
        let type = (attachment.typeIdentifier ?? "").lowercased()
        let name = (attachment.fileName ?? "").lowercased()
        return type.contains("audio") || name.hasSuffix(".m4a") || name.hasSuffix(".mp3") || name.hasSuffix(".wav")
    }

    var duration: TimeInterval { current?.duration ?? 0 }

    /// الوقت المطلق الذي يُشغَّل الآن
    var playheadDate: Date? {
        guard let current else { return nil }
        return current.start.addingTimeInterval(currentTime)
    }

    // MARK: التشغيل

    /// يشغّل التسجيل الذي كان يعمل وقت كتابة هذا الخط. يرجع false إن لم يكن هناك تسجيل وقتها.
    @discardableResult
    func play(at date: Date) -> Bool {
        guard let recording = recordings.first(where: { $0.contains(date) }) else { return false }
        // نبدأ قبل الكلمة بثانيتين حتى يُسمع سياق الجملة
        let offset = max(0, date.timeIntervalSince(recording.start) - 2)
        play(recording, from: offset)
        return true
    }

    func play(_ recording: TimedRecording, from offset: TimeInterval = 0) {
        if current?.id != recording.id || player == nil {
            stopPlayer()
            do {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playback, mode: .spokenAudio)
                try session.setActive(true)
                let player = try AVAudioPlayer(data: recording.data)
                player.delegate = self
                player.prepareToPlay()
                self.player = player
                current = recording
            } catch {
                return
            }
        }
        guard let player else { return }
        player.currentTime = min(max(0, offset), max(0, player.duration - 0.1))
        player.play()
        isPlaying = true
        startTimer()
        tick()
    }

    func togglePlay() {
        guard let player else {
            if let first = recordings.first { play(first) }
            return
        }
        if player.isPlaying {
            player.pause()
            isPlaying = false
            timer = nil
        } else {
            player.play()
            isPlaying = true
            startTimer()
        }
    }

    func seek(to time: TimeInterval) {
        guard let player else { return }
        player.currentTime = min(max(0, time), player.duration)
        tick()
    }

    func skip(_ seconds: TimeInterval) {
        guard let player else { return }
        seek(to: player.currentTime + seconds)
    }

    func stop() {
        stopPlayer()
        current = nil
        onTimeChanged?(nil)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func stopPlayer() {
        player?.stop()
        player = nil
        isPlaying = false
        timer = nil
        currentTime = 0
    }

    private func startTimer() {
        timer = Timer.publish(every: 0.2, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.tick() }
    }

    private func tick() {
        currentTime = player?.currentTime ?? 0
        onTimeChanged?(playheadDate)
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async {
            self.isPlaying = false
            self.timer = nil
            self.currentTime = player.duration
            self.onTimeChanged?(nil)
        }
    }
}

extension TimeInterval {
    /// 1:05
    var clockText: String {
        let seconds = Int(self.rounded(.down))
        return "\(seconds / 60):\(String(format: "%02d", seconds % 60))"
    }
}
