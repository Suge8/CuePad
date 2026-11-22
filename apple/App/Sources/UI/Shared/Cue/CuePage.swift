import CueStore
import SwiftUI

struct CuePage: View {
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @State private var thread: CueThread?
    @State private var follow = ChatFollow()
    @State private var opened: PreviewOpening?
    @State private var docking = false
    @State private var dockedCard: String?
    @State private var seen: [UUID: Date] = [:]

    static let readingWidth = Spacing.reading
    static let inset = Spacing.page

    private var cue: CueWatch { workspace.cue }
    private func card(_ thread: CueThread) -> String? { CueWaitDock.current(in: thread.waiting, asking: workspace.cueAsking)?.id }
    private func sinking(_ thread: CueThread) -> Bool { dockedCard != nil && card(thread) == nil }
    private var catchingUp: Bool { services.syncing.isCatchingUp(on: cue.hostID) }
    var body: some View {
        page
            .background { CueSky(beat: cue.beat) }
            .observing(services.store, into: $thread, onError: workspace.fail) { try CueThread.read(from: $0) }
            .previewPresenter($opened, reply: .cue)
            .panel(isPresented: Bindable(cue).showsMemory) { CueMemoryPage() }
            .panel(isPresented: Bindable(cue).showsSchedules) { CueSchedulePage() }
            .modifier(CueViewing(thread: thread, catchingUp: catchingUp, seen: $seen, follow: $follow))
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
                .padding(.horizontal, Self.inset)
                .frame(maxWidth: Self.readingWidth)
        }
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
        .floatingHeader(.verbatim(cue.name), height: CueHeader.height, hasPanel: true, center: { CueHeader() }) { EmptyView() }
    }
    #endif

    private var railInset: CGFloat { workspace.layout == .narrow ? SessionRail.phoneWidth + Spacing.item - Self.inset : 0 }

    /// 读不出来时也排一个真的视图：读库的订阅挂在页上，等视图出现才启动。
    @ViewBuilder private var chat: some View {
        Group {
            if let thread, !thread.rows.isEmpty {
                conversation(thread)
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
                CueEnding(newestSaid: thread.messages.last { $0.author == .known(.cue) }?.createdAt, joined: rows.last?.speaker == .leading)
            }
            #if os(iOS)
            .environment(\.inlineTextSelection, false)
            #endif
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
                CueWaitDock(waiting: thread.waiting, asking: workspace.cueAsking, moving: $docking)
                    .padding(.horizontal, railInset)
                if !thread.rows.isEmpty, !cue.canHear { CueWelcome(intro: false).fixedSize(horizontal: false, vertical: true).padding(.bottom, Spacing.item).transition(.opacity) }
            }
            #if os(macOS)
            CueVoicePanel()
            #endif
            if !calling, cue.canHear || workspace.layout == .narrow {
                CueComposer(style: .page, takesFocusRequests: true) { follow.sent() }
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .animation(Motion.fade, value: cue.canHear)
        .animation(Motion.fade, value: calling)
    }

    private var calling: Bool {
        #if os(macOS)
        workspace.voiceViewState.presentation().active
        #else
        false
        #endif
    }
}

/// 欢迎的字排在小人头顶之上（`CueSky.reach`）：空着时天空与小人就是这一页的底。
private struct CueWelcomeChat: View {
    @Environment(\.chatBottomInset) private var replyInset

    var body: some View {
        GeometryReader { room in
            ScrollView {
                CueWelcome(intro: true)
                    .padding(.horizontal, CuePage.inset)
                    .frame(maxWidth: CuePage.readingWidth)
                    .frame(maxWidth: .infinity, minHeight: max(0, room.size.height - max(replyInset, CueSky.reach)))
            }
            .safeAreaPadding(.bottom, max(replyInset, CueSky.reach))
            .scrollBounceBehavior(.basedOnSize)
        }
    }
}
