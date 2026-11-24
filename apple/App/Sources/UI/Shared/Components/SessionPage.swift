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
    @State private var derived = ChatDerived()
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
        let chat = derived.refresh(stored == nil ? nil : digest, at: services.speech)
        Group {
            if workspace.layout == .wide {
                reply(session, digest, chat)
                    .safeAreaPadding(.top, Chrome.band)
                    .overlay(alignment: .top) {
                        if let session {
                            PaneHead {
                                PaneTitle(
                                    crumb: .init(digest?.project, in: workspace), title: digest?.title(at: services.speech) ?? session.title,
                                    handle: workspace.pane(in: column), close: workspace.isSplit ? { workspace.closeColumn(column) } : nil,
                                    marks: { SessionPaneMarks(ended: session.staysEnded(by: digest?.delivery, at: services.speech), tier: digest?.tier.map { CueTierButton(sessionID: session.sessionID, tier: $0) }) },
                                    tools: { if let route = workspace.session(in: column) { LivePreviewTool(session: route) } })
                            }
                            .contextMenu { if secondary { menu(session, digest) } }
                        } else if stored != nil, workspace.isSplit {
                            PaneHead { PaneTitle(title: String(localized: "会话"), handle: workspace.pane(in: column), close: { workspace.closeColumn(column) }) }
                        }
                    }
            } else {
                #if os(iOS)
                reply(session, digest, chat)
                    .modifier(SessionHeader(
                        follow: $follow, title: digest?.title(at: services.speech) ?? session?.title ?? "",
                        menu: session.map { menu($0, digest, tier: digest?.tier) },
                        detail: session.map { SessionSubtitle(session: $0, delivery: digest?.delivery, tier: digest?.tier, ending: ending(digest)) },
                        trailing: LivePhoneTool(session: id, zoom: zoom)))
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
            guard let stored, let session = stored.session else { return }
            lastSeen = session
            workspace.launching.observed(SendingTarget(session)) { id in
                stored.deliveries.contains { $0.id == id } || stored.messages.last { $0.deliveryID == id } != nil
            }
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

    private func menu(_ session: SessionState, _ digest: SessionDigest?, tier: CueTier? = nil) -> SessionMenuItems {
        SessionMenuItems(session: session, place: SessionPlace.menuTitle(of: session, project: digest?.project), task: task, pin: digest?.task, ending: ending(digest), tier: tier)
    }

    private func reply(_ session: SessionState?, _ digest: SessionDigest?, _ chat: ChatDerived.Facts) -> some View {
        FloatingReply {
            self.chat(session, digest, chat)
        } reply: {
            if let session {
                Group {
                    #if os(macOS)
                    if secondary {
                        dock(session, digest, chat)
                    } else {
                        Color.clear.frame(height: ComposerMetrics.openOneLine)
                    }
                    #else
                    VStack(spacing: 0) {
                        DockedCard(workspace.ideaDock.flatMap { $0.session == id ? $0 : nil }) { IdeaDockCard(dock: $0) }
                        dock(session, digest, chat).modifier(CompactAway(follow: $follow))
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

    private func dock(_ session: SessionState, _ digest: SessionDigest?, _ chat: ChatDerived.Facts) -> SessionDock {
        SessionDock(session: session, digest: digest, chat: chat, revealNote: { follow.seek($0.entry) }) { follow.sent() }
    }

    /// 读到库再整段出现：对话从空变满不算"新内容"，不逐条淡入。读到前也排一个真的视图：这一页的 `.task` 与读库的 `.observing` 要等视图出现才启动。
    private func chat(_ session: SessionState?, _ digest: SessionDigest?, _ chat: ChatDerived.Facts) -> some View {
        Group {
            if stored != nil, let digest {
                if let session {
                    #if os(macOS)
                    SessionChat(session: session, digest: digest, readingWidth: Spacing.reading, inset: Spacing.page, chat: chat, follow: $follow,
                                slot: sessionID.flatMap { services.bridge.slot(sessionID: $0) })
                        .replyNotes(session: session.id, messages: digest.messages)
                    #else
                    SessionChat(session: session, digest: digest, readingWidth: Spacing.reading, inset: Spacing.page, chat: chat, follow: $follow)
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

#if os(iOS)
/// 修饰器重算时它包着的内容不跟着重算：跟随在滚动的每次起止、越线时都变，只让这一层读它。
private struct SessionHeader<Items: View, Detail: View, Trailing: View>: ViewModifier {
    @Binding var follow: ChatFollow
    let title: String
    let menu: Items?
    let detail: Detail?
    let trailing: Trailing

    func body(content: Content) -> some View {
        content.floatingHeader(.verbatim(title), hidden: !follow.showsHeader, reveal: { follow.reveal() }) {
            if let menu { menu }
        } detail: {
            if let detail { detail }
        } trailing: {
            trailing
        }
    }
}

private struct CompactAway: ViewModifier {
    @Binding var follow: ChatFollow

    func body(content: Content) -> some View { content.environment(\.replyCompact, !follow.atNewest) }
}
#endif

private struct DigestKey: Equatable {
    var id: UUID
    var sessionID: String?
}

/// 会话胶囊里名字后面的记号：已休眠、交给 Cue 的那一档。
private struct SessionPaneMarks: View {
    let ended: Bool
    let tier: CueTierButton?
    @Environment(\.palette) private var palette

    var body: some View {
        Group {
            if ended {
                HStack(spacing: Spacing.tight) {
                    Image(.ended).readerHidden(true)
                    Text(SessionShown(status: .ended).label)
                }
                .font(Typography.caption).foregroundStyle(palette.ink3).lineLimit(1).fixedSize()
                .padding(.trailing, PaneCell.pad)
                .transition(.opacity)
            }
            if let tier { tier.frame(minWidth: PaneCell.side, minHeight: PaneCell.side) }
        }
        .animation(Motion.fade, value: ended)
    }
}
