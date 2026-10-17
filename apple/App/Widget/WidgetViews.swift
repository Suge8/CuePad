import SwiftUI
import WidgetKit

/// 小组件的界面。未分类的整块点开"对 Cue 说"（`DeepLink.speak`，随手记也在那里说），卡片可用 `DeepLink.card` 链接直达。
/// 主 App（iOS）也编进这个文件，调试画面用同一份视图按系统尺寸画（`DebugWidgetStage`）：尺寸档由调用方给，
/// 小组件里从环境读（`widgetFamily` 只能由系统设）。
enum WidgetViews {
    static func unfiled(_ snapshot: UnfiledSnapshot) -> some View {
        UnfiledView(snapshot: snapshot)
            .widgetURL(DeepLink.speak.url)
            .modifier(WidgetPaper())
    }

    /// Cue：头像与名字、"等你 N"（赭黄），下面它最近一句；整块点开 Cue 页（`DeepLink.cue`）。
    static func cue(_ snapshot: CueSnapshot) -> some View {
        FamilyReader { cue(snapshot, family: $0) }
    }

    static func cue(_ snapshot: CueSnapshot, family: WidgetFamily) -> some View {
        CueView(snapshot: snapshot, family: family)
            .widgetURL(DeepLink.cue.url)
            .modifier(WidgetPaper())
    }
}

private struct FamilyReader<Content: View>: View {
    @ViewBuilder let content: (WidgetFamily) -> Content
    @Environment(\.widgetFamily) private var family

    var body: some View { content(family) }
}

/// 小组件的底与字：桌面色的底、墨色的字，同 App 一样的纸与墨（不用系统白底灰字）。
private struct WidgetPaper: ViewModifier {
    func body(content: Content) -> some View {
        content.modifier(Inked()).withPalette()
    }

    private struct Inked: ViewModifier {
        @Environment(\.palette) private var palette

        func body(content: Content) -> some View {
            content.foregroundStyle(palette.ink).containerBackground(palette.desk, for: .widget)
        }
    }
}

private struct CueView: View {
    let snapshot: CueSnapshot
    let family: WidgetFamily
    @Environment(\.palette) private var palette

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
                Text(line).font(.footnote).foregroundStyle(palette.ink2).lineLimit(family == .systemSmall ? 3 : 2)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct UnfiledView: View {
    let snapshot: UnfiledSnapshot
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(Dotted("未分类", "\(snapshot.total)")).font(.caption).foregroundStyle(palette.ink2)
            ForEach(snapshot.cards.prefix(3), id: \.id) { card in
                Text(card.title.isEmpty ? "图片" : card.title).font(.footnote).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
