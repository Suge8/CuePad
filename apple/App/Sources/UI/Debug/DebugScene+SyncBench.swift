#if DEBUG && os(macOS)
import CueStore
import Foundation
import os

extension DebugScene {
    /// `-CuePadCloudKit YES`：隔离库也连 iCloud（同步测量）。签名的 CloudKit 环境必须是 Development：
    /// 测量只写开发环境，开发构建的 ad-hoc 或生产签名带着它也不连。
    static var syncsIsolatedLibrary: Bool {
        guard defaults.bool(forKey: "CuePadCloudKit") else { return false }
        guard Entitlements.cloudKitEnvironment == "Development" else {
            SyncBench.log.error("-CuePadCloudKit 要开发环境签名（CUEPAD_SIGN=development xc.sh build mac），这个构建是 \(Entitlements.cloudKitEnvironment ?? "无", privacy: .public)，不连")
            return false
        }
        return true
    }
}

/// `-CuePadSyncBench <host|remote>`（配 `-CuePadCloudKit YES` 与各自的 `-CuePadHost`）：同一台 Mac 上两个隔离实例经 CloudKit 开发环境同步，
/// 打点给 `apple/scripts/sync-bench.py` 统计（跑法与口径见 docs/verify.md「同步测量」）。每个点是类别 `bench` 的一行 `<事件> 键=值…`。
/// - host：有在线会话的 Mac（会话由脚本的假扩展给）。别的设备对 Cue 说的话一到库里就记 `cue-arrived lag=`（创建到本机库，同一台机器的时钟）。
///   Cue 不值班（隔离目录里没有登录的运行时），所以只量到达、不量 Cue 的回复。
/// - remote：代替开着 Agent 页的手机，拉取节奏也换成手机那档（`DebugHooks.pollsLikePhone`）。等 host 的会话同步过来后，每 `-CuePadSyncBenchEvery` 秒（默认 30）一轮：给 host 的一个在线会话"马上说"一句，
///   与手机同一条路（写请求、立即上传），等结果回到本机记 `send total= upload= toMac= back=`（分段同 `AppServices.PingTiming`）；
///   对 Cue 说一句（`Workspace.sayToCue` 同一条路）；立即同步一次记 `syncNow took=`。
enum SyncBench {
    static let log = Logger(subsystem: AppServices.bundleID, category: "bench")
    /// 一句话等结果最多这么久（同连接测试），超时记一次失败、接着下一轮
    private static let timeout = Duration.seconds(60)

    static func run(_ services: AppServices) async {
        switch defaults.string(forKey: "CuePadSyncBench") {
        case "host": await host(services)
        case "remote":
            let every = defaults.integer(forKey: "CuePadSyncBenchEvery")
            await remote(services, every: .seconds(every > 0 ? every : 30))
        default: break
        }
    }

    private static var defaults: UserDefaults { DebugScene.defaults }

    private static func host(_ services: AppServices) async {
        var seen: Set<UUID>?
        do {
            for try await messages in services.store.observe({ try $0.cueMessages(limit: 50) }) {
                let yours = messages.filter { $0.author == .known(.you) }
                if let known = seen {
                    for message in yours where !known.contains(message.id) {
                        log.notice("cue-arrived lag=\(Date.now.timeIntervalSince(message.createdAt), format: .fixed(precision: 3), privacy: .public)")
                    }
                }
                seen = (seen ?? []).union(yours.map(\.id))
            }
        } catch {
            log.error("bench-error 读 Cue 消息：\(error.localizedDescription, privacy: .public)")
        }
    }

    private static func remote(_ services: AppServices, every interval: Duration) async {
        log.notice("remote-start host=\(services.hostID, privacy: .public)")
        var round = 0
        while !Task.isCancelled {
            let began = ContinuousClock.now
            round += 1
            if let target = await onlineSession(services) {
                await send(round, to: target, services)
            } else {
                log.notice("waiting 还没看到别的 Mac 上的在线会话")
            }
            await sayToCue(round, services)
            // 计到同步真正做完：界面那层（`AppServices.syncNow`）最多等 5 秒，量不出完成时长
            let syncing = ContinuousClock.now
            do { try await services.sync?.syncNow() } catch { log.error("bench-error 立即同步：\(error.localizedDescription, privacy: .public)") }
            log.notice("syncNow took=\((ContinuousClock.now - syncing).seconds, format: .fixed(precision: 3), privacy: .public)")
            try? await Task.sleep(until: began + interval)
        }
    }

    /// 别的 Mac 上的一个在线会话（与手机的发送目标同一批：同步来的会话状态）。
    private static func onlineSession(_ services: AppServices) async -> PiSessionState? {
        let page = try? await services.store.piSessionPage(.current)
        return page?.items.map(\.state).filter { $0.hostID != services.hostID && $0.state != .known(.ended) }.randomElement()
    }

    private static func send(_ round: Int, to session: PiSessionState, _ services: AppServices) async {
        let started = ContinuousClock.now
        do {
            let request = try await services.store.requestDelivery(
                "同步测量第 \(round) 句", to: session.target, on: session.hostID, mode: .steer)
            let written = ContinuousClock.now
            async let done = services.result(of: request.id, within: timeout)
            await services.upload(request.id)
            let uploaded = (instant: ContinuousClock.now, date: Date.now)
            guard let (result, seen) = try await done else {
                return log.error("bench-error 发送：\(timeout.components.seconds) 秒没有结果")
            }
            let completed = result.completedAt ?? seen.date
            log.notice("""
                send total=\((seen.instant - started).seconds, format: .fixed(precision: 3), privacy: .public) \
                upload=\((uploaded.instant - written).seconds, format: .fixed(precision: 3), privacy: .public) \
                toMac=\(completed.timeIntervalSince(uploaded.date), format: .fixed(precision: 3), privacy: .public) \
                back=\(seen.date.timeIntervalSince(completed), format: .fixed(precision: 3), privacy: .public) \
                failed=\(result.failure != nil, privacy: .public)
                """)
        } catch {
            log.error("bench-error 发送：\(error.localizedDescription, privacy: .public)")
        }
    }

    private static func sayToCue(_ round: Int, _ services: AppServices) async {
        do {
            let message = try await services.store.addCueMessage(.you, text: "同步测量第 \(round) 句")
            await services.upload(message.id)
        } catch {
            log.error("bench-error 对 Cue 说：\(error.localizedDescription, privacy: .public)")
        }
    }
}
#endif
