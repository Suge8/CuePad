import SwiftUI

/// 控件的尺寸档：一排里只有一种高，相邻的按钮、胶囊、分段、单行输入同高。按"放在哪"取，不按好看另配一个数：
/// `inline` 嵌在别的控件里（输入框工具排、落点、筛选）；`compact` 卡、气泡、面板与设置行里的钮；`regular` 一排控件（圆钮、玻璃胶囊、页顶）。
/// 看得见的可以比命中小：点得到的边至少 `target`（Mac 常用操作 28，触屏 44）。
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

    /// 字离上下边的最小距离（字号大了胶囊随字长高）。Mac 的 `inline` 只留 2：12 点的字行高 15、胶囊上的模型标志 20，
    /// 留 6 就撑破 24 的档，一排里带标志的、不带的、思考强度条各高各的。
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
    /// 停用的控件整体变淡到这么多，看得出点不了。
    static let disabledOpacity = 0.45
}

/// 控件只有一套外形与按压实现；签名色只给主动作，其余是墨色。外形单拆成 `ControlSurface`：点开菜单的按钮（`MenuButton`）不是 `Button`，要同一个样子时直接挂它。
/// `glass`：浮在内容上的玻璃胶囊（Mac 工具栏与页顶那一排的项目范围、新任务、收起、清空回收站），与 `circular` 的玻璃圆钮同高；
/// `round`：纸与面板上的淡底圆钮（浮层的关闭、问号）——玻璃不叠玻璃，纸上不用 `circular`。毁掉东西的（`role: .destructive`）字是出错色。
/// `icon`：窗口最顶那一排不浮在内容上的图标钮（收起右栏、会话条开合）：同系统工具栏里不带玻璃的项，平时只有图标，悬停浮一层圆的淡底（`PressFeedback`），圆多大按 `size`。
struct ControlButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, quiet, circular, glass, round, icon }
    var kind = Kind.secondary
    var size = ControlSize.regular

    func makeBody(configuration: Configuration) -> some View {
        configuration.label.modifier(ControlSurface(kind: kind, size: size, destructive: configuration.role == .destructive))
            .modifier(PressFeedback(pressed: configuration.isPressed, kind: [.circular, .round, .icon].contains(kind) ? .button : .control))
    }
}

#if os(iOS)
extension View {
    /// 浮在内容上的玻璃圆钮（手机与 iPad 页顶那一排、窄屏侧栏那一排；挂在一排上管里面所有的钮与菜单）：系统的 Liquid Glass 钮——
    /// `.glass` 按钮样式配圆形的边（WWDC26 SwiftUI Group Lab：玻璃钮用玻璃按钮样式，不在钮上套 `glassEffect`，那是"钮坐在玻璃上"），
    /// 按压、悬停的反应都是系统给的（玻璃随手指鼓起、透光），不再叠 `PressFeedback`；只画图标，墨色，字号封顶同页顶那一排。
    /// 大小只有一种：`ControlMetrics.height` 见方（同系统导航栏里的圆钮），图标排在里面居中；一排里相邻两颗隔 `Spacing.item` 以内时放进同一个
    /// `GlassEffectContainer`，玻璃彼此取样、开合时相融。Mac 的工具栏圆钮仍是 `ControlButtonStyle(kind: .circular)`。
    func glassCircle() -> some View { modifier(GlassCircle()) }
}

private struct GlassCircle: ViewModifier {
    @Environment(\.palette) private var palette

    func body(content: Content) -> some View {
        content
            .font(Typography.body.weight(.medium))
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

/// `selected`：开着的筛选、选中的那一颗（全 App 一套选中：选中底、墨字半粗，docs/ui.md「选中」），只对带字的胶囊有意义；胶囊的外形经 `chip`。
/// `level`：胶囊自己当读数用（上下文用量）——底下从左铺一层到比例，高就是胶囊实际的高（随字号长），不含触屏补出来的点按区。
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
    @Environment(\.palette) private var palette
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        shape(content).opacity(isEnabled ? 1 : ControlMetrics.disabledOpacity)
    }

    @ViewBuilder private func shape(_ content: Content) -> some View {
        switch kind {
        case .circular:
            content
                .font(Typography.body.weight(.medium))
                .foregroundStyle(ink)
                .frame(width: ControlMetrics.height, height: ControlMetrics.height)
                .contentShape(.circle)
                .glass(in: .circle, interactive: true, ink: .clear)
        case .icon:
            content
                .font(Typography.body.weight(.medium))
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
                .font(Typography.secondary.weight(.medium))
                .foregroundStyle(ink)
                .padding(.horizontal, ControlSize.compact.padding)
                .frame(height: ControlMetrics.height)
                .contentShape(.capsule)
                .glass(in: .capsule, interactive: true)
        default:
            content
                .font(size.font.weight(selected ? .semibold : .medium))
                .foregroundStyle(kind == .primary ? palette.onFill : ink)
                .padding(.horizontal, size.padding)
                .padding(.vertical, size.verticalPadding)
                .frame(minHeight: size.height)
                .background(background, in: .capsule)
                .background {
                    if let level {
                        // 缩放不改排版，不用读几何
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
        case .primary: palette.signatureFill
        case .quiet, .glass, .icon: .clear
        case .secondary, .circular, .round: palette.fill
        }
    }
}
