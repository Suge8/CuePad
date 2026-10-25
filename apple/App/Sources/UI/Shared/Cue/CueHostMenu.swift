import SwiftUI

/// 选 Cue 在哪台 Mac 上运行的菜单，各入口同一份（Cue 页的启用 `CueWelcome`、手机 Cue 面板、两端设置里那一行 `CueSettingsSection`）：
/// 每台一项，副标题写能当大脑的几家或为什么一家都不能用，选不了的是停用项（`CueSettings.Host.selectable`）。
/// 设置里（`running` 给了）打勾此刻运行的那台，另一组是"不启用"（停用，选它 `pick(nil)`）；启用入口只列几台。
struct CueHostMenu<Label: View>: View {
    let hosts: [CueSettings.Host]
    var running: Running? = nil
    let accessibilityLabel: String
    let pick: (CueSettings.Host?) -> Void
    @ViewBuilder let label: () -> Label

    /// 设置里的那一行：此刻运行在哪台（没启用为 nil）。
    struct Running { let id: String? }

    var body: some View {
        MenuButton(sections: sections, accessibilityLabel: accessibilityLabel, value: value, label: label)
    }

    private var sections: [ChoiceMenu.Section] {
        let machines = ChoiceMenu.Section(choices: hosts.map { host in
            ChoiceMenu.Choice(
                title: host.name, subtitle: host.note.isEmpty ? nil : host.note, image: .icon(.mac),
                checked: running.map { $0.id == host.id }, disabled: !host.selectable
            ) { pick(host) }
        })
        guard let running else { return [machines] }
        return [machines, ChoiceMenu.Section(choices: [ChoiceMenu.Choice(title: CueSettings.off, checked: running.id == nil) { pick(nil) }])]
    }

    private var value: String? {
        running.map { CueSettings.shown($0.id, in: hosts) }
    }
}
