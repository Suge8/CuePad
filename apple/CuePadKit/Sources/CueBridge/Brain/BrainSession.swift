#if os(macOS)
import CueAgent
import CueStore
import Foundation

@MainActor
final class BrainSession {
    let events: AsyncStream<TurnEvent>
    private let emitter: AsyncStream<TurnEvent>.Continuation
    private let agent: AgentKind
    private var directory: URL?
    private var ended = false

    init(agent: AgentKind) {
        self.agent = agent
        (events, emitter) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
    }

    func emit(_ event: TurnEvent) {
        if case .tool(let id, let name, let arguments) = event {
            emitter.yield(.tool(id: id, name: CueMCPServer.bareName(name, on: agent), arguments: arguments))
        } else {
            emitter.yield(event)
        }
    }

    func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "cue-brain-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        self.directory = directory
        return directory
    }

    func exited(_ reason: ShownText?) {
        guard !ended else { return }
        ended = true
        if let directory { try? FileManager.default.removeItem(at: directory) }
        emitter.yield(.exited(reason))
        emitter.finish()
    }

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
