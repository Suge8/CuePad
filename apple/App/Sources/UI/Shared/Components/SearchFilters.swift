import CueStore
import SwiftUI

/// 搜索的四个筛选（项目、含图片、发给过哪个 Agent、时间）：有哪几项、菜单里列什么、生效时写什么两端同一份，胶囊的样子由调用方给（`chip`）。
/// 项目列表读 `Workspace.catalog`，目标读这一页结果（`CardMatches.targets`）。菜单与按钮的样式跟外面的环境（Mac 在外面套 `PressStyle`）。
struct SearchFilters<Chip: View>: View {
    @Binding var query: PaletteQuery
    let targets: [SendTarget]
    /// 名字、取值（开关没有取值，也没有菜单）、生效没有。
    @ViewBuilder let chip: (_ name: String, _ value: String?, _ on: Bool) -> Chip

    @Environment(Workspace.self) private var workspace

    var body: some View {
        let projects = workspace.catalog?.projects ?? []
        menu("项目", query.projectLabel(in: projects), on: query.project != nil) {
            Button("全部") { query.project = nil }
            Divider()
            ForEach(projects) { project in Button(project.name) { query.project = project.id } }
        }
        Button { query.withImages.toggle() } label: { chip("含图片", nil, query.withImages) }
            .accessibilityAddTraits(query.withImages ? .isSelected : [])
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
        menu("时间", query.period.label, on: query.period != .any) {
            ForEach(PaletteQuery.Period.allCases, id: \.self) { period in Button(period.label) { query.period = period } }
        }
    }

    private func menu(_ name: String, _ value: String, on: Bool, @ViewBuilder items: () -> some View) -> some View {
        Menu { items() } label: { chip(name, value, on).menuLabel("\(name)：\(value)") }
    }
}
