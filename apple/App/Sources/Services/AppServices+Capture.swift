import CueStore
import CueText
import Foundation

/// 分享扩展留在共享容器里的内容入库：主 App 是资料库唯一写者。
extension AppServices {
    /// 失败的条目保留（下次再试）并报告。
    /// 同一时刻只有一趟在跑：跑的时候再来的记成再扫一遍，并等这趟扫完。
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
        let shared = DarwinNotifications.notifications(named: CaptureQueue.notification)  // 先订再扫：扫的途中分享进来的，通知不漏
        follow {
            await self.drainCaptures()
            for await _ in shared {
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
        _ = try await store.createCard(
            in: capture.project, body: sections.joined(separator: "\n\n"), capture: entry.id, ifProjectMissing: .useDefault)
    }
}
