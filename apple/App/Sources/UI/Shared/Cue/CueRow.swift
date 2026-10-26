import CueStore
import SwiftUI

/// 对话里的一段（约 `CuePage.segment` 格，`ChatSegments`）：只按各格的内容比较。
struct CueSegment: View, Equatable {
    let rows: [CueRow]

    @Environment(AppServices.self) private var services

    nonisolated static func == (a: Self, b: Self) -> Bool { a.rows.map(\.key) == b.rows.map(\.key) }

    /// 新到的淡入挂在插进来的那一格上（`equatable()` 外面）：挂在格子里面的过渡不会播。各格用 `equatable()` 包着，带时间的一格也只是一个子视图（`ChatRows` 按一格一个认）。
    var body: some View {
        ChatRows(ids: rows.map(\.row.id), spacing: 0) {
            ForEach(rows, id: \.row.id) { row in
                row.equatable().transition(CueRow.arrives(row.row, swapsInPlace: services.cueSwapsInPlace) ? CueBubble.arrival : .identity)
            }
        }
    }
}

/// 对话里的一格，连同上面的时间与间距。只按自己的输入比较（`equatable()`）：对话里来了一句、Cue 的状态变了，别的格子不重算——
/// 发出一句的那一刻对话要重排，每格都重算的话那一帧就掉了。在跑的那一轮、"已送达"都只交给用得着的那一格。
struct CueRow: View, Equatable {
    let row: CueThread.Row
    let shots: [CueShown]
    let joined: Bool
    let stamp: Date?
    /// 你最后一句：气泡旁标已送达（`BubbleTrip.delivered`）。
    let delivered: Bool
    let live: CueLiveRound?
    /// 这一格是新消息：左边一颗小点（`CueUnreadDot`），末尾进出滚动区时报给页面（`CueViewing`）。
    /// 页边距（`chatMargin`）放得下时在气泡外隔一条缝；放不下（iPhone、窄窗口的 iPad）点骑在气泡左缘上（`straddlesDot`），离屏缘约 12 点：
    /// 挤在屏边与气泡之间时离屏缘只剩 3 点，像被切掉一半。
    let unread: Bool
    @Binding var opened: PreviewOpening?
    @Binding var seen: [UUID: Date]
    @Environment(Workspace.self) private var workspace
    @Environment(\.chatMargin) private var margin

    /// 这一格排出来什么样只看这几样。
    nonisolated struct Key: Equatable {
        let row: CueThread.Row, shots: [CueShown], joined: Bool, stamp: Date?, delivered: Bool, live: CueLiveRound?, unread: Bool
    }

    nonisolated var key: Key {
        Key(row: row, shots: shots, joined: joined, stamp: stamp, delivered: delivered, live: live, unread: unread)
    }

    nonisolated static func == (a: Self, b: Self) -> Bool { a.key == b.key }

    var body: some View {
        if let stamp { ChatTimeMarker(date: stamp).padding(.top, CuePage.stampAbove) }
        content
            .overlay(alignment: .topLeading) {
                CueUnreadDot(unread: unread).alignmentGuide(.leading) { [straddlesDot] in
                    straddlesDot ? $0[HorizontalAlignment.center] : $0[.trailing] + CueUnreadDot.gap
                }
            }
            .padding(.top, stamp != nil ? CuePage.stampBelow : CuePage.gap(before: row.speaker, joined: joined))
            .background(alignment: .bottom) {
                if unread {
                    CueEndProbe { visible in seen[row.id] = visible ? row.date : nil }
                }
            }
    }

    /// 新来时把上面的对话撑上去、自己淡入的那几种（`ChatScroll.rise`、`CueBubble.arrival`）：Cue 新说的一句与结果卡。
    /// `swapsInPlace`：Cue 在这台 Mac 值班，它的话原位换下正在说的那句（`CueEnding`），直接出现。你的话由回复框那头的发出动画接上，其余各格直接出现。
    static func arrives(_ row: CueThread.Row, swapsInPlace: Bool) -> Bool {
        switch row {
        case .cue: !swapsInPlace
        case .result: true
        default: false
        }
    }

