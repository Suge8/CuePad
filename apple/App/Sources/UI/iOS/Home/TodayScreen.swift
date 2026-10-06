#if os(iOS)
import CueStore
import SwiftUI

nonisolated private struct TodayData: Sendable {
    var cards: [CardEntry]
    var total: Int
    var projects: [UUID: Project]
}

/// 今天流：今天编辑过的卡，跨项目按时间倒序，每张标出所属项目。
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
                        ContentUnavailableView("今天还没有动过的卡", systemImage: "sun.max").padding(.top, 60)
                    }
                    ForEach(data.cards) { entry in
                        CardRow(entry: entry, project: .some(entry.card.projectID.flatMap { data.projects[$0] }))
                    }
                    if data.total > data.cards.count {
                        Button("显示更多") { pages += 1 }.padding()
                    }
                }
            }
            .padding(.horizontal, 16).padding(.bottom, 24)
            .animation(Motion.quick, value: data?.cards.map(\.id))
        }
        .background(palette.desk)
        .captureBar()
        // 不带张数副标题：数据晚于推入到达，导航栏在推入后再加一行副标题会让整页跳一下；张数在书架的入口上
        .navigationTitle("今天")
        .observing(services.store, [.cards, .projects], id: pages, into: $data, onError: workspace.fail) { [pages] store in
            let now = Date.now
            let found = try store.search(
                SearchQuery(modifiedIn: Calendar.current.startOfDay(for: now)...now), limit: Self.pageSize * pages)
            return TodayData(
                cards: found.cards.map(CardEntry.init), total: found.totalCards,
                projects: Dictionary(uniqueKeysWithValues: try store.projects().map { ($0.id, $0) }))
        }
    }
}
#endif
