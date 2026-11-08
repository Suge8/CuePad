import CueStore
import CueText
import Foundation

/// 分享扩展留在共享容器里的内容入库：主 App 是资料库唯一写者。
extension AppServices {
    /// 把 `Capture/` 里已写完的条目存成卡片并删除条目。失败的条目保留（下次再试）并报告。
    /// 同一时刻只有一趟在跑（启动跟随者、Darwin 通知、回到前台都会调）：跑的时候再来的记成再扫一遍，并等这趟扫完。
    func drainCaptures() async {
        if let running = flights.captureDrain {
            flights.captureDrainAgain = true
            return await running.value
        }
        let running = Task {
            repeat {
                flights.captureDrainAgain = false
                await importPendingCaptures()
            } while flights.captureDrainAgain
            flights.captureDrain = nil
        }
        flights.captureDrain = running
        await running.value
    }

    private func importPendingCaptures() async {
        for entry in CaptureQueue.pending(in: location.captureDirectory) {
            do {
                try await importCapture(entry)
                try CaptureQueue.remove(entry)
                try await store.finishCapture(entry.id)
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
        let files = try entry.files().map { CueFormat.markup(key: try store.files.store(fileAt: $0.url), name: $0.name) }
        let capture = entry.capture
        let sections = [
            capture.text ?? "",
            capture.urls.map(\.absoluteString).joined(separator: "\n"),
            files.joined(separator: "\n"),
        ].filter { !$0.isEmpty }
        let project = try await existingProject(capture.project)
        _ = try await store.createCard(in: project, body: sections.joined(separator: "\n\n"), capture: entry.id)  // 已入库过的返回 nil
    }

    /// 选的项目此后已被删除（卡片放进已删除的项目会不可见）的，进默认项目。
    private func existingProject(_ id: UUID) async throws -> UUID {
        guard let project = try await store.project(id), project.deletedAt == nil else { return Project.defaultID }
        return id
    }
}
