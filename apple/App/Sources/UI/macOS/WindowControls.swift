#if os(macOS)
import CueStore
import SwiftUI

extension View {
    func keepsPlace(shown: Bool) -> some View {
        opacity(shown ? 1 : 0).allowsHitTesting(shown).accessibilityHidden(!shown)
    }
}

struct SyncAlertSlot: View {
    static func needed(_ services: AppServices) -> Bool {
        services.sync != nil && SyncSummary(services.syncing.state.status).tone != .calm
    }

    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette

    var body: some View {
        if services.sync != nil {
            let summary = SyncSummary(services.syncing.state.status)
            Button { SettingsPane.open(.general) } label: {
                Image(summary.icon).foregroundStyle(palette.color(summary.tone))
            }
            .buttonStyle(ControlButtonStyle(kind: .circular))
            .help([summary.title, summary.detail, String(localized: "点按在设置里处理")].compactMap { $0 }.joined(separator: "\n"))
            .accessibilityLabel(summary.title)
            .keepsPlace(shown: summary.tone != .calm)
        }
    }
}

#endif
