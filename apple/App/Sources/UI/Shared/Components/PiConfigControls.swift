import CueStore
import SwiftUI

/// 回复框下方的模型与思考强度（iOS 会话页、Mac 会话页共用）：左边模型胶囊（提供方的印 + 模型短名，点开按提供方分组的菜单，
/// 当前打勾，每个写着它支持的强度），右边思考强度胶囊（"思考"的标 + 一组竖格：格数是当前模型支持的档位，一格比一格高，
/// 当前档以下填满，关着时格全空、一道斜线；点在哪格或横着拖就调到哪档，每过一档轻触一下；按下就在上方浮出档位名，
/// 松手后停一会儿再淡出，点"思考"的标只看现在是哪档；最高档填色有一道流光）。
/// 显示值由会话记录与配置请求推出（`SessionDigest.config`）：换了之后立即显示新值、填色轻轻呼吸直到送达，没换成回到原值
/// （原因由调用方写在输入框头部）。只给在线会话（已结束的不为换模型去唤醒 Pi），由调用方决定放不放。减弱动态效果时没有流光与呼吸。
struct PiConfigControls: View {
    let session: PiSessionState
    let shown: PiConfigShown
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    /// 这一排拿到的宽度：模型胶囊最宽是它的一半（`PiModelLabel.capsuleWidth`）。
    @State private var available: CGFloat = 0

