#if os(iOS)
import CueStore
import SwiftUI

/// 一个 Pi 会话的对话（Agent 页的会话行、锁屏通知、"发到 Mac"选好会话后都进这里），聊天式：
/// 顶上与返回钮同排的一块玻璃：会话名，下面一行小字"所在 · 状态 · 计时"；中间是对话（`PiConversation`，子代理列在末尾的进展下），打开停在最新；
/// 底部是回复框（标签栏收起，回复框独占底部），等你确认时问题卡固定在它上方。已结束的会话也能回复（Mac 在后台把它恢复起来再送达）。
/// 很久以前的会话没有对话时请 Mac 补写，补写中写一句"正在从 Mac 取对话…"。
/// 会话记录在页面打开期间被删掉（Mac 上的会话文件被删）时，照样显示最后一次看到的内容，底部换成说明。
struct SessionScreen: View {
    let id: UUID
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(Navigation.self) private var navigation
    @Environment(\.palette) private var palette
    @State private var digest: SessionDigest?
    /// 最后一次读到的会话记录：记录被删后仍显示它。
    @State private var lastSeen: PiSessionState?
    @State private var askedForTranscript = false
    @State private var follow = ChatFollow()
    @State private var confirmingEnd = false
    /// 刚从刻度滑条跳到的那条你的话，短暂描一圈。
    @State private var highlight: UUID?

    /// `seed`：推入前读好的这一页（`Navigation.openSession`），首帧即用，之后以 Store 的观察流为准。
    init(id: UUID, seed: SessionDigest? = nil) {
        self.id = id
        _digest = State(initialValue: seed)
        _lastSeen = State(initialValue: seed?.session)
    }

    /// 阅读宽度上限：iPad 上长回答一行不超过它。
    private static let readingWidth: CGFloat = 640
    private var session: PiSessionState? { digest?.session ?? lastSeen }
    /// 回复框的草稿在 `Navigation`（离开会话再回来还在）。
    private var draft: Binding<ComposerDraft> {
        Binding(get: { navigation.replyDraft(for: id) }, set: { navigation.setReplyDraft($0, for: id) })
    }
    /// 此刻要显示的结束（还在路上的，或没能结束、之后没再发过别的），与 Agent 页同一条规则。
    private var shownEnd: DeliveryRequest? { DeliveryRequest.shownEnd(in: digest?.deliveries ?? []) }
    private var fetchingTranscript: Bool {
        digest?.deliveries.contains { $0.mode == .known(.transcript) && $0.isOpen } == true
    }

