#if os(iOS)
import SwiftUI

/// 模态浮出（手机与 iPad）：居中的浮窗（`popup(isPresented:)`）与页里原地长开的面板（`GrowPanel`）。
/// 点外面、Esc、读屏的退出手势怎么关，背后进不进读屏，只在这里一处（`ModalHost`、`ModalScrim`），窗口那一层（`panelHost`）挂一份：
/// - 开着时铺一层接点按的底，盖在整窗上（会话条、提示横幅、iPad 的别的栏都在它下面）：手指一落在浮出外面就关，
///   那一下不落到下面（点外面是"关掉它"，不是点了下面那张卡）；收起那一下就撤（`transition(.identity)`），紧接着的点按照常落到下面。
///   页里长开的面板在这一层下面：它报来自己的框（`ModalHost.hole`），底在那一块开个洞，面板自己接点按。
/// - 读屏：浮窗开着时背后整窗不进读屏；页里长开的面板由所在的页藏起旁边的（`FloatingHeader`、`NarrowCue`）。
///   浮出标为模态，开时读屏从它读起，关后焦点回到长出它的那颗钮（#68）。
/// 气泡（`PanelStyle.bubble`）不是模态：点外面关、那一下照常落到下面（`BubbleLayer`）；右缘抽屉的点外面关在它自己那一层（`DrawerLayer`）。
@Observable
final class ModalHost {
    /// 开着的那一个：一个窗口一次只一个。
    private(set) var modal: Modal?
    /// 页里原地长开的那块（`Modal.inPage`）此刻在窗口里的框：开合的每一帧都在变，单放一处，只有接点按的那一层读它。
    private(set) var hole: CGRect?

    /// 开着一个：后开的顶掉先开的（先关它，同点在它外面）。页里长开的给它此刻的框。
    func cover(_ entry: Modal, hole: CGRect? = nil) {
        if let modal, modal.token != entry.token { modal.close() }
        modal = entry
        self.hole = hole
    }

    func uncover(_ token: UUID) {
        guard modal?.token == token else { return }
        modal = nil
        hole = nil
    }

    func reshape(_ token: UUID, hole: CGRect) {
        if modal?.token == token, self.hole != hole { self.hole = hole }
    }

    struct Modal {
        let token: UUID
        let close: ClosePanel
        /// 页里原地长开的面板（`GrowPanel`）：它在这一层下面，报来自己的框（`reshape`），那一块留给它自己接点按。
        var inPage = false
        /// 居中的浮窗：画在这一层，背后压暗。
        var popup: Popup?
    }

    struct Popup {
        /// 长出它的那颗钮在窗口里的框：从这里长出、收回这里。
        let source: CGRect
        let content: AnyView
    }
}

extension View {
    /// 居中的浮窗（进展页的额度）：从这颗钮长出、落在窗口正中，背后压暗；同一块实底玻璃从钮的框长到浮窗的框，字按终点排好、玻璃长过三成才淡出来，
    /// 不缩放字（有字的一块进出场不缩放，理由在 `Bubble.swift`）；收起原路缩回钮上。减弱动态效果时只淡。
    /// 宽是窗口减两侧页边、最宽 `PopupLayer.widest`，高随内容（内容里不放滚动区，同 `GrowPanel`）。离开页面（`pageActive`）、钮走了都收起。
    func popup(isPresented: Binding<Bool>, @ViewBuilder content: @escaping () -> some View) -> some View {
        modifier(PopupSlot(isPresented: isPresented, panel: content))
    }
}

/// 窗口那一层（`panelHost`）挂的模态浮出：浮窗开着时背后整窗不进读屏，接点按的底与浮窗盖在整窗上。
struct ModalLayers: ViewModifier {
    let host: ModalHost

    func body(content: Content) -> some View {
        content
            .readerHidden(host.modal?.popup != nil)
            .overlay { ModalScrim(modal: host.modal, hole: host.hole) }
            .overlay { PopupLayer(modal: host.modal) }
            .environment(host)
            .debugExposesModals(host)
    }
}

private struct PopupSlot<Panel: View>: ViewModifier {
    @Binding var isPresented: Bool
    @ViewBuilder let panel: () -> Panel
    @Environment(ModalHost.self) private var host: ModalHost?
    @Environment(\.self) private var environment
    @Environment(\.pageActive) private var active
    @State private var token = UUID()
    @State private var measured = Measured()
    @AccessibilityFocusState private var focused: Bool

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { measured.frame = $0 }
            .accessibilityFocused($focused)
            .accessibilityExpanded(isPresented)
            .onChange(of: isPresented, initial: true) { was, open in
                guard let host else { return }
                guard open else {
                    host.uncover(token)
                    // 关了：读屏的焦点回到这颗钮
                    if was { focused = true }
                    return
                }
                let close = ClosePanel { [$isPresented] in $isPresented.wrappedValue = false }
                host.cover(ModalHost.Modal(
                    token: token, close: close,
                    popup: ModalHost.Popup(source: measured.frame ?? .zero, content: AnyView(panel().environment(\.closePanel, close).environment(\.self, environment)))))
                Task {
                    await NextFrame.drawn()
                    AccessibilityNotification.ScreenChanged(nil).post()
                }
            }
            .onChange(of: active) { if !active { isPresented = false } }
            .onDisappear {
                isPresented = false
                host?.uncover(token)
            }
            .sensoryFeedback(.impact(weight: .light), trigger: isPresented)
    }

    /// 钮在窗口里的框：记在不触发重算的盒子里，钮随滚动挪动不重算。
    private final class Measured {
        var frame: CGRect?
    }
}

