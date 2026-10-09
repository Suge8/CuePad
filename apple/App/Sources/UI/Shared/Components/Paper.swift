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
    var font: Font = .system(size: 11)
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

/// 滚动内容在顶栏、底栏后面淡到页面底色，玻璃后面不叠字（全 App 只此一种：Mac 工具栏下与底部输入栏下，iOS 推入页的状态栏与
/// 悬浮顶栏下、标签根页的底部栏下）。从这条边起先是一段实底（`solid`；nil 时是这条边的安全区——iOS 的状态栏加顶栏、
/// 底部栏让出的高度加主屏指示条），到栏的边沿处仍完全不透明，再往内容那边淡出 `fade` 这么高。
/// 是盖在内容上的底色渐变，而不是遮罩：遮罩要把整面滚动内容先画到离屏缓冲再裁，侧栏开合、滚动时每帧都要重来。
/// Mac 的栏高固定（给 `solid`），不读几何，侧栏开合时不跟着每帧重算；Mac 上用它作滚动视图的兄弟层：挂成滚动视图自己的
/// overlay 盖不住滚进工具栏区域的那段内容（macOS 把那段放在更上层）。
struct EdgeFade: View {
    let edge: VerticalEdge
    var solid: CGFloat?
    let fade: CGFloat

    #if os(macOS)
    /// 窗口工具栏下（工具栏高 52，往内容淡出 12；页面内容的上边距要让出这 12，停在顶部时标题不被淡掉）。
    static var underToolbar: EdgeFade { EdgeFade(edge: .top, solid: 52, fade: toolbarFade) }
    static let toolbarFade: CGFloat = 12
    /// 底部玻璃输入栏下（输入栏连同下边距约 70，往上淡出 64）。
    static var underInputBar: EdgeFade { EdgeFade(edge: .bottom, solid: 70, fade: 64) }
    #endif
    @Environment(\.palette) private var palette
    @Environment(\.pageBackground) private var pageBackground

    var body: some View {
        let alignment: Alignment = edge == .top ? .top : .bottom
        if let solid {
            gradient(solid: solid).frame(maxHeight: .infinity, alignment: alignment).ignoresSafeArea()
        } else {
            GeometryReader { proxy in
                let inset = edge == .top ? proxy.safeAreaInsets.top : proxy.safeAreaInsets.bottom
                gradient(solid: inset)
                    .frame(maxHeight: .infinity, alignment: alignment)
                    .offset(y: edge == .top ? -inset : inset)
            }
        }
    }

    private func gradient(solid: CGFloat) -> some View {
        let ground = pageBackground ?? palette.desk
        let height = solid + fade
        return LinearGradient(
            stops: [
                .init(color: ground, location: 0), .init(color: ground, location: solid / max(height, 1)),
                .init(color: ground.opacity(0), location: 1),
            ],
            startPoint: edge == .top ? .top : .bottom, endPoint: edge == .top ? .bottom : .top)
            .frame(height: height)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

extension EnvironmentValues {
    /// 页面的底色（iOS 推入页由 `RouteView` 给出：纸页是纸，其余是桌面）；`EdgeFade` 淡到它。没给时是桌面。
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

enum Highlight {
    /// 关键词命中处加底色（大小写不敏感）。
    static func matches(_ text: String, _ term: String, base: AttributedString? = nil) -> AttributedString {
        var result = base ?? AttributedString(text)
        let term = term.trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty else { return result }
        var searchStart = result.startIndex
        while searchStart < result.endIndex,
              let range = result[searchStart...].range(of: term, options: .caseInsensitive) {
            result[range].backgroundColor = .yellow.opacity(0.35)
            searchStart = range.upperBound
        }
        return result
    }
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
