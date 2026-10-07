import CueStore
import SwiftUI
import WidgetKit

@main
struct CuePadWidgets: WidgetBundle {
    var body: some Widget {
        InboxWidget()
    }
}

struct InboxEntry: TimelineEntry {
    let date: Date
    let snapshot: InboxSnapshot
}

/// 数据来自主 App 写在共享容器里的快照；主 App 在资料库变化时刷新时间线，所以这里不自己定时刷新。
struct InboxProvider: TimelineProvider {
    private static let empty = InboxSnapshot(cards: [], total: 0)

    func placeholder(in context: Context) -> InboxEntry {
        InboxEntry(date: .now, snapshot: Self.empty)
    }

    func getSnapshot(in context: Context, completion: @escaping (InboxEntry) -> Void) {
        completion(current())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<InboxEntry>) -> Void) {
        completion(Timeline(entries: [current()], policy: .never))
    }

    private func current() -> InboxEntry {
        let directory = (try? LibraryLocation.resolve())?.snapshotsDirectory
        let snapshot = directory.flatMap(Snapshots.readInbox(from:)) ?? Self.empty
        return InboxEntry(date: .now, snapshot: snapshot)
    }
}

struct InboxWidget: Widget {
    static let kind = "CuePadInbox"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: InboxProvider()) { entry in
            WidgetViews.inbox(entry)
        }
        .configurationDisplayName("收件箱")
        .description("最近记下的灵感，点一下就能随手记。")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
