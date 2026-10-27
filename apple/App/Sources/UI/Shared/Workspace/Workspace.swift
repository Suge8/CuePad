import CueStore
import Foundation
import Observation
import SwiftUI

/// 一个窗口（场景）的界面状态：去处、项目目录、打开的卡、浮层、提示；Mac 另有挂着的页与发送目标。数据本身不在这里，界面直接订阅 Store。
/// 去处只在这里一份（`root` 与 `path`，规则见 `Workspace+Navigation`）：两端都经 `show`、`open` 去，平台只决定怎么摆（`Layout`）。
@Observable
final class Workspace {
    struct Notice: Identifiable, Equatable {
        let id = UUID()
        var text: Dotted
        var tone: Tone
        /// 会话状态的提示（前台横幅）带的状态图形（`PiStateGlyph`）；nil 时按 `tone` 用默认的。
        var status: PiShown.Status?
        /// 点提示去哪（如随手记的落点）；nil 时提示只是告知。
        var link: Route?
        /// 提示右边的一个动作：多是"撤销"（把刚才那一下拨回去），完成任务后是"归档"。
        var action: NoticeAction?

        /// 出错：字与图标用出错色，手机给出错的触感。
        var isError: Bool { tone == .failure }

        /// 一条提示说的是哪一类事：图标只在这里定（两端的提示同读 `icon`），出错另有颜色与触感。
        enum Tone: Equatable {
            /// 做成了、记下了
            case done
            /// 点了去的那一处已不在（删了、归档了）
            case gone
            case failure

            var icon: Icon {
                switch self {
                case .done: .done
                // 带斜线的圈：那里已经没有它了。不用对勾（对勾只表示完成与记下）
                case .gone: .gone
                case .failure: .failure
                }
            }
        }
    }

    struct NoticeAction: Equatable {
        let id = UUID()
        let title: String
        /// 撤销刚才那一下（Mac 上 ⌘Z 也能点它）。
        var isUndo = false
        let run: Undo
        static func undo(_ run: @escaping Undo) -> Self { Self(title: String(localized: "撤销"), isUndo: true, run: run) }
        static func == (lhs: NoticeAction, rhs: NoticeAction) -> Bool { lhs.id == rhs.id }
    }

