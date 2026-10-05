#if os(macOS)
import CuePi
import CueStore
import SwiftUI

extension PiSessionState {
    /// 桥上的实时会话写成同步记录的形状（会话行与近况共用；同步记录按节流写，会落后几秒，界面读这个）。
    static func live(_ session: CuePi.PiSession, hostID: String, projectID: UUID?) -> PiSessionState {
        let (state, detail) = session.syncRepresentation
        return PiSessionState(
            id: recordID(sessionID: session.sessionID), sessionID: session.sessionID, hostID: hostID, title: session.displayName,
            projectID: projectID, state: .known(state), detail: detail, folder: session.cwd.lastPathComponent,
            lastPrompt: session.lastPrompt, lastReply: session.lastReply, question: session.question.map(PiQuestion.init), notify: nil,
            stateSince: session.stateSince, busySince: session.busySince, createdAt: session.stateSince, modifiedAt: session.stateSince)
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
        digest.session = .live(session, hostID: hostID, projectID: project?.id ?? self.session?.projectID)
        if let project { digest.project = project }
        return digest
    }
}

/// 一个 Pi 会话的详情（侧栏、菜单栏面板的会话行点开，⌘K 会话范围的右侧）：共用的近况（`PiSessionDigest`），
/// 下面是发过去的请求与回复框；已结束的会话回复框换成"继续"。
/// `embedded`：放在 ⌘K 里时高度由面板给，近况在里面滚动；弹出层里按内容长高、到上限才滚动。
struct PiSessionDetail: View {
    let sessionID: String
    var embedded = false
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @State private var stored: SessionDigest?

    private static let maxDigestHeight: CGFloat = 520

    var body: some View {
        let live = services.pi.sessions.first { $0.sessionID == sessionID }
        let project = live.flatMap { workspace.catalog?.project(workspace.sessionProjects[$0.id]) }
        // 在线会话不等资料库读完就能显示
        let digest = (stored ?? SessionDigest(session: nil, project: nil, deliveries: [])).live(live, hostID: services.hostID, project: project)
        VStack(spacing: 0) {
            if let session = digest.session {
                let scroll = ScrollView {
                    PiSessionDigest(session: session, project: digest.project).padding(20)
                }
                if embedded {
                    scroll.frame(maxHeight: .infinity)
                } else {
                    scroll.frame(maxHeight: Self.maxDigestHeight).fixedSize(horizontal: false, vertical: true)
                }
                DeliveryStack(deliveries: digest.deliveries, session: session.state == .known(.ended) ? nil : session)
                    .padding(.horizontal, 14).padding(.bottom, 10)
                Divider()
                DetailReply(session: session, live: live).padding(14)
            } else if stored != nil {
                Text("找不到这个会话").foregroundStyle(palette.ink3).padding(24)
            }
        }
        .observing(services.store, [.piSessionStates, .deliveryRequests, .projects], id: sessionID, into: $stored,
                   onError: workspace.fail) { [sessionID] store in
            try SessionDigest.read(sessionID: sessionID, from: store)
        }
    }
}

/// 发给这个会话：走"发给当前目标"同一条通道（`Workspace.send`），方式按共用规则（`MacDelivery`）。
/// 已结束的会话写明发消息时 Mac 会在后台恢复它；在别的 Mac 上运行的写明在哪。后台托管的会话没有终端，不给"跳到终端"。
private struct DetailReply: View {
    let session: PiSessionState
    let live: CuePi.PiSession?
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @State private var text = ""
    @State private var chosenMode: DeliveryMode?
    @State private var sending = false
    @FocusState private var focused: Bool

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var modes: [DeliveryMode] { MacDelivery.modes(for: session, hasImages: false) }
    /// 会话状态变了（比如开始干活）时，原来选的方式可能不再可用：换成当前可用的第一个。
    private var mode: DeliveryMode? { chosenMode.flatMap { modes.contains($0) ? $0 : nil } ?? modes.first }

    var body: some View {
        if let live {
            VStack(alignment: .leading, spacing: 10) {
                TextField("回复 \(session.title)", text: $text, axis: .vertical)
                    .accessibilityLabel("回复")
                    .textFieldStyle(.plain)
                    .lineLimit(1...5)
                    .focused($focused)
                    .onSubmit(send)
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .paper(radius: 10)
                HStack(spacing: 8) {
                    Picker("发送方式", selection: Binding(get: { mode }, set: { chosenMode = $0 })) {
                        ForEach(modes, id: \.self) { Text($0.label).tag(Optional($0)) }
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                    if !live.hosted {
                        Button("跳到终端", systemImage: "terminal") { workspace.jumpToTerminal(live.id) }
                            .labelStyle(.iconOnly).buttonStyle(.borderless)
                            .help("跳到这个会话所在的终端")
                    }
                    Spacer()
                    Button("发送", action: send)
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(trimmed.isEmpty || sending)
                }
                .controlSize(.small)
                if let explanation = mode?.explanation {
                    Text(explanation).font(.footnote).foregroundStyle(palette.ink3)
                }
            }
            .onAppear { focused = true }
        } else if session.state == .known(.ended) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("这个会话已结束").font(.subheadline.weight(.semibold)).foregroundStyle(palette.ink2)
                    Text(session.hostID == services.hostID ? "给它发消息时，Mac 会在后台把它恢复起来" : "在它所在的 Mac 上接着它")
                        .font(.footnote).foregroundStyle(palette.ink3)
                }
                Spacer()
            }
        } else {
            VStack(alignment: .leading, spacing: 2) {
                Text("在另一台 Mac 上运行").font(.subheadline.weight(.semibold)).foregroundStyle(palette.ink2)
                Text("从这里发不到它；到那台 Mac 上回复").font(.footnote).foregroundStyle(palette.ink3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func send() {
        guard let live, let mode, !trimmed.isEmpty, !sending else { return }
        sending = true
        let body = trimmed
        Task {
            if await workspace.send(body, via: .pi(live.id, mode)) { text = "" }
            sending = false
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
    private static let width: CGFloat = 440
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
    /// 本机在线的会话换上桥上的实时状态（同步记录按节流写，会落后几秒）；其余原样。
    func withLiveState(_ session: PiSessionState) -> PiSessionState {
        guard let live = services.pi.sessions.first(where: { $0.sessionID == session.sessionID }) else { return session }
        return .live(live, hostID: services.hostID, projectID: sessionProjects[live.id] ?? session.projectID)
    }



    /// 在本机后台开新会话，等到它出现：返回新会话的 Pi 会话 id（按发起时生成的标识认领）；没能打开时抛出执行端写回的原因。
    /// 请求成功（Pi 已连上）时先调 `launched`：之后等的是它的同步记录写出来。
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
            if let outcome, outcome.status == .known(.failed) { throw SendError.notDelivered(outcome.resultDetail ?? "没有说明原因") }
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
