#if os(iOS)
import CryptoKit
import Foundation
import Network
import Synchronization
import UIKit

/// 手机、iPad 开着的一个活预览去 Mac 的路，看得见的这一段一份（`run`，预览面板的 task，收起、进后台就结束）：向 Mac 要隧道的入口（`LiveRemote.watch(open:)`），
/// 拿到后同时连 Mac 报来的每个局域网地址、只验票（端口 0），最先通的交给代理（`LiveTunnel.Proxy`）：局域网地址的页面经它的 SOCKS 口，localhost 的经它照搬到手机回环上的同号口（`mirror`）。
/// 本地网络权限的弹窗出在这里第一次连局域网地址时：只有点开预览才走到这里，会话页本身只经中转问、不碰局域网。
/// 连不上时每 `retry` 再试一次，直到通了或预览收起：允许权限、回到 Wi-Fi、Mac 醒来都不用动手。
@Observable
final class LiveLink {
    enum State: Equatable {
        case asking, ready
        case trouble(LiveTrouble)
    }

    private(set) var state = State.asking
    var trouble: LiveTrouble? {
        switch state {
        case .asking: .asking
        case .ready: nil
        case .trouble(let trouble): trouble
        }
    }

    @ObservationIgnored let proxy: LiveTunnel.Proxy
    @ObservationIgnored private var connecting: Task<Void, Never>?
    @ObservationIgnored private var door: LiveSignal.Door?
    /// 代理此刻用的路（`LiveTunnel.Route.id`）：只理会这条路断了的报告。
    @ObservationIgnored private var route: UUID?
    @ObservationIgnored private var pages: [URL] = []

    static let retry = Duration.seconds(3)
    /// 连一个地址最多等多久：同一网段里连不上多半是路由器不让设备互连（访客网络），不再等下去。
    static let reach = Duration.seconds(3)

    init() throws { proxy = try LiveTunnel.Proxy() }

    /// 直到所在任务取消（预览收起、App 进后台）：走时断开隧道，Mac 那头这张票据随之作废。只跑一次：代理的监听口关了不能再开。
    func run(_ preview: LivePreview, sessionID: String, host: String, remote: LiveRemote, key: @escaping @MainActor () -> SymmetricKey?) async {
        defer {
            connecting?.cancel()
            proxy.cancel()
            preview.serve(nil)
        }
        guard let port = try? await proxy.start() else { return state = .trouble(.isolated) }
        preview.dataStore.proxyConfigurations = [proxy.configuration(port: port)]
        let broken = proxy.broken
        await withDiscardingTaskGroup { group in
            group.addTask { await remote.watch(sessionID, on: host, open: true) }
            group.addTask { await self.mend(broken, preview, sessionID: sessionID, remote: remote, key: key) }
            for await seen in Observations({ Seen(answer: remote.answers[sessionID], offline: remote.offline.contains(sessionID)) }) {
                follow(seen, preview, key: key)
            }
        }
    }

    /// 票据不认了（Mac 重开了口、手机换了租约）：再要一张；连不上了：重新找路。
    private func mend(_ broken: AsyncStream<LiveTunnel.Break>, _ preview: LivePreview, sessionID: String, remote: LiveRemote,
                      key: @escaping @MainActor () -> SymmetricKey?) async {
        for await report in broken where report.route == route {
            if report.answer == .ticket { remote.renew(sessionID) } else if let door { connect(door, preview, key: key) }
        }
    }

    private struct Seen: Equatable, Sendable {
        let answer: LiveRemote.Pages?
        let offline: Bool
    }

    private func follow(_ seen: Seen, _ preview: LivePreview, key: () -> SymmetricKey?) {
        if seen.offline { return lose(.offline, preview) }
        guard let answer = seen.answer else {
            // 还没答过是在问；答过、现在没有页面了是服务停了
            if door != nil { lose(.gone, preview) }
            return
        }
        pages = answer.pages
        proxy.mirror(Set(answer.ports.compactMap { UInt16(exactly: $0) }.filter { $0 != 0 }))
        preview.follow(answer, showing: true)
        if state == .ready { preview.serve(pages) }
        guard let next = answer.door, next != door else { return }
        door = next
        connect(next, preview, key: key)
    }

