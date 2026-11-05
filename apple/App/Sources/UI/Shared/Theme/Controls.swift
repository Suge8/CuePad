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

    /// 控件上的字（字重由控件给）。
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

    /// 带字的控件里字离两头。
    var padding: CGFloat {
        switch self {
        case .inline: 8
        case .compact: 12
        case .regular: 16
        }
    }
}

/// 圆钮、胶囊与行尾动作的几何：可见尺寸按平台，iPhone 的命中高度始终至少 44。
enum ControlMetrics {
    static var height: CGFloat { ControlSize.regular.height }
    static let stroke: CGFloat = 1
    /// 停用的控件整体变淡到这么多，看得出点不了。
    static let disabledOpacity = 0.45
}

/// 控件只有一套外形与按压实现，空态、绑定引导和搜索栏共用；签名色只给主动作，其余是墨色。高按 `size`（`ControlSize`）。
/// 外形单拆成 `ControlSurface`：点开菜单的按钮（`MenuButton`）不是 `Button`，要同一个样子时直接挂它。
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

/// 控件的外形（`ControlButtonStyle` 的样子，不含按压）；停用时整体变淡，挂在菜单按钮上的同样。
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
