import CueStore
import SwiftUI

/// 拍板卡上露出的那一件（`CueWaitDock.shown`）：它出自的那份在等的列表与位置。
/// 只存列表的引用、到画的地方才取出这一件：一件按值约 1.4KB，放进视图值会随外面每一层修饰一起复制、比较。
struct CueWaitPick: Equatable {
    let waits: [TaskBoard.Wait]
    let index: Int

    var wait: TaskBoard.Wait { waits[index] }
    var id: String { wait.id }

    /// 挨着的那件（眉题行的小箭头、滑卡换到哪件）；到头了为 nil。
    func neighbor(by offset: Int) -> CueWaitPick? {
        waits.indices.contains(index + offset) ? CueWaitPick(waits: waits, index: index + offset) : nil
    }
}

/// 拍板卡铺开的一件（外面的升起、叠边、滑卡在 `CueWaitDock`）：从上到下眉题（`CueWaitEyebrow`）、问句与点名的图、怎么答（`WaitAnswer`，主动作在右下角）。
/// 卡至多占对话区可见高的一半，地方不够时只用剩下的（`RiseLayout`）。
/// Mac 上放不下时问句与图在卡里滚、怎么答钉在卡底。
/// 手机上按给的高一次挑排法（`CueWaitFit`）：整张 → 紧凑（收起图）→ 只剩问句一行（`folded`）。放得下时不进滚动区：滚动区里的按钮按下要晚一下才有反馈。
struct CueWaitCard: View {
    let pick: CueWaitPick
    /// 提问点名的图（`CueThread.shots` 里这一问的）
    let shots: [CueShown]?
    let open: (PreviewOpening) -> Void
    @Environment(Workspace.self) private var workspace
    #if os(iOS)
    @Environment(\.palette) private var palette
    /// 收成了一行（`CueWaitFit` 排成的，量它那一格得知）：收起的几部分量成零大小、裁掉，但按钮仍点得到、读屏仍读得到，跟着它关掉。
    @State private var folded = false
    #endif

    nonisolated static let side: CGFloat = 16
    /// 卡里上下的边与几部分之间：眉题离卡顶、怎么答离卡底、各部分之间。
    nonisolated static let edge: CGFloat = 12
    nonisolated static let gap: CGFloat = 12
    /// 眉题与问句之间。
    nonisolated static let lead: CGFloat = 6

    #if os(macOS)
    /// 卡至少多高（Cue 页打开时数要排几格，`CuePage.covered`）：眉题、问句（至少一行标题字）、带图时一排图（`CueShots.floor`）、
    /// 怎么答（至少一颗按钮）、上下的边与卡下面的空（`CueWaitDock.below`）；叠边不算。只能数少。
    static func floor(_ wait: TaskBoard.Wait, shots: [UUID: [CueShown]], width: CGFloat) -> CGFloat {
        let pictures = wait.message.flatMap { shots[$0.id] }.map { gap + CueShots.floor(count: $0.count, width: width - 2 * side) } ?? 0
        return edge + CueWaitEyebrow.height + lead + Typography.titleSize + pictures + gap + ControlMetrics.compactHeight + edge + CueWaitDock.below
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            eyebrow
            Yielding {
                ScrollView {
                    VStack(alignment: .leading, spacing: Self.gap) {
                        CueQuestionLine(wait: pick.wait)
                        pictures
                    }
                    .padding(.top, Self.lead)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
            WaitAnswer(wait: pick.wait.wait).padding(.top, Self.gap).layoutPriority(1)
        }
        .padding(.horizontal, Self.side).padding(.bottom, Self.edge)
    }
    #else
    var body: some View {
        CueWaitFit {
            eyebrow.fitPart(.sheet, hidden: folded)
            CueQuestionLine(wait: pick.wait).fitPart(.sheet, hidden: folded)
            pictures.fitPart(.pictures, hidden: folded)
            WaitAnswer(wait: pick.wait.wait).fitPart(.sheet, hidden: folded)
            line.fitFrame()
                // 量裁的框（不是里面的内容）：收成一行的那条排出来了就是收起了
                .onGeometryChange(for: Bool.self) { $0.size.height > 0 } action: { folded = $0 }
                .fitRole(.folded, hidden: !folded)
        }
        .accessibilityAction(named: "上一件") { step(by: -1) }
        .accessibilityAction(named: "下一件") { step(by: 1) }
    }

    /// 连紧凑的样子都放不下（横屏弹着键盘）：整张卡收成问句一行。点它收起键盘，地方够了卡就按上面的挑法展开。
    private var line: some View {
        Button {
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        } label: {
            HStack(spacing: 9) {
                PiStateGlyph(status: .asking).font(Typography.title)
                Text(pick.wait.asked.line).font(Typography.title).foregroundStyle(palette.ink).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Self.side)
            .frame(minHeight: ControlMetrics.height)
            .contentShape(.rect)
        }
        .buttonStyle(PressStyle())
        .accessibilityHint("收起键盘，展开这张卡")
    }
    #endif

    private var eyebrow: some View {
        CueWaitEyebrow(wait: pick.wait, index: pick.index, count: pick.waits.count, step: step)
            .padding(.top, Self.edge)
    }

    /// 换到挨着的那件（眉题行的小箭头、读屏的"上一件""下一件"；手机上滑卡在 `CueWaitDock`）。
    private func step(by offset: Int) {
        guard let next = pick.neighbor(by: offset) else { return }
        withAnimation(HandOff.quick) { workspace.cueAsking = next.id }
    }

    /// Cue 点名的图（`CueShots`）："可以"选的是其中一张时那张描靛青圈；点开全屏时底栏就是这几个选项，看完当场定。
    @ViewBuilder private var pictures: some View {
        if let message = pick.wait.message, let shots {
            CueShots(shots: shots, group: "waiting", reply: .answer(message), chosen: CueShots.chosen(for: message.asking, in: shots), open: open)
        }
    }
}

#if os(iOS)
/// 手机上卡里几部分按给的高一次排（不用 `ViewThatFits`：它把每一档连同整张卡各建一遍）：眉题、问句、点名的图、怎么答，最后是收成一行的那条（`Part.folded`）。
/// 放得下整张排整张；放不下先收起图（`Part.pictures`）；连这都放不下只排收成一行的那条。不给高（量理想高）时排整张。
/// 收起的那几格量成零大小、裁掉不画（`fitPart`）。
struct CueWaitFit: Layout {
    enum Part { case sheet, pictures, folded }
    struct Role: LayoutValueKey { static let defaultValue = Part.sheet }

