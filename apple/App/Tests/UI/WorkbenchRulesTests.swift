import CueStore
import Foundation
import Testing
@testable import CuePad

/// 项目页的纯规则：工作集卡片墙、"更早"分组、Pi 会话归项目。规格见 docs/development.md「视觉」。
struct WallTests {
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        calendar.firstWeekday = 2
        return calendar
    }()

    let project = UUID()
    /// 2026-09-30（周三）15:00，上海时间。
    let now = WallTests.date(2026, 9, 30, hour: 15)

    static func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    func card(daysAgo: Double, sent: Bool = false, pinned: Bool = false, id: UUID = UUID()) -> CardStamp {
        let modified = now.addingTimeInterval(-daysAgo * 86_400)
        return CardStamp(id: id, modifiedAt: modified, lastSentAt: sent ? modified : nil, isPinned: pinned)
    }

    func arrange(_ cards: [CardStamp], at time: Date? = nil) -> WallArrangement {
        WallArrangement.arrange(cards, project: project, now: time ?? now)
    }

    // MARK: 上墙

    @Test func 两周内编辑的上墙_一个月内编辑且从未发送的上墙_其余进更早() {
        let recentSent = card(daysAgo: 3, sent: true)
        let unsent = card(daysAgo: 20)
        let oldSent = card(daysAgo: 20, sent: true)
        let stale = card(daysAgo: 40)

        let wall = arrange([stale, oldSent, unsent, recentSent])

        #expect(wall.wall == [recentSent.id, unsent.id])
        #expect(wall.older == [oldSent.id, stale.id])
    }

    @Test func 墙按最近编辑排序且有名额_超出的进更早() {
        let cards = (0..<(WallArrangement.capacity + 2)).map { card(daysAgo: Double($0) * 0.5) }

        let wall = arrange(cards.shuffled())

        #expect(wall.wall == cards.prefix(WallArrangement.capacity).map(\.id))
        #expect(wall.older == cards.suffix(2).map(\.id))
    }

    @Test func 置顶卡单列_无论多旧都在_不占墙名额() {
        let pinnedOld = card(daysAgo: 200, pinned: true)
        let recent = (0..<WallArrangement.capacity).map { card(daysAgo: Double($0) * 0.5) }

        let wall = arrange(recent + [pinnedOld])

        #expect(wall.pinned == [pinnedOld.id])
        #expect(wall.wall == recent.map(\.id))
        #expect(wall.older.isEmpty)
    }

    // MARK: 同一次打开里墙不自己挪动

    @Test func 再次编辑的旧卡与新建的卡_回到墙首_最近的在最前() {
        let a = card(daysAgo: 1), old = card(daysAgo: 60)
        let first = arrange([a, old])
        let t1 = now.addingTimeInterval(600), t2 = now.addingTimeInterval(1200)
        let reedited = CardStamp(id: old.id, modifiedAt: t1, lastSentAt: nil, isPinned: false)
        let fresh = CardStamp(id: UUID(), modifiedAt: t2, lastSentAt: nil, isPinned: false)

        let next = first.refreshed(with: [a, reedited, fresh], project: project, now: t2, calendar: Self.calendar)

        #expect(next.wall == [fresh.id, old.id, a.id])
        #expect(next.older.isEmpty)
    }

    @Test func 打开另一个项目或跨天才重排() {
        let a = card(daysAgo: 1), b = card(daysAgo: 2)
        let first = arrange([a, b])
        let later = now.addingTimeInterval(1800)
        let edited = CardStamp(id: b.id, modifiedAt: later, lastSentAt: nil, isPinned: false)

        let otherProject = first.refreshed(with: [a, edited], project: UUID(), now: later, calendar: Self.calendar)
        let nextDay = first.refreshed(
            with: [a, edited], project: project, now: Self.date(2026, 10, 1, hour: 9), calendar: Self.calendar)

        #expect(otherProject.wall == [b.id, a.id])
        #expect(nextDay.wall == [b.id, a.id])
    }

    // MARK: 更早

    @Test func 更早三个月内按周分组_更久按月分组_新的在前() {
        let thisWeekOld = CardStamp(id: UUID(), modifiedAt: Self.date(2026, 9, 1), lastSentAt: nil, isPinned: false)  // 周二
        let sameWeek = CardStamp(id: UUID(), modifiedAt: Self.date(2026, 8, 31), lastSentAt: nil, isPinned: false)  // 周一
        let previousWeek = CardStamp(id: UUID(), modifiedAt: Self.date(2026, 8, 30), lastSentAt: nil, isPinned: false)  // 周日
        let may = CardStamp(id: UUID(), modifiedAt: Self.date(2026, 5, 20), lastSentAt: nil, isPinned: false)
        let mayEarly = CardStamp(id: UUID(), modifiedAt: Self.date(2026, 5, 2), lastSentAt: nil, isPinned: false)
        let april = CardStamp(id: UUID(), modifiedAt: Self.date(2026, 4, 9), lastSentAt: nil, isPinned: false)

        let groups = OlderGroup.group(
            [april, sameWeek, may, previousWeek, mayEarly, thisWeekOld], now: now, calendar: Self.calendar)

        #expect(groups == [
            OlderGroup(period: .week(start: Self.date(2026, 8, 31, hour: 0)), cards: [thisWeekOld.id, sameWeek.id]),
            OlderGroup(period: .sparseMonth(start: Self.date(2026, 8, 1, hour: 0)), cards: [previousWeek.id]),
            OlderGroup(period: .month(start: Self.date(2026, 5, 1, hour: 0)), cards: [may.id, mayEarly.id]),
            OlderGroup(period: .month(start: Self.date(2026, 4, 1, hour: 0)), cards: [april.id]),
        ])
    }

    /// 三个月内，一个月里每周都只有一条时不再一周一个标题（标题比内容还多），这个月并成一组、常开。
    @Test func 更早_每周只有一条的月份并成一组() {
        let sep16 = CardStamp(id: UUID(), modifiedAt: Self.date(2026, 9, 16), lastSentAt: nil, isPinned: false)
        let sep8 = CardStamp(id: UUID(), modifiedAt: Self.date(2026, 9, 8), lastSentAt: nil, isPinned: false)
        let aug13 = CardStamp(id: UUID(), modifiedAt: Self.date(2026, 8, 13), lastSentAt: nil, isPinned: false)
        let aug12 = CardStamp(id: UUID(), modifiedAt: Self.date(2026, 8, 12), lastSentAt: nil, isPinned: false)
        let jul15 = CardStamp(id: UUID(), modifiedAt: Self.date(2026, 7, 15), lastSentAt: nil, isPinned: false)

        let groups = OlderGroup.group([jul15, aug12, sep8, aug13, sep16], now: now, calendar: Self.calendar)

        #expect(groups == [
            OlderGroup(period: .sparseMonth(start: Self.date(2026, 9, 1, hour: 0)), cards: [sep16.id, sep8.id]),
            OlderGroup(period: .week(start: Self.date(2026, 8, 10, hour: 0)), cards: [aug13.id, aug12.id]),
            OlderGroup(period: .sparseMonth(start: Self.date(2026, 7, 1, hour: 0)), cards: [jul15.id]),
        ])
        #expect(groups.allSatisfy { !$0.isMonth })
    }

}

