#if os(iOS)
import SwiftUI
import UIKit

extension View {
    func presentPanel<Item: Identifiable>(
        item: Binding<Item?>, style: PanelStyle, close: ClosePanel, @ViewBuilder content: @escaping (Item) -> some View
    ) -> some View {
        Group {
            switch style {
            case .fullScreen:
                self.fullScreenCover(item: item) { content($0).modalPage(close) }
            case .bubble(let source, let width):
                let shown = item.wrappedValue
                self.modifier(BubbleSlot(key: shown.map { AnyHashable($0.id) }, source: source, width: width, close: close) { if let shown { content(shown) } })
            case .sheet:
                self.sheet(item: item) { content($0).modalPage(close) }
            case .drawer:
                self.presentDrawer(isPresented: Binding { item.wrappedValue != nil } set: { if !$0 { close() } }) {
                    if let shown = item.wrappedValue { content(shown) }
                }
            }
        }
    }

    func presentDrawer(isPresented: Binding<Bool>, @ViewBuilder content: @escaping () -> some View) -> some View {
        modifier(DrawerSlot(open: isPresented.wrappedValue, close: ClosePanel { isPresented.wrappedValue = false }, panel: content))
    }

    /// sheet 与全屏是盖在上面的一页新的，不吃挂它那一页的页内环境（呈现的内容照样继承呈现处的环境）：
    /// 页顶那一排画在它自己的导航栏里（根页、iPad 的 Cue 面板给的 `HeaderHost` 会让它不画标题、改画成根页那一排），
    /// 底下那页被提示横幅盖着时它不跟着让开、不算长开的面板里，它在前台（看板分段、翻走的根页给的 `pageActive` 不算数）。
    fileprivate func modalPage(_ close: ClosePanel) -> some View {
        // sheet 是另一层呈现，窗口那一层的气泡画不到它上面：里面长出的气泡画在它自己的这一层
        panelHost()
            .environment(\.closePanel, close)
            .environment(\.headerHost, .navigationBar)
            .environment(\.headerGivesWay, false)
            .environment(\.headerGrown, false)
            .environment(\.pageActive, true)
            .environment(\.pagePrefetch, false)
    }

    /// 窗口里每一次手指落下都报给 `pressed`（窗口坐标），不拦这一下（任务气泡从这里长出来，`Workspace.pressed`）。
    func watchesTouches(_ pressed: @escaping (CGPoint) -> Void) -> some View {
        background { TouchWatch { point, _ in pressed(point) } }
    }
}

/// 窗口里的气泡（`PanelStyle.bubble`）都画在这里，同 Mac 的 `PanelHost`：场景的根挂一次（`panelHost()`，盖住窄屏与宽屏），
/// sheet 与全屏页里各挂一次（`modalPage`）。挂在页里、控件上的气泡画不出控件那么大的框（输入框还把它裁掉），所以不各画各的。
/// 一次只开一个：手指落在开着的那个外面就先关它，再点出下一个。内容带着呈现处的环境画（`BubbleSlot`），这一层在 Workspace 之外也画得对。
@Observable
final class PanelHost {
    struct Shown {
        let token: UUID
        /// 换了这个就是另一个气泡（换一条任务）：旧的退场、新的进场。
        let identity: AnyHashable
        let source: BubbleSource
        let width: BubblePlacement.Width
        let content: AnyView
        let close: ClosePanel
    }

    private(set) var shown: Shown?
    /// 右缘抽屉（`PanelStyle.drawer`）：挂上就一直在，关着时滑在窗外（`open`）。
    struct Drawer {
        let token: UUID
        let open: Bool
        let content: AnyView
        let close: ClosePanel
    }

    fileprivate(set) var drawer: Drawer?
    /// 这一层（窗口、sheet）的字号：气泡内容按它画，不按呈现处——呈现处可能在一排封了字号的控件里（工具排），气泡里是能放大的说明。
    @ObservationIgnored fileprivate var typeSize = DynamicTypeSize.large

    /// 气泡里字号的上限，同 Cue 面板。
    static let largestType = DynamicTypeSize.accessibility1

    func show(_ entry: Shown) { shown = entry }

