import CueStore
import Foundation

extension Workspace {
    func operate(on host: String, viewing sessionID: String? = nil) async {
        services.settings.remoteLastHost = host
        if let device = services.settings.remoteDevices[host] { await control(device, host: host, viewing: sessionID) } else { await bind(host, viewing: sessionID) }
    }

    func operateMac() async -> [MacAgents]? {
        let macs: [MacAgents]
        do { macs = try await services.store.allMacAgents() } catch {
            fail(error)
            return nil
        }
        let last = services.settings.remoteLastHost
        if macs.count == 1 { await operate(on: macs[0].hostID) }
        else if let last, macs.contains(where: { $0.hostID == last }) { await operate(on: last) }
        else { return macs }
        return nil
    }

    /// 重新在 UU 远程里给这台 Mac 选电脑（选错了、换了 UU 账号：全屏远控连不上时 UU 不回报，只能这样改）。
    func rebindMac(_ host: String) async {
        services.settings.remoteLastHost = host
        await bind(host)
    }

    private func bind(_ host: String, viewing sessionID: String? = nil) async {
        let nonce = UUID().uuidString
        services.settings.remoteBinding = .init(nonce: nonce, host: host, viewing: sessionID)
        await launch(MacRemote.authorize(nonce: nonce))
    }

    private func control(_ device: String, host: String, viewing sessionID: String? = nil) async {
        #if os(iOS)
        if let sessionID { await services.liveRemote.show(sessionID, on: host) }
        let launched = await launch(MacRemote.control(device, host: host))
        if !launched, sessionID != nil { await services.liveRemote.comeBack() }
        #else
        await launch(MacRemote.control(device, host: host))
        #endif
    }

    @discardableResult private func launch(_ url: URL) async -> Bool {
        guard await !apps.open(url) else { return true }
        say("先装网易 UU 远程，并在 Mac 上也装好、登录同一个账号", tone: .gone, action: NoticeAction(title: String(localized: "去 App Store")) {
            _ = await $0.apps.open(MacRemote.appStore)
        })
        return false
    }

    func remoteBound(device: String?, error: String?, nonce: String?) async {
        guard let binding = services.settings.remoteBinding, binding.nonce == nonce else { return }
        services.settings.remoteBinding = nil
        if let device {
            services.settings.remoteDevices[binding.host] = device
            await control(device, host: binding.host, viewing: binding.viewing)
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