    var body: some View {
        HStack(spacing: 6) {
            PiModelCapsule(models: session.models, current: shown.model, pending: shown.pending,
                           maxWidth: PiModelLabel.capsuleWidth(available: available)) { configure(PiConfig(model: $0)) }
            if let levels = shown.model?.thinkingLevels, !levels.isEmpty {
                PiThinkingDial(meter: PiThinkingMeter(levels: levels, current: shown.thinking), pending: shown.pending) {
                    configure(PiConfig(thinking: $0))
                }
            }
            if let context = shown.context { PiContextRing(session: session, usage: context) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { available = $0 }
    }

    private func configure(_ config: PiConfig) {
        workspace.attempt { _ = try await services.configure(config, for: session) }
    }
}

// MARK: 规则

/// 模型怎么写：胶囊上是提供方的印（名字的首字母）与短名（去掉"提供方/"前缀、Anthropic 模型名开头的 Claude、末尾的日期戳），菜单按提供方分组。
nonisolated enum PiModelLabel {
    static func short(_ model: PiModelOption) -> String {
        var name = model.name.isEmpty ? model.key.id : model.name
        if let slash = name.lastIndex(of: "/") { name = String(name[name.index(after: slash)...]) }
        name = name.replacing(/^(?i:claude)[\s\-]+/, with: "").replacing(/[\s\-]\d{8}$/, with: "")
        return name.isEmpty ? model.key.id : name
    }

    /// 提供方的印上的字：提供方名字的首字母（Anthropic 是 A、OpenAI 是 O）。
    static func seal(_ model: PiModelOption) -> String {
        provider(named: model.key.provider).prefix(1).uppercased()
    }

    /// 胶囊最宽是这一排宽度的一半，至少 96（短名放得下）、至多 240（iPad、Mac 宽屏不至于拉得过长）。
    static func capsuleWidth(available: CGFloat) -> CGFloat {
        min(max(available * 0.5, 96), 240)
    }

    /// 菜单里的分组：提供方按第一次出现的顺序。
    static func groups(_ models: [PiModelOption]) -> [(provider: String, models: [PiModelOption])] {
        var order: [String] = []
        var byProvider: [String: [PiModelOption]] = [:]
        for model in models {
            if byProvider[model.key.provider] == nil { order.append(model.key.provider) }
            byProvider[model.key.provider, default: []].append(model)
        }
        return order.map { (provider(named: $0), byProvider[$0] ?? []) }
    }

    private static func provider(named id: String) -> String {
        switch id.lowercased() {
        case "anthropic": "Anthropic"
        case "openai": "OpenAI"
        case "google", "gemini": "Google"
        case "xai": "xAI"
        case "deepseek": "DeepSeek"
        case "openrouter": "OpenRouter"
        default: id.prefix(1).uppercased() + id.dropFirst()
        }
    }
}

/// 思考强度条：格是当前模型支持的档位里除"关"以外的几档，当前档以下填满；关着时格全空。
/// 拖动时按横向位置均分所有档（含"关"，在最左）。
nonisolated struct PiThinkingMeter: Equatable {
    let levels: [PiThinkingLevel]
    let current: PiThinkingLevel?

    var bars: [PiThinkingLevel] { levels.filter { $0 != .off } }
    var filled: Int { current.flatMap { bars.firstIndex(of: $0) }.map { $0 + 1 } ?? 0 }
    var isOff: Bool { current == .off }
    /// 填到最高一档。
    var isMax: Bool { !bars.isEmpty && filled == bars.count }

    func level(at fraction: Double) -> PiThinkingLevel {
        let index = Int((min(max(fraction, 0), 0.999) * Double(levels.count)).rounded(.down))
        return levels[min(index, levels.count - 1)]
    }

    /// 读屏的上一档、下一档。
    func step(_ delta: Int) -> PiThinkingLevel? {
        guard let current, let index = levels.firstIndex(of: current) else { return levels.first }
        let next = index + delta
        return levels.indices.contains(next) ? levels[next] : nil
    }
}

extension PiThinkingLevel {
    /// 思考强度给人看的名字。
    nonisolated var label: String {
        switch self {
        case .off: "关"
        case .minimal: "最低"
        case .low: "低"
        case .medium: "中"
        case .high: "高"
        case .xhigh: "很高"
        case .max: "最高"
        }
    }
}

// MARK: 模型胶囊

private struct PiModelCapsule: View {
    let models: [PiModelOption]
    let current: PiModelOption?
    let pending: Bool
    let maxWidth: CGFloat
    let choose: (PiModelKey) -> Void
    @Environment(\.palette) private var palette

    var body: some View {
        Menu {
            ForEach(PiModelLabel.groups(models), id: \.provider) { group in
                Section(group.provider) {
                    ForEach(group.models) { model in
                        Toggle(isOn: Binding(get: { current?.key == model.key }, set: { if $0 { choose(model.key) } })) {
                            Text(model.name.isEmpty ? model.key.id : model.name)
                            Text(model.thinkingLevels.isEmpty ? "不调思考强度" : "思考 " + model.thinkingLevels.map(\.label).joined(separator: " · "))
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                // 装饰：Mac 上菜单的标签与值会落到标签里的图标上，不藏起来读屏多出一个同名的"模型"
                ProviderSeal(letter: current.map(PiModelLabel.seal)).modifier(Breathing(active: pending))
                    .accessibilityHidden(true)
                Text(current.map(PiModelLabel.short) ?? "模型").lineLimit(1).truncationMode(.tail)
                    .contentTransition(.opacity)
            }
            .font(.footnote.weight(.medium)).foregroundStyle(palette.ink2)
            .padding(.leading, 7).padding(.trailing, 11)
            // 按内容宽，最宽 `maxWidth`，再长截断
            .frame(maxWidth: maxWidth, alignment: .leading)
            .fixedSize(horizontal: true, vertical: false)
            .frame(height: 30)
            .background(palette.fill, in: .capsule)
            .frame(minHeight: 44)
            .contentShape(.capsule)
            .animation(Motion.quick, value: current?.key)
        }
        .menuIndicator(.hidden)
        #if os(macOS)
        .menuStyle(.button)
        #endif
        .buttonStyle(.plain)
        .accessibilityLabel("模型")
        .accessibilityValue(current?.name ?? "未知")
    }
}

/// 提供方的印：一方墨色小印，反白一个衬线首字母（纸与墨）；还不知道是哪个模型时是一方空印。
private struct ProviderSeal: View {
    let letter: String?
    @Environment(\.palette) private var palette
    @ScaledMetric(relativeTo: .footnote) private var side: CGFloat = 16

    var body: some View {
        RoundedRectangle(cornerRadius: side * 0.28, style: .continuous)
            .fill(letter == nil ? palette.ink3.opacity(0.4) : palette.ink2)
            .frame(width: side, height: side)
            .overlay {
                if let letter {
                    Text(letter).font(.system(size: side * 0.66, weight: .bold, design: .serif)).foregroundStyle(palette.paper)
                        .contentTransition(.opacity)
                }
            }
    }
}

// MARK: 思考强度条

private struct PiThinkingDial: View {
    let meter: PiThinkingMeter
    let pending: Bool
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
    private static let space = "thinking-dial"

    /// 此刻画的样子：按着时是指到的那档。
    private var drawn: PiThinkingMeter { touched.map { PiThinkingMeter(levels: meter.levels, current: $0) } ?? meter }

    var body: some View {
        let drawn = drawn
        HStack(spacing: 6) {
            Image(systemName: "brain").font(.caption.weight(.semibold)).foregroundStyle(palette.ink3)
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
                    .font(.caption).foregroundStyle(palette.ink3)
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

    /// 按下与拖动：在竖格上就调到指着的档；按在"思考"的标上（还没拖动）只浮出现在的档。
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
            .modifier(Breathing(active: pending && touched == nil && !reduceMotion))
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

/// 发出后还没送达：轻轻呼吸（只在这一小会儿，不是常驻动效）。
private struct Breathing: ViewModifier {
    let active: Bool
    @State private var dim = false

    func body(content: Content) -> some View {
        content
            .opacity(active && dim ? 0.45 : 1)
            .onChange(of: active, initial: true) { _, active in
                if active {
                    withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { dim = true }
                } else {
                    withAnimation(Motion.quick) { dim = false }
                }
            }
    }
}