    /// 把一处气泡的内容交给这一层（`panel(style: .bubble)`）：连同呈现处的环境，字号按这一层的。
    func present(
        token: UUID, key: AnyHashable, source: BubbleSource, width: BubblePlacement.Width, close: ClosePanel, environment: EnvironmentValues, content: some View
    ) {
        show(Shown(
            token: token, identity: [AnyHashable(token), key], source: source, width: width,
            content: AnyView(
                content.environment(\.closePanel, close)
                    .environment(\.dynamicTypeSize, min(typeSize, Self.largestType))
                    .environment(\.self, environment)),
            close: close))
    }

    func hide(_ token: UUID) {
        if shown?.token == token { shown = nil }
    }

}

extension View {
    /// 场景的根与 sheet 各挂一次（同 Mac 的 `panelHost`）：这一层的气泡都画在这里。
    func panelHost() -> some View { modifier(PanelHostModifier()) }

    /// 从这个控件（按钮、圆钮、胶囊）长出的气泡，同 Mac：挂在它的框下（放不下挂上面），尾巴指它。宽默认随内容（`BubblePlacement.Width`）。
    func bubble(isPresented: Binding<Bool>, width: BubblePlacement.Width = .fitting, @ViewBuilder content: @escaping () -> some View) -> some View {
        modifier(ControlBubble(isPresented: isPresented, width: width, panel: content))
    }
}

private struct PanelHostModifier: ViewModifier {
    @State private var host = PanelHost()
    @State private var modals = ModalHost()
    @Environment(\.dynamicTypeSize) private var typeSize

    func body(content: Content) -> some View {
        content
            .modifier(ModalLayers(host: modals))
            .onChange(of: typeSize, initial: true) { host.typeSize = typeSize }
            .overlay { DrawerLayer(drawer: host.drawer) }
            .overlay { BubbleLayer(shown: host.shown) }
            .environment(host)
    }
}

/// 一处 `panel(style: .bubble)`：开着时把内容交给这一层的 `PanelHost`，连同呈现处的环境（这一层可能在 Workspace 之外）；字号除外，按这一层的（`PanelHost.typeSize`）。
private struct BubbleSlot<Panel: View>: ViewModifier {
    let key: AnyHashable?
    let source: BubbleSource
    let width: BubblePlacement.Width
    let close: ClosePanel
    @ViewBuilder let panel: () -> Panel
    @Environment(PanelHost.self) private var host: PanelHost?
    @Environment(\.self) private var environment
    @State private var token = UUID()

    func body(content: Content) -> some View {
        content
            .onChange(of: Mode(key: key, source: source, width: width), initial: true) { _, mode in
                guard let host else { return }
                guard let key = mode.key else { return host.hide(token) }
                host.present(token: token, key: key, source: mode.source, width: mode.width, close: close, environment: environment, content: panel())
            }
            .onDisappear { host?.hide(token) }
    }

    private struct Mode: Equatable {
        let key: AnyHashable?
        let source: BubbleSource
        let width: BubblePlacement.Width
    }
}

/// 一处 `drawer(isPresented:)`：挂上就把内容交给这一层的 `PanelHost`（连同呈现处的环境，同 `BubbleSlot`），走了才收回。
/// 开合与外观（深浅色、字号、对比度）变了重交一次：内容一直挂着，带的环境不跟着这些变就停在交出去那一刻；类型不变，里面的状态照留。
private struct DrawerSlot<Panel: View>: ViewModifier {
    let open: Bool
    let close: ClosePanel
    @ViewBuilder let panel: () -> Panel
    @Environment(PanelHost.self) private var host: PanelHost?
    @Environment(\.self) private var environment
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var token = UUID()

    func body(content: Content) -> some View {
        content
            .onChange(of: Mode(open: open, scheme: scheme, contrast: contrast, typeSize: typeSize), initial: true) { _, mode in
                host?.drawer = PanelHost.Drawer(
                    token: token, open: mode.open,
                    content: AnyView(panel().modifier(DrawerSurface()).environment(\.pageActive, mode.open).environment(\.closePanel, close).environment(\.self, environment)),
                    close: close)
            }
            .onDisappear { if host?.drawer?.token == token { host?.drawer = nil } }
    }

