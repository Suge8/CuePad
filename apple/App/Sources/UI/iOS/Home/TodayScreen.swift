#if os(iOS)
import CueStore
import SwiftUI

nonisolated private struct TodayData: Sendable {
    var cards: [Card]
    var total: Int
    var projects: [UUID: Project]
}

/// 今天流：今天编辑过的卡，跨项目按时间倒序；每张标出所属项目，右侧是首图缩略。
struct TodayScreen: View {
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @State private var data: TodayData?
    @State private var pages = 1

    nonisolated private static let pageSize = 40

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                if let data {
                    if data.cards.isEmpty {
                        ContentUnavailableView("今天还没有动过的卡", systemImage: "sun.max")
                            .padding(.top, 60)
                    }
                    ForEach(data.cards) { card in TodayRow(card: card, project: card.projectID.flatMap { data.projects[$0] }) }
                    if data.total > data.cards.count {
                        Button("显示更多") { pages += 1 }.padding()
                    }
                }
            }
            .padding(.horizontal, 16).padding(.bottom, 24)
        }
        .background(palette.desk)
        .navigationTitle("今天")
        .navigationSubtitle(data.map { "\($0.total) 张" } ?? "")
        .observing(services.store, [.cards, .projects], id: pages, into: $data, onError: workspace.fail) { [pages] store in
            let now = Date.now
            let found = try store.search(
                SearchQuery(modifiedIn: Calendar.current.startOfDay(for: now)...now), limit: Self.pageSize * pages)
            return TodayData(
                cards: found.cards, total: found.totalCards,
                projects: Dictionary(uniqueKeysWithValues: try store.projects().map { ($0.id, $0) }))
        }
    }
}

private struct TodayRow: View {
    let card: Card
    let project: Project?
    @Environment(\.palette) private var palette
    @Environment(\.zoomNamespace) private var zoom

    var body: some View {
        let text = CardText(card.body)
        NavigationLink(value: Navigation.Route.card(card.id)) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text(project?.name ?? "未归档")
                            .foregroundStyle(project.map { Palette.projectTint($0.color) } ?? palette.ink3)
                        Text(DateLabel.short(card.modifiedAt)).foregroundStyle(palette.ink3)
                    }
                    .font(.caption.weight(.medium))
                    Text(text.title.isEmpty ? "空白卡片" : text.title).font(.headline).foregroundStyle(palette.ink).lineLimit(2)
                    if !text.preview.isEmpty {
                        Text(VariableText.styled(text.preview, palette)).font(.subheadline).foregroundStyle(palette.ink2).lineLimit(2)
                    }
                    if text.blockCount > 1 {
                        Text("\(text.blockCount) 块").font(.caption).foregroundStyle(palette.ink3)
                    }
                }
                .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                if let image = text.images.first {
                    Thumbnail(hash: image, height: 72, radius: 8).frame(width: 96)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .paper(radius: 16)
        }
        .buttonStyle(.plain)
        .zoomSource(card.id, in: zoom)
        .contextMenu { CardActions(card: card, isGoal: false) }
    }
}
#endif
