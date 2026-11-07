#if os(macOS)
@testable import CueStore
import CueTestSupport
import Foundation
import Testing
@testable import CuePad

/// 新会话提交的流程与规则验证（视图订阅与到点刷新另做交互验收）：输入框任何情况下都不会一直锁住（`LaunchProgress.locksInput`）：只在有期限的等待里锁，期限一过解锁、说明结果，可以再开。
/// "手机"开新会话走新会话输入框调的同一条 `launchSession`；那台 Mac 写回什么由服务器的回声给。
@MainActor
struct LaunchLockTests {
    let clock = ManualTiming()
    private let month = Duration.seconds(30 * 86_400)

    private func launch(_ phone: TestApp, replacing previous: SessionLaunch? = nil) async throws -> SessionLaunch {
        try await Workspace(services: phone.services).launchSession(
            in: Project.defaultID, prompt: "hi", title: "CuePad", on: "mac-gone", card: nil, agent: .pi, replacing: previous?.request)
    }

    /// 服务器收下（回声）；`status` 给了就同时带上那台 Mac 写回的状态。
    private func serverHas(_ phone: TestApp, _ launch: SessionLaunch, status: String? = nil) async throws {
        var row = try #require(try await phone.services.store.syncRow(recordName: launch.request.uuidString.lowercased()))
        if let status {
            let stamp = Int64(clock.now.timeIntervalSince1970 * 1000)
            row.fields["status"] = .text(status)
            row.fields["handledBy"] = .text("mac-gone")
            row.fields["completedAt"] = .int(stamp)
            row.fields["modifiedAt"] = .int(row.modifiedAt + 1000)
        }
        #expect(try await phone.services.store.applyRemote([.save(row, systemFields: Data(), serverAt: clock.now)]).isEmpty)
    }

    /// 输入框此刻锁不锁、显示什么（`NewSessionInput` 读的同一份进度）。
    private func shown(_ phone: TestApp, _ launch: SessionLaunch) async throws -> (locked: Bool, phase: LaunchProgress.Phase) {
        var progress: LaunchProgress?
        for try await next in phone.services.store.observe({ try launch.progress(from: $0) }) { progress = next; break }
        let moment = Speech.Moment.always(at: clock.now)
        return (LaunchProgress.locksInput(sending: false, launched: launch, progress: progress, at: moment), try #require(progress).phase(at: moment))
    }

    @Test func 离线一直没传上去_不锁_再开时撤回它() async throws {
        let phone = TestApp(timing: clock.timing, host: "phone")
        defer { phone.services.cancelBackgroundWork() }
        let first = try await launch(phone)
        clock.advance(month)
        #expect(try await !shown(phone, first).locked, "没有期限的等待不锁")
        let second = try await launch(phone, replacing: first)
        #expect(try await phone.services.store.deliveryRequests().map(\.id) == [second.request], "再开时撤回还没交出去的那条，不会开出两个")
    }

    @Test func 服务器收下了_那台Mac一直没应答_期限内锁_过了解锁说未确认() async throws {
        let phone = TestApp(timing: clock.timing, host: "phone")
        defer { phone.services.cancelBackgroundWork() }
        let first = try await launch(phone)
        try await serverHas(phone, first)
        clock.advance(.seconds(DeliveryRequest.phaseLimit))
        #expect(try await shown(phone, first).locked, "派发期限内锁着")
        clock.advance(.seconds(Speech.receiptLimit + 1))
        let late = try await shown(phone, first)
        #expect(!late.locked)
        #expect(late.phase == .unconfirmed(Speech.unconfirmedReason.text))
    }

    @Test func Mac写回开好了_会话一直没连上_等连上有期限() async throws {
        let phone = TestApp(timing: clock.timing, host: "phone")
        defer { phone.services.cancelBackgroundWork() }
        let first = try await launch(phone)
        try await serverHas(phone, first, status: DeliveryStatus.succeeded.rawValue)
        let opening = try await shown(phone, first)
        #expect(opening.locked && opening.phase == .opening)
        clock.advance(.seconds(LaunchProgress.openingLimit + 1))
        let late = try await shown(phone, first)
        #expect(!late.locked)
        #expect(late.phase == .unconfirmed(LaunchProgress.notConnected))
        clock.advance(month)
        #expect(try await !shown(phone, first).locked)
    }

    @Test func Mac写回未确认_解锁说未确认() async throws {
        let phone = TestApp(timing: clock.timing, host: "phone")
        defer { phone.services.cancelBackgroundWork() }
        let first = try await launch(phone)
        try await serverHas(phone, first, status: DeliveryStatus.unconfirmed.rawValue)
        let shown = try await shown(phone, first)
        #expect(!shown.locked)
        guard case .unconfirmed = shown.phase else { Issue.record("应显示结果没确认，是 \(shown.phase)"); return }
        let second = try await launch(phone, replacing: first)
        #expect(Set(try await phone.services.store.deliveryRequests().map(\.id)) == [first.request, second.request], "可能已经开了的那条留着，不假装撤回")
    }
}
#endif
