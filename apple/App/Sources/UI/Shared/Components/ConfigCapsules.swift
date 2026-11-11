import CueStore
import SwiftUI

/// Mac 点开与 ⌘⇧M 是同一个 AppKit 菜单（`ChoiceMenu`）：SwiftUI 在 Mac 上把菜单项里的图片丢掉。到了重置时刻无新观测就收起数值环（`Moments`）。
struct ModelCapsule: View {
    let models: ModelMenu
    let current: ModelOption?
    let unnamed: LocalizedStringResource
    let pending: Bool
    let quotas: [AccountQuota]
    #if os(macOS)
    let pick: () -> Void
    #endif

    var body: some View {
        Moments(next: quotas.nextReset(after:)) { now in capsule(at: now) }
    }

    @ViewBuilder private func capsule(at now: Date) -> some View {
        #if os(macOS)
        Button(action: pick) { label(at: now) }
            .buttonStyle(PressStyle())
            .accessibilityLabel("模型")
            .accessibilityValue(spoken(at: now))
        #else
        MenuButton(sections: models.sections(quotas: quotas, at: now), accessibilityLabel: "模型", value: spoken(at: now)) {
            label(at: now)
        }
        #endif
    }

    private func label(at now: Date) -> some View {
        let mark = current.flatMap(BrandMark.model), binding = binding(at: now)
        let badged = mark != nil || binding != nil
        let name = (current.map { Text(Dotted(ModelName.short($0), $0.account?.label(provider: $0.key.provider)).visible) } ?? Text(unnamed))
            .contentTransition(.opacity)
        return HStack(spacing: 0) {
            // 装饰：Mac 上菜单的标签与值会落到标签里的图标上，不藏起来读屏多出一个同名的"模型"
            if badged {
                ModelBadge(mark: mark, binding: binding)
                    .modifier(Breathing(active: pending))
                    .readerHidden(true)
                // 工具排给的宽放不下全名（`ConfigRow` 的 `model`）就只留标志，不截成"G…"；完整模型名可悬停、读屏或在菜单里看
                ViewThatFits(in: .horizontal) {
                    name.padding(.leading, Self.gap)
                    Color.clear.frame(width: 0, height: 0)
                }
            } else {
                name.truncationMode(.tail)
            }
        }
        .chip(menu: true)
        .help(spoken(at: now))
        .animation(Motion.fade, value: current?.key)
    }

    /// 标志与名字之间：胶囊（`inline` 档）里的图标贴字，比一般的图标与字（`glyph`）紧一档——工具排一排放到头，每颗省一点才不把名字挤掉。
    static let gap = Spacing.tight

    private func spoken(at now: Date) -> String {
        Dotted(current?.displayName ?? String(localized: unnamed), current.flatMap { $0.account?.label(provider: $0.key.provider) }, binding(at: now).map { String(localized: "\($0.name)额度剩 \($0.percent)") }).spoken
    }

    private func binding(at now: Date) -> QuotaMeter.Window? {
        guard let current, let quota = current.quota(in: quotas) else { return nil }
        return quota.binding(at: now, model: current.key.id).map { QuotaMeter.Window($0, at: now) }
    }
}


/// iOS 是系统菜单（`MenuButton`），Mac 同模型胶囊弹 AppKit 菜单（`ChoiceMenu`，SwiftUI 在 Mac 上丢掉菜单项里的产品标志）。
struct AgentCapsule: View {
    let pick: AgentPick
    #if os(macOS)
    @State private var anchor = PopUpAnchor()
    #endif

    var body: some View {
        if !pick.choosable {
            label.accessibilityElement(children: .ignore).accessibilityLabel("用 \(pick.current.name)")
        } else {
            #if os(macOS)
            Button { if let view = anchor.view { ChoiceMenu.popUp(pick.menu, below: view) } } label: { label }
                .buttonStyle(PressStyle())
                .popUpAnchor(anchor)
                .accessibilityLabel("Agent")
                .accessibilityValue(pick.current.name)
            #else
            MenuButton(sections: pick.menu, accessibilityLabel: "Agent", value: pick.current.name) { label }
            #endif
        }
    }

    private var label: some View {
        let kind = pick.current
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: ModelCapsule.gap) {
                ModelBadge(mark: kind.mark, binding: nil).readerHidden(true)
                Text(kind.name).lineLimit(1).contentTransition(.opacity)
            }.fixedSize()
            ModelBadge(mark: kind.mark, binding: nil).readerHidden(true)
        }
        .chip(menu: pick.choosable)
        .help(kind.name)
        .animation(Motion.fade, value: kind)
    }
}


/// 没有额度的只有标志、占同样大，换模型时不跳。认不出的模型（`BrandMark`）只有环；两样都没有时胶囊上不放它。
struct ModelBadge: View {
    let mark: BrandMark?
    let binding: QuotaMeter.Window?
    @ScaledMetric(relativeTo: .footnote) private var side: CGFloat = 20
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if let binding {
                QuotaRing(binding)
                    .animation(Motion.spatial(Motion.nudge, reduceMotion: reduceMotion), value: binding)
            }
            mark?.image
                .font(.system(size: side * 0.52))
                .contentTransition(.opacity)
        }
        .frame(width: side, height: side)
    }
}


