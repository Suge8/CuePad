import CueStore
import SwiftUI

extension SessionShown {
    func tint(_ palette: Palette) -> Color {
        switch status {
        case .asking: palette.waiting
        case .cueAsking: palette.ink
        case .delivery(.preparing), .delivery(.inTransit(.unconfirmed)): palette.ink3
        case .failed, .delivery(.failed): palette.failure
        case .working, .delivery: palette.signature
        case .unread, .awaitsReply: palette.replied
        case .idle, .resting, .fresh, .interrupted, .unknown, .offline, .ended: palette.ink3
        }
    }

    var isColored: Bool {
        switch status {
        case .delivery(.preparing), .delivery(.inTransit(.unconfirmed)): false
        case .asking, .awaitsReply, .failed, .working, .delivery, .unread: true
        case .cueAsking, .idle, .resting, .fresh, .ended, .interrupted, .unknown, .offline: false
        }
    }

    func labelTint(_ palette: Palette) -> Color {
        isColored || status == .cueAsking ? tint(palette) : status == .ended ? palette.ink3 : palette.ink2
    }

    func wash(_ palette: Palette) -> Color? {
        switch status {
        case .failed, .delivery(.failed): palette.failureWash
        case .unread, .awaitsReply: palette.repliedWash
        default: nil
        }
    }

    var icon: Icon {
        switch status {
        case .asking, .cueAsking: .waiting
        case .failed: .failure
        case .delivery(.preparing): .more
        case .delivery(.failed): .undelivered
        case .delivery: .onTheWay
        case .working(.delegating): .relay
        case .working(.tool): .tool
        case .working(.compacting): .compacting
        case .working: .session
        case .unread, .awaitsReply: .replied
        case .idle, .resting: .session
        case .fresh: .fresh
        case .ended: .ended
        case .interrupted: .interrupted
        case .unknown, .offline: .unknown
        }
    }
}

struct StateDot: View {
    let shown: SessionShown
    var size: CGFloat = 8
    var announces = false
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @LoopsPlay private var loops
    @ScaledMetric private var scale: CGFloat = 1
    @State private var calls = 0
    @State private var rings = 0

    private var box: CGFloat { size * 1.8 * scale }
    private nonisolated static let midline = 0.36

    var body: some View {
        let tint = shown.tint(palette)
        let pose = shown.ink
        let mark = ZStack {
            StateInk(pose: pose ?? .hidden, color: tint, loops: loops, morphs: !reduceMotion)
            if pose == nil {
                Group {
                    if shown.flies { OnTheWay(size: box, color: tint) } else { symbol(tint) }
                }
                .transition(reduceMotion ? .opacity : .scale(scale: 0.3).combined(with: .opacity))
            }
        }
        .frame(width: box, height: box)
        .animation(reduceMotion ? Motion.fade : Motion.Ink.pop, value: pose == nil)
        .animation(Motion.fade, value: shown)
        // 铃铛、徽是刚弹出来的新视图：等它落定再晃，晃的值在它出现之前就变了的话它不晃
        .onChange(of: shown.status) { old, new in if new.callsOut, old != new, !reduceMotion { calls += 1 } }
        .task(id: calls) {
            guard calls > 0, (try? await Task.sleep(for: Self.settle)) != nil else { return }
            rings = calls
        }
        // 旁边是字时按第一行对齐（`.firstTextBaseline`）：每种标都把自己的中心放在那一行字的中线上。不能用各自的基线——
        // 符号有基线、自绘的线没有（落到底边），同一列里就高高低低；标的大小跟着旁边的字走，中线离基线约是字高的四成
        Group {
            // 只给读屏：每行一个悬停提示会让整页每行都挂一块跟踪区，滚动时跟着重算
            if announces { mark.iconLabel(shown.presence) } else { mark.readerHidden(true) }
        }
        .alignmentGuide(.firstTextBaseline) { [box] in $0[VerticalAlignment.center] + box * Self.midline }
    }

    private func symbol(_ tint: Color) -> some View {
        Image(shown.icon)
            .font(Glyph.at(box * 0.86))
            .foregroundStyle(tint)
            .contentTransition(.symbolEffect(.replace))
            .symbolEffect(.wiggle, options: .nonRepeating, value: rings)
    }

    private static let settle: Duration = .milliseconds(260)
}

extension SessionShown {
    var ink: InkPose? {
        switch status {
        case .working(.tool): InkPose(shape: .wrench, life: .twist)
        case .working(.compacting): InkPose(shape: .spring, life: .press)
        case .working(.delegating): InkPose(shape: .bot, life: .bot)
        case .working: InkPose(shape: .heartbeat, life: .pulse)
        case .asking: InkPose(shape: .ask, life: .nod)
        case .cueAsking: InkPose(shape: .ask, life: .still)
        case .awaitsReply, .unread: InkPose(shape: .mail, life: .flap)
        case .idle, .resting: .hidden
        case .interrupted: InkPose(shape: .plug, life: .jitter)
        case .ended: InkPose(shape: .moon, life: .rock)
        case .delivery, .failed, .fresh, .unknown, .offline: nil
        }
    }

    var flies: Bool {
        switch status {
        case .delivery(.preparing), .delivery(.failed), .delivery(.inTransit(.unconfirmed)): false
        case .delivery: true
        default: false
        }
    }
}

extension SessionShown.Status {
    var callsOut: Bool {
        switch self {
        case .failed, .delivery(.failed): true
        default: false
        }
    }
}

struct StateGlyph: View {
    let status: SessionShown.Status
    @Environment(\.palette) private var palette

    var body: some View {
        let shown = SessionShown(status: status)
        Image(shown.icon).foregroundStyle(shown.tint(palette))
    }

    static let undelivered = StateGlyph(status: .delivery(.failed(.reported(DeliveryRequest.unexplainedFailure))))
}
