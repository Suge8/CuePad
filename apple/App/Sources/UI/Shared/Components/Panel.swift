import SwiftUI

struct ClosePanel: Equatable {
    nonisolated(unsafe) let id: AnyHashable?
    let run: @MainActor () -> Void

    init(id: AnyHashable? = nil, run: @escaping @MainActor () -> Void) {
        self.id = id
        self.run = run
    }

    func callAsFunction() { run() }
    func of(_ id: AnyHashable) -> ClosePanel { ClosePanel(id: id, run: run) }
    nonisolated static func == (a: Self, b: Self) -> Bool { a.id == b.id }
}

extension EnvironmentValues {
    @Entry var closePanel = ClosePanel {}
    @Entry var panelCovered = false
    @Entry var escapeTaken = false
}

enum PanelStyle: Equatable {
    case sheet
    case bare(from: CGPoint?)
    case fullScreen
    case bubble(BubbleSource, width: BubblePlacement.Width = .fitting)

    var modal: Bool {
        switch self {
        case .sheet, .bare, .fullScreen: true
        case .bubble: false
        }
    }
}

extension View {
    /// 调用处只给状态与内容，平台只换呈现。AppKit 的窗口 sheet 开、关都把主线程关在约 300ms 的嵌套动画循环里，关的那一段整窗不出帧，所以 Mac 上窗口内的浮层都只走这里。内容用环境里的 `closePanel` 关自己。
    func panel(isPresented: Binding<Bool>, style: PanelStyle = .sheet, @ViewBuilder content: @escaping () -> some View) -> some View {
        panel(item: Binding { isPresented.wrappedValue ? Shown() : nil } set: { isPresented.wrappedValue = $0 != nil }, style: style) { _ in content() }
    }

    func panel<Item: Identifiable>(
        item: Binding<Item?>, style: PanelStyle = .sheet, @ViewBuilder content: @escaping (Item) -> some View
    ) -> some View {
        presentPanel(item: item, style: style, close: ClosePanel { item.wrappedValue = nil }, content: content)
    }
}

private struct Shown: Identifiable { let id = true }

/// 浮层画在窗口那一层，不在源视图下面：会话、Cue 那一栏各在自己的托管视图里，偏好值传不到窗口那一层。
/// 开着时源视图挂 `feeds`，每次重算经平台视图的更新把新内容写进盒子，开着的浮层随源的状态变（不用再把源的值抄进自己的盒子）；
/// 收起后盒子留着最后一份，退场动画画的就是它。
@Observable
final class PanelContent {
    var view: AnyView

    init(_ view: AnyView = AnyView(EmptyView())) { self.view = view }
}

struct PanelBody: View {
    let content: PanelContent

    var body: some View { content.view }
}

extension View {
    func feeds(_ content: PanelContent, while on: Bool, _ view: @escaping () -> AnyView) -> some View {
        background { if on { PanelFeed(content: content, view: view()) } }
    }
}

#if os(macOS)
private struct PanelFeed: NSViewRepresentable {
    let content: PanelContent
    let view: AnyView

    func makeNSView(context: Context) -> Inert { Inert() }
    func updateNSView(_ inert: Inert, context: Context) { content.view = view }

    final class Inert: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
#else
private struct PanelFeed: UIViewRepresentable {
    let content: PanelContent
    let view: AnyView

    func makeUIView(context: Context) -> UIView {
        let inert = UIView()
        inert.isUserInteractionEnabled = false
        return inert
    }

    func updateUIView(_ inert: UIView, context: Context) { content.view = view }
}
#endif

struct DrawerSurface: ViewModifier {
    var edge = HorizontalEdge.trailing
    var ground: KeyPath<Palette, Color> = \.desk
    var shown = true
    var bleed = EdgeInsets()
    @Environment(\.palette) private var palette

    func body(content: Content) -> some View {
        content
            .frame(maxHeight: .infinity)
            // 影子只挂在底那块上：挂在整块内容上要先离屏合成里面的字再糊影子（同 `PaperSurface`）
            .background { if shown { palette[keyPath: ground].elevation(.panel).padding(bled).ignoresSafeArea() } }
            .overlay(alignment: edge == .trailing ? .leading : .trailing) {
                if shown { palette.hair.frame(width: ControlMetrics.stroke).padding(bled).ignoresSafeArea() }
            }
    }

    private var bled: EdgeInsets { EdgeInsets(top: -bleed.top, leading: -bleed.leading, bottom: -bleed.bottom, trailing: -bleed.trailing) }
}

/// 调用处挂 `transition(.identity)`：收起那一下就撤，不然它跟着收起的动画淡完之前还接点按。
/// Esc 同一时刻只有一个出处、先收最上面那层：窗口里有浮出开着（抽屉里长开的名牌、抽屉里弹的气泡与浮层，`escapeTaken`）时抽屉不挂自己的 Esc，
/// 收给那一层（Mac 是 `PanelHost` 的按键监听，手机与 iPad 是 `ModalScrim`）；浮出收了才挂回来，再按一下收抽屉。两个同键的快捷键谁先响由系统定，不留给运气。
struct DrawerCatcher: View {
    let close: () -> Void
    @Environment(\.escapeTaken) private var escapeTaken

    var body: some View {
        Color.clear.contentShape(.rect)
            .gesture(DragGesture(minimumDistance: 0).onChanged { _ in close() })
            .overlay {
                if !escapeTaken { Button("关闭", action: close).keyboardShortcut(.escape, modifiers: []).opacity(0).readerHidden(true) }
            }
            .ignoresSafeArea()
            .onChange(of: escapeTaken, initial: true) { DebugHooks.drawerEscape(hung: !escapeTaken) }
    }
}

struct DrawerSlide: ViewModifier {
    let open: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    private static let shadowRoom: CGFloat = 40

    func body(content: Content) -> some View {
        content
            .visualEffect { [shown, room = Self.shadowRoom] effect, proxy in
                effect.offset(x: shown ? 0 : -(proxy.size.width + room))
            }
            .allowsHitTesting(open)
            .onChange(of: open, initial: true) { _, open in
                withAnimation(Motion.spatial(Motion.nudge, reduceMotion: reduceMotion)) { shown = open }
            }
    }
}
