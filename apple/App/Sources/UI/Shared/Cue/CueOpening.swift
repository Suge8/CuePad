import QuartzCore
import SwiftUI

/// 开门：每次冷启动，窗口先是启动屏那一幕（图标的墨色、正中站着 Cue，iOS 的启动屏就是它：`LaunchBackground`、`LaunchCue`），
/// 两者与这里盖的第一帧要一模一样，接缝才看不出。模拟器的 splashboardd 把资源目录缓存在内存里、重装也不重读（装的路径不变）：
/// 改了这两样，杀掉它（launchd 自己再起）才看得到新的启动屏，不然一直是旧色。
/// Cue 页的天空第一次画好后开门：墨色从 Cue 身上碎成方格、由近及远散开（同 Cue 页天空的像素），前沿一圈是签名色；
/// 整个窗口从近处退回原位，Cue 蹲一下、跳着落回它住的地方（空着的 Cue 页落在云上，否则落进头像，`relaySpot(cue:)`）。
/// 一个进程只放一次：回前台、开第二个窗口都不放。降低动态效果时墨色直接淡掉。
/// 画法同接力（`CueRelayStage`）：整块交给 Core Animation，盖在窗口最底层之上；冷启动时主线程正忙，逐帧不经 App 进程才不掉帧。
/// 墨色、镜头、小人都取自同一条时间线（`OpeningDoor`），采成关键帧一次交出去。
@Observable
final class CueOpening {
    static let shared = CueOpening()

    enum Phase: Equatable {
        case shut
        case opening(landing: CueSpot?)
        case open

        /// 小人还没落下时它要落的那处藏着；门开之前哪处都藏着（落点等门开那一刻才量）。
        func hides(_ spot: CueSpot) -> Bool {
            switch self {
            case .shut: true
            case .opening(let landing): landing == spot
            case .open: false
            }
        }
    }

    private(set) var phase = Phase.shut
    @ObservationIgnored private var began = false
    @ObservationIgnored private var skyDrawn = false
    @ObservationIgnored private var waiting: CheckedContinuation<Void, Never>?

    func drewSky() {
        skyDrawn = true
        release()
    }

    private func release() {
        waiting?.resume()
        waiting = nil
    }

    fileprivate func play(in window: AnyObject, root: CALayer, world: CALayer?, ink: CGColor, edge: CGColor, pose: (idle: CGImage, jump: CGImage), reduceMotion: Bool) {
        guard !began else { return }
        began = true
        if reduceMotion { phase = .open }
        let up = RelayFlight.up(in: root)
        let curtain = OpeningCurtain(root: root, world: world, ink: ink, pose: pose, at: OpeningDoor.start(in: root.bounds), up: up, breathes: !reduceMotion)
        let bounds = root.bounds, paint = (ink: OpeningDoor.pixel(ink), edge: OpeningDoor.pixel(edge))
        let veils = Task.detached { OpeningDoor.veil(in: bounds, ink: paint.ink, edge: paint.edge) }
        Task {
            let clock = ContinuousClock(), start = clock.now
            await sky(by: start + OpeningDoor.patience)
            try? await clock.sleep(until: start + OpeningDoor.dwell)
            await NextFrame.drawn()
            guard !reduceMotion else { return await curtain.fade() }
            let landing = Self.landing(in: window, root: root)
            let door = OpeningDoor(bounds: root.bounds, up: up, landing: landing)
            phase = .opening(landing: landing?.spot)
            await curtain.open(door, veils: await veils.value)
            phase = .open
            await NextFrame.drawn()
            curtain.remove()
        }
    }

    private func sky(by deadline: ContinuousClock.Instant) async {
        guard !skyDrawn else { return }
        await withCheckedContinuation { continuation in
            waiting = continuation
            Task {
                try? await Task.sleep(until: deadline)
                release()
            }
        }
    }

    /// 落在哪：云上的小人在就落它身上，否则落进看得见的那个头像（按图的宽高比套进头像那一圈）。
    private static func landing(in window: AnyObject, root: CALayer) -> OpeningDoor.Landing? {
        let spots = RelayAnchorView.all(in: window).compactMap { anchor -> (spot: CueSpot, frame: CGRect)? in
            guard case .cue(let spot) = anchor.role, let frame = anchor.frame(in: root) else { return nil }
            return (spot, frame)
        }
        guard let (spot, frame) = spots.max(by: { $0.spot.rawValue < $1.spot.rawValue }) else { return nil }
        if spot == .perch { return OpeningDoor.Landing(spot: spot, frame: frame) }
        let height = frame.width * OpeningDoor.cue.height / OpeningDoor.cue.width
        return OpeningDoor.Landing(spot: spot, frame: CGRect(x: frame.minX, y: frame.midY - height / 2, width: frame.width, height: height))
    }
}

extension View {
    /// 挂在窗口的根上：第一次进窗口就把墨色盖上（与启动屏同一帧接上），之后照 `CueOpening` 开门。
    func cueOpening() -> some View { modifier(OpeningStage()) }
}

private struct OpeningStage: ViewModifier {
    func body(content: Content) -> some View {
        content.background { OpeningProbe() }.debugSettling(CueOpening.shared.phase != .open)
    }
}

private struct OpeningProbe {
    final class Probe: RelayAnchorBase {
        var reduceMotion = false
        var edge = CGColor(gray: 0, alpha: 1)

        #if os(iOS)
        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard let window else { return }
            let ink = UIColor(named: "LaunchBackground")!.resolvedColor(with: window.windowScene!.screen.traitCollection).cgColor
            CueOpening.shared.play(
                in: window, root: window.layer, world: window.rootViewController?.view.layer, ink: ink, edge: edge,
                pose: (UIImage(named: "cue-stage-idle")!.cgImage!, UIImage(named: "cue-stage-jump")!.cgImage!), reduceMotion: reduceMotion)
        }
        #else
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, let root = RelayAnchorView.rootLayer(of: window) else { return }
            var ink = CGColor(gray: 0, alpha: 1)
            window.effectiveAppearance.performAsCurrentDrawingAppearance { ink = NSColor(named: "LaunchBackground")!.cgColor }
            CueOpening.shared.play(
                in: window, root: root, world: window.contentView?.layer, ink: ink, edge: edge,
                pose: (Self.image("cue-stage-idle"), Self.image("cue-stage-jump")), reduceMotion: reduceMotion)
        }

        private static func image(_ name: String) -> CGImage {
            NSImage(named: name)!.cgImage(forProposedRect: nil, context: nil, hints: nil)!
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        #endif
    }
}

#if os(iOS)
extension OpeningProbe: UIViewRepresentable {
    func makeUIView(context: Context) -> Probe {
        let probe = Probe()
        probe.isUserInteractionEnabled = false
        probe.reduceMotion = context.environment.accessibilityReduceMotion
        probe.edge = context.environment.palette.signature.resolve(in: context.environment).cgColor
        return probe
    }

    func updateUIView(_ probe: Probe, context: Context) {}
}
#else
extension OpeningProbe: NSViewRepresentable {
    func makeNSView(context: Context) -> Probe {
        let probe = Probe()
        probe.reduceMotion = context.environment.accessibilityReduceMotion
        probe.edge = context.environment.palette.signature.resolve(in: context.environment).cgColor
        return probe
    }

    func updateNSView(_ probe: Probe, context: Context) {}
}
#endif