    private struct Plan {
        /// 各格的高（收起的为 0），与 `subviews` 同序。
        var heights: [CGFloat]
        var height: CGFloat
        var folded = false
    }

    private func plan(_ proposal: ProposedViewSize, _ subviews: Subviews) -> Plan {
        let width = proposal.width ?? .infinity
        let roles = subviews.map { $0[Role.self] }
        let inner = ProposedViewSize(width: width - 2 * CueWaitCard.side, height: nil)
        let heights = zip(subviews, roles).map { $1 == .folded ? 0 : $0.sizeThatFits(inner).height }
        // 眉题与问句之间是 `lead`，其后各部分之间是 `gap`，底下是 `edge`（眉题上面的边在眉题里）
        func stack(keeping keep: (Part) -> Bool) -> Plan {
            let kept = zip(heights, roles).map { keep($1) ? $0 : 0 }
            let gaps = CueWaitCard.gap * CGFloat(max(kept.count(where: { $0 > 0 }) - 2, 0))
            return Plan(heights: kept, height: kept.reduce(0, +) + CueWaitCard.lead + gaps + CueWaitCard.edge)
        }
        let room = proposal.height ?? .infinity
        let full = stack { _ in true }
        if full.height <= room { return full }
        let compact = stack { $0 != .pictures }
        if compact.height <= room { return compact }
        let line = zip(subviews, roles).map { $1 == .folded ? $0.sizeThatFits(ProposedViewSize(width: width, height: nil)).height : 0 }
        return Plan(heights: line, height: line.reduce(0, +), folded: true)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: proposal.width ?? 0, height: plan(proposal, subviews).height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let plan = plan(ProposedViewSize(width: bounds.width, height: proposal.height), subviews)
        let inset = plan.folded ? 0 : CueWaitCard.side
        var y = bounds.minY, placed = 0
        for (subview, height) in zip(subviews, plan.heights) {
            guard height > 0 else {
                subview.place(at: bounds.origin, proposal: .zero)
                continue
            }
            y += placed == 0 ? 0 : placed == 1 ? CueWaitCard.lead : CueWaitCard.gap
            subview.place(at: CGPoint(x: bounds.minX + inset, y: y), proposal: ProposedViewSize(width: bounds.width - 2 * inset, height: height))
            y += height
            placed += 1
        }
    }
}

private extension View {
    /// 卡里的一格（`CueWaitFit.Part`）：能被排成零大小并裁掉。裁掉的按钮照样点得到、读屏照样读到，收起时（`hidden`）一并关掉。
    func fitPart(_ part: CueWaitFit.Part, hidden: Bool) -> some View {
        fitFrame().fitRole(part, hidden: hidden)
    }

    func fitFrame() -> some View {
        frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading).clipped()
    }

    func fitRole(_ part: CueWaitFit.Part, hidden: Bool) -> some View {
        allowsHitTesting(!hidden).accessibilityHidden(hidden).layoutValue(key: CueWaitFit.Role.self, value: part)
    }
}
#endif

#if os(macOS)
/// 地方不够时先让的一段：给了高时按里面的理想高（滚动区是它内容的高）、至多到给的高（滚动区本身会占满给的高，留下一截空白）；
/// 量理想高时（外面不给高）不占高。
private struct Yielding: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let ideal = subviews[0].sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: proposal.width ?? ideal.width, height: proposal.height.map { min(ideal.height, $0) } ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews[0].place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}
#endif
