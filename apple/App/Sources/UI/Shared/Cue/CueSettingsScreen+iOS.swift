#if os(iOS)
import CueStore
import SwiftUI

/// 手机上 Cue 的设置（从 Cue 面板的"设置"推入）：名字；在哪台 Mac 上运行——能运行的几台直接列成一组单选（每台下面写能当大脑的几家，
/// 或为什么一家都不能用），选一台就是换到那台并启用，"不启用"是停用；选了哪台后是用哪个 Agent、模型与思考强度（`CueConfigControls`，
/// 与新会话同一排，Cue 面板第一行也是它）；对话里显示不显示工具步骤（`CueStepsSetting`，存本机）；不用先问的事（允许清单：每类要先问的事一个"所有项目都不用问"的开关，只管一个项目的那几项各一行、可撤销）。
/// 顶栏是它的名字与现状（在哪台上运行、用哪家；没写成时是原因）。读写都经两端同一份 `CueSettingsModel`（Mac 上是设置窗口里的 `CueSettingsSection`）。
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
                host(settings)
                if settings.profile.hostID != nil {
                    Section("用哪个 Agent 与模型") { CueConfigControls(fail: model.fail) }
                }
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

    @ViewBuilder private func host(_ settings: CueSettings) -> some View {
        let hosts = settings.hosts(here: nil)
        Section {
            if hosts.isEmpty {
                Label("先到 Mac 上打开 CuePad，它会出现在这里", icon: .mac).foregroundStyle(palette.ink3)
            } else {
                Picker(Self.hostTitle, selection: Binding(get: { settings.profile.activeHost }, set: { model.run(on: $0, services) })) {
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
                Text(Self.hostTitle)
                if model.enabling != nil { Spinner(.mini) }
            }
        } footer: {
            if let failure = model.failure { Text(failure).foregroundStyle(palette.failure) }
        }
    }

    private static let hostTitle = "在哪台 Mac 上运行"

    private func allows(_ settings: CueSettings) -> some View {
        Section {
            ForEach(settings.allowGroups) { group in
                Toggle(isOn: Binding(get: { group.all }, set: { model.allow(group.everywhere, $0, services) })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(group.ask.name)
                        Text(group.all ? CueSettings.allowedEverywhere : CueSettings.asksFirst).font(.footnote).foregroundStyle(palette.ink3)
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
        } header: {
            Text(CueSettings.allowsTitle)
        } footer: {
            Text(CueSettings.allowsNote(settings.profile.name))
        }
    }
}
#endif
