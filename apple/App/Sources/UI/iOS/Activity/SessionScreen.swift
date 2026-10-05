#if os(iOS)
import CueStore
import CueText
import SwiftUI

/// 一个 Pi 会话的近况（Pi 页的会话行、锁屏通知、"发到 Mac"选好会话后都进这里）：上面是近况，
/// 底部是发过去的最新一条请求与回复框（已结束的会话也能回复，Mac 在后台把它恢复起来再送达）。
/// 会话记录在页面打开期间被删掉（Mac 上的会话文件被删）时，照样显示最后一次看到的近况，底部换成说明。
struct SessionScreen: View {
    let id: UUID
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(Navigation.self) private var navigation
    @Environment(\.palette) private var palette
    @State private var digest: SessionDigest?
    /// 最后一次读到的会话记录：记录被删后仍显示它。
    @State private var lastSeen: PiSessionState?
    @State private var draft: Navigation.Outbox?

    /// 阅读宽度上限：iPad 上长回答一行不超过它。
    private static let readingWidth: CGFloat = 600

    var body: some View {
        ScrollView {
            if let session = digest?.session ?? lastSeen {
                PiSessionDigest(session: session, project: digest?.project, deliveries: digest?.deliveries ?? [])
                    .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 24)
                    // iPad 上一行不超过阅读宽度，居中
                    .frame(maxWidth: Self.readingWidth)
                    .frame(maxWidth: .infinity)
            } else if digest != nil {
                ContentUnavailableView {
                    Label("找不到这个会话", systemImage: "terminal")
                } description: {
                    Text("Mac 上这个会话的文件可能已经删掉了")
                }
                .padding(.top, 60)
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .background(palette.desk)
        // 会话名在页面里（读到之前导航栏不先显示一个空标题再换）
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let session = digest?.session ?? lastSeen {
                // 已结束的会话也能回复：Mac 在后台把它恢复起来再送达
                let alive = digest?.session != nil
                // 发出后最新一条就在回复框上方，长回答下也看得到送达情况
                VStack(spacing: 8) {
                    DeliveryStack(deliveries: digest?.deliveries ?? [], session: alive ? session : nil)
                    if alive {
                        ReplyBar(session: session, draft: $draft)
                    } else {
                        Text("这个会话已经不在了，发不到它").font(.footnote).foregroundStyle(palette.ink3)
                    }
                }
                .padding(.horizontal, 8).padding(.bottom, 8)
                .frame(maxWidth: Self.readingWidth)
                .frame(maxWidth: .infinity)
            }
        }
        .onAppear { if draft == nil { draft = navigation.takeDraft(for: id) } }
        .observing(services.store, [.piSessionStates, .deliveryRequests, .projects], id: DigestKey(id: id, sessionID: lastSeen?.sessionID),
                   into: $digest, onError: workspace.fail) { [id, lastSeen] store in
            try SessionDigest.read(id, sessionID: lastSeen?.sessionID, from: store)
        }
        .onChange(of: digest?.session) { _, session in if let session { lastSeen = session } }
    }
}

private struct DigestKey: Equatable {
    var id: UUID
    var sessionID: String?
}

/// 回复框：一个发送。Pi 空闲时直接发；正忙时发出的话等它做完再说，旁边一个"马上说"打断它。
/// 输入框聚焦或带着卡片时露出要带上的卡片与同步提示。发出后清空，请求马上贴到它上方。回答弹窗在问题卡上，不在这里。
/// 同步到不了 Mac 时不能发，写明原因。
private struct ReplyBar: View {
    let session: PiSessionState
    @Binding var draft: Navigation.Outbox?
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @State private var text = ""
    @State private var sending = false
    @State private var sentCount = 0
    @FocusState private var focused: Bool

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var content: String {
        [draft?.content, trimmed.nonEmpty].compactMap { $0 }.joined(separator: "\n\n")
    }

    /// 第一个是发送按钮的方式，第二个（忙时的马上说）是次级按钮。
    private var modes: [DeliveryMode] {
        MacDelivery.modes(for: session, hasImages: !CardText(content).images.isEmpty)
    }

    private var reachable: Bool { services.reachesPiHost }
    private var canSend: Bool { !content.isEmpty && reachable && !sending }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if focused || draft != nil, !reachable { SyncHint(status: services.syncStatus) }
            if let draft { attachment(draft) }
            HStack(alignment: .bottom, spacing: 8) {
                TextField(placeholder, text: $text, axis: .vertical)
                    .lineLimit(1...5)
                    .focused($focused)
                    .accessibilityLabel("回复")
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(palette.paper, in: .rect(cornerRadius: 20, style: .continuous))
                if modes.count > 1, let interrupt = modes.last {
                    Button("马上说") { send(interrupt) }
                        .buttonStyle(.plain)
                        .font(.subheadline.weight(.medium)).foregroundStyle(canSend ? palette.ink : palette.ink3)
                        .padding(.horizontal, 12).frame(minHeight: 40)
                        .background(palette.fill, in: .capsule)
                        .disabled(!canSend)
                        .accessibilityHint("打断它正在做的")
                }
                Button { if let mode = modes.first { send(mode) } } label: {
                    Image(systemName: "arrow.up").font(.body.weight(.semibold))
                        .frame(width: 40, height: 40)
                }
                .prominentButton()
                .clipShape(.circle)
                .disabled(!canSend)
                .accessibilityLabel(modes.first == .followUp ? "等它做完再说" : "发送")
                .sensoryFeedback(.success, trigger: sentCount)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glass(in: .rect(cornerRadius: 24))
        .animation(Motion.quick, value: focused)
    }

