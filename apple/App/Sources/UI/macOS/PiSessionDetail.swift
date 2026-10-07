#if os(macOS)
import CuePi
import CueStore
import SwiftUI

extension PiSessionState {
    /// 桥上的实时会话写成同步记录的形状（会话行与近况共用；状态记录按节流写，会落后几秒，界面读这个）。
    /// 摘要（问与答）不在桥上：取同步记录里的（`recap`，对话的投影，文件一变就写）。
    static func live(_ session: CuePi.PiSession, hostID: String, projectID: UUID?, recap: PiRecap?) -> PiSessionState {
        let (state, detail) = session.syncRepresentation
        return PiSessionState(
            id: recordID(sessionID: session.sessionID), sessionID: session.sessionID, hostID: hostID, title: session.displayName,
            projectID: projectID, state: .known(state), detail: detail, folder: session.cwd.lastPathComponent,
            lastPrompt: recap?.lastPrompt, lastReply: recap?.lastReply, question: session.question.map(PiQuestion.init), notify: nil,
            stateSince: session.stateSince, busySince: session.busySince, createdAt: session.stateSince, modifiedAt: session.stateSince,
            launchToken: session.launchToken, hosted: session.hosted, subagents: session.subagentStates,
            pendingPrompt: recap?.pendingPrompt)
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

/// 一个 Pi 会话的详情（侧栏、菜单栏面板的会话行、任务上的会话状态点开，⌘K 会话范围的右侧），聊天式，与手机的会话页同一套：
/// 顶上一行会话名，下面一行"所在 · 状态 · 计时"（`PiSessionSubtitle`）；中间是对话（`PiConversation`，子代理列在末尾的进展下），
/// 打开停在最新；底部是回复框，等你确认时问题卡固定在它上方。很久以前的会话没有对话时请它所在的 Mac 补写。
/// `embedded`：放在 ⌘K 里时高度由面板给；弹出层里对话区按内容长高，到上限后在里面滚动。
struct PiSessionDetail: View {
    let sessionID: String
    var embedded = false
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @State private var stored: SessionDigest?
    @State private var askedForTranscript = false

    /// 弹出层里对话区最高多少：按读对话调高，再长就在里面滚动。
    private static let maxConversationHeight: CGFloat = 620

    var body: some View {
        let live = services.pi.sessions.first { $0.sessionID == sessionID }
        let project = live.flatMap { workspace.catalog?.project(workspace.sessionProjects[$0.id]) }
        // 在线会话不等资料库读完就能显示
        let digest = (stored ?? SessionDigest(session: nil, project: nil, deliveries: [])).live(live, hostID: services.hostID, project: project)
        VStack(spacing: 0) {
            if let session = digest.session {
                header(session, project: digest.project, delivery: digest.latestDelivery, live: live)
                Divider()
                conversation(session, digest)
                VStack(spacing: 8) {
                    PiQuestionDock(session: session, deliveries: digest.deliveries)
                    DetailReply(session: session, live: live)
                }
                .padding(12)
                .animation(Motion.quick, value: session.question)
            } else if stored != nil {
                Text("找不到这个会话").foregroundStyle(palette.ink3).padding(24)
            }
        }
        .observing(services.store, SessionDigest.tables, id: sessionID, into: $stored,
                   onError: workspace.fail) { [sessionID] store in
            try SessionDigest.read(sessionID: sessionID, from: store)
        }
        .onChange(of: stored) { askForTranscriptIfNeeded() }
        // 开着详情就算看过：侧栏与菜单栏里的"有新回复"据此消失
        .task(id: digest.session?.stateSince) { if let session = digest.session { services.settings.markSeen(session) } }
    }

    private func header(_ session: PiSessionState, project: Project?, delivery: DeliveryRequest?, live: CuePi.PiSession?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title).font(.headline).foregroundStyle(palette.ink).lineLimit(1)
                PiSessionSubtitle(session: session, project: project, delivery: delivery)
            }
            Spacer(minLength: 8)
            if let live, !live.hosted {
                Button("跳到终端窗口", systemImage: "macwindow") { workspace.jumpToTerminal(live.id) }
                    .labelStyle(.iconOnly).buttonStyle(.borderless).foregroundStyle(palette.ink3)
                    .help("跳到这个会话所在的终端窗口")
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    @ViewBuilder private func conversation(_ session: PiSessionState, _ digest: SessionDigest) -> some View {
        let follow = PiConversation.followKey(session: session, messages: digest.messages, deliveries: digest.deliveries)
        // 打开停在最新；在底部时跟着新内容，往上翻后暂停并出"新消息"按钮（`ChatScroll`）
        let scroll = ChatScroll(followKey: follow) {
            VStack(spacing: 14) {
                if fetchingTranscript(digest) {
                    Label("正在从 Mac 取对话…", systemImage: "arrow.down.circle").font(.footnote).foregroundStyle(palette.ink3)
                }
                PiConversation(session: session, messages: digest.messages, deliveries: digest.deliveries)
            }
            .padding(16)
        }
        if embedded {
            scroll.frame(maxHeight: .infinity)
        } else {
            scroll.frame(maxHeight: Self.maxConversationHeight).fixedSize(horizontal: false, vertical: true)
        }
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

    private func composer(placeholder: String, @ViewBuilder button: () -> some View) -> some View {
        HStack(alignment: .bottom, spacing: 6) {
            TextField(placeholder, text: $text, axis: .vertical)
                .accessibilityLabel("回复")
                .textFieldStyle(.plain)
                .lineLimit(1...6)
                .focused($focused)
                .onSubmit(submit)
                .padding(.vertical, 8)
            button()
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

/// 会话详情的弹出层挂在稳定的容器上（侧栏列表、菜单栏面板），箭头指向点开的那一行：列表里的行会随会话结束、
/// 排序变化被重建甚至消失，挂在行上的弹出层会跟着被关掉。行经 `sessionDetailRow(_:)` 报位置、点开。
struct SessionDetailHost: ViewModifier {
    let arrowEdge: Edge
    @State private var opened: Opened?
    @State private var frames: [String: CGRect] = [:]

    private struct Opened: Identifiable { let id: String }
    private static let space = "sessionDetailHost"
    /// 读对话的宽度：长回答一行不至于太长，气泡也不挤。
    private static let width: CGFloat = 480
    @Environment(\.palette) private var palette

    func body(content: Content) -> some View {
        content
            .environment(\.sessionDetail, SessionDetailAction(
                open: { opened = Opened(id: $0) },
                report: { id, frame in frames[id] = frame },
                space: Self.space))
            .coordinateSpace(.named(Self.space))
            .popover(item: $opened, attachmentAnchor: .rect(.rect(opened.flatMap { frames[$0.id] } ?? .zero)), arrowEdge: arrowEdge) {
                PiSessionDetail(sessionID: $0.id).frame(width: Self.width).background(palette.desk)
            }
    }
}

struct SessionDetailAction {
    let open: (String) -> Void
    let report: (String, CGRect) -> Void
    let space: String
}

extension EnvironmentValues {
    @Entry var sessionDetail: SessionDetailAction?
}

extension View {
    /// 会话行：点按打开它的详情（由外层的 `SessionDetailHost` 弹出）。
    func sessionDetailRow(_ sessionID: String) -> some View { modifier(SessionDetailRow(sessionID: sessionID)) }
}

private struct SessionDetailRow: ViewModifier {
    let sessionID: String
    @Environment(\.sessionDetail) private var host

    func body(content: Content) -> some View {
        Button { host?.open(sessionID) } label: { content.contentShape(.rect) }
            .buttonStyle(PressStyle(scale: 0.98))
            .accessibilityHint("打开会话详情")
            .onGeometryChange(for: CGRect.self) { [space = host?.space ?? ""] in $0.frame(in: .named(space)) } action: { host?.report(sessionID, $0) }
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

    /// 在本机后台开新会话，等到它出现：返回新会话的 Pi 会话 id（按发起时生成的标识认领）；没能开出来时抛出执行端写回的原因。
    /// 请求已执行（Pi 已启动）时先调 `launched`：之后等的是 Pi 自己连上。
    func startSession(at place: PiLaunchPlace, prompt: String?, title: String, launched: @escaping () -> Void) async throws -> String {
        let token = UUID().uuidString
        let request = try await services.launch(PiLaunch(place: place, prompt: prompt, token: token), title: title, on: services.hostID)
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
