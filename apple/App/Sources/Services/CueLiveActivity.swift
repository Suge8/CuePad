#if os(iOS)
import ActivityKit
import Foundation
import OSLog

/// iPhone 锁屏与灵动岛上的实时活动（格子进度，内容见 `CueActivityState`）：App 在前台且有在管或等你时开一个（只一个），变了就更新，都没了就结束。
/// 没有服务端，内容只由 App 改：前台时库一变就改；后台靠推送把 App 叫起来——等你类的可见推送带 content-available，与同步区的静默推送一样让 App 拉一次
/// （`IOSAppDelegate`），拉到的变化经小组件快照那同一条观察到这里（`AppServices.startSnapshots`），不另起轮询。推送会被系统合并、被划掉的 App 叫不醒，
/// 所以每份都带过时时刻（写下后 `staleAfter`）：过了还没有新的，卡片变淡、写"x 分钟前"，不装作是新的；回到前台、进后台前按此刻重发一次，过时时刻从那时算。
/// 系统只许前台开启，所以后台读到有事时只改已开着的，回前台时再开。
/// 状态（开着哪一个、发出去的是哪份）只在 actor 里、只在挂起前改：两次调用交错时，后发的那份按发出的先后落在系统里。
actor CueLiveActivity {
    /// 一份写下后多久算过时。
    static let staleAfter: TimeInterval = 15 * 60
    private static let log = Logger(subsystem: "com.sugeh.cuepad", category: "live-activity")

    /// 开着的那一个（`Activity.id`）：只记 id，用时从系统的列表里取，系统的对象不跨隔离带着走。上次运行开着的接着用，多出来的结束。
    private var id: String?
    /// 最近读到的一份与最近发出去的一份。
    private var latest: CueActivityState?
    private var sent: CueActivityState?

    init() {
        let running = Activity<CueActivityAttributes>.activities.map(\.id)
        id = running.first
        for extra in running.dropFirst() { Task { await Self.end(extra, nil) } }
    }

    /// 读到新的一份：内容变了才发；`resend` 时一样也发（过时时刻从此刻算）。`foreground`：App 此刻在前台，没开着就开一个。
    func show(_ state: CueActivityState, resend: Bool = false, foreground: Bool) async {
        latest = state
        await apply(resend: resend, foreground: foreground)
    }

    /// 按最近读到的那份重发（回到前台）。
    func resend(foreground: Bool) async { await apply(resend: true, foreground: foreground) }

    private func apply(resend: Bool, foreground: Bool) async {
        guard var state = latest else { return }
        state.at = .now
        guard state.isLive else {
            let ending = id
            (id, sent) = (nil, nil)
            if let ending { await Self.end(ending, ActivityContent(state: state, staleDate: nil)) }
            return
        }
        let content = ActivityContent(state: state, staleDate: state.at.addingTimeInterval(Self.staleAfter))
        if let id, let running = Self.running(id) {
            if !resend, sent?.same(as: state) == true { return }
            sent = state
            await running.update(content)
            return
        }
        // 没开过，或被划掉、被系统结束了：在前台再开一个
        (id, sent) = (nil, nil)
        guard foreground, ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        do {
            id = try Activity.request(attributes: CueActivityAttributes(), content: content).id
            sent = state
        } catch {
            Self.log.error("实时活动没能开启：\(String(describing: error), privacy: .public)")
        }
    }

    private static func running(_ id: String) -> Activity<CueActivityAttributes>? {
        Activity<CueActivityAttributes>.activities.first { $0.id == id && [.active, .stale].contains($0.activityState) }
    }

    private static func end(_ id: String, _ content: ActivityContent<CueActivityState>?) async {
        await running(id)?.end(content, dismissalPolicy: .immediate)
    }
}
#endif
