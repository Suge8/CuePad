#if os(macOS)
import CuePi
import CueStore
import Foundation
import Observation
import SwiftUI

/// 一个窗口的界面状态：选中的页、打开的卡、浮层、发送目标、提示。数据本身不在这里，界面直接订阅 Store。
/// 当前项目的唯一事实源是 `AppSettings.currentProject`；这里只记"未归档"和"回收站"这两个非项目页。
@MainActor @Observable
final class Workspace {
    enum Page: Hashable {
        case project(UUID)
        case inbox
        case trash
    }

    enum Overlay: Equatable {
        case search
        case tasks
    }

    struct Notice: Identifiable, Equatable {
        let id = UUID()
        var text: String
        var isError: Bool
    }

    /// Pi 会话正忙时待用户选择插话或排队的一次发送。
    struct BusySend {
        var text: String
        var session: CuePi.PiSession.ID
        var card: UUID?
        var task: UUID?
    }

    let services: AppServices
    var sidebar: NavigationSplitViewVisibility = .all
    var nonProjectPage: Page?
    var openCard: UUID?
    var overlay: Overlay?
    var notice: Notice?
    var busySend: BusySend?
    /// 用户在本窗口选过的发送目标；nil 或已失效时用默认目标。
    var sendChoice: SendChoice?
    /// 本机项目目录绑定（Pi 会话据此归项目）；由根视图订阅 Store 更新。
    var directories: [UUID: String]?

    @ObservationIgnored private var noticeTask: Task<Void, Never>?

    init(services: AppServices) {
        self.services = services
    }

    var page: Page {
        if let nonProjectPage { return nonProjectPage }
        return services.settings.currentProject.map(Page.project) ?? .inbox
    }

    /// 当前项目（未归档为 nil）。回收站页没有项目。
    var currentProject: UUID? {
        if case .project(let id) = page { id } else { nil }
    }

    func show(_ page: Page) {
        openCard = nil
        switch page {
        case .project(let id):
            nonProjectPage = nil
            services.settings.currentProject = id
        case .inbox, .trash:
            nonProjectPage = page
        }
    }

    func toggle(_ overlay: Overlay) {
        self.overlay = self.overlay == overlay ? nil : overlay
    }

    func toggleSidebar() {
        sidebar = sidebar == .detailOnly ? .all : .detailOnly
    }

    // MARK: 提示

    private static let noticeDuration: Duration = .seconds(2.4)

    func say(_ text: String, isError: Bool = false) {
        let notice = Notice(text: text, isError: isError)
        self.notice = notice
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: Self.noticeDuration)
            if self?.notice == notice { self?.notice = nil }
        }
    }

    func fail(_ error: any Error) {
        say(ErrorText.describe(error), isError: true)
    }

    // MARK: 当前项目与新建位置

    /// 保存的当前项目以 Store 为准：不存在或已进回收站时回落到侧栏第一个有效项目，没有项目则到未归档，并纠正设置。
    /// 根视图在项目表每次变化后调用。
    func reconcileCurrentProject() async {
        guard let saved = services.settings.currentProject else { return }
        do {
            let projects = try await services.store.projects()
            guard !projects.contains(where: { $0.id == saved }) else { return }
            let summaries = try await services.store.projectSummaries()
            let fallback = SidebarOrder.projects(projects, summaries: summaries).first?.id
            if services.settings.currentProject == saved { services.settings.currentProject = fallback }
        } catch {
            fail(error)
        }
    }

    /// 新建卡片。目标项目在写入前核对：不存在或在回收站时落到未归档，卡片不会写进看不见的地方。
    func createCard(body: String = "", in project: UUID?) async throws -> Card {
        try await services.store.createCard(in: liveProject(project), body: body)
    }

    /// 新建任务；目标项目失效时归为全局。
    func createTask(_ content: String, in project: UUID?) async throws -> CueTask {
        try await services.store.createTask(content, in: liveProject(project))
    }

    private func liveProject(_ id: UUID?) async throws -> UUID? {
        guard let id, let project = try await services.store.project(id), project.deletedAt == nil else { return nil }
        return id
    }

    /// 执行一个异步操作，失败时提示。
    func attempt(_ work: @escaping @MainActor () async throws -> Void) {
        Task {
            do { try await work() } catch { fail(error) }
        }
    }

    /// 执行一个 Store 写操作，失败时提示。
    func perform(_ work: @escaping @Sendable (CueStore) async throws -> Void) {
        let store = services.store
        Task {
            do { try await work(store) } catch { fail(error) }
        }
    }
}
#endif
