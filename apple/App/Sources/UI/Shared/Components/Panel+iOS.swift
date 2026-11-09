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
                self.fullScreenCover(item: item) { content($0).modalPage(close.of($0.id)) }
            case .bubble(let source, let width):
                let shown = item.wrappedValue
                self.modifier(BubbleSlot(key: shown.map { AnyHashable($0.id) }, source: source, width: width, close: close) { if let shown { content(shown) } })
            case .sheet:
                self.sheet(item: item) { content($0).modalPage(close.of($0.id)) }
            }
        }
    }

    /// sheet 与全屏是盖在上面的一页新的，不吃挂它那一页的页内环境（呈现的内容照样继承呈现处的环境）。
    fileprivate func modalPage(_ close: ClosePanel) -> some View {
        // sheet 是另一层呈现，窗口那一层的气泡画不到它上面：里面长出的气泡画在它自己的这一层
        panelHost()
            .environment(\.closePanel, close)
            // 页顶那一排画在它自己的导航栏里，不吃根页给的让开、长开面板与前台状态
            .environment(\.headerHost, .navigationBar)
            .environment(\.headerGivesWay, false)
            .environment(\.headerGrown, false)
            .environment(\.pageActive, true)
            .environment(\.pagePrefetch, false)
    }

    /// 不拦这一下（任务气泡从这里长出来，`Workspace.pressed`）。
    func watchesTouches(_ pressed: @escaping (CGPoint) -> Void) -> some View {
        background { TouchWatch { point, _ in pressed(point) } }
    }
}

/// 挂在页里、控件上的气泡画不出控件那么大的框（输入框还把它裁掉），所以不各画各的。一次只开一个：手指落在开着的那个外面就先关它，再点出下一个。
@Observable
final class PanelHost {
    struct Shown {
        let token: UUID
        let identity: AnyHashable
        let source: BubbleSource
        let width: BubblePlacement.Width
        let content: AnyView
        let close: ClosePanel
    }

    private(set) var shown: Shown?
    /// 这一层（窗口、sheet）的字号：气泡内容按它画，不按呈现处——呈现处可能在一排封了字号的控件里（工具排），气泡里是能放大的说明。
    @ObservationIgnored fileprivate var typeSize = DynamicTypeSize.large

    static let largestType = DynamicTypeSize.accessibility1

    func show(_ entry: Shown) { shown = entry }

    func present(
        token: UUID, key: AnyHashable, source: BubbleSource, width: BubblePlacement.Width, close: ClosePanel, environment: EnvironmentValues, content: some View
    ) {
        show(Shown(
            token: token, identity: [AnyHashable(token), key], source: source, width: width,
            content: AnyView(
                content.environment(\.closePanel, close.of(token))
                    .environment(\.dynamicTypeSize, min(typeSize, Self.largestType))
                    .environment(\.self, environment)),
            close: close))
    }

    func hide(_ token: UUID) {
        if shown?.token == token { shown = nil }
    }

}

extension View {
    func panelHost() -> some View { modifier(PanelHostModifier()) }

    func bubble(isPresented: Binding<Bool>, width: BubblePlacement.Width = .fitting, @ViewBuilder content: @escaping () -> some View) -> some View {
        modifier(ControlBubble(isPresented: isPresented, width: width, panel: content))
    }
}

private struct PanelHostModifier: ViewModifier {
    @State private var host = PanelHost()
    @State private var modals = ModalHost()
    @Environment(\.dynamicTypeSize) private var typeSize

    func body(content: Content) -> some View {
        let covered = modals.modal != nil
        content
            // 模态浮出开着时 Esc 归它（`ModalScrim`），抽屉不挂自己的（`DrawerCatcher`）
            .environment(\.escapeTaken, covered)
            .onChange(of: typeSize, initial: true) { host.typeSize = typeSize }
            // 任何模态浮出开着时，窗口的气泡都不读；浮出外面的页与栏由放它的地方藏（浮窗：`ModalLayers` 整块，名牌：所在的页与 iPad 的 `SplitRoot`）
            .overlay { BubbleLayer(shown: host.shown).readerHidden(covered) }
            // 模态浮出盖在这一层的最上面：开着的气泡上、iPad 抽屉里长开的名牌外面的一下也由它接住，浮窗开着时气泡一起不进读屏
            .modifier(ModalLayers(host: modals))
            .environment(host)
    }
}

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

/// 量的框记在不触发重算的盒子里：控件随滚动、键盘挪动不重算这一层。
/// 系统导航栏里的项用不了它（栏里的项建好之后系统不再跑它上面的 `onChange`）：栏里的问号由钮自己量框交出气泡（`BarHelpButton`）。
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

/// 点另一条任务就是换成它的气泡）。键盘升起时（在气泡里写字）气泡收起尾巴、整块往上挪到键盘上沿之上，只挪不重排；
/// 放不下才矮下去、在里面滚。这一层不让键盘（`ignoresSafeArea(.keyboard)`）：摆法始终对着整个容器算，键盘只给一条下沿（`BubbleStage.floor`）。
private struct BubbleLayer: View {
    let shown: PanelHost.Shown?
    @State private var keyboardTop: CGFloat?
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
                    .environment(\.bubbleDrag, source == .bottom ? BubbleDrag(bubble: shown.identity, changed: dragged, ended: released) : nil)
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

    private func dragged(_ translation: CGFloat) {
        drag = translation > 0 ? translation : -pow(-translation, 0.6)
    }

    private func released(_ translation: CGFloat, predicted: CGFloat) {
        if max(translation, predicted) > Self.dismissDrag { shown?.close(); return }
        withAnimation(Motion.spatial(Motion.nudge, reduceMotion: reduceMotion)) { drag = 0 }
    }

    private static var dismissDrag: CGFloat { 140 }

    private static var insets: EdgeInsets { EdgeInsets(top: 8, leading: BubblePlacement.margin, bottom: 8, trailing: BubblePlacement.margin) }
}

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
            .readerHidden(true)
    }
}

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

