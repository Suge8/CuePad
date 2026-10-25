#if DEBUG && os(macOS)
import CoreFoundation
import CueStore
import CueSync
import Foundation

extension SyncBench {
    /// 两端一样的记录方：说的话（Cue 消息、投送请求）每过一段记一行，脚本按 `id` 把两个实例的行拼成一条时间线。
    /// 本机写下的与同步来的按第一次读到时服务器收下过没有分（同步来的都收下过）：
    /// - `msg-write`（时刻取 `createdAt`）/ `msg-arrived`：本机写下 / 同步到本机库；`msg-accepted`：本机写下的被服务器收下（已发出）；
    ///   `msg-delivered`：有了 `deliveredAt`（Cue 那台是交给 Cue，发出方是回执到了）；`msg-shown`：第一次画进页面（`shown`）。
    /// - `req-write`、`req-accepted`、`req-arrived` 同上；`req-done`：本机读到结果（`completed` 是执行完的时刻）。
    /// - `sync-status s=`、`relay live=`：同步状态、门铃通断每次变化。
    /// 第一次读到的那批记 `*-present`（启动前就在库里的），不算到达。
    enum Watch {
        static func start(_ services: AppServices) {
            let store = services.store
            Task { await follow(store.observe { try $0.cueMessages(limit: 200) }, prefix: "msg") { Seen($0) } }
            Task { await follow(store.observe { try $0.deliveryRequests() }, prefix: "req") { Seen($0) } }
            Task {
                for await status in Observations({ String(describing: services.syncStatus) }) { mark("sync-status", ["s": status]) }
            }
            Task {
                for await live in Observations({ services.relay?.isLive ?? false }) { mark("relay", ["live": live]) }
            }
        }

        /// 一条说的话此刻的样子里记录方关心的几样。
        struct Seen {
            let id: UUID
            let created: Date
            let reachedServer: Bool
            let done: Date?
            /// Cue 消息是谁说的（you、cue）；请求没有。
            var author: String?

            init(_ message: CueMessage) {
                (id, created, reachedServer, done) = (message.id, message.createdAt, message.reachedServer, message.deliveredAt)
                author = message.author.rawValue
            }

            init(_ request: DeliveryRequest) {
                (id, created, reachedServer, done) = (request.id, request.createdAt, request.reachedServer, request.completedAt)
            }
        }

        private static func follow<T>(_ updates: AsyncThrowingStream<[T], any Error>, prefix: String, _ seen: (T) -> Seen) async {
            var known: [UUID: Seen]?
            do {
                for try await items in updates {
                    var next: [UUID: Seen] = [:]
                    for item in items.map(seen) {
                        next[item.id] = item
                        step(prefix, item, was: known.map { $0[item.id] })
                    }
                    known = (known ?? [:]).merging(next) { $1 }
                }
            } catch {
                mark("bench-error", ["what": "读 \(prefix)：\(error.localizedDescription)"])
            }
        }

        /// `was`：nil 是第一次读（启动时），`.some(nil)` 是这一条第一次出现。
        private static func step(_ prefix: String, _ item: Seen, was: Seen??) {
            let id: [String: any Sendable] = ["id": item.id.uuidString.lowercased()]
            let first = id.merging(["author": item.author ?? ""] as [String: any Sendable]) { $1 }
            guard let was else { return mark("\(prefix)-present", first) }
            if let was {
                if item.reachedServer, !was.reachedServer { mark("\(prefix)-accepted", id) }
            } else if item.reachedServer {
                mark("\(prefix)-arrived", first)
            } else {
                mark("\(prefix)-write", first, at: item.created)
            }
            if let done = item.done, was?.done == nil { mark(prefix == "msg" ? "msg-delivered" : "req-done", id.merging(["at": done.timeIntervalSince1970] as [String: any Sendable]) { $1 }) }
        }

        /// 已经画过的 Cue 消息。
        private static var shown: Set<UUID> = []

        /// 页面的订阅拿到新值（`Observing` 写进页面状态那一刻，`DebugHooks.observed`）：Cue 页里第一次出现的话，
        /// 等这一圈主线程的界面更新与 Core Animation 提交做完（提交之后的 beforeWaiting 观察者）记 `msg-shown`。
        static func observed(_ value: Any) {
            guard let thread = value as? CueThread else { return }
            let fresh = thread.messages.map(\.id).filter { !shown.contains($0) }
            guard !fresh.isEmpty else { return }
            shown.formUnion(fresh)
            let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, false, afterCommit) { _, _ in
                for id in fresh { mark("msg-shown", ["id": id.uuidString.lowercased()]) }
            }
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        }

        /// 排在 Core Animation 提交（2000000）之后。
        private static let afterCommit = 2_100_000
    }
}
#endif