    private struct Mode: Equatable {
        let open: Bool
        let scheme: ColorScheme
        let contrast: ColorSchemeContrast
        let typeSize: DynamicTypeSize
    }
}

/// 抽屉那一层：开着时先铺一层接点按的透明底（手指落在抽屉外就关，那一下不落到下面；收起那一下就撤，`transition(.identity)`），
/// 抽屉贴右缘、整窗高；外接键盘的 Esc 同关。
private struct DrawerLayer: View {
    let drawer: PanelHost.Drawer?

    var body: some View {
        ZStack(alignment: .trailing) {
            if let drawer {
                if drawer.open {
                    Color.clear.contentShape(.rect)
                        .gesture(DragGesture(minimumDistance: 0).onChanged { _ in drawer.close() })
                        .overlay { Button("关闭") { drawer.close() }.keyboardShortcut(.escape, modifiers: []).opacity(0).accessibilityHidden(true) }
                        .ignoresSafeArea()
                        .transition(.identity)
                }
                drawer.content.modifier(DrawerSlide(open: drawer.open)).readerHidden(!drawer.open)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
    }
}

/// 从控件长出的气泡（`View.bubble(isPresented:)`）：开着时按 SwiftUI 量的框长出。量的框记在不触发重算的盒子里：控件随滚动、键盘挪动不重算这一层。
/// 系统导航栏里的项用不了它（栏里的项建好之后系统不再跑它上面的 `onChange`）：栏里的问号是系统 popover（`BarHelpButton`）。
private struct ControlBubble<Panel: View>: ViewModifier {
    @Binding var isPresented: Bool
    let width: BubblePlacement.Width
    @ViewBuilder let panel: () -> Panel
    @State private var measured = Measured()

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { measured.frame = $0 }
            .panel(isPresented: $isPresented, style: .bubble(isPresented ? measured.frame.map(BubbleSource.control) ?? .unanchored : .unanchored, width: width), content: panel)
    }

    private final class Measured {
        var frame: CGRect?
    }
}

/// 气泡那一层：铺满宿主、一直在，气泡在里面进出（进出场挂在被插入、移除的那一层上）。手指落在气泡外面就关（那一下照常落到下面，
/// 点另一条任务就是换成它的气泡）。键盘升起时（在气泡里写字）气泡收起尾巴、整块往上挪到键盘上沿之上，只挪不重排；
/// 放不下才矮下去、在里面滚。这一层不让键盘（`ignoresSafeArea(.keyboard)`）：摆法始终对着整个容器算，键盘只给一条下沿（`BubbleStage.floor`）。
private struct BubbleLayer: View {
    let shown: PanelHost.Shown?
    /// 键盘上沿（窗口坐标）；键盘收着为 nil。
    @State private var keyboardTop: CGFloat?
    /// 贴在底部的纸被往下拖了多远（`BubbleDrag`）。
    @State private var drag: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let source = shown?.source ?? .unanchored
        GeometryReader { proxy in
            let frame = proxy.frame(in: .global)
            let placement = BubblePlacement(source: source, container: frame, insets: Self.insets, width: shown?.width ?? .fitting).lifted(keyboardTop != nil)
            BubbleStage(floor: keyboardTop.map { $0 - frame.minY - Self.insets.bottom }, ceiling: Self.insets.top) {
                if let shown {
                    BubbleFrame(placement: placement) {
                        shown.content
                    } area: {
                        TouchWatch { point, area in
                            if !area.bounds.contains(area.convert(point, from: nil)) { shown.close() }
                        }
                    }
                    .offset(y: drag)
                    .environment(\.bubbleDrag, source == .bottom ? BubbleDrag(changed: dragged, ended: released) : nil)
                    .id(shown.identity)
                    .transition(placement.transition(reduceMotion: reduceMotion))
                }
            }
            .coordinateSpace(.named(BubbleStage.space))
        }
        // 贴在底部的纸伸进 Home 指示条那一截：与屏幕圆角同心
        .ignoresSafeArea(source == .bottom ? .all : .keyboard, edges: source == .bottom ? .bottom : .all)
        .allowsHitTesting(shown != nil)
        .animation(Motion.fading(Motion.nudge, reduceMotion: reduceMotion), value: shown?.identity)
        .animation(Motion.spatial(Motion.nudge, reduceMotion: reduceMotion), value: keyboardTop)
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { note in
            guard shown != nil, let end = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
            // 键盘开着时只往上让、不往下回：菜单一开候选栏收起、键盘矮一截，气泡跟着掉下去再弹回来是看得见的抖（同 `KeyboardHold`）；
            // 收起时末位在屏幕下面，也不往下挪，随后的 willHide 清掉
            keyboardTop = min(keyboardTop ?? end.minY, end.minY)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in keyboardTop = nil }
        .onChange(of: shown == nil) { if shown == nil { keyboardTop = nil } else { drag = 0 } }
    }

