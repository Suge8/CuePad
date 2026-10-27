import CueStore
import CueText
import Foundation

/// 分享扩展留在共享容器里的内容入库：主 App 是资料库唯一写者。
extension AppServices {
    /// 把 `Capture/` 里已写完的条目存成卡片并删除条目。失败的条目保留（下次再试）并报告。
    func drainCaptures() async {
        for entry in CaptureQueue.pending(in: location.captureDirectory) {
            do {
                try await importCapture(entry)
                try CaptureQueue.remove(entry)
            } catch {
                reportIssue(.captureImportFailed("\(error)"))
            }
        }
    }

    func startCaptureIngest() {
        follow {
            await self.drainCaptures()
            for await _ in DarwinNotifications.notifications(named: CaptureQueue.notification) {
                await self.drainCaptures()
            }
        }
    }

    private func importCapture(_ entry: CaptureQueue.Entry) async throws {
        var hashes: [String] = []
        for url in entry.imageURLs() {
            hashes.append(try store.files.store(fileAt: url))
        }
        let capture = entry.capture
        let sections = [
            capture.text ?? "",
            capture.urls.map(\.absoluteString).joined(separator: "\n"),
            hashes.map { CueFormat.imageMarkup(key: $0) }.joined(separator: "\n"),
        ].filter { !$0.isEmpty }
        let project = try await existingProject(capture.project)
        _ = try await store.createCard(in: project, body: sections.joined(separator: "\n\n"))
    }

    /// 选的项目此后已被删除（卡片放进已删除的项目会不可见）的，进默认项目。
    private func existingProject(_ id: UUID) async throws -> UUID {
        guard let project = try await store.project(id), project.deletedAt == nil else { return Project.defaultID }
        return id
    }
}
