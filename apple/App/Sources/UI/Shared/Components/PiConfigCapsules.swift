import CueStore
import SwiftUI

/// 模型胶囊：模型的标志（`BrandMark.model`）+ 模型短名。iOS 点开是 SwiftUI 的菜单；Mac 点开与 ⌘⇧M 是同一个 AppKit 菜单（`ChoiceMenu`，
/// SwiftUI 在 Mac 上把菜单项里的图片丢掉）：按提供方分组，分组标题带提供方的产品标志（Mac），每个模型带它自己的标志。
/// 有订阅额度的提供方：标志外一圈细环是卡着的那个窗口用了多少（`ModelBadge`），菜单的分组标题写各窗口的用量
/// （`PiModelLabel.title`，Mac 的 AppKit 菜单同一份，见 `PiConfigControls.open`）；到了重置时刻随即按已重置画（`QuotaMoments`）。
struct PiModelCapsule: View {
    let models: [PiModelOption]
    let current: PiModelOption?
    let pending: Bool
    let maxWidth: CGFloat
    let quotas: [AccountQuota]
    let choose: (PiModelKey) -> Void
    #if os(macOS)
    /// 弹出 AppKit 的模型菜单。
    let pick: () -> Void
    #endif
    @Environment(\.palette) private var palette

    var body: some View {
        QuotaMoments(quotas) { now in capsule(at: now) }
    }

    @ViewBuilder private func capsule(at now: Date) -> some View {
        #if os(macOS)
        Button(action: pick) { label(at: now) }
            .buttonStyle(.plain)
            .accessibilityLabel("模型")
            .accessibilityValue(spoken(at: now))
        #else
        Menu {
            ForEach(PiModelLabel.groups(models), id: \.provider.id) { group in
                Section(PiModelLabel.title(group.provider, quotas: quotas, at: now)) {
                    ForEach(group.models) { model in
                        Toggle(isOn: Binding(get: { current?.key == model.key }, set: { if $0 { choose(model.key) } })) {
                            Text(model.name.isEmpty ? model.key.id : model.name)
                            Text(PiModelLabel.levels(model))
                            BrandMark.model(model).image
                        }
                    }
                }
            }
        } label: {
            label(at: now)
        }
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .accessibilityLabel("模型")
        .accessibilityValue(spoken(at: now))
        #endif
    }

    private func label(at now: Date) -> some View {
        HStack(spacing: 5) {
            // 装饰：Mac 上菜单的标签与值会落到标签里的图标上，不藏起来读屏多出一个同名的"模型"
            ModelBadge(mark: current.map(BrandMark.model) ?? .unknown, binding: binding(at: now))
                .modifier(Breathing(active: pending))
                .accessibilityHidden(true)
            Text(current.map(PiModelName.short) ?? "模型").lineLimit(1).truncationMode(.tail)
                .contentTransition(.opacity)
        }
        .font(Typography.meta.weight(.medium)).foregroundStyle(palette.ink2)
        .padding(.leading, 6).padding(.trailing, 11)
        // 按内容宽，最宽 `maxWidth`，再长截断
        .frame(maxWidth: maxWidth, alignment: .leading)
        .fixedSize(horizontal: true, vertical: false)
        .frame(height: 30)
        .background(palette.fill, in: .capsule)
        .frame(minHeight: 44)
        .contentShape(.capsule)
        .animation(Motion.quick, value: current?.key)
    }

    private func spoken(at now: Date) -> String {
        Dotted(current?.name ?? "未知", binding(at: now).map { "\($0.name)额度已用 \($0.percent)" }).spoken
    }

    /// 当前模型的提供方卡着的那个窗口（按模型的周额度只算这个模型的）。
    private func binding(at now: Date) -> QuotaMeter.Window? {
        guard let current, let quota = quotas.first(where: { $0.provider == current.key.provider }) else { return nil }
        return quota.binding(at: now, model: current.key.id).map { QuotaMeter.Window($0, at: now) }
    }
}


/// 胶囊上的模型标志（次要墨色）；它的提供方有订阅额度时外面一圈细环：卡着的那个窗口用了多少（`QuotaArc`，不画匀速刻度），
/// 没有额度的只有标志、占同样大，换模型时不跳。还不知道是哪个模型时是通用图标。
struct ModelBadge: View {
    let mark: BrandMark
    let binding: QuotaMeter.Window?
    @ScaledMetric(relativeTo: .footnote) private var side: CGFloat = 20

    var body: some View {
        ZStack {
            if let binding { QuotaArc(window: binding, inset: 0, line: 1.5, showsPace: false) }
            mark.image
                .font(.system(size: side * 0.52))
                .contentTransition(.opacity)
        }
        .frame(width: side, height: side)
    }
}


struct PiThinkingDial: View {
    let meter: PiThinkingMeter
    let pending: Bool
    /// 写"思考 中"；窄处只写档名。
    let wordy: Bool
    let choose: (PiThinkingLevel) -> Void
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 手指（或鼠标）按着时指到的档：先在条上预览，松手才发出去。
    @State private var touched: PiThinkingLevel?
    /// 气泡里写的档：按下就有，松手后停 `linger` 再淡出。
    @State private var bubble: PiThinkingLevel?
    /// 每松手一次加一：重新计停留的时间。
    @State private var released = 0
    /// 竖格在这一枚胶囊里的位置：横向位置按它换算成档。
    @State private var track: CGRect = .zero