    /// 忙时的提示写明发送按钮的默认：等它做完再说。
    private var placeholder: String {
        if draft != nil { return "补一句（可不填）" }
        return modes.first == .followUp ? "等它做完再说…" : "回复 \(session.title)"
    }

    /// 带上的卡片或任务：标题、图片数，可移除。
    private func attachment(_ outbox: Navigation.Outbox) -> some View {
        let card = CardText(outbox.content)
        return HStack(spacing: 10) {
            Image(systemName: outbox.task == nil ? "rectangle.on.rectangle" : "checklist").foregroundStyle(palette.ink3)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(card.title.nonEmpty ?? "图片").font(.subheadline.weight(.semibold)).foregroundStyle(palette.ink).lineLimit(1)
                if !card.images.isEmpty {
                    Text("\(card.images.count) 张图片").font(.caption).foregroundStyle(palette.ink3)
                }
            }
            Spacer(minLength: 8)
            Button("不带了", systemImage: "xmark") { withAnimation(Motion.quick) { draft = nil } }
                .labelStyle(.iconOnly).foregroundStyle(palette.ink3)
                .frame(width: 44, height: 44).contentShape(.rect)
        }
        .padding(.leading, 12)
        .background(palette.paper, in: .rect(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("带上：\(card.title.nonEmpty ?? "图片")")
    }

    private func send(_ mode: DeliveryMode) {
        let content = content, card = draft?.card, task = draft?.task
        guard canSend else { return }
        sending = true
        workspace.attempt {
            defer { sending = false }
            _ = try await services.requestMacDelivery(content, to: session, mode: mode, card: card, task: task)
            text = ""
            draft = nil
            focused = false
            sentCount += 1
        }
    }
}

/// "发到 Mac"：先选会话（卡片所在项目的在前，已结束的不列），选好进入会话页，内容预填在回复框里。
struct SessionPicker: View {
    let outbox: Navigation.Outbox
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(Navigation.self) private var navigation
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var palette
    @State private var sessions: [PiSessionState]?

    var body: some View {
        NavigationStack {
            List {
                if let sessions {
                    if sessions.isEmpty {
                        ContentUnavailableView(
                            "Mac 上没有运行中的 Pi 会话", systemImage: "terminal",
                            description: Text("在 Mac 上启动 Pi 后再试"))
                            .listRowBackground(Color.clear)
                    } else {
                        Section("发给哪个会话") {
                            ForEach(sessions) { session in row(session) }
                        }
                    }
                }
            }
            .deskBackground()
            .navigationTitle("发到 Mac")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭", systemImage: "xmark", role: .cancel) { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
        .observing(services.store, [.piSessionStates], into: $sessions, onError: workspace.fail) { [project = outbox.project] store in
            try store.piSessionPage(.live).items.map(\.state)
                .sorted { ($0.projectID == project && project != nil ? 1 : 0, $0.state.urgency) > ($1.projectID == project && project != nil ? 1 : 0, $1.state.urgency) }
        }
    }

    private func row(_ session: PiSessionState) -> some View {
        let project = workspace.catalog?.project(session.projectID)
        return Button { navigation.openSession(session.id, draft: outbox) } label: {
            HStack(spacing: 12) {
                PiStateDot(state: session.state)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(session.title).font(.body.weight(.medium)).foregroundStyle(palette.ink)
                        if project != nil, project?.id == outbox.project {
                            Text("本项目").font(.caption2.weight(.medium)).foregroundStyle(palette.ink2)
                                .padding(.horizontal, 6).padding(.vertical, 2).background(palette.fill, in: .capsule)
                        }
                    }
                    PiActivityLine(lead: [PiPlace.name(of: session, project: project), session.state.label])
                        .foregroundStyle(session.state == .known(.waitingForUser) ? palette.attention : palette.ink3)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(palette.ink3)
                    .accessibilityHidden(true)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .listRowBackground(palette.paper)
    }
}
#endif

#if os(iOS)
extension View {
    /// Pi 页与会话近况页：显示期间算作"正在看 Pi"，手机按 3 秒主动拉，状态与近况是活的（见 `AppServices.pollingCadence`）。
    func countsAsPiViewer() -> some View { modifier(PiViewing()) }
}

private struct PiViewing: ViewModifier {
    @Environment(AppServices.self) private var services

    func body(content: Content) -> some View {
        content
            .onAppear { services.piViewers += 1 }
            .onDisappear { services.piViewers -= 1 }
    }
}
#endif
