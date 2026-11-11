import CueStore
import SwiftUI

/// 菜单的样式跟外面的环境（Mac 在外面套 `.menuStyle(.button)`）。
struct SearchFilters: View {
    @Binding var query: PaletteQuery
    let targets: [SendTarget]

    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    var body: some View {
        let projects = workspace.catalog?.projects ?? []
        menu(String(localized: "项目"), query.projectLabel(in: projects), on: query.project != nil) {
            Button("全部") { query.project = nil }
            Divider()
            ForEach(projects) { project in Button(project.shownName) { query.project = project.id } }
        }
        Button { query.withAttachments.toggle() } label: { chip(String(localized: "含附件"), nil, on: query.withAttachments) }
            .buttonStyle(PressStyle())
            .accessibilityAddTraits(query.withAttachments ? .isSelected : [])
        menu("Agent", query.sentLabel, on: query.sent != .any) {
            Button("任意") { query.sent = .any }
            Divider()
            Button("没发给过 Agent") { query.sent = .never }
            Button("发给过 Agent") { query.sent = .sent(kind: .known(.piSession)) }
            if !targets.isEmpty {
                Divider()
                ForEach(targets, id: \.filterID) { target in
                    Button(target.name) { query.sent = .sent(kind: target.kind, name: target.name) }
                }
            }
        }
        menu(String(localized: "时间"), query.period.label, on: query.period != .any) {
            ForEach(PaletteQuery.Period.allCases, id: \.self) { period in Button(period.label) { query.period = period } }
        }
    }

    private func menu(_ name: String, _ value: String, on: Bool, @ViewBuilder items: () -> some View) -> some View {
        Menu { items() } label: { chip(name, value, on: on).menuLabel("\(name)：\(value)") }
    }

    private func chip(_ name: String, _ value: String?, on: Bool) -> some View {
        HStack(spacing: Spacing.tight) {
            if let value, on {
                Text(name).fontWeight(.regular).foregroundStyle(palette.ink2)
                Text(value).fontWeight(.medium)
            } else {
                Text(name)
            }
        }
        .chip(on: on, menu: value != nil)
    }
}

/// 结果变短时滚动位置留在原处、落到内容外面，懒加载的列表画成空白，两端都会，所以换了条件（卡片页数回到 1）就回到顶上，"显示更多"不动。
struct ResultsScroll<Content: View>: View {
    let query: PaletteQuery
    @ViewBuilder let content: Content

    private static var top: String { "top" }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView { content.id(Self.top) }
                .onChange(of: query.cards) { if query.pages == 1 { proxy.scrollTo(Self.top, anchor: .top) } }
        }
    }
}
