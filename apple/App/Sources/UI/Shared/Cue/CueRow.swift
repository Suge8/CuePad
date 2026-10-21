import CueStore
import CueText
import SwiftUI

/// 对话里的一段（约 `CuePage.segment` 格，`ChatSegments`）：只按各格的内容比较。
struct CueSegment: View, Equatable {
    let rows: [CueRow]

    nonisolated static func == (a: Self, b: Self) -> Bool { a.rows.map(\.key) == b.rows.map(\.key) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(rows, id: \.row.id) { $0.equatable() }
        }
    }
}

/// 对话里的一格，连同上面的时间与间距。只按自己的输入比较（`equatable()`）：对话里来了一句、Cue 的状态变了，别的格子不重算——
/// 发出一句的那一刻对话要重排，每格都重算的话那一帧就掉了。要的那件活、在跑的那一轮、"已送达"都只交给用得着的那一格。
struct CueRow: View, Equatable {
    let row: CueThread.Row
    let ref: CueTaskRef?
    let shots: [CueShown]
    let joined: Bool
    let stamp: Date?
    /// 你最后一句：气泡旁标已送达（`BubbleTrip.delivered`）。
    let delivered: Bool
    let live: CueLiveRound?
    /// 这一格是新消息：左边一颗小点（`CueUnreadDot`），末尾进出滚动区时报给页面（`CueViewing`）。
    let unread: Bool
    @Binding var opened: PreviewOpening?
    @Binding var seen: [UUID: Date]
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services

    /// 这一格排出来什么样只看这几样。
    nonisolated struct Key: Equatable {
        let row: CueThread.Row, ref: CueTaskRef?, shots: [CueShown], joined: Bool, stamp: Date?, delivered: Bool, live: CueLiveRound?, unread: Bool
    }

    nonisolated var key: Key {
        Key(row: row, ref: ref, shots: shots, joined: joined, stamp: stamp, delivered: delivered, live: live, unread: unread)
    }

    nonisolated static func == (a: Self, b: Self) -> Bool { a.key == b.key }

    var body: some View {
        if let stamp { ChatTimeMarker(date: stamp).padding(.top, CuePage.stampAbove) }
        content
            .overlay(alignment: .topLeading) {
                CueUnreadDot(unread: unread).alignmentGuide(.leading) { $0[.trailing] + CueUnreadDot.gap }
            }
            .padding(.top, stamp != nil ? CuePage.stampBelow : CuePage.gap(before: row.speaker, joined: joined))
            .background(alignment: .bottom) {
                if unread {
                    CueEndProbe { visible in seen[row.id] = visible ? row.date : nil }
                }
            }
    }

    @ViewBuilder private var content: some View {
        let cue = workspace.cue
        switch row {
        case .you(let message):
            SpeechBubble(said: .cue(message, host: cue.hostID), box: Bindable(cue).draft, showsDelivered: delivered, look: .cue(joined: joined)) { _ in
                MessageActions(text: message.text, kind: .cue)
            }
        case .answer(let question):
            CueAnswer(question: question, joined: joined)
        case .cue(let message, _):
            CueSays(message: message, task: ref, shots: shots, open: { opened = $0 }, joined: joined, arrives: !swapsInPlace)
        case .result(let message, _):
            CueSays(message: message, task: ref, shots: shots, open: { opened = $0 }, card: true)
        case .notes(let rounds):
            CueNoteBubble(rounds: rounds, live: live)
        case .process(let message):
            RoundProcess(tools: message.tools, ending: CueLiveRound.ending(of: message, in: live)).padding(.leading, CueBubble.noteInset)
        }
    }

    /// Cue 的话原位换下正在说的话（Cue 在这台 Mac 值班时），不淡入。
    private var swapsInPlace: Bool {
        #if os(macOS)
        services.cue.keeper != nil
        #else
        false
        #endif
    }
}

/// Cue 在跑的那一轮：经过那一行（`round`）此刻的结尾，其余经过不记用时。
/// 交给对话里各格的是这个值而不是闭包：闭包每次都不相等，Cue 的状态一变（被叫醒、在想→用工具）对话里每一格都要重算。
nonisolated struct CueLiveRound: Equatable {
    let round: UUID
    let ending: RoundProcess.Ending

    static func ending(of message: CueMessage, in live: CueLiveRound?) -> RoundProcess.Ending {
        guard let live, live.round == message.id else { return .took(nil) }
        return live.ending
    }
}

/// Cue 页对话的末尾：它在做事、这一轮在对话里还没有一格（你发起的一轮还没调过工具，或设置里关了工具步骤）时是一行此刻在做的（`RoundProcess` 的那一行，同会话页）。
/// Cue 在这台 Mac 值班时，在回答你的一轮出字就换成逐字长出的正在说的话
/// （`CueKeeper.speech`，同会话页的 `SessionDraft`）：只有这个视图读它，出字时对话列表不重算；它与对话在同一次更新里拿到同一份对话，
/// 落库了（`PiDraft.landed`）就不再显示，换下是同一帧里的一减一加。已落库而 Cue 的状态还没歇下时也不冒出进展那一行（话已经说完）；
/// 中途转成工具调用时让位给进展那一行。进展那一行被换下时直接拿掉，不与正在说的话叠着淡出。别的 Mac 与手机只有进展那一行。
struct CueEnding: View {
    /// 对话里最近一条 Cue 的话的时刻
    let newestSaid: Date?
    /// 对话最后一格是 Cue 的话：正在说的这句落库后与它连成一串，说着的时候就排成那个样子。
    let joined: Bool
    /// 在跑的那一轮在对话里有一格（它的经过，或收着它的动态）：此刻在做的写在那一格里，这里不再写一遍。
    /// 没有那一格时（你发起的一轮还没调过工具；设置里关了工具步骤，`CueThread.rows` 不排经过）写在这里。
    let roundInRows: Bool
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    #if os(macOS)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    #endif

    var body: some View {
        #if os(macOS)
        let draft = services.cue.keeper?.speech.draft
        let landed = draft?.landed(newestReply: newestSaid) ?? false
        if let draft, !landed {
            // 与落库后的那句（`CueSays`）同一颗气泡、同一个位置，换下时正文不动
            BubbleWidth(fraction: CueBubble.cueWidth, edge: .leading) {
                MarkdownText(source: draft.text).equatable().cueBubble(joined: joined)
            }
            .padding(.top, CuePage.gap(before: .leading, joined: joined))
            .transition(.asymmetric(insertion: CueBubble.arrival(.leading, reduceMotion: reduceMotion), removal: .identity))
        } else if !landed {
            live
        }
        #else
        live
        #endif
    }

    @ViewBuilder private var live: some View {
        let presence = workspace.cue.presence
        if !roundInRows, let shown = presence.shown, let progress = presence.progress {
            RoundProcess(tools: nil, ending: .live(shown, doing: progress, step: nil))
                .padding(.leading, CueBubble.noteInset)
                .padding(.top, CuePage.gap(before: nil, joined: false))
                .transition(.asymmetric(insertion: .entry, removal: .identity))
        }
    }
}
