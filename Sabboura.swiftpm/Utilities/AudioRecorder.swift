import AVFoundation
import Foundation

/// تسجيل صوتي بسيط (m4a) يُحفظ كمرفق في المذكرة.
final class AudioRecorder: NSObject, AVAudioRecorderDelegate {
    private var recorder: AVAudioRecorder?
    private(set) var startDate: Date?

    var isRecording: Bool { recorder?.isRecording ?? false }

    /// يطلب الإذن ثم يبدأ التسجيل. يعيد false إن رُفض الإذن أو فشل البدء.
    func start(completion: @escaping (Bool) -> Void) {
        AVAudioApplication.requestRecordPermission { granted in
            DispatchQueue.main.async {
                guard granted else {
                    completion(false)
                    return
                }
                completion(self.beginRecording())
            }
        }
    }

    private func beginRecording() -> Bool {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true)
            let url = TemporaryFiles.directory("Recordings").appending(path: "rec-\(UUID().uuidString).m4a")
            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
            ]
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.delegate = self
            guard recorder.record() else { return false }
            self.recorder = recorder
            startDate = Date()
            return true
        } catch {
            print("⚠️ Recording failed: \(error)")
            return false
        }
    }

    /// يوقف التسجيل ويعيد رابط الملف ومدته.
    func stop() -> (url: URL, duration: TimeInterval)? {
        guard let recorder else { return nil }
        let duration = recorder.currentTime
        recorder.stop()
        self.recorder = nil
        startDate = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        return (recorder.url, duration)
    }
}
