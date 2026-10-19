#if DEBUG
import CueStore
import CueSync
import Foundation
import SQLite3
import Synchronization

extension DebugScene {
    /// `-CuePadSync stalled`：装上拉取永不返回的同步替身（隔离库本来没有同步），核对下拉刷新的圈有时限、界面不跟着卡。
    /// `-CuePadSync arrive`：像隔了一阵没打开的手机，启动后的第一次拉取带回别的设备写下的 Cue 的话，分几页陆续到（`ArrivingSync`）。
    /// `-CuePadSync offline`：一开始连不上 iCloud，`-CuePadOfflineSeconds`（默认 6）秒后恢复；配 `-CuePadDemoMac YES` 与
    /// `-CuePadSpeech send` 录"断网时说 → 同步不通 → 恢复 → 送达"（演示 Mac 断网时不接手）。
    /// `-CuePadSync <noAccount|decide|failed|syncing|restricted|conflicts>`：装上报这个状态的替身，设置里 iCloud 同步那一行、
    /// 要你决定的两个选择、立即同步与 Mac 工具栏的同步提示都按有同步时的样子出现；`failed` 带两条没能同步的记录，`conflicts` 在演示库里造一份冲突副本。
    static var syncSource: AppServices.SyncSource {
        let issues = [
            SyncIssue(recordType: "Card", recordName: "A1B2", message: "CKError 14: server record changed"),
            SyncIssue(recordType: "Attachment", recordName: "9F3E", message: "CKError 27: asset file not found"),
        ]
        return switch defaults.string(forKey: "CuePadSync") {
        case "stalled": .custom(StandInSync(stalls: true))
        case "conflicts": .custom(StandInSync())
        case "noAccount": .custom(StandInSync(SyncState(status: .noAccount, issues: [])))
        case "decide": .custom(StandInSync(SyncState(status: .needsDecision(.accountSwitched), issues: [])))
        case "failed": .custom(StandInSync(SyncState(status: .failed("同步出错"), issues: issues)))
        case "syncing": .custom(StandInSync(SyncState(status: .syncing, issues: [])))
        case "restricted": .custom(StandInSync(SyncState(status: .accountRestricted, issues: [])))
        case "offline": .custom(OfflineSync(seconds: defaults.object(forKey: "CuePadOfflineSeconds") as? Double ?? 6))
        case "arrive": .custom(ArrivingSync())
        default: .iCloud
        }
    }

