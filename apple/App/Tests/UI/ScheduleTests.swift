import CueStore
import CueTestSupport
import Foundation
import Testing
@testable import CuePad

@MainActor
struct ScheduleTests {
    @Test func 原地改成每周一九点_不再定时就撤掉() async throws {
        let rig = TestApp()
        let store = rig.services.store
        let task = try await store.createTask("清理过期分支")
        let line = try await store.noteCueLine("清理过期分支", source: .cue, remindAt: .now.addingTimeInterval(3600), task: task.id)
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

    @Test func 任务完成_归档_删掉就不再定时_取回也不回来() async throws {
        let rig = TestApp()
        let store = rig.services.store
        let workspace = Workspace(services: rig.services)
        var lines: [UUID] = []
        for title in ["清理过期分支", "续费域名", "周报"] {
            let task = try await store.createTask(title)
            lines.append(try await store.noteCueLine(
                title, source: .cue, remindAt: .now.addingTimeInterval(3600), repeats: CueRepeat(.daily, hour: 9, minute: 0), task: task.id
            ).id)
            switch title {
            case "清理过期分支":
                try await workspace.complete(task.id)
                try await workspace.reopen(task.id)  // 再点一下：重新打开
            case "续费域名":
                try await workspace.archive(task.id)
                try await #require(workspace.notice?.action).run()  // 撤销：取回
            default:
                try await workspace.trash(task.id)
                try await #require(workspace.notice?.action).run()  // 撤销：恢复
            }
        }
        #expect(try await store.cueSchedules().isEmpty)
        for line in lines { #expect(try await store.cueLine(line)?.deletedAt != nil) }
    }

    #if os(macOS)
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

    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: realPi.path), "需要 ~/.local/bin/pi"))
    func 写不成的重复_退回不定() async throws {
        let rig = try await CueHostTests.Rig()
        try await rig.say("请隔天 9 点清理分支")
        try await rig.message(.cue, containing: "办好了")
        #expect(rig.model.answers("（时刻取 at 的）：FREQ=DAILY;INTERVAL=2") == 1)
        #expect(try await rig.store.cueSchedules().isEmpty)
        await rig.stop()
    }

    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: realPi.path), "需要 ~/.local/bin/pi"))
    func 错过的每天定时_启动后只补一次_排到下一次() async throws {
        let start = Date.now.addingTimeInterval(-3 * 86_400 + 3600)
        let missed = Date(timeIntervalSince1970: (start.timeIntervalSince1970 / 60).rounded(.down) * 60)
        let clock = Calendar.current.dateComponents([.hour, .minute], from: missed)
        let daily = try #require(CueRepeat(.daily, hour: clock.hour!, minute: clock.minute!))
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
        let latest = try #require(Calendar.current.date(byAdding: .day, value: 2, to: missed))
        #expect(abs(last.due.timeIntervalSince(latest)) < 1 && last.late)
        try await rig.reconciled()
        #expect(try await rig.store.cueMessages().filter { if case .schedule? = $0.wake { true } else { false } }.count == 1)
        await rig.stop()
    }
    #endif
}
