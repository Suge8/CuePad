#if os(iOS)
import CueStore
import CueText
import SwiftUI

/// 一个 Pi 会话的对话（Pi 页的会话行、锁屏通知、"发到 Mac"选好会话后都进这里），聊天式：
/// 顶上一行会话名，下面一行小字"所在 · 状态 · 计时"，有子代理时再一行小标签；中间是对话（`PiConversation`），打开停在最新；
/// 底部是回复框，等你确认时问题卡固定在它上方。已结束的会话也能回复（Mac 在后台把它恢复起来再送达）。
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
    @State private var draft: Navigation.Outbox?
    @State private var askedForTranscript = false

    /// 阅读宽度上限：iPad 上长回答一行不超过它。
    private static let readingWidth: CGFloat = 640

    private var session: PiSessionState? { digest?.session ?? lastSeen }
    private var fetchingTranscript: Bool {
        digest?.deliveries.contains { $0.mode == .known(.transcript) && $0.isOpen } == true
    }

    var body: some View {
        ChatScroll(followKey: PiConversation.followKey(session: session, messages: digest?.messages ?? [], deliveries: digest?.deliveries ?? [])) {
            if let session {
                VStack(spacing: 14) {
                    if fetchingTranscript {
                        Label("正在从 Mac 取对话…", systemImage: "arrow.down.circle").font(.footnote).foregroundStyle(palette.ink3)
                    }
                    PiConversation(session: session, messages: digest?.messages ?? [], deliveries: digest?.deliveries ?? [])
                }
                .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 16)
                // iPad 上一行不超过阅读宽度，居中
                .frame(maxWidth: Self.readingWidth)
                .frame(maxWidth: .infinity)
            } else if digest != nil {
                ContentUnavailableView {
                    Label("找不到这个会话", systemImage: "waveform.path.ecg")
                } description: {
                    Text("Mac 上这个会话的文件可能已经删掉了")
                }
                .padding(.top, 60)
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .background(palette.desk)
        .navigationTitle(session?.title ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let session {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 1) {
                        Text(session.title).font(.subheadline.weight(.semibold)).foregroundStyle(palette.ink).lineLimit(1)
                        PiSessionSubtitle(session: session, project: digest?.project)
                    }
                }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if let subagents = session?.subagents, !subagents.isEmpty {
                PiSubagentChips(subagents: subagents)
                    .padding(.horizontal, 16).padding(.vertical, 6)
                    .frame(maxWidth: Self.readingWidth)
                    .frame(maxWidth: .infinity)
                    .background(palette.desk.opacity(0.94))
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let session {
                VStack(spacing: 8) {
                    PiQuestionDock(session: session, deliveries: digest?.deliveries ?? [])
                    if digest?.session != nil {
                        ReplyBar(session: session, draft: $draft)
                    } else {
                        Text("这个会话已经不在了，发不到它").font(.footnote).foregroundStyle(palette.ink3)
                    }
                }
                .padding(.horizontal, 8).padding(.bottom, 8)
                .frame(maxWidth: Self.readingWidth)
                .frame(maxWidth: .infinity)
                .animation(Motion.quick, value: session.question)
            }
        }
        .onAppear { if draft == nil { draft = navigation.takeDraft(for: id) } }
        .observing(services.store, SessionDigest.tables, id: DigestKey(id: id, sessionID: lastSeen?.sessionID),
                   into: $digest, onError: workspace.fail) { [id, lastSeen] store in
            try SessionDigest.read(id, sessionID: lastSeen?.sessionID, from: store)
        }
        .onChange(of: digest) { _, digest in
            if let session = digest?.session { lastSeen = session }
            askForTranscriptIfNeeded()
        }
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

/// 回复框：发送是输入框里右下角的圆钮。Pi 空闲时直接发；正忙时点它是等它做完再说，长按选马上说。
/// 等你确认时按问题类型（`MacDelivery.reply`）：文字型问题它就是作答框；选择、确认型收成一行"先在上面作答"，
/// 这里答不了的写明要在 Mac 上回答——都不发自由文本（Pi 不答完题不会去看，消息会一直挂着）。
/// 输入框聚焦或带着卡片时露出要带上的卡片与同步提示。发出后清空，请求马上贴到它上方。同步到不了 Mac 时不能发，写明原因。
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

    private var reply: PiReply { MacDelivery.reply(to: session, hasImages: !CardText(content).images.isEmpty) }

    /// 发消息时可用的方式：第一个是点发送的方式，第二个（忙时的马上说）在长按菜单里。
    private var modes: [DeliveryMode] {
        if case .message(let modes) = reply { modes } else { [] }
    }

    private var answering: PiQuestion? {
        if case .answer(let question) = reply { question } else { nil }
    }

    private var reachable: Bool { services.reachesPiHost }
    private var canSend: Bool { !(answering == nil ? content : trimmed).isEmpty && reachable && !sending }

    var body: some View {
        switch reply {
        case .answerAbove: notice("先在上面作答", systemImage: "arrow.up")
        case .unanswerable: notice("这个问题要在 Mac 上回答", systemImage: "desktopcomputer")
        case .message, .answer: composer
        }
    }

    /// 等你确认、不能发自由文本时收成的一行。
    private func notice(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.subheadline).foregroundStyle(palette.ink2)
            .padding(.horizontal, 18).frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
            .glass(in: .rect(cornerRadius: 30))
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if focused || draft != nil, !reachable { SyncHint(status: services.syncStatus) }
            if let draft, answering == nil { attachment(draft) }
            HStack(alignment: .bottom, spacing: 4) {
                TextField(placeholder, text: $text, axis: .vertical)
                    .lineLimit(1...5)
                    .focused($focused)
                    .accessibilityLabel("回复")
                    .padding(.leading, 14).padding(.vertical, 11)
                sendControl.padding(.trailing, 2)
            }
            .background(palette.paper, in: .rect(cornerRadius: 22, style: .continuous))
            .sensoryFeedback(.success, trigger: sentCount)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glass(in: .rect(cornerRadius: 30))
        .animation(Motion.quick, value: focused)
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
        if draft != nil { return "补一句（可不填）" }
        return modes.first == .followUp ? "\(DeliveryMode.followUp.label) · 长按发送可\(DeliveryMode.steer.label)" : "回复 \(session.title)"
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

    private func answer() {
        let value = PiAnswerValue.text(trimmed)
        guard canSend else { return }
        sending = true
        workspace.attempt {
            defer { sending = false }
            _ = try await services.answer(value, to: session)
            text = ""
            focused = false
            sentCount += 1
        }
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

/// 输入框里的圆形发送钮：能发时墨色实心，不能发时淡。
private struct SendGlyph: View {
    let enabled: Bool
    @Environment(\.palette) private var palette

    var body: some View {
        Image(systemName: "arrow.up").font(.callout.weight(.bold))
            .foregroundStyle(enabled ? palette.paper : palette.ink3)
            .frame(width: 34, height: 34)
            .background(enabled ? palette.ink : palette.fill, in: .circle)
            .frame(width: 44, height: 44)
            .contentShape(.circle)
            .animation(Motion.quick, value: enabled)
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
                            "Mac 上没有运行中的 Pi 会话", systemImage: "waveform.path.ecg",
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