    let services: AppServices
    /// 当前去处（Mac 的内容区、iPad 右边那一栏、窄屏选中的 tab）：打开 App 先到 `openingRoute`。经 `select` 换；窄屏点标签栏直接换它（各 tab 的栈留着）。
    var root: Route
    /// 各个根上推入的页（iOS 的卡片纸页、会话页……），按根分开：窄屏每个 tab 一个导航栈，切走再回来还在；宽屏与 Mac 只有当前根的那一份（`select` 换根时清掉）。
    /// Mac 没有历史，总是空的。
    var stacks: [Route: [Route]] = [:]
    /// 当前根上推入的页。
    var path: [Route] {
        get { stacks[root] ?? [] }
        set { stacks[root] = newValue }
    }
    /// 去处怎么摆：Mac 固定是 `.pages`，iOS 随尺寸类在 `.split` 与 `.dock` 之间换（`IOSRoot`）。变窄时把宽屏的去处推到它所属的那一页上。
    var layout = Layout.native {
        didSet {
            guard layout == .dock, oldValue != .dock, let home = root.home, home != root else { return }
            stacks = [home: [root] + path]
            root = home
        }
    }
    /// 新建（`project` 为 nil）或编辑项目的表单：侧栏、书架与项目页的入口都经这里，窗口的根弹出。
    var projectForm: ProjectFormRequest?
    /// 请过"对 Cue 说"拿到焦点（`speakToCue`：随手记小组件、手机的 ⌘⇧N），Cue 页的输入框还没接：它出现时或已在屏上时接下并清掉。
    /// 不用计数：从别的页过来时输入框是新建的，看不到数变过。
    var cueFocusPending = false
    /// Cue 的现状与 Cue 页的草稿（`CueWatch`，`follow` 跟着）。
    let cue: CueWatch
    /// 本窗口的项目目录（建工作区时当场读到，`follow` 接着订阅）；nil 表示读取失败。
    private(set) var catalog: ProjectCatalog?
    /// 资料库读得出来（项目目录读到了）。读取失败时，凡是会写资料库的入口都不出现或不可用。
    var isLibraryReady: Bool { catalog != nil }
    /// 项目目录读取失败的原因；根视图据此显示错误与"重试"。
    private(set) var catalogFailure: String?
    /// 第几次读项目目录：`retryCatalog` 加一并当场重读，`follow` 就从读到的那份重新订阅。
    private(set) var catalogAttempt = 0
    /// 当场读到的那份目录（`catalogFailure` 时为 nil）：订阅从它接着走。
    @ObservationIgnored private var catalogStart: Snapshot<ProjectCatalog>?
    #if os(macOS)
    let pages = MacPages()
    let presses = CardPresses()
    let sendState: SendState
    /// 盖在当前页上的那一页（一次只有一页，开新的就换掉旧的）：换页、"收起"、Esc 时清空；底部输入条、工具栏的"收起"都只看它。
    /// 灵感的编辑页设上时立即挂上，清空时先淡出、淡完才卸下（`CardEditorPage`）；iOS 打开卡片与技能、规则是推入，见 `showEditor`、`openLibrary`。
    var overlay: Overlay? {
        didSet { if case .card(let id)? = overlay { presses.present(id) } }
    }
    enum Overlay: Hashable {
        /// 灵感的编辑页
        case card(UUID)
        /// 技能与规则的文件页
        case library(LibraryFile)
    }
    var openCard: UUID? { if case .card(let id)? = overlay { id } else { nil } }
    var openLibraryFile: LibraryFile? { if case .library(let file)? = overlay { file } else { nil } }
    /// 收起这一页；已换成别的就不动。
    func close(_ page: Overlay) { if overlay == page { overlay = nil } }
    #else
    /// 手机上改着的技能与规则（`fileDraft(_:on:)`），按哪台 Mac 的哪一份分开：离开文件页也留着。
    @ObservationIgnored var fileDrafts: [FileDraftKey: FileDraft] = [:]
    #endif
    /// 气泡里看着的任务（`TaskBubble`）：从被点的那一下长出来，盖在当前页上，不换页。两端同一份，各个入口都经 `openTask(_:)`。
    var openTask: TaskBubble.Request? {
        didSet { if openTask == nil, let oldValue { closedTask = (oldValue.task, .now) } }
    }
    /// 刚收起的气泡是哪件事、什么时候：按在它那一行上收起的（按下就关，松开时那一行又要打开它），这一下不再打开。
    @ObservationIgnored var closedTask: (task: UUID, at: ContinuousClock.Instant)?
    @ObservationIgnored var press = PressPoint()
    #if os(iOS)
    /// 任务行左滑"更多"长出的气泡（`CardMorePanel`）。
    var moreCard: CardMoreRequest?
    #endif
    #if os(macOS)
    /// ⌘K 搜索开着（`SearchPalette`）。
    var searching = false
    /// 接入 Agent 并启用 Cue 的面板（`SetupPanel`；首次打开由 `offerSetup` 置起，Cue 页的启用钮（`CueWelcome`）与会话页的"接入"也打开它，主窗口弹出）。
    var showsSetup = false
    /// 新会话的表单开着（`NewSessionForm`，从会话页的 + 弹出；菜单"文件 › 新会话"先去会话页再置起，`newSession`）。
    var showsNewSession = false
    /// 这台 Mac 上点"开始"没开成会话的叶子与原因（`handOff`）：任务气泡那一行一直写着、给"重试"，再点开始时清掉。
    /// 只记在这台：没开成的开新会话请求过一会儿就清掉（`DeliveryExecutor.retention`），提示条两秒多就收，原因就只剩这里。
    var launchFailures: [UUID: String] = [:]
    /// 进展页待办顶上浮出添加那一行（页上的"新任务"与右上"⋯"里的同一下）。
    var addsTask = false
    /// 清空回收站的确认开着（回收站页上与"⋯"里的"清空回收站…"同一下）。
    var confirmsEmptyTrash = false
    /// 指针此刻停在哪个项目上（侧栏的项目行、看板卡上的项目小图形）：看板上别的项目的卡淡下去（`boardDim`）。侧栏与看板读写这一份。
    var hoveredProject: UUID?
    #else
    /// 这个窗口有系统菜单开着（`MenuButton`）：这段里贴着键盘的那一层不跟键盘走（`KeyboardHold`）。
    var menuOpen = false
    /// 发给 Agent 的输入框（`HandOffInput`，`handOff` 浮起）。
    var outbox: Outbox? {
        didSet { if let outbox, outbox.id != oldValue?.id { handOffDraft = ComposerDraft(attachments: [outbox]) } }
    }
    /// 发给 Agent 输入框的草稿（换了一件任务就重来）：放在这里而不在输入框里，发出即收起后写库失败还能放回、重新浮起。
    var handOffDraft = ComposerDraft()
    /// 新会话的输入框（`NewSessionInput`）。
    var newSession: NewSessionInput.Start?
    var sidebar: NavigationSplitViewVisibility = .automatic
    /// 宽屏：右侧的 Cue 面板是否展开。
    var agentPanel = false
    /// 每次 ⌘K（或点搜索钮、项目页与侧栏顶上的搜索框）加一：搜索页据此聚焦搜索框，已在搜索页时同样生效。
    var searchFocusRequests = 0
    #endif
    /// 项目范围：进展页的看板与会话两段共用这一份（顶栏那颗显示它、点 ✕ 清掉；项目页"⋯"里的"看这个项目的会话"设成这个项目再切到会话段），nil 是全部项目。
    var projectScope: UUID?
    /// 页面按哪个项目筛（进展页的两段）：项目范围里的项目进了回收站就是全部（nil）。
    var scopedProject: UUID? { catalog?.project(projectScope)?.id }
    /// 进展页此刻在哪一段：看板或会话。三端同一份：工具栏的主操作（新任务 / 新会话）与页顶的分段都读它，去会话段经 `showSessions`。
    var progressPane = ProgressPane.board
    /// 技能与规则页此刻在哪一段：规则或技能。两端同一份：Mac 工具栏与手机页顶的分段都读它，去文件页再回来、换页再回来都还在这一段。
    var libraryPane = LibraryPane.rules
    /// Cue 页拍板卡露的是哪一件（`TaskBoard.Wait.id`）：看板上点了一张 Cue 问的卡、在拍板卡上换一件都写这里；不在等了露第一件。
    var cueAsking: String?
    var notice: Notice?
    /// 正在给哪个项目选文件夹（iOS：根视图据此弹候选；Mac 直接弹系统的选文件夹面板，不经这里）。
    var folderPicker: Project?

