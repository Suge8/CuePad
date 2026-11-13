import SwiftUI

/// 打开时响一声，听得出开的是什么。
struct SoundToggle: View {
    @Environment(AppServices.self) private var services

    var body: some View {
        @Bindable var settings = services.settings
        Toggle(isOn: $settings.sounds) { Label("音效", icon: .audio) }
            .onChange(of: settings.sounds) { settings.play(.check) }
    }
}
