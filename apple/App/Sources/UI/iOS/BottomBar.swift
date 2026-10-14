#if os(iOS)
import CueStore
import SwiftUI

/// 底部一行：左边一块玻璃里的三个标签 [Cue | Agent | 灵感]，右边一颗同高同玻璃的圆形"写"，与系统悬浮标签栏（照片、音乐：标签组靠左、
/// 搜索圆钮靠右）同一几何——高 62、离屏幕左右与底边都是 21（与屏幕圆角同心），选中滴同心内缩 4；不随滚动收小。
/// 玻璃上不另铺底；选中那一格是一层中性的滴（浅色压暗、深色更暗，同系统）加靛青的图标与字，未选中的是墨色。
/// 内容一直滚到栏后面、清楚可见，玻璃本身就是遮挡。
/// 浅色下玻璃的边几乎看不出，两块玻璃各描一圈发丝线、垫一层很轻的投影，从纸上浮起来。都不是色带：栏外一点不画。
/// 字号固定、不随动态字体放大，辅助字号下长按任一格或"写"弹出大内容查看器——系统标签栏同款取舍：栏高固定，字放大只会挤掉图标。
/// 按住选中的那一格时滴轻轻一压，按住另一格时手指下亮出一层淡按压底，都给一下轻触感；换标签时滴在轨道里滑过去
/// （减弱动态效果时淡出淡入、不压）。
/// Cue 那一格挂"等你 N"（`CueWaiting`，同侧栏的 Cue 一行）。
struct BottomBar: View {
    let select: (Navigation.Tab) -> Void
    @Environment(Navigation.self) private var navigation
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 正按着的那一格。
    @State private var pressed: Navigation.Tab?

    private static let height: CGFloat = 62
    private static let margin: CGFloat = 21
    /// 选中滴离轨道的边。
    private static let inset: CGFloat = 4
    private static let tabWidth: CGFloat = 80
    private static let icon: CGFloat = 20

    /// 内容在安全区之上还要给底部栏让出的高度（栏顶到安全区底边）；键盘盖住底部栏时为 0。
    static func reserve(above safeBottom: CGFloat) -> CGFloat { max(0, height + margin - safeBottom) }

    private var drop: Color { palette.dark ? Color.black.opacity(0.3) : palette.ink.opacity(0.07) }

    var body: some View {
        HStack(spacing: 12) {
            tabs
            Spacer(minLength: 0)
            Button { navigation.startCapture() } label: {
                Image(systemName: WriteEntry.symbol).font(.system(size: Self.icon, weight: .medium)).foregroundStyle(palette.ink)
                    .frame(width: Self.height, height: Self.height)
                    .contentShape(.circle)
            }
            .buttonStyle(PressStyle(.button))
            .glass(in: .circle, interactive: true)
            .modifier(BarLift(shape: .circle))
            .accessibilityLabel(WriteEntry.title)
            .accessibilityShowsLargeContentViewer { Label(WriteEntry.title, systemImage: WriteEntry.symbol) }
        }
        .padding(.horizontal, Self.margin)
        .padding(.bottom, Self.margin)
        .sensoryFeedback(.impact(weight: .light, intensity: 0.6), trigger: pressed) { _, now in now != nil }
    }

    /// 一块玻璃是轨道，选中滴是轨道里的一层底（玻璃不叠玻璃）；字与图标在最上面。
    private var tabs: some View {
        // 减弱动态效果时换成每格各一滴：换标签是旧滴淡出、新滴淡入（随 `Motion.spatial` 的短淡入淡出），不滑过去
        Capsule().fill(drop)
            .frame(width: Self.tabWidth, height: Self.height - Self.inset * 2)
            .scaleEffect(pressed == navigation.tab && !reduceMotion ? 0.94 : 1)
            .animation(Motion.press, value: pressed)
            .padding(Self.inset)
            .id(reduceMotion ? navigation.tab : nil)
            .transition(.opacity)
            .offset(x: Self.tabWidth * CGFloat(Navigation.Tab.allCases.firstIndex(of: navigation.tab) ?? 0))
            .frame(width: Self.tabWidth * CGFloat(Navigation.Tab.allCases.count) + Self.inset * 2, alignment: .leading)
            .glass(in: .capsule, interactive: true)
            .modifier(BarLift(shape: .capsule))
            .overlay {
                let cue = workspace.cue
                HStack(spacing: 0) {
                    tab(.cue, title: cue.name, symbol: "bubble.left.and.text.bubble.right", waiting: cue.digest.waiting)
                    tab(.agent, title: "Agent", symbol: "waveform.path.ecg")
                    tab(.projects, title: "灵感", symbol: "lightbulb")
                }
                .accessibilityElement(children: .contain)
                .accessibilityAddTraits(.isTabBar)
            }
    }

    private func tab(_ tab: Navigation.Tab, title: String, symbol: String, waiting: Int = 0) -> some View {
        let selected = navigation.tab == tab
        return Button { select(tab) } label: {
            VStack(spacing: 2) {
                Image(systemName: symbol).font(.system(size: Self.icon, weight: selected ? .semibold : .medium))
                    .frame(height: Self.icon + 4)
                    .overlay(alignment: .topTrailing) { WaitingBadge(count: waiting).dynamicTypeSize(...DynamicTypeSize.xLarge).offset(x: 13, y: -5) }
                Text(title).font(.system(size: 10, weight: selected ? .semibold : .medium)).lineLimit(1)
            }
            .foregroundStyle(selected ? palette.signature : palette.ink)
            // 一格占轨道的一半，四周的边也算它的：点在滴外面一点也算点中
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                // 按住没选中的这一格：手指下亮出一层比选中滴淡一半的底，与滴同大同心
                if pressed == tab, !selected {
                    Capsule().fill(drop.opacity(0.5)).padding(Self.inset).transition(.opacity)
                }
            }
            .animation(Motion.press, value: pressed)
            .contentShape(.rect)
        }
        .buttonStyle(TabPress(tab: tab, pressed: $pressed))
        .accessibilityElement(children: .ignore)
        .accessibilityShowsLargeContentViewer { Label(title, systemImage: symbol) }
        .accessibilityLabel(title)
        .accessibilityValue(waiting > 0 ? "等你 \(waiting)" : "")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// 底部栏玻璃的边：浅色下描一圈发丝线、垫一层很轻的投影（玻璃在浅纸上几乎看不出边）；深色下玻璃自己的高光已经分得开。
private struct BarLift<S: Shape>: ViewModifier {
    let shape: S
    @Environment(\.palette) private var palette

    func body(content: Content) -> some View {
        content
            .overlay { if !palette.dark { shape.stroke(palette.ink.opacity(0.1), lineWidth: 0.5).allowsHitTesting(false) } }
            .shadow(color: .black.opacity(palette.dark ? 0 : 0.06), radius: 8, y: 2)
    }
}

/// 标签的按下：字不缩（缩的是选中滴，见 `BottomBar`），只把"正按着哪一格"报上去。
private struct TabPress: ButtonStyle {
    let tab: Navigation.Tab
    @Binding var pressed: Navigation.Tab?

    func makeBody(configuration: Configuration) -> some View {
        configuration.label.onChange(of: configuration.isPressed) { _, down in
            if down { pressed = tab } else if pressed == tab { pressed = nil }
        }
    }
}
#endif
