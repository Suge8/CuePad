import SwiftUI

/// 空态与出错页：吉祥物、一句现状、一句下一步、一个可选动作，自上而下一列居中，全 App 只有这一套布局：
/// 任何宽度与辅助字号下字都按行折、不和图或按钮并排挤成竖排。那张纸与所在页面的内容同宽（左右边线与标题、其他纸对齐，中轴就是页面的中轴），纸里的字居中、最宽 420。
/// 那句下一步按逗号、句号断成几截排（`PhraseLines`）：居中的中文按字折行，行尾常剩一两个孤字。
/// 吉祥物出场时从下方轻轻弹上来，只这一次；减弱动态效果时只淡入、不挪。
/// "这里还没有"类的空态（`waitsForSync`）在本机正在和 iCloud 对时（`AppServices.isCatchingUp`）不先说空：对得快就等对完再出，
/// 久过 `Pending.delay` 换成"正在从 iCloud 同步"——新装的设备上东西一页页地到，说"还没有"是错的。
struct EmptyState<Action: View>: View {
    let mascot: Mascot
    let title: LocalizedStringResource
    var message: LocalizedStringResource?
    var waitsForSync = false
    @ViewBuilder var action: Action
    @Environment(AppServices.self) private var services: AppServices?
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false
    @State private var syncing = false

    private var catchingUp: Bool { waitsForSync && services?.isCatchingUp == true }

    var body: some View {
        VStack(spacing: 16) {
            illustration
            copy
            if !syncing { action }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: 420)
        .padding(24)
        .frame(maxWidth: .infinity)
        .paper(radius: 24)
        .scaleEffect(shown || reduceMotion ? 1 : 0.97)
        .opacity(shown ? 1 : 0)
        .buttonStyle(ControlButtonStyle(kind: .primary))
        .onAppear { if !catchingUp { appear() } }
        .onChange(of: catchingUp) { if !catchingUp { appear() } }
        .pending(catchingUp, shown: $syncing)
        .onChange(of: syncing) { if syncing { appear() } }
    }

    private func appear() {
        guard !shown else { return }
        withAnimation(reduceMotion ? HandOff.quick : Motion.snappy) { shown = true }
    }

    private var illustration: some View {
        Image(syncing ? Mascot.search.rawValue : mascot.rawValue).resizable().scaledToFit()
            .frame(width: 104, height: 104)
            .accessibilityHidden(true)
    }

