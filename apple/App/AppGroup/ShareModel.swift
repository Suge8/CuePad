import CueStore
import Foundation
import Observation

/// 分享扩展的状态与动作：读取分享内容、选项目、存进待入库目录。界面（`ShareViews`）只画它。
@MainActor @Observable
final class ShareModel {
    enum State: Equatable {
        case loading
        case ready
        case saving
        case failed(String)
    }

    private(set) var state = State.loading
    private(set) var content: ShareContent?
    /// 可选的项目（主 App 写的快照；从没打开过主 App 则为空，只能存进收件箱）。
    let projects: [ProjectsSnapshot.Project]
    /// nil 是收件箱。
    var selectedProject: UUID?

    private let providers: [NSItemProvider]
    private let location: LibraryLocation

    init(providers: [NSItemProvider], location: LibraryLocation) {
        self.providers = providers
        self.location = location
        projects = Snapshots.readProjects(from: location.snapshotsDirectory)?.projects ?? []
    }

    func load() async {
        do {
            content = try await ShareItemLoader.load(from: providers)
            state = .ready
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// 存进待入库目录并通知主 App；成功返回 true，由调用方关闭扩展。
    func save() async -> Bool {
        guard let content, state == .ready else { return false }
        state = .saving
        do {
            try CaptureInbox.enqueue(content, project: selectedProject, into: location.captureDirectory)
            DarwinNotifications.post(CaptureInbox.notification)
            return true
        } catch {
            state = .failed(error.localizedDescription)
            return false
        }
    }
}
