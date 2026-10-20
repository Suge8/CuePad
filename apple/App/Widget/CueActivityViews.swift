#if os(iOS)
import AppIntents
import SwiftUI

/// 实时活动的几种样子（`CueActivityState`）。小组件扩展按系统给的态画（`CueActivityWidget`）；主 App 也编进了这个文件，
/// 调试画面用同一份视图画出各态（`DebugActivityStage`）：系统的上下文（`ActivityViewContext`）造不出来，这里只吃内容与过没过时。
/// - 紧凑态：左边 Cue 的表情，右边有等你时赭黄"?M"、否则靛青"N"（实心小胶囊）；最小态只有表情。
/// - 展开态与锁屏：一排格子（每件在管靛青、每件等你赭黄、今天做完石绿，`cells`）、"在管 N 件 · 等你 M"、第一件等你带"打开"，
///   Cue 带选项的提问另有"允许一次"（`AllowOnceIntent`，不打开 App）；锁屏最下一行是最近做完的。
/// - 过时（`staleDate` 到了还没有新的一份）：整张变淡，右上角写这一份是多久前的。
/// 灵动岛的底永远是黑的，岛里一律按深色取色板；锁屏随系统深浅。
enum CueActivityViews {
    static func lockScreen(_ state: CueActivityState, stale: Bool) -> some View {
        LockScreen(state: state, stale: stale).withPalette()
    }

    static func compactLeading(_ state: CueActivityState) -> some View { Face(mood: state.mood, size: 24) }

    static func compactTrailing(_ state: CueActivityState) -> some View { Count(state: state).island() }

    static func minimal(_ state: CueActivityState) -> some View { Face(mood: state.mood, size: 24) }

    static func expandedLeading(_ state: CueActivityState) -> some View { Face(mood: state.mood, size: 36).padding(.leading, 4) }

    static func expandedTrailing(_ state: CueActivityState) -> some View { Count(state: state).padding(.trailing, 4).island() }

    static func expandedBottom(_ state: CueActivityState, stale: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Cells(cells: state.cells)
            Header(state: state, stale: stale, island: true)
            if let first = state.first { FirstWait(wait: first, island: true) }
        }
        .padding(.horizontal, 4)
        .opacity(stale ? Self.staleOpacity : 1)
        .island()
    }

    /// 过时时整张的不透明度。
    static let staleOpacity = 0.55
}

private extension View {
    /// 灵动岛里：底是黑的，按深色取色板。
    func island() -> some View { withPalette().environment(\.colorScheme, .dark) }
}

private struct LockScreen: View {
    let state: CueActivityState
    let stale: Bool
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Face(mood: state.mood, size: 28)
                Header(state: state, stale: stale, island: false)
            }
            Cells(cells: state.cells)
            if let first = state.first { FirstWait(wait: first, island: false) }
            if let done = state.lastDone {
                palette.hair.frame(height: 1)
                HStack(spacing: 6) {
                    WidgetIcon.done.image.foregroundStyle(palette.replied)
                    Text("做完：\(done.title)").foregroundStyle(palette.ink2).lineLimit(1)
                    Spacer(minLength: 8)
                    Text(done.at, format: .relative(presentation: .named)).foregroundStyle(palette.ink3).monospacedDigit()
                }
                .font(.footnote)
            }
        }
        .padding(16)
        .opacity(stale ? CueActivityViews.staleOpacity : 1)
        .foregroundStyle(palette.ink)
        .activityBackgroundTint(palette.paper)
        .activitySystemActionForegroundColor(palette.ink)
    }
}

/// "在管 N 件 · 等你 M"（为 0 的那半不写），过时时右边写这一份是多久前的。
private struct Header: View {
    let state: CueActivityState
    let stale: Bool
    let island: Bool
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 8) {
            counts.font(island ? .footnote : .subheadline.weight(.semibold)).lineLimit(1)
            Spacer(minLength: 8)
            if stale {
                Text(state.at, format: .relative(presentation: .named)).font(.footnote).foregroundStyle(palette.ink3).monospacedDigit()
            }
        }
    }

    private var counts: Text {
        let managing = state.managing > 0 ? Text("在管 \(state.managing) 件").foregroundStyle(island ? palette.ink2 : palette.ink) : nil
        let waiting = state.waiting > 0 ? Text("等你 \(state.waiting)").foregroundStyle(palette.waiting) : nil
        return switch (managing, waiting) {
        case (let managing?, let waiting?): Text("\(managing)\(Dotted.inline.foregroundStyle(palette.ink3))\(waiting)")
        case (let managing?, nil): managing
        case (nil, let waiting?): waiting
        case (nil, nil): Text(TallyLabel<EmptyView, EmptyView>.quiet).foregroundStyle(palette.ink2)
        }
    }
}

/// 一排格子：一件一格，等宽铺满一行。
private struct Cells: View {
    let cells: [CueActivityState.Cell]
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 4) {
            ForEach(cells.indices, id: \.self) { index in
                Capsule().fill(color(cells[index])).frame(height: 5)
            }
        }
        .accessibilityHidden(true)
    }

    private func color(_ cell: CueActivityState.Cell) -> Color {
        switch cell {
        case .managing: palette.signature
        case .waiting: palette.waiting
        case .done: palette.replied
        }
    }
}

/// 第一件等你：赭黄问号、说什么，右边"打开"与（Cue 带选项的提问才有的）"允许一次"。
private struct FirstWait: View {
    let wait: CueActivityState.Wait
    let island: Bool
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            if !island { WidgetIcon.waiting.image.font(.subheadline).foregroundStyle(palette.waiting) }
            VStack(alignment: .leading, spacing: 2) {
                Text(wait.title).font(.subheadline.weight(.semibold)).foregroundStyle(palette.ink).lineLimit(island ? 1 : 2)
                if let detail = wait.detail { Text(detail).font(.caption).foregroundStyle(palette.ink2).lineLimit(1) }
            }
            Spacer(minLength: 6)
            Link(destination: wait.open) {
                Text("打开").font(.footnote.weight(.semibold)).foregroundStyle(palette.ink).pill(palette.fill)
            }
            if let allow = wait.allow {
                Button(intent: AllowOnceIntent(allow)) {
                    Text("允许一次").font(.footnote.weight(.semibold)).foregroundStyle(palette.onFill).pill(palette.signatureFill)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// 紧凑态右边的数：有等你时赭黄"?M"，否则靛青"N"。
private struct Count: View {
    let state: CueActivityState
    @Environment(\.palette) private var palette

    var body: some View {
        let waits = state.waiting > 0
        Text(waits ? "?\(state.waiting)" : "\(state.managing)")
            .font(.caption.weight(.bold)).monospacedDigit().foregroundStyle(palette.onFill)
            .padding(.horizontal, 7).frame(minWidth: 24, minHeight: 20)
            .background(waits ? palette.waitingFill : palette.signatureFill, in: .capsule)
            .accessibilityLabel(waits ? "等你 \(state.waiting)" : "在管 \(state.managing)")
    }
}

private struct Face: View {
    let mood: String
    let size: CGFloat

    var body: some View {
        Image("mascot-cue-\(mood)").resizable().scaledToFit().frame(width: size, height: size).accessibilityHidden(true)
    }
}

private extension View {
    func pill(_ fill: Color) -> some View {
        padding(.horizontal, 12).frame(minHeight: 30).background(fill, in: .capsule)
    }
}
#endif
