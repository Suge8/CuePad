import CueEditor
import CueStore
import CueText
import SwiftUI

/// 瀑布墙：列数随宽度变化，每张卡按实测高度放进当前最短的列，墙底边尽量齐。
struct MasonryLayout: Layout {
    var minColumnWidth: CGFloat = 220
    var maxColumns = 4
    var spacing: CGFloat = 16

    private static let idealWidth: CGFloat = 900

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        // 问理想尺寸（nil）或最大尺寸（无穷）时给一个常规宽度：墙本身没有固有宽度，无穷宽会让列数换算崩溃
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? Self.idealWidth
        let frames = place(subviews, width: width)
        return CGSize(width: width, height: frames.map(\.maxY).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (subview, frame) in zip(subviews, place(subviews, width: bounds.width)) {
            subview.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                proposal: ProposedViewSize(width: frame.width, height: frame.height))
        }
    }

    /// 墙没有文字基线可对齐；默认实现会逐个询问子视图，侧栏开合时每帧都付这笔账（时间分析里约 4%）。
    func explicitAlignment(of guide: HorizontalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGFloat? { nil }
    func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGFloat? { nil }

    private func place(_ subviews: Subviews, width: CGFloat) -> [CGRect] {
        let columns = max(1, min(maxColumns, Int((width + spacing) / (minColumnWidth + spacing))))
        let columnWidth = (width - spacing * CGFloat(columns - 1)) / CGFloat(columns)
        var heights = Array(repeating: CGFloat(0), count: columns)
        return subviews.map { subview in
            let column = heights.indices.min { heights[$0] < heights[$1] } ?? 0
            let height = subview.sizeThatFits(ProposedViewSize(width: columnWidth, height: nil)).height
            let frame = CGRect(x: CGFloat(column) * (columnWidth + spacing), y: heights[column], width: columnWidth, height: height)
            heights[column] += height + spacing
            return frame
        }
    }
}

/// 卡片上的元信息：时间、发送目标，以及任务、浮回、资料标记。Mac 用固定小字，iOS 随动态字体。
struct CardMeta: View {
    let card: Card
    let text: CardText
    let lastTarget: String?
    let floated: Bool
    var font: Font = Typography.caption2
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 8) {
            Text(DateLabel.short(card.modifiedAt))
            // 第一个链接的域名：长段文字里一眼认出是哪张
            if let host = text.linkHost {
                Label(host, systemImage: "link").labelStyle(.titleAndIcon).lineLimit(1).truncationMode(.middle).layoutPriority(-1)
            }
            if let lastTarget { SentMark(target: lastTarget) }
            Spacer(minLength: 0)
            if card.isTask { Image(systemName: "checklist").help("任务").accessibilityLabel("任务") }
            if floated { Image(systemName: "arrow.up").help("刚从更早的灵感里拿回来").accessibilityLabel("刚从更早的灵感里拿回来") }
            if card.isPinned { Image(systemName: "books.vertical.fill").help("资料").accessibilityLabel("资料") }
        }
        .font(font)
        .foregroundStyle(palette.ink3)
    }
}

/// 栏后面最小的可读处理：从屏幕或窗口边沿的页面底色淡到栏的内沿全透，不铺实底、不伸进内容区——内容一直滚到栏下，
/// 玻璃后面隐约可见（沉浸式）。能用系统滚动边缘效果（`.scrollEdgeEffectStyle(.soft, …)`）的滚动区优先用系统的，这一层只补它到不了的地方：
/// iOS 推入页的状态栏那一段、Mac 底部输入栏（macOS 上系统效果几乎看不出）。Mac 窗口工具栏下是虚化的 `ToolbarEdge`。
/// 滚动区关掉了系统效果、内容会一直滚到整条栏后面时（iOS 倒过来的对话）只压一半不够，用 `BarScrim.veil`：整条栏（状态栏加悬浮顶栏）
/// 后面虚化并铺实，到栏下沿再往下淡出，与 `ToolbarEdge` 同一种做法（`EdgeVeil`）。
/// `height` 是栏占的高度；nil 时取 iOS 上边安全区里状态栏那一段（安全区减去悬浮顶栏）。
struct BarScrim: View {
    let edge: VerticalEdge
    var height: CGFloat?
    @Environment(\.palette) private var palette
    @Environment(\.pageBackground) private var pageBackground

    #if os(macOS)
    /// 底部玻璃输入栏（输入栏高 40 加下边距 16；改了输入栏的高度或边距时跟着改）。
    static var underInputBar: BarScrim { BarScrim(edge: .bottom, height: 56) }
    #endif