    /// 先报连不上 iCloud，过一会儿报已同步；拉取与上传什么都不做。
    nonisolated final class OfflineSync: SyncControlling {
        let seconds: Double
        init(seconds: Double) { self.seconds = seconds }
        var stateUpdates: AsyncStream<SyncState> {
            AsyncStream { [seconds] continuation in
                continuation.yield(SyncState(status: .offline, issues: []))
                let task = Task {
                    try? await Task.sleep(for: .seconds(seconds))
                    continuation.yield(SyncState(status: .idle, issues: []))
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }
        func start() async throws {}
        func stop() async {}
        func syncNow() async throws {}
        func send(recordName: String) async -> Bool { true }
        func push() async {}
        func resolve(_ resolution: SyncResolution) async throws {}
    }

    /// 第一次拉取（启动后同步一通就拉的那一次，`AppServices.setSyncState`）带回 `pages` 页别的设备写下的 Cue 的话，每页 `perPage` 条、
    /// 隔 `pageGap` 到一页（同 `ZonePuller` 一页页应用），拉完才返回；之后的拉什么都不做。话直接写进本机库：界面看到的与应用远端变更是同一种变化。
    nonisolated final class ArrivingSync: SyncControlling {
        static let pages = 3
        static let perPage = 6
        static let pageGap = Duration.milliseconds(450)
        /// 资料库在服务建好后才有（替身先建）：摆画面时交过来（`presetSync`）。
        static let library = AsyncStream<CueStore>.makeStream(bufferingPolicy: .bufferingNewest(1))
        private let first = Mutex<Task<Void, Never>?>(nil)

        var stateUpdates: AsyncStream<SyncState> { AsyncStream { $0.yield(SyncState(status: .idle, issues: [])) } }
        func start() async throws {}
        func stop() async {}
        func syncNow() async throws { await pull() }
        func send(recordName: String) async -> Bool { true }
        func push() async {}
        func resolve(_ resolution: SyncResolution) async throws {}

        private func pull() async {
            let task = first.withLock { task in
                if let task { return task }
                let made = Task { await Self.arrive() }
                task = made
                return made
            }
            await task.value
        }

        private static func arrive() async {
            var stores = library.stream.makeAsyncIterator()
            guard let store = await stores.next() else { return }
            let lines = [
                (CueAuthor.note, "看了圆桌：重连的人拿到了新的加入时间，乱序就是从这来的"),
                (.note, "让 atlas 改成按首次加入时间排序，正在跑 scheduler 的测试"),
                (.cue, "排序改好了，scheduler 的 42 个测试都过了。接下来补 3 个重连用例。"),
                (.note, "补了「6 人同时重连顺序不变」，在跑"),
                (.note, "CuePad 导入旧数据的会话又出错了：prompt 太长，等你回来再拆"),
                (.cue, "重连用例都过了，预发也部署好了，截图放在任务上。要推送到 origin/main 吗？"),
            ]
            for page in 0..<pages {
                try? await Task.sleep(for: pageGap)
                for index in 0..<perPage {
                    let (author, text) = lines[(page * perPage + index) % lines.count]
                    _ = try? await store.addCueMessage(author, text: text)
                }
            }
        }
    }

    /// 报 `state`（默认已同步），其余什么都不做；`stalls` 时立即同步不返回（像网络一直没有回音）。
    nonisolated final class StandInSync: SyncControlling {
        let state: SyncState
        let stalls: Bool
        init(_ state: SyncState = SyncState(status: .idle, issues: []), stalls: Bool = false) { (self.state, self.stalls) = (state, stalls) }
        var stateUpdates: AsyncStream<SyncState> { AsyncStream { [state] in $0.yield(state) } }
        func start() async throws {}
        func stop() async {}
        func syncNow() async throws { if stalls { try await Task.sleep(for: .seconds(86_400)) } }
        func send(recordName: String) async -> Bool { true }
        func push() async {}
        func resolve(_ resolution: SyncResolution) async throws {}
    }

    /// 摆画面时交给同步替身的：`arrive` 的资料库，`conflicts` 的冲突副本（冲突那一行由有同步时的订阅读出，`AppServices.startSync`）。
    static func presetSync(_ services: AppServices) async {
        switch defaults.string(forKey: "CuePadSync") {
        case "arrive": ArrivingSync.library.continuation.yield(services.store)
        case "conflicts": await seedConflict(services)
        default: break
        }
    }

    /// 拿演示库里的一张灵感，复制一份改过的正文，标成它的冲突副本。
    private static func seedConflict(_ services: AppServices) async {
        let store = services.store
        var original: Card?
        for project in (try? await store.projects()) ?? [] where original == nil {
            original = try? await store.cards(in: project.id).first
        }
        guard let original, let copy = try? await store.createCard(in: original.projectID, body: original.body + "\n另一台设备上补了一句")
        else { return }
        _ = markConflict(copy: copy.id, of: original.id, database: services.location.databaseURL)
    }

    /// 库里没有创建冲突副本的公开入口（由同步产生）：直接在库文件里把副本指回原卡。演示与测试共用这一处。
    static func markConflict(copy: UUID, of original: UUID, database: URL) -> Bool {
        var handle: OpaquePointer?
        defer { sqlite3_close(handle) }
        guard sqlite3_open(database.path, &handle) == SQLITE_OK else { return false }
        let sql = "UPDATE cards SET conflictOf = '\(original.uuidString.lowercased())' WHERE id = '\(copy.uuidString.lowercased())'"
        return sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK
    }
}
#endif
