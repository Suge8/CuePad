#if os(macOS)
import CueAgent
import CuePi
@testable import CueStore
import CueTestSupport
import Darwin
import Foundation
import Testing
@testable import CuePad

extension CueHostTests {
    @Test func 收尾那一刻追问_这句在下一轮得到回答_只答一次() async throws {
        let rig = try await Rig(settleGate: true)
        let held = try rig.armSettle()
        let remote = try await rig.remoteMac()
        try await remote.update(sessionID: "remote-1", state: .thinking, title: "修好登录页", turnStartedAt: .now)
        try await remote.update(sessionID: "remote-1", state: .settled)
        try await rig.answered("remote-1")
        try await held()
        try await rig.say("第二句")
        try await rig.handed("第二句")
        try await rig.releaseSettle()
        try await rig.message(.cue, containing: "收到：第二句")
        try await eventually("Cue 歇下") { try await rig.store.cueState()?.state == .known(.settled) }
        #expect(try await rig.count("登录页那边歇下了") == 1)
        #expect(try await rig.count("收到：第二句") == 1)
        #expect(try await rig.count("办好了") == 0, "叫醒的那一轮没接走这句")
        await rig.stop()
    }

    /// 规矩不插进这一轮：插了模型会回应它、盖掉回复。
    @Test func 收尾那一刻改规矩又追问_这句换班次后只答一次_规矩照样生效() async throws {
        let rig = try await Rig(settleGate: true)
        let held = try rig.armSettle()
        let remote = try await rig.remoteMac()
        try await remote.update(sessionID: "remote-1", state: .thinking, title: "修好登录页", turnStartedAt: .now)
        try await remote.update(sessionID: "remote-1", state: .settled)
        try await rig.answered("remote-1")
        try await held()
        let line = try await rig.store.noteCueLine("推送前先问我", source: .you)
        Workspace(services: rig.services).pinCueLine(line.id, true)
        try await rig.say("第二句")
        try await rig.releaseSettle()
        try await rig.message(.cue, containing: "收到：第二句")
        try await eventually("Cue 歇下") { try await rig.store.cueState()?.state == .known(.settled) }
        #expect(try await rig.count("收到：第二句") == 1)
        #expect(rig.handings(of: "第二句") == 2, "先插给旧班次、退回后再交给新班次")
        try await rig.say("重点有哪些")
        let answer = try await rig.message(.cue, containing: "重点：")
        #expect(answer.text.contains("推送前先问我"))
        #expect(try await rig.count("登录页那边歇下了") == 1)
        await rig.stop()
    }

    @Test func 一轮没答完就停用_那句退回_再启用时答上() async throws {
        let rig = try await Rig()
        try await rig.say("请等我放行")
        try await eventually("这一轮停在模型那里") { rig.model.holding }
        _ = try await rig.store.updateCueProfile { $0.enabledAt = nil }
        try await eventually("那句退回没送达") { try await rig.store.cueMessages().first { $0.text == "请等我放行" }?.deliveredAt == nil }
        rig.model.release()
        let host = TestApp.hostID
        _ = try await rig.store.updateCueProfile { $0.hostID = host; $0.enabledAt = .now }
        try await eventually("再启用后重新交出") { try await rig.store.cueMessages().first { $0.text == "请等我放行" }?.deliveredAt != nil }
        try await eventually("答上了") { rig.model.holding }
        rig.model.release()
        try await rig.message(.cue, containing: "先这样")
        #expect(try await rig.count("先这样") == 1)
        await rig.stop()
    }

    /// 崩溃留下的样子用正常停用后改回去摆出来：进度文件换回停用前的那份，那句再记成已送达。
    @Test func 一轮没答完App就崩溃_那句再值班时答上() async throws {
        let rig = try await Rig()
        try await rig.say("请等我放行")
        try await eventually("这一轮停在模型那里") { rig.model.holding }
        let said = try #require(try await rig.store.cueMessages().first { $0.text == "请等我放行" })
        let progress = rig.app.directory.appending(path: "Library/Cue/keeper.json")
        let crashed = try Data(contentsOf: progress)
        _ = try await rig.store.updateCueProfile { $0.enabledAt = nil }
        try await eventually("停用收尾退回了那句") { try await rig.store.cueMessages().first { $0.id == said.id }?.deliveredAt == nil }
        try await eventually("停用收尾做完、不再写进度") { rig.health == nil }
        rig.model.release()
        try crashed.write(to: progress)
        try await rig.store.markCueMessagesDelivered([said.id])
        let host = TestApp.hostID
        _ = try await rig.store.updateCueProfile { $0.hostID = host; $0.enabledAt = .now }
        try await eventually("再值班时重新交出、停在模型那里") { rig.model.holding }
        rig.model.release()
        try await rig.message(.cue, containing: "先这样")
        #expect(try await rig.count("先这样") == 1)
        await rig.stop()
    }

    /// 触发器拦库写入，同磁盘满、库坏这类真实失败。
    @Test func 退回那句时库写不进_库好了自己再退回_答上一次() async throws {
        let rig = try await Rig(timing: { $0.returnRetry = .milliseconds(300) })
        let first = try #require(rig.brainPIDs.first)
        try await rig.say("请慢慢想")
        try await eventually("请求挂在模型那里") { rig.model.hanging }
        let db = RawDB(rig.services.location.databaseURL)
        try db.exec("CREATE TRIGGER no_return BEFORE UPDATE OF deliveredAt ON cueMessages WHEN new.deliveredAt IS NULL BEGIN SELECT RAISE(ABORT, '写不进'); END;")
        kill(first, SIGKILL)
        try await eventually("新的大脑起好") { !rig.brainPIDs.isEmpty && !rig.brainPIDs.contains(first) && rig.health?.phase == .running }
        try await rig.reconciled()  // 再试退回，又撞上写不进
        #expect(try await rig.count("收到：请慢慢想") == 0)
        try db.exec("DROP TRIGGER no_return;")
        try await rig.message(.cue, containing: "收到：请慢慢想")
        try await eventually("Cue 歇下") { try await rig.store.cueState()?.state == .known(.settled) }
        #expect(try await rig.count("收到：请慢慢想") == 1)
        await rig.stop()
    }

    @Test func 回答写不进库_那句重新交出_库好了答上一次() async throws {
        let rig = try await Rig()
        let db = RawDB(rig.services.location.databaseURL)
        try db.exec("CREATE TRIGGER no_reply BEFORE INSERT ON cueMessages WHEN new.author = 'cue' BEGIN SELECT RAISE(ABORT, '写不进'); END;")
        try await rig.say("第一句")
        try await eventually("回答没写成、那句又交了一次") { rig.rounds.filter { $0.sent.contains { $0.contains("第一句") } }.count >= 2 }
        try db.exec("DROP TRIGGER no_reply;")
        try await rig.message(.cue, containing: "收到：第一句")
        try await eventually("Cue 歇下") { try await rig.store.cueState()?.state == .known(.settled) }
        #expect(try await rig.count("收到：第一句") == 1)
        await rig.stop()
    }
}
#endif
