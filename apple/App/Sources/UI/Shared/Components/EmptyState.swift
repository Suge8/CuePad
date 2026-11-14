import SwiftUI

/// 那句下一步按全角标点断成几截排（`PhraseLines`，标点黏在前一截末尾）：居中的中文按字折行，行尾常剩一两个孤字。
/// "这里还没有"类的空态（`waitsForSync`）在本机正在和 iCloud 对时（`SyncDriver.isCatchingUp`）不先说空：对得快就等对完再出，久过 `Pending.delay` 换成"正在从 iCloud 同步"——新装的设备上东西一页页地到，说"还没有"是错的。
struct EmptyState<Action: View>: View {
    let mascot: Mascot
    let title: LocalizedStringResource
    var message: LocalizedStringResource?
    var waitsForSync = false
    /// 不垫纸，直接排在所在那一面上（Cue 那一栏：整栏只有它，再套一张纸是卡里套卡）。
    var bare = false
    @ViewBuilder var action: Action
    @Environment(AppServices.self) private var services: AppServices?
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false
    @State private var syncing = false

    private var catchingUp: Bool { waitsForSync && services?.syncing.isCatchingUp == true }

    var body: some View {
        // 等同步那一句换成这里的空态：整块换身份，先淡掉再淡入（`handOff`），两块叠在同一张纸上、不同时交叉淡
        ZStack {
            VStack(spacing: Spacing.block) {
                illustration
                copy
                if !syncing { action }
            }
            .id(syncing)
            .transition(.handOff)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: 420)
        .padding(Spacing.sheet)
        .frame(maxWidth: .infinity)
        .modifier(Sheet(bare: bare))
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
        withAnimation(Motion.fading(Motion.nudge, reduceMotion: reduceMotion)) { shown = true }
    }

    private var illustration: some View {
        Image(decorative: syncing ? Mascot.search.rawValue : mascot.rawValue).resizable().scaledToFit()
            .frame(width: 104, height: 104)
            .readerHidden(true)
    }

    private var copy: some View {
        VStack(spacing: Spacing.tight) {
            HStack(spacing: Spacing.glyph) {
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

private struct Sheet: ViewModifier {
    let bare: Bool

    func body(content: Content) -> some View {
        if bare { content } else { content.paper(cornerRadius: Radius.sheet) }
    }
}

/// 用 `Layout` 一次排，不量了再写回状态。读屏读整句。
private struct PhraseLines: View {
    let text: String

    fileprivate static let breaks: Set<Character> = ["，", "。", "；", "：", "、", "！", "？"]

    var body: some View {
        Flow {
            ForEach(Array(Self.phrases(text).enumerated()), id: \.offset) { Phrase(text: $0.element) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }

    /// 一截：末尾的全角标点单放在一个字宽的格子里。整截一个 `Text` 时，排版把行尾的全角标点挤成半角（每截都在行尾），逗号句号就贴着字。
    /// 一行放不下、要在截内折行时整截一个 `Text`：格子挨着的是整块的右边，不是最后一行的末字，标点会悬在块外。
    private struct Phrase: View {
        let text: String

        var body: some View {
            if let last = text.last, PhraseLines.breaks.contains(last) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 0) {
                        Text(text.dropLast())
                        Text(verbatim: "中").hidden().overlay(alignment: .leading) { Text(String(last)) }
                    }
                    Text(text)
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

    static func noMatch(_ query: String) -> Self {
        EmptyState(mascot: .search, title: query.isEmpty ? "没有符合条件的结果" : "没有找到“\(query)”", message: "换个词或条件试试")
    }
}

enum Mascot: String {
    case welcome = "mascot-welcome"
    case empty = "mascot-empty"
    case search = "mascot-search"
    case trash = "mascot-trash"
    case clean = "mascot-clean"
    case error = "mascot-error"
    case hello = "mascot-hello"
}
