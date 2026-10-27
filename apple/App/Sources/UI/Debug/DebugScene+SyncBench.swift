#if DEBUG && os(macOS)
import AppKit
import CueStore
import CueSync
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
/// 由 `apple/scripts/sync-bench.py` 驱动与统计（场景与口径见 docs/perf.md「同步测量」）。
/// - host：有在线会话的 Mac（会话由脚本的假扩展给），Cue 在这台值班（大脑是 `-CuePadCueBrain` 的替身，回"知道了。"）。
/// - remote：代替手机，拉取节奏按手机开着 Agent 页那档（`DebugHooks.pollsLikePhone`）。
/// 两端都只做脚本经标准输入给的命令（`command`），自己不按时做任何事：节奏只在脚本一处。
/// 打点是标准输出里的一行 `SYNCBENCH {json}`（`e` 事件、`t` 墙钟秒，同一台机器跨进程可直接相减），事件见 `SyncBench.Watch` 与 `command`。
/// `-CuePadSyncBenchNoRelay YES`：不连门铃，只靠按节奏的拉取（门铃不通的那条路）。
enum SyncBench {
    static let log = Logger(subsystem: AppIdentity.id, category: "bench")
    static var role: String? { defaults.string(forKey: "CuePadSyncBench") }
    static var relayOff: Bool { role != nil && defaults.bool(forKey: "CuePadSyncBenchNoRelay") }
    /// `-CuePadSyncBenchCloud <目录>`：两个实例共用的模拟云（`SharedCloud`，延迟模型在目录里）；没给就连真的 iCloud 开发环境，
    /// 这时 `-CuePadSyncBenchBudget <个>` 是这个进程的请求上限。
    static var sharedCloud: URL? { defaults.string(forKey: "CuePadSyncBenchCloud").map { URL(filePath: $0, directoryHint: .isDirectory) } }
    static var budget: Int? { defaults.object(forKey: "CuePadSyncBenchBudget") == nil ? nil : defaults.integer(forKey: "CuePadSyncBenchBudget") }
    private static var defaults: UserDefaults { DebugScene.defaults }

    static func run(_ workspace: Workspace) async {
        guard let role else { return }
        let services = workspace.services
        mark("ready", ["role": role, "pid": Int(getpid()), "relay": services.relay != nil])
        Watch.start(services)
        Files.start(services)
        if role == "host" { await enableCue(services) }
        do {
            for try await line in FileHandle.standardInput.bytes.lines {
                await command(line.split(separator: " ").map(String.init), workspace)
            }
        } catch {
            log.error("bench-error 读命令：\(error.localizedDescription, privacy: .public)")
        }
    }

