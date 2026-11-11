#if os(iOS)
import CueStore
import SwiftUI

/// 规则在 `MacRemote`、`Workspace+Remote`。
struct RemoteMacButton: View {
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @State private var macs: [MacAgents]?
    @State private var choosing: [MacAgents]?

    var body: some View {
        Menu {
            let macs = macs ?? []
            if macs.count > 1 {
                Section("连这台 Mac") {
                    ForEach(macs, id: \.hostID) { mac in Button(mac.shownName) { Task { await workspace.operate(on: mac.hostID) } } }
                }
                Menu("重新选择 Mac", icon: .renew) {
                    ForEach(macs, id: \.hostID) { mac in Button(mac.shownName) { Task { await workspace.rebindMac(mac.hostID) } } }
                }
            } else if let mac = macs.first {
                Button("重新选择 Mac", icon: .renew) { Task { await workspace.rebindMac(mac.hostID) } }
            }
        } label: {
            Label("在 Mac 上操作", icon: .remoteMac)
        } primaryAction: {
            Task { choosing = await workspace.operateMac() }
        }
        .accessibilityHint("用网易 UU 远程控制 Mac")
        .accessibilityIdentifier("remote-mac")
        .observing(services.store, into: $macs, onError: workspace.fail) { try $0.allMacAgents() }
        .dialog("在哪台 Mac 上操作", isPresented: Binding { choosing != nil } set: { if !$0 { choosing = nil } }, buttons: choices)
    }

    private var choices: [DialogButton] {
        (choosing ?? []).map { mac in
            DialogButton(title: LocalizedStringResource(stringLiteral: mac.shownName)) { Task { await workspace.operate(on: mac.hostID) } }
        } + [DialogButton(title: "取消", role: .cancel) {}]
    }
}

struct RemoteMacActions: View {
    let host: String
    @Environment(Workspace.self) private var workspace

    var body: some View {
        Button("在 Mac 上操作", icon: .remoteMac) { Task { await workspace.operate(on: host) } }
        if workspace.services.settings.remoteDevices[host] != nil {
            Button("重新选择 Mac", icon: .renew) { Task { await workspace.rebindMac(host) } }
        }
    }
}
#endif
