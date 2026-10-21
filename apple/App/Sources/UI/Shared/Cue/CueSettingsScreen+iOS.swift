#if os(iOS)
import CueStore
import SwiftUI

/// 手机上 Cue 的设置（Cue 面板的齿轮与设置页的 Cue 一行推入），按要紧排，与 Mac 设置窗口的 Cue 那一页同一套（`CueSettingsPane`）：
/// 在哪台 Mac 上运行——能运行的几台直接列成一组单选（每台下面写能当大脑的几家，或为什么一家都不能用），选一台就是换到那台并启用，"不启用"是停用；
/// 不用先问的事（允许清单：每类一个开关，开着就是所有项目里都不用问，只管一个项目的那几项各一行、可撤销）；对话里显示不显示工具步骤（`CueStepsSetting`，存本机）；名字。
/// 用哪个 Agent、模型与思考强度在 Cue 面板第一行（`CueConfigControls`），这里不重复。顶栏是它的名字。读写都经两端同一份 `CueSettingsModel`。
struct CueSettingsScreen: View {
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @State private var model = CueSettingsModel()
    @State private var name = ""
    @FocusState private var editing: Bool

    var body: some View {
        let settings = model.settings ?? .empty
        SettingsForm {
            host(settings)
            allows(settings)
            Section {
                Toggle(CueStepsSetting.title, isOn: Bindable(services.settings).showsCueSteps)
            } footer: {
                Text(CueStepsSetting.note)
            }
            Section {
                LabeledContent("名字") {
                    TextField("名字", text: $name, prompt: Text(CueProfile.defaultName))
                        .multilineTextAlignment(.trailing)
                        .focused($editing)
                        .submitLabel(.done)
                        .onSubmit { model.rename(name, services) }
                }
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .floatingHeader(settings.profile.name)
        .onChange(of: editing) { left, _ in
            if left { model.rename(name, services) }
        }
        .onChange(of: settings.profile.name, initial: true) { _, saved in name = saved }
        .cueSettings(model)
    }

    @ViewBuilder private func host(_ settings: CueSettings) -> some View {
        let hosts = settings.hosts(here: nil)
        Section {
            if hosts.isEmpty {
                Label(CueSettings.noHost, icon: .mac).foregroundStyle(palette.ink3)
            } else {
                Picker(CueSettings.hostTitle, selection: Binding(get: { settings.profile.activeHost }, set: { model.run(on: $0, services) })) {
                    Text("不启用").tag(String?.none)
                    ForEach(hosts) { host in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(host.name)
                            Text(host.note).font(.footnote).foregroundStyle(host.usable ? palette.ink3 : palette.failure)
                        }
                        .tag(Optional(host.id))
                    }
                }
                .pickerStyle(.inline).labelsHidden()
                .disabled(model.enabling != nil)
            }
        } header: {
            HStack(spacing: 6) {
                Text(CueSettings.hostTitle)
                if model.enabling != nil { Spinner(.mini) }
            }
        } footer: {
            if let failure = model.failure { Text(failure).foregroundStyle(palette.failure) }
        }
    }

    private func allows(_ settings: CueSettings) -> some View {
        Section {
            ForEach(settings.allowGroups) { group in
                Toggle(group.ask.name, isOn: Binding(get: { group.all }, set: { model.allow(group.everywhere, $0, services) }))
                ForEach(group.projects, id: \.allow) { item in
                    HStack {
                        Label("\(item.name)里\(group.ask.name)", icon: .folder).foregroundStyle(palette.ink2)
                        Spacer(minLength: 8)
                        Button("撤销") { model.allow(item.allow, false, services) }.buttonStyle(.borderless)
                    }
                }
            }
        } header: {
            Text(CueSettings.allowsTitle)
        } footer: {
            Text(CueSettings.allowsNote(settings.profile.name))
        }
    }
}
#endif