    @ViewBuilder private var content: some View {
        let cue = workspace.cue
        switch row {
        case .you(let message):
            SpeechBubble(said: .cue(message, host: cue.hostID), box: Bindable(cue).draft, showsDelivered: delivered, look: .cue(joined: joined)) { _ in
                MessageActions(text: message.text, kind: .cue)
            }
        case .answer(let question, let quoted):
            CueAnswer(question: question, quoted: quoted, joined: joined)
        case .cue(let message, let task):
            CueSays(message: message, task: task, shots: shots, open: { opened = $0 }, joined: joined)
        case .result(let message, let task):
            CueSays(message: message, task: task, shots: shots, open: { opened = $0 }, card: true)
        case .notes(let rounds):
            CueNoteLog(rounds: rounds, live: live)
        case .process(let message, let touches):
            BubbleWidth(fraction: CueBubble.cueWidth, edge: .leading) {
                CueTrace(touches: touches, doing: live?.round == message.id ? live?.doing : nil).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var straddlesDot: Bool { margin < CueUnreadDot.room }
}

/// Cue 在跑的那一轮：经过那一行（`round`）与此刻在做的（并进这一轮的经过，`CueTrace`）。
/// 交给对话里各格的是这个值而不是闭包：闭包每次都不相等，Cue 的状态一变（被叫醒、在想→用工具）对话里每一格都要重算。
nonisolated struct CueLiveRound: Equatable {
    let round: UUID
    /// 它那台 Mac 此刻不在（`CuePresence.shown` 为空）时为 nil：这一轮照样没做完，只是不写在做什么
    let doing: Doing?

    /// 在跑那一步：碰到任务与会话的（`step`）并进经过里它那一处的一行，其余是末尾图标加那一句；在说话时（`speaking`）没有这一行。
    struct Doing: Equatable {
        let icon: Icon
        let step: CueActivity.Touch?
        let text: String
        let speaking: Bool
    }
}

/// Cue 页对话的末尾：此刻在做的那一行（`CueDoing`）的位置一直占着（`ChatLiveSlot`，没有时留白）：它在做事、这一轮在对话里还没有一格时
/// （你发起的一轮还没碰到任务与会话）写在这里，出现、收起与换字都不挪对话。
/// Cue 在这台 Mac 值班时，在回答你的一轮出字就在这一行上方逐字长出正在说的话
/// （`CueKeeper.speech`，同会话页的 `SessionDraft`）：只有这个视图读它，出字时对话列表不重算；它与对话在同一次更新里拿到同一份对话，
/// 落库了（`PiDraft.landed`）就不再显示，换下是同一帧里的一减一加。有草稿时（说着、已落库而 Cue 的状态还没歇下）那一行留白（话已经在说、说完了）；
/// 中途转成工具调用时桥清掉草稿，那一行写进展。进展那一行被换下时直接拿掉，不与正在说的话叠着淡出。别的 Mac 与手机只有进展那一行。
/// 待回复提示（`CueReplyTip`）落在这一行的位置上：它在时盖住这一行。
struct CueEnding: View {
    /// 对话里最近一条 Cue 的话的时刻
    let newestSaid: Date?
    /// 对话最后一格是 Cue 的话：正在说的这句落库后与它连成一串，说着的时候就排成那个样子。
    let joined: Bool
    /// 在跑的那一轮在对话里有一格（它的经过，或收着它的动态）：此刻在做的写在那一格里，这里不再写一遍。
    /// 没有那一格时（你发起的一轮还没碰到任务与会话，`CueThread.rows` 不排经过）写在这里。
    let roundInRows: Bool
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            #if os(macOS)
            let draft = services.cue.keeper?.speech.draft
            if let draft, !draft.landed(newestReply: newestSaid) {
                // 与落库后的那句（`CueSays`）同一颗气泡、同一个位置，换下时正文不动
                BubbleWidth(fraction: CueBubble.cueWidth, edge: .leading) {
                    MarkdownText(source: draft.text).equatable().cueBubble(joined: joined)
                }
                .padding(.top, CuePage.gap(before: .leading, joined: joined))
                .transition(.asymmetric(insertion: CueBubble.arrival, removal: .identity))
            }
            ChatLiveSlot(gap: CuePage.gap(before: nil, joined: false), font: CueDoing.font, floating: CueReplyTip.clearance) { if draft == nil { live } }
            #else
            ChatLiveSlot(gap: CuePage.gap(before: nil, joined: false), font: CueDoing.font, floating: CueReplyTip.clearance) { live }
            #endif
        }
    }

    @ViewBuilder private var live: some View {
        let presence = workspace.cue.presence
        if !roundInRows, let shown = presence.shown, let progress = presence.progress {
            CueDoing(shown: shown, doing: progress)
                .transition(.asymmetric(insertion: .entry, removal: .identity))
        }
    }
}

/// Cue 此刻在做的那一行（对话末尾，`CueEnding`）：状态标加一句它在做什么（`CuePresence.progress`：碰到任务与会话的一步写成"发给 登录回调超时"，与这一轮的经过同一套动词，`CueActivity.line`），
/// 仍是旁注、不铺底，左缘对着 Cue 气泡的左缘；字比旁注大一档（正文的次一级）：这是你刚说完在等的那件事，比经过与动态要紧。
private struct CueDoing: View {
    let shown: PiShown
    let doing: String
    @Environment(\.palette) private var palette

    static let font = Typography.secondary

    var body: some View {
        // 一行：它的位置只留一行（`ChatLiveSlot`）
        NoteLine { PiStateDot(shown: shown, size: 7) } label: {
            Text(doing).font(Self.font).foregroundStyle(palette.ink2).lineLimit(1).shimmering()
        }
        .accessibilityElement(children: .ignore).accessibilityLabel(doing)
    }
}

extension AppServices {
    /// Cue 的话原位换下正在说的那句（Cue 在这台 Mac 值班，`CueEnding`），新到时不另外长出来（`CueRow.arrives`）。
    var cueSwapsInPlace: Bool {
        #if os(macOS)
        cue.keeper != nil
        #else
        false
        #endif
    }
}
