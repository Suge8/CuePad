#if os(iOS)
import CueStore
import SwiftUI

struct LibrarySource: View {
    let library: AgentLibrary
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @State private var mac: MacAgents?

    var body: some View {
        Text(Dotted(mac?.shownName, String(localized: "\(DateLabel.short(library.modifiedAt))报来")))
            .font(Typography.meta.monospacedDigit()).foregroundStyle(palette.ink3)
            .frame(maxWidth: .infinity)
            .observing(services.store, id: library.hostID, into: $mac, onError: workspace.fail) { [host = library.hostID] in try $0.macAgents(on: host) }
    }
}
#endif
