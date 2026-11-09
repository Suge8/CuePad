import CueStore
import SwiftUI

struct LibraryHelp: View {
    let library: AgentLibrary
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @State private var mac: MacAgents?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.group) {
            Text(Self.direct).foregroundStyle(palette.ink)
            Text("行末划掉的标志：那一家读不到这一份").foregroundStyle(palette.ink)
            Text(Dotted(mac?.shownName, String(localized: "\(DateLabel.short(library.modifiedAt))报来"))).font(Typography.meta.monospacedDigit()).foregroundStyle(palette.ink3)
        }
        .font(Typography.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .padding(Spacing.block)
        .observing(services.store, id: library.hostID, into: $mac, onError: workspace.fail) { [host = library.hostID] in try $0.macAgents(on: host) }
    }

    #if os(macOS)
    private static let direct: LocalizedStringResource = "CuePad 直接改这台 Mac 上的这些文件，不经过 Agent"
    #else
    private static let direct: LocalizedStringResource = "那台 Mac 上的 CuePad 直接改这些文件，不经过 Agent"
    #endif
}
