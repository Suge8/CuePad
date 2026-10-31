import SwiftUI

/// 选 Cue 在哪台 Mac 上运行的菜单，各入口同一份（Cue 页的启用 `CueWelcome`、手机 Cue 面板、两端设置里那一行 `CueHostSetting`）：
/// 每台一项，副标题写能用的几家或为什么一家都不能用，选不了的是停用项（`CueSettings.Host.selectable`）。
/// 启用入口只列几台，选了就在那台启用；设置里打勾此刻运行的那台，选了另一台才改。没有"不启用"：停用只经开关（`CueSettingsModel.turn`）。
struct CueHostMenu<Label: View>: View {
    let hosts: [CueSettings.Host]
    let use: Use
    let accessibilityLabel: String
    @ViewBuilder let label: () -> Label

    enum Use {
        /// 启用入口：选了哪台。
        case enable((CueSettings.Host) -> Void)
        /// 设置里那一行（只在开着时有）：此刻运行在哪台，改成哪台。
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

    /// 每台一项；`checked` 是打不打勾（启用入口不打，为 nil）。
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

/// 两端设置里"在哪台 Mac 上运行"那一行的菜单（只在开着时有）：写此刻在哪台、带下拉箭头，改了经 `CueSettingsModel.choose`（改 Mac 先确认）。
/// 启用中不能再选。
struct CueHostSetting: View {
    let running: String
    let hosts: [CueSettings.Host]
    let model: CueSettingsModel
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette

    var body: some View {
        CueHostMenu(hosts: hosts, use: .setting(running: running) { model.choose($0, services) }, accessibilityLabel: CueSettings.hostTitle) {
            HStack(spacing: 4) {
                Text(CueSettings.shown(running, in: hosts)).lineLimit(1)
                Image(.expand).font(.footnote.weight(.semibold))
            }
            .foregroundStyle(palette.ink2)
        }
        .disabled(model.enabling != nil)
    }
}
