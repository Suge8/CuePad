#if os(iOS)
import SwiftUI

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
                        HStack(spacing: Spacing.glyph) {
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
