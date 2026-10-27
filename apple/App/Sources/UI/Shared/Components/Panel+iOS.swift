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
            case .bubble(let source):
                self.overlay { BubbleLayer(item: item.wrappedValue, source: source, close: close, content: content) }
            case .sheet:
                self.sheet(item: item) { content($0).modalPage(close) }
            }
        }
    }

    /// sheet 与全屏是盖在上面的一页新的，不吃挂它那一页的页内环境（呈现的内容照样继承呈现处的环境）：
    /// 页顶那一排画在它自己的导航栏里（根页、iPad 的 Cue 面板给的 `HeaderHost` 会让它不画标题、改画成根页那一排），
    /// 底下那页被提示横幅盖着时它不跟着让开、不算长开的面板里，它在前台（看板分段、翻走的根页给的 `pageActive` 不算数）。
    fileprivate func modalPage(_ close: ClosePanel) -> some View {
        environment(\.closePanel, close)
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

/// 气泡那一层：铺满所在的视图、一直在，气泡在里面进出（进出场挂在被插入、移除的那一层上）。手指落在气泡外面就关（那一下照常落到下面，
/// 点另一条任务就是换成它的气泡）。键盘升起时（在气泡里写字）气泡收起尾巴、整块往上挪到键盘上沿之上，只挪不重排；
/// 放不下才矮下去、在里面滚。这一层不让键盘（`ignoresSafeArea(.keyboard)`）：摆法始终对着整个容器算，键盘只给一条下沿（`BubbleStage.floor`）。
private struct BubbleLayer<Item: Identifiable, Panel: View>: View {
    let item: Item?
    let source: BubbleSource
    let close: ClosePanel
    @ViewBuilder let content: (Item) -> Panel
    /// 键盘上沿（窗口坐标）；键盘收着为 nil。
    @State private var keyboardTop: CGFloat?
    /// 贴在底部的纸被往下拖了多远（`BubbleDrag`）。
    @State private var drag: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            let frame = proxy.frame(in: .global)
            let placement = BubblePlacement(source: source, container: frame, insets: Self.insets).lifted(keyboardTop != nil)
            BubbleStage(floor: keyboardTop.map { $0 - frame.minY - Self.insets.bottom }, ceiling: Self.insets.top) {
                if let item {
                    BubbleFrame(placement: placement) {
                        content(item).environment(\.closePanel, close)
                    } area: {
                        TouchWatch { point, area in
                            if !area.bounds.contains(area.convert(point, from: nil)) { close() }
                        }
                    }
                    .offset(y: drag)
                    .environment(\.bubbleDrag, source == .bottom ? BubbleDrag(changed: dragged, ended: released) : nil)
                    .id(item.id)
                    .transition(placement.transition(reduceMotion: reduceMotion))
                }
            }
        }
        // 贴在底部的纸伸进 Home 指示条那一截：与屏幕圆角同心，盖住底部那一排
        .ignoresSafeArea(source == .bottom ? .all : .keyboard, edges: source == .bottom ? .bottom : .all)
        .animation(Motion.fading(Motion.nudge, reduceMotion: reduceMotion), value: item?.id)
        .animation(Motion.spatial(Motion.nudge, reduceMotion: reduceMotion), value: keyboardTop)
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { note in
            guard item != nil, let end = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
            // 键盘开着时只往上让、不往下回：菜单一开候选栏收起、键盘矮一截，气泡跟着掉下去再弹回来是看得见的抖（同 `KeyboardHold`）；
            // 收起时末位在屏幕下面，也不往下挪，随后的 willHide 清掉
            keyboardTop = min(keyboardTop ?? end.minY, end.minY)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in keyboardTop = nil }
        .onChange(of: item == nil) { if item == nil { keyboardTop = nil } else { drag = 0 } }
    }

    /// 往下跟手；往上拉不动，越拉越沉。
    private func dragged(_ translation: CGFloat) {
        drag = translation > 0 ? translation : -pow(-translation, 0.6)
    }

    /// 松手按去势定去留（`predicted` 是照这股劲滑到哪）：拖得够远或甩得够快就关、从此刻的位置落回底边，否则弹回。
    private func released(_ translation: CGFloat, predicted: CGFloat) {
        if max(translation, predicted) > Self.dismissDrag { return close() }
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