    var body: some View {
        ChatScroll(
            followKey: PiConversation.followKey(session: session, messages: digest?.messages ?? [], deliveries: digest?.deliveries ?? []),
            follow: $follow
        ) {
            // 读到库再整段出现：对话从空变满不算"新内容"，不逐条淡入
            if let digest {
                if let session {
                    PiConversation(session: session, messages: digest.messages, deliveries: digest.deliveries)
                        .padding(.horizontal, 16).padding(.vertical, 14)
                        // iPad 上一行不超过阅读宽度，居中
                        .frame(maxWidth: Self.readingWidth)
                        .frame(maxWidth: .infinity)
                } else {
                    ContentUnavailableView {
                        Label("找不到这个会话", systemImage: "waveform.path.ecg")
                    } description: {
                        Text("Mac 上这个会话的文件可能已经删掉了")
                    }
                    .padding(.top, 60)
                    .chatRow()
                }
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .environment(\.chatHighlight, highlight)
        .overlay(alignment: .trailing) {
            let marks = ChatScrubber.marks(PiChat.entries(digest?.messages ?? []))
            if !marks.isEmpty {
                ChatScrubber(marks: marks, scrolling: follow.scrolling) { id in
                    follow.jump(to: id)
                    highlight = id
                }
            }
        }
        .task(id: highlight) {
            guard highlight != nil else { return }
            try? await Task.sleep(for: .seconds(1.2))
            highlight = nil
        }
        .overlay {
            if fetchingTranscript {
                Label("正在从 Mac 取对话…", systemImage: "arrow.down.circle").font(.footnote).foregroundStyle(palette.ink3)
            }
        }
        // 往历史里翻时顶栏让开，往最新那边回滑一小段或回到最新就回来（同 Safari 的阅读，`ChatFollow.showsHeader`）
        .floatingHeader(session?.title ?? "", hidden: !follow.showsHeader) {
            if shownEnd?.isOpen == true {
                Text("正在结束…").font(.caption).foregroundStyle(palette.ink3)
            } else if let session {
                PiSessionSubtitle(session: session, project: digest?.project, delivery: digest?.latestDelivery)
            }
        } trailing: {
            if let session, session.state != .known(.ended) {
                Menu {
                    Button("结束会话", systemImage: "stop.circle", role: .destructive) { confirmingEnd = true }
                        .disabled(shownEnd?.isOpen == true)
                } label: {
                    Image(systemName: "ellipsis")
                }
                .accessibilityLabel("更多")
            }
        }
        .confirmationDialog("结束这个会话？", isPresented: $confirmingEnd, titleVisibility: .visible) {
            Button("结束会话", role: .destructive, action: end)
        } message: {
            Text("对话会保留，再给它发消息会在后台恢复")
        }
        .safeAreaBar(edge: .bottom, spacing: 0) {
            if let session {
                VStack(spacing: 8) {
                    PiQuestionDock(session: session, deliveries: digest?.deliveries ?? [])
                    if let reason = shownEnd?.failure, session.state != .known(.ended) {
                        Callout(tint: palette.failure, symbol: "exclamationmark.circle.fill", text: "没能结束：\(reason)")
                    }
                    // 读库完成、确认记录不在了才换成说明；推入时带着首帧状态、还没读到时照常是回复框
                    if digest != nil, digest?.session == nil {
                        Text("这个会话已经不在了，发不到它").font(.footnote).foregroundStyle(palette.ink3)
                    } else {
                        // 在看历史时收成短胶囊，点它展开（不挪正在读的内容）
                        ReplyBar(session: session, config: digest?.config, draft: draft, compact: !follow.atNewest)
                    }
                }
                .padding(.horizontal, 12).padding(.bottom, 8)
                .frame(maxWidth: Self.readingWidth)
                .frame(maxWidth: .infinity)
                .animation(Motion.quick, value: session.question)
            }
        }
        .ownsBottomEdge()
        .observing(services.store, SessionDigest.tables, id: DigestKey(id: id, sessionID: lastSeen?.sessionID),
                   into: $digest, onError: workspace.fail) { [id, lastSeen] store in
            try SessionDigest.read(id, sessionID: lastSeen?.sessionID, from: store)
        }
        .onChange(of: digest, initial: true) { _, digest in
            if let session = digest?.session { lastSeen = session }
            askForTranscriptIfNeeded()
        }
        // 开着这页就算看过：进来、Pi 每次换状态、离开时都记一下（列表里的"有新回复"据此消失）
        .task(id: session?.stateSince) { if let session { services.settings.markSeen(session) } }
        .onDisappear { if let session { services.settings.markSeen(session) } }
    }

    /// 请会话所在的 Mac 结束它；进度与失败都从发给它的结束请求推出（`shownEnd`）。
    private func end() {
        guard let session else { return }
        Task { await workspace.end(session) }
    }

    /// 很久以前的会话没有对话：请它所在的 Mac 补写一次（同步不通时等通了再说）。
    private func askForTranscriptIfNeeded() {
        guard !askedForTranscript, let digest, let session = digest.session, services.reachesPiHost,
              PiChat.needsTranscript(session, messages: digest.messages), !fetchingTranscript else { return }
        askedForTranscript = true
        workspace.attempt { _ = try await services.requestTranscript(of: session) }
    }
}

private struct DigestKey: Equatable {
    var id: UUID
    var sessionID: String?
}

/// 回复框：共用的 `Composer`，去处是这个 Pi 会话（＋ 选卡片、相册、拍照；有内容时右下角出现圆形发送钮）。
/// Pi 空闲时直接发；正忙时点发送钮是等它做完再说，长按选马上说。含图片时也只有这两种（`MacDelivery.reply`）。
/// 等你确认时按问题类型：文字型问题它就是作答框（只收文字）；选择、确认型收成一行"先在上面作答"，
/// 这里答不了的写明要在 Mac 上回答——都不发自由文本（Pi 不答完题不会去看，消息会一直挂着）。
/// 同步到不了 Mac 时不能发，聚焦后写明原因。发出后清空，请求马上贴到对话末尾。
private struct ReplyBar: View {
    let session: PiSessionState
    /// 模型与思考强度的显示值（在线会话聚焦时放在工具排"＋"的右边）。
    let config: PiConfigShown?
    @Binding var draft: ComposerDraft
    /// 在看历史：收成短胶囊。
    let compact: Bool
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @State private var sending = false
    @State private var sentCount = 0
    @FocusState private var focused: Bool

    private var reply: PiReply { MacDelivery.reply(to: session, hasImages: draft.hasImages) }

    /// 发消息时可用的方式：第一个是点发送的方式，第二个（忙时的马上说）在长按菜单里。
    private var modes: [DeliveryMode] {
        if case .message(let modes) = reply { modes } else { [] }
    }

    private var answering: PiQuestion? {
        if case .answer(let question) = reply { question } else { nil }
    }

    private var accepts: ComposerKinds { answering == nil ? [.images, .cards] : [] }
    private var reachable: Bool { services.reachesPiHost }
    private var canSend: Bool { !draft.isEmpty(accepting: accepts) && reachable && !sending }

    /// 单行时是胶囊：高 = 字行 + 上下各 14，发送钮 36 居中。
    private static let radius: CGFloat = 25

    var body: some View {
        switch reply {
        case .answerAbove: notice("先在上面作答", systemImage: "arrow.up")
        case .unanswerable: notice("这个问题要在 Mac 上回答", systemImage: "desktopcomputer")
        case .message, .answer:
            Composer(
                draft: $draft, prompt: compact ? "回复 \(session.title)" : placeholder, label: "回复", focus: $focused, accepts: accepts,
                cardsFrom: session.projectID, compact: compact,
                header: {
                    if !reachable { SyncHint(status: services.syncStatus).padding(.horizontal, 18).padding(.top, 12) }
                    if focused, let failure = config?.failure {
                        Text("没换成：\(failure)").font(.caption).foregroundStyle(palette.failure).lineLimit(2)
                            .padding(.horizontal, 18).padding(.top, 12)
                    }
                },
                tools: {
                    // 只给在线会话：已结束的不为换模型去唤醒 Pi
                    if let config, session.state != .known(.ended), !session.models.isEmpty {
                        PiConfigTools(session: session, shown: config)
                    }
                },
                send: { sendControl }
            )
            .sensoryFeedback(.success, trigger: sentCount)
        }
    }

    /// 等你确认、不能发自由文本时收成的一行。
    private func notice(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.subheadline).foregroundStyle(palette.ink2)
            .padding(.horizontal, 18).frame(maxWidth: .infinity, minHeight: 2 * Self.radius, alignment: .leading)
            .glass(in: .rect(cornerRadius: Self.radius, style: .continuous))
    }

    @ViewBuilder private var sendControl: some View {
        if answering != nil {
            Button(action: answer) { SendGlyph(enabled: canSend) }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .accessibilityLabel("回答")
        } else if modes.count > 1, let queued = modes.first, let interrupt = modes.last {
            Menu {
                Button { send(interrupt) } label: {
                    Label(interrupt.label, systemImage: "bolt")
                    if let explanation = interrupt.explanation { Text(explanation) }
                }
            } label: {
                SendGlyph(enabled: canSend)
            } primaryAction: {
                send(queued)
            }
            .menuIndicator(.hidden)
            .buttonStyle(.plain)
            .disabled(!canSend)
            .accessibilityLabel(queued.label)
            .accessibilityHint("\(queued.explanation ?? "")；长按可以\(interrupt.label)，\(interrupt.explanation ?? "")")
        } else {
            Button { if let mode = modes.first { send(mode) } } label: { SendGlyph(enabled: canSend) }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .accessibilityLabel("发送")
        }
    }

    /// 忙时的提示写明点发送是什么、长按是什么；作答时写明在回答问题。
    private var placeholder: String {
        if answering != nil { return "在这里回答上面的问题" }
        if draft.attachment != nil || !draft.images.isEmpty { return "补一句（可不填）" }
        return modes.first == .followUp ? "\(DeliveryMode.followUp.label) · 长按发送可\(DeliveryMode.steer.label)" : "回复 \(session.title)"
    }

    private func answer() {
        let value = PiAnswerValue.text(draft.text.trimmingCharacters(in: .whitespacesAndNewlines))
        guard canSend else { return }
        sending = true
        workspace.attempt {
            defer { sending = false }
            _ = try await services.answer(value, to: session)
            draft.text = ""
            focused = false
            sentCount += 1
        }
    }

    private func send(_ mode: DeliveryMode) {
        let sent = draft
        guard canSend else { return }
        sending = true
        workspace.attempt {
            defer { sending = false }
            _ = try await services.requestMacDelivery(sent, to: session, mode: mode)
            draft = ComposerDraft()
            focused = false
            sentCount += 1
        }
    }
}

/// 回复框工具排里"＋"右边的两颗小圆钮：模型（芯片）、思考强度（灯泡），点开是菜单，菜单头写当前值；思考强度只列当前模型支持的。
/// 换了之后图标轻轻跳动直到送达，显示值由会话记录与配置请求推出（`SessionDigest.config`），没换成的原因写在输入框头部。
private struct PiConfigTools: View {
    let session: PiSessionState
    let shown: PiConfigShown
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 0) {
            Menu {
                Section("模型 · \(shown.model?.name ?? "未知")") {
                    Picker("模型", selection: Binding(get: { shown.model?.key }, set: { if let key = $0 { configure(PiConfig(model: key)) } })) {
                        ForEach(session.models) { model in Text(model.name).tag(Optional(model.key)) }
                    }
                }
            } label: {
                glyph("cpu")
            }
            .accessibilityLabel("模型")
            .accessibilityValue(shown.model?.name ?? "未知")
            if let levels = shown.model?.thinkingLevels, !levels.isEmpty {
                Menu {
                    Section("思考强度 · \(shown.thinking?.label ?? "未知")") {
                        Picker("思考强度", selection: Binding(get: { shown.thinking }, set: { if let level = $0 { configure(PiConfig(thinking: level)) } })) {
                            ForEach(levels, id: \.self) { level in Text(level.label).tag(Optional(level)) }
                        }
                    }
                } label: {
                    glyph("lightbulb.max")
                }
                .accessibilityLabel("思考强度")
                .accessibilityValue(shown.thinking?.label ?? "未知")
            }
        }
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
    }

    /// 比"＋"小一号的圆：看得见的 30，点得到的 44，与"＋"同一排居中。
    private func glyph(_ systemImage: String) -> some View {
        Image(systemName: systemImage).font(.footnote.weight(.semibold))
            .foregroundStyle(palette.ink2)
            .symbolEffect(.pulse, isActive: shown.pending)
            .frame(width: 30, height: 30)
            .background(palette.fill, in: .circle)
            .frame(width: 44, height: Composer<EmptyView, EmptyView, EmptyView>.slot)
            .contentShape(.circle)
    }

    private func configure(_ config: PiConfig) {
        workspace.attempt { _ = try await services.configure(config, for: session) }
    }
}

