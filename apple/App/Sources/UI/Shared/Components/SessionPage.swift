import CueStore
import SwiftUI

struct SessionPage: View {
    let route: SessionRoute
    var column = Workspace.Column.main

    init(_ route: SessionRoute, column: Workspace.Column = .main) {
        self.route = route
        self.column = column
    }

    var body: some View {
        SessionPageBody(route, column: column).id(route.id)
    }
}

private struct SessionPageBody: View {
    let id: UUID
    let sessionID: String?
    let column: Workspace.Column
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    #if os(iOS)
    @Environment(\.scenePhase) private var phase
    @Namespace private var zoom
    #endif
    @State private var stored: SessionDigest?
    @State private var lastSeen: SessionState?
    @State private var task: SessionTaskLink?
    @State private var follow = ChatFollow()
    @State private var secondary = Self.dockAtOnce

    init(_ route: SessionRoute, column: Workspace.Column) {
        id = route.id
        sessionID = route.sessionID
        self.column = column
        _stored = State(initialValue: route.seed)
        _lastSeen = State(initialValue: route.seed?.session)
    }

    var body: some View {
        let digest = shown
        let session = digest?.session ?? lastSeen
        Group {
            if workspace.layout == .wide {
                reply(session, digest)
                    .safeAreaPadding(.top, Chrome.band)
                    .overlay(alignment: .top) {
                        if let session {
                            WideSessionTitle(title: digest?.title(at: services.speech) ?? session.title, project: digest?.project,
                                             ended: session.staysEnded(by: digest?.delivery, at: services.speech), tier: digest?.tier.map { CueTierButton(sessionID: session.sessionID, tier: $0) }, column: column)
                                .contextMenu { if secondary { menu(session, digest) } }
                        }
                    }
            } else {
                #if os(iOS)
                reply(session, digest).floatingHeader(.verbatim(digest?.title(at: services.speech) ?? session?.title ?? ""), hidden: !follow.showsHeader, reveal: { follow.reveal() }) {
                    if let session { menu(session, digest) }
                } detail: {
                    if ending(digest) {
                        Text("正在休眠…").font(Typography.caption).foregroundStyle(palette.ink3)
                    } else if let session {
                        SessionSubtitle(session: session, delivery: digest?.delivery, undelivered: Chat.undeliveredNote(digest?.undelivered(at: services.speech) ?? 0))
                    }
                } trailing: {
                    if let session, let tier = digest?.tier { CueTierButton(sessionID: session.sessionID, tier: tier, compact: true) }
                    LivePhoneTool(session: id, zoom: zoom)
                }
                .livePhoneCover(id, zoom: zoom)
                #endif
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.desk)
        #if os(macOS)
        .task {
            await NextFrame.wait()
            await NextFrame.wait()
            secondary = true
        }
        #endif
        .observing(services.store, id: DigestKey(id: id, sessionID: sessionID ?? lastSeen?.sessionID), into: $stored, onError: workspace.fail) {
            [id, sessionID = sessionID ?? lastSeen?.sessionID] store in try SessionDigest.read(id, sessionID: sessionID, from: store)
        }
        .observing(services.store, id: SessionTaskLink.Key(session: session?.sessionID, project: session?.projectID), into: $task, onError: workspace.fail) {
            [session] store in try SessionTaskLink.read(sessionID: session?.sessionID ?? "", project: session?.projectID, from: store)
        }
        .onChange(of: stored, initial: true) { _, stored in
            if let session = stored?.session { lastSeen = session }
        }
        .requestsTranscript(stored)
        #if os(iOS)
        .debugDrivesHeader($follow)
        .task(id: liveWatch(session)) { if let watch = liveWatch(session) { await services.liveRemote.watch(watch.sessionID, on: watch.host) } }
        #endif
        .task(id: session?.sessionID) { if let session { markSeen(session) } }
        .task(id: session?.stateSince) { if let session, !session.runtimeState.isWorking { markSeen(session) } }
        .onDisappear { if let session { markSeen(session) } }
    }

    #if os(iOS)
    private struct LiveWatch: Equatable {
        let sessionID: String
        let host: String
    }

    private func liveWatch(_ session: SessionState?) -> LiveWatch? {
        guard let session, phase == .active, workspace.shownSessions.contains(where: { $0.id == id }) else { return nil }
        return LiveWatch(sessionID: session.sessionID, host: session.hostID)
    }
    #endif

    private func markSeen(_ session: SessionState) {
        let store = services.store, id = session.sessionID
        workspace.attempt { try await store.mark(.sessionSeen(id)) }
    }

    private var shown: SessionDigest? {
        #if os(macOS)
        let live = sessionID.flatMap { services.bridge.slot(sessionID: $0)?.session }
        guard let live else { return stored }
        let project = workspace.catalog?.project(workspace.sendState.projects[live.id])
        return (stored ?? SessionDigest(session: nil, project: nil, deliveries: [])).live(live, hostID: services.hostID, project: project)
        #else
        stored
        #endif
    }

    private func ending(_ digest: SessionDigest?) -> Bool {
        MacDelivery.endProgress(digest?.deliveries ?? [], at: services.speech)?.inTransit == true
    }

    private func menu(_ session: SessionState, _ digest: SessionDigest?) -> SessionMenuItems {
        SessionMenuItems(session: session, place: SessionPlace.menuTitle(of: session, project: digest?.project), task: task, pin: digest?.task, ending: ending(digest))
    }

    private func reply(_ session: SessionState?, _ digest: SessionDigest?) -> some View {
        FloatingReply {
            chat(session, digest)
        } reply: {
            if let session {
                Group {
                    #if os(macOS)
                    if secondary {
                        dock(session, digest)
                    } else {
                        Color.clear.frame(height: ComposerMetrics.openOneLine)
                    }
                    #else
                    VStack(spacing: 0) {
                        DockedCard(workspace.ideaDock.flatMap { $0.session == id ? $0 : nil }) { IdeaDockCard(dock: $0) }
                        dock(session, digest)
                    }
                    #endif
                }
                #if os(macOS)
                .replyTray()
                .padding(.horizontal, Spacing.page)
                #else
                .padding(.horizontal, Spacing.group)
                #endif
                .frame(maxWidth: Spacing.reading)
                .animation(Motion.fade, value: session.question)
            }
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private func dock(_ session: SessionState, _ digest: SessionDigest?) -> SessionDock {
        #if os(macOS)
        SessionDock(session: session, digest: digest, revealNote: { follow.seek($0.entry) }) { follow.sent() }
        #else
        SessionDock(session: session, digest: digest, compact: !follow.atNewest, revealNote: { follow.seek($0.entry) }) { follow.sent() }
        #endif
    }

    /// 读到库再整段出现：对话从空变满不算"新内容"，不逐条淡入。读到前也排一个真的视图：这一页的 `.task` 与读库的 `.observing` 要等视图出现才启动。
    private func chat(_ session: SessionState?, _ digest: SessionDigest?) -> some View {
        Group {
            if stored != nil, let digest {
                if let session {
                    #if os(macOS)
                    SessionChat(session: session, digest: digest, readingWidth: Spacing.reading, inset: Spacing.page, follow: $follow,
                                slot: sessionID.flatMap { services.bridge.slot(sessionID: $0) })
                        .replyNotes(session: session.id, messages: digest.messages)
                    #else
                    SessionChat(session: session, digest: digest, readingWidth: Spacing.reading, inset: Spacing.page, follow: $follow)
                        .replyNotes(session: session.id, messages: digest.messages)
                    #endif
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

extension SessionPageBody {
    #if os(macOS)
    fileprivate static let dockAtOnce = false
    #else
    fileprivate static let dockAtOnce = true
    #endif
}

private struct DigestKey: Equatable {
    var id: UUID
    var sessionID: String?
}
