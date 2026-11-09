#if os(macOS)
@testable import CueStore
import CueTestSupport
import Foundation
import Testing
@testable import CuePad

/// 新会话安全替换与主动重复：编辑、关闭不等回执；第二次副作用须由可撤回事实或用户明确确认授权。
/// "手机"开新会话走新会话输入框调的同一条 `AppServices.launchSession`；那台 Mac 写回什么由服务器的回声给。
@MainActor
struct LaunchLockTests {
    let clock = ManualTiming()
    private let month = Duration.seconds(30 * 86_400)

    private func launch(_ phone: TestApp, replacing previous: SessionLaunch? = nil) async throws -> SessionLaunch {
        try await phone.services.launchSession(
            in: Project.defaultID, prompt: "hi", title: "CuePad", on: "mac-gone", card: nil, agent: .pi, intent: previous.map { .replacing($0.request) } ?? .new)
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

    private func shown(_ phone: TestApp, _ launch: SessionLaunch) async throws -> LaunchProgress.Phase {
        for try await progress in phone.services.store.observe({ try launch.progress(from: $0) }) {
            return progress.phase(at: .always(at: clock.now))
        }
        throw CancellationError()
    }

    @Test func 离线一直没传上去_不锁_再开时撤回它() async throws {
        let phone = TestApp(timing: clock.timing, host: "phone")
        defer { phone.services.cancelBackgroundWork() }
        let first = try await launch(phone)
        clock.advance(month)
        #expect(try await shown(phone, first).submission == .safe, "未上传可安全替换")
        let second = try await launch(phone, replacing: first)
        #expect(try await phone.services.store.deliveryRequests().map(\.id) == [second.request], "再开时撤回还没交出去的那条，不会开出两个")
    }

    @Test func 服务器收下后等待结果_超时再开需要确认() async throws {
        let phone = TestApp(timing: clock.timing, host: "phone")
        defer { phone.services.cancelBackgroundWork() }
        let first = try await launch(phone)
        try await serverHas(phone, first)
        clock.advance(.seconds(DeliveryRequest.phaseLimit))
        #expect(try await shown(phone, first).submission == .waiting)
        clock.advance(.seconds(Speech.receiptLimit + 1))
        let late = try await shown(phone, first)
        #expect(late.submission == .confirm)
        #expect(late == .unconfirmed(Speech.unconfirmedReason.text))
    }

    @Test(arguments: [DeliveryStatus.succeeded.rawValue, DeliveryStatus.unconfirmed.rawValue, "missing"])
    func 未知或已开但未连上_不能安全替换_确认后才另开(status: String) async throws {
        let phone = TestApp(timing: clock.timing, host: "phone")
        defer { phone.services.cancelBackgroundWork() }
        let first = try await launch(phone)
        if status == "missing" { try await phone.services.store.deleteDelivery(first.request) }
        else { try await serverHas(phone, first, status: status) }
        clock.advance(month)
        #expect(try await shown(phone, first).submission == .confirm)
        await #expect(throws: CueStoreError.deliveryAlreadyHanded) { try await launch(phone, replacing: first) }
        let before = try await phone.services.store.deliveryRequests().map(\.id)
        #expect(before == (status == "missing" ? [] : [first.request]))
        let second = try await phone.services.launchSession(
            in: Project.defaultID, prompt: "hi", title: "CuePad", on: "mac-gone", card: nil, agent: .pi,
            intent: .repeatingConfirmed)
        #expect(Set(try await phone.services.store.deliveryRequests().map(\.id)) == Set(before + [second.request]))
    }

    @Test func 上传器已领取旧请求_安全替换不写新请求() async throws {
        let phone = TestApp(timing: clock.timing, host: "phone"), store = phone.services.store
        defer { phone.services.cancelBackgroundWork() }
        let first = try await launch(phone)
        let row = try #require(try await store.syncRow(recordName: first.request.uuidString.lowercased()))
        #expect(try await store.reserveForUpload([(row.id, row.table, row.modifiedAt)]).isEmpty)
        await #expect(throws: CueStoreError.deliveryAlreadyHanded) { try await launch(phone, replacing: first) }
        #expect(try await store.deliveryRequests().map(\.id) == [first.request])
    }

    @Test func 同一条离线请求两次替换_只有一次能写成() async throws {
        let phone = TestApp(timing: clock.timing, host: "phone")
        defer { phone.services.cancelBackgroundWork() }
        let first = try await launch(phone)
        async let left = try? launch(phone, replacing: first)
        async let right = try? launch(phone, replacing: first)
        let launches = await [left, right].compactMap { $0 }
        #expect(launches.count == 1)
        #expect(try await phone.services.store.deliveryRequests().map(\.id) == launches.map(\.request))
    }
}
#endif
