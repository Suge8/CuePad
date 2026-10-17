import CueStore
import CueText
import SwiftUI

/// 给输入框选一张卡片带上（作为这次消息的附件，卡片不动）：可搜；所属项目的资料在最前（长期参考，发给 Agent 时常要带上），
/// 再是本项目的其余卡片，其余按最近修改。点一张即选中并收起。
struct CardPicker: View {
    /// 排在前面的项目；nil 不分组。
    let project: UUID?
    let pick: (Card) -> Void
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.closePanel) private var close
    @Environment(\.palette) private var palette
    @State private var text = ""
    /// 拿去搜的词：输入法组字（拼音还没上屏）时不跟着变，上屏后再搜。
    @State private var settled = ""
    @State private var pages = 1
    @State private var data: Page?

    private static let macSize = CGSize(width: 560, height: 620)

    var body: some View {
        content
            .onChange(of: text) { if !TextComposition.isComposing { settled = text } }
            .onChange(of: settled) { pages = 1 }
            .observing(services.store, id: Key(text: settled, pages: pages), into: $data, onError: workspace.fail) {
                [project, settled, pages] store in
                try Page.read(text: settled, project: project, limit: PaletteQuery.pageSize * pages, from: store)
            }
    }

    #if os(iOS)
    private var content: some View {
        NavigationStack {
            list
                .scrollDismissesKeyboard(.immediately)
                .navigationTitle(Self.title)
                .navigationBarTitleDisplayMode(.inline)
                .searchable(text: $text, placement: .navigationBarDrawer(displayMode: .always), prompt: Self.prompt)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("关闭", icon: .close, role: .cancel) { close() } }
                }
        }
        .presentationDetents([.medium, .large])
    }
    #else
    private var content: some View {
        VStack(spacing: 14) {
            PanelHeader(Self.title)
            PanelSearchField(prompt: Self.prompt, text: $text)
            list
        }
        .padding(.top, 18)
        .frame(width: Self.macSize.width).frame(maxHeight: Self.macSize.height)
        .background(palette.desk)
    }
    #endif

    private static let title = "选一条灵感或任务"
    private static let prompt = "搜索灵感与任务"

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                if let data {
                    if data.shown == 0, !settled.isEmpty { EmptyState.noMatch(settled) }
                    if !data.resources.isEmpty {
                        header("资料", project: nil)
                        rows(data.resources)
                    }
                    if !data.pinned.isEmpty {
                        header(workspace.catalog?.project(project)?.name ?? "本项目", project: workspace.catalog?.project(project))
                        rows(data.pinned)
                        if !data.rest.isEmpty { header("其他", project: nil).padding(.top, 8) }
                    }
                    rows(data.rest, showsProject: true)
                    if data.total > data.shown {
                        Button("还有 \(data.total - data.shown) 条") { pages += 1 }.frame(maxWidth: .infinity).padding()
                    }
                }
            }
            .padding(.horizontal, 16).padding(.bottom, 24)
        }
        .background(palette.desk)
    }

    private func rows(_ entries: [CardEntry], showsProject: Bool = false) -> some View {
        ForEach(entries) { entry in
            CardRow(
                entry: entry, project: showsProject && project == nil ? .some(workspace.catalog?.project(entry.card.projectID)) : nil,
                highlight: settled
            ) { card in
                pick(card)
                close()
            }
        }
    }

    private func header(_ title: String, project: Project?) -> some View {
        HStack(spacing: 6) {
            if let project { ProjectGlyph(project: project, size: 12) }
            SectionHeader(title: title, count: nil).padding(.horizontal, -4)
        }
    }

    private struct Key: Equatable {
        var text: String
        var pages: Int
    }

    /// 一次读到的结果：所属项目的资料最前、本项目其余卡片其次（项目只在不分组时为 nil），其余在后；每张卡只出现一次。
    nonisolated struct Page: Sendable, Equatable {
        var resources: [CardEntry] = []
        var pinned: [CardEntry]
        var rest: [CardEntry]
        var total: Int
        var shown: Int { resources.count + pinned.count + rest.count }

        static func read(text: String, project: UUID?, limit: Int, from store: isolated CueStore) throws -> Page {
            let all = try store.search(SearchQuery(text: text), limit: limit)
            guard let project else { return Page(pinned: [], rest: all.cards.map(CardEntry.init), total: all.totalCards) }
            let own = try store.search(SearchQuery(text: text, projects: [project]), limit: limit).cards
            let rest = all.cards.filter { $0.projectID != project }
            return Page(
                resources: own.filter(\.isPinned).map(CardEntry.init), pinned: own.filter { !$0.isPinned }.map(CardEntry.init),
                rest: rest.map(CardEntry.init), total: all.totalCards)
        }
    }
}