    private func lose(_ trouble: LiveTrouble, _ preview: LivePreview) {
        connecting?.cancel()
        door = nil
        route = nil
        proxy.use(nil)
        preview.serve(nil)
        state = .trouble(trouble)
    }

    private func connect(_ door: LiveSignal.Door, _ preview: LivePreview, key: () -> SymmetricKey?) {
        connecting?.cancel()
        guard let key = key() else { return state = .trouble(.offline) }
        connecting = Task {
            while !Task.isCancelled {
                let reached = await Self.reach(door, key: key)
                // 探的这一会儿又断了一次、换了入口（新的一轮已经起了）：这一轮的结果不提交，不然切回旧入口、多载一次
                guard !Task.isCancelled else { return }
                switch reached {
                case .mac(let mac):
                    let addresses = Set(door.addresses.map(\.host))
                    let next = LiveTunnel.Route(key: key, ticket: door.ticket, mac: mac, addresses: addresses)
                    route = next.id
                    proxy.use(next)
                    preview.tunneled = addresses
                    preview.linked(pages)
                    state = .ready
                    return
                case .trouble(.denied) where UIApplication.shared.applicationState != .active:
                    // 权限框挂着（应用这时不在活动状态）系统就把连接报成没给权限：他还没答，不亮"没有本地网络权限"；答完回来马上再探。
                    // 实测等着重试的那一下，点了允许还要看十来秒"没有本地网络权限"
                    for await _ in NotificationCenter.default.notifications(named: UIApplication.didBecomeActiveNotification) { break }  // 晚订：上一行刚看过还没回到活动状态，中间没让出主线程
                    continue
                case .trouble(let trouble):
                    preview.serve(nil)
                    state = .trouble(trouble)
                }
                try? await Task.sleep(for: Self.retry)
            }
        }
    }

    private enum Reached: Sendable {
        case mac(NWEndpoint)
        case trouble(LiveTrouble)
    }

    private enum Probe: Sendable {
        case open(NWEndpoint)
        case denied, failed
    }

    /// 同时连 Mac 的每个地址，用最先验过票的那个。都不通时按手机自己的网络说原因：没有 Wi-Fi、不在一个网段、同网段却连不上（多半是访客网络的隔离）、没给本地网络权限。
    private nonisolated static func reach(_ door: LiveSignal.Door, key: SymmetricKey) async -> Reached {
        let mine = LiveTunnel.localAddresses()
        guard !mine.isEmpty else { return .trouble(.noWiFi) }
        var denied = false
        let found: NWEndpoint? = await withTaskGroup(of: Probe.self) { group in
            for address in door.addresses {
                group.addTask { await probe(.hostPort(host: .init(address.host), port: .init(rawValue: door.port)!), key: key, ticket: door.ticket) }
            }
            for await result in group {
                switch result {
                case .open(let mac):
                    group.cancelAll()
                    return mac
                case .denied: denied = true
                case .failed: break
                }
            }
            return nil
        }
        if let found { return .mac(found) }
        if denied { return .trouble(.denied) }
        let together = mine.contains { mine in door.addresses.contains(where: mine.shares) }
        return .trouble(together ? .isolated : .apart)
    }

    private nonisolated static func probe(_ mac: NWEndpoint, key: SymmetricKey, ticket: Data) async -> Probe {
        let connection = NWConnection(to: mac, using: LiveTunnel.parameters(key: key))
        defer { connection.cancel() }
        let denied = Mutex(false)
        do {
            try await connection.established(within: reach) { if $0 == .localNetworkDenied { denied.withLock { $0 = true } } }
            try await connection.write(LiveTunnel.Request(ticket: ticket, host: "", port: 0).encoded)
            let answer = try await connection.bounded(reach) { try await connection.read(1) }
            return answer.first == LiveTunnel.Answer.open.rawValue ? .open(mac) : .failed
        } catch {
            return denied.withLock { $0 } ? .denied : .failed
        }
    }
}
#endif
