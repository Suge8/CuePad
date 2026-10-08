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
            pendingPrompt: recap?.pendingPrompt, model: config.model, thinking: config.thinking, models: config.models)
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
/// 顶上会话名，下面一行"所在 · 状态 · 计时"（`PiSessionSubtitle`），右边"⋯"（跳到终端、结束会话）；中间是对话
/// （`PiConversation`，子代理在末尾收成一行汇总），打开即最新，离最新超过一屏出"回到最新"（`ChatScroll`，Mac 不倒置）；
/// 底部是回复框，等你确认时问题卡固定在它上方。很久以前的会话没有对话时请它所在的 Mac 补写。推在根页上，返回回到原来那页。
struct SessionPage: View {
    let sessionID: String
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @State private var stored: SessionDigest?
    @State private var askedForTranscript = false
    @State private var confirmingEnd = false

    /// 读对话的宽度：长回答一行不至于太长，气泡也不挤。
    private static let readingWidth: CGFloat = 760

    var body: some View {
        let live = services.pi.sessions.first { $0.sessionID == sessionID }
        let project = live.flatMap { workspace.catalog?.project(workspace.sessionProjects[$0.id]) }
        // 在线会话不等资料库读完就能显示
        let digest = (stored ?? SessionDigest(session: nil, project: nil, deliveries: [])).live(live, hostID: services.hostID, project: project)
        let shownEnd = DeliveryRequest.shownEnd(in: digest.deliveries)
        VStack(spacing: 0) {
            if let session = digest.session {
                header(session, digest: digest, live: live, ending: shownEnd?.isOpen == true)
                conversation(session, digest)
                VStack(spacing: 8) {
                    PiQuestionDock(session: session, deliveries: digest.deliveries)
                    if let reason = shownEnd?.failure, session.state != .known(.ended) {
                        Callout(tint: palette.failure, symbol: "exclamationmark.circle.fill", text: "没能结束：\(reason)")
                    }
                    DetailReply(session: session, live: live, config: digest.config)
                }
                .padding(.horizontal, 24).padding(.bottom, 16)
                .frame(maxWidth: Self.readingWidth)
                .animation(Motion.quick, value: session.question)
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
        .observing(services.store, SessionDigest.tables, id: sessionID, into: $stored,
                   onError: workspace.fail) { [sessionID] store in
            try SessionDigest.read(sessionID: sessionID, from: store)
        }
        .onChange(of: stored) { askForTranscriptIfNeeded() }
        // 开着这页就算看过：侧栏与菜单栏里的"有新回复"据此消失
        .task(id: digest.session?.stateSince) { if let session = digest.session { services.settings.markSeen(session) } }
    }

    private func header(_ session: PiSessionState, digest: SessionDigest, live: CuePi.PiSession?, ending: Bool) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(session.title).font(.system(size: 17, weight: .semibold)).foregroundStyle(palette.ink).lineLimit(1)
                if ending {
                    Text("正在结束…").font(.caption).foregroundStyle(palette.ink3)
                } else {
                    PiSessionSubtitle(session: session, project: digest.project, delivery: digest.latestDelivery)
                }
            }
            Spacer(minLength: 8)
            let canJump = live.map { !$0.hosted } ?? false
            if canJump || session.state != .known(.ended) {
                Menu {
                    if let live, canJump {
                        Button("跳到终端窗口", systemImage: "macwindow") { workspace.jumpToTerminal(live.id) }
                    }
                    if session.state != .known(.ended) {
                        Button("结束会话", systemImage: "stop.circle", role: .destructive) { confirmingEnd = true }
                            .disabled(ending)
                    }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 14, weight: .semibold)).foregroundStyle(palette.ink2)
                        .frame(width: 32, height: 32).contentShape(.circle)
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                .glassEffect(.regular.interactive(), in: .circle)
                .accessibilityLabel("更多")
            }
        }
        .padding(.horizontal, 24).padding(.top, 4).padding(.bottom, 10)
        .frame(maxWidth: Self.readingWidth)
    }

    private func conversation(_ session: PiSessionState, _ digest: SessionDigest) -> some View {
        let follow = PiConversation.followKey(session: session, messages: digest.messages, deliveries: digest.deliveries)
        return ChatScroll(followKey: follow) {
            VStack(spacing: 14) {
                if fetchingTranscript(digest) {
                    Label("正在从 Mac 取对话…", systemImage: "arrow.down.circle").font(.footnote).foregroundStyle(palette.ink3)
                }
                PiConversation(session: session, messages: digest.messages, deliveries: digest.deliveries)
            }
            .padding(.horizontal, 24).padding(.vertical, 16)
            .frame(maxWidth: Self.readingWidth)
            .frame(maxWidth: .infinity)
        }
        .frame(maxHeight: .infinity)
    }

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

