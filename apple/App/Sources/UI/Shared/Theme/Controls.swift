import SwiftUI

enum ControlSize {
    case inline, compact, regular

    var height: CGFloat {
        #if os(iOS)
        switch self {
        case .inline: 32
        case .compact: 36
        case .regular: 44
        }
        #else
        switch self {
        case .inline: 24
        case .compact: 28
        case .regular: 36
        }
        #endif
    }

    #if os(iOS)
    static let target: CGFloat = 44
    #else
    static let target: CGFloat = 28
    #endif

    var font: Font {
        switch self {
        case .inline: Typography.meta
        #if os(iOS)
        case .compact: Typography.secondary
        #else
        case .compact: Typography.meta
        #endif
        case .regular: Typography.secondary
        }
    }

    var verticalPadding: CGFloat {
        #if os(macOS)
        self == .inline ? 2 : 6
        #else
        6
        #endif
    }

    var padding: CGFloat {
        switch self {
        case .inline: 8
        case .compact: 12
        case .regular: 16
        }
    }
}

enum ControlMetrics {
    static var height: CGFloat { ControlSize.regular.height }
    static let stroke: CGFloat = 1
    static let disabledOpacity = 0.45
}

struct ControlButtonStyle: ButtonStyle {
    enum Kind {
        case primary, secondary, quiet, glass, round, icon
        #if os(macOS)
        case circular
        #endif
    }
    var kind = Kind.secondary
    var size = ControlSize.regular

    func makeBody(configuration: Configuration) -> some View {
        configuration.label.modifier(ControlSurface(kind: kind, size: size, destructive: configuration.role == .destructive))
            .modifier(PressFeedback(pressed: configuration.isPressed, kind: kind.round ? .button : .control))
    }
}

extension ControlButtonStyle.Kind {
    fileprivate var round: Bool {
        switch self {
        case .round, .icon: true
        case .primary, .secondary, .quiet, .glass: false
        #if os(macOS)
        case .circular: true
        #endif
        }
    }
}

#if os(iOS)
extension View {
    /// 浮在内容上的玻璃圆钮（手机与 iPad 页顶那一排、窄屏侧栏那一排；挂在一排上管里面所有的钮与菜单）：系统的 Liquid Glass 钮——
    /// `.glass` 按钮样式配圆形的边（WWDC26 SwiftUI Group Lab：玻璃钮用玻璃按钮样式，不在钮上套 `glassEffect`，那是"钮坐在玻璃上"），
    /// 按压、悬停的反应都是系统给的（玻璃随手指鼓起、透光），不再叠 `PressFeedback`；只画图标，墨色，字号封顶同页顶那一排。
    /// 大小只有一种：`ControlMetrics.height` 见方（同系统导航栏里的圆钮），图标排在里面居中；一排里相邻两颗隔 `Spacing.item` 以内时放进同一个
    /// `GlassEffectContainer`，玻璃彼此取样、开合时相融。Mac 的工具栏圆钮是 `ControlButtonStyle(kind: .circular)`，只在 Mac 编。
    func glassCircle() -> some View { modifier(GlassCircle()) }
}

private struct GlassCircle: ViewModifier {
    @Environment(\.palette) private var palette

    func body(content: Content) -> some View {
        content
            .font(Typography.bodyBold)
            .foregroundStyle(palette.ink)
            .labelStyle(GlassIconLabel())
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .dynamicTypeSize(...FloatingHeaderLayout.largestType)
    }
}

/// 玻璃圆钮的标签（钮与点开菜单的钮都写成 `Label`）：只画图标（名字给读屏与悬停提示），排在 `face` 见方里居中——
/// 系统样式在标签四周加它自己的边，标签随图标大小走的话一排里放大镜、筛选、头像各大各的。
private struct GlassIconLabel: LabelStyle {
    /// 标签那一块的边长：加上系统玻璃钮四周的边（iOS 27 实测每边约 7）是 `ControlMetrics.height`。
    static let face: CGFloat = 30

    func makeBody(configuration: Configuration) -> some View {
        configuration.icon.frame(width: Self.face, height: Self.face)
    }
}
#endif

struct ControlSurface: ViewModifier {
    struct Level: Equatable {
        let fraction: Double
        let color: Color
    }

    var kind = ControlButtonStyle.Kind.secondary
    var size = ControlSize.regular
    var selected = false
    var destructive = false
    var level: Level?
    var height: CGFloat?
    @Environment(\.palette) private var palette
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        shape(content).opacity(isEnabled ? 1 : ControlMetrics.disabledOpacity)
    }

    @ViewBuilder private func shape(_ content: Content) -> some View {
        switch kind {
        #if os(macOS)
        case .circular:
            content
                .font(Typography.bodyBold)
                .foregroundStyle(ink)
                .frame(width: ControlMetrics.height, height: ControlMetrics.height)
                .contentShape(.circle)
                .glass(in: .circle, interactive: true, ink: .clear)
        #endif
        case .icon:
            content
                .font(Typography.bodyBold)
                .foregroundStyle(ink)
                .frame(width: size.height, height: size.height)
                .contentShape(.circle)
        case .round:
            content
                .font(Glyph.small)
                .foregroundStyle(destructive ? palette.failure : palette.ink2)
                .frame(width: size.height, height: size.height)
                .background(palette.fill, in: .circle)
                .frame(minWidth: ControlSize.target, minHeight: ControlSize.target)
                .contentShape(.rect)
        case .glass:
            content
                .font(Typography.secondaryBold)
                .foregroundStyle(ink)
                .padding(.horizontal, ControlSize.compact.padding)
                .frame(height: ControlMetrics.height)
                .contentShape(.capsule)
                .glass(in: .capsule, interactive: true)
        default:
            content
                .font(size.font).emphasis(.bold)
                .foregroundStyle(kind == .primary ? palette.onAction : ink)
                .padding(.horizontal, size.padding)
                .padding(.vertical, size.verticalPadding)
                .frame(minWidth: height, minHeight: height ?? size.height)
                .background(background, in: .capsule)
                .background {
                    if let level {
                        level.color.scaleEffect(x: level.fraction, anchor: .leading).clipShape(.capsule)
                    }
                }
                .overlay { Capsule().strokeBorder(kind == .secondary && !selected ? palette.hair : .clear, lineWidth: ControlMetrics.stroke) }
                #if os(iOS)
                .frame(minHeight: ControlSize.target)
                #endif
                .contentShape(.capsule)
                .animation(Motion.fade, value: selected)
                .animation(Motion.fade, value: level)
        }
    }

    private var ink: Color { destructive ? palette.failure : palette.ink }

    private var background: Color {
        if selected { return palette.selection }
        return switch kind {
        case .primary: palette.action
        case .quiet, .glass, .icon: .clear
        case .secondary, .round: palette.fill
        #if os(macOS)
        case .circular: palette.fill
        #endif
        }
    }
}
