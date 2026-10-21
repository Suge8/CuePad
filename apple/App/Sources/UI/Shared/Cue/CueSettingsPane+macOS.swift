#if os(macOS)
import CueStore
import SwiftUI

/// 设置窗口 Cue 那一页，每项一行 `SettingRow`（同其他各页），按要紧排：在哪台 Mac 上运行（这台排第一，"不启用"是停用；没能写成的原因写在这一行；
/// 能不能选读 `CueGate`：还没和 iCloud 对过时写在等什么、选不了，正在别的 Mac 上运行时换过去先确认）；
/// 不用先问的事（允许清单 `CueProfile.allows`：每类一个开关，只管一个项目的那几项各一行、可撤销）；对话里显示不显示工具步骤（`CueStepsSetting`，存本机）与名字。
/// 用哪个 Agent、模型与思考强度在 Cue 页输入框上（`CueConfigControls`），这里不重复。读写都经两端同一份 `CueSettingsModel`（手机上是 `CueSettingsScreen`）。
struct CueSettingsPane: View {
    @Environment(AppServices.self) private var services
    @State private var model = CueSettingsModel()

    /// 名字输入框的宽：不撑满一行。
    private static let fieldWidth: CGFloat = 200

    var body: some View {
        // 读库挂在一直在的行上（不排行时 Section 是空的，读库永远不开始）
        let shown = model.settings ?? .empty
        Section {
            host(shown)
        }
        .cueSettings(model)
        Section {
            allowRows(shown)
        } header: {
            Text(CueSettings.allowsTitle)
        } footer: {
            Text(CueSettings.allowsNote(shown.profile.name))
        }
        Section {
            SettingRow(title: CueStepsSetting.title, icon: Image(.tool), help: CueStepsSetting.note) {
                Toggle(CueStepsSetting.title, isOn: Bindable(services.settings).showsCueSteps).labelsHidden().toggleStyle(.switch)
            }
            SettingRow(title: "名字", icon: Image(.name)) {
                CueNameField(model: model).labelsHidden().frame(width: Self.fieldWidth)
            }
        }
    }

    private func host(_ settings: CueSettings) -> some View {
        let hosts = settings.hosts(here: services.hostID)
        let waiting = settings.gate(services).waitingReason
        return SettingRow(
            title: CueSettings.hostTitle, icon: Image(.mac), tone: model.failure == nil ? .calm : .failure,
            busy: model.enabling != nil || waiting != nil, status: (model.failure ?? waiting).map { Dotted($0) }
        ) {
            Picker(CueSettings.hostTitle, selection: Binding(
                get: { settings.profile.activeHost },
                set: { id in model.choose(hosts.first { $0.id == id }, services) }
            )) {
                Text("不启用").tag(String?.none)
                Divider()
                ForEach(hosts) { Text($0.name).tag(Optional($0.id)) }
            }
            .labelsHidden().fixedSize()
            .disabled(waiting != nil)
        }
    }

    /// 允许清单：每类一个开关（开着就是所有项目里都不用问）；只管一个项目的各一行，可撤销。
    @ViewBuilder private func allowRows(_ settings: CueSettings) -> some View {
        ForEach(settings.allowGroups) { group in
            SettingRow(title: group.ask.name, icon: Image(.autoApprove)) {
                Toggle(group.ask.name, isOn: Binding(get: { group.all }, set: { model.allow(group.everywhere, $0, services) }))
                    .labelsHidden().toggleStyle(.switch)
            }
            ForEach(group.projects, id: \.allow) { item in
                SettingRow(title: "\(item.name)里\(group.ask.name)", icon: Image(.folder)) {
                    Button("撤销") { model.allow(item.allow, false, services) }.settingButton()
                }
            }
        }
    }
}

#endif
