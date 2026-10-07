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
        /// 点提示去哪（如随手记的落点）；nil 时提示只是告知。
        var link: Link?
        /// 提示里的"撤销"：把刚才那一下拨回去（如"要做"开关）。
        var undo: Undo?
    }

    struct Undo: Equatable {
        let id = UUID()
        let run: @MainActor () async throws -> Void
        static func == (lhs: Undo, rhs: Undo) -> Bool { lhs.id == rhs.id }
    }

    /// 提示能带去的地方：项目页（nil 是未归档）。
    enum Link: Equatable {
        case project(UUID?)
    }

    #if os(macOS)
    /// Pi 会话正忙时待用户选择马上说或等它做完再说的一次发送。
    struct BusySend {
        var text: String
        var session: CuePi.PiSession.ID
        var card: UUID?
    }
    #endif

    let services: AppServices
    /// 本窗口的项目目录；nil 表示还没读到或读取失败，根视图在读到之前不显示页面。
    private(set) var catalog: ProjectCatalog?
    /// 资料库读得出来（项目目录已读到）。没读到或读取失败时，凡是会写资料库的入口都不出现或不可用。
    var isLibraryReady: Bool { catalog != nil }
    /// 项目目录读取失败的原因；根视图据此显示错误与"重试"，不停在空白页上。
    private(set) var catalogFailure: String?
    /// 第几次订阅项目目录：根视图以它为 `.task` 的 id，`retryCatalog` 加一即重新订阅。
    private(set) var catalogAttempt = 0
    var sidebar: NavigationSplitViewVisibility = .all
    var nonProjectPage: Page?
    /// 打开的卡（编辑纸页）。设成某张卡时纸页立即挂上；清空时纸页先缩回原卡片，缩完才卸下（见 `presentedCard`）。
    var openCard: UUID? {
        didSet { if let openCard { present(openCard) } }
    }
    /// 纸页挂在屏上的卡：比 `openCard` 晚一步清空，缩回卡片的动画期间仍在。
    private(set) var presentedCard: UUID?
    /// 各张卡在纸页开合中的状态，按卡分开（见 `CardPresence`）。
    @ObservationIgnored private var presences: [UUID: CardPresence] = [:]
    var overlay: Overlay?
    var notice: Notice?
    #if os(macOS)
    /// 鼠标停在哪张卡上、正按着哪张卡（卡片报上来的悬停与 AppKit 的鼠标事件，见 `mouse(down:)`）。不触发界面刷新。
    @ObservationIgnored private var hoveredCard: UUID?
    @ObservationIgnored private var pressedCard: UUID?
    private static let releaseGrace: Duration = .milliseconds(80)
    var busySend: BusySend?
    /// 用户在本窗口选过的发送目标；nil 或已失效时用默认目标。
    var sendChoice: AppServices.Destination?
    /// Pi 会话（会话 id，含本次运行里已结束的）各自归属的项目，由 Store 按工作目录判定（`project(containing:)`）；
    /// 会话或目录绑定变化时由根视图调用 `refreshSessionProjects` 重算。
    private(set) var sessionProjects: [String: UUID] = [:]
    /// 本机在线会话的摘要（Pi 自己的会话 id → 同步记录上的问与答）：桥上没有，界面把它配到桥上的实时状态上。
    /// 由 `observeSessionRecaps` 跟随同步记录。
    private(set) var sessionRecaps: [String: PiRecap] = [:]
    /// 发给在线会话的最近一条投送请求（Pi 的会话 id →），同一次观察带来：Mac 上配到桥的实时状态上算显示状态（`PiDelivery`）。
    private(set) var sessionDeliveries: [String: DeliveryRequest] = [:]
    /// 本次运行里已结束的会话（会话 id），按本窗口看到它们结束的先后。可观察：默认发送目标取最后结束的那个。
    private(set) var endedOrder: [String] = []

    /// 鼠标进出一张卡。拖出卡片也就不再按着它（与按钮拖出即松开一致）。
    func hover(_ card: UUID, inside: Bool) {
        if inside {
            hoveredCard = card
        } else {
            if hoveredCard == card { hoveredCard = nil }
            if pressedCard == card { release() }
        }
    }

    /// AppKit 分发鼠标按下、松开时调用（本地事件监听，早于 SwiftUI 按钮识别按下）：按下时鼠标停着的那张卡在这一轮就显出按下，
    /// 点下的第一帧就有反馈。
    func mouse(down: Bool) {
        guard down else {
            // 松开到"打开中"接上之间隔着一两次更新：这时就放开，卡片会先弹一下再按回去（两段动画叠加还会压得更小）。
            // 稍等再放开；打开了就由"打开中"接着按住，没打开（取消）这时才回弹
            let card = pressedCard
            Task {
                try? await Task.sleep(for: Self.releaseGrace)
                if pressedCard == card { release() }
            }
            return
        }
        guard let card = hoveredCard else { return }
        pressedCard = card
        presence(of: card).pressing = true
    }

    private func release() {
        if let card = pressedCard { presence(of: card).pressing = false }
        pressedCard = nil
    }

    /// 跟随同步记录里在线会话的摘要与发给它们的最近一条投送请求，直到任务取消。
    func observeSessionRecaps() async {
        do {
            for try await items in services.store.observe([.piSessionStates, .deliveryRequests], { try $0.piSessionPage(.live).items }) {
                let recaps = Dictionary(items.map { ($0.state.sessionID, $0.state.recap) }) { first, _ in first }
                let deliveries = Dictionary(items.compactMap { item in item.delivery.map { (item.state.sessionID, $0) } }) { first, _ in first }
                if recaps != sessionRecaps { sessionRecaps = recaps }
                if deliveries != sessionDeliveries { sessionDeliveries = deliveries }
            }
        } catch is CancellationError {
        } catch {
            fail(error)
        }
    }

    /// 重算活着的会话各归哪个项目。
    func refreshSessionProjects() async {
        // 会话变化时都会来到这里：顺带记下结束的先后（桥只给出结束了哪些），默认发送目标取最后结束的那个
        for id in services.pi.endedSessions.keys where !endedOrder.contains(id) { endedOrder.append(id) }
        var result: [String: UUID] = [:]
        // 已结束的会话也算：默认发送目标要认出"本项目刚结束的会话"（见 effectiveChoice）
        for session in services.pi.sessions + services.pi.endedSessions.values {
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
        guard openCard == nil else { return }
        dismissPresented()
    }

    /// 纸接过原卡片、开始放大。
    func cover(_ card: UUID) {
        presence(of: card).phase = .covered
    }

    /// 纸页缩回到原卡片、自己隐去的同一帧：原卡片回来（纸页稍后才卸下）。
    func uncover(_ card: UUID) {
        presence(of: card).phase = .returned
    }

    /// 这张卡在纸页开合中的状态；卡片视图只观察自己的那一个。
    func presence(of card: UUID) -> CardPresence {
        if let presence = presences[card] { return presence }
        let presence = CardPresence()
        presences[card] = presence
        return presence
    }

    private func present(_ card: UUID) {
        guard presentedCard != card else { return }
        dismissPresented()
        presentedCard = card
        presence(of: card).phase = .opening
    }

    private func dismissPresented() {
        if let card = presentedCard { presence(of: card).reset() }
        presentedCard = nil
    }

    func show(_ page: Page) {
        openCard = nil
        dismissPresented()
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

    func say(_ text: String, isError: Bool = false, link: Link? = nil, undo: (@MainActor () async throws -> Void)? = nil) {
        let notice = Notice(text: text, isError: isError, link: link, undo: undo.map(Undo.init(run:)))
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
            #if DEBUG
            try DebugScene.injectCatalogFailure(attempt: catalogAttempt)
            #endif
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

    /// 保存的当前项目以 Store 为准：不存在或已进回收站时回落到第一个有效项目（`store.projects()` 的顺序），没有项目则到未归档，并纠正设置。
    /// 根视图在项目表每次变化后调用。
    func reconcileCurrentProject() async {
        guard let saved = holder.currentProject else { return }
        do {
            let projects = try await services.store.projects()
            guard !projects.contains(where: { $0.id == saved }) else { return }
            if holder.currentProject == saved { holder.currentProject = projects.first?.id }
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

    /// 新建任务；项目失效时同样回落，任务归为未归档并提示。
    func createTask(_ body: String, in project: UUID?) async throws -> Card {
        let store = services.store
        return try await fallingBack(from: project) { try await store.createTask(body, in: $0) }
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

    /// 点任务的圆圈：待办与进行中都变完成，完成的回到待办。下一个状态按 Store 的当前值决定，不看界面手里的副本：
    /// 副本可能已过时（列表还没刷新就又点了一次），按它推算会把已勾的再勾一次。
    func toggle(_ task: Card) async throws {
        let store = services.store
        let current = try await store.card(task.id)?.status
        try await store.setStatus(task.id, current == .done ? .todo : .done)
    }

    /// 挪动卡片（拖放、缩进、反缩进、挂成素材）；下级随它走。
    func move(_ id: UUID, _ move: TaskMove) {
        perform { try await $0.moveCard(id, to: move.slot, after: move.after) }
    }

    /// 开始做（待办 → 进行中）；`back` 为 true 时停下回到待办。
    func start(_ task: Card, back: Bool = false) async throws {
        try await services.store.setStatus(task.id, back ? .todo : .inProgress)
    }

    /// "要做"开关：灵感成为任务，或任务回到灵感（下级提到它的位置）。提示里带"撤销"，点了就拨回去。
    func setTodo(_ id: UUID, _ on: Bool) async throws {
        let store = services.store
        try await store.setTodo(id, on)
        say(on ? "已设为任务" : "已回到灵感", undo: { try await store.setTodo(id, !on) })
    }

    /// 界面上的"要做"开关：失败时提示。
    func toggleTodo(_ id: UUID, _ on: Bool) {
        attempt { try await self.setTodo(id, on) }
    }

    /// 点提示里的"撤销"：收起提示，把刚才那一下拨回去。
    func undo(_ undo: Undo) {
        notice = nil
        attempt { try await undo.run() }
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

/// 一张卡在纸页开合中的状态。按卡分开、各自可观察：开合时只有被打开的那张卡的视图重算，
/// 墙上其余卡片与"更早"各行不受牵动（大项目里有上千张）。
@MainActor @Observable
final class CardPresence {
    enum Phase {
        /// 没有打开。
        case idle
        /// 刚点开、纸页还在准备：原卡片保持按下的样子，纸从这个样子起飞。
        case opening
        /// 纸接过了原卡片（同一帧纸以原卡片按下的样子出现在它的位置上）：原卡片隐去，开合全程屏幕上只有一份这张卡的字。
        case covered
        /// 纸缩回原卡片、自己隐去：原卡片回来（不再按下），纸页下一帧卸下。
        case returned
    }

    fileprivate(set) var phase = Phase.idle
    /// 鼠标正按着这张卡（Mac，见 `Workspace.mouse(down:)`）。
    fileprivate(set) var pressing = false
    /// 卡在屏幕上的位置（全局坐标），纸页从这里放大、缩回到这里；只在跟踪期间更新，不触发界面刷新。
    @ObservationIgnored var frame: CGRect?

    /// 纸页挂着期间才跟踪这张卡的位置：时时跟踪的话，滚动时每一帧都要为每张卡换算一次位置。
    var isTracked: Bool { phase != .idle }
    var covered: Bool { phase == .covered }
    /// 原卡片显出按下的样子（见 `CardOpenStyle`）：鼠标按着，或已打开、纸页还在准备。
    var held: Bool { pressing || phase == .opening }

    fileprivate func reset() {
        phase = .idle
        frame = nil
    }
}
