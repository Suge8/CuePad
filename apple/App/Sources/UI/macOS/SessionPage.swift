#if os(macOS)
import CuePi
import CueStore
import SwiftUI

extension SessionState {
    /// 状态记录按节流写，会落后几秒，界面读这个。摘要（问与答、这一轮已做完的步骤）不在桥上，取同步记录里的。正自己换上新扩展的（`upgrading`）桥上读不到状态，为 nil：界面照同步记录里最后一次读到的样子。
    static func live(_ session: CuePi.Session, hostID: String, projectID: UUID?, recap: Recap?) -> SessionState? {
        guard !session.upgrading else { return nil }
        return SessionState(
            id: recordID(sessionID: session.sessionID), sessionID: session.sessionID, hostID: hostID, title: session.displayName,
            projectID: projectID, state: .known(session.state), detail: session.detail, folder: session.cwd.lastPathComponent,
            lastPrompt: recap?.lastPrompt, lastReply: recap?.lastReply, question: session.question, notify: nil,
            stateSince: session.stateSince, busySince: session.busySince, createdAt: session.stateSince, modifiedAt: session.stateSince,
            launchToken: session.launchToken, hosted: session.hosted, subagents: session.subagents,
            pendingPrompt: recap?.pendingPrompt, pendingTools: recap?.pendingTools, model: session.model, thinking: session.thinking, fast: session.fast, context: session.context,
            agent: .known(session.agent), turnStartedAt: session.turnStartedAt, answeredAt: recap?.answeredAt, failure: session.failure.map(Open.known), bootID: SystemBoot.id, runtimeUntil: .distantFuture)
    }
}

extension CuePi.Session {
    /// 跳转至少要激活终端应用，所以后台托管的与没报终端的（OpenCode 的服务）没有。
    var canJump: Bool { !hosted && terminal.bundleID != nil }
}

extension SessionDigest {
    static func read(sessionID: String, from store: isolated CueStore) throws -> SessionDigest {
        try read(SessionState.recordID(sessionID: sessionID), sessionID: sessionID, from: store)
    }

    func live(_ session: CuePi.Session?, hostID: String, project: Project?) -> SessionDigest {
        guard let session,
              let state = SessionState.live(
                session, hostID: hostID, projectID: project?.id ?? self.session?.projectID, recap: self.session.map(\.recap))
        else { return self }
        var digest = self
        digest.session = state
        digest.catalog = AgentCatalog(host: hostID, models: session.availableModels, commands: session.commands, at: session.stateSince)
        if let project { digest.project = project }
        return digest
    }
}

struct SessionPage: View {
    let sessionID: String
    let column: Workspace.Column
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @State private var stored: SessionDigest?
    @State private var task: SessionTaskLink?
    @State private var follow = ChatFollow()

    /// 标题、状态与最新的对话先出；回复框、问题卡与"⋯"晚两帧（`NextFrame`）：它们的建立（文本视图、玻璃、菜单）占点击回合的一半，不在点的那一圈里。
    @State private var secondary = false

