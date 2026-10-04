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
            lastPrompt: session.lastPrompt, lastReply: session.lastReply, question: session.question, notify: nil,
            stateSince: session.stateSince, busySince: session.busySince, createdAt: session.stateSince, modifiedAt: session.stateSince)
    }

    /// 历史索引里的会话（同步记录已过期或从没写过）：当作已结束，没有近况，时间是最后活动。
    nonisolated static func history(_ row: StoredPiSession, hostID: String, projectID: UUID?) -> PiSessionState {
        let folder = URL(filePath: row.cwd).lastPathComponent
        return PiSessionState(
            id: recordID(sessionID: row.id), sessionID: row.id, hostID: hostID, title: row.title.isEmpty ? folder : row.title,
            projectID: projectID, state: .known(.ended), detail: nil, folder: folder, lastPrompt: nil, lastReply: nil,
            question: nil, notify: nil, stateSince: row.lastActivityAt, busySince: nil, createdAt: row.lastActivityAt,
            modifiedAt: row.lastActivityAt)
    }
}

extension SessionDigest {
    /// Mac 端按会话 id 读资料库里的部分：这台 Mac 写的同步记录（结束后留 7 天）；没有记录时（结束更久、或从没写过）
    /// 取历史索引里的那一行，当作已结束。在线会话再经 `live(_:hostID:project:)` 换上桥上的实时值。
    static func read(sessionID: String, hostID: String, from store: isolated CueStore) throws -> SessionDigest {
        var digest = try read(PiSessionState.recordID(sessionID: sessionID), sessionID: sessionID, from: store)
        guard digest.session == nil, let row = try store.piSessions().first(where: { $0.id == sessionID }) else { return digest }
        let project = try store.project(containing: URL(filePath: row.cwd))
        digest.project = project
        digest.session = .history(row, hostID: hostID, projectID: project?.id)
        return digest
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

/// 一个 Pi 会话的详情（侧栏、菜单栏面板的会话行点开）：共用的近况（`PiSessionDigest`），下面是发给它的输入。
struct PiSessionDetail: View {
    let sessionID: String
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @State private var stored: SessionDigest?

    private static let width: CGFloat = 440
    private static let maxDigestHeight: CGFloat = 520

    var body: some View {
        let live = services.pi.sessions.first { $0.sessionID == sessionID }
        let project = live.flatMap { workspace.catalog?.project(workspace.sessionProjects[$0.id]) }
        // 在线会话不等资料库读完就能显示
        let digest = (stored ?? SessionDigest(session: nil, project: nil, deliveries: [])).live(live, hostID: services.hostID, project: project)
        VStack(spacing: 0) {
            if let session = digest.session {
                ScrollView {
                    PiSessionDigest(session: session, project: digest.project).padding(20)
                }
                .frame(maxHeight: Self.maxDigestHeight)
                .fixedSize(horizontal: false, vertical: true)
                DeliveryStack(deliveries: digest.deliveries, session: session.state == .known(.ended) ? nil : session)
                    .padding(.horizontal, 14).padding(.bottom, 10)
                Divider()
                DetailReply(session: session, live: live).padding(14)
            } else if stored != nil {
                Text("找不到这个会话").foregroundStyle(palette.ink3).padding(24)
            }
        }
        .frame(width: Self.width)
        .background(palette.desk)
        .observing(services.store, [.piSessionStates, .deliveryRequests, .projects, .piSessions], id: sessionID, into: $stored,
                   onError: workspace.fail) { [sessionID, hostID = services.hostID] store in
            try SessionDigest.read(sessionID: sessionID, hostID: hostID, from: store)
        }
    }
}

/// 发给这个会话：走"发给当前目标"同一条通道（`Workspace.send`），方式按共用规则（`MacDelivery`）；会话已结束时写明原因。
private struct DetailReply: View {
    let session: PiSessionState
    let live: CuePi.PiSession?
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @State private var text = ""
    @State private var chosenMode: DeliveryMode?
    @State private var sending = false
    @FocusState private var focused: Bool

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var modes: [DeliveryMode] { MacDelivery.modes(for: session.state, hasImages: false) }
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
                    Button("跳到终端", systemImage: "terminal") { workspace.jumpToTerminal(live.id) }
                        .labelStyle(.iconOnly).buttonStyle(.borderless)
                        .help("跳到这个会话所在的终端")
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
        } else {
            VStack(alignment: .leading, spacing: 2) {
                Text("这个会话已结束").font(.subheadline.weight(.semibold)).foregroundStyle(palette.ink2)
                Text("发不到它了。在终端重新运行 pi，新的会话会出现在侧栏").font(.footnote).foregroundStyle(palette.ink3)
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

    func body(content: Content) -> some View {
        content
            .environment(\.sessionDetail, SessionDetailAction(
                open: { opened = Opened(id: $0) },
                report: { id, frame in frames[id] = frame },
                space: Self.space))
            .coordinateSpace(.named(Self.space))
            .popover(item: $opened, attachmentAnchor: .rect(.rect(opened.flatMap { frames[$0.id] } ?? .zero)), arrowEdge: arrowEdge) {
                PiSessionDetail(sessionID: $0.id)
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
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(host?.space ?? "")) } action: { host?.report(sessionID, $0) }
    }
}

extension Workspace {
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
