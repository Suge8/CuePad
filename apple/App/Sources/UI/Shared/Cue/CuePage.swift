import CueStore
import SwiftUI

struct CuePage: View {
    var grounded = true
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    #if os(iOS)
    @Environment(\.headerHost) private var headerHost
    #endif
    @State private var thread: CueThread?
    @State private var follow = ChatFollow()
    @State private var opened: PreviewOpening?
    @State private var docking = false
    @State private var dockedCard: String?
    @State private var seen: [UUID: Date] = [:]
    @State private var stage: Bool?
    @State private var brief: CueBrief?
    @State private var stagedAt = Date.now
    @State private var stageInView = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let readingWidth = Spacing.reading
    static let inset = Spacing.page

    private var cue: CueWatch { workspace.cue }
    private func card(_ thread: CueThread) -> String? { CueWaitDock.current(in: thread.waiting, asking: workspace.cueAsking)?.id }
    private func sinking(_ thread: CueThread) -> Bool { dockedCard != nil && card(thread) == nil }
    private var catchingUp: Bool { services.syncing.isCatchingUp(on: cue.hostID) }
    var body: some View {
        page
            .observing(services.store, into: $thread, onError: workspace.fail) { try CueThread.read(from: $0) }
            .previewPresenter($opened, reply: .cue)
            .panel(isPresented: Bindable(cue).showsMemory) { CueMemoryPage() }
            .panel(isPresented: Bindable(cue).showsSchedules) { CueSchedulePage() }
            .modifier(CueViewing(thread: thread, catchingUp: catchingUp, seen: $seen, follow: $follow, staged: staged) {
                guard DebugHooks.preset.cueStage == nil else { return }
                stage = true
                stagedAt = .now
                follow.jumpToNewest()
            })
            .onAppear { if stage == nil { stage = DebugHooks.preset.cueStage ?? CueStage.opens(left: services.settings.cueLeft, at: .now) } }
            .onChange(of: thread.flatMap(card), initial: true) { dockedCard = $1 }
            .onChange(of: thread != nil, initial: true) { _, loaded in
                guard loaded else { return }
                DebugHooks.mark("cue")
            }
    }

    #if os(macOS)
    private var page: some View {
        FloatingReply {
            chat.frame(maxWidth: .infinity, maxHeight: .infinity)
        } reply: {
            bottom()
                .replyTray(!(staged && stageInView))
                .padding(.horizontal, Self.inset)
                .frame(maxWidth: Self.readingWidth)
        }
        .background { if grounded { palette.desk } }
    }
    #else
    private var page: some View {
        FloatingReply {
            chat
        } reply: {
            bottom()
                .padding(.horizontal, Spacing.group)
                .frame(maxWidth: Self.readingWidth)
        }
        .scrollDismissesKeyboard(.interactively)
        .fadesUnderHead(headerHost == .panel && !(staged && stageInView))
        .floatingHeader(.verbatim(cue.name), height: CueHeader.height, hasPanel: true, center: { CueHeader(staged: staged && stageInView) }) { EmptyView() }
    }
    #endif

    private var railInset: CGFloat { workspace.layout == .narrow ? SessionRail.phoneWidth + Spacing.item - Self.inset : 0 }

    private var staged: Bool { stage == true && cue.canHear && thread?.rows.isEmpty == false }

    /// 读不出来时也排一个真的视图：读库的订阅挂在页上，等视图出现才启动。
    @ViewBuilder private var chat: some View {
        Group {
            if let thread, !thread.rows.isEmpty {
                if stage != nil {
                    conversation(thread)
                } else {
                    Color.clear
                }
            } else if thread != nil {
                CueWelcomeChat().padding(.horizontal, railInset)
            } else {
                Color.clear
            }
        }
    }

