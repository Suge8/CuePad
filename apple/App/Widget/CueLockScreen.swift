#if os(iOS)
import AppIntents
import SwiftUI
import WidgetKit

/// 锁屏那张卡此刻的主角与其余几行。主角只有一个：有拍板是第一件拍板，没有而有新回复是那个会话，再没有而有件在推进是那个数，
/// 都没有是刚做完的那件或 Cue 的那一句。颜色跟主角走（`Palette.signal`）；过时的那一份没有哪种状态还作数，回到纸。
private struct Poster {
    enum Head {
        case wait(CueNow.Wait)
        case item(CueNow.Item)
        case count(Int)
        case line(String)
    }

    let tone: CueNow.Tone
    let head: Head
    /// 数下面 Cue 自己此刻那一步或不在的原因，占一行。
    let step: String?
    let rows: [CueNow.Item]

    init(_ now: CueNow, stale: Bool) {
        var items = now.items.filter { $0.kind != .resting }
        func take(_ kind: CueNow.Item.Kind) -> CueNow.Item? {
            guard let index = items.firstIndex(where: { $0.kind == kind }) else { return nil }
            return items.remove(at: index)
        }
        var step: String?
        var tone = now.keyTone
        // 卡高 158pt 排得下的行数
        var room = 2
        if let first = now.first {
            // 第一件拍板已经写成主角（`first` 与拍板那几行同一个次序）
            _ = take(.asks)
            head = .wait(first)
        } else if let reply = take(.reply) {
            head = .item(reply)
            room = 3
        } else if now.tally.moving > 0 {
            head = .count(now.advancing)
            step = switch now.cue {
            case .working(let woke, let doing, _): doing ?? woke ?? CueNow.thinking
            case .hearing: String(localized: "你的话在路上")
            case .away(let reason, _): reason
            case .idle: nil
            }
            room = step == nil ? 4 : 3
        } else if !now.isBusy, let done = take(.done) {
            head = .item(done)
            tone = .done
            room = 3
        } else {
            head = .line(now.quietLine)
            room = 3
        }
        self.tone = stale ? .quiet : tone
        self.step = step
        // 过时那一行（多久前的）占掉一行
        rows = Array(items.prefix(room - (stale ? 1 : 0)))
    }
}

struct CueLockScreen: View {
    let now: CueNow
    let stale: Bool
    @Environment(\.palette) private var palette

    /// 系统给锁屏这一块封顶 160pt。
    private static let height: CGFloat = 158
    private static let pose: CGFloat = 140
    /// 标题下面右边让给 Cue 的宽：字不排到它身上。标题那一行在它头顶上面，占满。
    private static let beside: CGFloat = 109

    func fill(_ palette: Palette) -> Color { palette.signal(Poster(now, stale: stale).tone).fill }

