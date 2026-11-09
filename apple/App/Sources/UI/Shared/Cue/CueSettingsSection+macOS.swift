#if os(macOS)
import SwiftUI

struct CueSettingsSection: View {
    @Environment(AppServices.self) private var services
    @State private var model = CueSettingsModel()

    var body: some View {
        let settings = model.settings ?? .empty
        Section {
            CueSwitchRow(model: model, here: services.hostID, blocked: settings.gate(services).waitingReason)
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