    /// 交给了会话的灵感与任务（`AgentLinks`，卡与行上的状态点读它）：整个窗口一份，页面直接读，
    /// 不各自订阅（挂着的页也不会在每次回到前台时重读一遍）。读到和已有的相同不送来（`observe(after:)` 在读取一侧比较），免得页面白算。
    private(set) var agentLinks = AgentLinks(items: [:], launching: [:])
    /// 技能与规则（`AgentLibrary`：Mac 上是本机的，手机上是 Cue 运行的那台的）：入口的角标、技能与规则页与文件页都读这一份；
    /// 同项目目录当场读（`readLibrary`），第一帧就是库里的样子；没有一台写过为 nil。
    private(set) var library: AgentLibrary?
    @ObservationIgnored private var libraryStart: Snapshot<AgentLibrary?>?

    private func follow<T: Sendable & Equatable>(
        _ value: ReferenceWritableKeyPath<Workspace, T>, _ read: @escaping @Sendable (isolated CueStore) throws -> T
    ) async {
        do {
            for try await next in services.store.observe(after: self[keyPath: value], read) { self[keyPath: value] = next }
        } catch is CancellationError {
        } catch {
            fail(error)
        }
    }

    #if os(macOS)
    let sessionHeader = SessionHeader()

    #endif

    @ObservationIgnored private var noticeTask: Task<Void, Never>?

    /// 项目目录当场读（`CueStore.snapshot`），Cue 的现状取整个 App 手里那份（`CueFeed.latest`）：第一帧就是读到的样子，没有"还没读到"这一态。
    init(services: AppServices) {
        self.services = services
        root = Self.openingRoute(services)
        cue = CueWatch(services.cueFeed.latest()?.digest, at: services.speech, local: services.cueLocal)
        #if os(macOS)
        sendState = SendState(services: services)
        #endif
        readCatalog()
        readLibrary()
    }

    #if os(macOS)
    /// 此刻挂着的页：留着的加上当前页（首屏、目录纠正出来的页还没经过 `select`；会话页只在是当前页时在里面）。
    var mountedPages: [Route] { pages.kept.contains(root) ? pages.kept : pages.kept + [root] }

    func finishClosingCard() {
        guard openCard == nil else { return }
        presses.dismiss()
    }
    #endif

    // MARK: 提示

    static let noticeDuration: Duration = .seconds(2.4)

