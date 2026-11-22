import SwiftUI

/// 发出的那句从输入框飞进对话。按下时字留在输入框里原处（写进库、排出气泡要几帧，输入框这时已经空了，不留这一下空白）；
/// 气泡一排好就飞过去：竖着比横着快，走一道弧，一路长出气泡的底，落下时换成真的那颗（飞着时它透明）。
/// 一个对话区（`FloatingReply`）一份：输入框报字的位置（`origin`），气泡按"按下之后说的、字一样"认出自己（`carries`）、报落点（`aim`）。
/// 只飞纯文字：带附件、批注、技能调用的气泡长相不同；没有看得见的落点就原地淡掉。减弱动态效果时不给这一份，不飞。
/// 只平移与改留白，不缩放：缩放时每帧重画字形。
@MainActor @Observable final class SendFlight {
    struct Trip: Equatable {
        let text: String
        let from: CGRect
        let at: Date
    }

    struct Landing: Equatable {
        let frame: CGRect
        let look: BubbleLook
        let opacity: CGFloat
    }

    private(set) var trip: Trip?
    private(set) var landing: Landing?
    @ObservationIgnored var origin: CGRect?

    func depart(_ draft: ComposerDraft) {
        let text = Self.shown(draft.text)
        guard let origin, !text.isEmpty, draft.files.isEmpty, draft.attachments.isEmpty, draft.notes.isEmpty else { return }
        landing = nil
        trip = Trip(text: text, from: origin, at: .now)
    }

    func carries(_ text: String, said: Date?) -> Bool {
        guard let trip, let said else { return false }
        return said.timeIntervalSince(trip.at) > -Self.slack && Self.shown(text) == trip.text
    }

    /// 库里的时间只存到毫秒，读回来比起飞时早一点；一秒内不会再发出一样的一句。
    private static let slack: TimeInterval = 1

    /// 落点压在输入框后面（对话没滚到最新）就不认：往下钻进输入框后面读不出去了哪。
    func aim(_ landing: Landing) {
        guard let trip, landing.frame.maxY <= trip.from.minY, self.landing != landing else { return }
        self.landing = landing
    }

    func land(_ trip: Trip) {
        guard self.trip == trip else { return }
        self.trip = nil
        landing = nil
    }

    private static func shown(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
}

extension EnvironmentValues {
    @Entry var sendFlight: SendFlight?
}

extension View {
    /// 输入框的字区：报给这一页的飞行，发出时从这里起飞。
    func sendsFlight() -> some View { modifier(FlightOrigin()) }

    /// 正被飞着的那颗气泡：透明着，报落点。
    func flightLanding(_ flight: SendFlight?, look: BubbleLook, opacity: CGFloat) -> some View {
        modifier(FlightLanding(flight: flight, look: look, opacity: opacity))
    }
}

private struct FlightOrigin: ViewModifier {
    @Environment(\.sendFlight) private var flight

    func body(content: Content) -> some View {
        if let flight {
            content.onGeometryChange(for: CGRect.self) { $0.frame(in: .named(floatingReplyPage)) } action: { flight.origin = $0 }
        } else {
            content
        }
    }
}

private struct FlightLanding: ViewModifier {
    let flight: SendFlight?
    let look: BubbleLook
    let opacity: CGFloat

    func body(content: Content) -> some View {
        if let flight {
            content.opacity(0)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(floatingReplyPage)) } action: {
                    flight.aim(SendFlight.Landing(frame: $0, look: look, opacity: opacity))
                }
        } else {
            content
        }
    }
}

struct SendFlightLayer: View {
    let flight: SendFlight

    var body: some View {
        if let trip = flight.trip {
            GeometryReader { layer in
                FlyingWords(flight: flight, trip: trip, base: layer.frame(in: .named(floatingReplyPage)).origin).id(trip.at)
            }
            .allowsHitTesting(false)
            .readerHidden(true)
        }
    }
}

private struct FlyingWords: View {
    let flight: SendFlight
    let trip: SendFlight.Trip
    let base: CGPoint
    @State private var spot: CGPoint
    @State private var grown = false
    @State private var gone = false
    @State private var leg = 0
    @Environment(\.palette) private var palette

    init(flight: SendFlight, trip: SendFlight.Trip, base: CGPoint) {
        self.flight = flight
        self.trip = trip
        self.base = base
        _spot = State(initialValue: trip.from.origin)
    }

    var body: some View {
        let landing = flight.landing, look = landing?.look ?? .session, full = look.padding
        let width = landing.map { $0.frame.width - full.leading - full.trailing } ?? trip.from.width
        Paragraphs(verbatim: trip.text, lineSpacing: Typography.readingLineSpacing, lineLimit: UserBubble<EmptyView>.foldedLines)
            .font(Typography.reading).foregroundStyle(palette.ink)
            .frame(width: width, alignment: .leading)
            .padding(grown ? full : EdgeInsets())
            .background {
                look.shape.fill(palette.bubble)
                    .overlay { if let edge = palette.bubbleEdge { look.shape.strokeBorder(edge) } }
                    .opacity(grown ? 1 : 0)
            }
            .opacity(gone ? 0 : grown ? landing?.opacity ?? 1 : 1)
            .offset(x: spot.x - base.x, y: spot.y - base.y)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .onChange(of: landing, initial: true) { fly(to: landing) }
            .task {
                try? await Task.sleep(for: Motion.Send.wait)
                guard !Task.isCancelled, flight.landing == nil else { return }
                withAnimation(Motion.fade) { gone = true } completion: { flight.land(trip) }
            }
    }

    /// 按下当帧就先往上起飞一小段（气泡要几帧后才排出来，停在原处会压着输入框里冒出来的占位字）；
    /// 落点到了、或在飞的途中挪了（滚到最新、键盘收起）就改终点：弹簧从当前的位置与速度接着走，只认最后一段的落定。
    private func fly(to landing: SendFlight.Landing?) {
        guard let landing else {
            withAnimation(Motion.Send.lift) { spot.y -= Motion.Send.takeoff }
            return
        }
        withAnimation(Motion.Send.grow) { grown = true }
        let to = landing.frame.origin, across = abs(to.x - spot.x) >= Self.still
        guard across || abs(to.y - spot.y) >= Self.still else { return }
        leg += 1
        let current = leg
        func land() { if leg == current { flight.land(trip) } }
        withAnimation(Motion.Send.lift, completionCriteria: .logicallyComplete) { spot.y = to.y } completion: { if !across { land() } }
        withAnimation(Motion.Send.drift, completionCriteria: .logicallyComplete) { spot.x = to.x } completion: { if across { land() } }
    }

    /// 终点没挪（同一处又报了一次，只差小数点后几位）就不开新的一段：值没变的动画当场回调完成，会在半路落地。
    private static let still: CGFloat = 0.5
}
