#if os(macOS)
import CuePi
import CueStore
import Foundation

/// Mac 端的远程职责：把 Pi 会话的状态写成同步记录（手机据此显示 Pi 在干什么）与目录绑定。
extension AppServices {
    // MARK: Pi 状态记录

    /// 这台 Mac 启动（`init` 里，第一次读库之前）：对账上次留下的会话记录（别的 Mac 的不动）并写下在线（`CueStore.launchMac`）——
    /// 进程确实没了的收尾，还在的留给桥重新连上；对账之前还没收尾的会话交给桥：重新接上时状态种类没变就沿用原来的起点（`PiBridge.attach`）。
    static func launch(_ store: CueStore, on host: String, bridge: PiBridge) throws {
        bridge.carryOver(try store.launchMac(host: host) { $0.isRunning })
    }

    /// 把 Pi 桥的会话变化写成同步记录，直到流结束（规则在 `PiSessionMirror`）；没名字的会话顺带起名（`SessionNamer`）。
    func consumePiChanges(_ changes: AsyncStream<PiSessionChange>) async throws {
        var mirror = PiSessionMirror(recorder: piStateRecorder)
        let namer = SessionNamer(bridge: pi, store: store)
        for await change in changes {
            if let alerted = try await mirror.apply(change) {
                // 带通知标志的写入立即上传（不阻塞后面的会话变化）：排在其余待推送后面要多等，期间状态还可能前进而把它作废
                let record = PiSessionState.recordID(sessionID: alerted)
                Task { await upload(record) }
            }
            switch change {
            case .appeared(let session), .stateChanged(let session, _), .infoChanged(let session): namer.consider(session)
            default: break
            }
        }
    }

    // MARK: 目录绑定

    /// 本机的目录绑定写成同步的目录绑定记录（手机据此知道哪些项目能在哪台 Mac 上开新会话）：先对一次，
    /// 之后本机绑定每次变化时跟上，直到后台任务取消。
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
