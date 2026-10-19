#if os(macOS)
import CueStore
import SwiftUI

/// 设置里的"Cue"一节，每项一行 `SettingRow`（同其他各节）：第一行选它在哪台 Mac 上运行（这台排第一，"不启用"是停用），状态写在哪台运行、
/// 用哪个 Agent，没能写成的原因也写在这里；选了哪台后是用哪个 Agent、模型与思考强度（`CueConfigControls`，与新会话同一排，Cue 页输入框里也是它）；
/// 下面是名字与对话里显示不显示工具步骤（`CueStepsSetting`，存本机）。下一节是不用先问的事（允许清单 `CueProfile.allows`）：每类要先问的事一个"所有项目都不用问"的开关，只管一个项目的那几项各一行、可撤销。
/// 读写都经两端同一份 `CueSettingsModel`（手机上是 `CueSettingsScreen`）。
struct CueSettingsSection: View {
    @Environment(AppServices.self) private var services
    @State private var model = CueSettingsModel()
    @State private var name = ""
    /// 名字在回车或离开输入框时写入。
    @FocusState private var editing: Bool

    /// 名字输入框的宽：不撑满一行。
    private static let fieldWidth: CGFloat = 200

    var body: some View {
        // 读库挂在一直在的行上（不排行时 Section 是空的，读库永远不开始）
        let shown = model.settings ?? .empty
        Section {
            rows(shown)
        }
        .onChange(of: editing) { left, _ in
            if left { model.rename(name, services) }
        }
        .onChange(of: shown.profile.name, initial: true) { _, saved in name = saved }
        .cueSettings(model)
        Section {
            allowRows(shown)
        } header: {
            Text(CueSettings.allowsTitle)
        } footer: {
            Text(CueSettings.allowsNote(shown.profile.name))
        }
    }

    @ViewBuilder private func rows(_ settings: CueSettings) -> some View {
        let here = services.hostID
        SettingRow(
            title: settings.profile.name, icon: Image(.profile), tone: model.failure == nil ? .calm : .failure,
            busy: model.enabling != nil, status: model.failure.map { Dotted($0) } ?? settings.status(here: here)
        ) {
            Picker("在哪台 Mac 上运行", selection: Binding(get: { settings.profile.activeHost }, set: { model.run(on: $0, services) })) {
                Text("不启用").tag(String?.none)
                Divider()
                ForEach(settings.hosts(here: here)) { Text($0.name).tag(Optional($0.id)) }
            }
            .labelsHidden().fixedSize()
        }
        if settings.profile.hostID != nil {
            SettingRow(title: "Agent 与模型", icon: Image(.agent)) { CueConfigControls(fail: model.fail).fixedSize() }
        }
        SettingRow(title: "名字", icon: Image(.name)) {
            TextField("名字", text: $name, prompt: Text(CueProfile.defaultName)).labelsHidden().multilineTextAlignment(.trailing)
                .frame(width: Self.fieldWidth)
                .focused($editing)
                .onSubmit { model.rename(name, services) }
        }
        SettingRow(title: CueStepsSetting.title, icon: Image(.tool), status: Dotted(CueStepsSetting.note)) {
            Toggle(CueStepsSetting.title, isOn: Bindable(services.settings).showsCueSteps).labelsHidden().toggleStyle(.switch)
        }
    }

    /// 允许清单：每类一行"所有项目"的开关；只管一个项目的各一行，可撤销。
    @ViewBuilder private func allowRows(_ settings: CueSettings) -> some View {
        ForEach(settings.allowGroups) { group in
            SettingRow(
                title: group.ask.name, icon: Image(.autoApprove), status: Dotted(group.all ? CueSettings.allowedEverywhere : CueSettings.asksFirst)
            ) {
                Toggle(CueSettings.allowedEverywhere, isOn: Binding(get: { group.all }, set: { model.allow(group.everywhere, $0, services) }))
                    .labelsHidden().toggleStyle(.switch)
            }
            ForEach(group.projects, id: \.allow) { item in
                SettingRow(title: "\(item.name)里\(group.ask.name)", icon: Image(.folder), status: "不用问") {
                    Button("撤销") { model.allow(item.allow, false, services) }.settingButton()
                }
            }
        }
    }
}

#endif
