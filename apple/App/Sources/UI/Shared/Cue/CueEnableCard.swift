import SwiftUI

/// 还没启用时 Cue 页输入框上方的那一块，两端同一个：只放启用这一步，启用后怎么用由 Cue 页空态那一句说（同一屏不说两遍）。选一台 Mac 启用（能运行 Cue 的几台，`CueSettings.hosts`）——
/// 一台就是一颗"在那台上启用"的主按钮；几台是点开选哪台的菜单（`MenuButton`，每台下面写能当大脑的几家或为什么不能用），
/// Mac 上点按是在这台运行、长按选别的。在这台 Mac 上启用打开接入面板（`SetupPanel`：先检测、接入这台的 Agent，一家都没装时给装法，
/// 同一下启用），别的 Mac 直接启用，没写成的原因就地写在下面（`CueSettingsModel`）。能不能启用读 `CueGate`：这台还没和 iCloud 对过时
/// 只写在等什么、没有按钮；对过发现 Cue 已在别的 Mac 上运行（Mac 上，`CueNow.elsewhere`）时卡还在，改写它在哪台。
/// 手机上还没有哪台 Mac 写下过自己时，说先到 Mac 上打开 CuePad。没启用时输入框发出去是记下灵感。
struct CueEnableCard: View {
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @State private var model = CueSettingsModel()

    var body: some View {
        let settings = model.settings ?? .empty
        let hosts = settings.hosts(here: workspace.localHost)
        VStack(alignment: .leading, spacing: 10) {
            if let elsewhere = workspace.cue.now.elsewhere {
                Label("\(workspace.cue.name) \(elsewhere)", icon: .mac)
                    .font(Typography.secondary).foregroundStyle(palette.ink2)
            } else if let why = settings.gate(services).waitingReason {
                HStack(spacing: 8) {
                    Spinner(.small)
                    Text(why).font(Typography.secondary).foregroundStyle(palette.ink3)
                }
            } else if hosts.isEmpty {
                Label(CueSettings.noHost, icon: .mac)
                    .font(Typography.secondary).foregroundStyle(palette.ink3)
            } else {
                HStack(spacing: 8) {
                    enableButton(hosts)
                    if model.enabling != nil { Spinner(.small) }
                }
                .disabled(model.enabling != nil)
            }
            if let failure = model.failure {
                Text(failure).font(Typography.meta).foregroundStyle(palette.failure)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glass(in: .rect(cornerRadius: ComposerMetrics.radius, style: .continuous))
        .cueSettings(model)
        .animation(Motion.quick, value: model.failure)
    }

    private func enable(on host: CueSettings.Host) {
        #if os(macOS)
        guard host.id != workspace.localHost else {
            workspace.showsSetup = true
            return
        }
        #endif
        model.choose(host, services)
    }

    @ViewBuilder private func enableButton(_ hosts: [CueSettings.Host]) -> some View {
        let here = workspace.localHost
        if hosts.count == 1, let host = hosts.first {
            Button(title(host)) { enable(on: host) }
                .buttonStyle(ControlButtonStyle(kind: .primary))
        } else {
            MenuButton(
                sections: [ChoiceMenu.Section(choices: hosts.map { host in
                    ChoiceMenu.Choice(title: host.name, subtitle: host.note.isEmpty ? nil : host.note, image: .icon(.mac)) {
                        enable(on: host)
                    }
                })],
                primary: here == nil ? nil : { if let first = hosts.first { enable(on: first) } },
                accessibilityLabel: here == nil ? "选一台 Mac 启用" : "在这台 Mac 上启用", hint: here == nil ? nil : "长按选别的 Mac"
            ) {
                HStack(spacing: 6) {
                    Text(here == nil ? "选一台 Mac 启用" : "在这台 Mac 上启用")
                    Image(.expand).font(.footnote.weight(.semibold))
                }
                .modifier(ControlSurface(kind: .primary))
            }
        }
    }

    private func title(_ host: CueSettings.Host) -> String {
        host.id == workspace.localHost ? "在这台 Mac 上启用" : "在「\(host.name)」上启用"
    }
}
