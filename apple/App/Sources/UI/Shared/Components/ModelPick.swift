import CueStore
import SwiftUI

struct ModelPick: View {
    let models: ModelMenu
    let current: ModelOption?
    let unnamed: LocalizedStringResource
    let pending: Bool
    let quotas: [AccountQuota]
    let meter: ThinkingMeter?
    let chooseThinking: (ThinkingLevel) -> Void
    @Binding var picking: BubbleSwitch
    @State private var live = Live()

    var body: some View {
        Moments(next: quotas.nextReset(after:)) { now in
            Button { picking.toggle() } label: { label(at: now) }
                .buttonStyle(PressStyle())
                .bubble($picking, width: .fixed(Self.width)) { ModelPickBubble(live: live) }
                .onChange(of: picking.open, initial: true) { if picking.open { live.take(self) } }
                .onChange(of: Seen(self)) { live.take(self) }
                .accessibilityLabel("模型")
                .accessibilityValue(Dotted(spoken(at: now), meter.map { String(localized: "思考 \($0.label)") }).spoken)
                .accessibilityAdjustableAction { direction in
                    guard let meter, let next = meter.step(direction == .increment ? 1 : -1), next != meter.current else { return }
                    chooseThinking(next)
                }
        }
    }

    private func label(at now: Date) -> some View {
        let mark = current.flatMap(BrandMark.model), binding = binding(at: now)
        let name = (current.map { Text(Dotted(ModelName.short($0), $0.account?.label(provider: $0.key.provider)).visible) } ?? Text(unnamed))
            .contentTransition(.opacity)
        let badge = ModelBadge(mark: mark, binding: binding).modifier(Breathing(active: pending)).readerHidden(true)
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: Self.gap) { badge; name; ticks }.fixedSize()
            HStack(spacing: Self.gap) { badge; ticks }.fixedSize()
            badge
        }
        .chip()
        .help(Dotted(spoken(at: now), meter.map { String(localized: "思考 \($0.label)") }).visible)
        .animation(Motion.fade, value: current?.key)
    }

    @ViewBuilder private var ticks: some View {
        if let meter { ThinkingWord(meter: meter).padding(.leading, Spacing.hair).readerHidden(true) }
    }

    static let gap = Spacing.tight
    private static let width: CGFloat = 300

    private func spoken(at now: Date) -> String {
        Dotted(current?.displayName ?? String(localized: unnamed), current.flatMap { $0.account?.label(provider: $0.key.provider) }, binding(at: now).map { String(localized: "\($0.name)额度剩 \($0.percent)") }).spoken
    }

    private func binding(at now: Date) -> QuotaMeter.Window? {
        guard let current, let quota = current.quota(in: quotas) else { return nil }
        return quota.binding(at: now, model: current.key.id).map { QuotaMeter.Window($0, at: now) }
    }
}

@Observable private final class Live {
    var models = ModelMenu(models: [], current: nil) { _ in }
    var current: ModelOption?
    var quotas: [AccountQuota] = []
    var meter: ThinkingMeter?
    var chooseThinking: (ThinkingLevel) -> Void = { _ in }

    func take(_ pick: ModelPick) {
        models = pick.models
        current = pick.current
        quotas = pick.quotas
        meter = pick.meter
        chooseThinking = pick.chooseThinking
    }
}

private struct Seen: Equatable {
    let models: [ModelOption]
    let defaultModel: ModelKey?
    let current: ModelOption?
    let quotas: [AccountQuota]
    let meter: ThinkingMeter?

    init(_ pick: ModelPick) {
        models = pick.models.models
        defaultModel = pick.models.defaultModel
        current = pick.current
        quotas = pick.quotas
        meter = pick.meter
    }
}

private struct ModelPickBubble: View {
    let live: Live
    private var models: ModelMenu { live.models }
    private var current: ModelOption? { live.current }
    private var quotas: [AccountQuota] { live.quotas }
    private var meter: ThinkingMeter? { live.meter }
    private var chooseThinking: (ThinkingLevel) -> Void { live.chooseThinking }
    @Environment(\.palette) private var palette

