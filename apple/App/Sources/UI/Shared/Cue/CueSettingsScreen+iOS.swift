#if os(iOS)
import SwiftUI

/// 手机上 Cue 的设置（Cue 面板的齿轮与设置页的 Cue 一行推入），按要紧排，与 Mac 设置窗口的 Cue 那一页同一套（`CueSettingsPane`）：
/// 在哪台 Mac 上运行——能运行的几台直接列成一组单选（每台下面写能当大脑的几家，或为什么一家都不能用），选一台就是改在那台运行并启用，"不启用"是停用
/// （能不能选读 `CueGate`：还没和 iCloud 对过时写在等什么、选不了，正在别的 Mac 上运行时改过来先确认）；
/// 不用先问的事（允许清单：每类一个开关，开着就是所有项目里都不用问，只管一个项目的那几项各一行、可撤销）；名字。
/// 用哪个 Agent、模型与思考强度在 Cue 面板第一行（`CueConfigControls`），这里不重复。顶栏是它的名字。读写都经两端同一份 `CueSettingsModel`。
struct CueSettingsScreen: View {
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @State private var model = CueSettingsModel()

    var body: some View {
        let settings = model.settings ?? .empty
        SettingsForm {
            host(settings)
            allows(settings)
            Section {
                LabeledContent("名字") { CueNameField(model: model).submitLabel(.done) }
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .floatingHeader(settings.profile.name)
        .cueSettings(model)
    }

    @ViewBuilder private func host(_ settings: CueSettings) -> some View {
        let hosts = settings.hosts(here: nil)
        let waiting = settings.gate(services).waitingReason
        Section {
            if let waiting {
                Label(waiting, icon: .syncing).foregroundStyle(palette.ink3)
            } else if hosts.isEmpty {
                Label(CueSettings.noHost, icon: .mac).foregroundStyle(palette.ink3)
            } else {
                Picker(CueSettings.hostTitle, selection: Binding(
                    get: { settings.profile.activeHost },
                    set: { id in model.choose(hosts.first { $0.id == id }, services) }
                )) {
                    Text("不启用").tag(String?.none)
                    ForEach(hosts) { host in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(host.name)
                            Text(host.note).font(.footnote).foregroundStyle(host.usable ? palette.ink3 : palette.failure)
                        }
                        .tag(Optional(host.id))
                        // 一家都不能当大脑的那台列着、写为什么，选不了（同 Cue 页启用菜单的停用项）
                        .disabled(!host.selectable)
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
