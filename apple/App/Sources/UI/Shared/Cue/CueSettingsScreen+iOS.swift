#if os(iOS)
import CueStore
import SwiftUI

/// 手机上 Cue 的设置（从 Cue 面板的"设置"推入）：名字；住在哪台 Mac——Cue 能住的几台直接列成一组单选（每台下面写能当大脑的几家，
/// 或为什么一家都不能用），选一台就是住过去并启用，"不启用"是停用；允许清单（每类要先问的事一个"所有项目都不用问"的开关，
/// 只管一个项目的那几项各一行、可撤销）；对话里显示不显示工具步骤（`CueStepsSetting`，存本机）。顶栏是它的名字与现状（住在哪、用哪家；没写成时是原因）。
/// 读写都经两端同一份 `CueSettingsModel`（Mac 上是设置窗口里的 `CueSettingsSection`）；大脑在 Cue 面板第一行选。
struct CueSettingsScreen: View {
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var model = CueSettingsModel()
    @State private var name = ""
    @FocusState private var editing: Bool

    /// 宽屏上表单限宽居中（同 `SettingsScreen`）。
    private static let readableWidth: CGFloat = 640

    var body: some View {
        let settings = model.settings ?? .empty
        Form {
            Group {
                Section {
                    TextField("名字", text: $name, prompt: Text(CueProfile.defaultName))
                        .focused($editing)
                        .submitLabel(.done)
                        .onSubmit { model.rename(name, services) }
                } header: {
                    Text("名字")
                }
                home(settings)
                Section {
                    Toggle(CueStepsSetting.title, isOn: Bindable(services.settings).showsCueSteps)
                } footer: {
                    Text(CueStepsSetting.note)
                }
                allows(settings)
            }
            .listRowBackground(palette.paper)
        }
        .frame(maxWidth: sizeClass == .regular ? Self.readableWidth : .infinity)
        .frame(maxWidth: .infinity)
        .scrollContentBackground(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .floatingHeader(settings.profile.name, detail: model.failure.map { Dotted($0) } ?? settings.status(here: nil))
        .onChange(of: editing) { left, _ in
            if left { model.rename(name, services) }
        }
        .onChange(of: settings.profile.name, initial: true) { _, saved in name = saved }
        .cueSettings(model)
    }

    @ViewBuilder private func home(_ settings: CueSettings) -> some View {
        let hosts = settings.hosts(here: nil)
        Section {
            if hosts.isEmpty {
                Label("先到 Mac 上打开 CuePad，它会出现在这里", icon: .mac).foregroundStyle(palette.ink3)
            } else {
                Picker("住在哪台 Mac", selection: Binding(get: { settings.profile.activeHost }, set: { model.live(on: $0, services) })) {
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
                Text("住在哪台 Mac")
                if model.enabling != nil { Spinner(.mini) }
            }
        } footer: {
            if let failure = model.failure { Text(failure).foregroundStyle(palette.failure) }
        }
    }

    private func allows(_ settings: CueSettings) -> some View {
        Section("\(settings.profile.name) 不用先问") {
            ForEach(settings.allowGroups) { group in
                Toggle(isOn: Binding(get: { group.all }, set: { model.allow(group.everywhere, $0, services) })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(group.ask.name)
                        Text(group.all ? "所有项目都不用问" : "先问你").font(.footnote).foregroundStyle(palette.ink3)
                    }
                }
                ForEach(group.projects, id: \.allow) { item in
                    HStack {
                        Label("\(item.name)里\(group.ask.name)", icon: .folder).foregroundStyle(palette.ink2)
                        Spacer(minLength: 8)
                        Button("撤销") { model.allow(item.allow, false, services) }.buttonStyle(.borderless)
                    }
                }
            }
        }
    }
}
#endif
