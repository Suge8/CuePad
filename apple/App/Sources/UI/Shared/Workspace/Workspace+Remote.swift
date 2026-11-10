import CueStore
import Foundation

extension Workspace {
    func operate(on host: String) async {
        services.settings.remoteLastHost = host
        if let device = services.settings.remoteDevices[host] { await launch(MacRemote.control(device, host: host)) } else { await bind(host) }
    }

    /// 还没连过时返回这几台，由界面先选一台。
    func operateMac() async -> [MacAgents]? {
        let macs: [MacAgents]
        do { macs = try await services.store.allMacAgents() } catch {
            fail(error)
            return nil
        }
        let last = services.settings.remoteLastHost
        if macs.count == 1 { await operate(on: macs[0].hostID) }
        else if let last, macs.contains(where: { $0.hostID == last }) { await operate(on: last) }
        else if macs.isEmpty { say("还没有 Mac 用过 CuePad", tone: .gone) }
        else { return macs }
        return nil
    }

    /// 重新在 UU 远程里给这台 Mac 选电脑（选错了、换了 UU 账号：全屏远控连不上时 UU 不回报，只能这样改）。
    func rebindMac(_ host: String) async {
        services.settings.remoteLastHost = host
        await bind(host)
    }

    private func bind(_ host: String) async {
        let nonce = UUID().uuidString
        services.settings.remotePending = [nonce: host]
        await launch(MacRemote.authorize(nonce: nonce))
    }

    /// 拉起 UU 远程；打不开就是没装，提示去 App Store。
    private func launch(_ url: URL) async {
        guard await !apps.open(url) else { return }
        say("先装网易 UU 远程，并在 Mac 上也装好、登录同一个账号", tone: .gone, action: NoticeAction(title: String(localized: "去 App Store")) {
            _ = await $0.apps.open(MacRemote.appStore)
        })
    }

    func remoteBound(device: String?, error: String?, nonce: String?) async {
        guard let nonce, let host = services.settings.remotePending[nonce] else { return }
        services.settings.remotePending = [:]
        if let device {
            services.settings.remoteDevices[host] = device
            await launch(MacRemote.control(device, host: host))
        } else if let message = error.flatMap(MacRemote.failure) {
            say(Dotted(message), tone: .failure)
        }
    }

    func remoteFailed(host: String?, reason: String) {
        guard let failure = MacRemote.controlFailure(reason) else { return }
        if reason == "device_not_found", let host { services.settings.remoteDevices[host] = nil }
        let rebind = host.flatMap { host in
            failure.rebind ? NoticeAction(title: String(localized: "重新选择 Mac")) { await $0.rebindMac(host) } : nil
        }
        say(Dotted(failure.message), tone: .failure, action: rebind)
    }
}