    /// 边沿处的不透明度：只压一半，栏上的字（时间、标题）压得住，后面的内容仍看得出来。
    private static let edgeOpacity = 0.5

    #if os(iOS)
    /// 盖住整条顶栏的一层（状态栏加悬浮顶栏，高度取上边安全区），到栏下沿仍是实的，再往下淡出 `EdgeVeil.fade`。
    /// 给关掉了系统滚动边缘效果的滚动区用（倒过来的对话）：内容滚到时间、返回钮、标题后面也读得出栏上的字。
    static var veil: some View {
        GeometryReader { proxy in
            EdgeVeil(solid: proxy.safeAreaInsets.top).offset(y: -proxy.safeAreaInsets.top)
        }
    }
    #endif

    var body: some View {
        let alignment: Alignment = edge == .top ? .top : .bottom
        if let height {
            scrim(height).frame(maxHeight: .infinity, alignment: alignment).ignoresSafeArea()
        } else {
            #if os(iOS)
            GeometryReader { proxy in
                let inset = proxy.safeAreaInsets.top
                scrim(max(0, inset - FloatingHeaderLayout.height / 2)).offset(y: -inset)
            }
            #endif
        }
    }

    private func scrim(_ height: CGFloat) -> some View {
        let ground = pageBackground ?? palette.desk
        return LinearGradient(
            colors: [ground.opacity(Self.edgeOpacity), ground.opacity(0)],
            startPoint: edge == .top ? .top : .bottom, endPoint: edge == .top ? .bottom : .top)
            .frame(height: height)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// 顶上一条栏后面的虚化：一层系统材质按渐变遮罩从实到无，叠一层由实到无的页面底色，让虚化的内容回到纸与墨的色温。
/// 从这条边起 `solid` 那么高是实的（栏本身），再往内容淡出 `fade`。遮罩只在这一条上，不碰滚动内容；"降低透明度"时退回实底渐变。
/// Mac 窗口工具栏下（`ToolbarEdge`）与 iOS 倒过来的对话的顶栏下（`BarScrim.veil`）都是它。
struct EdgeVeil: View {
    let solid: CGFloat
    static let fade: CGFloat = 20
    @Environment(\.palette) private var palette
    @Environment(\.pageBackground) private var pageBackground
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let ground = pageBackground ?? palette.desk
        let fading = LinearGradient(
            stops: [.init(color: .black, location: 0), .init(color: .black, location: solid / (solid + Self.fade)), .init(color: .clear, location: 1)],
            startPoint: .top, endPoint: .bottom)
        ZStack {
            if !reduceTransparency { Rectangle().fill(.regularMaterial) }
            LinearGradient(
                colors: [ground.opacity(reduceTransparency ? 1 : 0.72), ground.opacity(reduceTransparency ? 1 : 0.4)],
                startPoint: .top, endPoint: .bottom)
        }
        .mask(fading)
        .frame(height: solid + Self.fade)
        .frame(maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

#if os(macOS)
/// 窗口工具栏下的一条边：滚上来的内容到悬浮的玻璃条目（往上一层、标题、搜索与任务）后面时虚化，再往下淡出——与 iOS 的柔和滚动边缘效果
/// 同一种观感。系统的滚动边缘效果在这个窗口里只给得出不透明的硬边（透明标题栏下则完全没有，`scrollEdgeEffectStyle` 管不到标题栏这层），
/// 所以自己铺（`EdgeVeil`）。作滚动视图的兄弟层放在它上面、页面里浮在顶上的玻璃之下。
struct ToolbarEdge: View {
    /// 工具栏高，往内容再淡出 `fade`（页面内容的上边距要让出这一段，停在顶部时标题不被虚化）。
    static let height: CGFloat = 52
    static let fade = EdgeVeil.fade

    var body: some View { EdgeVeil(solid: Self.height) }
}
#endif

extension EnvironmentValues {
    /// 页面的底色（iOS 推入页由 `RouteView` 给出：纸页是纸，其余是桌面）；`BarScrim` 淡到它。没给时是桌面。
    @Entry var pageBackground: Color?
}

/// 发过的卡的标记：浅灰小纸飞机 + 目标名。没发过是默认状态，什么都不显示。卡片与列表共用这一种。
struct SentMark: View {
    let target: String

    var body: some View {
        Label(target, systemImage: "paperplane").labelStyle(.titleAndIcon).lineLimit(1)
            // 纸飞机是装饰：整体读作一句"已发给 …"
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("已发给 \(target)")
    }
}

/// 附件缩略图：按内容哈希从附件目录降采样读取，读不到时显示占位底色。
struct Thumbnail: View {
    let hash: String
    var height: CGFloat
    var radius: CGFloat = 10
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @Environment(\.displayScale) private var scale
    @State private var image: CGImage?

    var body: some View {
        Rectangle()
            .fill(palette.fill)
            .overlay {
                if let image {
                    Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fill)
                        // 深色下截图多是亮底，原样放在暗纸上刺眼：压暗一层
                        .overlay { if palette.dark { Color.black.opacity(0.14) } }
                }
            }
            .frame(height: height)
            .frame(maxWidth: .infinity)
            .clipShape(.rect(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder((palette.dark ? Color.white : .black).opacity(0.1)))
            .task(id: hash) {
                guard let url = services.store.files.fileURL(for: hash) else { return }
                let pixels = Int(height * 3 * scale)
                image = await Task.detached(priority: .utility) { Thumbnails.image(at: url, maxPixel: pixels) }.value
            }
    }
}

/// 预览文字里的 `{{变量}}` 染成琥珀色标注（`Palette.variable`）。
enum VariableText {
    static func styled(_ text: String, _ palette: Palette) -> AttributedString {
        var result = AttributedString(text)
        let utf16 = text.utf16
        for range in CueVariables.ranges(in: text, within: NSRange(location: 0, length: utf16.count)) {
            guard let swiftRange = Range(range, in: text), let attributed = Range(swiftRange, in: result) else { continue }
            result[attributed].foregroundColor = palette.variable
            result[attributed].backgroundColor = palette.variableBackground
        }
        return result
    }
}

/// 搜索命中的标法（灵感搜索、⌘K、Agent 页的会话搜索同一条）：搜索词按空格分开，每个词命中处加底色（大小写不敏感）。
enum Highlight {
    static func matches(_ text: String, _ query: String, base: AttributedString? = nil) -> AttributedString {
        var result = base ?? AttributedString(text)
        for term in query.split(whereSeparator: \.isWhitespace) {
            var searchStart = result.startIndex
            while searchStart < result.endIndex,
                  let range = result[searchStart...].range(of: term, options: .caseInsensitive) {
                result[range].backgroundColor = .yellow.opacity(0.35)
                searchStart = range.upperBound
            }
        }
        return result
    }
}

extension EnvironmentValues {
    /// 此刻的搜索词：列表里的会话行据此标出命中（`Highlight`）。
    @Entry var searchHighlight = ""
}

/// "更早"分组的标题：周是日期区间，月是年月。
enum OlderGroupTitle {
    static func text(_ period: OlderGroup.Period, calendar: Calendar = .current) -> String {
        let chinese = Locale(identifier: "zh_CN")
        switch period {
        case .all:
            return "更早"
        case .week(let start):
            // 两端都写成"月/日"，与卡片行上的日期同一种写法
            let end = calendar.date(byAdding: .day, value: 6, to: start) ?? start
            let day = Date.FormatStyle.dateTime.month(.defaultDigits).day().locale(chinese)
            return "\(start.formatted(day)) – \(end.formatted(day))"
        case .sparseMonth(let start):
            return start.formatted(.dateTime.month(.wide).locale(chinese))
        case .month(let start):
            return start.formatted(.dateTime.year().month(.wide).locale(chinese))
        }
    }
}

extension View {
    /// 纸页开合的原卡片：被纸盖住时隐去，被打开期间把位置报给纸页（见 `CardPresence`）；Mac 上报鼠标进出，按下时据此知道按的是哪张卡。
    func cardPresence(_ id: UUID, in workspace: Workspace) -> some View {
        modifier(CardPresenceSource(card: id, presence: workspace.presence(of: id), workspace: workspace))
    }
}

extension EnvironmentValues {
    /// 这张卡显出按下：鼠标按着，或刚被打开、纸页还在准备（见 `CardOpenStyle`）。
    @Entry var cardHeld = false
}

/// 单独的修饰器：只有它读这张卡的开合状态，卡片本身的内容不随开合重算。
private struct CardPresenceSource: ViewModifier {
    let card: UUID
    let presence: CardPresence
    let workspace: Workspace

    func body(content: Content) -> some View {
        content
            .environment(\.cardHeld, presence.held)
            .opacity(presence.covered ? 0 : 1)
            #if os(macOS)
            .onHover { workspace.hover(card, inside: $0) }
            #endif
            .background {
                // 只在被打开期间挂上位置读取；放在背景里，增减它不改变卡片本身的身份
                if presence.isTracked {
                    Color.clear.onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { presence.frame = $0 }
                }
            }
    }
}
