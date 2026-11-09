import SwiftUI

/// Mac 的窗口内浮层没有系统的 `dismiss`，两端的弹层内容都用它。交进浮层内容的环境前按那一层认（`of`：呈现它的那一处的 token 或条目 id），按它比较：呈现处每更新一次都新建一个闭包，闭包没法比，按闭包比的话浮层里读它的视图次次重算；同一层的关法不变，比出相等时读者留着的旧闭包关的也是这一层。
struct ClosePanel: Equatable {
    /// 不可变、只拿来比（token 或条目 id）：比较不在主线程上也读得了。
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
    /// 这一层上面有开着的模态浮层（Mac 的窗口内浮层，`PanelHost.covers`；iOS 的弹层是系统的，恒为假）：
    /// 被盖住的输入框不要焦点——出现时的自动聚焦、焦点请求都先看它（盖上时交出见 `yieldsFocusWhenCovered`）。
    @Entry var panelCovered = false
    /// 由两端的浮层宿主一处报（`panelHost`），抽屉的 Esc 据此让位（`DrawerCatcher`）。
    @Entry var escapeTaken = false
}

enum PanelStyle: Equatable {
    case sheet
    case fullScreen
    /// 点外面或 Esc 关、那一下照常落到下面；iOS 不是系统 sheet。从控件长出的用 `bubble(isPresented:)`，它替控件量框。
    case bubble(BubbleSource, width: BubblePlacement.Width = .fitting)

    var modal: Bool {
        switch self {
        case .sheet, .fullScreen: true
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

/// 抽屉的面（Cue 的右缘抽屉 `CueDock`、会话条的左缘抽屉 `RailDrawer`，只这一份）：底色连同面板阴影、朝窗口里那一侧一道发丝边，
/// 都铺到安全区外，内容照样排在安全区里。宽由内容定。底色随里面放的是什么：Cue 是桌面底，会话条是侧栏底。
struct DrawerSurface: ViewModifier {
    var edge = HorizontalEdge.trailing
    var ground: KeyPath<Palette, Color> = \.desk
    /// 画不画：Cue 那一块放得下时是右边那一栏、不是抽屉（`CueDock`），面不画、块不换。
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
