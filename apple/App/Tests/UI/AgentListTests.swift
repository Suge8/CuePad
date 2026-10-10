import CueStore
import Foundation
import Testing
@testable import CuePad

/// 会话列表的规则（真实数据挑刺报告第六节）：需要 /reload 的会话是维护、不是要你动手——排在工作中之后、不带彩色，
/// 两个以上合成一行；时间全 App 一种写法，几小时前的事粗到小时，一天以上写昨天、星期、日期。
@MainActor
struct AgentListTests {
    private func session(_ id: String, _ state: PiWorkState) -> PiSessionState {
        PiSessionState(
            id: UUID(), sessionID: id, hostID: "mac", title: id, projectID: nil, state: .known(state), detail: nil, folder: nil,
            lastPrompt: "做一下", lastReply: "好了", question: nil, notify: nil, stateSince: .now, busySince: nil, createdAt: .now,
            modifiedAt: .now)
    }

    @Test func 需要reload排在工作中之后_不带彩色_两个以上合成一行() {
        let sessions = PiSessionState.inListOrder([
            session("old1", .incompatible), session("idle", .settled), session("work", .thinking), session("old2", .incompatible),
            session("ask", .waitingForUser),
        ])
        #expect(sessions.map(\.sessionID) == ["ask", "work", "old1", "old2", "idle"])
        #expect(!PiShown(state: .known(.incompatible)).needsYou)

        let rows = PiNowRow.rows(sessions, state: { $0 })
        #expect(rows.count == 4)
        guard case .reload(let folded) = rows[2] else { Issue.record("第三行应是合成的 /reload 行"); return }
        #expect(folded.map(\.sessionID) == ["old1", "old2"])

        // 只有一个时照常一行
        #expect(PiNowRow.rows([session("old", .incompatible), session("work", .thinking)], state: { $0 }).allSatisfy {
            if case .session = $0 { true } else { false }
        })
    }

    @Test func 时间一种写法_一天内粗到小时_再往前写昨天星期日期() {
        let calendar = WallTests.calendar
        let now = WallTests.date(2026, 10, 7, hour: 15)  // 周三
        func label(_ date: Date) -> String { DateLabel.short(date, now: now, calendar: calendar) }
        #expect(label(now.addingTimeInterval(-30)) == "刚刚")
        #expect(label(now.addingTimeInterval(-5 * 60 - 10)) == "5 分钟前")
        #expect(label(now.addingTimeInterval(-(7 * 3600 + 41 * 60))) == "7 小时前")
        #expect(label(WallTests.date(2026, 10, 6, hour: 9)) == "昨天")
        #expect(label(WallTests.date(2026, 10, 5, hour: 9)) == "周一")
        #expect(label(WallTests.date(2026, 9, 5)) == "9/5")
        #expect(label(WallTests.date(2025, 9, 5)) == "2025/9/5")

        // 会话的"多久前"与计时同一粒度
        #expect(PiClock.ago(now.addingTimeInterval(-(11 * 3600 + 48 * 60))).text(now: now, calendar: calendar) == "11 小时前")
        #expect(PiClock.running(since: now.addingTimeInterval(-(2 * 3600 + 5 * 60))).text(now: now, calendar: calendar) == "运行了 2 小时")
        // 列表里只到分钟、第一分钟不每秒换字；只有会话页顶栏到秒
        #expect(PiClock.waiting(since: now.addingTimeInterval(-42)).text(now: now) == "刚开始等")
        #expect(PiClock.waiting(since: now.addingTimeInterval(-42)).text(now: now, precision: .second) == "等了 42 秒")
        #expect(PiClock.waiting(since: now.addingTimeInterval(-3 * 60 - 5)).text(now: now) == "等了 3 分钟")
        #expect(PiClock.running(since: now.addingTimeInterval(-42)).text(now: now) == "刚开始")
        #expect(PiClock.running(since: now.addingTimeInterval(-4 * 60)).text(now: now) == "运行了 4 分钟")
        #expect(PiClock.sent(since: now.addingTimeInterval(-42)).text(now: now) == "刚发出")
        #expect(PiClock.sent(since: now.addingTimeInterval(-7 * 60 - 3)).text(now: now) == "7 分钟前发出")
        #expect(PiClock.running(since: now.addingTimeInterval(-42)).live(.minute).discreteInput(after: now) == now.addingTimeInterval(18))
        #expect(PiClock.running(since: now.addingTimeInterval(-42)).live(.second).discreteInput(after: now) == now.addingTimeInterval(1))
    }
}
