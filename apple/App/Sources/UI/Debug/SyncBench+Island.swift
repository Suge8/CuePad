#if DEBUG && os(iOS)
import ActivityKit
import CueStore
import Foundation

/// `-CuePadSyncBench island`（iPhone 模拟器，配 `-CuePadLiveActivity YES`，`sync-bench.py island` 起）：M4 收消息到灵动岛在模拟器上量得到的那一段——
/// 推送叫醒后拉到的话已经入库，到实时活动换成新的一份。每轮以 Cue 的身份写一问（等你多一件，岛的内容必变），
/// 走推送回调拉完之后的同一步（`AppServices.writeSnapshots`），系统那份实时活动的内容每换一次记 `island`（`Activity.contentUpdates`），脚本按轮对上。
/// 打点写进库目录的 `bench-marks.jsonl`（一行 `{"e","t","round"}`，墙钟秒），`-CuePadSyncBenchRounds` 轮（默认 10）后记 `done`。
/// 在摆画面那一步里跑完才报就绪（`DebugScene.prepare`）：xc.sh run 等就绪期间一直持有模拟器，跑到一半不会被别的任务换掉；脚本读完按 PID 收掉实例。
/// 量不到：推送到达本身、后台叫醒（模拟器上本机构建不带推送权限，系统不在后台叫起它）、拉取（Mac 上的替身手机量）、岛画到屏幕上。
enum IslandBench {
    static func run(_ services: AppServices) async {
        let defaults = DebugScene.defaults
        guard defaults.string(forKey: "CuePadSyncBench") == "island",
              let library = ProcessInfo.processInfo.environment["CUEPAD_LIBRARY_DIR"] else { return }
        let marks = Marks(URL(filePath: library).appending(path: "bench-marks.jsonl"))
        let rounds = defaults.integer(forKey: "CuePadSyncBenchRounds") > 0 ? defaults.integer(forKey: "CuePadSyncBenchRounds") : 10
        let watcher = Task {
            for await activity in Activity<CueActivityAttributes>.activityUpdates {
                marks.add("island-open")
                for await _ in activity.contentUpdates { marks.add("island") }
            }
        }
        // 第 0 轮只为让岛开起来（系统只许前台开），脚本不计
        for round in 0...rounds {
            do {
                _ = try await services.store.addCueMessage(.cue, text: "同步测量第 \(round) 问", ask: CueAsking(.taste, action: "测量第 \(round) 问"))
                marks.add("write", round)
                try await services.writeSnapshots()
                marks.add("snapshots", round)
            } catch {
                marks.add("bench-error \(error)", round)
            }
            try? await Task.sleep(for: .seconds(1))
        }
        watcher.cancel()
        marks.add("done")
    }

    private final class Marks {
        let file: FileHandle?
        init(_ url: URL) {
            FileManager.default.createFile(atPath: url.path(), contents: nil)
            file = try? FileHandle(forWritingTo: url)
        }

        func add(_ event: String, _ round: Int? = nil, at time: Date = .now) {
            var row: [String: Any] = ["e": event, "t": time.timeIntervalSince1970]
            if let round { row["round"] = round }
            guard let data = try? JSONSerialization.data(withJSONObject: row) else { return }
            file?.write(data + Data("\n".utf8))
        }
    }
}
#endif
