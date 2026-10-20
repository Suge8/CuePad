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
                self.fullScreenCover(item: item) { content($0).environment(\.closePanel, close) }
            case .bubble(let anchor):
                self.overlay { BubbleLayer(item: item.wrappedValue, anchor: anchor, close: close, content: content) }
            case .sheet, .side:
                self.sheet(item: item) { content($0).environment(\.closePanel, close) }
            }
        }
    }

    /// 窗口里每一次手指落下都报给 `pressed`（窗口坐标），不拦这一下（任务气泡从这里长出来，`Workspace.pressed`）。
    func watchesTouches(_ pressed: @escaping (CGPoint) -> Void) -> some View {
        background { TouchWatch { point, _ in pressed(point) } }
    }
}

/// 气泡那一层：铺满所在的视图、一直在，气泡在里面进出（进出场挂在被插入、移除的那一层上）。手指落在气泡外面就关（那一下照常落到下面，
/// 点另一条任务就是换成它的气泡）。键盘升起时（在气泡里写正文）气泡收起尾巴、贴在键盘上沿，不被键盘盖住。
private struct BubbleLayer<Item: Identifiable, Panel: View>: View {
    let item: Item?
    let anchor: CGPoint?
    let close: ClosePanel
    @ViewBuilder let content: (Item) -> Panel
    @State private var keyboardUp = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            let origin = proxy.frame(in: .global).origin
            let placement = keyboardUp
                ? BubblePlacement(dockedIn: proxy.size, insets: Self.insets)
                : BubblePlacement(anchor: anchor.map { CGPoint(x: $0.x - origin.x, y: $0.y - origin.y) }, container: proxy.size, insets: Self.insets)
            BubbleStage {
                if let item {
                    BubbleFrame(placement: placement) {
                        content(item).environment(\.closePanel, close)
                    } area: {
                        TouchWatch { point, area in
                            if !area.bounds.contains(area.convert(point, from: nil)) { close() }
                        }
                    }
                    .id(item.id)
                    .transition(placement.transition(reduceMotion: reduceMotion))
                }
            }
        }
        .animation(Motion.spatial(Motion.snappy, reduceMotion: reduceMotion) ?? Motion.quick, value: item?.id)
        .animation(Motion.spatial(Motion.snappy, reduceMotion: reduceMotion), value: keyboardUp)
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in if item != nil { keyboardUp = true } }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in keyboardUp = false }
        .onChange(of: item == nil) { if item == nil { keyboardUp = false } }
    }

    /// 气泡离安全区的边（状态栏、Home 指示条、键盘）。
    private static var insets: EdgeInsets { EdgeInsets(top: 8, leading: BubblePlacement.margin, bottom: 8, trailing: BubblePlacement.margin) }
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
