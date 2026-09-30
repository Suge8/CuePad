import CueStore
import CueText
import Foundation

/// 分享扩展留在共享容器里的内容入库：主 App 是资料库唯一写者。
extension AppServices {
    /// 把 `Capture/` 里已写完的条目存成卡片并删除条目。失败的条目保留（下次再试）并报告。
    func drainCaptures() async {
        for entry in CaptureInbox.pending(in: location.captureDirectory) {
            do {
                try await importCapture(entry)
                try CaptureInbox.remove(entry)
            } catch {
                reportIssue(.captureImportFailed("\(error)"))
            }
        }
    }

    /// 收到扩展的通知就入库，直到任务取消。
    func startCaptureIngest() {
        tasks.append(Task {
            await drainCaptures()
            for await _ in DarwinNotifications.notifications(named: CaptureInbox.notification) {
                await drainCaptures()
            }
        })
    }

    private func importCapture(_ entry: CaptureInbox.Entry) async throws {
        var hashes: [String] = []
        for url in entry.imageURLs() {
            hashes.append(try store.files.store(fileAt: url))
        }
        let capture = entry.capture
        let sections = [
            capture.text ?? "",
            capture.urls.map(\.absoluteString).joined(separator: "\n"),
            hashes.map { CueFormat.imageMarkup(id: $0) }.joined(separator: "\n"),
        ].filter { !$0.isEmpty }
        let project = try await existingProject(capture.project)
        try await store.createCard(in: project, body: sections.joined(separator: "\n\n"))
    }

    /// 分享时选的项目此后可能已被删除；卡片放进已删除的项目会不可见，回到收件箱。
    private func existingProject(_ id: UUID?) async throws -> UUID? {
        guard let id else { return nil }
        guard let project = try await store.project(id), project.deletedAt == nil else { return nil }
        return id
    }
}
