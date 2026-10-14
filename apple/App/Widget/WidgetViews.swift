import SwiftUI
import WidgetKit

/// 小组件的界面。整块点击打开随手记（`DeepLink.capture`），卡片可用 `DeepLink.card` 链接直达。
enum WidgetViews {
    static func unfiled(_ entry: UnfiledEntry) -> some View {
        UnfiledView(entry: entry)
            .widgetURL(DeepLink.capture(project: nil).url)
            .containerBackground(.background, for: .widget)
    }

    /// Cue：头像与名字、"等你 N"（赭黄），下面它最近一句；整块点开 Cue 页（`DeepLink.cue`）。
    static func cue(_ entry: CueEntry) -> some View {
        CueView(snapshot: entry.snapshot)
            .widgetURL(DeepLink.cue.url)
            .containerBackground(.background, for: .widget)
    }
}

private struct CueView: View {
    let snapshot: CueSnapshot
    @Environment(\.widgetFamily) private var family

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image("mascot-cue-\(snapshot.mood)").resizable().scaledToFit().frame(width: family == .systemSmall ? 40 : 44)
                    .opacity(snapshot.mood == "sleeping" ? 0.6 : 1)
                VStack(alignment: .leading, spacing: 1) {
                    Text(snapshot.name).font(.headline).lineLimit(1)
                    WaitingCount(count: snapshot.waiting).font(.caption)
                }
            }
            if let line = snapshot.lastSaid {
                Text(line).font(.footnote).foregroundStyle(.secondary).lineLimit(family == .systemSmall ? 3 : 2)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct UnfiledView: View {
    let entry: UnfiledEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(Dotted("收件箱", "\(entry.snapshot.total)")).font(.caption).foregroundStyle(.secondary)
            ForEach(entry.snapshot.cards.prefix(3), id: \.id) { card in
                Text(card.title.isEmpty ? "图片" : card.title).font(.footnote).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
