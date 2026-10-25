#if os(iOS)
import SwiftUI

/// 设置页最上面一组：组名是 Cue 的名字，两行——名字，与在哪台 Mac 上运行（同 Mac 设置窗口通用页那一组，`CueSettingsSection`）。
/// 在哪台运行用各入口同一份菜单（`CueHostMenu`：每台写能当大脑的几家或为什么不能用，"不启用"是停用）；启用中转圈，没能写成的原因写在组下面；
/// 能不能选读 `CueGate`：还没和 iCloud 对过时写在等什么、选不了，正在别的 Mac 上运行时改过来先确认；还没有哪台 Mac 写下过自己时写先去 Mac 上打开。
/// 用哪个 Agent、模型与思考强度在 Cue 面板第一行（`CueConfigControls`），这里不重复。读写都经各入口同一份 `CueSettingsModel`。
struct CueSettingsSection: View {
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @State private var model = CueSettingsModel()

    var body: some View {
        let settings = model.settings ?? .empty
        Section {
            LabeledContent {
                CueNameField(model: model).submitLabel(.done)
            } label: {
                Label("名字", icon: .name)
            }
            LabeledContent {
                host(settings)
            } label: {
                Label {
                    HStack(spacing: 6) {
                        Text(CueSettings.hostTitle)
                        if model.enabling != nil { Spinner(.mini) }
                    }
                } icon: {
                    Image(.mac)
                }
            }
            // 改 Mac 前的确认从这一行长出
            .cueSettings(model)
        } header: {
            Text(settings.profile.name)
        } footer: {
            if let failure = model.failure { Text(failure).foregroundStyle(palette.failure) }
        }
    }

    @ViewBuilder private func host(_ settings: CueSettings) -> some View {
        let hosts = settings.hosts(here: nil)
        let running = settings.profile.activeHost
        if let waiting = settings.gate(services).waitingReason {
            Text(waiting).foregroundStyle(palette.ink3)
        } else if hosts.isEmpty {
            Text(CueSettings.noHost).foregroundStyle(palette.ink3)
        } else {
            CueHostMenu(hosts: hosts, running: .init(id: running), accessibilityLabel: CueSettings.hostTitle) { host in
                if host?.id != running { model.choose(host, services) }
            } label: {
                HStack(spacing: 4) {
                    Text(CueSettings.shown(running, in: hosts)).lineLimit(1)
                    Image(.expand).font(.footnote.weight(.semibold))
                }
                .foregroundStyle(palette.ink2)
            }
            .disabled(model.enabling != nil)
        }
    }
}
#endif
