import UIKit
import UIKit.UIGestureRecognizerSubclass

/// يلتقط مساراً حراً (بالقلم أو الإصبع) لاستخدامه في "ممحاة التحديد".
/// يبدأ فوراً عند اللمس دون انتظار حركة، ويستخدم اللمسات المدمجة (coalesced)
/// للحصول على أعلى دقة من قلم أبل.
final class LassoPathGestureRecognizer: UIGestureRecognizer {
    private(set) var points: [CGPoint] = []
    private weak var trackedTouch: UITouch?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        if trackedTouch != nil {
            for touch in touches where touch !== trackedTouch {
                ignore(touch, for: event)
            }
            return
        }
        guard touches.count == 1, let touch = touches.first else {
            state = .failed
            return
        }
        trackedTouch = touch
        points = [touch.location(in: view)]
        state = .began
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = trackedTouch, touches.contains(touch) else { return }
        let samples = event.coalescedTouches(for: touch) ?? [touch]
        for sample in samples {
            points.append(sample.location(in: view))
        }
        state = .changed
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = trackedTouch, touches.contains(touch) else { return }
        points.append(touch.location(in: view))
        state = .ended
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        state = .cancelled
    }

    override func reset() {
        super.reset()
        points = []
        trackedTouch = nil
    }
}

/// يراقب نوع اللمسات دون أن يتدخل فيها: عند أول لمسة من قلم أبل يبلّغ التطبيق
/// ليُفعّل رفض راحة اليد تلقائياً.
final class PencilDetectorGestureRecognizer: UIGestureRecognizer, UIGestureRecognizerDelegate {
    var onPencilTouch: (() -> Void)?

    /// يجعل المراقب شفافاً تماماً: لا يؤخر اللمسات ولا يلغيها.
    func configurePassive() {
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        delegate = self
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        if touches.contains(where: { $0.type == .pencil }) {
            onPencilTouch?()
        }
        state = .failed
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        true
    }
}