/// 回复框（与手机同一种：发送钮在输入框里），此刻做什么按共用规则（`MacDelivery.reply`）：
/// 平时发消息——点发送钮是默认方式，其余方式按住发送钮出来；等你确认时，文字型问题它就是作答框，
/// 选择、确认型收成一行"先在上面作答"（问题卡固定在回复框上方），这里答不了的写明要在 Pi 里回答。
/// 发消息时本机在线的走"发给当前目标"同一条通道（`Workspace.send`）；已结束的与别的 Mac 上的写一条投送请求给它所在的 Mac
/// （已结束的由那台 Mac 在后台唤醒后再送达），送达情况写在对话末尾你的气泡下。
private struct DetailReply: View {
    let session: PiSessionState
    let live: CuePi.PiSession?
    /// 模型与思考强度的显示值：在线会话放在输入框下面一排（与手机同一组件 `PiConfigControls`）。
    let config: PiConfigShown
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @State private var text = ""
    @State private var sending = false
    @FocusState private var focused: Bool

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSend: Bool { !trimmed.isEmpty && !sending }
    private var reply: PiReply { MacDelivery.reply(to: session, hasImages: false) }

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            switch reply {
            case .message(let modes): composer(placeholder: placeholder(modes)) { sendButton(modes) }
            case .answer: composer(placeholder: "在这里回答上面的问题") { answerButton }
            case .answerAbove: notice("先在上面作答", systemImage: "arrow.up")
            case .unanswerable: notice("这个问题要在终端里的 Agent 那边回答", systemImage: "terminal")
            }
        }
    }

    /// 输入框：文字在上；在线会话下面一排模型与思考强度，右边发送钮（没有那一排时发送钮跟在文字右边）。
    private func composer(placeholder: String, @ViewBuilder button: () -> some View) -> some View {
        let tools = session.state != .known(.ended) && !session.models.isEmpty
        return VStack(alignment: .leading, spacing: 0) {
            if let failure = config.failure {
                Text("没换成：\(failure)").font(.caption).foregroundStyle(palette.failure).lineLimit(2).padding(.top, 8)
            }
            HStack(alignment: .bottom, spacing: 6) {
                TextField(placeholder, text: $text, axis: .vertical)
                    .accessibilityLabel("回复")
                    .textFieldStyle(.plain)
                    .lineLimit(1...6)
                    .focused($focused)
                    .onSubmit(submit)
                    .onExitCommand { focused = false }
                    .padding(.vertical, 8)
                if !tools { button() }
            }
            if tools {
                HStack(spacing: 6) {
                    PiConfigControls(session: session, shown: config)
                    button()
                }
            }
        }
        .padding(.leading, 12).padding(.trailing, 4).padding(.vertical, 2)
        .paper(radius: 18)
        .onAppear { focused = true }
    }

    /// 等你确认、不能发自由文本时收成的一行。
    private func notice(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.subheadline).foregroundStyle(palette.ink2)
            .padding(.horizontal, 14).frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
            .paper(radius: 18)
    }

    private func placeholder(_ modes: [DeliveryMode]) -> String {
        if session.state == .known(.ended) { return "回复 \(session.title)（会先在后台唤醒它）" }
        guard let first = modes.first, modes.count > 1, first != .send else { return "回复 \(session.title)" }
        return "\(first.label) · 按住发送钮可选别的说法"
    }

    @ViewBuilder private func sendButton(_ modes: [DeliveryMode]) -> some View {
        let others = modes.dropFirst()
        if others.isEmpty {
            Button { send(modes.first) } label: { RoundSendGlyph(enabled: canSend) }
                .buttonStyle(.plain)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!canSend)
                .accessibilityLabel("发送")
        } else {
            Menu {
                ForEach(Array(others), id: \.self) { mode in
                    Button { send(mode) } label: {
                        Text(mode.label)
                        if let explanation = mode.explanation { Text(explanation) }
                    }
                }
            } label: {
                RoundSendGlyph(enabled: canSend)
            } primaryAction: {
                send(modes.first)
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .disabled(!canSend)
            .help([modes.first?.label, modes.first?.explanation].compactMap { $0 }.joined(separator: "："))
            .accessibilityLabel(modes.first.map { "发送，\($0.label)" } ?? "发送")
            .accessibilityHint("按住可以选别的说法")
            .background { Button("") { send(modes.first) }.keyboardShortcut(.return, modifiers: .command).hidden() }
        }
    }

    private var answerButton: some View {
        Button(action: answer) { RoundSendGlyph(enabled: canSend) }
            .buttonStyle(.plain)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!canSend)
            .accessibilityLabel("回答")
    }

    private func submit() {
        switch reply {
        case .message(let modes): send(modes.first)
        case .answer: answer()
        case .answerAbove, .unanswerable: break
        }
    }

    private func send(_ mode: DeliveryMode?) {
        guard let mode, canSend else { return }
        sending = true
        let body = trimmed
        Task {
            defer { sending = false }
            if let live {
                if await workspace.send(body, via: .pi(live.id, mode)) { text = "" }
                return
            }
            do {
                try await services.requestMacDelivery(body, to: session, mode: mode)
                text = ""
            } catch {
                workspace.fail(error)
            }
        }
    }

    /// 文字型问题的回答：作答请求交给会话所在的 Mac（本机也走它，由执行器交给扩展）。
    private func answer() {
        guard canSend else { return }
        sending = true
        let value = PiAnswerValue.text(trimmed)
        workspace.attempt {
            defer { sending = false }
            _ = try await services.answer(value, to: session)
            text = ""
        }
    }
}

