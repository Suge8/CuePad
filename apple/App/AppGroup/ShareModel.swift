import CueStore
import Foundation
import Observation

/// 界面（`ShareViews`）只画它。
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
    /// 主 App 写的项目列表；缺快照时为 nil，仍可存进默认项目。
    let projects: [ProjectsSnapshot.Entry]?
    var selectedProject = Project.defaultID

    private let providers: [NSItemProvider]
    private let location: LibraryLocation

    init(providers: [NSItemProvider], location: LibraryLocation) {
        self.providers = providers
        self.location = location
        projects = Snapshots.read(ProjectsSnapshot.self, from: location.snapshotsDirectory)?.projects
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
            try CaptureQueue.enqueue(content, project: selectedProject, into: location.captureDirectory)
            DarwinNotifications.post(CaptureQueue.notification)
            return true
        } catch {
            state = .failed(error.localizedDescription)
            return false
        }
    }
}