    /// 收已经拼好的 `Dotted`；界面字面量走下面那个（进目录、按当前语言取字）。
    func say(
        _ text: Dotted, tone: Notice.Tone = .done, status: PiShown.Status? = nil, link: Route? = nil, duration: Duration = Workspace.noticeDuration,
        action: NoticeAction? = nil
    ) {
        let notice = Notice(text: text, tone: tone, status: status, link: link, action: action)
        self.notice = notice
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            if self?.notice == notice { self?.notice = nil }
        }
    }

    func say(
        _ text: LocalizedStringResource, tone: Notice.Tone = .done, status: PiShown.Status? = nil, link: Route? = nil,
        duration: Duration = Workspace.noticeDuration, action: NoticeAction? = nil
    ) {
        say(Dotted(String(localized: text)), tone: tone, status: status, link: link, duration: duration, action: action)
    }

    func fail(_ error: any Error) {
        say(Dotted(error.localizedDescription), tone: .failure)
    }

    // MARK: 项目目录、当前项目与新建位置

    /// 工作区的全部订阅，直到所在任务取消：项目目录（读不出来时按"重试"重新订阅）、交给了会话的卡、文件夹引导、Cue 的现状、
    /// 待打开的链接与点开的通知（`openLinks`），Mac 上还有会话归属的项目；会话摘要由 App 级的 `LiveSessions` 跟。页面只读这里存下的那几项，不各自订阅。
    /// Mac 的工作区随 App 常驻、主窗口与两个面板共用一个，由 App 启动时跟：不挂在哪个视图上，窗口关上、内容摘下（`MainShellWindow`）
    /// 面板也照常更新；iOS 每个窗口一份，由窗口的根视图跟。
    func follow() async {
        async let catalog: Void = followCatalog()
        async let links: Void = followAgentLinks()
        async let cue: Void = followCue()
        async let opens: Void = openLinks()
        async let library: Void = followLibrary()
        #if os(macOS)
        await followSessionPlacement()
        #endif
        _ = await (catalog, links, cue, opens, library)
    }

    private func followCatalog() async {
        for await _ in Observations({ self.catalogAttempt }) { await observeCatalog() }
    }

    private func followAgentLinks() async { await follow(\.agentLinks) { try AgentLinks.read(from: $0) } }

    private func readLibrary() {
        let host = localHost
        do {
            libraryStart = try services.store.snapshot { try $0.agentLibrary(host: host) }
            library = libraryStart?.value ?? nil
        } catch {
            fail(error)
        }
    }

    /// 从当场读到的那份接着订阅（当场没读出来就从头订阅）。
    private func followLibrary() async {
        let host = localHost
        let read: @Sendable (isolated CueStore) throws -> AgentLibrary? = { try $0.agentLibrary(host: host) }
        guard let start = libraryStart else { return await follow(\.library, read) }
        do {
            for try await next in services.store.observe(from: start, read) { library = next }
        } catch is CancellationError {
        } catch {
            fail(error)
        }
    }

    private func readCatalog() {
        do {
            try DebugHooks.willReadCatalog(attempt: catalogAttempt)
            let start = try services.store.snapshot { try ProjectCatalog.read(from: $0) }
            (catalogStart, catalog, catalogFailure) = (start, start.value, nil)
        } catch {
            (catalogStart, catalog, catalogFailure) = (nil, nil, error.localizedDescription)
        }
    }

    /// 从当场读到的那份接着订阅项目目录，直到所在任务取消；Mac 上开始时与项目增删时核对当前项目。
    /// 读取失败时清空目录并记下原因：资料库读不出来时不能接着显示过时的项目。
    private func observeCatalog() async {
        guard let start = catalogStart else { return }
        #if os(macOS)
        await reconcileCurrentProject()
        #endif
        do {
            for try await next in services.store.observe(from: start, { try ProjectCatalog.read(from: $0) }) {
                let membershipChanged = catalog.map { Set($0.projects.map(\.id)) != Set(next.projects.map(\.id)) } ?? true
                catalog = next
                if membershipChanged {
                    #if os(macOS)
                    await reconcileCurrentProject()
                    pages.forget(projectsNotIn: Set(next.projects.map(\.id)))
                    #endif
                }
            }
        } catch is CancellationError {
        } catch {
            catalog = nil
            catalogFailure = error.localizedDescription
        }
    }

    func retryCatalog() {
        catalogAttempt += 1
        readCatalog()
        readLibrary()
    }

    #if os(macOS)
    /// 保存的当前项目以 Store 为准：不存在或已进回收站时清掉设置，正开着它就回到 `Route.first`（不经 `select`：不把失效的页记成去过的）。
    /// 项目表每次变化后、写入撞上失效项目时调用。
    func reconcileCurrentProject() async {
        let settings = services.settings
        guard let saved = settings.currentProject else { return }
        do {
            let projects = try await services.store.projects()
            guard !projects.contains(where: { $0.id == saved }) else { return }
            if settings.currentProject == saved { settings.currentProject = nil }
            if root == .project(saved) { root = .first }
        } catch {
            fail(error)
        }
    }
    #endif

    /// 请会话所在的 Mac 结束它。进度（正在结束、没能结束的原因）只来自这条结束请求，界面按 `DeliveryRequest.shownEnd` 读；
    /// 还在路上时再点不会再发一条（Store 去重）。写不进请求时提示。
    func end(_ session: PiSessionState) async {
        do { _ = try await services.end(session) } catch { fail(error) }
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
        attempt { try await work(store) }
    }
}
