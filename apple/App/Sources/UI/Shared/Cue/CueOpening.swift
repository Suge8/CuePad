import QuartzCore
import SwiftUI

/// 开门：每次冷启动，窗口先是启动屏那一幕（图标的墨色、正中站着 Cue，iOS 的启动屏就是它：`LaunchBackground`、`LaunchCue`），
/// 两者与这里盖的第一帧要一模一样，接缝才看不出。模拟器的 splashboardd 把资源目录缓存在内存里、重装也不重读（装的路径不变）：
/// 改了这两样，杀掉它（launchd 自己再起）才看得到新的启动屏，不然一直是旧色。
/// Cue 页的天空第一次画好后，从 Cue 腰上那只环的位置张开一扇门：环由扁转圆一路撑到屏外，门里的天空由粗格子收拢到平时的细格子，
/// 整个窗口从近处退回原位，Cue 顺势落回它住的地方（空着的 Cue 页落在云上，否则落进头像，`relaySpot(cue:)`）。
/// 一个进程只放一次：回前台、开第二个窗口都不放。降低动态效果时墨色直接淡掉。
/// 画法同接力（`CueRelayStage`）：整块交给 Core Animation，盖在窗口最底层之上；冷启动时主线程正忙，逐帧不经 App 进程才不掉帧。
/// 环、门、镜头、小人都取自同一条时间线（`OpeningDoor`），采成关键帧一次交出去。
@Observable
final class CueOpening {
    static let shared = CueOpening()

    enum Phase: Equatable {
        case shut
        case opening(landing: CueSpot?, grain: Int)
        case open

        /// 天空的格子是平时的几倍：门缝里先是粗格子，门开到几成就细一档。
        var grain: Int {
            switch self {
            case .shut: OpeningDoor.grains[0]
            case .opening(_, let grain): grain
            case .open: 1
            }
        }

        /// 小人还没落下时它要落的那处藏着；门开之前哪处都藏着（落点等门开那一刻才量）。
        func hides(_ spot: CueSpot) -> Bool {
            switch self {
            case .shut: true
            case .opening(let landing, _): landing == spot
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

    fileprivate func play(in window: AnyObject, root: CALayer, world: CALayer?, ink: CGColor, ring: [CGColor], cue: CGImage, reduceMotion: Bool) {
        guard !began else { return }
        began = true
        if reduceMotion { phase = .open }
        let up = RelayFlight.up(in: root)
        let curtain = OpeningCurtain(root: root, world: world, ink: ink, ring: ring, cue: cue, at: OpeningDoor.start(in: root.bounds), up: up, breathes: !reduceMotion)
        Task {
            let clock = ContinuousClock(), start = clock.now
            await sky(by: start + OpeningDoor.patience)
            try? await clock.sleep(until: start + OpeningDoor.dwell)
            await NextFrame.drawn()
            guard !reduceMotion else { return await curtain.fade() }
            let landing = Self.landing(in: window, root: root)
            let door = OpeningDoor(bounds: root.bounds, up: up, landing: landing)
            phase = .opening(landing: landing?.spot, grain: OpeningDoor.grains[0])
            let steps = Task {
                let opened = clock.now
                for (index, at) in door.steps.enumerated() {
                    guard (try? await clock.sleep(until: opened + .seconds(at))) != nil else { return }
                    phase = .opening(landing: landing?.spot, grain: OpeningDoor.grains[index + 1])
                }
            }
            await curtain.open(door)
            steps.cancel()
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
        if spot == .perch { return OpeningDoor.Landing(spot: spot, frame: frame, lift: 34) }
        let height = frame.width * OpeningDoor.cue.height / OpeningDoor.cue.width
        return OpeningDoor.Landing(spot: spot, frame: CGRect(x: frame.minX, y: frame.midY - height / 2, width: frame.width, height: height), lift: 18)
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
        var ring: [CGColor] = []

        #if os(iOS)
        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard let window else { return }
            let ink = UIColor(named: "LaunchBackground")!.resolvedColor(with: window.windowScene!.screen.traitCollection).cgColor
            CueOpening.shared.play(
                in: window, root: window.layer, world: window.rootViewController?.view.layer, ink: ink, ring: ring,
                cue: UIImage(named: "cue-stage-idle")!.cgImage!, reduceMotion: reduceMotion)
        }
        #else
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, let root = RelayAnchorView.rootLayer(of: window) else { return }
            var ink = CGColor(gray: 0, alpha: 1)
            window.effectiveAppearance.performAsCurrentDrawingAppearance { ink = NSColor(named: "LaunchBackground")!.cgColor }
            CueOpening.shared.play(
                in: window, root: root, world: window.contentView?.layer, ink: ink, ring: ring,
                cue: NSImage(named: "cue-stage-idle")!.cgImage(forProposedRect: nil, context: nil, hints: nil)!, reduceMotion: reduceMotion)
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
        probe.ring = context.environment.palette.ringTube.map { $0.resolve(in: context.environment).cgColor }
        return probe
    }

    func updateUIView(_ probe: Probe, context: Context) {}
}
#else
extension OpeningProbe: NSViewRepresentable {
    func makeNSView(context: Context) -> Probe {
        let probe = Probe()
        probe.reduceMotion = context.environment.accessibilityReduceMotion
        probe.ring = context.environment.palette.ringTube.map { $0.resolve(in: context.environment).cgColor }
        return probe
    }

    func updateNSView(_ probe: Probe, context: Context) {}
}
#endif
