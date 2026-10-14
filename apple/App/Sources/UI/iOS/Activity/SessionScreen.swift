#if os(iOS)
import CueStore
import SwiftUI

/// 一个 Pi 会话的对话（Agent 页的会话行、锁屏通知、"发到 Mac"选好会话后都进这里），聊天式：
/// 顶上与返回钮同排的一块玻璃：会话名，在跑或要你注意时下面一行小字写状态（`PiSessionSubtitle`，歇着时只有会话名）；中间是对话（`SessionChat`，与 Mac 同一个），打开停在最新；
/// 底部是浮在对话上的回复框（标签栏收起，回复框独占底部），等你确认时问题卡固定在它上方；对话滚到顶栏与回复框的玻璃后面都清楚可见。已结束的会话也能回复（Mac 在后台把它恢复起来再送达）。
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
    @State private var confirmingEnd: PiSessionState?
    @State private var renaming: PiSessionState?
    private static let barGap: CGFloat = 8

    /// `seed`：推入前读好的这一页（`Navigation.openSession`），首帧即用，之后以 Store 的观察流为准。
    init(id: UUID, seed: SessionDigest? = nil) {
        self.id = id
        _digest = State(initialValue: seed)
        _lastSeen = State(initialValue: seed?.session)
    }

    /// 阅读宽度上限：iPad 上长回答一行不超过它。
    private static let readingWidth: CGFloat = 640
    private var session: PiSessionState? { digest?.session ?? lastSeen }
    /// 此刻要显示的结束（还在路上的，或没能结束、之后没再发过别的），与 Agent 页同一条规则。
    private var shownEnd: DeliveryRequest? { DeliveryRequest.shownEnd(in: digest?.deliveries ?? []) }

    var body: some View {
        Group {
            // 读到库再整段出现：对话从空变满不算"新内容"，不逐条淡入。
            // 读到前也要有一个真的视图（不能什么都不排）：这一页里的 .task 要等视图出现才启动，读库的 .observing 就挂在它上面；
            // 没有首帧时（点通知、点横幅）整页没有任何视图，读库不启动，页面永远空白
            if let digest {
                if let session {
                    SessionChat(session: session, digest: digest, readingWidth: Self.readingWidth, inset: 16, follow: $follow)
                } else {
                    EmptyState(mascot: .search, title: "找不到这个会话", message: "Mac 上这个会话的文件可能已经删掉了")
                        .padding(.horizontal, 16)
                        .frame(maxHeight: .infinity)
                }
            } else {
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .scrollDismissesKeyboard(.interactively)
        // 看历史时标题与"⋯"让开（返回钮留着），点标题原来的位置唤出，回到最新自动出现（`ChatFollow.showsHeader`）
        .floatingHeader(digest?.title ?? session?.title ?? "", hidden: !follow.showsHeader, reveal: { follow.reveal() },
                        explanation: session.flatMap { PiShown($0).explanation }) {
            if shownEnd?.isOpen == true {
                Text("正在结束…").font(.caption).foregroundStyle(palette.ink3)
            } else if let session {
                HStack(spacing: 4) {
                    if digest?.cueFollows == true { CueFollowMark() }
                    PiSessionSubtitle(session: session, undelivered: PiChat.undeliveredNote(digest?.undelivered ?? 0), cueFollows: digest?.cueFollows ?? false)
                }
            }
        } trailing: {
            if let session {
                Menu {
                    // 所在与"后台"不挤在顶栏里：点"⋯"时写在最上面
                    if let title = PiPlace.menuTitle(of: session, project: digest?.project) { Section { } header: { Text(title) } }
                    if MacDelivery.canRename(session) {
                        Button("重命名", systemImage: "pencil") { renaming = session }.disabled(!services.reachesPiHost)
                    }
                    if session.canEnd {
                        Button("结束会话", systemImage: "stop.circle", role: .destructive) { confirmingEnd = session }
                            .disabled(shownEnd?.isOpen == true)
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .accessibilityLabel("更多")
                // 确认框挂在"⋯"上，系统从这颗钮弹出；挂在整页上会指向页面中间随便一处
                .endSession($confirmingEnd)
            }
        }
        .renameSession($renaming)
        .safeAreaBar(edge: .bottom, spacing: 0) {
            if let session {
                VStack(spacing: 8) {
                    PiQuestionDock(session: session, deliveries: digest?.deliveries ?? [])
                    if let reason = shownEnd?.failure, session.state != .known(.ended) {
                        Callout(status: .failed, text: "没能结束：\(reason)", docked: true)
                    }
                    // 读库完成、确认记录不在了才换成说明；推入时带着首帧状态、还没读到时照常是回复框
                    if digest != nil, digest?.session == nil {
                        Text("这个会话已经不在了，发不到它").font(.footnote).foregroundStyle(palette.ink3)
                    } else {
                        // 在看历史时收成短胶囊，点它展开（不挪正在读的内容）
                        PiReplyBar(
                            session: session, config: digest?.config, compact: !follow.atNewest,
                            stopping: MacDelivery.stopping(session, deliveries: digest?.deliveries ?? []),
                            commandProgress: MacDelivery.commandProgress(digest?.deliveries ?? []),
                            queued: PiChat.queued(digest?.deliveries ?? [], messages: digest?.messages ?? []),
                            recall: PiChat.lastSaid(digest?.messages ?? [])
                        ) { follow.jumpToNewest() }
                    }
                }
                .padding(.horizontal, 12).padding(.bottom, Self.barGap)
                .frame(maxWidth: Self.readingWidth)
                .frame(maxWidth: .infinity)
                .animation(Motion.quick, value: session.question)
                // 浮在整片对话上、自己也写着字：玻璃里垫实底，背后的字透不过来（`GlassInk.solid`）
                .environment(\.composerInk, .solid)
            }
        }
        .ownsBottomEdge()
        .observing(services.store, id: DigestKey(id: id, sessionID: lastSeen?.sessionID),
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
    /// 很久以前的会话没有对话：请它所在的 Mac 补写一次（同步不通时等通了再说）。
    private func askForTranscriptIfNeeded() {
        guard !askedForTranscript, let digest, let session = digest.session, services.reachesPiHost,
              PiChat.needsTranscript(session, messages: digest.messages), !digest.fetchingTranscript else { return }
        askedForTranscript = true
        workspace.attempt { _ = try await services.requestTranscript(of: session) }
    }
}

private struct DigestKey: Equatable {
    var id: UUID
    var sessionID: String?
}

#endif

#if os(iOS)
extension View {
    /// Agent 页与会话近况页：显示期间算作"正在看 Pi"，手机按 3 秒主动拉，状态与近况是活的（见 `AppServices.pollingCadence`）。
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