    var body: some View {
        let now = Date.now
        VStack(alignment: .leading, spacing: Spacing.tight) {
            caption("模型") {
                if let current, let url = current.account?.usageURL(provider: current.key.provider) {
                    Link("管理用量", destination: url).buttonStyle(PressStyle(.inline))
                }
            }
            VStack(alignment: .leading, spacing: Spacing.item) {
                ForEach(ModelLabel.groups(models.models), id: \.provider.id) { group in
                    VStack(alignment: .leading, spacing: Spacing.hair) {
                        ForEach(group.models) { row($0, at: now) }
                    }
                }
            }
        }
        .padding(Spacing.item)
        if let meter, !meter.levels.isEmpty {
            ThinkingTrack(meter: meter, choose: chooseThinking)
                .padding(Spacing.item)
                .bubbleFoot()
        }
    }

    private func caption(_ title: LocalizedStringResource, @ViewBuilder trailing: () -> some View) -> some View {
        HStack(spacing: Spacing.tight) {
            Text(title)
            Spacer(minLength: Spacing.item)
            trailing()
        }
        .font(Typography.caption).foregroundStyle(palette.ink3)
        .padding(.horizontal, Spacing.item)
    }

    private func row(_ model: ModelOption, at now: Date) -> some View {
        let chosen = model.key == current?.key
        let mark = BrandMark.model(model)
        let quota = model.quota(in: quotas)
        let binding = quota.flatMap { $0.binding(at: now, model: model.key.id) }.map { QuotaMeter.Window($0, at: now) }
        let note = Dotted(
            model.account?.source != nil || quota != nil ? ModelLabel.title(model, quotas: quotas, at: now) : mark == nil ? Provider(id: model.key.provider).name : nil,
            model.key == models.defaultModel ? String(localized: "默认") : nil)
        return Button { if !chosen { models.choose(model) } } label: {
            HStack(spacing: Spacing.item) {
                ModelBadge(mark: mark, binding: binding).readerHidden(true)
                VStack(alignment: .leading, spacing: 0) {
                    Text(verbatim: model.displayName).font(Typography.secondary.weight(chosen ? .semibold : .regular)).foregroundStyle(palette.ink)
                    if !note.isEmpty { Text(note).font(Typography.caption).foregroundStyle(palette.ink3) }
                }
                .lineLimit(1)
                Spacer(minLength: Spacing.item)
                if chosen { Image(.checked).font(Glyph.small.weight(.semibold)).foregroundStyle(palette.ink).readerHidden(true) }
            }
            .padding(.horizontal, Spacing.item)
            .frame(maxWidth: .infinity, minHeight: Self.rowHeight, alignment: .leading)
            .background(chosen ? palette.selection : .clear, in: .rect(cornerRadius: Radius.row))
            .contentShape(.rect(cornerRadius: Radius.row))
        }
        .buttonStyle(PressStyle())
        .accessibilityValue(note.spoken)
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }

    #if os(iOS)
    private static let rowHeight: CGFloat = 44
    #else
    private static let rowHeight: CGFloat = 34
    #endif
}

private struct ThinkingTrack: View {
    let meter: ThinkingMeter
    let choose: (ThinkingLevel) -> Void
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @LoopsPlay private var loops
    @State private var dragging: CGFloat?
    @State private var heading: ThinkingLevel?

