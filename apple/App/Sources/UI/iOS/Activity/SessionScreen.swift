#if os(iOS)
import CueStore
import CueText
import SwiftUI

/// 一个 Pi 会话的近况（Pi 页的会话行、锁屏通知、"发到 Mac"选好会话后都进这里）：上面是近况，
/// 底部是发过去的最新一条请求与回复框。
/// 会话记录在页面打开期间被删掉（结束 7 天后）时，照样显示最后一次看到的近况，回复框换成说明。
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
                    Text("它可能已经结束很久，记录已经清掉了")
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
                let alive = digest?.session != nil && session.state != .known(.ended)
                // 发出后最新一条就在回复框上方，长回答下也看得到送达情况
                VStack(spacing: 8) {
                    DeliveryStack(deliveries: digest?.deliveries ?? [], session: alive ? session : nil)
                    ReplyBar(session: session, alive: alive, draft: $draft)
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

/// 回复框：平时收成一行（输入 + 当前方式的短名 + 发送），不挡近况；输入框聚焦、有字或带着卡片时展开，
/// 露出要带上的卡片、发送方式与说明、同步提示。发出后清空，请求马上贴到它上方。回答弹窗在问题卡上，不在这里。
/// 同步到不了 Mac、会话已结束时不能发，写明原因。
private struct ReplyBar: View {
    let session: PiSessionState
    let alive: Bool
    @Binding var draft: Navigation.Outbox?
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @State private var text = ""
    @State private var chosenMode: DeliveryMode?
    @State private var sending = false
    @State private var sentCount = 0
    @FocusState private var focused: Bool

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var content: String {
        [draft?.content, trimmed.nonEmpty].compactMap { $0 }.joined(separator: "\n\n")
    }

    private var modes: [DeliveryMode] {
        MacDelivery.modes(for: session.state, hasImages: !CardText(content).images.isEmpty)
    }

    /// 会话状态变了（比如开始干活）时，原来选的方式可能不再可用：换成当前可用的第一个。
    private var mode: DeliveryMode? {
        chosenMode.flatMap { modes.contains($0) ? $0 : nil } ?? modes.first
    }

    private var reachable: Bool { services.syncStatus.reachesMac }
    private var expanded: Bool { focused || !text.isEmpty || draft != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !alive {
                Text("会话已结束，回复发不到它；在 Mac 的终端重新运行 pi 开新会话").font(.footnote).foregroundStyle(palette.ink3)
            } else {
                if expanded, !reachable { SyncHint(status: services.syncStatus) }
                if let draft { attachment(draft) }
                HStack(alignment: .bottom, spacing: 8) {
                    TextField(placeholder, text: $text, axis: .vertical)
                        .lineLimit(expanded ? 1...5 : 1...1)
                        .focused($focused)
                        .accessibilityLabel("回复")
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(palette.paper, in: .rect(cornerRadius: 20, style: .continuous))
                    if !expanded, let mode {
                        // 收起时只露当前方式的短名，点它展开
                        Button(mode.label) { focused = true }
                            .buttonStyle(.plain)
                            .font(.footnote.weight(.medium)).foregroundStyle(reachable ? palette.ink2 : palette.ink3)
                            .padding(.horizontal, 10).frame(minHeight: 40)
                            .background(palette.fill, in: .capsule)
                            .accessibilityHint("展开发送方式")
                    }
                    Button(action: send) {
                        Image(systemName: "arrow.up").font(.body.weight(.semibold))
                            .frame(width: 40, height: 40)
                    }
                    .prominentButton()
                    .clipShape(.circle)
                    .disabled(content.isEmpty || mode == nil || !reachable || sending)
                    .accessibilityLabel("发送")
                    .sensoryFeedback(.success, trigger: sentCount)
                }
                if expanded, let mode {
                    VStack(alignment: .leading, spacing: 4) {
                        if modes.count > 1 {
                            Picker("方式", selection: Binding(get: { mode }, set: { chosenMode = $0 })) {
                                ForEach(modes, id: \.self) { Text($0.label).tag($0) }
                            }
                            .scalingPickerStyle()
                            .fixedSize()
                        }
                        if let explanation = mode.explanation {
                            Text(explanation).font(.footnote).foregroundStyle(palette.ink3)
                        }
                    }
                    .transition(.opacity)
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glass(in: .rect(cornerRadius: 24))
        .animation(Motion.quick, value: expanded)
    }

    private var placeholder: String {
        draft == nil ? "回复 \(session.title)" : "补一句（可不填）"
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

    private func send() {
        let content = content, card = draft?.card, task = draft?.task
        guard !content.isEmpty, let mode, reachable, !sending else { return }
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
            try store.piSessionStates()
                .filter { $0.state != .known(.ended) }
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