    var body: some View {
        let slot = services.pi.slot(sessionID: sessionID)
        let live = slot?.session
        let project = live.flatMap { workspace.catalog?.project(workspace.sendState.projects[$0.id]) }
        let digest = (stored ?? SessionDigest(session: nil, project: nil, deliveries: [])).live(live, hostID: services.hostID, project: project)
        VStack(spacing: 0) {
            if let session = digest.session {
                WideSessionTitle(title: digest.title(at: services.speech) ?? session.title, project: digest.project?.shownName, column: column)
                    .contextMenu {
                        if let state = headerState(digest, menu: secondary, task: task) { SessionMenuItems(state: state) }
                    }
                FloatingReply {
                    // 数据读到前不排对话：在线会话不等资料库就有状态，先排出来是空对话，数据到了再长成整段
                    if stored != nil {
                        SessionChat(
                            session: session, digest: digest, readingWidth: Spacing.reading, inset: Spacing.page, follow: $follow, slot: slot)
                            .replyNotes(session: session.id, messages: digest.messages)
                    }
                } reply: {
                    VStack(spacing: Spacing.item) {
                        if secondary {
                            SessionDock(session: session, digest: digest, revealNote: { follow.seek($0.entry) }) { follow.sent() }
                        } else {
                            // 留出回复框平时的高度，它到了时对话不被顶上去
                            Color.clear.frame(height: ComposerMetrics.openOneLine)
                        }
                    }
                    .replyTray()
                    .padding(.horizontal, Spacing.page)
                    .frame(maxWidth: Spacing.reading)
                    .animation(Motion.fade, value: session.question)
                }
                .fadesUnderHead()
            } else if stored != nil {
                EmptyState(mascot: .empty, title: "找不到这个会话", message: "Mac 上这个会话的文件可能已经删掉了")
                    .frame(maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.desk)
        .task {
            await NextFrame.wait()
            await NextFrame.wait()
            secondary = true
        }
        .observing(services.store, id: sessionID, into: $stored,
                   onError: workspace.fail) { [sessionID] store in
            try SessionDigest.read(sessionID: sessionID, from: store)
        }
        .observing(services.store, id: TaskKey(session: sessionID, project: digest.session?.projectID), into: $task,
                   onError: workspace.fail) { [sessionID, project = digest.session?.projectID] store in
            try SessionTaskLink.read(sessionID: sessionID, project: project, from: store)
        }
        .requestsTranscript(stored)
        .task(id: digest.session?.stateSince) { if let session = digest.session { services.settings.markSeen(session) } }
    }

    private func headerState(_ digest: SessionDigest, menu: Bool, task: SessionTaskLink?) -> SessionHeader.State? {
        guard let session = digest.session else { return nil }
        return SessionHeader.State(
            session: session, delivery: digest.delivery, title: digest.title(at: services.speech) ?? session.title, undelivered: Chat.undeliveredNote(digest.undelivered(at: services.speech)),
            ending: DeliveryRequest.shownEnd(in: digest.deliveries, at: services.speech)?.inTransit == true, place: SessionPlace.menuTitle(of: session, project: digest.project),
            pin: digest.task, showsHeader: follow.showsHeader, showsMenu: menu, task: task)
    }

    private struct TaskKey: Equatable {
        var session: String
        var project: UUID?
    }
}

extension View {
    /// 不给 `press` 是侧栏里的一行，给了是卡片或圆钮的按压。
    func sessionLink(_ sessionID: String, press: Press? = nil) -> some View { modifier(SessionLink(sessionID: sessionID, press: press)) }
}

private struct SessionLink: ViewModifier {
    let sessionID: String
    let press: Press?
    @Environment(Workspace.self) private var workspace

    func body(content: Content) -> some View {
        let opened = workspace.shownSessions.contains { $0.sessionID == sessionID }
        let button = Button {
            workspace.searching = false
            workspace.openSession(SessionState.recordID(sessionID: sessionID), sessionID: sessionID,
                                  in: NSEvent.modifierFlags.contains(.command) ? .beside : .main)
        } label: {
            content.contentShape(.rect)
        }
        Group {
            if let press { button.buttonStyle(PressStyle(press)) } else { button.buttonStyle(RowStyle(selected: opened)) }
        }
        .accessibilityAddTraits(opened ? .isSelected : [])
        .accessibilityHint("打开会话")
        .draggable(DraggedSession(sessionID: sessionID))
    }
}

extension Workspace {
    /// 本机在线的会话换上桥上的实时状态（同步记录按节流写，会落后几秒）；其余原样。
    func withLiveState(_ session: SessionState) -> SessionState {
        guard let live = services.pi.session(sessionID: session.sessionID) else { return session }
        return .live(live, hostID: services.hostID, projectID: sendState.projects[live.id] ?? session.projectID, recap: session.recap) ?? session
    }

    func withLiveState(_ item: SessionListItem) -> SessionListItem {
        var item = item
        item.state = withLiveState(item.state)
        return item
    }

    /// 跳到会话所在的终端；只能大致定位或失败时说一句。
    func jumpToTerminal(_ id: CuePi.Session.ID) {
        Task {
            do {
                let result = try await services.jumpToTerminal(id)
                if let note = result.note { say(Dotted(note), tone: result.precision == .failed ? .failure : .done) }
            } catch {
                fail(error)
            }
        }
    }
}
#endif
