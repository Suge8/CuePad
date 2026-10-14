#if os(macOS)
import CoreGraphics
import Foundation

/// 人在不在这台 Mac 前。接入据此决定确认在哪里答：人在就在 Agent 自己的界面里答，人不在才交给 CuePad（手机通知、远程作答）。
@MainActor
public protocol UserPresence: AnyObject, Sendable {
    var isPresent: Bool { get }
    /// 等到人在（已经在就立刻返回）；任务取消时也返回。
    func untilPresent() async
}

/// 系统的判断：屏幕没锁，且最近 `idleLimit` 内有键盘鼠标操作。操作按硬件层（`.hidSystemState`，与 ioreg 的 HIDIdleTime、
/// 屏保同一口径）算：会话层（`.combinedSessionState`）实测只被合成事件更新，真人在用时反而一直在涨。
@MainActor
public final class SystemPresence: UserPresence {
    public static let idleLimit: TimeInterval = 120
    /// 空闲着等人回来时多久看一次：恢复操作没有系统事件，只在有人等着（`untilPresent`）时看
    private static let returnCheck: Duration = .seconds(1)
    private static let unlocked = Notification.Name("com.apple.screenIsUnlocked")

    public init() {}

    public var isPresent: Bool { !isLocked && idleSeconds < Self.idleLimit }

    public func untilPresent() async {
        while !Task.isCancelled, !isPresent {
            if isLocked {
                // 先订阅再看一次，订阅之前解了锁也不会漏
                let unlocks = DistributedNotificationCenter.default().notifications(named: Self.unlocked)
                guard isLocked else { continue }
                for await _ in unlocks { break }
            } else {
                try? await Task.sleep(for: Self.returnCheck)
            }
        }
    }

    private var isLocked: Bool {
        (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool == true
    }

    private var idleSeconds: TimeInterval {
        CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: CGEventType(rawValue: ~0)!)
    }
}
#endif