/// "更早"的组标题：只有一组按周的卡时不再套一层日期标题（每行自带日期）；按月的组要标题来折叠。Mac 与 iOS 同一条规则。
struct OlderGroupTitleRuleTests {
    let week = OlderGroup.Period.week(start: Date(timeIntervalSince1970: 0))
    let earlierWeek = OlderGroup.Period.week(start: Date(timeIntervalSince1970: -604_800))
    let month = OlderGroup.Period.month(start: Date(timeIntervalSince1970: -10_000_000))

    @Test func 只有一组按周时不显示组标题_按月或多于一组时显示() {
        #expect(OlderGroup.needsTitles(in: [OlderGroup(period: week, cards: [UUID()])]) == false)
        #expect(OlderGroup.needsTitles(in: [OlderGroup(period: month, cards: [UUID()])]) == true)
        #expect(OlderGroup.needsTitles(in: [OlderGroup(period: week, cards: [UUID()]), OlderGroup(period: earlierWeek, cards: [UUID()])]) == true)
    }
}

/// "更早"的组标题写法：同一年里写"9 月"，跨年才带年份（"2025 年 12 月"），数字两边空一格；周是"8/31 – 9/6"。
struct OlderGroupTitleTextTests {
    let now = WallTests.date(2026, 9, 30, hour: 15)

}

/// Pi 会话副行的"在哪"：绑定了项目写项目名，否则写文件夹名。手机上的会话记录同样带着文件夹名。
@MainActor
struct PiPlaceTests {
}

