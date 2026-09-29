import Foundation
import MetricKit

extension Notification.Name {
    static let sabbouraCrashReportsChanged = Notification.Name("sabbouraCrashReportsChanged")
}

/// يلتقط تقارير الأعطال (استثناءات Objective-C + تقارير MetricKit من النظام)
/// ويحفظها في مجلد Documents/CrashReports الظاهر في تطبيق الملفات،
/// ثم يعرض التطبيق خيار مشاركتها في التشغيل التالي.
final class CrashReporter: NSObject, MXMetricManagerSubscriber {
    static let shared = CrashReporter()

    static var folder: URL {
        URL.documentsDirectory.appending(path: "CrashReports", directoryHint: .isDirectory)
    }

    private static var seenFolder: URL {
        folder.appending(path: "Seen", directoryHint: .isDirectory)
    }

    static func install() {
        try? FileManager.default.createDirectory(at: seenFolder, withIntermediateDirectories: true)
        NSSetUncaughtExceptionHandler { exception in
            let text = [
                "Sabboura — Objective-C exception",
                "Date: \(Date())",
                "Name: \(exception.name.rawValue)",
                "Reason: \(exception.reason ?? "-")",
                "",
                exception.callStackSymbols.joined(separator: "\n")
            ].joined(separator: "\n")
            let url = CrashReporter.folder.appending(path: "exception-\(Int(Date().timeIntervalSince1970)).txt")
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
        MXMetricManager.shared.add(shared)
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads where !(payload.crashDiagnostics ?? []).isEmpty {
            let name = "diagnostic-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(6)).json"
            try? payload.jsonRepresentation().write(to: Self.folder.appending(path: name))
        }
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .sabbouraCrashReportsChanged, object: nil)
        }
    }

    /// تقارير لم يطّلع عليها المستخدم بعد.
    static func pendingReports() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { !$0.hasDirectoryPath }.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    static func markAllSeen() {
        for url in pendingReports() {
            let destination = seenFolder.appending(path: url.lastPathComponent)
            try? FileManager.default.removeItem(at: destination)
            try? FileManager.default.moveItem(at: url, to: destination)
        }
        NotificationCenter.default.post(name: .sabbouraCrashReportsChanged, object: nil)
    }
}
