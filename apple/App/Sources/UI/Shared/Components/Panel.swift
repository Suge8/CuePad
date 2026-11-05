import SwiftUI

/// 关掉自己所在的弹层（`panel`）。Mac 的窗口内浮层没有系统的 `dismiss`，两端的弹层内容都用它。
struct ClosePanel {
    let run: @MainActor () -> Void
    func callAsFunction() { run() }
}

extension EnvironmentValues {
    @Entry var closePanel = ClosePanel {}
    /// 这一层上面有开着的模态浮层（Mac 的窗口内浮层，`PanelHost.covers`；iOS 的弹层是系统的，恒为假）：
    /// 被盖住的输入框不要焦点——出现时的自动聚焦、焦点请求都先看它（盖上时交出见 `yieldsFocusWhenCovered`）。
    @Entry var panelCovered = false
    /// 抽屉关着、已滑到窗外（`DrawerSlide`）：里面自己托管的视图（Mac 的 Cue 栏）据此藏起，⌃Tab 不轮到看不见的那一块。
    @Entry var drawerParked = false
}

enum PanelStyle: Equatable {
    /// 居中、模态（iOS 是 sheet）。
    case sheet
    /// 大块内容（预览）：iOS 全屏覆盖，Mac 同 `sheet`。
    case fullScreen
    /// 长出来的气泡（`BubbleFrame`，摆法在 `BubblePlacement`）：不压暗，点外面或 Esc 关、那一下照常落到下面；两端同一个样子（iOS 不是系统 sheet）。
    /// 两端都画在窗口那一层（`panelHost`）。从控件长出的用 `bubble(isPresented:)`，它替控件量框。宽默认随内容（`BubblePlacement.Width`）。
    case bubble(BubbleSource, width: BubblePlacement.Width = .fitting)
    /// 右缘抽屉（`drawer(isPresented:)`）：贴窗口右缘、整窗高，发丝边加面板阴影、不压暗，开合滑入滑出。
    /// 点外面或 Esc 关，那一下不落到下面（同 sheet：点外面是"关掉它"，不是点了下面那张卡）；不拿走焦点，按键照常进窗口。
    case drawer

    /// 模态：压暗、拦下外面的点按、拿走焦点（居中的 sheet 与全屏）。
    var modal: Bool {
        switch self {
        case .sheet, .fullScreen: true
        case .bubble, .drawer: false
        }
    }

    /// 点外面关的那一下不落到下面。
    var catchesOutside: Bool { modal || self == .drawer }
}

extension View {
    /// 弹层：调用处只给状态与内容，平台只换呈现。iOS 是系统 sheet（`fullScreen` 时全屏覆盖）；Mac 是窗口内浮层（`panelHost`）——
    /// AppKit 的窗口 sheet 开、关都把主线程关在约 300ms 的嵌套动画循环里，关的那一段整窗不出帧。Mac 上窗口内的浮层（⌘K、任务气泡、
    /// 挑任务、表单、确认框）都只走这里。内容用环境里的 `closePanel` 关自己。
    func panel(isPresented: Binding<Bool>, style: PanelStyle = .sheet, @ViewBuilder content: @escaping () -> some View) -> some View {
        panel(item: Binding { isPresented.wrappedValue ? Shown() : nil } set: { isPresented.wrappedValue = $0 != nil }, style: style) { _ in content() }
    }

    func panel<Item: Identifiable>(
        item: Binding<Item?>, style: PanelStyle = .sheet, @ViewBuilder content: @escaping (Item) -> some View
    ) -> some View {
        presentPanel(item: item, style: style, close: ClosePanel { item.wrappedValue = nil }, content: content)
    }

    /// 右缘抽屉（`PanelStyle.drawer`）：挂上就建好内容、一直挂着（同 `keptPanel`），关着只是滑出窗外、暂停订阅（`pageActive`），开合不丢里面的状态与滚动位置。
    /// 挂它的视图走了才卸下。
    func drawer(isPresented: Binding<Bool>, @ViewBuilder content: @escaping () -> some View) -> some View {
        presentDrawer(isPresented: isPresented, content: content)
    }
}

/// `panel(isPresented:)` 的身份：开着只有这一个。
private struct Shown: Identifiable { let id = true }

/// 抽屉的面（`PanelStyle.drawer`）：桌面底连同面板阴影、左缘一道发丝边，都铺到安全区外，内容照样排在安全区里。宽由内容定。
struct DrawerSurface: ViewModifier {
    @Environment(\.palette) private var palette

    func body(content: Content) -> some View {
        content
            .frame(maxHeight: .infinity)
            // 影子只挂在底那块上：挂在整块内容上要先离屏合成里面的字再糊影子（同 `PaperSurface`）
            .background { palette.desk.elevation(.panel).ignoresSafeArea() }
            .overlay(alignment: .leading) { palette.hair.frame(width: 1).ignoresSafeArea() }
    }
}

/// 抽屉开合：整块从窗口右缘外滑入、滑回窗外（渲染端的平移，`visualEffect` 不让页每帧重排），关着时点不到；减弱动态效果时直接到位。
/// 滑出去落定后报 `drawerParked`，开的那一下当即撤掉。
struct DrawerSlide: ViewModifier {
    let open: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false
    @State private var parked = true

    /// 关着时多挪出去的一截：面板阴影不留在窗口右缘。
    private static let shadowRoom: CGFloat = 40

    func body(content: Content) -> some View {
        content
            .environment(\.drawerParked, parked)
            .visualEffect { [shown, room = Self.shadowRoom] effect, proxy in effect.offset(x: shown ? 0 : proxy.size.width + room) }
            .allowsHitTesting(open)
            .onChange(of: open, initial: true) { _, open in
                if open { parked = false }
                withAnimation(Motion.spatial(Motion.nudge, reduceMotion: reduceMotion)) { shown = open } completion: { parked = !shown }
            }
    }
}