extension PiThinkingLevel {
    /// 思考强度给人看的名字。
    var label: String {
        switch self {
        case .off: "关"
        case .minimal: "最低"
        case .low: "低"
        case .medium: "中"
        case .high: "高"
        case .xhigh: "很高"
        case .max: "最高"
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
    @State private var sessions: [PiSessionListItem]?

    var body: some View {
        NavigationStack {
            List {
                if let sessions {
                    if sessions.isEmpty {
                        ContentUnavailableView(
                            "Mac 上没有运行中的 Agent 会话", systemImage: "waveform.path.ecg",
                            description: Text("在 Mac 的终端运行 pi 后再试"))
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
        .observing(services.store, [.piSessionStates, .deliveryRequests], into: $sessions, onError: workspace.fail) { [project = outbox.project] store in
            try store.piSessionPage(.live).items
                .sorted { ($0.state.projectID == project && project != nil ? 1 : 0, $0.state.state.urgency) > ($1.state.projectID == project && project != nil ? 1 : 0, $1.state.state.urgency) }
        }
    }

    private func row(_ item: PiSessionListItem) -> some View {
        let session = item.state
        let project = workspace.catalog?.project(session.projectID)
        let shown = services.settings.shown(item)
        return Button { navigation.openSession(session.id, sessionID: session.sessionID, draft: outbox, store: services.store) } label: {
            HStack(spacing: 12) {
                PiStateDot(shown: shown)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(session.title).font(.body.weight(.medium)).foregroundStyle(palette.ink)
                        if project != nil, project?.id == outbox.project {
                            Text("本项目").font(.caption2.weight(.medium)).foregroundStyle(palette.ink2)
                                .padding(.horizontal, 6).padding(.vertical, 2).background(palette.fill, in: .capsule)
                        }
                    }
                    PiActivityLine(lead: [PiPlace.name(of: session, project: project), shown.label])
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
    /// Agent 页与会话近况页：显示期间算作"正在看 Pi"，手机按 3 秒主动拉，状态与近况是活的（见 `AppServices.pollingCadence`）；
    /// 给了 `session`（会话页）时也告诉通知中心正看着它，这个会话的通知在前台不弹横幅。
    func countsAsPiViewer(session: UUID? = nil) -> some View { modifier(PiViewing(session: session)) }
}

private struct PiViewing: ViewModifier {
    let session: UUID?
    @Environment(AppServices.self) private var services
    @Environment(PiAlertCenter.self) private var alerts

    func body(content: Content) -> some View {
        content
            .onAppear {
                services.piViewers += 1
                if let session { alerts.beginViewing(session) }
            }
            .onDisappear {
                services.piViewers -= 1
                if let session { alerts.endViewing(session) }
            }
    }
}
#endif
