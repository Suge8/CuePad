#if os(macOS)
import SwiftUI

/// 设置窗口通用那一页最上面一组（同手机设置）：第一行是 Cue 本人与它的开关（`CueSwitchRow`：头像、就地改的名字、开关，Cue 唯一的停用入口），
/// 开着时下面一行是在哪台 Mac 上运行（`SettingRow`，各入口同一份菜单 `CueHostSetting`：这台排第一，每台写能用的几家或为什么不能用），关着时这一行不在。
/// 没能写成的原因写在名字下面；还没和 iCloud 对过时开关停用、名字下面写在等什么；正在别的 Mac 上运行时改过来先确认（`CueGate`）。
/// 用哪个 Agent、模型与思考强度在 Cue 页输入框上（`CueConfigControls`），这里不重复。读写都经各入口同一份 `CueSettingsModel`。
struct CueSettingsSection: View {
    @Environment(AppServices.self) private var services
    @State private var model = CueSettingsModel()

    var body: some View {
        let settings = model.settings ?? .empty
        Section {
            CueSwitchRow(model: model, here: services.hostID, blocked: settings.gate(services).waitingReason)
                // 读设置与改 Mac 前的确认挂在一直在的这一行上
                .cueSettings(model)
            if let running = settings.profile.activeHost, model.isOn {
                SettingRow(title: .verbatim(CueSettings.hostTitle), icon: Image(.mac), busy: model.enabling != nil) {
                    CueHostSetting(running: running, hosts: settings.hosts(here: services.hostID), model: model)
                }
                .transition(.opacity)
            }
        }
        .animation(Motion.fade, value: model.isOn)
    }
}
#endif
