#if DEBUG && os(macOS)
import CueStore
import Foundation

extension Session {
    /// 调试画面给一段演示会话挂上的在线会话（App 的 `-CuePadSpeak`）：只用来喂正在说的话。
    public static func demo(sessionID: String, agent: AgentKind, cwd: URL) -> Session {
        Session(id: "\(sessionID).demo", sessionID: sessionID, agent: agent, sessionFile: nil, pid: 1, cwd: cwd, state: .settled, stateSince: .now)
    }
}
#endif
