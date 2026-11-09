#if os(macOS)
import CueStore
import Foundation

/// 桥上的会话变化（`PiSessionChange`）写成库里的样子：会话记录与这台 Mac 的额度来源，直到变化流结束。
/// - 一个会话一条记录：同一会话同时有两个进程（后台托管的那个正在让给你在终端里打开的那个）时，记录跟着你的；
///   其中一个结束而另一个还在时，记录不标为结束，换由还在的那个写。进程都退出时怎么收尾（历史、歇着、删除）只由 `PiStateRecorder.exited` 定，
///   重载扩展（`PiSessionEndReason.reload`）不是退出：同一进程马上以新扩展连回来接着写。
/// - 标题：会话自己报了名字或首条消息就用它的，否则用会话索引里的（接上的老会话在第一句话之前就有标题，不必去读会话文件）。
/// - 正自己换上新扩展的（`PiSession.upgrading`）读不到在做什么，不写：记录留着上一次读到的样子，退出时据此分清是不是做到一半被打断。
public struct PiSessionMirror {
    private let recorder: PiStateRecorder
    private var live: [PiSession.ID: PiSession] = [:]
    private var store: CueStore { recorder.store }

    public init(recorder: PiStateRecorder) {
        self.recorder = recorder
    }

    /// 写下一次变化。返回这次写入置位了通知标志的会话（`PiSessionState.sessionID`）：调用方立即上传那一条，通知不排在其余待推送后面。
    public mutating func apply(_ change: PiSessionChange) async throws -> String? {
        switch change {
        case .appeared(let session), .stateChanged(let session, _), .infoChanged(let session):
            let previous = live.updateValue(session, forKey: session.id)
            let alerted = owner(of: session.sessionID)?.id == session.id ? try await record(session) : nil
            if previous?.model != session.model || previous?.availableModels != session.availableModels || previous?.proofs != session.proofs {
                try await store.retainQuotaSources(on: recorder.hostID, live: live.values.map {
                    QuotaWitness(sessionID: $0.sessionID, models: $0.availableModels + [$0.model].compactMap { $0 }, proofs: $0.proofs)
                })
            }
            return alerted
        case .ended(let session, let reason):
            live[session.id] = nil
            if let other = owner(of: session.sessionID) { return try await record(other) }
            if reason != .reload { try await recorder.exited(sessionID: session.sessionID, spoke: session.spoke) }
            return nil
        case .quota(let report):
            try await store.recordQuota(report, host: recorder.hostID, proofs: live.values.flatMap(\.proofs))
            return nil
        case .incompatible:
            return nil
        }
    }

    private func owner(of sessionID: String) -> PiSession? {
        let processes = live.values.filter { $0.sessionID == sessionID }
        return processes.first { !$0.hosted } ?? processes.first
    }

    private func record(_ session: PiSession) async throws -> String? {
        guard !session.upgrading else { return nil }
        let title = session.name != nil || session.firstMessage != nil
            ? session.displayName : try await store.piSession(session.sessionID)?.title ?? session.displayName
        let snapshot = session.snapshot(title: title, projectID: try await store.project(containing: session.cwd)?.id)
        return try await recorder.update(snapshot) == nil ? nil : session.sessionID
    }
}
#endif
