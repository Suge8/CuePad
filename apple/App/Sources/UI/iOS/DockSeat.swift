#if os(iOS)
import SwiftUI
import UIKit

/// 底边那一格同一时刻只有一个主人：Cue 页里的输入框（`handed`），或底部那一排的 Cue 钮。对象经环境交给 Cue 页，换主人只重算输入框那一层（`DockSeatGate`），
/// 不经 `DockRoot`：不然每换一次，根上四页都要跟着环境重算一遍。
/// 收回时 Cue 钮是长成输入框样子的一块空玻璃：输入框的字与加号要是当场没了，就是条刚一动、"⋯"刚一点，底边先闪一下。
/// 所以收回那一刻按输入框在窗口里的位置拍一张（`ghost`，渲染服务手里现成的那一帧），盖在 Cue 钮上随换形淡出去（`DockGhostView`）。
/// 被否决的：在 Cue 钮里照着画一个输入框——加号、提示语、草稿、图片、多行各有各的样子，差一点就是一跳。
@Observable
final class DockSeat {
    /// 底边交给了页里的输入框。
    private(set) var handed = false
    /// 输入框已画上屏：Cue 钮藏起。
    private(set) var released = false
    /// 最近一次收回时输入框的样子。
    private(set) var ghost: DockGhost?
    /// 输入框在哪（`DockSeatGate` 挂上的一个空视图，跟着输入框的大小与位置）。
    @ObservationIgnored fileprivate weak var anchor: UIView?

    /// 交给输入框：先让它显出来，它画上屏之后 Cue 钮才藏起（输入框的玻璃从藏着到画出来要几帧，这期间 Cue 钮还在，底边不空）；收回当场收。
    func hand(_ owner: Bool) {
        guard owner else {
            if handed { ghost = DockGhost(of: anchor) }
            handed = false
            released = false
            return
        }
        handed = true
        ghost = nil
        Task {
            await NextFrame.drawn()
            if handed { released = true }
        }
    }
}

/// 收回那一刻的输入框：快照与它在窗口里的位置。
struct DockGhost {
    let view: UIView
    let frame: CGRect

    init?(of anchor: UIView?) {
        guard let anchor, let window = anchor.window else { return nil }
        let frame = anchor.convert(anchor.bounds, to: window)
        guard !frame.isEmpty, let view = window.resizableSnapshotView(from: frame, afterScreenUpdates: false, withCapInsets: .zero) else { return nil }
        view.isUserInteractionEnabled = false
        self.view = view
        self.frame = frame
    }
}

/// 输入框只在底边归它时显出、点得到；顺带告诉 `DockSeat` 它在哪。
struct DockSeatGate: ViewModifier {
    let seat: DockSeat?

    func body(content: Content) -> some View {
        let owns = seat?.handed ?? true
        content.opacity(owns ? 1 : 0).allowsHitTesting(owns).accessibilityHidden(!owns)
            .background { if let seat { SeatAnchor(seat: seat) } }
    }
}

private struct SeatAnchor: UIViewRepresentable {
    let seat: DockSeat

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        seat.anchor = view
        return view
    }

    func updateUIView(_ view: UIView, context: Context) { seat.anchor = view }
}

/// 收回时的输入框快照，盖在原处随底部那一排换形淡出：换形走到三成就没了（"⋯"与 Cue 钮的字还没出来，不叠着）。
struct DockGhostView: View {
    let seat: DockSeat
    let motion: PagerMotion
    let placesOpen: Bool

    var body: some View {
        if let ghost = seat.ghost {
            GhostHost(view: ghost.view)
                .frame(width: ghost.frame.width, height: ghost.frame.height)
                .offset(x: ghost.frame.minX, y: ghost.frame.minY)
                .modifier(GhostFade(places: placesOpen ? 1 : 1 - motion.onCue))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

/// 淡出按换形的进度逐帧算（`Animatable`）：点"⋯"时弹簧插的是进度，淡完的那一刻才与拖动时一样落在三成。
private struct GhostFade: ViewModifier, Animatable {
    var places: CGFloat
    private static let fade: CGFloat = 0.3

    var animatableData: CGFloat {
        get { places }
        set { places = newValue }
    }

    func body(content: Content) -> some View { content.opacity(1 - Double(min(places / Self.fade, 1))) }
}

private struct GhostHost: UIViewRepresentable {
    let view: UIView

    func makeUIView(context: Context) -> UIView {
        let host = UIView()
        host.isUserInteractionEnabled = false
        return host
    }

    func updateUIView(_ host: UIView, context: Context) {
        guard view.superview !== host else { return }
        host.subviews.forEach { $0.removeFromSuperview() }
        view.frame.origin = .zero
        host.addSubview(view)
    }
}

extension EnvironmentValues {
    /// 底边那一格归谁（`DockSeat`）；宽屏没有底部那一排，为 nil（输入框一直是自己的）。
    @Entry var dockSeat: DockSeat?
}
#endif
