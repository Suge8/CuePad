#if os(macOS)
import CueStore
import Foundation

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

    /// 只有自己能读。
    func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "cue-brain-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        self.directory = directory
        return directory
    }

    /// `reason` 为 nil 是 `stop()` 让它退的；只算第一次。
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
}

func brainText(_ content: JSONValue?) -> String {
    if let text = content?.string { return text }
    return (content?.array ?? []).filter { $0["type"]?.string == "text" }.compactMap { $0["text"]?.string }.joined(separator: "\n")
}

func jsonString(_ object: Any) -> String {
    String(decoding: (try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])) ?? Data(), as: UTF8.self)
}
#endif
