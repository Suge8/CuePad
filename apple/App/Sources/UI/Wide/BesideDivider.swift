import SwiftUI

/// 并排两半之间的分界（右半是会话或 Mac 的活预览）：不画分割线，拖动改两边的宽，两边的页跟着实时重排、网页不重新载入。
/// 双击回到这一种右半的默认比例（`WideMetrics.BesideShare`）。拖的范围由 `WideMetrics.leading` 卡住：两边各不窄于自己的最窄。
/// Mac：平时什么都不画，指针靠近时变成左右拖动、浮出一条很淡的把手；接指针的那一条大半落在左边那块的留白上：压在网页上的那一截，网页自己会抢着换光标。
/// iPad：手指找不到看不见的东西，把手一直淡淡地在（拖着时深一点）；接触摸的那一条有手指宽，骑在分界上；指针移上去吸附成把手的样子（iPadOS 的指针效果）。
struct BesideDivider: View {
    let sizes: WideMetrics
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false
    @State private var start: CGFloat?

    #if os(macOS)
    private static let reach: CGFloat = 12
    private static let overlap: CGFloat = 3
    private static let resting = 0.0
    #else
    private static let reach: CGFloat = 44
    private static let overlap: CGFloat = reach / 2
    private static let resting = 0.25
    #endif
    private static let handle = CGSize(width: 4, height: 40)

    var body: some View {
        Color.clear
            .frame(width: Self.reach)
            .contentShape(.rect)
            .overlay(alignment: .trailing) {
                Capsule()
                    .fill(palette.ink3)
                    .frame(width: Self.handle.width, height: Self.handle.height)
                    .offset(x: Self.handle.width / 2 - Self.overlap)
                    .opacity(hovering || start != nil ? 0.5 : Self.resting)
                    .animation(Motion.fade, value: hovering || start != nil)
                    #if os(iOS)
                    .contentShape(.hoverEffect, Capsule().inset(by: -4))
                    .hoverEffect(.highlight)
                    #endif
            }
            #if os(macOS)
            .pointerStyle(.columnResize(directions: directions))
            #endif
            .onHover { hovering = $0 }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let from = start ?? sizes.leading
                        start = from
                        let leading = WideMetrics.leading(main: sizes.main, share: 1 - (from + value.translation.width) / sizes.main, preview: sizes.preview)
                        workspace.besideShare[preview: sizes.preview] = 1 - leading / sizes.main
                    }
                    .onEnded { _ in start = nil }
            )
            .simultaneousGesture(TapGesture(count: 2).onEnded {
                withAnimation(Motion.spatial(Motion.travel, reduceMotion: reduceMotion)) {
                    workspace.besideShare[preview: sizes.preview] = WideMetrics.BesideShare()[preview: sizes.preview]
                }
            })
            .padding(.leading, sizes.rail + sizes.leading - Self.reach + Self.overlap)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .readerHidden(true)
    }

    #if os(macOS)
    private var directions: HorizontalDirection.Set {
        if sizes.leading <= WideMetrics.session { return .trailing }
        if sizes.trailing <= WideMetrics.trailingMin(preview: sizes.preview) { return .leading }
        return .all
    }
    #endif
}