    private static let barWidth: CGFloat = 4
    private static let gap: CGFloat = 3
    private static let lowest: CGFloat = 6
    private static let tallest: CGFloat = 16
    private static let linger: Duration = .seconds(1.2)
    private nonisolated static let space = "thinking-dial"

    /// 此刻画的样子：按着时是指到的那档。
    private var drawn: PiThinkingMeter { touched.map { PiThinkingMeter(levels: meter.levels, current: $0) } ?? meter }

    var body: some View {
        let drawn = drawn
        HStack(spacing: 6) {
            // 写出档名（与"上下文 86%"同一种写法）：只有一个脑图标加几根竖条要猜；按着时跟着指到的档变
            Text("\(wordy ? "思考 " : "")\(Text(drawn.current?.label ?? "–").fontWeight(.medium).foregroundStyle(palette.ink2))")
                .font(Typography.meta).foregroundStyle(palette.ink3)
                .contentTransition(.opacity)
                .fixedSize()
                .accessibilityHidden(true)
            meterBars(drawn)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: { track = $0 }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(palette.fill, in: .capsule)
        .overlay(alignment: .top) {
            if let bubble {
                Text("思考 \(Text(bubble.label).fontWeight(.semibold).foregroundStyle(palette.ink))")
                    .font(Typography.caption).foregroundStyle(palette.ink3)
                    .contentTransition(.opacity)
                    .padding(.horizontal, 10).frame(height: 26)
                    .glass(in: .capsule)
                    .fixedSize()
                    .offset(y: -32)
                    .transition(.opacity.combined(with: .scale(scale: 0.85, anchor: .bottom)))
                    .allowsHitTesting(false)
            }
        }
        .frame(minHeight: 44)
        .contentShape(.rect)
        .coordinateSpace(.named(Self.space))
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
                .onChanged(press)
                .onEnded { _ in
                    if let touched, touched != meter.current { choose(touched) }
                    touched = nil
                    released += 1
                })
        .task(id: released) {
            guard released > 0, (try? await Task.sleep(for: Self.linger)) != nil, touched == nil else { return }
            bubble = nil
        }
        .sensoryFeedback(.selection, trigger: touched) { _, new in new != nil }
        .animation(reduceMotion ? nil : Motion.snappy, value: drawn)
        .animation(Motion.quick, value: bubble)
        .accessibilityElement()
        .accessibilityLabel("思考强度")
        .accessibilityValue(meter.current?.label ?? "未知")
        .accessibilityAdjustableAction { direction in
            let next = direction == .increment ? meter.step(1) : meter.step(-1)
            if let next, next != meter.current { choose(next) }
        }
    }

    /// 按下与拖动：在竖格上就调到指着的档；按在"思考 中"那几个字上（还没拖动）只浮出现在的档。
    private func press(_ value: DragGesture.Value) {
        let onIcon = value.location.x < track.minX && touched == nil && abs(value.translation.width) < 4
        if onIcon {
            bubble = meter.current
            return
        }
        let level = meter.level(at: track.width > 0 ? (value.location.x - track.minX) / track.width : 0)
        touched = level
        bubble = level
    }

    private func meterBars(_ drawn: PiThinkingMeter) -> some View {
        bars(drawn) { index in index < drawn.filled ? (drawn.isMax ? palette.signature : palette.ink) : palette.ink.opacity(0.14) }
            .overlay {
                if drawn.isMax, !reduceMotion {
                    // 最高档：一道亮光从左往右扫过填满的格
                    LoopLayer(kind: .sheen, color: .white.opacity(0.75)).mask { bars(drawn) { _ in .black } }.allowsHitTesting(false)
                }
            }
            .overlay {
                if drawn.isOff {
                    // 关着：一道斜线压过空格
                    Capsule().fill(palette.ink3).frame(width: 1.5)
                        .frame(height: Self.tallest + 4).rotationEffect(.degrees(42))
                        .transition(.opacity)
                }
            }
            .modifier(Breathing(active: pending && touched == nil))
    }

    private func bars(_ drawn: PiThinkingMeter, color: @escaping (Int) -> Color) -> some View {
        HStack(alignment: .bottom, spacing: Self.gap) {
            ForEach(Array(drawn.bars.enumerated()), id: \.offset) { index, _ in
                Capsule().fill(color(index)).frame(width: Self.barWidth, height: height(index, of: drawn.bars.count))
            }
        }
        .frame(height: Self.tallest, alignment: .bottom)
    }

    /// 一格比一格高：从 `lowest` 均匀长到 `tallest`。
    private func height(_ index: Int, of count: Int) -> CGFloat {
        count > 1 ? Self.lowest + (Self.tallest - Self.lowest) * CGFloat(index) / CGFloat(count - 1) : Self.tallest
    }
}


/// 发出后还没送达：轻轻呼吸（只在这一小会儿）。一层胶囊底色盖在内容上一明一暗（`LoopLayer` 的 `pulse`，交给渲染服务）：
/// SwiftUI 的 repeatForever 每帧在 App 进程里重算，一直没送达时会话页静止也占约 9% CPU。减弱动态效果时不呼吸。
struct Breathing: ViewModifier {
    let active: Bool
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.overlay {
            if active, !reduceMotion { LoopLayer(kind: .pulse, color: palette.fill).mask { content }.allowsHitTesting(false) }
        }
    }
}
