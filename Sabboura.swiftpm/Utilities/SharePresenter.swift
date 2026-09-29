import UIKit

/// يعرض قائمة المشاركة الرسمية (حفظ في الملفات، AirDrop، البريد...) من أعلى نافذة ظاهرة.
enum SharePresenter {
    static func share(_ items: [Any]) {
        guard !items.isEmpty, let presenter = topViewController() else { return }
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        if let popover = controller.popoverPresentationController {
            popover.sourceView = presenter.view
            let bounds = presenter.view.bounds
            popover.sourceRect = CGRect(x: bounds.midX, y: bounds.minY + 64, width: 1, height: 1)
            popover.permittedArrowDirections = [.up]
        }
        presenter.present(controller, animated: true)
    }

    static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        guard var top = scene?.keyWindow?.rootViewController ?? scene?.windows.first?.rootViewController else {
            return nil
        }
        while let presented = top.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        return top
    }
}
