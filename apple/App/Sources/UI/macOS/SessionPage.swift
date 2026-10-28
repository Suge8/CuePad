#if os(macOS)
import CuePi
import CueStore
import SwiftUI

extension PiSessionState {
    /// 桥上的实时会话写成同步记录的形状（会话行与近况共用；状态记录按节流写，会落后几秒，界面读这个）。
    /// 摘要（问与答、这一轮已做完的步骤）不在桥上：取同步记录里的（`recap`，对话的投影，文件一变就写）。
    /// 正自己换上新扩展的（`upgrading`）桥上读不到状态，为 nil：界面照同步记录里最后一次读到的样子。
    static func live(_ session: CuePi.PiSession, hostID: String, projectID: UUID?, recap: PiRecap?) -> PiSessionState? {
        guard !session.upgrading else { return nil }
        return PiSessionState(
            id: recordID(sessionID: session.sessionID), sessionID: session.sessionID, hostID: hostID, title: session.displayName,
            projectID: projectID, state: .known(session.state), detail: session.detail, folder: session.cwd.lastPathComponent,
            lastPrompt: recap?.lastPrompt, lastReply: recap?.lastReply, question: session.question, notify: nil,
            stateSince: session.stateSince, busySince: session.busySince, createdAt: session.stateSince, modifiedAt: session.stateSince,
            launchToken: session.launchToken, hosted: session.hosted, subagents: session.subagents,
            pendingPrompt: recap?.pendingPrompt, pendingTools: recap?.pendingTools, model: session.model, thinking: session.thinking, context: session.context,
            agent: .known(session.agent))
    }
}

extension CuePi.PiSession {
    /// 能跳到它所在的终端：开在终端里、知道是哪个终端应用（跳转至少要激活它）。后台托管的与没报终端的（OpenCode 的服务）没有。
    var canJump: Bool { !hosted && terminal.bundleID != nil }
}

extension SessionDigest {
    /// Mac 端按会话 id 读：同步记录（在线与已结束是同一条记录）。在线会话再经 `live(_:hostID:project:)` 换上桥上的实时值。
    static func read(sessionID: String, from store: isolated CueStore) throws -> SessionDigest {
        try read(PiSessionState.recordID(sessionID: sessionID), sessionID: sessionID, from: store)
    }

    /// 会话在线时，状态、详情、名字、可换的模型与命令取桥上的实时值。
    func live(_ session: CuePi.PiSession?, hostID: String, project: Project?) -> SessionDigest {
        guard let session,
              let state = PiSessionState.live(
                session, hostID: hostID, projectID: project?.id ?? self.session?.projectID, recap: self.session.map(\.recap))
        else { return self }
        var digest = self
        digest.session = state
        digest.catalog = AgentCatalog(host: hostID, models: session.availableModels, commands: session.commands, at: session.stateSince)
        if let project { digest.project = project }
        return digest
    }
}

/// 一个 Agent 会话的整页（侧栏、Agent 页、⌘K、菜单栏面板、任务上的会话状态都进这里），对话（`SessionChat`）、回复框（`PiReplyBar`，Mac 上一直是两层）
/// 与顶栏规则（`ChatFollow.showsHeader`）与手机同一套。页头全在窗口工具栏上，内容区里不另起一行。
/// 看历史时标题让开，"⋯"不让开：工具栏一直在，让开只留一格空位；Mac 没有状态栏可点，鼠标移到标题原来的位置（或点它）就唤出。
/// 很久以前的会话没有对话时请它所在的 Mac 补写。是一页（`Route.session`），左上不放返回：去别处靠侧栏。
struct SessionPage: View {
    let sessionID: String
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    private var header: SessionHeader { workspace.sessionHeader }
    @State private var stored: SessionDigest?
    @State private var task: SessionTaskLink?
    @State private var follow = ChatFollow()

    /// 标题、状态与最新的对话先出；回复框、问题卡与"⋯"晚两帧（`NextFrame`）：它们的建立（文本视图、玻璃、菜单）占点击回合的一半，不在点的那一圈里。
    @State private var secondary = false
    /// 读对话的宽度：长回答一行不至于太长，气泡也不挤。
    private static let readingWidth: CGFloat = 760

