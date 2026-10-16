import CueStore
import SwiftUI
import WidgetKit

@main
struct CuePadWidgets: WidgetBundle {
    var body: some Widget {
        UnfiledWidget()
        CueWidget()
    }
}

struct UnfiledEntry: TimelineEntry {
    let date: Date
    let snapshot: UnfiledSnapshot
}

/// 数据来自主 App 写在共享容器里的快照；主 App 在资料库变化时刷新时间线，所以这里不自己定时刷新。
struct UnfiledProvider: TimelineProvider {
    private static let empty = UnfiledSnapshot(cards: [], total: 0)

    func placeholder(in context: Context) -> UnfiledEntry {
        UnfiledEntry(date: .now, snapshot: Self.empty)
    }

    func getSnapshot(in context: Context, completion: @escaping (UnfiledEntry) -> Void) {
        completion(current())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<UnfiledEntry>) -> Void) {
        completion(Timeline(entries: [current()], policy: .never))
    }

    private func current() -> UnfiledEntry {
        let directory = (try? LibraryLocation.resolve())?.snapshotsDirectory
        let snapshot = directory.flatMap(Snapshots.readUnfiled(from:)) ?? Self.empty
        return UnfiledEntry(date: .now, snapshot: snapshot)
    }
}

struct CueEntry: TimelineEntry {
    let date: Date
    let snapshot: CueSnapshot
}

/// Cue 的小组件：快照由主 App 在 Cue 的对话、等你的数变化时写，同样不自己定时刷新。
struct CueProvider: TimelineProvider {
    private static let empty = CueSnapshot(name: "Cue", waiting: 0, lastSaid: nil, mood: "sleeping")

    func placeholder(in context: Context) -> CueEntry { CueEntry(date: .now, snapshot: Self.empty) }

    func getSnapshot(in context: Context, completion: @escaping (CueEntry) -> Void) { completion(current()) }

    func getTimeline(in context: Context, completion: @escaping (Timeline<CueEntry>) -> Void) {
        completion(Timeline(entries: [current()], policy: .never))
    }

    private func current() -> CueEntry {
        let directory = (try? LibraryLocation.resolve())?.snapshotsDirectory
        return CueEntry(date: .now, snapshot: directory.flatMap(Snapshots.readCue(from:)) ?? Self.empty)
    }
}

struct CueWidget: Widget {
    static let kind = "CuePadCue"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: CueProvider()) { entry in
            WidgetViews.cue(entry)
        }
        .configurationDisplayName("Cue")
        .description("等你的几件事和它最近说的一句，点一下和它说话。")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct UnfiledWidget: Widget {
    /// 已放到桌面的小组件按这个字符串认，改了它们会消失；与代码里的叫法不同是有意保留。
    static let kind = "CuePadInbox"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: UnfiledProvider()) { entry in
            WidgetViews.unfiled(entry)
        }
        .configurationDisplayName("未分类")
        .description("最近记下的灵感，点一下对 Cue 说。")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
