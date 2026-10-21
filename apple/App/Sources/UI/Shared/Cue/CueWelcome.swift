import CueStore
import SwiftUI

/// Cue 页的首次见面与启用，两端同一张纸（`EmptyState`）：吉祥物、一句它是谁、一句现在能做什么、一个此刻就能做的主动作。
/// 空态与启用合成这一处，同一屏不说两遍；输入框上方不另放一块。
/// - 还没说过话（`intro`）：自我介绍"我是 Cue"，在对话那一块正中。启用了请你直接说，下面接几句能直接说的话（`CueStarters`，点一句放进输入框），
///   没有主按钮。
/// - 说过话、后来停用了：一小张纸排在输入框正上方（"等你"卡之下，离你下一步最近），不画吉祥物、不再自我介绍，只说启用后它接着干活。
/// 没启用时启用是唯一的主动作：选一台 Mac（能运行 Cue 的几台，`CueSettings.hosts`；按钮的样子见 `enableButton`，选不了的写为什么，
/// `CueSettings.Host.selectable`）；菜单里每台下面写能当大脑的几家。在这台 Mac 上启用打开接入面板
/// （`SetupPanel`：先检测、接入这台的 Agent，一家都没装时给装法，同一下启用），别的 Mac 直接启用，没写成的原因就地写在按钮下面（`CueSettingsModel`）。
/// 能不能启用读 `CueGate`：这台还没和 iCloud 对过时只写在等什么、没有按钮（对得久了整张换成"正在从 iCloud 同步"，`EmptyState.waitsForSync`）。
/// 手机上还没有哪台 Mac 写下过自己时，说先到 Mac 上打开 CuePad，主动作是把 Mac 版的下载链接（GitHub Releases，`CueSettings.macDownload`）发出去，隔空投送到 Mac 上最快。
/// 没启用时下面的输入框发出去是记下灵感。Cue 运行在别的 Mac 上不写在这里：Mac 上写在输入框工具排的末尾（`CueComposer`）。
struct CueWelcome: View {
    let intro: Bool
    @Environment(Workspace.self) private var workspace

    var body: some View {
        let cue = workspace.cue
        if cue.canHear {
            EmptyState(mascot: .hello, title: "我是 \(cue.name)", message: "要做什么，直接跟我说，比如：", waitsForSync: true) { CueStarters() }
        } else {
            CueEnable(intro: intro)
        }
    }
}

private struct CueEnable: View {
    let intro: Bool
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @State private var model = CueSettingsModel()

    var body: some View {
        let settings = model.settings ?? .empty
        let hosts = settings.hosts(here: workspace.localHost)
        let name = workspace.cue.name
        Group {
            if intro {
                EmptyState(mascot: .hello, title: "我是 \(name)", message: message(hosts), waitsForSync: true) { steps(settings, hosts) }
            } else {
                // 说过话后停用了：页头已写"已停用"，这里只说启用后怎样与那一步，不再自我介绍
                VStack(spacing: 10) {
                    Text("启用后 \(name) 接着干活").font(Typography.secondary).foregroundStyle(palette.ink2)
                    steps(settings, hosts)
                }
                .multilineTextAlignment(.center)
                .padding(16)
                .frame(maxWidth: .infinity)
                .paper(radius: 20)
                .buttonStyle(ControlButtonStyle(kind: .primary))
            }
        }
        .cueSettings(model)
        .animation(HandOff.quick, value: model.failure)
    }

    private func steps(_ settings: CueSettings, _ hosts: [CueSettings.Host]) -> some View {
        VStack(spacing: 10) {
            action(settings, hosts)
            if let failure = model.failure {
                Text(failure).font(Typography.meta).foregroundStyle(palette.failure)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func message(_ hosts: [CueSettings.Host]) -> String {
        guard !hosts.isEmpty else { return "我在你的 Mac 上干活。在 Mac 上打开 CuePad 就能叫我，这之前想到的先在下面记下" }
        return "启用后说一件想做的事，我来开工，要你拿主意时再找你"
    }

    @ViewBuilder private func action(_ settings: CueSettings, _ hosts: [CueSettings.Host]) -> some View {
        if let why = settings.gate(services).waitingReason {
            HStack(spacing: 8) {
                Spinner(.small)
                Text(why).font(Typography.secondary).foregroundStyle(palette.ink3)
            }
        } else if hosts.isEmpty {
            ShareLink(item: CueSettings.macDownload) { Label("发出 Mac 版的下载链接", icon: .share) }
        } else {
            HStack(spacing: 8) {
                enableButton(hosts)
                if model.enabling != nil { Spinner(.small) }
            }
            .disabled(model.enabling != nil)
        }
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

    /// 一台：一颗直接启用的主按钮（选不了时停用、下面写为什么）。几台：Mac 上主按钮直接在这台启用，别的几台收在旁边一颗"选别的 Mac"的菜单里；
    /// 手机上没有"这台"，主按钮本身就是选哪台的菜单（带下拉箭头）。一颗按钮只做一件事：点了直接启用的不带箭头，带箭头的点开是菜单。
    @ViewBuilder private func enableButton(_ hosts: [CueSettings.Host]) -> some View {
        if let host = hosts.first, hosts.count == 1 || host.isHere {
            VStack(spacing: 6) {
                Button(host.isHere ? "在这台 Mac 上启用" : "在「\(host.name)」上启用") { enable(on: host) }.disabled(!host.selectable)
                if !host.selectable { Text(host.note).font(Typography.meta).foregroundStyle(palette.ink3) }
                if hosts.count > 1 {
                    hostMenu(Array(hosts.dropFirst()), title: "选别的 Mac", surface: ControlSurface(kind: .quiet, compact: true))
                }
            }
        } else {
            hostMenu(hosts, title: "选一台 Mac 启用", surface: ControlSurface(kind: .primary))
        }
    }

    private func hostMenu(_ hosts: [CueSettings.Host], title: String, surface: ControlSurface) -> some View {
        MenuButton(
            sections: [ChoiceMenu.Section(choices: hosts.map { host in
                ChoiceMenu.Choice(title: host.name, subtitle: host.note.isEmpty ? nil : host.note, image: .icon(.mac), disabled: !host.selectable) {
                    enable(on: host)
                }
            })],
            accessibilityLabel: title
        ) {
            HStack(spacing: 6) {
                Text(title)
                Image(.expand).font(.footnote.weight(.semibold))
            }
            .modifier(surface)
        }
    }
}
