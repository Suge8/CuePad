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

/// App 前台开启，远程内容由 Mac 发布（`CueLiveActivity`）。
struct CueActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: CueActivityAttributes.self) { context in
            CueActivityViews(context.state, at: .now).lockScreen
                .widgetURL(DeepLink.cue.url)
        } dynamicIsland: { context in
            let views = CueActivityViews(context.state, at: .now)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.bottom) { views.expanded }
            } compactLeading: {
                views.compactLeading
            } compactTrailing: {
                views.compactTrailing
            } minimal: {
                views.minimal
            }
            .keylineTint(views.keyline)
            .widgetURL(DeepLink.cue.url)
        }
    }
}

struct SnapshotEntry<S: SnapshotFile>: TimelineEntry {
    let date: Date
    let snapshot: S?
}

/// 数据来自主 App 写在共享容器里的快照；主 App 在快照内容变了时刷新时间线，所以这里不自己定时刷新。
/// 快照里按时刻会变的（`timeline`：Cue 此刻过时、刚做完的那颗收掉）从此刻起排成时间线，到点由系统换，不靠 App 醒来。
struct SnapshotProvider<S: SnapshotFile>: TimelineProvider {
    /// 系统占位预览使用的内容；真实读取缺失时保留 nil。
    let empty: S
    var timeline: (S, Date) -> [SnapshotEntry<S>] = { [SnapshotEntry(date: $1, snapshot: $0)] }

    func placeholder(in context: Context) -> SnapshotEntry<S> { SnapshotEntry(date: .now, snapshot: empty) }

    func getSnapshot(in context: Context, completion: @escaping (SnapshotEntry<S>) -> Void) { completion(entries()[0]) }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotEntry<S>>) -> Void) {
        completion(Timeline(entries: entries(), policy: .never))
    }

    private func entries() -> [SnapshotEntry<S>] {
        let directory = (try? LibraryLocation.resolve())?.snapshotsDirectory
        guard let snapshot = directory.flatMap({ Snapshots.read(S.self, from: $0) }) else {
            return [SnapshotEntry(date: .now, snapshot: nil)]
        }
        return timeline(snapshot, .now)
    }
}

extension CueNow {
    static func timeline(_ now: CueNow, from date: Date) -> [SnapshotEntry<CueNow>] {
        sequence(first: date) { now.nextShownChange(after: $0) }.map { SnapshotEntry(date: $0, snapshot: now.shown(at: $0)) }
    }
}

struct CueWidget: Widget {
    static let kind = "CuePadCue"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: SnapshotProvider(empty: CueNow.empty, timeline: CueNow.timeline)) { entry in
            WidgetViews.cue(entry.snapshot ?? .empty)
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
        StaticConfiguration(kind: Self.kind, provider: SnapshotProvider(empty: DefaultProjectSnapshot(name: Project.defaultName, cards: [], total: 0))) { entry in
            WidgetViews.defaultProject(entry.snapshot)
        }
        .configurationDisplayName("默认")
        .description("最近记下的灵感，点一下对 Cue 说。")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
