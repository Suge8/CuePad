#if DEBUG
import CueStore
import Foundation

/// 长对话与追加中的对话（验收会话页的滚动，iOS 与 Mac 共用）：
/// - `-CuePadLongChat YES`（配 `-CuePadDemo YES`）：演示库多一个 300 轮的会话 marathon（CuePad 项目），回答高矮悬殊——
///   一句话、整页长段落、40 行代码块、宽表、长列表轮换，每 25 轮你贴进来一段长文；看打开即最新、往上翻、回到最新。
/// - `-CuePadStream YES`（配 session 画面）：打开会话后给它一轮一轮追加（你的话、思考中、回答，高矮轮换），看新内容到达时跟随最新。
/// - `-CuePadBench chatdepth`（仅 iOS，配 session 画面打开 marathon）：测量脚本从最新处一路往上滑到第 1 轮，每排开一段量一次开销与掉帧（`ChatDepthBench`）。
/// - `-CuePadBench chatresize`（仅 Mac，配 session 画面打开 marathon）：测量脚本翻到深处后拖窗口边改宽，每次拖动量一次开销与掉帧（`ChatResizeBench`）。
extension DebugScene {
    static let longChat = "marathon"
    private static let longChatRounds = 300

    static func seedLongChat(_ store: CueStore, project: UUID?) async {
        try? await PiStateRecorder(store: store, hostID: "demo-mac").update(
            sessionID: longChat, state: .settled, title: longChat, folder: longChat, projectID: project)
        let start = Date.now.addingTimeInterval(-Double(longChatRounds) * 240)
        let turns = (0..<longChatRounds).map { round in
            let asked = start.addingTimeInterval(Double(round) * 240)
            return ChatTurn(you: prompt(round), pi: reply(round), tools: nil, asked: asked, answered: asked.addingTimeInterval(60))
        }
        try? await writeChat(longChat, turns, store: store)
    }

    /// 给 `sessionID` 一轮一轮追加，共 `rounds` 轮：你的话 → 思考中 → 回答 → 歇下。
    static func stream(_ sessionID: String, rounds: Int = 12, store: CueStore) async {
        guard let session = try? await store.piSessionPage(PiSessionQuery(id: PiSessionState.recordID(sessionID: sessionID))).items.first?.state else { return }
        let recorder = PiStateRecorder(store: store, hostID: session.hostID)
        func set(_ state: PiWorkState) async {
            try? await recorder.update(sessionID: sessionID, state: state, title: session.title, folder: session.folder, projectID: session.projectID)
        }
        for round in 0..<rounds {
            try? await Task.sleep(for: .seconds(2))
            let you = PiChatMessage(sessionID: sessionID, entryID: "stream-u\(round)", seq: Int64(1_000_000 + round * 2), role: .user, text: prompt(round + 1), at: .now)
            try? await store.writePiTranscript(PiTranscript(sessionID: sessionID, messages: [you], recap: PiRecap(pendingPrompt: you.text)))
            await set(.thinking)
            try? await Task.sleep(for: .seconds(1.5))
            let answer = PiChatMessage(
                sessionID: sessionID, entryID: "stream-p\(round)", seq: Int64(1_000_001 + round * 2), role: .pi, text: reply(round + 1), at: .now,
                roundStartedAt: you.at)
            try? await store.writePiTranscript(PiTranscript(sessionID: sessionID, messages: [answer], recap: PiRecap(lastPrompt: you.text, lastReply: answer.text)))
            await set(.settled)
        }
    }

    private static func prompt(_ round: Int) -> String {
        guard round % 25 != 0 else {
            return "第 \(round) 轮，我把日志贴过来：\n" + (1...30).map { "[\($0)] worker-\($0 % 7) retry=\($0 % 3) 连接被对端重置，正在重连第 \($0) 次" }.joined(separator: "\n")
        }
        return ["继续", "第 \(round) 轮：把上一步的结果整理成表格", "这里为什么会慢？给我看一下热点代码", "好，下一个", "列一下还剩哪些没做"][round % 5]
    }

    private static func reply(_ round: Int) -> String {
        let paragraph = "第 \(round) 轮的回答。调度器在重连时会拿到新的时间戳，所以按加入时间排序会把重连的人排到最前；改成按首次加入时间排序之后，"
            + "重连不再改变顺序，压测里 p95 从 12ms 降到 9ms，内存基本不变。另外两条超时路径还没有用例覆盖，补上之后覆盖率能到 85% 左右。"
        switch round % 6 {
        case 0: return "好的，第 \(round) 轮做完了。"
        case 1: return Array(repeating: paragraph, count: 5).joined(separator: "\n\n")
        case 2: return paragraph + "\n\n```swift\n" + (1...40).map { "let value\($0) = try await compute(\($0), retry: \($0 % 5))" }.joined(separator: "\n") + "\n```"
        case 3:
            return "| 用例 | 结果 | 耗时 | 说明 |\n|:--|:--:|--:|:--|\n"
                + (1...8).map { "| 用例 \($0) | \($0 % 3 == 0 ? "失败" : "通过") | \($0 * 13) ms | 第 \(round) 轮的第 \($0) 个检查 |" }.joined(separator: "\n")
        case 4: return (1...12).map { "- 第 \($0) 项：" + ($0 % 2 == 0 ? "已完成" : "还差一点，等上游合并") }.joined(separator: "\n")
        default: return paragraph
        }
    }
}
#endif

