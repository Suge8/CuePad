#if os(iOS)
import CueStore
import SwiftUI

/// Cue 页页顶那一排最右的圆钮"在 Mac 上操作"（`CueHeader` 摆它；规则在 `MacRemote`、`Workspace+Remote`）：
/// 点一下连 Mac——只有一台直接连，几台时连上次那台、还没连过先选一台；长按是菜单：连另一台、在 UU 远程里重新选择 Mac。
struct RemoteMacButton: View {
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @State private var macs: [MacAgents]?
    /// 几台 Mac、还没连过时先选的那几台
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

/// 会话菜单（`SessionActions`）里的两项：在这个会话所在的那台 Mac 上操作；这台绑过 UU 远程的电脑时，还能重新选择。
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
