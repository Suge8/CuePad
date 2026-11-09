import CueStore
import SwiftUI

/// 空态与启用合成这一处，同一屏不说两遍；输入框上方不另放一块。
/// 启用前后是同一张纸（同一个 `EmptyState`）：同步对完、Cue 在别处已启用时只换纸里的字与动作，吉祥物的出场不重播、不先空一下。
/// 说过话后停用的那张小纸只在没启用时出现（`CuePage`）。
struct CueWelcome: View {
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
                let hears = workspace.cue.canHear
                EmptyState(
                    mascot: .hello, title: "我是 \(name)", message: hears ? "要做什么，直接跟我说，比如：" : .verbatim(message(settings)), waitsForSync: true
                ) {
                    if hears { CueStarters() } else { steps(settings, hosts) }
                }
            } else {
                // 说过话后停用了：页头已写"已停用"，这里只说启用后怎样与那一步，不再自我介绍
                VStack(spacing: Spacing.item) {
                    Text("启用后 \(name) 接着干活").font(Typography.secondary).foregroundStyle(palette.ink2)
                    steps(settings, hosts)
                }
                .multilineTextAlignment(.center)
                .padding(Spacing.block)
                .frame(maxWidth: .infinity)
                .paper(cornerRadius: Radius.sheet)
                .buttonStyle(ControlButtonStyle(kind: .primary))
            }
        }
        .cueSettings(model)
        .animation(Motion.fade, value: model.failure)
    }

    @ViewBuilder private func steps(_ settings: CueSettings, _ hosts: [CueSettings.Host]) -> some View {
        #if os(iOS)
        CueMacSteps(setup: setup(settings)) { enabling(settings, hosts) }
        #else
        enabling(settings, hosts)
        #endif
    }

    private func enabling(_ settings: CueSettings, _ hosts: [CueSettings.Host]) -> some View {
        VStack(spacing: Spacing.item) {
            action(settings, hosts)
            if let failure = model.failure {
                Text(failure).font(Typography.meta).foregroundStyle(palette.failure)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    #if os(iOS)
    private func setup(_ settings: CueSettings) -> CueMacSetup {
        CueMacSetup(macs: settings.macs, status: services.syncState.status, waiting: settings.gate(services).waitingReason)
    }
    #endif

    /// Mac 上这台总在能启用的几台里（`CueSettings.hosts(here:)`），只有手机要先接上 Mac。
    private func message(_ settings: CueSettings) -> String {
        #if os(iOS)
        if setup(settings).stuck != nil { return String(localized: "我在你的 Mac 上干活，接上 Mac 就能叫我") }
        #endif
        return String(localized: "启用后说一件想做的事，我来开工，要你拿主意时再找你")
    }

    @ViewBuilder private func action(_ settings: CueSettings, _ hosts: [CueSettings.Host]) -> some View {
        if let why = settings.gate(services).waitingReason {
            HStack(spacing: Spacing.item) {
                Spinner(.small)
                Text(why).font(Typography.secondary).foregroundStyle(palette.ink3)
            }
        } else {
            HStack(spacing: Spacing.item) {
                enableButton(settings, hosts)
                if model.enabling != nil { Spinner(.small) }
            }
            .disabled(model.enabling != nil)
        }
    }

    private func enable(on host: CueSettings.Host) {
        #if os(macOS)
        if host.isHere, !host.usable {
            workspace.showsSetup = true
            return
        }
        #endif
        model.choose(host, services)
    }

    /// 别的几台收在旁边一颗"选别的 Mac"的菜单里；Mac 上这颗菜单常驻、没有别的时藏起（占着位置）：库里多一台 Mac 时卡片不长高一截（卡片竖直居中，长高就整块上下挪）；
    /// 不置灰露着：只有一台 Mac 的新用户看到一颗点不了的"选别的 Mac"，不知道该装第二台还是哪里坏了。
    @ViewBuilder private func enableButton(_ settings: CueSettings, _ hosts: [CueSettings.Host]) -> some View {
        if let host = primary(settings, hosts) {
            VStack(spacing: Spacing.item) {
                Button(host.isHere ? "在这台 Mac 上启用" : "在「\(host.name)」上启用") { enable(on: host) }.disabled(!host.selectable)
                if !host.selectable { Text(host.note).font(Typography.meta).foregroundStyle(palette.ink3) }
                let others = hosts.filter { $0.id != host.id }
                #if os(macOS)
                let menu = hostMenu(others, title: String(localized: "选别的 Mac"), surface: ControlSurface(kind: .quiet, size: .compact))
                if others.isEmpty { menu.hidden() } else { menu }
                #else
                if !others.isEmpty { hostMenu(others, title: String(localized: "选别的 Mac"), surface: ControlSurface(kind: .quiet, size: .compact)) }
                #endif
            }
        } else {
            hostMenu(hosts, title: String(localized: "选一台 Mac 启用"), surface: ControlSurface(kind: .primary))
        }
    }

    private func primary(_ settings: CueSettings, _ hosts: [CueSettings.Host]) -> CueSettings.Host? {
        guard hosts.count == 1 || settings.profile.hostID != nil || hosts.first?.isHere == true else { return nil }
        return settings.resumeHost(here: workspace.localHost)
    }

    private func hostMenu(_ hosts: [CueSettings.Host], title: String, surface: ControlSurface) -> some View {
        CueHostMenu(hosts: hosts, use: .enable { enable(on: $0) }, accessibilityLabel: title) {
            HStack(spacing: Spacing.glyph) {
                Text(title)
                Chevron(.expand)
            }
            .modifier(surface)
        }
    }
}