    var body: some View {
        let poster = Poster(now, stale: stale)
        let signal = palette.signal(poster.tone)
        VStack(alignment: .leading, spacing: 0) {
            title(poster, signal)
            VStack(alignment: .leading, spacing: 0) {
                under(poster, signal)
                if let step = poster.step {
                    Text(step).font(IslandType.posterWord).foregroundStyle(signal.soft).lineLimit(1).padding(.top, 2)
                }
                VStack(spacing: 0) {
                    ForEach(poster.rows) { PosterRow(item: $0, signal: signal).transition(.blurReplace) }
                }
                .padding(.top, 5)
                if stale { Text(now.at, style: .relative).font(IslandType.posterWord).foregroundStyle(signal.soft).padding(.top, 4) }
            }
            .padding(.trailing, Self.beside)
        }
        .padding(.top, 14).padding(.horizontal, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .frame(height: Self.height)
        // 从右下角探出来，脚和半只手被卡的圆角裁掉
        .background(alignment: .bottomTrailing) {
            Image(decorative: "cue-pose-\(now.beat.pose)").resizable().scaledToFit().frame(width: Self.pose)
                .rotationEffect(.degrees(-5)).offset(x: 14, y: 30)
                .opacity(now.beat.faded ? CueFaceMarks.awayOpacity : 1)
        }
        .opacity(stale ? CueActivityViews.staleOpacity : 1)
        .activityBackgroundTint(signal.fill)
        .activitySystemActionForegroundColor(signal.ink)
    }

    @ViewBuilder private func title(_ poster: Poster, _ signal: Palette.Signal) -> some View {
        switch poster.head {
        case .wait(let wait):
            Link(destination: wait.open) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(wait.title).font(wait.detail == nil ? IslandType.posterQuestion : IslandType.posterTitle).foregroundStyle(signal.ink)
                        .lineLimit(wait.detail == nil ? 2 : 1).fixedSize(horizontal: false, vertical: true).multilineTextAlignment(.leading)
                    if let detail = wait.detail { Text(detail).font(IslandType.posterWord).foregroundStyle(signal.soft).lineLimit(1) }
                }
            }
        case .item(let item):
            Text(item.name).font(IslandType.posterTitle).foregroundStyle(signal.ink).lineLimit(1)
        case .count(let count):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(count, format: .number).font(IslandType.posterBig).monospacedDigit().foregroundStyle(signal.ink)
                    .contentTransition(.numericText())
                Text("推进中").font(IslandType.posterHeadWord).foregroundStyle(signal.soft)
            }
            .frame(height: 44)
            .accessibilityElement(children: .ignore).accessibilityLabel(now.spoken)
        case .line(let line):
            Text(line).font(IslandType.posterTitle).foregroundStyle(signal.ink).lineLimit(1)
        }
    }

    /// 主角下面那一行：等了、过了多久的大钟与状态词；能"允许一次"的拍板是那颗钮。
    @ViewBuilder private func under(_ poster: Poster, _ signal: Palette.Signal) -> some View {
        switch poster.head {
        case .wait(let wait):
            if let allow = wait.allow {
                HStack(spacing: 12) {
                    // 同 App 里拍板卡答"可以"的那颗钮：只有对勾。卡是赭黄的，钮反过来用墨底、赭黄的勾
                    Button(intent: AllowOnceIntent(allow)) {
                        WidgetIcon.tick.image.font(IslandType.posterTick).foregroundStyle(signal.fill)
                            .frame(width: 72, height: 42).background(signal.ink, in: .capsule)
                            .frame(minHeight: 44).contentShape(.rect)
                    }
                    .accessibilityLabel("允许一次")
                    .buttonStyle(.plain).fixedSize()
                    word(.asks, signal)
                    if let since = now.clock { ActivityElapsed(since: since).font(IslandType.posterTime).foregroundStyle(signal.soft) }
                }
                .padding(.top, 5)
            } else {
                lead(since: now.clock, word: .asks, signal)
            }
        case .item(let item):
            if item.kind == .done {
                word(item.kind, signal, font: IslandType.posterHeadWord).padding(.top, 6)
            } else {
                lead(since: item.since, word: item.kind, signal)
            }
        case .count:
            EmptyView()
        case .line:
            if !stale, let since = now.clock { lead(since: since, word: nil, signal) }
        }
    }

    private func lead(since: Date?, word kind: CueNow.Item.Kind?, _ signal: Palette.Signal) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let since {
                ActivityElapsed(since: since, alignment: .leading).font(IslandType.posterBig).minimumScaleFactor(0.6).foregroundStyle(signal.ink)
            }
            if let kind { word(kind, signal) }
        }
        .frame(height: 44)
    }

    private func word(_ kind: CueNow.Item.Kind, _ signal: Palette.Signal, font: Font = IslandType.posterWord) -> some View {
        HStack(spacing: 5) {
            kind.glyph?.image
            Text(kind.label)
        }
        .font(font).foregroundStyle(signal.soft).fixedSize()
    }
}

/// 其余几行：名字、行尾还在动的写做了多久（自己走），停下的写状态词。整块上了色，行里不再分颜色，靠行首的图形分。
private struct PosterRow: View {
    let item: CueNow.Item
    let signal: Palette.Signal

    var body: some View {
        HStack(spacing: 6) {
            item.kind.glyph?.image.font(IslandType.posterGlyph).foregroundStyle(signal.soft)
            Text(item.name).font(IslandType.posterRow).lineLimit(1)
            Spacer(minLength: 4)
            if item.kind.tone == .moving {
                ActivityElapsed(since: item.since).font(IslandType.posterTime).minimumScaleFactor(0.7).frame(width: IslandType.posterTimeWidth, alignment: .trailing)
            } else {
                Text(item.label).font(IslandType.posterRow).fixedSize()
            }
        }
        .foregroundStyle(signal.ink)
        .frame(height: 21)
        .accessibilityElement(children: .ignore).accessibilityLabel(Dotted(item.name, item.label).spoken)
    }
}
#endif
