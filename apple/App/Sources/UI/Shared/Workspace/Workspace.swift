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
    /// 本窗口的项目目录；nil 表示还没读到或读取失败，根视图在读到之前不显示页面。
    private(set) var catalog: ProjectCatalog?
    /// 项目目录读取失败的原因；根视图据此显示错误与"重试"，不停在空白页上。
    private(set) var catalogFailure: String?
    /// 第几次订阅项目目录：根视图以它为 `.task` 的 id，`retryCatalog` 加一即重新订阅。
    private(set) var catalogAttempt = 0
    var sidebar: NavigationSplitViewVisibility = .all
    var nonProjectPage: Page?
    /// 打开的卡（编辑纸页）。设成某张卡时纸页立即挂上；清空时纸页先缩回原卡片，缩完才卸下（见 `presentedCard`）。
    var openCard: UUID? {
        didSet { if let openCard { presentedCard = openCard } }
    }
    /// 纸页挂在屏上的卡：比 `openCard` 晚一步清空，缩回卡片的动画期间仍在。
    private(set) var presentedCard: UUID?
    /// 墙上卡片与"更早"各行在屏幕上的位置：纸页从这里放大、缩回到这里。持续更新，不触发界面刷新。
    @ObservationIgnored var cardFrames: [UUID: CGRect] = [:]
    var overlay: Overlay?
    var notice: Notice?
    #if os(macOS)
    var busySend: BusySend?
    /// 用户在本窗口选过的发送目标；nil 或已失效时用默认目标。
    var sendChoice: AppServices.Destination?
    /// 活着的 Pi 会话（会话 id）各自归属的项目，由 Store 按工作目录判定（`project(containing:)`）；
    /// 会话或目录绑定变化时由根视图调用 `refreshSessionProjects` 重算。
    private(set) var sessionProjects: [String: UUID] = [:]

    /// 重算活着的会话各归哪个项目。
    func refreshSessionProjects() async {
        var result: [String: UUID] = [:]
        for session in services.pi.sessions {
            do {
                if let project = try await services.store.project(containing: session.cwd) { result[session.id] = project.id }
            } catch {
                fail(error)
                return
            }
        }
        sessionProjects = result
    }

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

    /// 纸页缩回动画结束。
    func finishClosingCard() {
        if openCard == nil { presentedCard = nil }
    }

    func show(_ page: Page) {
        openCard = nil
        presentedCard = nil
        switch page {
        case .project(let id):
            nonProjectPage = nil
            holder.currentProject = id
        case .inbox, .trash:
            nonProjectPage = page
        }
    }

    /// 开关浮层。⌘K 搜索每天用很多次，直接出现；任务面板从右侧滑入（短弹簧，减弱动态效果时只淡入淡出由视图决定）。
    func toggle(_ overlay: Overlay) {
        let next = self.overlay == overlay ? nil : overlay
        if overlay == .search || self.overlay == .search {
            self.overlay = next
        } else {
            withAnimation(Motion.snappy) { self.overlay = next }
        }
    }

    func toggleSidebar() {
        withAnimation { sidebar = sidebar == .detailOnly ? .all : .detailOnly }
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
        say(error.localizedDescription, isError: true)
    }

    // MARK: 项目目录、当前项目与新建位置

    /// 订阅项目目录，直到所在任务取消（根视图在 `.task(id: catalogAttempt)` 里调用）；项目增删时核对当前项目。
    /// 读取失败时清空目录并记下原因：资料库读不出来时不能接着显示过时的项目。
    func observeCatalog() async {
        catalogFailure = nil
        do {
            for try await next in services.store.observe(ProjectCatalog.tables, { try ProjectCatalog.read(from: $0) }) {
                guard next != catalog else { continue }
                let membershipChanged = catalog.map { Set($0.projects.map(\.id)) != Set(next.projects.map(\.id)) } ?? true
                catalog = next
                if membershipChanged { await reconcileCurrentProject() }
            }
        } catch is CancellationError {
        } catch {
            catalog = nil
            catalogFailure = error.localizedDescription
        }
    }

    func retryCatalog() {
        catalogAttempt += 1
    }

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

    /// 勾选或取消勾选任务完成。下一个状态在写事务里按 Store 的当前值决定，不看界面手里的副本：
    /// 副本可能已过时（列表还没刷新就又点了一次），按它推算会把已勾的再勾一次。
    func toggle(_ task: CueTask) async throws {
        try await services.store.updateTask(task.id) { $0.completedAt = $0.completedAt == nil ? .now : nil }
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