    private func conversation(_ thread: CueThread) -> some View {
        let rows = thread.rows
        return ChatColumn(
            followKey: FollowKey(thread, live: cue.presence.shown != nil), readingWidth: Self.readingWidth, inset: Self.inset + railInset, follow: $follow,
            marks: thread.marks, ids: rows.map(\.id), paging: Self.paging(thread),
            holding: catchingUp || docking || sinking(thread),
            arrival: rows.last.flatMap { CueRow.arrives($0, swapsInPlace: services.cueOnDutyHere) ? $0.id : nil }
        ) { window in
            let lastYou = thread.messages.last { $0.author == .known(.you) }?.id
            ChatStack(spacing: 0) {
                ChatSegments(items: rows, window: window, size: Self.segment, spare: Self.spare) { items in
                    CueSegment(rows: items.map { item in
                        CueRow(
                            row: item, shots: thread.shots[item.id] ?? [],
                            joined: thread.joined.contains(item.id),
                            stamp: thread.stamps[item.id], delivered: item.id == lastYou,
                            unread: thread.unread.contains(item.id), settled: item.id != rows.last?.id, opened: $opened, seen: $seen)
                    })
                    .equatable()
                }
                if staged {
                    stageView(thread)
                } else {
                    CueEnding(
                        newestSaid: thread.messages.last { $0.author == .known(.cue) }?.createdAt, joined: rows.last?.speaker == .leading)
                }
            }
            #if os(iOS)
            .environment(\.inlineTextSelection, false)
            #endif
        }
    }

    private func stageView(_ thread: CueThread) -> some View {
        let replies = cue.now.items.filter { $0.kind == .reply }, said = CueBrief.said(thread)
        let room = CueBrief.limit - (said == nil ? 0 : 1)
        return CueStage(
            beat: cue.beat, status: cue.now.quietLine, brief: (said.map { [$0] } ?? []) + (brief?.lines ?? []),
            period: CueStage.Period(at: stagedAt, dark: palette.dark), open: openBrief)
            .onScrollVisibilityChange(threshold: 0.4) { stageInView = $0 }
            .observing(services.store, id: [String(room)] + replies.map(\.id), into: $brief, onError: workspace.fail) { [replies] in
                try CueBrief.read(replies: replies, room: room, from: $0)
            }
            .transition(.opacity)
    }

    private func openBrief(_ line: CueBrief.Line) {
        switch line.go {
        case .session(let session): workspace.openSession(SessionState.recordID(sessionID: session), sessionID: session)
        case .message(let id): follow.seek(id)
        }
    }

    private struct FollowKey: Equatable {
        var count: Int
        var last: Date?
        var waiting: Int
        var live: Bool

        init(_ thread: CueThread, live: Bool) {
            count = thread.messages.count
            last = thread.messages.last?.modifiedAt
            waiting = thread.waiting.count
            self.live = live
        }
    }

    private func bottom() -> some View {
        VStack(spacing: 0) {
            if let thread {
                CueWaitDock(waiting: thread.waiting, asking: workspace.cueAsking, shots: thread.shots, open: { opened = $0 }, moving: $docking)
                    .padding(.horizontal, railInset)
                if !thread.rows.isEmpty, !cue.canHear { CueWelcome(intro: false).fixedSize(horizontal: false, vertical: true).padding(.bottom, Spacing.item).transition(.opacity) }
            }
            #if os(macOS)
            CueVoicePanel()
            #endif
            if !calling, cue.canHear || workspace.layout == .narrow {
                CueComposer(style: .page, takesFocusRequests: true, focusing: closeStage) {
                    follow.sent()
                    closeStage()
                }
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .animation(Motion.fade, value: cue.canHear)
        .animation(Motion.fade, value: calling)
    }

    private func closeStage() {
        guard stage == true else { return }
        stageInView = false
        withAnimation(Motion.fading(Motion.travel, reduceMotion: reduceMotion)) { stage = false }
    }

    private var calling: Bool {
        #if os(macOS)
        workspace.voiceViewState.presentation().active
        #else
        false
        #endif
    }
}

private struct CueWelcomeChat: View {
    @Environment(\.chatBottomInset) private var replyInset

    var body: some View {
        GeometryReader { room in
            ScrollView {
                CueWelcome(intro: true)
                    .padding(.horizontal, CuePage.inset)
                    .frame(maxWidth: CuePage.readingWidth)
                    .frame(maxWidth: .infinity, minHeight: max(0, room.size.height - replyInset))
            }
            .safeAreaPadding(.bottom, replyInset)
            .scrollBounceBehavior(.basedOnSize)
        }
    }
}
