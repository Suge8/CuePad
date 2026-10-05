#if os(iOS)
import CueStore
import CueSync
import SwiftUI

/// Pi：只回答"每个会话在做什么、现在到哪了、结果或卡点是什么"。"现在"是没结束的会话，按要你注意的先后排
/// （等你确认 → 出错 → 工作中 → 空闲）；"历史"是所有已结束的，按结束时间分段（今天、昨天……）、可搜，滑到底才读下一页。
/// 点开看近况、回复（历史会话看最后一轮、在 Mac 上继续）。右上角开新会话。
/// iPad 右侧面板里没有导航栏：搜索与新会话放在列表顶上。
struct ActivityScreen: View {
    var inPanel = false
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(Navigation.self) private var navigation
    @Environment(\.palette) private var palette
    @State private var list: PiSessionList?
    @State private var query = ""
    @State private var limit = PiSessionList.pageSize

    private var searching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        ScrollView {
            // 间距逐项写：历史的行要首尾相接拼成一张纸
            LazyVStack(alignment: .leading, spacing: 0) {
                if inPanel { panelHeader.padding(.bottom, 12) }
                if !services.syncStatus.reachesMac { SyncHint(status: services.syncStatus).padding(.horizontal, 4).padding(.bottom, 12) }
                if let list {
                    if list.isEmpty {
                        empty
                    } else {
                        if !list.now.isEmpty {
                            SectionTitle(text: "现在").padding(.bottom, 8)
                            rows(list.now).padding(.bottom, 24)
                        }
                        if !list.ended.isEmpty {
                            SectionTitle(text: "历史")
                            // 段内逐行懒加载：每行是 LazyVStack 的一个子项，滑到才画
                            ForEach(PiHistorySection.split(list.ended, date: \.state.stateSince, now: .now), id: \.section) { run in
                                Text(run.section.title).font(.footnote.weight(.medium)).foregroundStyle(palette.ink3)
                                    .padding(.horizontal, 4).padding(.top, 12).padding(.bottom, 6)
                                ForEach(Array(run.items.enumerated()), id: \.element.id) { index, item in
                                    VStack(spacing: 0) {
                                        if index > 0 { Divider().padding(.leading, 44) }
                                        SessionRow(item: item)
                                    }
                                    .paperSlice(first: index == 0, last: index == run.items.count - 1, radius: 16)
                                }
                            }
                        }
                        if list.loaded < list.total {
                            // 滑到这里才读下一页。按已读条数重跑：读完一页它仍在屏幕上（一页没填满屏幕）时接着读
                            ProgressView().frame(maxWidth: .infinity).padding(.vertical, 12)
                                .task(id: list.loaded) { limit = list.loaded + PiSessionList.pageSize }
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
            .animation(Motion.quick, value: list?.now.map(\.id))
            .animation(Motion.quick, value: list?.now.map(\.state.state))
        }
        .scrollDismissesKeyboard(.immediately)
        #if DEBUG
        .defaultScrollAnchor(DebugScene.scene == "activity" && DebugScene.defaults.integer(forKey: "CuePadHistory") > 0 && DebugScene.searchText.isEmpty ? .bottom : nil)
        #endif
        .background(palette.desk)
        .bottomEdgeFade()
        .navigationTitle("Pi")
        .modifier(PiPageChrome(enabled: !inPanel, query: $query))
        .refreshable { await services.syncNow() }
        .onChange(of: query) { limit = PiSessionList.pageSize }
        #if DEBUG
        .onAppear { if DebugScene.scene == "activity" { query = DebugScene.searchText } }
        #endif
        .observing(services.store, [.piSessionStates, .projects], id: PiSessionList.Key(text: query, limit: limit), into: $list,
                   onError: workspace.fail) { [query, limit] store in
            try PiSessionList.read(text: query, historyLimit: limit, from: store)
        }
    }

    private func rows(_ items: [PiSessionListItem]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                if index > 0 { Divider().padding(.leading, 44) }
                SessionRow(item: item)
            }
        }
        .paper(radius: 16)
    }

    @ViewBuilder private var empty: some View {
        if searching {
            ContentUnavailableView.search(text: query).padding(.top, 40)
        } else {
            ContentUnavailableView {
                Label("还没有 Pi 会话", systemImage: "terminal")
            } description: {
                Text("在 Mac 的终端运行 pi，或在这里开一个新会话")
            } actions: {
                Button("新会话") { navigation.newSession = .init() }.buttonStyle(.borderedProminent)
            }
            .padding(.top, 40)
        }
    }

    private var panelHeader: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(palette.ink3).accessibilityHidden(true)
                TextField("搜会话、目录、说过的话", text: $query).submitLabel(.search)
            }
            .padding(.horizontal, 12).frame(minHeight: 40)
            .background(palette.fill, in: .capsule)
            NewSessionButton()
        }
    }
}

