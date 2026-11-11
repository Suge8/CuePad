#if os(macOS)
import CueBridge
import CueStore
import Foundation

extension AppServices {

    /// `init` 里、第一次读库之前调用。进程确实没了的收尾，还在的留给桥重新连上；重新接上时状态种类没变就沿用原来的起点（`Bridge.attach`）。
    static func launch(_ store: CueStore, on host: String, bridge: Bridge) throws {
        bridge.carryOver(try store.launchMac(host: host) { $0.isRunning })
    }

    func consumePiChanges(_ changes: AsyncStream<SessionChange>) async throws {
        var mirror = SessionMirror(recorder: piStateRecorder)
        let namer = SessionNamer(bridge: pi, store: store)
        for await change in changes {
            if let alerted = try await mirror.apply(change) {
                // 带通知标志的写入立即上传（不阻塞后面的会话变化）：排在其余待推送后面要多等，期间状态还可能前进而把它作废
                let record = SessionState.recordID(sessionID: alerted)
                Task { await upload(record) }
            }
            switch change {
            case .appeared(let session), .stateChanged(let session, _), .infoChanged(let session): namer.consider(session)
            default: break
            }
        }
    }


    /// 手机据此知道哪些项目能在哪台 Mac 上开新会话。
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
