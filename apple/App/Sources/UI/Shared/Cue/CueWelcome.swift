import CueStore
import SwiftUI

/// Cue 页的首次见面与启用，两端同一张纸（`EmptyState`）：吉祥物、一句它是谁、一句现在能做什么、一个此刻就能做的主动作。
/// 空态与启用合成这一处，同一屏不说两遍；输入框上方不另放一块。
/// - 还没说过话（`intro`）：自我介绍"我是 Cue"，在对话那一块正中。启用了只请你在下面直接说，没有按钮。
/// - 说过话、后来停用了：排在对话末尾，不再自我介绍，只请你启用让它接着干活。
/// 没启用时主动作是启用：选一台 Mac（能运行 Cue 的几台，`CueSettings.hosts`）——一台就是一颗"在那台上启用"的主按钮；几台是点开选哪台的菜单
/// （`MenuButton`，每台下面写能当大脑的几家或为什么不能用），Mac 上点按是在这台运行、长按选别的。在这台 Mac 上启用打开接入面板
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
            EmptyState(mascot: .hello, title: "我是 \(cue.name)", message: "要做什么，直接在下面跟我说", waitsForSync: true)
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
        EmptyState(
            mascot: .hello, title: intro ? "我是 \(name)" : "启用 \(name)，接着干活", message: intro ? message(hosts) : nil, waitsForSync: intro
        ) {
            VStack(spacing: 10) {
                action(settings, hosts)
                if let failure = model.failure {
                    Text(failure).font(Typography.meta).foregroundStyle(palette.failure)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .cueSettings(model)
        .animation(Motion.quick, value: model.failure)
    }

    private func message(_ hosts: [CueSettings.Host]) -> String {
        guard !hosts.isEmpty else { return "我在你的 Mac 上干活。在 Mac 上打开 CuePad 就能叫我，这之前想到的先在下面记下" }
        let home = workspace.catalog?.project(Project.defaultID)?.name ?? ""
        return "启用后说一件想做的事，我放进「\(home)」项目里开工，只在要你拿主意时找你"
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

    @ViewBuilder private func enableButton(_ hosts: [CueSettings.Host]) -> some View {
        let here = workspace.localHost
        if hosts.count == 1, let host = hosts.first {
            Button(host.id == here ? "在这台 Mac 上启用" : "在「\(host.name)」上启用") { enable(on: host) }
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
}
