#if os(macOS)
import CueStore
import SwiftUI

/// Mac 的技能与规则页（侧栏底下那一排的那颗，`Route.library`）：读这台 Mac 写下的快照（`Workspace.library`），文件改了它就跟着变。
/// 宽时两列——左列规则（标题行末一颗问号，一键整理那块纸有才有、在它最上面），右列技能清单；窄时上下一列（`LibraryColumns`）。
/// 整页一起滚，一直滚到工具栏后面；顶上不写页名（侧栏底下那颗已经说了在哪）。
/// 这台还没写下快照时（刚升级、第一次扫还没完）只写一句在读。
struct LibraryPage: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    var body: some View {
        ScrollView {
            if let library = workspace.library {
                LibraryColumns {
                    InstructionSection(library: library)
                    SkillSection(library: library)
                }
                .padding(.horizontal, Spacing.page)
                .padding(.bottom, Spacing.section)
            } else {
                HStack(spacing: 8) {
                    Spinner(.small)
                    Text("正在读这台 Mac 上的技能与规则…")
                }
                .font(Typography.secondary).foregroundStyle(palette.ink3)
                .frame(maxWidth: .infinity).padding(.top, 120)
            }
        }
        .safeAreaPadding(.top, Bars.contentGap)
    }
}

/// 两列（宽时）或一列（窄时）：左列定宽、右列占剩下的；放不下两列最窄的宽时上下排，左列在上。一次排完，不先量再写回状态。
private struct LibraryColumns: Layout {
    private static let left: CGFloat = 380
    private static let rightMin: CGFloat = 440
    private static let gap: CGFloat = 40

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? Self.left + Self.gap + Self.rightMin
        let frames = place(in: width, subviews)
        return CGSize(width: width, height: frames.map(\.maxY).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (subview, frame) in zip(subviews, place(in: bounds.width, subviews)) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: ProposedViewSize(frame.size))
        }
    }

    private func place(in width: CGFloat, _ subviews: Subviews) -> [CGRect] {
        guard subviews.count == 2 else { return [] }
        if width >= Self.left + Self.gap + Self.rightMin {
            let right = width - Self.left - Self.gap
            let a = subviews[0].sizeThatFits(ProposedViewSize(width: Self.left, height: nil)).height
            let b = subviews[1].sizeThatFits(ProposedViewSize(width: right, height: nil)).height
            return [CGRect(x: 0, y: 0, width: Self.left, height: a), CGRect(x: Self.left + Self.gap, y: 0, width: right, height: b)]
        }
        let a = subviews[0].sizeThatFits(ProposedViewSize(width: width, height: nil)).height
        let b = subviews[1].sizeThatFits(ProposedViewSize(width: width, height: nil)).height
        return [CGRect(x: 0, y: 0, width: width, height: a), CGRect(x: 0, y: a + Spacing.section, width: width, height: b)]
    }
}
#endif
