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
    @Binding var picking: Bool

    var body: some View {
        Moments(next: quotas.nextReset(after:)) { now in
            Button { picking.toggle() } label: { label(at: now) }
                .buttonStyle(PressStyle())
                .bubble(isPresented: $picking, width: .fixed(Self.width)) {
                    ModelPickBubble(models: models, current: current, quotas: quotas, meter: meter, chooseThinking: chooseThinking)
                }
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

/// 气泡本身已是一张卡，里面不铺底、不分组头：两段（模型、思考强度）各一行小标题，模型按提供方排、组与组之间只隔一段留白，
/// 标志就说了是哪家；额度、默认、认不出标志时的提供方名写在那一行的第二行。选中的那行垫选中底、行尾一个勾。
/// 否决过：每家一行组头（照搬系统菜单的分组）——多数家只有一个模型，组头比模型还多，整块又长又碎。
private struct ModelPickBubble: View {
    let models: ModelMenu
    let current: ModelOption?
    let quotas: [AccountQuota]
    let meter: ThinkingMeter?
    let chooseThinking: (ThinkingLevel) -> Void
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
                VStack(alignment: .leading, spacing: Spacing.tight) {
                    caption("思考强度") { EmptyView() }
                    ThinkingSegments(meter: meter, choose: chooseThinking)
                }
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

/// 思考强度的分段：这个模型支持的档一格一段，选中的那段浮起一块纸，换档时它滑过去。
private struct ThinkingSegments: View {
    let meter: ThinkingMeter
    let choose: (ThinkingLevel) -> Void
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var thumb

    var body: some View {
        HStack(spacing: 0) {
            ForEach(meter.levels, id: \.self) { level in
                let on = level == meter.current
                Button { if !on { choose(level) } } label: {
                    Text(verbatim: level.label)
                        .font(Typography.meta.weight(on ? .semibold : .medium))
                        .foregroundStyle(on ? palette.ink : palette.ink2)
                        .lineLimit(1).minimumScaleFactor(0.7)
                        .frame(maxWidth: .infinity, minHeight: Self.height)
                        .background {
                            if on {
                                Capsule().fill(palette.paperLit).overlay { Capsule().strokeBorder(palette.hair, lineWidth: ControlMetrics.stroke) }
                                    .padding(Self.inset)
                                    .matchedGeometryEffect(id: 0, in: thumb)
                            }
                        }
                        .contentShape(.capsule)
                }
                .buttonStyle(PressStyle(.mark))
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .background(palette.fill, in: .capsule)
        .animation(Motion.spatial(Motion.nudge, reduceMotion: reduceMotion), value: meter.current)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("思考强度")
    }

    #if os(iOS)
    private static let height: CGFloat = 36
    #else
    private static let height: CGFloat = 28
    #endif
    /// 选中那段浮起的纸与分段外沿留的一线：贴边时像把分段的底换了色，不像浮起一块
    private static let inset: CGFloat = 3
}

/// 思考强度的竖格：除"关"以外的六档各一格（`ThinkingMeter.scale`），当前档以下填满；关着时格全空、斜划一道，最高档时有一道光扫过。
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
            index < meter.filled ? palette.ink : meter.current == nil ? palette.ink3 : palette.track
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
