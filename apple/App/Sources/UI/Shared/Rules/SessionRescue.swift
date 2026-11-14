import CueStore
import Foundation

/// 卡住的会话就地处理的那一件：额度用完去管理用量，出错的重试，上下文快满（`ContextMeter.suggestsCompact`）的压缩。
/// 会话页（`FailureDock`、`ContextGauge`）与看板卡（`BoardRescue`）同读这一份。
nonisolated enum SessionRescue: Equatable {
    case usage(URL), retry, compact

    static func of(_ session: SessionState) -> Self? {
        if let url = session.usageURL { return .usage(url) }
        if session.canRetry { return .retry }
        if session.context.flatMap(ContextMeter.init)?.suggestsCompact == true { return .compact }
        return nil
    }
}

extension Workspace {
    func compact(_ session: SessionState) {
        speak("/compact", to: .session(session, mode: .command))
    }
}
