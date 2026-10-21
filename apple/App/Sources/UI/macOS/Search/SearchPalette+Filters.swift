#if os(macOS)
import CueStore
import SwiftUI

struct FilterBar: View {
    @Binding var query: PaletteQuery
    let projects: [Project]
    let targets: [SendTarget]
    let total: Int?
    @Environment(\.palette) private var palette

    var body: some View {
        // 筛选在左、可横向滚动（窄面板里不被挤成省略号），结果数常驻右侧
        HStack(spacing: 12) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) { chips }
            }
            if let total { Text(CountCopy.hits(total)).font(Typography.meta.monospacedDigit()).foregroundStyle(palette.ink2).fixedSize().layoutPriority(1) }
        }
    }

    @ViewBuilder private var chips: some View {
        FilterToken(name: "项目", value: projectLabel, on: query.project != nil) {
            Button("全部") { query.project = nil }
            Divider()
            ForEach(projects) { project in Button(project.name) { query.project = project.id } }
        }
        Button { query.withImages.toggle() } label: {
            FilterCapsule(name: "含图片", value: nil, on: query.withImages)
        }
        .buttonStyle(PressStyle())
        FilterToken(name: "Agent", value: sentLabel, on: query.sent != .any) {
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
        FilterToken(name: "时间", value: query.period.label, on: query.period != .any) {
            ForEach(PaletteQuery.Period.allCases, id: \.self) { period in Button(period.label) { query.period = period } }
        }
    }

    private var projectLabel: String {
        query.project.flatMap { id in projects.first { $0.id == id }?.name } ?? "全部"
    }

    private var sentLabel: String {
        switch query.sent {
        case .any: "任意"
        case .never: "没交过"
        case .sent(_, .some(let name)): name
        case .sent(_, nil): "交过"
        }
    }
}

private struct FilterToken<Items: View>: View {
    let name: String
    let value: String
    let on: Bool
    @ViewBuilder let items: () -> Items

    var body: some View {
        Menu { items() } label: { FilterCapsule(name: name, value: value, on: on).menuLabel("\(name)：\(value)") }
            .menuStyle(.button).buttonStyle(PressStyle()).menuIndicator(.hidden).fixedSize()
    }
}

/// 筛选胶囊：生效时填成实心。
private struct FilterCapsule: View {
    let name: String
    let value: String?
    let on: Bool
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 4) {
            Text(name).foregroundStyle(on ? palette.paper : palette.ink2)
            if let value {
                Text(value).fontWeight(.medium)
                Image(.expand).font(.system(size: 8, weight: .bold)).opacity(0.6).accessibilityHidden(true)
            }
        }
        .font(Typography.meta)
        .foregroundStyle(on ? palette.paper : palette.ink)
        .padding(.horizontal, 10).frame(height: 28)
        .background(on ? palette.ink : palette.fill, in: .capsule)
        .contentShape(.capsule)
    }
}
#endif
