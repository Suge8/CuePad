import ActivityKit
import CueStore
import SwiftUI
import WidgetKit

@main
struct CuePadWidgets: WidgetBundle {
    var body: some Widget {
        DefaultProjectWidget()
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
            let (state, stale) = (context.state, context.isStale)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) { CueActivityViews.expandedLeading(state, stale: stale) }
                DynamicIslandExpandedRegion(.trailing) { CueActivityViews.expandedTrailing(state, stale: stale) }
                DynamicIslandExpandedRegion(.center) { CueActivityViews.expandedCenter(state, stale: stale) }
                DynamicIslandExpandedRegion(.bottom) { CueActivityViews.expandedBottom(state, stale: stale) }
            } compactLeading: {
                CueActivityViews.compactLeading(state, stale: stale)
            } compactTrailing: {
                CueActivityViews.compactTrailing(state, stale: stale)
            } minimal: {
                CueActivityViews.minimal(state, stale: stale)
            }
            .keylineTint(CueActivityViews.keyline(state, stale: stale, palette: Palette(dark: true)))
            .widgetURL(DeepLink.cue.url)
        }
    }
}

struct SnapshotEntry<S: SnapshotFile>: TimelineEntry {
    let date: Date
    let snapshot: S
}

/// 数据来自主 App 写在共享容器里的快照；主 App 在快照内容变了时刷新时间线，所以这里不自己定时刷新。
/// 快照里按时刻会变的（`later`：Cue 此刻过时、刚做完的那颗收掉）预先排成时间线上后面的几条，到点由系统换，不靠 App 醒来。
struct SnapshotProvider<S: SnapshotFile>: TimelineProvider {
    /// 还没有快照（从没打开过主 App）时显示的。
    let empty: S
    var later: (S, Date) -> [SnapshotEntry<S>] = { _, _ in [] }

    func placeholder(in context: Context) -> SnapshotEntry<S> { SnapshotEntry(date: .now, snapshot: empty) }

    func getSnapshot(in context: Context, completion: @escaping (SnapshotEntry<S>) -> Void) { completion(current()) }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotEntry<S>>) -> Void) {
        let entry = current()
        completion(Timeline(entries: [entry] + later(entry.snapshot, entry.date), policy: .never))
    }

    private func current() -> SnapshotEntry<S> {
        let directory = (try? LibraryLocation.resolve())?.snapshotsDirectory
        return SnapshotEntry(date: .now, snapshot: directory.flatMap { Snapshots.read(S.self, from: $0) } ?? empty)
    }
}

extension CueNow {
    /// 小组件时间线上后面的几条：过时的那一刻只信慢的事实（`settled`），刚做完的那几颗各在到点时收掉。
    static func later(_ now: CueNow, after date: Date) -> [SnapshotEntry<CueNow>] {
        var entries: [SnapshotEntry<CueNow>] = []
        var shown = now, at = date
        let stale = now.at.addingTimeInterval(now.staleAfter)
        while true {
            let next = [shown.nextChange(after: at), stale > at && shown != shown.settled ? stale : nil].compactMap { $0 }.min()
            guard let next else { return entries }
            shown = (next >= stale ? shown.settled : shown).aged(to: next)
            at = next
            entries.append(SnapshotEntry(date: next, snapshot: shown))
        }
    }
}

struct CueWidget: Widget {
    static let kind = "CuePadCue"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: SnapshotProvider(empty: CueNow.empty, later: CueNow.later)) { entry in
            WidgetViews.cue(entry.snapshot)
        }
        .configurationDisplayName("Cue")
        .description("它此刻在做什么、手上几件活、几件等你拍板，点一下和它说话。")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct DefaultProjectWidget: Widget {
    /// 已放到桌面的小组件按这个字符串认，改了它们会消失；与代码里的叫法不同是有意保留。
    static let kind = "CuePadInbox"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: SnapshotProvider(empty: DefaultProjectSnapshot(name: "默认", cards: [], total: 0))) { entry in
            WidgetViews.defaultProject(entry.snapshot)
        }
        .configurationDisplayName("默认")
        .description("最近记下的灵感，点一下对 Cue 说。")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