#if os(iOS) && DEBUG
import QuartzCore
import UIKit

/// 长对话一路往上翻到第 1 轮，每排开一段的开销：测量脚本在模拟器上真滑（程序改偏移不算用户滚动），对话每在上面排开一段
/// （`DebugHooks.chatShowsEarlier`）就从那一刻起量 800ms：点击回合、合计、最重一圈（主线程 CPU 毫秒）、指令数（百万）、掉帧。
/// `roundsBack` 是排开后最早一条离最新多少轮（按条目位置算，每轮是你的话与回答两条）；800ms 内又排开一段时上一段提前收（`windowMs`）。
/// 每段一行 `DEPTH {json}` 写进隔离库目录下的 `chatdepth.jsonl`；排开到第 1 条写 `DONE` 退出。
enum ChatDepthBench {
    private static let turns = TurnLog()
    private static var out: URL?
    private static var running: Running?

    private struct Running {
        let recorder: FrameRecorder
        let instructions: Double
        let from: Int
        let count: Int
        let started: CFTimeInterval
        let token = UUID()
    }

    static func run() async {
        guard let dir = ProcessInfo.processInfo.environment["CUEPAD_LIBRARY_DIR"] else { return }
        let out = URL(filePath: dir).appending(path: "chatdepth.jsonl")
        try? Data().write(to: out)
        try? await Task.sleep(for: .seconds(4))
        self.out = out
        write("READY")
    }

    static func began(from item: Int, of count: Int) {
        guard out != nil else { return }
        finish()
        let recorder = FrameRecorder()
        recorder.start()
        let running = Running(recorder: recorder, instructions: instructionsMillions(), from: item, count: count, started: CACurrentMediaTime())
        self.running = running
        turns.begin(running.started, root: nil)
        Task {
            try? await Task.sleep(for: .milliseconds(800))
            if Self.running?.token == running.token { finish() }
        }
    }

    private static func finish() {
        guard let running else { return }
        self.running = nil
        var row = TurnLog.metrics(turns.finish(), instructions: running.instructions, frames: running.recorder.stop())
        ["clickMs", "visibleTurns", "seen", "heavy"].forEach { row[$0] = nil }
        row["roundsBack"] = (running.count - running.from + 1) / 2
        row["windowMs"] = ((CACurrentMediaTime() - running.started) * 1000).rounded()
        write("DEPTH " + String(decoding: try! JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]), as: UTF8.self))
        if running.from == 0 {
            write("DONE")
            exit(0)
        }
    }

    private static func write(_ line: String) {
        guard let out, let handle = try? FileHandle(forWritingTo: out) else { return }
        handle.seekToEndOfFile()
        handle.write(Data((line + "\n").utf8))
        try? handle.close()
    }
}
#endif

#if os(macOS) && DEBUG
import AppKit

/// 长对话翻到深处后拖窗口边改宽的开销：从按住窗口边（开始拖动改大小）量到松手后 500ms：点击回合、合计、最重一圈（主线程 CPU 毫秒）、
/// 指令数（百万）、掉帧。每次拖动一行 `RESIZE {json}` 写进隔离库目录下的 `chatresize.jsonl`。
enum ChatResizeBench {
    private static let turns = TurnLog()
    private static var running: (recorder: FrameRecorder, instructions: Double, started: CFTimeInterval)?

    static func run() async {
        guard let dir = ProcessInfo.processInfo.environment["CUEPAD_LIBRARY_DIR"] else { return }
        let out = URL(filePath: dir).appending(path: "chatresize.jsonl")
        try? Data("READY\n".utf8).write(to: out)
        let center = NotificationCenter.default
        for await note in center.notifications(named: NSWindow.willStartLiveResizeNotification) {
            guard let view = (note.object as? NSWindow)?.contentView else { continue }
            begin(view)
            for await _ in center.notifications(named: NSWindow.didEndLiveResizeNotification).prefix(1).map({ _ in () }) {}
            try? await Task.sleep(for: .milliseconds(500))
            finish(out)
        }
    }

    private static func begin(_ view: NSView) {
        let recorder = FrameRecorder()
        recorder.start(in: view)
        let started = CACurrentMediaTime()
        running = (recorder, instructionsMillions(), started)
        turns.begin(started, root: nil)
    }

    private static func finish(_ out: URL) {
        guard let running else { return }
        self.running = nil
        var row = TurnLog.metrics(turns.finish(), instructions: running.instructions, frames: running.recorder.stop())
        ["clickMs", "visibleTurns", "seen", "heavy"].forEach { row[$0] = nil }
        row["windowMs"] = ((CACurrentMediaTime() - running.started) * 1000).rounded()
        guard let handle = try? FileHandle(forWritingTo: out) else { return }
        handle.seekToEndOfFile()
        handle.write(Data(("RESIZE " + String(decoding: try! JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]), as: UTF8.self) + "\n").utf8))
        try? handle.close()
    }
}
#endif
