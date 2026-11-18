#if os(macOS)
import SwiftUI

/// 会话与活预览之间的分界：平时不画（不用分割线），指针靠近时变成左右拖动、浮出一条很淡的把手；拖动改两边的宽，网页跟着实时变宽、不重新载入。
/// 双击回到默认比例（`WideMetrics.previewShare`）。拖的范围由 `WideMetrics.leading` 卡住：会话、预览各不窄于自己的最窄。
/// 接指针的那一条大半落在会话那边的留白上：压在网页上的那一截，网页自己会抢着换光标。
struct LiveDivider: View {
    let sizes: WideMetrics
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false
    @State private var start: CGFloat?

    private static let reach: CGFloat = 12
    private static let overlap: CGFloat = 3
    private static let handle = CGSize(width: 4, height: 40)

    var body: some View {
        let session = sizes.leading <= WideMetrics.session, preview = sizes.trailing <= WideMetrics.previewWidth
        Color.clear
            .frame(width: Self.reach)
            .contentShape(.rect)
            .overlay(alignment: .trailing) {
                Capsule()
                    .fill(palette.ink3)
                    .frame(width: Self.handle.width, height: Self.handle.height)
                    .offset(x: Self.handle.width / 2 - Self.overlap)
                    .opacity(hovering || start != nil ? 0.5 : 0)
                    .animation(Motion.fade, value: hovering || start != nil)
            }
            .pointerStyle(.columnResize(directions: session ? .trailing : preview ? .leading : .all))
            .onHover { hovering = $0 }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let from = start ?? sizes.leading
                        start = from
                        let leading = WideMetrics.leading(main: sizes.main, share: 1 - (from + value.translation.width) / sizes.main)
                        workspace.previewShare = 1 - leading / sizes.main
                    }
                    .onEnded { _ in start = nil }
            )
            .simultaneousGesture(TapGesture(count: 2).onEnded {
                withAnimation(Motion.spatial(Motion.travel, reduceMotion: reduceMotion)) { workspace.previewShare = WideMetrics.previewShare }
            })
            .padding(.leading, sizes.rail + sizes.leading - Self.reach + Self.overlap)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .accessibilityHidden(true)
    }
}
#endif
