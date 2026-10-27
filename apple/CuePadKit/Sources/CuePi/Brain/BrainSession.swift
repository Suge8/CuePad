#if os(macOS)
import CueStore
import Foundation

/// 各家大脑共用的部分：事件流、本次运行的临时目录（系统提示等）、给运行时的环境。进程与协议各家用接入里的那一份
/// （`ChildProcess`、`CodexRPC`、`ClaudeStream`、`OpenCodeClient`）。
@MainActor
final class BrainSession {
    let events: AsyncStream<TurnEvent>
    private let emitter: AsyncStream<TurnEvent>.Continuation
    private var directory: URL?
    private var ended = false

    init() {
        (events, emitter) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
    }

    func emit(_ event: TurnEvent) {
        emitter.yield(event)
    }

    /// 本次运行的临时目录（只有自己能读）。
    func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "cue-brain-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        self.directory = directory
        return directory
    }

    /// 进程退出（`reason` 为 nil 是 `stop()` 让它退的）：删掉临时目录，发 `exited` 并结束事件流。只算第一次。
    func exited(_ reason: ShownText?) {
        guard !ended else { return }
        ended = true
        if let directory { try? FileManager.default.removeItem(at: directory) }
        emitter.yield(.exited(reason))
        emitter.finish()
    }

    /// 起不来（握手失败等）：停掉已起的进程、收拾干净。调用方拿不到这个大脑，没人能再收拾。
    func abandon(_ stop: () async -> Void) async {
        await stop()
        exited(nil)
    }

    /// 运行时的环境：CuePad 自己的环境加上配置给的与 `extra`，PATH 按 `ExecutableLocator.environment` 的规则（配置给的 PATH 已是找到它的那组目录）。
    static func environment(_ config: CueBrainConfig, _ extra: [String: String] = [:]) -> [String: String] {
        ExecutableLocator(searchDirectories: []).environment(launching: config.executable, overrides: config.environment.merging(extra) { $1 })
    }
}

/// 工具结果里的文字：字符串原样，内容块（`[{"type": "text", "text": …}]`，MCP 与 Pi 同形）只取文字块拼起来。
func brainText(_ content: JSONValue?) -> String {
    if let text = content?.string { return text }
    return (content?.array ?? []).filter { $0["type"]?.string == "text" }.compactMap { $0["text"]?.string }.joined(separator: "\n")
}

func jsonString(_ object: Any) -> String {
    String(decoding: (try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])) ?? Data(), as: UTF8.self)
}
#endif
