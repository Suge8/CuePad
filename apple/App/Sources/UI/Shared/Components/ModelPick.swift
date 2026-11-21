import CueStore
import SwiftUI

/// 模型与思考强度合成一颗：胶囊写这一次用谁（标志、名字）和思考几格，点开是挨着它长出的气泡——上面按提供方分组列模型，下面一排思考强度。
/// 选了模型气泡不收，接着就能选强度（换了模型强度的档跟着换）；点外面或 Esc 收起。Mac 的 ⌘⇧M 与思考强度的快捷键都打开它。
/// 否决过：两颗胶囊各开一个系统菜单——模型菜单里只有一列名字，强度要回到工具排再点另一颗，换一次模型要开两个菜单。
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
                .bubble(isPresented: $picking.open, width: .fixed(Self.width)) { ModelPickBubble(live: live) }
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
        // 装饰：意思由按钮的标签与值说
        let badge = ModelBadge(mark: mark, binding: binding).modifier(Breathing(active: pending)).readerHidden(true)
        // 工具排给的宽放不下就先收名字、留标志与强度格，再只留标志（`ConfigRow` 的 `model`）；整颗是候选，只把名字放进去会量错（同 `AgentCapsule`）
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
        if let meter { ThinkingTicks(meter: meter, size: .small).padding(.leading, Spacing.hair).readerHidden(true) }
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

/// 气泡的内容在打开那一刻交给浮层宿主，之后不随胶囊重算（`presentPanel`）：要跟着变的（选中哪个模型、哪一档、额度）放进这只盒子，气泡读它。
/// 打开时整份重放一遍：输入框换会话时可能留着同一个视图，盒子里的两个选择动作不能还是上一个会话的。
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

/// 开着时要重放进盒子的那些值；动作是闭包、比不了，跟着这些一起换。
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

/// 气泡本身已是一张卡，里面不铺底、不分组头：两段（模型、思考强度）各一行小标题，模型按提供方排、组与组之间只隔一段留白，
/// 标志就说了是哪家；额度、默认、认不出标志时的提供方名写在那一行的第二行。选中的那行垫选中底、行尾一个勾。
/// 否决过：每家一行组头（照搬系统菜单的分组）——多数家只有一个模型，组头比模型还多，整块又长又碎。
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
        VStack(alignment: .leading, spacing: Spacing.block) {
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
            if let meter, !meter.levels.isEmpty {
                ThinkingTrack(meter: meter, choose: chooseThinking)
            }
        }
        .padding(Spacing.item)
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

/// 思考强度的能量轨道：这个模型支持的档从左到右排开，填满到钮的那一段是这一档的思考场（`ThinkingField`），
/// 档越高越长、越暖、星越密越快。最左端总是"关"：模型没有关这一档时那里空着、钮停不过去，最低档也就离开左端亮出一截，不像关着。
/// 按下或点在轨道上就跳到最近的档；拖着走时钮跟手，档位带回差地吸（过了两档正中再多走一成才换，
/// 停在边界上不来回跳），每换一档轻震一下；松手才提交、钮弹到档位上。小标题那一行的右端写着此刻（拖着时是要去）的档。
/// 否决过：一排分段——五六段挤在一行只剩字，看不出"越往右越用力"，选中的那块也只是换个颜色。
private struct ThinkingTrack: View {
    let meter: ThinkingMeter
    let choose: (ThinkingLevel) -> Void
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @LoopsPlay private var loops
    /// 拖着时钮的中心；松手后归 nil，钮回到档位上
    @State private var dragging: CGFloat?
    /// 拖着时、与松手后 Agent 报回新档之前要去的那一档；报不回（没换成）一秒后放下，回到当前档
    @State private var heading: Int?

    private var levels: [ThinkingLevel] { meter.levels }
    private var lead: Int { levels.contains(.off) ? 0 : 1 }
    private var index: Int? { heading ?? meter.current.flatMap { levels.firstIndex(of: $0) } }
    private var level: ThinkingLevel? { index.map { levels[$0] } }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            HStack(spacing: Spacing.tight) {
                Text("思考强度").foregroundStyle(palette.ink3)
                Spacer(minLength: Spacing.item)
                Text(verbatim: level?.label ?? meter.label).fontWeight(.semibold).foregroundStyle(palette.ink)
                    .contentTransition(.interpolate)
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
        .sensoryFeedback(.selection, trigger: index)
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
            // 钮两种外观都是暖白：深色下用纸色，压在亮的色带上是一块发沉的洞
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
                    // 刚按下时直接取最近的档；拖着时离开当前档过了 0.6 格才换（回差）
                    if dragging == nil || index.map({ abs(raw - Double($0)) > 0.6 }) ?? true {
                        heading = min(max(Int(raw.rounded()), 0), levels.count - 1)
                    }
                    dragging = x
                }
                .onEnded { _ in
                    dragging = nil
                    if let heading, levels[heading] != meter.current { choose(levels[heading]) }
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
    /// 捏住时钮略微鼓起，松手回原大
    private static let lift: CGFloat = 1.12
}

/// 思考强度的竖格：除"关"以外的六档各一格（`ThinkingMeter.scale`），当前档以下填满，每格是它那一档在色带上的颜色（`Palette.thinking`），
/// 越往上越暖；关着时格全空、斜划一道，最高档时有一道光扫过。常驻在工具排上，只用静止的颜色，不放每帧重算的东西。
struct ThinkingTicks: View {
    enum Size { case small, regular }

    let meter: ThinkingMeter
    var size = Size.regular
    var pending = false
    @Environment(\.palette) private var palette
    @LoopsPlay private var loops

    private var barWidth: CGFloat { size == .small ? 2.5 : 4 }
    private var gap: CGFloat { size == .small ? 1.5 : 3 }
    private var lowest: CGFloat { size == .small ? 4 : 6 }
    private var tallest: CGFloat { size == .small ? 12 : 16 }

    var body: some View {
        bars { index in
            index < meter.filled ? palette.thinking(Double(index) / Double(ThinkingMeter.scale.count - 1)) : meter.current == nil ? palette.ink3 : palette.track
        }
        .overlay {
            if meter.isMax, loops {
                LoopLayer(kind: .sheen, color: palette.onFill).mask { bars { _ in .black } }.allowsHitTesting(false)
            }
        }
        .overlay {
            if meter.isOff {
                Capsule().fill(palette.ink3).frame(width: 1.5)
                    .frame(height: tallest + 4).rotationEffect(.degrees(42))
                    .transition(.opacity)
            }
        }
        .modifier(Breathing(active: pending))
    }

    private func bars(color: @escaping (Int) -> Color) -> some View {
        HStack(alignment: .bottom, spacing: gap) {
            let count = ThinkingMeter.scale.count
            ForEach(0..<count, id: \.self) { index in
                Capsule().fill(color(index))
                    .frame(width: barWidth, height: count > 1 ? lowest + (tallest - lowest) * CGFloat(index) / CGFloat(count - 1) : tallest)
            }
        }
        .frame(height: tallest, alignment: .bottom)
    }
}
