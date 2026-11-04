#if os(iOS)
import SwiftUI

/// 设置页最上面一组（同 Mac 设置窗口通用页那一组）：第一行是 Cue 本人与它的开关（`CueSwitchRow`：头像、就地改的名字、开关，Cue 唯一的停用入口），
/// 开着时下面一行是在哪台 Mac 上运行（各入口同一份菜单 `CueHostSetting`：每台写能用的几家或为什么不能用，启用中转圈），关着时这一行不在。
/// 开关停用、名字下面写为什么的两种：还没和 iCloud 对过（在等什么），还没有哪台 Mac 写下过自己（先去 Mac 上打开；同步不通时写同步那一行的标题，`CueSettings.noHost`）。
/// 正在别的 Mac 上运行时改过来先确认（`CueGate`）。没能写成的原因写在名字下面。
/// 用哪个 Agent、模型与思考强度在 Cue 面板第一行（`CueConfigControls`），这里不重复。读写都经各入口同一份 `CueSettingsModel`。
struct CueSettingsSection: View {
    @Environment(AppServices.self) private var services
    @State private var model = CueSettingsModel()

    var body: some View {
        let settings = model.settings ?? .empty
        let hosts = settings.hosts(here: nil)
        Section {
            CueSwitchRow(model: model, here: nil, blocked: settings.gate(services).waitingReason ?? (hosts.isEmpty ? CueSettings.noHost(services) : nil))
                // 读设置与改 Mac 前的确认挂在一直在的这一行上
                .cueSettings(model)
            if let running = settings.profile.activeHost, model.isOn {
                LabeledContent {
                    CueHostSetting(running: running, hosts: hosts, model: model)
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
                .transition(.opacity)
            }
        }
        .animation(Motion.fade, value: model.isOn)
    }
}
#endif
