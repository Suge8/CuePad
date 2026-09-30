#if os(macOS)
import CuePi
#endif
import CueStore
import Foundation
import Observation
import SwiftUI

/// 一个窗口（场景）的界面状态：选中的页、打开的卡、浮层、提示（Mac 另有发送目标）。数据本身不在这里，界面直接订阅 Store。
/// 当前项目的唯一事实源由 `holder` 持有：Mac 是 `AppSettings`（整个 App 一个），iOS 是该窗口的 `SceneContext`
/// （iPad 多窗口各选各的）。这里只记"未归档"和"回收站"这两个非项目页。
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

    #if os(macOS)
    /// Pi 会话正忙时待用户选择插话或排队的一次发送。
    struct BusySend {
        var text: String
        var session: CuePi.PiSession.ID
        var card: UUID?
        var task: UUID?
    }
    #endif

    let services: AppServices
    var sidebar: NavigationSplitViewVisibility = .all
    var nonProjectPage: Page?
    var openCard: UUID?
    var overlay: Overlay?
    var notice: Notice?
    #if os(macOS)
    var busySend: BusySend?
    /// 用户在本窗口选过的发送目标；nil 或已失效时用默认目标。
    var sendChoice: SendChoice?
    /// 本机项目目录绑定（Pi 会话据此归项目）；由根视图订阅 Store 更新。
    var directories: [UUID: String]?
    #endif

    @ObservationIgnored private var noticeTask: Task<Void, Never>?

    @ObservationIgnored private let holder: any CurrentProjectHolder

    init(services: AppServices, holder: (any CurrentProjectHolder)? = nil) {
        self.services = services
        self.holder = holder ?? services.settings
    }

    var page: Page {
        if let nonProjectPage { return nonProjectPage }
        return holder.currentProject.map(Page.project) ?? .inbox
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
            holder.currentProject = id
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
        guard let saved = holder.currentProject else { return }
        do {
            let projects = try await services.store.projects()
            guard !projects.contains(where: { $0.id == saved }) else { return }
            let summaries = try await services.store.projectSummaries()
            let fallback = SidebarOrder.projects(projects, summaries: summaries).first?.id
            if holder.currentProject == saved { holder.currentProject = fallback }
        } catch {
            fail(error)
        }
    }

    /// 新建卡片。项目是否有效由 Store 在写事务里判定：项目已不存在或在回收站（`invalidProject`）时，
    /// 重新核对当前项目，卡片落到未归档并提示，不会写进看不见的地方。
    func createCard(body: String = "", in project: UUID?) async throws -> Card {
        let store = services.store
        return try await fallingBack(from: project) { try await store.createCard(in: $0, body: body) }
    }

    /// 新建任务；项目失效时同样回落，任务归为全局并提示。
    func createTask(_ content: String, in project: UUID?) async throws -> CueTask {
        let store = services.store
        return try await fallingBack(from: project) { try await store.createTask(content, in: $0) }
    }

    private func fallingBack<T>(from project: UUID?, _ write: (UUID?) async throws -> T) async throws -> T {
        do {
            return try await write(project)
        } catch CueStoreError.invalidProject where project != nil {
            await reconcileCurrentProject()
            let result = try await write(nil)
            say("原项目已不存在或在回收站，已放到未归档", isError: true)
            return result
        }
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

/// 当前项目的持有者。
@MainActor
protocol CurrentProjectHolder: AnyObject {
    var currentProject: UUID? { get set }
}

extension AppSettings: CurrentProjectHolder {}

#if os(iOS)
extension SceneContext: CurrentProjectHolder {}
#endif
