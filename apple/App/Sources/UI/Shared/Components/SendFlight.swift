import SwiftUI

/// 发出的那句从输入框飞进对话。按下时字留在输入框里原处（写进库、排出气泡要几帧，输入框这时已经空了，不留这一下空白）；
/// 气泡一排好就飞过去：竖着比横着快，走一道弧，一路显影出气泡的底（`Developing`），落下时换成真的那颗（飞着时它透明）。
/// 一个对话区（`FloatingReply`）一份：输入框报字的位置（`origin`），气泡按这句在库里的编号（按下时定好）认出自己（`carries`）、报落点（`aim`）。
/// 只飞纯文字：带附件、批注、技能调用的气泡长相不同；没有看得见的落点就原地淡掉。减弱动态效果时不给这一份，不飞。
/// 只平移与改留白，不缩放：缩放时每帧重画字形。
@MainActor @Observable final class SendFlight {
    struct Trip: Equatable {
        let id: UUID
        let text: String
        let from: CGRect
    }

    struct Landing: Equatable {
        let frame: CGRect
        let look: BubbleLook
        let opacity: CGFloat
    }

    private(set) var trip: Trip?
    private(set) var landing: Landing?
    @ObservationIgnored var origin: CGRect?

    func depart(_ draft: ComposerDraft, as id: UUID) {
        let text = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let origin, !text.isEmpty, draft.files.isEmpty, draft.importing.isEmpty, draft.attachments.isEmpty, draft.notes.isEmpty else { return }
        landing = nil
        trip = Trip(id: id, text: text, from: origin)
    }

    func carries(_ said: UUID?) -> Bool { trip?.id == said && said != nil }

    /// 落点压在输入框后面（对话没滚到最新）就不认：往下钻进输入框后面读不出去了哪。比的是输入框此刻的位置：键盘收起时它与对话一起往下挪。
    /// 认过之后又被压住（飞着时往回滚了）就不飞了，当场换成真的那颗。
    func aim(_ landing: Landing) {
        guard let trip, self.landing != landing else { return }
        guard landing.frame.maxY <= (origin ?? trip.from).minY else {
            if self.landing != nil { land(trip) }
            return
        }
        self.landing = landing
    }

    func land(_ trip: Trip) {
        guard self.trip == trip else { return }
        self.trip = nil
        landing = nil
    }

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
                FlyingWords(flight: flight, trip: trip, base: layer.frame(in: .named(floatingReplyPage)).origin).id(trip.id)
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
    @State private var developed = false
    @State private var gone = false
    @State private var legs = Legs()
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
        Developing(progress: developed ? 1 : 0, look: look, padding: full) {
            Paragraphs(verbatim: trip.text, lineSpacing: Typography.readingLineSpacing, lineLimit: UserBubble<EmptyView>.foldedLines)
                .font(Typography.reading).foregroundStyle(palette.ink)
                .frame(width: width, alignment: .leading)
        }
            .opacity(gone ? 0 : developed ? landing?.opacity ?? 1 : 1)
            .offset(x: spot.x - base.x, y: spot.y - base.y)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .onChange(of: landing, initial: true) { fly(to: landing) }
            .task {
                try? await Task.sleep(for: Motion.Send.wait)
                guard !Task.isCancelled, flight.landing == nil else { return }
                withAnimation(Motion.fade) { gone = true } completion: { flight.land(trip) }
            }
    }

    /// 两个方向与显影各记各的最后一段：落点只在一个方向上挪了时，另一个方向还在走，都停了才落下；显影没完就落下的话，真的那颗一下盖掉还带色的格子。
    private struct Legs {
        var y = 0, x = 0, develop = 0
        var moving: Set<WritableKeyPath<Self, Int>> = []
    }

    /// 按下当帧就先往上起飞一小段（气泡要几帧后才排出来，停在原处会压着输入框里冒出来的占位字）；
    /// 落点到了、或在飞的途中挪了（滚到最新、键盘收起）就改终点：弹簧从当前的位置与速度接着走。
    private func fly(to landing: SendFlight.Landing?) {
        guard !gone else { return }
        guard let landing else {
            withAnimation(Motion.Send.lift) { spot.y -= Motion.Send.takeoff }
            return
        }
        if !developed { start(\.develop, Motion.Send.develop) { developed = true } }
        let to = landing.frame.origin
        move(\.y, Motion.Send.lift, from: spot.y, to: to.y) { spot.y = to.y }
        move(\.x, Motion.Send.drift, from: spot.x, to: to.x) { spot.x = to.x }
    }

    /// 终点没挪（同一处又报了一次，只差小数点后几位）就不开新的一段：值没变的动画当场回调完成，会在半路落地。
    private func move(_ axis: WritableKeyPath<Legs, Int>, _ animation: Animation, from: CGFloat, to: CGFloat, _ change: () -> Void) {
        guard abs(to - from) >= Self.still else { return }
        start(axis, animation, change)
    }

    private func start(_ axis: WritableKeyPath<Legs, Int>, _ animation: Animation, _ change: () -> Void) {
        legs[keyPath: axis] += 1
        legs.moving.insert(axis)
        let current = legs[keyPath: axis]
        withAnimation(animation, completionCriteria: .logicallyComplete, change) {
            guard legs[keyPath: axis] == current else { return }
            legs.moving.remove(axis)
            if legs.moving.isEmpty { flight.land(trip) }
        }
    }

    private static let still: CGFloat = 0.5
}

