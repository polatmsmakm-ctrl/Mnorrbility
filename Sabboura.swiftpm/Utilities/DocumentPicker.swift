import UIKit
import UniformTypeIdentifiers

/// منتقي ملفات UIKit مباشر. يعمل حتى عند فتحه من زر أو قائمة، ويُسلّم نسخة من الملف
/// (الملفات على iCloud يُنزّلها النظام قبل الإرجاع).
final class DocumentPickerCoordinator: NSObject, UIDocumentPickerDelegate {
    /// يُبقي المنسّق حيّاً حتى يُغلق المنتقي.
    static var active: DocumentPickerCoordinator?

    private let completion: (Result<[URL], Error>) -> Void

    init(completion: @escaping (Result<[URL], Error>) -> Void) {
        self.completion = completion
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        finish(.success(urls))
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        finish(.success([]))
    }

    private func finish(_ result: Result<[URL], Error>) {
        DocumentPickerCoordinator.active = nil
        completion(result)
    }
}

enum DocumentPicker {
    /// يفتح تطبيق الملفات لاختيار ملف. الإلغاء يعيد قائمة فارغة بدون خطأ.
    static func present(types: [UTType],
                        allowsMultiple: Bool = false,
                        completion: @escaping (Result<[URL], Error>) -> Void) {
        guard let presenter = topViewController() else {
            completion(.failure(CocoaError(.userCancelled)))
            return
        }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
        picker.allowsMultipleSelection = allowsMultiple
        let coordinator = DocumentPickerCoordinator(completion: completion)
        DocumentPickerCoordinator.active = coordinator
        picker.delegate = coordinator
        presenter.present(picker, animated: true)
    }

    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first
        let window = scene?.windows.first(where: { $0.isKeyWindow }) ?? scene?.windows.first
        var top = window?.rootViewController
        while let presented = top?.presentedViewController {
            top = presented
        }
        return top
    }
}
