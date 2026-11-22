import CueStore
import Foundation

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
