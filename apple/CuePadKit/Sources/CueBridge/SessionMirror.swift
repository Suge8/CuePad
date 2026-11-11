#if os(macOS)
import CueStore
import Foundation

/// 一个会话一条记录：同一会话同时有两个进程时，记录跟着其中一个；
/// 其中一个结束而另一个还在时，记录不标为结束，换由还在的那个写。进程都退出时怎么收尾（历史、歇着、删除）只由 `StateRecorder.exited` 定，
/// 重载扩展（`SessionEndReason.reload`）不是退出：同一进程马上以新扩展连回来接着写。
/// 标题：会话自己报了名字或首条消息就用它的，否则用会话索引里的（接上的老会话在第一句话之前就有标题，不必去读会话文件）。
/// 正自己换上新扩展的（`Session.upgrading`）读不到在做什么，不写：记录留着上一次读到的样子，退出时据此分清是不是做到一半被打断。
public struct SessionMirror {
    private let recorder: StateRecorder
    private var live: [Session.ID: Session] = [:]
    private var store: CueStore { recorder.store }

    public init(recorder: StateRecorder) {
        self.recorder = recorder
    }

    /// 返回这次写入置位了通知标志的会话（`SessionState.sessionID`）：调用方立即上传那一条，通知不排在其余待推送后面。
    public mutating func apply(_ change: SessionChange) async throws -> String? {
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

    private func owner(of sessionID: String) -> Session? {
        live.values.first { $0.sessionID == sessionID }
    }

    private func record(_ session: Session) async throws -> String? {
        guard !session.upgrading else { return nil }
        let title = session.name != nil || session.firstMessage != nil
            ? session.displayName : try await store.indexedSession(session.sessionID)?.title ?? session.displayName
        let snapshot = session.snapshot(title: title, projectID: try await store.project(containing: session.cwd)?.id)
        return try await recorder.update(snapshot) == nil ? nil : session.sessionID
    }
}
#endif
