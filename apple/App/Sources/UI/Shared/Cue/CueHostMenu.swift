import SwiftUI

/// 启用入口只列几台，选了就在那台启用；设置里打勾此刻运行的那台，选了另一台才改。没有"不启用"：停用只经开关（`CueSettingsModel.turn`）。
struct CueHostMenu<Label: View>: View {
    let hosts: [CueSettings.Host]
    let use: Use
    let accessibilityLabel: String
    @ViewBuilder let label: () -> Label

    enum Use {
        case enable((CueSettings.Host) -> Void)
        case setting(running: String, change: (CueSettings.Host) -> Void)
    }

    var body: some View {
        MenuButton(sections: sections, accessibilityLabel: .verbatim(accessibilityLabel), value: value, label: label)
    }

    private var sections: [ChoiceMenu.Section] {
        switch use {
        case .enable(let pick):
            return [machines(checked: { _ in nil }, pick: pick)]
        case .setting(let running, let change):
            return [machines(checked: { $0.id == running }) { if $0.id != running { change($0) } }]
        }
    }

    private func machines(checked: (CueSettings.Host) -> Bool?, pick: @escaping (CueSettings.Host) -> Void) -> ChoiceMenu.Section {
        ChoiceMenu.Section(choices: hosts.map { host in
            ChoiceMenu.Choice(
                title: .verbatim(host.name), subtitle: host.note.isEmpty ? nil : .verbatim(host.note), image: .icon(.mac), checked: checked(host), disabled: !host.selectable
            ) { pick(host) }
        })
    }

    private var value: String? {
        guard case .setting(let running, _) = use else { return nil }
        return CueSettings.shown(running, in: hosts)
    }
}

struct CueHostSetting: View {
    let running: String
    let hosts: [CueSettings.Host]
    let model: CueSettingsModel
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette

    var body: some View {
        CueHostMenu(hosts: hosts, use: .setting(running: running) { model.choose($0, services) }, accessibilityLabel: CueSettings.hostTitle) {
            HStack(spacing: Spacing.tight) {
                Text(CueSettings.shown(running, in: hosts)).lineLimit(1)
                Chevron(.expand)
            }
            .foregroundStyle(palette.ink2)
        }
        .disabled(model.enabling != nil)
    }
}
