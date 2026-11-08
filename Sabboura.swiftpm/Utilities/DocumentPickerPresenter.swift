import UIKit
import UniformTypeIdentifiers

/// يفتح نافذة اختيار الملفات الرسمية (تطبيق الملفات) من أعلى شاشة ظاهرة.
///
/// بديل عن `.fileImporter` في SwiftUI: عند وجود أكثر من `.fileImporter` في نفس التسلسل
/// (قائمة المذكرات ← المحرر ← المرفقات) تتعارض فيما بينها، فتظهر نافذة الاختيار لكن
/// الضغط على الملف لا يحدده ولا يفتحه. هنا كل طلب له نافذته ومستلمه الخاص فلا يتعارض شيء.
final class DocumentPickerPresenter: NSObject, UIDocumentPickerDelegate {
    /// الطلب الجاري (نحتفظ به حتى يرد المستخدم لأن مندوب النافذة مرجع ضعيف)
    private static var active: DocumentPickerPresenter?

    private let types: [UTType]
    private let allowsMultiple: Bool
    private let completion: (Result<[URL], Error>) -> Void
    private var finished = false

    private init(types: [UTType], allowsMultiple: Bool, completion: @escaping (Result<[URL], Error>) -> Void) {
        self.types = types
        self.allowsMultiple = allowsMultiple
        self.completion = completion
    }

    /// يعرض نافذة الاختيار. عند الإلغاء تُعاد قائمة فارغة.
    static func present(types: [UTType], allowsMultiple: Bool,
                        completion: @escaping (Result<[URL], Error>) -> Void) {
        let request = DocumentPickerPresenter(types: types, allowsMultiple: allowsMultiple, completion: completion)
        active = request
        DispatchQueue.main.async {
            request.attemptPresentation(remaining: 12)
        }
    }

    /// ننتظر انتهاء أي حركة عرض أو إخفاء (قائمة أو نافذة تُغلق) قبل فتح نافذة الملفات.
    private func attemptPresentation(remaining: Int) {
        guard let top = SharePresenter.topViewController() else {
            finish(.success([]))
            return
        }
        let busy = top.isBeingPresented || top.isBeingDismissed || top.transitionCoordinator != nil
        if busy && remaining > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [self] in
                attemptPresentation(remaining: remaining - 1)
            }
            return
        }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types.isEmpty ? [.item] : types,
                                                    asCopy: true)
        picker.allowsMultipleSelection = allowsMultiple
        picker.shouldShowFileExtensions = true
        picker.delegate = self
        top.present(picker, animated: true)
    }

    private func finish(_ result: Result<[URL], Error>) {
        guard !finished else { return }
        finished = true
        completion(result)
        if Self.active === self {
            Self.active = nil
        }
    }

    // MARK: UIDocumentPickerDelegate

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        finish(.success(urls))
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        finish(.success([]))
    }
}