/// 飞着的气泡在路上显影：底用气泡自己的颜色，从字头往字尾一格格长出来，边上按阈值表抖开（`Halftone`），格子大到一眼看得出是像素；
/// 留白同时从字边长到气泡的边。显影完是一整块气泡色，与真的那颗一样，落下时换过去看不出来。
/// 字一直是实的：它从输入框里飞出来，本来就看得见，跟着闪的话读不成句。
private struct Developing<Words: View>: View, Animatable {
    var progress: Double
    let look: BubbleLook
    let padding: EdgeInsets
    @ViewBuilder let words: Words
    @Environment(\.palette) private var palette
    @Environment(\.displayScale) private var scale

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        let grow = 1 - pow(1 - progress, 2)
        words
            .padding(EdgeInsets(top: padding.top * grow, leading: padding.leading * grow, bottom: padding.bottom * grow, trailing: padding.trailing * grow))
            .background {
                Canvas { [progress, look, cell = (Self.grain * scale).rounded() / scale, tints = tints] context, size in
                    let outline = look.shape.path(in: CGRect(origin: .zero, size: size))
                    guard progress < 1 else { return context.fill(outline, with: .color(tints[0])) }
                    context.clip(to: outline)
                    var grown = Array(repeating: Path(), count: tints.count)
                    let columns = Int((size.width / cell).rounded(.up))
                    for y in 0..<Int((size.height / cell).rounded(.up)) {
                        for x in 0..<columns {
                            let age = progress - (Double(x) / Double(columns) * (1 - Self.soft) + Halftone.bayer(x, y) * Self.soft)
                            guard age > 0 else { continue }
                            let band = Int((max(0, 1 - age / Self.fresh) * Double(tints.count - 1)).rounded())
                            grown[band].addRect(CGRect(x: CGFloat(x) * cell, y: CGFloat(y) * cell, width: cell, height: cell))
                        }
                    }
                    for (band, path) in grown.enumerated() where !path.isEmpty { context.fill(path, with: .color(tints[band])) }
                }
                .overlay { if let edge = palette.bubbleEdge { look.shape.strokeBorder(edge).opacity(progress) } }
            }
    }

    /// 刚长出的格子带一点回答显影的色（`thinkingMid`、`thinkingHigh`），最多掺到 `tint`，`fresh` 内冷回气泡色：只有扫过去的那道边上有一丝。
    private var tints: [Color] {
        (0..<Self.bands).map { band in
            let heat = Double(band) / Double(Self.bands - 1)
            return palette.bubble.mix(with: palette.thinkingMid.mix(with: palette.thinkingHigh, by: heat), by: heat * Self.tint)
        }
    }

    private static var tint: Double { 0.4 }
    private static var fresh: Double { 0.18 }
    private static var bands: Int { 4 }
    /// 一格的边长（点，取整到设备像素）：回答显影的网点（约 2 点）放在一整颗气泡上太细，看着是一层灰雾。
    private static var grain: CGFloat { 4 }
    /// 扫过去的那道边有多宽（占整颗的几成）：边里按阈值表抖开，太窄是一道硬线，太宽又成了整颗一起闪。
    private static var soft: Double { 0.35 }
}
