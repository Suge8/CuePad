import SwiftUI
import WidgetKit

/// 小组件的界面。默认项目的整块点开"对 Cue 说"（`DeepLink.speak`，随手记也在那里说），卡片可用 `DeepLink.card` 链接直达。
/// 主 App（iOS）也编进这个文件，调试画面用同一份视图按系统尺寸画（`DebugWidgetStage`）：尺寸档由调用方给，
/// 小组件里从环境读（`widgetFamily` 只能由系统设）。
enum WidgetViews {
    static func defaultProject(_ snapshot: DefaultProjectSnapshot) -> some View {
        DefaultProjectView(snapshot: snapshot)
            .widgetURL(DeepLink.speak.url)
            .modifier(WidgetPaper())
    }

    /// Cue：头像（右上角是要你管的几件）、名字与数字账（`CueLedger`，同 App 里的名牌）；整块点开 Cue 页（`DeepLink.cue`）。
    static func cue(_ now: CueNow) -> some View {
        FamilyReader { cue(now, family: $0) }
    }

    static func cue(_ now: CueNow, family: WidgetFamily) -> some View {
        CueView(now: now, family: family)
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
    let now: CueNow
    let family: WidgetFamily
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CueNowFace(now: now, size: family == .systemSmall ? 48 : 52, badge: true, rim: palette.desk)
            Spacer(minLength: 0)
            Text(now.name).font(.headline).lineLimit(1)
            CueLedger(now: now, gap: 6).font(.footnote)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct DefaultProjectView: View {
    let snapshot: DefaultProjectSnapshot
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(Dotted(snapshot.name, "\(snapshot.total)")).font(.caption).foregroundStyle(palette.ink2)
            ForEach(snapshot.cards.prefix(3), id: \.id) { card in
                (card.title.isEmpty ? Text("图片") : Text(verbatim: card.title)).font(.footnote).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