    /// 往下跟手；往上拉不动，越拉越沉。
    private func dragged(_ translation: CGFloat) {
        drag = translation > 0 ? translation : -pow(-translation, 0.6)
    }

    /// 松手按去势定去留（`predicted` 是照这股劲滑到哪）：拖得够远或甩得够快就关、从此刻的位置落回底边，否则弹回。
    private func released(_ translation: CGFloat, predicted: CGFloat) {
        if max(translation, predicted) > Self.dismissDrag { shown?.close(); return }
        withAnimation(Motion.spatial(Motion.nudge, reduceMotion: reduceMotion)) { drag = 0 }
    }

    /// 拖过（或照去势会滑过）这么远就关。
    private static var dismissDrag: CGFloat { 140 }

    /// 气泡离安全区的边（状态栏、Home 指示条、键盘）。
    private static var insets: EdgeInsets { EdgeInsets(top: 8, leading: BubblePlacement.margin, bottom: 8, trailing: BubblePlacement.margin) }
}

/// 贴在底部的纸里的把手报给纸那一层：拖了多远、松手时照去势会滑到哪。纸那一层只挪图层（`offset`），纸里不重排。
struct BubbleDrag {
    let changed: (CGFloat) -> Void
    let ended: (_ translation: CGFloat, _ predicted: CGFloat) -> Void
}

extension EnvironmentValues {
    @Entry var bubbleDrag: BubbleDrag?
}

/// 贴在底部的纸顶上的把手：整条横着都接拖动（往下关，`BubbleDrag`），只画中间一小截。
struct SheetGrabber: View {
    @Environment(\.bubbleDrag) private var drag
    @Environment(\.palette) private var palette

    var body: some View {
        Capsule().fill(palette.track).frame(width: 36, height: 5)
            .frame(maxWidth: .infinity).frame(height: 18, alignment: .bottom)
            .contentShape(.rect)
            .gesture(
                DragGesture(minimumDistance: 2, coordinateSpace: .global)
                    .onChanged { drag?.changed($0.translation.height) }
                    .onEnded { drag?.ended($0.translation.height, $0.predictedEndTranslation.height) })
            .accessibilityHidden(true)
    }
}

/// 窗口上挂一个只看不拦的手势：每次手指落下把窗口坐标与自己（量自己占的地方用）交给 `down`。随这个视图进出窗口装卸。
private struct TouchWatch: UIViewRepresentable {
    let down: (CGPoint, UIView) -> Void

    func makeUIView(context: Context) -> Probe { Probe() }
    func updateUIView(_ view: Probe, context: Context) { view.down = down }

    final class Probe: UIView {
        var down: (CGPoint, UIView) -> Void = { _, _ in }
        private lazy var watch = Watch(probe: self)

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
        }

        required init?(coder: NSCoder) { nil }

        override func willMove(toWindow window: UIWindow?) {
            super.willMove(toWindow: window)
            watch.view?.removeGestureRecognizer(watch)
            window?.addGestureRecognizer(watch)
        }
    }

    /// 只看不认：落下的那一刻报一下就作废，不延迟、不取消别的手势与触摸。
    final class Watch: UIGestureRecognizer, UIGestureRecognizerDelegate {
        private weak var probe: Probe?

        init(probe: Probe) {
            self.probe = probe
            super.init(target: nil, action: nil)
            cancelsTouchesInView = false
            delaysTouchesBegan = false
            delaysTouchesEnded = false
            delegate = self
        }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
            if let probe, let touch = touches.first { probe.down(touch.location(in: nil), probe) }
            state = .failed
        }

        func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    }
}
#endif

