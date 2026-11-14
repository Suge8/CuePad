import CueStore
import CueText
import Foundation

/// 分享扩展留在共享容器里的内容入库：主 App 是资料库唯一写者。
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

    /// 失败的条目保留（下次再试）并报告。
    /// 同一时刻只有一趟在跑：跑的时候再来的记成再扫一遍，并等这趟扫完。
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
        for entry in CaptureQueue.pending(in: directory) {
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
