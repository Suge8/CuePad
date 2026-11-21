import CueStore
import SwiftUI

struct SearchFilters: View {
    @Binding var query: PaletteQuery

    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    var body: some View {
        let projects = workspace.catalog?.projects ?? []
        menu(String(localized: "类别"), query.kind.label, on: query.kind != .all) {
            ForEach(PaletteQuery.Kind.allCases, id: \.self) { kind in Button(kind.label) { query.kind = kind } }
        }
        menu(String(localized: "项目"), query.projectLabel(in: projects), on: query.project != nil) {
            Button("全部") { query.project = nil }
            Divider()
            ForEach(projects) { project in Button(project.shownName) { query.project = project.id } }
        }
        Button { query.withAttachments.toggle() } label: { chip(String(localized: "含附件"), nil, on: query.withAttachments) }
            .buttonStyle(PressStyle())
            .accessibilityAddTraits(query.withAttachments ? .isSelected : [])
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

struct SearchSuggestions: View {
    @Binding var query: PaletteQuery
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader("建议").padding(.bottom, Spacing.tight)
            row(PaletteQuery.Kind.sessions.label, .session) { query.kind = .sessions }
            row(PaletteQuery.Kind.tasks.label, .task) { query.kind = .tasks }
            row(PaletteQuery.Kind.ideas.label, .idea) { query.kind = .ideas }
            row(String(localized: "含附件"), .attachment) { query.withAttachments = true }
            row(PaletteQuery.Period.week.label, .recent) { query.period = .week }
        }
    }

    private func row(_ title: String, _ icon: Icon, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: Spacing.item) {
                Image(icon).foregroundStyle(palette.ink2).frame(width: Self.mark).readerHidden(true)
                Text(title).font(Typography.body).foregroundStyle(palette.ink)
                Spacer(minLength: 0)
            }
            .frame(minHeight: RowMetrics.height)
            .contentShape(.rect)
        }
        .buttonStyle(.row)
    }

    private static let mark: CGFloat = 20
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
