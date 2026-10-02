import CoreData
import SwiftUI

/// يدير توليد بطاقات الحفظ والكويز لكل المذكرات: واحدة كل مرة، في الخلفية،
/// وتلقائياً عند تغيّر المذكرة أو استيراد ملف (إن كان التوليد التلقائي مفعّلاً).
@MainActor
final class StudyService: ObservableObject {
    static let shared = StudyService()

    /// المذكرات التي يجري توليد مراجعتها الآن ونص الحالة
    @Published private(set) var working: [NSManagedObjectID: String] = [:]
    /// رسالة لآخر توليد (مثلاً: تعذّر Claude فاستُخدم التوليد على الجهاز)
    @Published private(set) var notices: [NSManagedObjectID: String] = [:]

    private var queue: [NSManagedObjectID] = []
    private var isRunning = false
    private var pendingAuto: [NSManagedObjectID: Task<Void, Never>] = [:]
    private var lastClaudeRun: [NSManagedObjectID: Date] = [:]

    private var context: NSManagedObjectContext { PersistenceController.shared.viewContext }

    func isWorking(on note: CDNote) -> Bool { working[note.objectID] != nil }

    func status(for note: CDNote) -> String? { working[note.objectID] }

    func notice(for note: CDNote) -> String? { notices[note.objectID] }

    /// توليد يطلبه المستخدم (زر «تحديث» أو فتح المراجعة لأول مرة).
    func generate(for note: CDNote) {
        guard note.isAlive else { return }
        enqueue(note.objectID, front: true)
    }

    /// تغيّرت المذكرة (خروج من شاشة الكتابة، استيراد ملف…): نولّد بعد لحظات إن احتاجت.
    func noteDidChange(_ note: CDNote, delay: TimeInterval = 1.5) {
        guard ReviewSettings.autoGenerate, note.isAlive, note.deletedAt == nil else { return }
        let id = note.objectID
        pendingAuto[id]?.cancel()
        pendingAuto[id] = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.pendingAuto[id] = nil
            guard let note = try? self.context.existingObject(with: id) as? CDNote,
                  note.isAlive, note.isStudyStale else { return }
            // لا نكرر Claude على نفس المذكرة أكثر من مرة كل ١٠ دقائق تلقائياً (توفيراً للتكلفة)
            if ReviewSettings.hasClaudeKey, let last = self.lastClaudeRun[id],
               Date().timeIntervalSince(last) < 600, note.studySet != nil {
                return
            }
            self.enqueue(id, front: false)
        }
    }

    /// عند فتح التطبيق: أحدث المذكرات التي تغيّرت ولم تُحدَّث مراجعتها.
    func sweep() {
        guard ReviewSettings.autoGenerate else { return }
        let request = CDNote.liveRequest()
        request.sortDescriptors = [NSSortDescriptor(key: "updatedAt", ascending: false)]
        request.fetchLimit = 8
        let notes = (try? context.fetch(request)) ?? []
        for note in notes where note.isAlive && note.pageCount > 0 && note.isStudyStale {
            enqueue(note.objectID, front: false)
        }
    }

    private func enqueue(_ id: NSManagedObjectID, front: Bool) {
        queue.removeAll { $0 == id }
        if front { queue.insert(id, at: 0) } else { queue.append(id) }
        if working[id] == nil { working[id] = "بانتظار دورها…" }
        runNext()
    }

    private func runNext() {
        guard !isRunning, !queue.isEmpty else { return }
        isRunning = true
        let id = queue.removeFirst()
        Task { @MainActor in
            await self.run(id)
            self.working[id] = nil
            self.isRunning = false
            self.runNext()
        }
    }

    private func run(_ id: NSManagedObjectID) async {
        guard let note = try? context.existingObject(with: id) as? CDNote, note.isAlive,
              let read = NoteContentReader.prepare(note, context: context) else { return }
        let signature = note.contentSignature
        let key = KeychainStore.read(KeychainStore.claudeKey) ?? ""
        let model = ReviewSettings.claudeModel
        var notice: String?
        var result: StudySet

        if !key.isEmpty {
            working[id] = "Claude يقرأ المذكرة…"
            lastClaudeRun[id] = Date()
            let content = await background { read(.textAndImages) }
            do {
                result = try await ClaudeStudyGenerator.generate(from: content, signature: signature, key: key, model: model)
            } catch {
                notice = ((error as? LocalizedError)?.errorDescription ?? "تعذّر Claude") + " — استخدمت التوليد على الجهاز."
                working[id] = "جارٍ قراءة المذكرة على الجهاز…"
                let local = await background { read(.textOnly) }
                result = await background { OnDeviceStudyGenerator.generate(from: local, signature: signature) }
            }
        } else {
            working[id] = "جارٍ قراءة المذكرة…"
            let local = await background { read(.textOnly) }
            working[id] = "جارٍ تجهيز البطاقات والأسئلة…"
            result = await background { OnDeviceStudyGenerator.generate(from: local, signature: signature) }
        }

        guard note.isAlive else { return }
        // نحتفظ بأفضل نتيجة سابقة إن لم يتغيّر المحتوى
        if let old = note.studySet, old.signature == signature {
            result.bestScore = old.bestScore
        }
        note.studySet = result
        DataStore.save(context)
        notices[id] = notice
    }

    /// يحفظ تقدّم المراجعة (البطاقات المعروفة، نتيجة الكويز).
    func update(_ note: CDNote, _ change: (inout StudySet) -> Void) {
        guard note.isAlive, var set = note.studySet else { return }
        change(&set)
        note.studySet = set
        DataStore.save(context)
    }

    private func background<T>(_ work: @escaping () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: work())
            }
        }
    }
}
