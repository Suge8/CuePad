import CueStore
import CueText
import Foundation

final class CaptureIngest {
    private let store: CueStore
    private let directory: URL
    private let report: @MainActor (AppServices.StartupIssue) -> Void
    private var drain: Task<Void, Never>?
    private var drainAgain = false

    init(store: CueStore, directory: URL, report: @escaping @MainActor (AppServices.StartupIssue) -> Void) {
        self.store = store
        self.directory = directory
        self.report = report
    }

    func drainCaptures() async {
        if let running = drain {
            drainAgain = true
            return await running.value
        }
        let running = Task {
            repeat {
                drainAgain = false
                await importPendingCaptures()
            } while drainAgain
            drain = nil
        }
        drain = running
        await running.value
    }

    private func importPendingCaptures() async {
        let (entries, unreadable) = CaptureQueue.pending(in: directory)
        for reason in unreadable { report(.captureUnreadable(reason)) }
        for entry in entries {
            do {
                try await importCapture(entry)
                try CaptureQueue.remove(entry)
                try await store.finishCapture(entry.id)
            } catch {
                report(.captureImportFailed("\(error)"))
            }
        }
    }

    private func importCapture(_ entry: CaptureQueue.Entry) async throws {
        let files = try entry.files().map { CueFormat.markup(key: try store.files.store(fileAt: $0.url), name: $0.name) }
        let capture = entry.capture
        let sections = [
            capture.text ?? "",
            capture.urls.map(\.absoluteString).joined(separator: "\n"),
            files.joined(separator: "\n"),
        ].filter { !$0.isEmpty }
        _ = try await store.createCard(
            in: capture.project, body: sections.joined(separator: "\n\n"), capture: entry.id, ifProjectMissing: .useDefault)
    }
}