    /// 一行打点，脚本按行读（标准输出是管道，每行当场冲出去）。
    static func mark(_ event: String, _ fields: [String: any Sendable] = [:], at time: Date = .now) {
        var row = fields
        row["e"] = event
        row["t"] = time.timeIntervalSince1970
        guard let data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) else { return }
        print("SYNCBENCH " + String(decoding: data, as: UTF8.self))
        fflush(stdout)
    }

    /// Cue 在这台值班：设置写成运行在这台、运行时 Pi（大脑由 `-CuePadCueBrain` 换成替身）。
    private static func enableCue(_ services: AppServices) async {
        let host = services.hostID
        do {
            try await services.store.updateCueProfile {
                $0.hostID = host
                $0.enabledAt = .now
                $0.runtime = .known(.pi)
            }
        } catch {
            log.error("bench-error 启用 Cue：\(error.localizedDescription, privacy: .public)")
        }
    }

    /// 脚本的命令，一行一条：
    /// - `say <标记>`：对 Cue 说一句（`Workspace.speak`，与输入框同一条路）；`send <标记> <Mac>`：对那台 Mac 上的一个在线会话说一句
    ///   （开发区里还有别的调试数据同步来的演示会话，所以点名是哪台）。
    /// - `cue <条数> [间隔秒]`：以 Cue 的身份对你说几句、每句马上传，传完记 `msg-sent ok=`（Cue 的话被收下不叫醒说的话的订阅，`Watch` 看不到已发出）。
    /// - `sync`：立即同步，记 `sync-now took=`（计到拉完：界面那层最多等 5 秒，量不出完成时长）。
    /// - `stats`：这个进程到此刻发给云的请求数与每种请求的每次用时（`CloudOutage`），记 `stats requests= timings=`。
    /// - `offline`：这个实例连 iCloud 的请求都以没有网络失败（`CloudOutage`），门铃断开；`online [path]`：恢复，门铃重连，
    ///   给了 path 再替路径监视器报一次网络回来（真断网的恢复；不给是路径一直可用、只是 iCloud 连不上）。
    /// - `card-new`：建一张卡记 `card id=`；`churn <卡片 id>`：紧循环改它的正文，`churn-stop` 停下并记 `churned writes=`（撞版本探针，`sync-bench.py versions`）。
    /// - 带文件的那几条（`burst`、`watch-file`）见 `Files.command`。
    /// - `bg`、`fg`：像手机那样进后台的收尾（`prepareForBackground`）、回前台（`handleActivation`）；`hide`、`activate`：Mac 隐藏、回到前台。
    private static func command(_ words: [String], _ workspace: Workspace) async {
        let services = workspace.services
        let tag = words.dropFirst().first ?? ""
        mark("command", ["line": words.joined(separator: " ")])
        switch words.first {
        case "say":
            workspace.speak("同步测量 \(tag)", to: .cue)
        case "send":
            guard let session = await onlineSession(on: words.count > 2 ? words[2] : "", services) else {
                return mark("bench-error", ["what": "没有那台 Mac 上的在线会话"])
            }
            workspace.speak("同步测量 \(tag)", to: .session(session, mode: .send))
        case "cue":
            let count = Int(tag) ?? 1
            let gap = words.count > 2 ? Double(words[2]) ?? 0 : 0
            for index in 0..<count {
                do {
                    let message = try await services.store.addCueMessage(.cue, text: "同步测量 Cue 第 \(index) 句")
                    Task {
                        let ok = await services.sync?.send(recordNames: [message.id.uuidString.lowercased()]) ?? false
                        mark("msg-sent", ["id": message.id.uuidString.lowercased(), "ok": ok])
                    }
                } catch {
                    mark("bench-error", ["what": "写 Cue 的话：\(error.localizedDescription)"])
                }
                if gap > 0, index < count - 1 { try? await Task.sleep(for: .seconds(gap)) }
            }
        case "sync":
            let began = ContinuousClock.now
            do { try await services.sync?.syncNow() } catch { mark("bench-error", ["what": "立即同步：\(error.localizedDescription)"]) }
            mark("sync-now", ["took": (ContinuousClock.now - began).seconds])
        case "bg":
            await services.prepareForBackground()
            mark("bg-done")
        case "fg", "activate":
            if words.first == "activate" { NSApp.unhide(nil) }
            await services.handleActivation()
            mark("fg-done")
        case "offline":
            CloudOutage.set(true)
            services.relay?.pause()
            await services.relay?.settle()
            mark("offline")
        case "online":
            CloudOutage.set(false, pathReturns: tag == "path")
            services.relay?.resume()
            mark("online")
        case "stats":
            mark("stats", ["requests": CloudOutage.requests, "timings": CloudOutage.requestTimings])
        case "card-new":
            do { mark("card", ["id": try await services.store.createCard(body: "同步测量 0").id.uuidString.lowercased()]) } catch {
                mark("bench-error", ["what": "建卡片：\(error.localizedDescription)"])
            }
        case "churn":
            guard let card = UUID(uuidString: tag) else { return mark("bench-error", ["what": "churn 要卡片 id"]) }
            churning = Task { await churn(card, services.store) }
        case "churn-stop":
            churning?.cancel()
            mark("churned", ["writes": await churning?.value ?? 0])
        case "hide":
            NSApp.hide(nil)
        default:
            if await !Files.command(words, workspace) { mark("bench-error", ["what": "不认识的命令"]) }
        }
    }

    private static var churning: Task<Int, Never>?

    /// 紧循环改同一张卡的正文，直到取消；返回写了几次（撞版本探针：命令行同时逐条改它）。
    private static func churn(_ card: UUID, _ store: CueStore) async -> Int {
        var writes = 0
        while !Task.isCancelled {
            writes += 1
            let body = "app-\(writes)"
            do { try await store.updateCard(card) { $0.body = body } } catch { mark("bench-error", ["what": "改卡片：\(error.localizedDescription)"]); break }
        }
        return writes
    }

    /// `host` 那台 Mac 上的一个在线会话（与手机的发送目标同一批：同步来的会话状态）。
    private static func onlineSession(on host: String, _ services: AppServices) async -> PiSessionState? {
        let page = try? await services.store.piSessionPage(.current)
        return page?.items.map(\.state).filter { $0.hostID == host && $0.state != .known(.ended) }.randomElement()
    }
}
#endif