/// Pi 历史按结束时间分段（手机 Agent 页、Mac ⌘K 共用）：今天 / 昨天 / 本周 / 本月 / 更早，周一为一周之始。
struct PiHistorySectionTests {
    let calendar = WallTests.calendar

    func section(_ date: Date, now: Date) -> PiHistorySection { PiHistorySection.of(date, now: now, calendar: calendar) }

}

/// 回复框的"停止"：只在指挥官自己在跑一轮时给（等子代理时没有这一轮）；停止请求发出后、这一轮歇下前是"正在停止"
/// （Mac 受理只表示收到，真正歇下看状态）；停止没成、或已经是下一轮了，就又能停。
@MainActor
struct StopRulesTests {
    let app = TestApp()

    private func session(_ state: PiWorkState, busySince: Date?) -> PiSessionState {
        PiSessionState(
            id: UUID(), sessionID: "s", hostID: "mac", title: "s", projectID: nil, state: .known(state), detail: nil, folder: nil,
            lastPrompt: nil, lastReply: nil, question: nil, notify: nil, stateSince: .now, busySince: busySince, createdAt: .now, modifiedAt: .now)
    }

    @Test func 只在跑一轮时能停_发出后到歇下前是正在停止_没停成或下一轮又能停() async throws {
        let running = session(.tool, busySince: .now.addingTimeInterval(-60))
        #expect(MacDelivery.canStop(running))
        #expect(MacDelivery.canStop(session(.compacting, busySince: .now)))  // 停止会中止压缩
        #expect(!MacDelivery.canStop(session(.delegating, busySince: .now)))
        #expect(!MacDelivery.canStop(session(.settled, busySince: nil)))
        // 在等你确认：它没在跑，回复框不给停止（答问题在问题卡或回复框里）
        #expect(!MacDelivery.canStop(session(.waitingForUser, busySince: .now)))

        let stop = try await app.services.store.requestStop(of: SendTarget(kind: .piSession, name: "s", ref: "s"), on: "mac")
        #expect(MacDelivery.stopping(running, deliveries: [stop]))
        var accepted = stop
        accepted.status = .known(.succeeded)
        #expect(MacDelivery.stopping(running, deliveries: [accepted]))
        var failed = stop
        failed.status = .known(.failed)
        #expect(!MacDelivery.stopping(running, deliveries: [failed]))
        #expect(!MacDelivery.stopping(session(.tool, busySince: .now.addingTimeInterval(60)), deliveries: [accepted]))
    }
}

/// 会话列表第三行与回复框的规则（手机 Agent 页、Mac 侧栏与详情共用）。
struct PiReplyRulesTests {
    func session(_ state: PiWorkState, reply: String? = nil, question: PiQuestion? = nil) -> PiSessionState {
        let now = Date(timeIntervalSince1970: 1_000)
        return PiSessionState(
            id: UUID(), sessionID: "s", hostID: "mac", title: "s", projectID: nil, state: .known(state), detail: nil, folder: nil,
            lastPrompt: nil, lastReply: reply, question: question, notify: nil, stateSince: now, busySince: nil, createdAt: now, modifiedAt: now)
    }

    /// 等你确认时：文字型问题回复框就是作答框；选择与确认型先在上面作答，这里答不了的不发自由文本。不在等你确认时照常发消息，忙时默认等它做完再说。
    @Test func 回复框按问题类型是作答_先在上面作答_答不了_或照常发消息() {
        let text = PiQuestion(promptID: "p", kind: .text, text: "新分支叫什么？")
        #expect(MacDelivery.reply(to: session(.waitingForUser, question: text)) == .answer(text))
        for kind in [PiQuestionKind.select, .confirm] {
            let question = PiQuestion(promptID: "p", kind: .known(kind), text: "确定吗？", options: ["是", "否"])
            #expect(MacDelivery.reply(to: session(.waitingForUser, question: question)) == .answerAbove)
        }
        let editor = PiQuestion(promptID: nil, kind: .unknown("editor"), text: "编辑提交说明")
        #expect(MacDelivery.reply(to: session(.waitingForUser, question: editor)) == .unanswerable)
        #expect(MacDelivery.reply(to: session(.waitingForUser)) == .unanswerable)

        #expect(Array(MacDelivery.modes(for: session(.thinking)).prefix(2)) == [.followUp, .steer])
        #expect(MacDelivery.reply(to: session(.settled)) == .message(MacDelivery.modes(for: session(.settled))))
        #expect(MacDelivery.reply(to: session(.thinking)) == .message(MacDelivery.modes(for: session(.thinking))))
    }
}
