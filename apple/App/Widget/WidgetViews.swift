import SwiftUI
import WidgetKit

/// 小组件的界面（界面 Worker 替换）。整块点击打开随手记（`DeepLink.capture`），卡片可用 `DeepLink.card` 链接直达。
enum WidgetViews {
    static func inbox(_ entry: InboxEntry) -> some View {
        InboxView(entry: entry)
            .widgetURL(DeepLink.capture(project: nil).url)
            .containerBackground(.background, for: .widget)
    }
}

private struct InboxView: View {
    let entry: InboxEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("收件箱 · \(entry.snapshot.total)").font(.caption).foregroundStyle(.secondary)
            ForEach(entry.snapshot.cards.prefix(3), id: \.id) { card in
                Text(card.title.isEmpty ? "图片" : card.title).font(.footnote).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
