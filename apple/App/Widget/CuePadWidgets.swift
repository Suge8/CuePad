import ActivityKit
import CueStore
import SwiftUI
import WidgetKit

@main
struct CuePadWidgets: WidgetBundle {
    var body: some Widget {
        UnfiledWidget()
        CueWidget()
        CueActivityWidget()
    }
}

/// Cue 的实时活动（App 开、改、结束，`CueLiveActivity`）：各态的样子在 `CueActivityViews`，点卡片空白处进 Cue 页。
struct CueActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: CueActivityAttributes.self) { context in
            CueActivityViews.lockScreen(context.state, stale: context.isStale)
                .widgetURL(DeepLink.cue.url)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) { CueActivityViews.expandedLeading(context.state) }
                DynamicIslandExpandedRegion(.trailing) { CueActivityViews.expandedTrailing(context.state) }
                DynamicIslandExpandedRegion(.bottom) { CueActivityViews.expandedBottom(context.state, stale: context.isStale) }
            } compactLeading: {
                CueActivityViews.compactLeading(context.state)
            } compactTrailing: {
                CueActivityViews.compactTrailing(context.state)
            } minimal: {
                CueActivityViews.minimal(context.state)
            }
            .widgetURL(DeepLink.cue.url)
        }
    }
}

struct SnapshotEntry<S: SnapshotFile>: TimelineEntry {
    let date: Date
    let snapshot: S
}

/// 数据来自主 App 写在共享容器里的快照；主 App 在快照内容变了时刷新时间线，所以这里不自己定时刷新。
struct SnapshotProvider<S: SnapshotFile>: TimelineProvider {
    /// 还没有快照（从没打开过主 App）时显示的。
    let empty: S

    func placeholder(in context: Context) -> SnapshotEntry<S> { SnapshotEntry(date: .now, snapshot: empty) }

    func getSnapshot(in context: Context, completion: @escaping (SnapshotEntry<S>) -> Void) { completion(current()) }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotEntry<S>>) -> Void) {
        completion(Timeline(entries: [current()], policy: .never))
    }

    private func current() -> SnapshotEntry<S> {
        let directory = (try? LibraryLocation.resolve())?.snapshotsDirectory
        return SnapshotEntry(date: .now, snapshot: directory.flatMap { Snapshots.read(S.self, from: $0) } ?? empty)
    }
}

struct CueWidget: Widget {
    static let kind = "CuePadCue"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: SnapshotProvider(empty: CueSnapshot(name: "Cue", managing: 0, waiting: 0, mood: "sleeping"))) { entry in
            WidgetViews.cue(entry.snapshot)
        }
        .configurationDisplayName("Cue")
        .description("它在管几件、几件在等你，点一下和它说话。")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct UnfiledWidget: Widget {
    /// 已放到桌面的小组件按这个字符串认，改了它们会消失；与代码里的叫法不同是有意保留。
    static let kind = "CuePadInbox"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: SnapshotProvider(empty: UnfiledSnapshot(cards: [], total: 0))) { entry in
            WidgetViews.unfiled(entry.snapshot)
        }
        .configurationDisplayName("未分类")
        .description("最近记下的灵感，点一下对 Cue 说。")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
