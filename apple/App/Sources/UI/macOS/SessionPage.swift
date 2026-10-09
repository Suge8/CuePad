#if os(macOS)
import CuePi
import CueStore
import SwiftUI

extension PiSessionState {
    /// 桥上的实时会话写成同步记录的形状（会话行与近况共用；状态记录按节流写，会落后几秒，界面读这个）。
    /// 摘要（问与答）不在桥上：取同步记录里的（`recap`，对话的投影，文件一变就写）。
    static func live(_ session: CuePi.PiSession, hostID: String, projectID: UUID?, recap: PiRecap?) -> PiSessionState {
        let (state, detail) = session.syncRepresentation
        let config = session.modelState
        return PiSessionState(
            id: recordID(sessionID: session.sessionID), sessionID: session.sessionID, hostID: hostID, title: session.displayName,
            projectID: projectID, state: .known(state), detail: detail, folder: session.cwd.lastPathComponent,
            lastPrompt: recap?.lastPrompt, lastReply: recap?.lastReply, question: session.question.map(PiQuestion.init), notify: nil,
            stateSince: session.stateSince, busySince: session.busySince, createdAt: session.stateSince, modifiedAt: session.stateSince,
            launchToken: session.launchToken, hosted: session.hosted, subagents: session.subagentStates,
            pendingPrompt: recap?.pendingPrompt, model: config.model, thinking: config.thinking, models: config.models,
            context: session.contextUsage, commands: session.slashCommands)
    }
}

extension SessionDigest {
    /// Mac 端按会话 id 读：同步记录（在线与已结束是同一条记录）。在线会话再经 `live(_:hostID:project:)` 换上桥上的实时值。
    static func read(sessionID: String, from store: isolated CueStore) throws -> SessionDigest {
        try read(PiSessionState.recordID(sessionID: sessionID), sessionID: sessionID, from: store)
    }

    /// 会话在线时，状态、详情、名字与近况取桥上的实时值。
    func live(_ session: CuePi.PiSession?, hostID: String, project: Project?) -> SessionDigest {
        guard let session else { return self }
        var digest = self
        digest.session = .live(
            session, hostID: hostID, projectID: project?.id ?? self.session?.projectID, recap: self.session.map(\.recap))
        if let project { digest.project = project }
        return digest
    }
}

/// 一个 Agent 会话的整页（侧栏、Agent 页、⌘K、菜单栏面板、任务上的会话状态都进这里），与手机的会话页同一套：
/// 会话名与"所在 · 状态 · 计时"（`PiSessionSubtitle`）在窗口工具栏的标题位、紧跟返回与前进，"⋯"（跳到终端、结束会话）在工具栏右边——
/// Mac 的窗口本来就有一条工具栏，手机那种浮在内容上的顶栏放在它下面就是两层页头。顶栏规则与手机同一份（`ChatFollow.showsHeader`）：
/// 看历史时标题与"⋯"让开，回到最新自动出现；Mac 没有状态栏可点，鼠标移到标题原来的位置（或点它）就唤出——顶栏就在那里，
/// 指针过去是桌面上"看一眼顶上"的自然动作。中间是对话
/// （`PiConversation`，子代理在末尾收成一行汇总；只排最近几条，更早的点最上面一行再排开），打开即最新，离最新超过一屏出"回到最新"（`ChatScroll`，Mac 不倒置）；
/// 底部是与手机同一个回复框（`PiReplyBar`），等你确认时问题卡固定在它上方。很久以前的会话没有对话时请它所在的 Mac 补写。
/// 是一页（`Workspace.Page.session`），上一层是 Agent 整页。
struct SessionPage: View {
    let sessionID: String
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @State private var stored: SessionDigest?
    @State private var askedForTranscript = false
    @State private var confirmingEnd = false
    /// 点标题弹出的说明（需要 /reload 时）开着。
    @State private var explaining = false
    @State private var renaming: PiSessionState?
    @State private var follow = ChatFollow()
    /// 对话排开最近多少条（`PiConversation.window`）。
    @State private var shown = PiConversation.firstWindow
    /// 刚从刻度滑条跳到的那条你的话，短暂描一圈。
    @State private var highlight: UUID?
    /// 要跳到的那条还没排开：先排开，排开之后再跳（同一次更新里跳，目标还不在滚动区里）。
    @State private var pendingJump: UUID?