    private var levels: [ThinkingLevel] { meter.levels }
    private var lead: Int { levels.contains(.off) ? 0 : 1 }
    private var level: ThinkingLevel? { heading.flatMap { levels.contains($0) ? $0 : nil } ?? meter.current }
    private var index: Int? { level.flatMap { levels.firstIndex(of: $0) } }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            HStack(spacing: Spacing.tight) {
                Text("思考强度").foregroundStyle(palette.ink3)
                Spacer(minLength: Spacing.item)
                Text(verbatim: level?.label ?? meter.label).fontWeight(.semibold).foregroundStyle(palette.ink)
                    .contentTransition(.numericText(value: Double(index ?? 0)))
                    .modifier(LevelPop(level: level))
                    .animation(Motion.spatial(Motion.nudge, reduceMotion: reduceMotion), value: level)
            }
            .font(Typography.caption)
            .padding(.horizontal, Spacing.item)
            .readerHidden(true)
            GeometryReader { proxy in track(width: proxy.size.width) }
                .frame(height: Self.height)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("思考强度")
        .accessibilityValue(meter.label)
        .accessibilityAdjustableAction { direction in
            guard let next = meter.step(direction == .increment ? 1 : -1), next != meter.current else { return }
            choose(next)
        }
        .sensoryFeedback(trigger: level) { _, level in
            .impact(flexibility: .soft, intensity: 0.6 + 0.4 * (level.flatMap(ThinkingMeter.energy) ?? 0))
        }
        .task(id: heading) {
            guard heading != nil, dragging == nil, (try? await Task.sleep(for: .seconds(1))) != nil else { return }
            heading = nil
        }
        .onChange(of: meter.current) { if dragging == nil { heading = nil } }
    }

    private func track(width: CGFloat) -> some View {
        let radius = Self.height / 2, span = max(width - Self.height, 1), slots = max(levels.count - 1 + lead, 1)
        let spot = { (i: Int) in radius + span * CGFloat(i + lead) / CGFloat(slots) }
        let knob = dragging ?? index.map(spot) ?? radius
        let fill = (index.map(spot) ?? radius) + radius
        return ZStack(alignment: .leading) {
            Capsule().fill(palette.fill)
            ThinkingField(energy: level.flatMap(ThinkingMeter.energy), fill: Double(fill / width), running: loops)
                .mask(alignment: .leading) { Capsule().frame(width: knob + radius) }
            ForEach(levels.indices, id: \.self) { i in
                Circle().fill(spot(i) < knob ? palette.thinkingRim : palette.track)
                    .frame(width: Self.dot, height: Self.dot)
                    .position(x: spot(i), y: radius)
            }
            Circle().fill(palette.onFill)
                .frame(width: Self.height - Self.inset * 2, height: Self.height - Self.inset * 2)
                .elevation(.hover)
                .scaleEffect(dragging == nil ? 1 : Self.lift)
                .position(x: knob, y: radius)
        }
        .contentShape(.capsule)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { drag in
                    let x = min(max(drag.location.x, spot(0)), spot(levels.count - 1))
                    let raw = Double((x - radius) / span) * Double(slots) - Double(lead)
                    if dragging == nil || index.map({ abs(raw - Double($0)) > 0.6 }) ?? true {
                        heading = levels[min(max(Int(raw.rounded()), 0), levels.count - 1)]
                    }
                    dragging = x
                }
                .onEnded { _ in
                    dragging = nil
                    if let heading, heading != meter.current { choose(heading) }
                }
        )
        .animation(Motion.spatial(Motion.nudge, reduceMotion: reduceMotion), value: dragging == nil)
        .animation(Motion.spatial(Motion.nudge, reduceMotion: reduceMotion), value: index)
    }

    #if os(iOS)
    private static let height: CGFloat = 36
    #else
    private static let height: CGFloat = 28
    #endif
    /// 钮与轨道外沿留的一线：贴边时钮像嵌进轨道里，不像压在上面
    private static let inset: CGFloat = 3
    private static let dot: CGFloat = 4
    private static let lift: CGFloat = 1.12
}

struct ThinkingWord: View {
    let meter: ThinkingMeter
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @LoopsPlay private var loops

    var body: some View {
        if let level = meter.current {
            let energy = ThinkingMeter.energy(level)
            ZStack(alignment: .leading) {
                ForEach(meter.levels, id: \.self) { Text($0.label).hidden() }
                Text(level.label)
                    .foregroundStyle(energy.map { AnyShapeStyle(LinearGradient(colors: [palette.thinkingInk(0), palette.thinkingInk($0)], startPoint: .leading, endPoint: .trailing)) } ?? AnyShapeStyle(palette.ink3))
                    .overlay { if meter.isMax, loops { LoopLayer(kind: .sheen, color: palette.onFill).mask { Text(level.label) }.allowsHitTesting(false) } }
                    .contentTransition(.numericText(value: Double(meter.levels.firstIndex(of: level) ?? 0)))
                    .modifier(LevelPop(level: level))
            }
            .font(Typography.meta.weight(.semibold)).fontDesign(.rounded)
            .animation(Motion.spatial(Motion.nudge, reduceMotion: reduceMotion), value: level)
        }
    }
}

private struct LevelPop: ViewModifier {
    let level: ThinkingLevel?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if reduceMotion {
            content
        } else {
            content.keyframeAnimator(initialValue: 1.0, trigger: level) { content, scale in
                content.scaleEffect(scale)
            } keyframes: { _ in
                SpringKeyframe(1.14, duration: 0.1)
                SpringKeyframe(1, duration: 0.35, spring: .bouncy)
            }
        }
    }
}