/// 浮窗那一层：浮窗在可用区（安全区里）正中，开合时从钮的框长出、缩回（\`PopupGrow\`）。
struct PopupLayer: View {
    let modal: ModalHost.Modal?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let widest: CGFloat = 440

    var body: some View {
        GeometryReader { proxy in
            let frame = proxy.frame(in: .global)
            ZStack {
                if let modal, let popup = modal.popup {
                    // 钮的框相对浮窗中心（浮窗在这一层正中）：浮窗多高要排出来才知道，长出的形状按排好的框从中心量
                    let source = popup.source.offsetBy(dx: -frame.midX, dy: -frame.midY)
                    popup.content
                        .frame(width: max(min(frame.width - 2 * Spacing.page, Self.widest), 0))
                        .frame(maxHeight: frame.height - 2 * Spacing.page)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityElement(children: .contain)
                        .accessibilityAddTraits(.isModal)
                        .accessibilityAction(.escape) { modal.close() }
                        .id(modal.token)
                        // 玻璃也画在这个转场里（停着时是它的终态）：减弱动态效果时不长、只淡
                        .transition(.modifier(
                            active: PopupGrow(progress: reduceMotion ? 1 : 0, source: source), identity: PopupGrow(progress: 1, source: source))
                            .combined(with: reduceMotion ? .opacity : .identity))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .animation(Motion.fading(Motion.nudge, reduceMotion: reduceMotion), value: modal?.popup == nil ? nil : modal?.token)
    }
}

/// 浮窗的玻璃从钮的框长到浮窗自己的框：\`progress\` 0 是钮、1 是浮窗。每一帧只改一块形状（\`GrowShape\`，不读几何、不排字）；
/// 里面的字按终点排好、裁在这块形状里，玻璃长过三成才淡出来。不开时（\`progress\` 1）就是浮窗本身的那块玻璃：浮窗只经它画玻璃。
private struct PopupGrow: ViewModifier, Animatable {
    var progress: CGFloat
    /// 钮的框，相对浮窗中心。
    let source: CGRect

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    /// 字从这一点起淡出来：玻璃还只有钮那么大时字挤在一小块里，读作一团。
    private static let textFrom: CGFloat = 0.3

    func body(content: Content) -> some View {
        let shape = GrowShape(progress: progress, source: source)
        content
            .opacity(min(max((progress - Self.textFrom) / (1 - Self.textFrom), 0), 1))
            .clipShape(shape)
            // 收回最后那一截玻璃落在钮上淡掉，钮从它底下露出来，不是一块白板盖着钮等弹簧的尾巴
            .background { Color.clear.glass(in: shape).opacity(min(progress / Self.glassFrom, 1)) }
    }

    /// 玻璃在这一点之前淡着：长出时一离开钮就是整块玻璃，收回时贴着钮淡掉。
    private static let glassFrom: CGFloat = 0.15
}

/// 从钮的框（相对中心给）到给的框之间、按 \`progress\` 插好的那一块圆角矩形：圆角从钮的半圆走到 \`Radius.sheet\`。
nonisolated private struct GrowShape: Shape {
    var progress: CGFloat
    let source: CGRect

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let start = source.offsetBy(dx: rect.midX, dy: rect.midY)
        let p = min(max(progress, 0), 1)
        func lerp(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * p }
        let frame = CGRect(x: lerp(start.minX, rect.minX), y: lerp(start.minY, rect.minY), width: lerp(start.width, rect.width), height: lerp(start.height, rect.height))
        let radius = lerp(min(start.width, start.height) / 2, Radius.sheet)
        return Path(roundedRect: frame, cornerRadius: min(radius, frame.height / 2), style: .continuous)
    }
}

/// 模态浮出开着时铺在整窗上的那一层：接住浮出外面的每一下（关，那一下不落到下面），浮窗时背后压暗；外接键盘的 Esc 同关。
struct ModalScrim: View {
    let modal: ModalHost.Modal?
    let hole: CGRect?
    @Environment(\.palette) private var palette

    var body: some View {
        GeometryReader { proxy in
            let origin = proxy.frame(in: .global).origin
            ZStack {
                if modal?.popup != nil {
                    palette.backdrop.allowsHitTesting(false).transition(.opacity)
                }
                if let modal {
                    Color.clear
                        .contentShape(Outside(hole: modal.inPage ? hole?.offsetBy(dx: -origin.x, dy: -origin.y) : nil), eoFill: true)
                        .gesture(DragGesture(minimumDistance: 0).onChanged { _ in modal.close() })
                        .overlay { Button("关闭") { modal.close() }.keyboardShortcut(.escape, modifiers: []).opacity(0).readerHidden(true) }
                        .transition(.identity)
                        .readerHidden(true)
                }
            }
        }
        .ignoresSafeArea()
        .animation(Motion.fade, value: modal?.popup != nil)
    }

    /// 整窗减去开着的那块：奇偶填充，洞里的点不算在形状里。
    nonisolated private struct Outside: Shape {
        let hole: CGRect?

        func path(in rect: CGRect) -> Path {
            var path = Path(rect)
            if let hole { path.addRect(hole) }
            return path
        }
    }
}

#endif