    private var copy: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                if syncing { Spinner(.small) }
                Text(syncing ? "正在从 iCloud 同步" : title)
            }
            .font(Typography.emptyTitle)
            .foregroundStyle(palette.ink)
            if let message = syncing ? "别的设备上的内容到了就会出现在这里" : message {
                PhraseLines(text: String(localized: message)).font(Typography.secondary)
                    .foregroundStyle(palette.ink2)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// 一段居中的话按标点断成几截（标点留在前一截末尾），一截一截往行里排：这一行放不下下一截就整截换行，一截比一行还宽时它自己折。
/// 用 `Layout` 一次排，不量了再写回状态。读屏读整句。
private struct PhraseLines: View {
    let text: String

    fileprivate static let breaks: Set<Character> = ["，", "。", "；", "：", "！", "？"]

    var body: some View {
        Flow {
            ForEach(Array(Self.phrases(text).enumerated()), id: \.offset) { Phrase(text: $0.element) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }

    /// 一截：末尾的全角标点单放在一个字宽的格子里。整截一个 `Text` 时，排版把行尾的全角标点挤成半角（每截都在行尾），逗号句号就贴着字。
    private struct Phrase: View {
        let text: String

        var body: some View {
            if let last = text.last, PhraseLines.breaks.contains(last) {
                HStack(spacing: 0) {
                    Text(text.dropLast())
                    Text(verbatim: "中").hidden().overlay(alignment: .leading) { Text(String(last)) }
                }
            } else {
                Text(text)
            }
        }
    }

    static func phrases(_ text: String) -> [String] {
        var phrases: [String] = [], current = ""
        for character in text {
            current.append(character)
            if breaks.contains(character) {
                phrases.append(current)
                current = ""
            }
        }
        if !current.isEmpty { phrases.append(current) }
        return phrases
    }

    private struct Flow: Layout {
        private static let lineGap: CGFloat = 2

        /// 按哪个宽分的行：量过的宽摆放时直接用，不再分一遍（子视图一变，系统按 `makeCache` 重建）。
        struct Cache {
            var width: CGFloat?
            var rows: [Row] = []
        }

        func makeCache(subviews: Subviews) -> Cache { Cache() }

        func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
            let rows = rows(width: proposal.width ?? .infinity, subviews, cache: &cache)
            return CGSize(width: rows.map(\.width).max() ?? 0, height: height(rows))
        }

        func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
            var y = bounds.minY
            for row in rows(width: bounds.width, subviews, cache: &cache) {
                var x = bounds.midX - row.width / 2
                for (index, size) in row.items {
                    subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                    x += size.width
                }
                y += row.height + Self.lineGap
            }
        }

        struct Row {
            var items: [(Int, CGSize)] = []
            var width: CGFloat = 0
            var height: CGFloat = 0
        }

        private func rows(width: CGFloat, _ subviews: Subviews, cache: inout Cache) -> [Row] {
            if cache.width != width {
                cache.rows = rows(width: width, subviews)
                cache.width = width
            }
            return cache.rows
        }

        private func rows(width: CGFloat, _ subviews: Subviews) -> [Row] {
            var rows: [Row] = [], row = Row()
            for index in subviews.indices {
                let ideal = subviews[index].sizeThatFits(.unspecified)
                let size = ideal.width <= width ? ideal : subviews[index].sizeThatFits(ProposedViewSize(width: width, height: nil))
                if !row.items.isEmpty, row.width + size.width > width {
                    rows.append(row)
                    row = Row()
                }
                row.items.append((index, size))
                row.width += size.width
                row.height = max(row.height, size.height)
            }
            if !row.items.isEmpty { rows.append(row) }
            return rows
        }

        private func height(_ rows: [Row]) -> CGFloat {
            rows.map(\.height).reduce(0, +) + Self.lineGap * CGFloat(max(rows.count - 1, 0))
        }
    }
}

extension EmptyState where Action == EmptyView {
    init(mascot: Mascot, title: LocalizedStringResource, message: LocalizedStringResource? = nil, waitsForSync: Bool = false) {
        self.init(mascot: mascot, title: title, message: message, waitsForSync: waitsForSync) { EmptyView() }
    }

    /// 没搜到；没有搜索词（只按条件筛）时不复述空词。
    static func noMatch(_ query: String) -> Self {
        EmptyState(mascot: .search, title: query.isEmpty ? "没有符合条件的结果" : "没有找到“\(query)”", message: "换个词或条件试试")
    }
}

/// 空态的动作按钮：small 给次要动作（墨色，签名色留给页上别处），primary 给整页唯一的主动作。两种尺寸共用同一字体、圆角、线宽、按压和触感。
struct EmptyStateButton: View {
    enum Kind { case small, primary }

    let title: LocalizedStringResource
    let icon: Icon?
    var kind = Kind.primary
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            if let icon {
                Label(title, icon: icon)
            } else {
                Text(title)
            }
        }
        .labelStyle(.titleAndIcon)
        .buttonStyle(ControlButtonStyle(kind: kind == .small ? .secondary : .primary, compact: kind == .small))
    }
}

/// 吉祥物的表情，对应 Assets 里的 mascot 图。
enum Mascot: String {
    case welcome = "mascot-welcome"
    case empty = "mascot-empty"
    case search = "mascot-search"
    case trash = "mascot-trash"
    case clean = "mascot-clean"
    case error = "mascot-error"
    case hello = "mascot-hello"

    /// 浮动用的位图（`LoopLayer.float`），按 `side` 的三倍取。
    func bitmap(side: CGFloat) -> CGImage? {
        #if os(macOS)
        var rect = CGRect(x: 0, y: 0, width: side * 3, height: side * 3)
        return NSImage(named: rawValue)?.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        #else
        UIImage(named: rawValue)?.cgImage
        #endif
    }
}
