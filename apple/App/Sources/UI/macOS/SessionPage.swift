#if os(macOS)
import CuePi
import CueStore
import SwiftUI

extension PiSessionState {
    /// 桥上的实时会话写成同步记录的形状（会话行与近况共用；状态记录按节流写，会落后几秒，界面读这个）。
    /// 摘要（问与答、这一轮已做完的步骤）不在桥上：取同步记录里的（`recap`，对话的投影，文件一变就写）。
    static func live(_ session: CuePi.PiSession, hostID: String, projectID: UUID?, recap: PiRecap?) -> PiSessionState {
        PiSessionState(
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
        guard let session else { return self }
        var digest = self
        digest.session = .live(
            session, hostID: hostID, projectID: project?.id ?? self.session?.projectID, recap: self.session.map(\.recap))
        digest.catalog = AgentCatalog(host: hostID, models: session.availableModels, commands: session.commands, at: session.stateSince)
        if let project { digest.project = project }
        return digest
    }
}

/// 一个 Agent 会话的整页（侧栏、Agent 页、⌘K、菜单栏面板、任务上的会话状态都进这里），与手机的会话页同一套：
/// 会话名与状态（`PiSessionSubtitle`，在跑或要你注意时才有）在窗口工具栏居中（与对话的阅读栏同一条中线），绑着任务时同一块玻璃里还有这件事与它的完成圈（`PageTitleSlot`），
/// "⋯"（完成或绑定任务、重命名、跳到终端、结束会话）在工具栏右上——Mac 的窗口本来就有一条工具栏，页头全在它上面，内容区里不另起一行。顶栏规则与手机同一份（`ChatFollow.showsHeader`）：
/// 看历史时标题让开（"⋯"不让开：工具栏本来就一直在，让开只留一格空位），回到最新自动出现；Mac 没有状态栏可点，鼠标移到标题原来的位置（或点它）就唤出——顶栏就在那里，
/// 指针过去是桌面上"看一眼顶上"的自然动作。中间是对话
/// （`SessionChat`，与手机同一个：只排最近几条，更早的点最上面一行再排开），打开即最新，离最新超过一屏出"回到最新"；
/// 底部是与手机同一个回复框（`PiReplyBar`，Mac 上一直是两层），等你确认时问题卡固定在它上方。很久以前的会话没有对话时请它所在的 Mac 补写。
/// 是一页（`Route.session`），左上不放返回：去别处靠侧栏。
struct SessionPage: View {
    let sessionID: String
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    private var header: SessionHeader { workspace.sessionHeader }
    @State private var stored: SessionDigest?
    @State private var task: SessionTaskLink?
    @State private var askedForTranscript = false
    @State private var confirmingEnd: PiSessionState?
    @State private var renaming: PiSessionState?
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
        let shownEnd = DeliveryRequest.shownEnd(in: digest.deliveries, at: services.speech)
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
                            PiQuestionDock(session: session, deliveries: digest.deliveries)
                            if let failure = shownEnd?.failure, session.state != .known(.ended) {
                                Callout(.failed, text: "没能结束：\(failure.text(sync: services.syncStatus))", docked: true)
                            }
                            PiReplyBar(
                                session: session, config: digest.config(at: services.speech), catalog: digest.catalog,
                                stopping: MacDelivery.stopping(session, deliveries: digest.deliveries, at: services.speech),
                                commandProgress: MacDelivery.commandProgress(digest.deliveries, messages: digest.messages, at: services.speech),
                                sending: PiChat.sending(digest.deliveries, messages: digest.messages, at: services.speech),
                                queued: PiChat.queued(digest.deliveries, messages: digest.messages, at: services.speech),
                                recall: PiChat.lastSaid(digest.messages),
                                revealNote: { follow.seek($0.entry) }
                            ) {
                                follow.sent()
                            }
                        } else {
                            // 留出回复框平时的高度，它到了时对话不被顶上去
                            Color.clear.frame(height: ComposerMetrics.openOneLine)
                        }
                    }
                    .padding(.horizontal, 24).padding(.bottom, 16)
                    .frame(maxWidth: Self.readingWidth)
                    .animation(Motion.quick, value: session.question)
                    .renameSession($renaming)
                    .endSession($confirmingEnd)
                }
            } else if stored != nil {
                EmptyState(mascot: .empty, title: "找不到这个会话", message: "Mac 上这个会话的文件可能已经删掉了")
                    .frame(maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.desk)
        .onChange(of: headerState(digest, live: live, shownEnd: shownEnd, menu: secondary, task: task), initial: true) { _, state in header.set(state) }
        .onAppear {
            header.rename = { renaming = $0 }
            header.end = { confirmingEnd = $0 }
            header.reveal = { follow.reveal() }
        }
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
        .onChange(of: stored) { askForTranscriptIfNeeded() }
        // 开着这页就算看过：侧栏与菜单栏里的"有新回复"据此消失
        .task(id: digest.session?.stateSince) { if let session = digest.session { services.settings.markSeen(session) } }
    }

    /// 工具栏上的标题与"⋯"（`SessionHeader`）要显示的值：页面算好交过去，工具栏项在主窗口里常驻。
    private func headerState(_ digest: SessionDigest, live: CuePi.PiSession?, shownEnd: Speech.Trip?, menu: Bool, task: SessionTaskLink?) -> SessionHeader.State? {
        guard let session = digest.session else { return nil }
        return SessionHeader.State(
            session: session, title: digest.title(at: services.speech) ?? session.title, undelivered: PiChat.undeliveredNote(digest.undelivered(at: services.speech)),
            ending: shownEnd == .sending, place: PiPlace.menuTitle(of: session, project: digest.project),
            liveID: live.flatMap { $0.canJump ? $0.id : nil }, canEnd: session.canEnd, canRename: MacDelivery.canRename(session),
            showsHeader: follow.showsHeader, showsMenu: menu, task: task)
    }

    /// 绑着的任务按会话读，还能绑的按所在项目读。
    private struct TaskKey: Equatable {
        var session: String
        var project: UUID?
    }

    /// 很久以前的会话没有对话：请它所在的 Mac 补写一次（本机的也走同一条路；已有没被领取的补写请求时不写第二条，`CueStore.requestTranscript`）。
    private func askForTranscriptIfNeeded() {
        guard !askedForTranscript, let stored, let session = stored.session, services.reachesPiHost,
              PiChat.needsTranscript(session, messages: stored.messages) else { return }
        askedForTranscript = true
        workspace.attempt { _ = try await services.requestTranscript(of: session) }
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
        let opened = workspace.page == .session(sessionID)
        let button = Button {
            workspace.searching = false
            workspace.showsTasks = false
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
        return .live(live, hostID: services.hostID, projectID: sendState.projects[live.id] ?? session.projectID, recap: session.recap)
    }

    /// 同 `withLiveState(_:)`，会话列表项的会话换上桥上的实时状态。
    func withLiveState(_ item: PiSessionListItem) -> PiSessionListItem {
        var item = item
        item.state = withLiveState(item.state)
        return item
    }

    /// 在本机后台开新会话，等到它出现：返回新会话的 Pi 会话 id（按发起时生成的标识认领）；没能开出来时抛出执行端写回的原因。
    /// 请求已执行（Pi 已启动）时先调 `launched`：之后等的是 Pi 自己连上。
    /// `host`：由哪台 Mac 开，默认这台。`card`：从这条灵感或任务开的，开好后它关联到新会话，会话名也按它定（`CueStore.requestLaunch`）。
    /// `agent`：用哪个 Agent 开，记作下次的默认（`AppSettings.lastAgent`）。
    func startSession(
        in project: UUID, prompt: String?, title: String, on host: String? = nil, card: UUID? = nil, agent: AgentKind,
        launched: @escaping () -> Void
    ) async throws -> String {
        let token = UUID().uuidString
        services.settings.lastAgent = agent
        let request = try await services.launch(
            PiLaunch(project: project, prompt: prompt, token: token, agent: agent), title: title, on: host ?? services.hostID, card: card)
        var reported = false
        for try await progress in services.store.observe({
            try LaunchProgress.read(request: request.id, token: token, from: $0)
        }) {
            if let claimed = progress.claimed { return claimed.sessionID }
            switch progress.phase(at: services.speech) {
            case .failed(let failure): throw SendError.notDelivered(failure.text(sync: services.syncStatus))
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
                if let note = result.note { say(Dotted(note), isError: result.precision == .failed) }
            } catch {
                fail(error)
            }
        }
    }
}

private extension View {
    /// 顶栏让开：淡到透明、不可点、读屏跳过（位置留着，工具栏不重排）。
    func headerVisibility(_ shown: Bool) -> some View {
        opacity(shown ? 1 : 0)
            .animation(Motion.quick, value: shown)
            .allowsHitTesting(shown)
            .accessibilityHidden(!shown)
    }
}
#endif
