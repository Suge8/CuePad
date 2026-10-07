#if os(iOS)
import CueStore
import SwiftUI

/// 冲突副本：同一张卡在两台设备上离线改过，两个版本并排，选一份保留，另一份删除。
struct ConflictsScreen: View {
    @Environment(AppServices.self) private var services

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                if services.conflicts.isEmpty {
                    ContentUnavailableView("没有待处理的冲突", systemImage: "checkmark.circle")
                        .padding(.top, 60)
                }
                ForEach(services.conflicts, id: \.copy.id) { ConflictPair(conflict: $0) }
            }
            .padding(16)
            .animation(Motion.quick, value: services.conflicts.map(\.copy.id))
        }
        .navigationTitle("两个版本")
    }
}

private struct ConflictPair: View {
    let conflict: CardConflict
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(CardText(conflict.original.body).title.nonEmpty ?? "空白卡片")
                .font(.headline).foregroundStyle(palette.ink)
                .accessibilityAddTraits(.isHeader)
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 12) { versions }
                VStack(spacing: 12) { versions }
            }
        }
    }

    @ViewBuilder private var versions: some View {
        version("原版本", conflict.original, keep: .original)
        version("另一台设备的版本", conflict.copy, keep: .copy)
    }

    private func version(_ label: String, _ card: Card, keep choice: ConflictChoice) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(label) · \(DateLabel.short(card.modifiedAt))").font(.caption.weight(.medium)).foregroundStyle(palette.ink3)
            Text(Outgoing.text(of: card)).font(.subheadline).foregroundStyle(palette.ink2)
                .lineLimit(12).frame(maxWidth: .infinity, alignment: .leading)
            Button("保留这一份") { keep(choice) }
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(14)
        .frame(minWidth: 280, maxWidth: .infinity, alignment: .topLeading)
        .paper(radius: 14)
        .accessibilityElement(children: .contain)
    }

    private func keep(_ choice: ConflictChoice) {
        let copy = conflict.copy.id
        workspace.attempt {
            try await services.resolveConflict(copy: copy, keep: choice)
            workspace.say("已保留所选版本")
        }
    }
}
#endif
