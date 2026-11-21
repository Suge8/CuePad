import CueStore
import SwiftUI

/// 会话页三端同一份。栏头按布局：宽屏是栏头那一排（`WideSessionTitle`，右键是 `SessionMenuItems`），窄屏是页头（"⋯" 里同一份菜单）。
/// 平台的差别：Mac 把本机在线的会话换上桥上的实时状态（栏头与对话，同步记录按节流写、会落后几秒）、回复框与菜单晚两帧建、回复框的托底；
/// 手机翻看历史时回复框收成胶囊，窄屏的页头只在手机。
/// 按会话重建（`.id`）：读到的那一份、跟随与滚动都属于这一个会话，同一栏里换会话不带过去（iPad 主栏换会话时页的位置不变）。
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
    /// 页头的预览钮与它长开的那一页（`LivePhoneCover`）。
    @Namespace private var zoom
    #endif
    @State private var stored: SessionDigest?
    /// 记录读不出来的那一下（同步中途）仍照最后一次读到的样子排，不闪成"找不到"。
    @State private var lastSeen: SessionState?
    @State private var task: SessionTaskLink?
    @State private var follow = ChatFollow()
    /// Mac 上标题、状态与最新的对话先出；回复框、问题卡与菜单晚两帧（`NextFrame`）：它们的建立（文本视图、玻璃、菜单）占点击回合的一半，不在点的那一圈里。
    @State private var secondary = Self.dockAtOnce

    /// `seed`：推入前读好的这一页，首帧即用，之后以 Store 的观察流为准。
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
                // 栏头是浮在对话上的玻璃：对话从它下面滑过去、到窗口边为止，不在栏头下沿裁掉或盖一层淡出
                reply(session, digest)
                    .safeAreaPadding(.top, Chrome.band)
                    #if os(iOS)
                    .scrollEdgeEffectHidden(true, for: .top)
                    #endif
                    .overlay(alignment: .top) {
                        if let session {
                            WideSessionTitle(title: digest?.title(at: services.speech) ?? session.title, project: digest?.project,
                                             ended: session.staysEnded(by: digest?.delivery, at: services.speech), column: column)
                                .contextMenu { if secondary { menu(session, digest) } }
                        }
                    }
            } else {
                #if os(iOS)
                // 右边只有活预览那一颗（有页面可看时），与左边的返回对称；完成、休眠这些点标题，等你的那件在看板与会话条上也有
                // 对话滑到页头的玻璃下面，只有状态栏那一条由窗口的模糊盖着（`StatusBarBlur`），页头这一截不再垫系统的淡出
                reply(session, digest).scrollEdgeEffectHidden(true, for: .top).floatingHeader(.verbatim(digest?.title(at: services.speech) ?? session?.title ?? ""), hidden: !follow.showsHeader, reveal: { follow.reveal() }) {
                    if let session { menu(session, digest) }
                } detail: {
                    if ending(digest) {
                        Text("正在休眠…").font(Typography.caption).foregroundStyle(palette.ink3)
                    } else if let session {
                        SessionSubtitle(session: session, delivery: digest?.delivery, undelivered: Chat.undeliveredNote(digest?.undelivered(at: services.speech) ?? 0))
                    }
                } trailing: {
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
        // 看得见（这一页在导航最上面、场景在前台）才问 Mac 有没有页面可看
        .task(id: liveWatch(session)) { if let watch = liveWatch(session) { await services.liveRemote.watch(watch.sessionID, on: watch.host) } }
        #endif
        // 打开就记一下（通知随即收掉，`AlertCenter.dismissSeen`）；之后干着活时不记：每换一步都记一下就是每步一次同步，停下、离开时记的那一下已盖住干活的那段
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
        // 在线的会话不等资料库就有状态：栏头先出来，对话等读到库再排
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

    /// 发出时回复框收回一行，对话不被系统先拉下来再滑上去。
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
                        // 留出回复框平时的高度，它到了时对话不被顶上去
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

    /// 手机上翻看历史时回复框收成一条胶囊（`compact`）。
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