    var body: some View {
        let slot = services.pi.slot(sessionID: sessionID)
        let live = slot?.session
        let project = live.flatMap { workspace.catalog?.project(workspace.sendState.projects[$0.id]) }
        // 在线会话不等资料库读完就能显示
        let digest = (stored ?? SessionDigest(session: nil, project: nil, deliveries: [])).live(live, hostID: services.hostID, project: project)
        VStack(spacing: 0) {
            if let session = digest.session {
                FloatingReply {
                    // 数据读到前不排对话：在线会话不等资料库就有状态，先排出来是空对话，数据到了再长成整段
                    if stored != nil {
                        SessionChat(
                            session: session, digest: digest, readingWidth: Self.readingWidth, inset: 24, follow: $follow, slot: slot)
                            .replyNotes(session: session.id, messages: digest.messages)
                    }
                } reply: {
                    VStack(spacing: 8) {
                        if secondary {
                            SessionDock(session: session, digest: digest, revealNote: { follow.seek($0.entry) }) { follow.sent() }
                        } else {
                            // 留出回复框平时的高度，它到了时对话不被顶上去
                            Color.clear.frame(height: ComposerMetrics.openOneLine)
                        }
                    }
                    .padding(.horizontal, 24).padding(.bottom, 16)
                    .frame(maxWidth: Self.readingWidth)
                    .animation(Motion.fade, value: session.question)
                }
            } else if stored != nil {
                EmptyState(mascot: .empty, title: "找不到这个会话", message: "Mac 上这个会话的文件可能已经删掉了")
                    .frame(maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.desk)
        .onChange(of: headerState(digest, menu: secondary, task: task), initial: true) { _, state in header.set(state) }
        .onAppear { header.reveal = { follow.reveal() } }
        .onDisappear { header.clear(sessionID) }
        .task {
            await NextFrame.wait()
            await NextFrame.wait()
            secondary = true
        }
        .observing(services.store, id: sessionID, into: $stored,
                   onError: workspace.fail) { [sessionID] store in
            try SessionDigest.read(sessionID: sessionID, from: store)
        }
        .observing(services.store, id: TaskKey(session: sessionID, project: digest.session?.projectID), into: $task,
                   onError: workspace.fail) { [sessionID, project = digest.session?.projectID] store in
            try SessionTaskLink.read(sessionID: sessionID, project: project, from: store)
        }
        .requestsTranscript(stored)
        // 开着这页就算看过：侧栏与菜单栏里的"有新回复"据此消失
        .task(id: digest.session?.stateSince) { if let session = digest.session { services.settings.markSeen(session) } }
    }

    /// 工具栏上的标题与"⋯"（`SessionHeader`）要显示的值：页面算好交过去，工具栏项在主窗口里常驻。
    private func headerState(_ digest: SessionDigest, menu: Bool, task: SessionTaskLink?) -> SessionHeader.State? {
        guard let session = digest.session else { return nil }
        return SessionHeader.State(
            session: session, delivery: digest.delivery, title: digest.title(at: services.speech) ?? session.title, undelivered: PiChat.undeliveredNote(digest.undelivered(at: services.speech)),
            ending: DeliveryRequest.shownEnd(in: digest.deliveries, at: services.speech)?.inTransit == true, place: PiPlace.menuTitle(of: session, project: digest.project),
            pin: digest.task, showsHeader: follow.showsHeader, showsMenu: menu, task: task)
    }

    /// 绑着的任务按会话读，还能绑的按所在项目读。
    private struct TaskKey: Equatable {
        var session: String
        var project: UUID?
    }
}

extension View {
    /// 点按在内容区打开这个会话的整页。不给 `press` 是侧栏里的一行（`RowStyle`，正打开着的那个是选中底），给了是卡片或圆钮的按压。
    func sessionLink(_ sessionID: String, press: Press? = nil) -> some View { modifier(SessionLink(sessionID: sessionID, press: press)) }
}

private struct SessionLink: ViewModifier {
    let sessionID: String
    let press: Press?
    @Environment(Workspace.self) private var workspace

    func body(content: Content) -> some View {
        let opened = workspace.root == .session(sessionID)
        let button = Button {
            workspace.searching = false
            workspace.show(.session(sessionID))
        } label: {
            content.contentShape(.rect)
        }
        Group {
            if let press { button.buttonStyle(PressStyle(press)) } else { button.buttonStyle(RowStyle(selected: opened)) }
        }
        .accessibilityAddTraits(opened ? .isSelected : [])
        .accessibilityHint("打开会话")
    }
}

extension Workspace {
    /// 本机在线的会话换上桥上的实时状态（同步记录按节流写，会落后几秒）；其余原样。
    func withLiveState(_ session: PiSessionState) -> PiSessionState {
        guard let live = services.pi.session(sessionID: session.sessionID) else { return session }
        return .live(live, hostID: services.hostID, projectID: sendState.projects[live.id] ?? session.projectID, recap: session.recap) ?? session
    }

    func withLiveState(_ item: PiSessionListItem) -> PiSessionListItem {
        var item = item
        item.state = withLiveState(item.state)
        return item
    }

    /// 在本机后台开新会话，等到它出现：返回新会话的 Pi 会话 id（按发起时生成的标识认领）；没能开出来时抛出执行端写回的原因。
    /// 请求已执行（Pi 已启动）时先调 `launched`：之后等的是 Pi 自己连上。
    /// `host`：由哪台 Mac 开，默认这台。`card`：从这条灵感或任务开的，开好后它关联到新会话，会话名也按它定（`CueStore.requestLaunch`）。
    /// `agent`：用哪个 Agent 开；`model`、`thinking` 为 nil 是这家的默认。
    func startSession(
        in project: UUID, prompt: String?, title: String, on host: String? = nil, card: UUID? = nil, agent: AgentKind,
        model: PiModelKey? = nil, thinking: PiThinkingLevel? = nil, launched: @escaping () -> Void
    ) async throws -> String {
        let launch = try await services.launchSession(
            in: project, prompt: prompt, title: title, on: host ?? services.hostID, card: card, agent: agent, model: model, thinking: thinking)
        var reported = false, seen = false
        for try await progress in services.store.observe({ try launch.progress(from: $0) }) {
            if let claimed = progress.claimed { return claimed.sessionID }
            // 请求开成了、会话却一直没带着认领标识连上来：等认领的请求到期清掉（`DeliveryExecutor`），不再静静地等下去
            if progress.request != nil { seen = true } else if seen { throw SendError.notLaunched(String(localized: "会话一直没连上 CuePad")) }
            switch progress.phase(at: services.speech) {
            case .failed(let failure): throw SendError.notLaunched(failure.text)
            case .opening where !reported:
                reported = true
                launched()
            default: break
            }
        }
        throw CancellationError()
    }

    /// 跳到会话所在的终端；只能大致定位或失败时说一句。
    func jumpToTerminal(_ id: CuePi.PiSession.ID) {
        Task {
            do {
                let result = try await services.jumpToTerminal(id)
                if let note = result.note { say(Dotted(note), tone: result.precision == .failed ? .failure : .done) }
            } catch {
                fail(error)
            }
        }
    }
}
#endif
