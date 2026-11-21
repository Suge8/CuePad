import SwiftUI

/// 并排的第 `index` 块与它右边那块之间的分界：不画分割线，拖动改这两块的宽（别的块不动），两边的页跟着实时重排、网页不重新载入。
/// 双击回到这一种摆法的默认比例（`WideMetrics.Shares`）。两块各不窄于自己的最窄。
/// Mac：平时什么都不画，指针靠近时变成左右拖动、浮出一条很淡的把手；接指针的那一条大半落在左边那块的留白上：压在网页上的那一截，网页自己会抢着换光标。
/// iPad：手指找不到看不见的东西，把手一直淡淡地在（拖着时深一点）；接触摸的那一条有手指宽，骑在分界上；指针移上去吸附成把手的样子（iPadOS 的指针效果）。
struct BesideDivider: View {
    let sizes: WideMetrics
    let index: Int
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
                        let from = start ?? sizes.widths[index]
                        start = from
                        var widths = sizes.widths
                        let pair = widths[index] + widths[index + 1]
                        widths[index] = min(max(from + value.translation.width, sizes.narrowest(index)), pair - sizes.narrowest(index + 1)).rounded()
                        widths[index + 1] = pair - widths[index]
                        workspace.paneShares.set(widths.map { $0 / sizes.main }, for: sizes.beside)
                    }
                    .onEnded { _ in start = nil }
            )
            .simultaneousGesture(TapGesture(count: 2).onEnded {
                withAnimation(Motion.spatial(Motion.travel, reduceMotion: reduceMotion)) {
                    workspace.paneShares.set(nil, for: sizes.beside)
                }
            })
            .padding(.leading, sizes.edge(after: index) - Self.reach + Self.overlap)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .readerHidden(true)
    }

    #if os(macOS)
    private var directions: HorizontalDirection.Set {
        if sizes.widths[index] <= sizes.narrowest(index) { return .trailing }
        if sizes.widths[index + 1] <= sizes.narrowest(index + 1) { return .leading }
        return .all
    }
    #endif
}
