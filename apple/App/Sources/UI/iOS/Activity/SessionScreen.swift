#if os(iOS)
import CueStore
import SwiftUI

struct SessionScreen: View {
    let id: UUID
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @State private var digest: SessionDigest?
    @State private var taskLink: SessionTaskLink?
    @State private var lastSeen: PiSessionState?
    @State private var follow = ChatFollow()

    /// `seed`：推入前读好的这一页，首帧即用，之后以 Store 的观察流为准。
    init(id: UUID, seed: SessionDigest? = nil) {
        self.id = id
        _digest = State(initialValue: seed)
        _lastSeen = State(initialValue: seed?.session)
    }

    private static let readingWidth = Spacing.reading
    private var session: PiSessionState? { digest?.session ?? lastSeen }
    private var shownEnd: Speech.Trip? { DeliveryRequest.shownEnd(in: digest?.deliveries ?? [], at: services.speech) }

    var body: some View {
        // 发出时回复框收回一行，对话不被系统先拉下来再滑上去。
        FloatingReply {
            chat
        } reply: {
            if let session {
                SessionDock(session: session, digest: digest, compact: !follow.atNewest, revealNote: { follow.seek($0.entry) }) { follow.sent() }
                    .padding(.horizontal, Spacing.group)
                    .frame(maxWidth: Self.readingWidth)
                    .animation(Motion.fade, value: session.question)
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .floatingHeader(.verbatim(digest?.title(at: services.speech) ?? session?.title ?? ""), hidden: !follow.showsHeader, reveal: { follow.reveal() }) {
            if shownEnd?.inTransit == true {
                Text("正在结束…").font(Typography.caption).foregroundStyle(palette.ink3)
            } else if let session {
                PiSessionSubtitle(session: session, delivery: digest?.delivery, undelivered: PiChat.undeliveredNote(digest?.undelivered(at: services.speech) ?? 0))
            }
        } trailing: {
            if let session {
                Menu {
                    if let title = PiPlace.menuTitle(of: session, project: digest?.project) { Section { } header: { Text(title) } }
                    if let taskLink { SessionTaskBindItems(session: session, link: taskLink) }
                    SessionActions(session: session, task: digest?.task, ending: shownEnd?.inTransit == true)
                } label: {
                    Image(.more)
                }
                .accessibilityLabel("更多")
            }
        }
        .observing(services.store, id: DigestKey(id: id, sessionID: lastSeen?.sessionID),
                   into: $digest, onError: workspace.fail) { [id, lastSeen] store in
            try SessionDigest.read(id, sessionID: lastSeen?.sessionID, from: store)
        }
        .observing(services.store, id: SessionTaskLink.Key(session: session?.sessionID, project: session?.projectID),
                   into: $taskLink, onError: workspace.fail) { [session] store in
            try SessionTaskLink.read(sessionID: session?.sessionID ?? "", project: session?.projectID, from: store)
        }
        .onChange(of: digest, initial: true) { _, digest in
            if let session = digest?.session { lastSeen = session }
        }
        .requestsTranscript(digest)
        .debugDrivesHeader($follow)
        .task(id: session?.stateSince) { if let session { services.settings.markSeen(session) } }
        .onDisappear { if let session { services.settings.markSeen(session) } }
    }

    private var chat: some View {
        Group {
            // 读到库再整段出现：对话从空变满不算"新内容"，不逐条淡入。
            // 读到前也要有一个真的视图（不能什么都不排）：这一页里的 .task 要等视图出现才启动，读库的 .observing 就挂在它上面；
            // 没有首帧时（点通知、点横幅）整页没有任何视图，读库不启动，页面永远空白
            if let digest {
                if let session {
                    SessionChat(session: session, digest: digest, readingWidth: Self.readingWidth, inset: Spacing.page, follow: $follow)
                        .replyNotes(session: session.id, messages: digest.messages)
                } else {
                    EmptyState(mascot: .search, title: "找不到这个会话", message: "Mac 上这个会话的文件可能已经删掉了")
                        .padding(.horizontal, Spacing.page)
                        .frame(maxHeight: .infinity)
                }
            } else {
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct DigestKey: Equatable {
    var id: UUID
    var sessionID: String?
}

#endif

#if os(iOS)
extension View {
    func countsAsPiViewer() -> some View { modifier(PiViewing()) }
}

private struct PiViewing: ViewModifier {
    @Environment(AppServices.self) private var services
    @Environment(\.pageActive) private var active
    @State private var appeared = false
    @State private var counted = false

    func body(content: Content) -> some View {
        content
            .onAppear { appeared = true }
            // 页拆掉时 onChange 不再来：在这里收回
            .onDisappear {
                appeared = false
                count(false)
            }
            .onChange(of: appeared && active, initial: true) { _, on in count(on) }
    }

    private func count(_ on: Bool) {
        guard on != counted else { return }
        counted = on
        services.piViewers += on ? 1 : -1
    }
}
#endif