struct ThinkingDial: View {
    let meter: ThinkingMeter
    let pending: Bool
    let choose: (ThinkingLevel) -> Void
    @Environment(\.singleLineConfig) private var compact
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @LoopsPlay private var loops
    @State private var touched: ThinkingLevel?
    @State private var bubble: ThinkingLevel?
    @State private var released = 0
    @State private var track: CGRect = .zero

    private var barWidth: CGFloat { compact ? 3 : 4 }
    private var gap: CGFloat { compact ? 2 : 3 }
    private var labelGap: CGFloat { compact ? 2 : 6 }
    private static let lowest: CGFloat = 6
    private static let tallest: CGFloat = 16
    private static let linger: Duration = .seconds(1.2)
    private nonisolated static let space = "thinking-dial"

    private var drawn: ThinkingMeter { touched.map(meter.pointing(at:)) ?? meter }

    var body: some View {
        #if os(iOS)
        Button {
            let levels = ThinkingLevel.allCases.filter(meter.levels.contains)
            let index = meter.current.flatMap { levels.firstIndex(of: $0) }
            if !levels.isEmpty { choose(levels[index.map { ($0 + 1) % levels.count } ?? 0]) }
        } label: {
            content
        }
        .buttonStyle(PressStyle())
        .accessibilityLabel("思考强度")
        .accessibilityValue(meter.label)
        #else
        content
        #endif
    }

    private var content: some View {
        let drawn = drawn
        return HStack(spacing: 0) {
            // 写出档名（与"上下文 86%"同一种写法）：只有一个脑图标加几根竖条要猜；按着时跟着指到的档变。
            // 工具排放不下时（`ConfigRow`）先只写档名，再只剩竖格（档名在读屏里）
            ViewThatFits(in: .horizontal) {
                reading(drawn, wordy: true).padding(.trailing, labelGap)
                reading(drawn, wordy: false).padding(.trailing, labelGap)
                Color.clear.frame(width: 0, height: 0)
            }
            .readerHidden(true)
            meterBars(drawn)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: { track = $0 }
        }
        .chip()
        .overlay(alignment: .top) {
            if let bubble {
                Text("思考 \(Text(bubble.label).fontWeight(.semibold).foregroundStyle(palette.ink))")
                    .font(Typography.caption).foregroundStyle(palette.ink3)
                    .contentTransition(.opacity)
                    .padding(.horizontal, Spacing.item).frame(height: 26)
                    .glass(in: .capsule)
                    .fixedSize()
                    .offset(y: -32)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        #if os(macOS)
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
        .animation(Motion.spatial(Motion.nudge, reduceMotion: reduceMotion), value: drawn)
        .animation(Motion.fade, value: bubble)
        #endif
        .accessibilityElement()
        .accessibilityLabel("思考强度")
        .accessibilityValue(meter.label)
        .accessibilityAdjustableAction { direction in
            let next = direction == .increment ? meter.step(1) : meter.step(-1)
            if let next, next != meter.current { choose(next) }
        }
    }

    private func reading(_ drawn: ThinkingMeter, wordy: Bool) -> some View {
        let level = Text(drawn.label).fontWeight(.medium).foregroundStyle(palette.ink2)
        return (wordy ? Text("思考 \(level)") : level)
            .font(Typography.meta).foregroundStyle(palette.ink3)
            .contentTransition(.opacity)
            .fixedSize()
    }

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

    private func meterBars(_ drawn: ThinkingMeter) -> some View {
        bars { index in
            index < drawn.filled ? palette.ink : drawn.current == nil ? palette.ink3 : palette.track
        }
            .overlay {
                if drawn.isMax, loops {
                    LoopLayer(kind: .sheen, color: palette.onFill).mask { bars { _ in .black } }.allowsHitTesting(false)
                }
            }
            .overlay {
                if drawn.isOff {
                    Capsule().fill(palette.ink3).frame(width: 1.5)
                        .frame(height: Self.tallest + 4).rotationEffect(.degrees(42))
                        .transition(.opacity)
                }
            }
            .modifier(Breathing(active: pending && touched == nil))
    }

    private func bars(color: @escaping (Int) -> Color) -> some View {
        HStack(alignment: .bottom, spacing: gap) {
            let count = ThinkingMeter.scale.count
            ForEach(0..<count, id: \.self) { index in
                Capsule().fill(color(index)).frame(width: barWidth, height: height(index, of: count))
            }
        }
        .frame(height: Self.tallest, alignment: .bottom)
    }

    private func height(_ index: Int, of count: Int) -> CGFloat {
        count > 1 ? Self.lowest + (Self.tallest - Self.lowest) * CGFloat(index) / CGFloat(count - 1) : Self.tallest
    }
}


/// SwiftUI 的 repeatForever 每帧在 App 进程里重算，一直没送达时会话页静止也占约 9% CPU，所以一层胶囊底色盖在内容上一明一暗，交给渲染服务（`LoopLayer` 的 `pulse`）。
struct Breathing: ViewModifier {
    let active: Bool
    @Environment(\.palette) private var palette
    @LoopsPlay private var breathes

    func body(content: Content) -> some View {
        content.overlay {
            if active, breathes { LoopLayer(kind: .pulse, color: palette.fill).mask { content }.allowsHitTesting(false) }
        }
    }
}