/// 导航栏里的搜索与"新会话"（iPhone、iPad 详情栏）。
private struct PiPageChrome: ViewModifier {
    let enabled: Bool
    @Binding var query: String

    func body(content: Content) -> some View {
        if enabled {
            content
                .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜会话、目录、说过的话")
                .toolbar { ToolbarItem(placement: .primaryAction) { NewSessionButton() } }
        } else {
            content
        }
    }
}

private struct NewSessionButton: View {
    @Environment(Navigation.self) private var navigation

    var body: some View {
        Button("新会话", systemImage: "plus") { navigation.newSession = .init() }
            .accessibilityHint("在 Mac 的终端里开一个 Pi 会话")
    }
}

private struct SectionTitle: View {
    let text: String
    @Environment(\.palette) private var palette

    var body: some View {
        Text(text).font(.subheadline.weight(.semibold)).foregroundStyle(palette.ink2)
            .padding(.horizontal, 4)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Pi 页读到的会话："现在"是全部在线的（不多，不分页），按要你注意的先后；"历史"是已结束的前 `loaded` 条，
/// 从新到旧（分段见 `PiHistorySection`）。两部分用同一个搜索词。
nonisolated struct PiSessionList: Sendable, Equatable {
    static let pageSize = 40

    struct Key: Equatable {
        var text: String
        var limit: Int
    }

    var now: [PiSessionListItem]
    var ended: [PiSessionListItem]
    var total: Int

    var loaded: Int { ended.count }
    var isEmpty: Bool { now.isEmpty && total == 0 }

    static func read(text: String, historyLimit: Int, from store: isolated CueStore) throws -> PiSessionList {
        let live = try store.piSessionPage(PiSessionQuery(scope: .live, text: text, limit: .max)).items
        let ended = try store.piSessionPage(PiSessionQuery(scope: .ended, text: text, limit: historyLimit))
        let order = Dictionary(uniqueKeysWithValues: PiSessionState.inListOrder(live.map(\.state)).enumerated().map { ($1.id, $0) })
        return PiSessionList(
            now: live.sorted { order[$0.id, default: 0] < order[$1.id, default: 0] }, ended: ended.items, total: ended.total)
    }
}

/// 一个会话三层：左边状态标；名字与时长；在哪（项目或文件夹） · 状态词（带色）；一句进度或结果（没有不占行）。已结束的整行更淡。
private struct SessionRow: View {
    let item: PiSessionListItem
    @Environment(Navigation.self) private var navigation
    @Environment(\.palette) private var palette

    var body: some View {
        let session = item.state
        let place = PiPlace.name(of: session, project: item.project)
        Button { navigation.push(.session(session.id)) } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                PiStateDot(state: session.state, size: 8)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(session.title).font(.headline).foregroundStyle(palette.ink).lineLimit(1)
                        Spacer(minLength: 8)
                        PiElapsed(session: session)
                    }
                    HStack(spacing: 4) {
                        if let place { Text("\(place) ·").foregroundStyle(palette.ink3).lineLimit(1) }
                        Text(session.state.label).fontWeight(.medium).foregroundStyle(session.state.tint(palette))
                    }
                    .font(.subheadline)
                    if let progress = PiProgress.line(of: session) {
                        Text(progress).font(.subheadline).foregroundStyle(palette.ink2).lineLimit(1)
                    }
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(session.state == .known(.ended) ? 0.6 : 1)
            .contentShape(.rect)
        }
        .buttonStyle(RowPressStyle())
        .accessibilityElement(children: .combine)
        .accessibilityHint(session.state == .known(.ended) ? "看最后一轮、在 Mac 上继续" : "看近况、回复")
    }
}

/// 同步到不了 Mac 时的一行轻提示（Pi 页顶部、回复框里）：哪里不通；详情与处理在设置里。
struct SyncHint: View {
    let status: SyncStatus
    @Environment(\.palette) private var palette

    var body: some View {
        let summary = SyncSummary(status)
        Label("\(summary.title) · 看到的可能不是最新，也发不到 Mac", systemImage: summary.symbol)
            .font(.footnote).foregroundStyle(palette.ink3)
            .lineLimit(2)
    }
}
#endif

