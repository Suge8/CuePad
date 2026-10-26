import CueStore
import CueTestSupport
import Foundation
import Testing
@testable import CuePad

/// 定时（#38）：Cue 的提醒可重复、可挂在任务上，到点开工。按用户走的路写：任务气泡与"记得什么"里原地改、不再定时；任务完成就不再定时；
/// 对 Cue 说一句就建；Mac 没开时错过的，启动后只补一次、排到下一次，那句事实记在叫醒原因上。
@MainActor
struct ScheduleTests {
    /// 任务气泡里点"改"：改成每周一 9:00，改的就是记忆里那一条，下一次是之后最近的周一 9:00；点"不再定时"就从定时里撤掉。
    @Test func 原地改成每周一九点_不再定时就撤掉() async throws {
        let rig = TestApp()
        let store = rig.services.store
        let task = try await store.createTask("清理过期分支")
        let line = try await store.noteCueLine("清理过期分支", source: .cue, remindAt: .now.addingTimeInterval(3600), task: task.id).line
        let workspace = Workspace(services: rig.services)

        var draft = ScheduleDraft(line)
        draft.cycle = .weekly
        draft.weekdays = [2]
        draft.date = try #require(Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: .now))
        workspace.rescheduleCueLine(line.id, draft)
        let changed = try await eventually(store, { try $0.cueSchedules(task: task.id).first?.line }) {
            $0?.repeats == CueRepeat(.weekly([2]), hour: 9, minute: 0)
        }
        let next = try #require(changed?.remindAt)
        let parts = Calendar.current.dateComponents([.weekday, .hour, .minute], from: next)
        #expect(parts.weekday == 2 && parts.hour == 9 && parts.minute == 0)
        #expect(next > .now && next <= .now.addingTimeInterval(7 * 86_400))
        #expect(changed?.text == "清理过期分支")

        workspace.forgetCueLine(line.id)
        _ = try await eventually(store, { try $0.cueSchedules(task: task.id) }) { $0.isEmpty }
    }

    /// 勾掉挂着定时的任务：任务完成就是不再定时。
    @Test func 任务完成就不再定时() async throws {
        let rig = TestApp()
        let store = rig.services.store
        let task = try await store.createTask("清理过期分支")
        let line = try await store.noteCueLine(
            "清理过期分支", source: .cue, remindAt: .now.addingTimeInterval(3600), repeats: CueRepeat(.daily, hour: 9, minute: 0), task: task.id
        ).line
        try await Workspace(services: rig.services).toggle(task.id)
        #expect(try await store.cueSchedules().isEmpty)
        #expect(try await store.cueLine(line.id)?.deletedAt != nil)
    }

    #if os(macOS)
    /// 你对 Cue 说"每周一 9 点清理分支"：它建成挂在那件任务上的每周定时，Cue 页这一轮的经过里一行"新建 定时"。
    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: realPi.path), "需要 ~/.local/bin/pi"))
    func 对Cue说一句_建成挂在任务上的定时() async throws {
        let rig = try await CueHostTests.Rig()
        let task = try await rig.store.createTask("清理过期分支")
        try await rig.say("请每周一 9 点清理分支")
        try await rig.message(.cue, containing: "办好了")
        let schedule = try #require(try await rig.store.cueSchedules().first?.line)
        #expect(schedule.repeats == CueRepeat(.weekly([2]), hour: 9, minute: 0) && schedule.task == task.id)
        let touches = try await rig.store.cueMessages().flatMap { CueActivity.touches($0.tools) }
        #expect(touches.contains { $0.kind == .schedule && $0.name == "清理过期分支" && $0.task == task.id })
        #expect(CueActivity.line(try #require(touches.first { $0.kind == .schedule })) == "新建 定时 清理过期分支")
        await rig.stop()
    }

    /// Mac 关着时错过了好几次每天 9:00 的定时：启动、启用 Cue 后只叫醒一次（定时到点），之后排到下一次；
    /// 那一次错过了、刚补上，任务气泡与"记得什么"读得到这句事实。
    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: realPi.path), "需要 ~/.local/bin/pi"))
    func 错过的每天定时_启动后只补一次_排到下一次() async throws {
        let missed = Date.now.addingTimeInterval(-3 * 86_400)
        let clock = Calendar.current.dateComponents([.hour, .minute], from: missed)
        let daily = CueRepeat(.daily, hour: clock.hour!, minute: clock.minute!)
        let rig = try await CueHostTests.Rig(prepare: { rig in
            _ = try await rig.store.noteCueLine("汇总昨天各项目的进展", source: .you, remindAt: missed, repeats: daily)
        })
        try await rig.message(.cue, containing: "定时到点：")
        let fired = try await rig.store.cueMessages().filter { if case .schedule? = $0.wake { true } else { false } }
        #expect(fired.count == 1)
        let scheduled = try #require(try await eventually(rig.store, { try $0.cueSchedules().first }) { $0?.line.remindAt.map { $0 > .now } == true })
        let next = try #require(scheduled.line.remindAt)
        #expect(next <= .now.addingTimeInterval(86_400))
        #expect(Calendar.current.dateComponents([.hour, .minute], from: next) == DateComponents(hour: clock.hour, minute: clock.minute))
        let last = try #require(scheduled.last)
        #expect(abs(last.due.timeIntervalSince(missed)) < 0.01 && last.late)
        await quietPeriod(.seconds(2))
        #expect(try await rig.store.cueMessages().filter { if case .schedule? = $0.wake { true } else { false } }.count == 1)
        await rig.stop()
    }
    #endif
}