/// 卡片与它的摘要。摘要在读数据时算好（Store 的执行体上），渲染与滚动时不在主线程解析正文。
nonisolated struct CardEntry: Identifiable, Sendable, Equatable {
    let card: Card
    let text: CardText
    var id: UUID { card.id }

    init(_ card: Card) {
        self.card = card
        var text = CardText(card.body)
        text.title = text.title.textGlyphs
        text.preview = text.preview.textGlyphs
        self.text = text
    }
}

/// 一张卡的纸面行（搜索结果与输入框的卡片选择共用）：可选的项目与时间、标题、摘要，右侧首图。
struct CardRow: View {
    let entry: CardEntry
    /// 标出所属项目（卡片选择里不属于本项目的那组）；nil 不标（搜索已按项目分组）。
    var project: Project??
    /// 命中的词（空格分隔），每个都标底色。
    var highlight = ""
    /// 点一下选中这张卡（卡片选择）；nil 时点开卡片，长按是卡片操作。
    var pick: ((Card) -> Void)?
    @Environment(\.palette) private var palette
    #if os(iOS)
    @Environment(\.zoomNamespace) private var zoom
    #endif
    /// 任务圈与标题同高。
    private static let ring: CGFloat = 18

    var body: some View {
        if let pick {
            Button { pick(entry.card) } label: { row }.buttonStyle(PressStyle(.card))
        } else {
            #if os(iOS)
            NavigationLink(value: Route.card(entry.card.id)) { row }
                .buttonStyle(PressStyle(.card))
                .zoomSource(entry.card.id, in: zoom)
                .contextMenu { CardActions(card: entry.card) }
            #endif
        }
    }

    private var row: some View {
        let card = entry.card, text = entry.text
        return HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                // 标题在前、时间靠右，与其余列表同一种读法
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    // 任务用全 App 同一个任务圈打头，一眼分得出任务与灵感
                    if card.isTask { TaskRingView(status: card.status, done: false, size: Self.ring) }
                    Text(marked(text.label)).font(.headline).foregroundStyle(palette.ink).lineLimit(2)
                    Spacer(minLength: 0)
                    Text(DateLabel.short(card.modifiedAt)).font(.caption.monospacedDigit()).foregroundStyle(palette.ink3).fixedSize()
                }
                // 搜索时摘要从命中处截起（`CueSummary.snippet`），看得出为什么搜到它
                let preview = highlight.isEmpty ? text.preview : CueSummary.snippet(card.body, matching: terms).textGlyphs
                if !preview.isEmpty {
                    Text(marked(preview)).font(.subheadline).foregroundStyle(palette.ink2).lineLimit(2)
                }
                if let project {
                    HStack(spacing: 4) {
                        ProjectGlyph(project: project, size: 10)
                        Text(project?.name ?? CaptureCopy.unfiled)
                    }
                    .font(.caption).foregroundStyle(palette.ink3).padding(.top, 2)
                }
            }
            .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
            if let image = text.images.first {
                Thumbnail(hash: image, height: 64, radius: 8).frame(width: 80)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .paper(radius: 16)
        .contentShape(.rect(cornerRadius: 16))
    }

    private var terms: [String] { highlight.split(whereSeparator: \.isWhitespace).map(String.init) }

    /// 变量照常标色，搜索词再叠一层命中底色。
    private func marked(_ string: String) -> AttributedString {
        Highlight.matches(string, highlight, base: VariableText.styled(string, palette))
    }
}

nonisolated extension String {
    /// ↩ ↪ 这类箭头在 iOS 上默认画成彩色 emoji 按键：加文字样式选择符，按普通字形显示。
    var textGlyphs: String {
        guard contains(where: { Self.emojiDefaulted.contains($0) }) else { return self }
        return String(flatMap { Self.emojiDefaulted.contains($0) ? [$0, "\u{FE0E}"] : [$0] })
    }

    private static let emojiDefaulted: Set<Character> = ["↩", "↪", "⤴", "⤵", "↔", "↕"]
}