extension View {
    /// 会话行：点按在内容区打开这个会话的整页（推在当前页上）；正打开着的那个垫选中底。
    func sessionLink(_ sessionID: String) -> some View { modifier(SessionLink(sessionID: sessionID)) }
}

private struct SessionLink: ViewModifier {
    let sessionID: String
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    func body(content: Content) -> some View {
        let opened = workspace.openedSession == sessionID
        Button {
            workspace.overlay = nil
            workspace.openSession(sessionID)
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

    /// 从灵感或任务交给 Agent 的新会话（开在它所在项目绑定的目录）：行上先是"正在开会话"，开好后它关联到新会话。
    /// 项目没绑目录时为 nil（菜单里不给这一项）。
    func newSessionHandOff(for card: Card) -> ((String) -> Void)? {
        guard let project = card.projectID, catalog?.directories[project] != nil else { return nil }
        let title = catalog?.projects.first { $0.id == project }?.name ?? "新会话", id = card.id
        return { [self] text in
            attempt { _ = try await self.startSession(at: .project(project), prompt: text.nonEmpty, title: title, card: id) {} }
        }
    }

    /// 在本机后台开新会话，等到它出现：返回新会话的 Pi 会话 id（按发起时生成的标识认领）；没能开出来时抛出执行端写回的原因。
    /// 请求已执行（Pi 已启动）时先调 `launched`：之后等的是 Pi 自己连上。
    /// `card`：从这条灵感或任务开的，开好后它关联到新会话。
    func startSession(
        at place: PiLaunchPlace, prompt: String?, title: String, card: UUID? = nil, launched: @escaping () -> Void
    ) async throws -> String {
        let token = UUID().uuidString
        let request = try await services.launch(PiLaunch(place: place, prompt: prompt, token: token), title: title, on: services.hostID, card: card)
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
#endif
