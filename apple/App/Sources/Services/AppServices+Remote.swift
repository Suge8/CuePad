#if os(macOS)
import CueBridge
import CueStore
import Foundation

extension AppServices {

    static func launch(_ store: CueStore, on host: String, bridge: Bridge) throws {
        bridge.carryOver(try store.launchMac(host: host) { $0.isRunning })
    }

    func consumeSessionChanges(_ changes: AsyncStream<SessionChange>) async throws {
        var mirror = SessionMirror(recorder: stateRecorder)
        let namer = SessionNamer(bridge: bridge, store: store)
        for await change in changes {
            try await mirror.apply(change)
            switch change {
            case .appeared(let session), .stateChanged(let session, _), .infoChanged(let session): namer.consider(session)
            default: break
            }
        }
    }


    func startDirectoryBindings() async throws {
        let host = hostID
        try await store.publishDirectoryBindings(host: host)
        let changes = store.observe { try $0.projectDirectories() }
        follow(reporting: { .syncUnavailable(String(localized: "目录绑定没能同步给手机：\(String(describing: $0))")) }) { [store] in
            for try await _ in changes { try await store.publishDirectoryBindings(host: host) }
        }
    }
}
#endif
