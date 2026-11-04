#if os(macOS)
import CueAgent
import CuePi
@testable import CueStore
import CueTestSupport
import Darwin
import Foundation
import Testing
@testable import CuePad

/// 交出去的你的话最终答上、只答一次：收尾那一刻插进去的、停用与崩溃时没答上的。
extension CueHostTests {
    /// 收尾那一刻追问：会话的动静叫醒的那一轮在 Pi 里已收尾、还没报出来时你说一句，这台 Mac 以为那一轮还在跑、把话插进去，
    /// Pi 报完收尾另开一轮接走它。这句在接走它的那一轮得到回答、只答一次；叫醒的那一轮最后的话不当成回答你写进对话。
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
        try rig.releaseSettle()
        try await rig.message(.cue, containing: "收到：第二句")
        try await eventually("Cue 歇下") { try await rig.store.cueState()?.state == .known(.settled) }
        #expect(try await rig.count("登录页那边歇下了") == 1)
        #expect(try await rig.count("收到：第二句") == 1)
        #expect(try await rig.count("办好了") == 0, "叫醒的那一轮没接走这句")
        await rig.stop()
    }

    /// 收尾那一刻改规矩又追问：叫醒的那一轮在 Pi 里已收尾、还没报出来时你钉上一条、再说一句，两句都插给了以为在跑的那一轮。
    /// 规矩一变这一轮做完就换班次：插进去的规矩不另开一轮、不写进对话，新班次照新规矩；你那句没被接走，退回交给新班次，只答一次。
    @Test func 收尾那一刻改规矩又追问_这句换班次后只答一次_规矩照样生效() async throws {
        let rig = try await Rig(settleGate: true)
        let held = try rig.armSettle()
        let remote = try await rig.remoteMac()
        try await remote.update(sessionID: "remote-1", state: .thinking, title: "修好登录页", turnStartedAt: .now)
        try await remote.update(sessionID: "remote-1", state: .settled)
        try await rig.answered("remote-1")
        try await held()
        let line = try await rig.store.noteCueLine("推送前先问我", source: .you).line
        Workspace(services: rig.services).pinCueLine(line.id, true)
        try await rig.handed("一直记着（刚改了")
        try await rig.say("第二句")
        try await rig.handed("第二句")
        try rig.releaseSettle()
        try await rig.message(.cue, containing: "收到：第二句")
        try await eventually("Cue 歇下") { try await rig.store.cueState()?.state == .known(.settled) }
        #expect(try await rig.count("收到：第二句") == 1)
        #expect(try await rig.count("这一轮照新规矩") == 0, "插进去的规矩不写进对话")
        try await rig.say("一直记着什么")
        let answer = try await rig.message(.cue, containing: "一直记着：")
        #expect(answer.text.contains("推送前先问我"))
        #expect(try await rig.count("登录页那边歇下了") == 1)
        await rig.stop()
    }

    /// 一轮还没答完你就停用 Cue（App 退出同一条路）：交出去没答上的那句退回没送达，再启用时重新交给它、只答一次。
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

    /// 一轮还没答完 App 就崩溃（没走到收尾）：磁盘上留着的是那句已送达、进度里记着它没答上。再值班时退回、重新交给它并答上。
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
}
#endif