    /// 读对话的宽度：长回答一行不至于太长，气泡也不挤。
    private static let readingWidth: CGFloat = 760
    /// 工具栏里标题一块最宽多少：名字长时截断，不把右边的按钮挤走。
    private static let titleWidth: CGFloat = 420

    var body: some View {
        let live = services.pi.sessions.first { $0.sessionID == sessionID }
        let project = live.flatMap { workspace.catalog?.project(workspace.sessionProjects[$0.id]) }
        // 在线会话不等资料库读完就能显示
        let digest = (stored ?? SessionDigest(session: nil, project: nil, deliveries: [])).live(live, hostID: services.hostID, project: project)
        let shownEnd = DeliveryRequest.shownEnd(in: digest.deliveries)
        VStack(spacing: 0) {
            if let session = digest.session {
                // 数据读到前不排对话：在线会话不等资料库就有状态，先排出来是空对话，数据到了再长成整段
                if stored != nil { conversation(session, digest) } else { Color.clear.frame(maxHeight: .infinity) }
                VStack(spacing: 8) {
                    PiQuestionDock(session: session, deliveries: digest.deliveries)
                    if let reason = shownEnd?.failure, session.state != .known(.ended) {
                        Callout(tint: palette.failure, symbol: "exclamationmark.circle.fill", text: "没能结束：\(reason)", docked: true)
                    }
                    PiReplyBar(
                        session: session, config: digest.config, compact: false,
                        stopping: MacDelivery.stopping(session, deliveries: digest.deliveries),
                        commandProgress: MacDelivery.commandProgress(digest.deliveries),
                        queued: PiChat.queued(digest.deliveries, messages: digest.messages),
                        recall: PiChat.lastSaid(digest.messages)
                    ) {
                        follow.jumpToNewest()
                    }
                }
                .padding(.horizontal, 24).padding(.bottom, 16)
                .frame(maxWidth: Self.readingWidth)
                .animation(Motion.quick, value: session.question)
                .renameSession($renaming)
                .confirmationDialog("结束这个会话？", isPresented: $confirmingEnd, titleVisibility: .visible) {
                    Button("结束会话", role: .destructive) { Task { await workspace.end(session) } }
                } message: {
                    Text("对话会保留，再给它发消息会在后台恢复")
                }
            } else if stored != nil {
                EmptyState(mascot: .empty, title: "找不到这个会话", message: "Mac 上这个会话的文件可能已经删掉了")
                    .frame(maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.desk)
        .toolbar {
            if let session = digest.session {
                // 标题是悬浮的一块玻璃（与手机会话页顶栏中间那一块同一种），让开时连玻璃一起不画
                ToolbarItem(placement: .navigation) { title(session, digest: digest, ending: shownEnd?.isOpen == true) }
                    .sharedBackgroundVisibility(follow.showsHeader ? .automatic : .hidden)
                ToolbarItem(placement: .primaryAction) {
                    menu(session, place: PiPlace.menuTitle(of: session, project: digest.project), live: live, ending: shownEnd?.isOpen == true).headerVisibility(follow.showsHeader)
                }
                // 让开时连系统给圆钮画的玻璃一起不画
                .sharedBackgroundVisibility(follow.showsHeader ? .automatic : .hidden)
            }
        }
        .observing(services.store, SessionDigest.tables, id: sessionID, into: $stored,
                   onError: workspace.fail) { [sessionID] store in
            try SessionDigest.read(sessionID: sessionID, from: store)
        }
        .onChange(of: stored) { askForTranscriptIfNeeded() }
        // 开着这页就算看过：侧栏与菜单栏里的"有新回复"据此消失
        .task(id: digest.session?.stateSince) { if let session = digest.session { services.settings.markSeen(session) } }
    }

    /// 工具栏标题位：一块玻璃里一行，会话名接"状态 · 计时"（所在写在"⋯"菜单最上面；工具栏的玻璃只有一行高）。
    private func title(_ session: PiSessionState, digest: SessionDigest, ending: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(digest.title ?? session.title).font(Typography.toolbarTitle).foregroundStyle(palette.ink).lineLimit(1).layoutPriority(1)
            if ending {
                Text("正在结束…").font(Typography.toolbarSubtitle).foregroundStyle(palette.ink3)
            } else {
                // 副标题以状态标打头：图形没有文字基线，按它的底边对齐会把整行压低；对齐到行里文字的基线
                PiSessionSubtitle(session: session, undelivered: PiChat.undeliveredNote(digest.deliveries, messages: digest.messages))
                    .alignmentGuide(.firstTextBaseline) { $0[.lastTextBaseline] }
            }
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: Self.titleWidth, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
        // 需要 /reload 的会话：状态就写在这块玻璃里，点它看怎么接上（不在对话上另浮一张卡）
        .contentShape(.rect)
        .onTapGesture { if follow.showsHeader, PiShown(session).explanation != nil { explaining = true } }
        .explanationPopover(PiShown(session).explanation, isPresented: $explaining)
        .headerVisibility(follow.showsHeader)
        // 让开时这一块仍接指针：移上去或点一下唤出
        .background {
            if !follow.showsHeader {
                Color.clear.contentShape(.rect)
                    .onHover { if $0 { follow.reveal() } }
                    .onTapGesture { follow.reveal() }
            }
        }
    }

    /// 工具栏右边的"⋯"：最上面写所在，下面重命名、跳到终端（开在终端里的在线会话）、结束会话；都没有时不出现。
    @ViewBuilder private func menu(_ session: PiSessionState, place: String?, live: CuePi.PiSession?, ending: Bool) -> some View {
        let canJump = live.map { !$0.hosted } ?? false
        let canEnd = MacDelivery.canEnd(session)
        let canRename = MacDelivery.canRename(session)
        if place != nil || canRename || canJump || canEnd {
            Menu("更多", systemImage: "ellipsis") {
                if let place { Section(place) {} }
                if canRename {
                    Button("重命名…", systemImage: "pencil") { renaming = session }
                }
                if let live, canJump {
                    Button("跳到终端窗口", systemImage: "macwindow") { workspace.jumpToTerminal(live.id) }
                }
                if canEnd {
                    Button("结束会话", systemImage: "stop.circle", role: .destructive) { confirmingEnd = true }
                        .disabled(ending)
                }
            }
            .menuIndicator(.hidden)
            .help("重命名、跳到终端、结束会话")
        }
    }

    private func conversation(_ session: PiSessionState, _ digest: SessionDigest) -> some View {
        let followKey = PiConversation.followKey(session: session, messages: digest.messages, previews: digest.previews, deliveries: digest.deliveries)
        return ChatScroll(followKey: followKey, readingWidth: Self.readingWidth, inset: 24, follow: $follow) {
            VStack(spacing: 14) {
                if fetchingTranscript(digest) {
                    Label("正在从 Mac 取对话…", systemImage: "arrow.down.circle").font(Typography.meta).foregroundStyle(palette.ink3)
                }
                PiConversation(session: session, messages: digest.messages, previews: digest.previews, deliveries: digest.deliveries, window: $shown)
            }
            #if DEBUG
            .onAppear { PerfProbe.mark("conversation") }
            #endif
        }
        .fadesUnderBars()
        .environment(\.chatHighlight, highlight)
        .overlay(alignment: .trailing) { scrubber(digest) }
        .onChange(of: shown) {
            guard let id = pendingJump else { return }
            pendingJump = nil
            jump(to: id)
        }
        .task(id: highlight) {
            guard highlight != nil else { return }
            try? await Task.sleep(for: .seconds(1.2))
            highlight = nil
        }
        .frame(maxHeight: .infinity)
    }

    /// 右缘的刻度滑条（与手机同一个）：让开窗口右缘的系统滚动条；跳到的那条还没排开时先排开到它。
    @ViewBuilder private func scrubber(_ digest: SessionDigest) -> some View {
        let marks = ChatScrubber.marks(PiChat.entries(digest.messages, previews: digest.previews))
        if !marks.isEmpty {
            ChatScrubber(marks: marks, scrolling: follow.scrolling) { id in
                let needed = PiConversation.window(reaching: id, messages: digest.messages, previews: digest.previews) ?? 0
                if needed > shown {
                    pendingJump = id
                    shown = needed
                } else {
                    jump(to: id)
                }
            }
            .padding(.trailing, Self.scrollerWidth)
        }
    }

    private func jump(to id: UUID) {
        follow.jump(to: id)
        highlight = id
    }

    /// 窗口右缘系统滚动条（悬浮式）占的宽。
    private static let scrollerWidth: CGFloat = 16

    private func fetchingTranscript(_ digest: SessionDigest) -> Bool {
        digest.deliveries.contains { $0.mode == .known(.transcript) && $0.isOpen }
    }

    /// 很久以前的会话没有对话：请它所在的 Mac 补写一次（本机的也走同一条路）。
    private func askForTranscriptIfNeeded() {
        guard !askedForTranscript, let stored, let session = stored.session, services.reachesPiHost,
              PiChat.needsTranscript(session, messages: stored.messages), !fetchingTranscript(stored) else { return }
        askedForTranscript = true
        workspace.attempt { _ = try await services.requestTranscript(of: session) }
    }
}

extension View {
    /// 会话行：点按在内容区打开这个会话的整页；正打开着的那个垫选中底。
    func sessionLink(_ sessionID: String) -> some View { modifier(SessionLink(sessionID: sessionID)) }
}

private struct SessionLink: ViewModifier {
    let sessionID: String
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    func body(content: Content) -> some View {
        let opened = workspace.page == .session(sessionID)
        Button {
            workspace.overlay = nil
            workspace.show(.session(sessionID))
        } label: {
            content.contentShape(.rect)
        }
        .buttonStyle(PressStyle(scale: 0.98))
        .background(opened ? palette.selection : .clear, in: .rect(cornerRadius: 8))
        .accessibilityAddTraits(opened ? .isSelected : [])
        .accessibilityHint("打开会话")
    }
}

extension Workspace {
    /// 本机桥上在线的这个 Pi 会话（`sessionID` 是 Pi 自己的会话 id）此刻的状态；不在线为 nil。
    func liveState(ofSession sessionID: String?) -> PiSessionState? {
        guard let sessionID, let live = services.pi.sessions.first(where: { $0.sessionID == sessionID }) else { return nil }
        return .live(live, hostID: services.hostID, projectID: sessionProjects[live.id], recap: sessionRecaps[sessionID])
    }

    /// 本机在线的会话换上桥上的实时状态（同步记录按节流写，会落后几秒）；其余原样。
    func withLiveState(_ session: PiSessionState) -> PiSessionState {
        guard let live = services.pi.sessions.first(where: { $0.sessionID == session.sessionID }) else { return session }
        return .live(live, hostID: services.hostID, projectID: sessionProjects[live.id] ?? session.projectID, recap: session.recap)
    }

    /// 从提示词交给 Agent 的新会话（开在它所在项目绑定的文件夹）：行上先是"正在开会话"，开好后它关联到新会话。
    /// 没归入项目的为 nil（没有地方可开）；项目还没绑文件夹时就地弹选文件夹面板，选了接着开，取消就不开。
    func newSessionHandOff(for card: Card) -> ((String) -> Void)? {
        guard let project = card.projectID else { return nil }
        let title = catalog?.projects.first { $0.id == project }?.name ?? "新会话", id = card.id
        return { [self] text in
            attempt {
                if try await self.services.store.directory(of: project) == nil {
                    guard let path = ProjectDirectory.pick() else { return }
                    try await self.services.store.setDirectory(path, for: project)
                }
                _ = try await self.startSession(in: project, prompt: text.nonEmpty, title: title, card: id) {}
            }
        }
    }

    /// 在本机后台开新会话，等到它出现：返回新会话的 Pi 会话 id（按发起时生成的标识认领）；没能开出来时抛出执行端写回的原因。
    /// 请求已执行（Pi 已启动）时先调 `launched`：之后等的是 Pi 自己连上。
    /// `card`：从这条灵感或任务开的，开好后它关联到新会话。
    func startSession(
        in project: UUID, prompt: String?, title: String, card: UUID? = nil, launched: @escaping () -> Void
    ) async throws -> String {
        let token = UUID().uuidString
        let request = try await services.launch(PiLaunch(project: project, prompt: prompt, token: token), title: title, on: services.hostID, card: card)
        let progress = services.store.observe([.piSessionStates, .deliveryRequests]) { store in
            (try store.piSessionPage(PiSessionQuery(launchToken: token, limit: 1)).items.first?.state.sessionID,
             try store.deliveryRequest(request.id))
        }
        var reported = false
        for try await (claimed, outcome) in progress {
            if let claimed { return claimed }
            if let reason = outcome?.failure { throw SendError.notDelivered(reason) }
            if !reported, outcome?.status == .known(.succeeded) {
                reported = true
                launched()
            }
        }
        throw CancellationError()
    }

    /// 跳到会话所在的终端；只能大致定位或失败时说一句。
    func jumpToTerminal(_ id: CuePi.PiSession.ID) {
        Task {
            do {
                let result = try await services.jumpToTerminal(id)
                if let note = result.note { say(note, isError: result.precision == .failed) }
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
