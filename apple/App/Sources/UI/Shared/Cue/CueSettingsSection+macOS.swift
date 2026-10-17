#if os(macOS)
import CueStore
import SwiftUI

/// 设置里的"Cue"一节，每项一行 `SettingRow`（同其他各节）：第一行选它住在哪台 Mac（这台排第一，"不启用"是停用），状态写住在哪、用哪个 Agent，
/// 没能写成的原因也写在这里；下面是名字。下一节是允许清单（`CueProfile.allows`）：每类要先问的事一个"所有项目都不用问"的开关，
/// 只管一个项目的那几项各一行、可撤销。读写都经两端同一份 `CueSettingsModel`（手机上是 `CueSettingsScreen`）；
/// 用哪个 Agent、模型与思考强度在 Cue 页的输入框里选（`CueConfigControls`）。
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
        Section("\(shown.profile.name) 不用先问") {
            allowRows(shown)
        }
    }

    @ViewBuilder private func rows(_ settings: CueSettings) -> some View {
        let here = services.hostID
        SettingRow(
            title: settings.profile.name, icon: Image(systemName: "face.smiling"), tone: model.failure == nil ? .calm : .failure,
            busy: model.enabling != nil, status: model.failure.map { Dotted($0) } ?? settings.status(here: here)
        ) {
            Picker("住在哪台 Mac", selection: Binding(get: { settings.profile.activeHost }, set: live)) {
                Text("不启用").tag(String?.none)
                Divider()
                ForEach(settings.hosts(here: here)) { Text($0.name).tag(Optional($0.id)) }
            }
            .labelsHidden().fixedSize()
        }
        SettingRow(title: "名字", icon: Image(systemName: "tag")) {
            TextField("名字", text: $name, prompt: Text(CueProfile.defaultName)).labelsHidden().multilineTextAlignment(.trailing)
                .frame(width: Self.fieldWidth)
                .focused($editing)
                .onSubmit { model.rename(name, services) }
        }
    }

    /// 允许清单：每类一行"所有项目"的开关；只管一个项目的各一行，可撤销。
    @ViewBuilder private func allowRows(_ settings: CueSettings) -> some View {
        ForEach(settings.allowGroups) { group in
            SettingRow(title: group.ask.name, icon: Image(systemName: "checkmark.shield"), status: Dotted(group.all ? "所有项目都不用问" : "先问你")) {
                Toggle("所有项目都不用问", isOn: Binding(get: { group.all }, set: { model.allow(group.everywhere, $0, services) }))
                    .labelsHidden().toggleStyle(.switch)
            }
            ForEach(group.projects, id: \.allow) { item in
                SettingRow(title: "\(item.name)里\(group.ask.name)", icon: Image(systemName: "folder"), status: "不用问") {
                    Button("撤销") { model.allow(item.allow, false, services) }.settingButton()
                }
            }
        }
    }

    private func live(_ host: String?) {
        if let host { model.enable(on: host, services) } else { model.disable(services) }
    }
}

#endif
