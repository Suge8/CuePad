import CueStore
import CueSync
import CueTestSupport
import Foundation
import SwiftUI
import Testing
@testable import CuePad

/// 说出去的话等回执：到哪了只看记录、此刻与本机同步从什么时候起通着（`Speech`，App 一处刷新"此刻"，`SpeechClock`）。
/// 时间用手动推进的钟：到点翻状态靠 App 自己的那一次睡眠，不靠测试去重读。会话在 mac-b、Cue 住在 mac-cue，都要经同步。
@MainActor
struct ReceiptTests {
    let clock = ManualTiming()
    let app: TestApp
    var services: AppServices { app.services }
    var store: CueStore { app.services.store }

    init() { app = TestApp(timing: clock.timing) }

    private func start() async throws {
        services.startSync()
        services.startSpeechClock()
        services.startLiveSessions()
        try await setSync(.idle)
    }

    private func setSync(_ status: SyncStatus) async throws {
        app.sync.emit(SyncState(status: status, issues: []))
        try await eventually("同步状态 \(status)") { services.syncStatus == status }
    }

    private func session(_ id: String = "atlas", state: PiWorkState = .settled, question: PiQuestion? = nil) async throws -> PiSessionState {
        let recorder = PiStateRecorder(store: store, hostID: "mac-b")
        try await recorder.update(sessionID: id, state: .thinking, title: id)
        try await recorder.update(sessionID: id, state: state, question: question)
        return try #require(try await store.allPiSessionStates().first { $0.sessionID == id })
    }

    private func enableCue() async throws {
        _ = try await store.updateCueProfile {
            $0.hostID = "mac-cue"
            $0.enabledAt = .now
        }
    }

    private func sayToCue(_ workspace: Workspace, _ text: String) async throws -> CueMessage {
        workspace.cue.draft = ComposerDraft(text: text)
        await workspace.speak(to: .cue, from: Bindable(workspace.cue).draft) { try $0.stored(in: store.files) }?.value
        return try #require(try await store.cueMessages().last { $0.author == .known(.you) })
    }

    private func sayToSession(_ workspace: Workspace, _ target: PiSessionState, _ text: String) async throws -> DeliveryRequest {
        let box = services.settings.replyDraftBinding(for: target.id)
        box.wrappedValue = ComposerDraft(text: text)
        await workspace.speak(to: .session(target, mode: .send), from: box) { try $0.stored(in: store.files) }?.value
        return try #require(try await store.deliveryRequests().last)
    }

    /// 让 App 的那一次睡眠醒来：等它睡下再拨钟，再等"此刻"跟上。
    private func advance(_ seconds: TimeInterval) async throws {
        await clock.waitForSleeper()
        let target = clock.now.addingTimeInterval(seconds)
        clock.advance(.seconds(seconds))
        try await eventually("此刻跟上") { services.speech.now >= target || clock.sleeperCount > 0 }
    }

    private func cuePresence() async throws -> CuePresence {
        let moment = services.speech
        return CuePresence.derive(try await CueDigest.read(from: store), at: moment)
    }

    private func row(_ id: String) -> PiShown? {
        services.liveSessions.live.first { $0.state.sessionID == id }.map(Workspace(services: services).shown)
    }

    /// 断网时说的话（对 Cue、对会话）当场是"同步不通"，等多久都不说 Mac 迟迟没收下、不说 Cue 在睡觉。断网超过手机主动拉取的
    /// 两分钟窗口后恢复：立即同步一次（交回引擎的记录当场传出、回执当场拉回），主动拉取重开一个窗口；时限从恢复那一刻重新算。
    /// 传出与回执经同步走完一圈见 CueSync 的 DeviceFlowTests（断网写下的请求恢复后到 Mac、结果回到手机）。
    @Test(.timeLimit(.minutes(1)))
    func 断网时说的话_报同步不通不报没回应_恢复后立即同步并重开拉取_时限重算() async throws {
        try await enableCue()
        let target = try await session()
        try await start()
        services.startPolling()
        let workspace = Workspace(services: services)

        try await setSync(.offline)
        try await eventually("断网") { services.speech.reachableSince == nil }
        let toCue = try await sayToCue(workspace, "顺便看看登录回调")
        let toSession = try await sayToSession(workspace, target, "改完再跑一遍")
        func trips() async throws -> [Speech.Trip] {
            let message = try #require(try await store.cueMessages().first { $0.id == toCue.id })
            let request = try #require(try await store.deliveryRequest(toSession.id))
            return [Said.cue(message, host: "mac-cue").trip(at: services.speech), Said.request(request).trip(at: services.speech)]
        }

        #expect(try await trips() == [.failed(.offline), .failed(.offline)])
        try await eventually("会话行是没能送达") { row("atlas")?.undelivered == .offline }
        #expect(services.liveSessions.undelivered["atlas"] == 1)
        #expect(try await cuePresence() != .asleep)

        // 断网两分钟多：拉取的窗口走完（手机）；断网时没有在等的时限，说法不变
        try await eventually("在等回执时按节奏拉") { app.sync.syncNows > 0 }
        await clock.waitForSleeper()
        clock.advance(.seconds(121))
        #if os(iOS)
        try await eventually("拉取窗口走完") { clock.sleeperCount == 0 }  // 醒来时已过两分钟，不再拉
        #else
        try await eventually("拉取醒来又睡下") { app.sync.syncNows > 1 && clock.sleeperCount > 0 }  // Mac 在等就一直拉
        #endif
        #expect(try await trips() == [.failed(.offline), .failed(.offline)])
        let syncs = app.sync.syncNows

        try await store.recordMacPresence(host: "mac-cue") { true }  // Cue 那台醒着（断网时没同步来，本机不说它在睡觉）
        try await setSync(.idle)
        try await eventually("恢复") { services.speech.reachableSince != nil }
        // 钟没动：恢复时立即同步的那一拉也是新窗口的开头，之后按节奏的拉取睡在新窗口的第一个间隔里，不另拉
        try await eventually("恢复时立即同步，拉取重新开始") { app.sync.syncNows == syncs + 1 && clock.sleeperCount > 0 }
        #expect(try await trips() == [.sending, .sending])
        try await eventually("会话行回到发送中") { row("atlas")?.status == .delivery(.inTransit(.sending)) }
        #expect(services.liveSessions.undelivered["atlas"] == nil)

        // 写下已过两个时限，但恢复才 59 秒：还在发送中
        clock.advance(.seconds(Speech.receiptLimit - 1))
        #expect(try await trips() == [.sending, .sending])
        #expect(try await cuePresence() == .sending)
    }

    /// 会话行与"N 句没送到"跟着同一个"此刻"：过了时限没回执，不用重开页面就翻成没能送达。
    @Test(.timeLimit(.minutes(1)))
    func 发给会话的话过了时限没回执_会话行与计数翻成没能送达() async throws {
        let target = try await session()
        try await start()
        let request = try await sayToSession(Workspace(services: services), target, "改完再跑一遍")

        try await eventually("会话行是发送中") { row("atlas")?.status == .delivery(.inTransit(.sending)) }
        #expect(services.liveSessions.undelivered["atlas"] == nil)

        try await advance(Speech.receiptLimit + 1)
        try await eventually("会话行翻成没能送达") { row("atlas")?.undelivered == .timedOut }
        #expect(services.liveSessions.undelivered["atlas"] == 1)
        #expect(row("atlas")?.label == "没能送达")
        #expect(Said.request(try #require(try await store.deliveryRequest(request.id))).trip(at: services.speech) == .failed(.timedOut))
    }
}
