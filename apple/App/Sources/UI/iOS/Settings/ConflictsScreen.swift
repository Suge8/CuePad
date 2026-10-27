#if os(iOS)
import CueStore
import SwiftUI

/// 冲突副本：同一张卡在两台设备上离线改过，两个版本并排，选一份保留，另一份删除。
struct ConflictsScreen: View {
    @Environment(AppServices.self) private var services
    @State private var choices = SyncChoices()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                if let failure = choices.failure {
                    Label { Text(failure).font(.footnote) } icon: { FailureMark() }
                }
                if services.conflicts.isEmpty {
                    EmptyState(mascot: .clean, title: "没有待处理的冲突")
                        .padding(.top, 60)
                }
                ForEach(services.conflicts, id: \.copy.id) { ConflictPair(conflict: $0, choices: choices) }
            }
            .padding(16)
            .animation(Motion.fade, value: services.conflicts.map(\.copy.id))
        }
        .floatingHeader("两个版本", detail: services.conflicts.isEmpty ? nil : Dotted(String(localized: "\(services.conflicts.count) 处")))
    }
}

private struct ConflictPair: View {
    let conflict: CardConflict
    let choices: SyncChoices
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(conflict.original.title)
                .font(.headline).foregroundStyle(palette.ink)
                .accessibilityAddTraits(.isHeader)
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 12) { versions }
                VStack(spacing: 12) { versions }
            }
        }
    }

    @ViewBuilder private var versions: some View {
        ForEach(conflict.versions, content: version)
    }

    private func version(_ version: ConflictVersion) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(Dotted(version.label, DateLabel.short(version.card.modifiedAt))).font(.caption.weight(.medium)).foregroundStyle(palette.ink3)
            Text(Outgoing.text(of: version.card)).font(.subheadline).foregroundStyle(palette.ink2)
                .lineLimit(12).frame(maxWidth: .infinity, alignment: .leading)
            Button(SyncChoices.keep) { choices.keep(version.keep, of: conflict, services) }
                .buttonStyle(.bordered)
                .disabled(choices.working)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(14)
        .frame(minWidth: 280, maxWidth: .infinity, alignment: .topLeading)
        .paper()
        .accessibilityElement(children: .contain)
    }
}
#endif
