import CloudKit
import CueStore
import Foundation
import Testing

@testable import CueSync

/// 两台设备经假云互相可见：Pi 会话状态（Mac 写、手机读）与投送请求（手机写、Mac 执行并写回结果）。
@Suite struct DeviceFlowTests {
  let clock = ManualTiming()
  let mac: Rig
  let phone: Rig
  let cloud: Loopback

  init() throws {
    mac = try Rig()
    phone = try Rig()
    cloud = Loopback(a: mac, b: phone)
  }

  @Test func piSessionStateWrittenOnTheMacIsVisibleOnThePhoneAndRemovedWhenTheSessionEnds() async throws {
    let recorder = PiStateRecorder(store: mac.store, hostID: "mac", timing: clock.timing)
    try await recorder.update(sessionID: "s1", state: .waitingForUser, detail: "确认写入？", title: "fix bug")
    try await cloud.exchange()

    let seen = try #require(try await phone.store.piSessionStates().first)
    #expect(seen.sessionID == "s1" && seen.state == .known(.waitingForUser) && seen.detail == "确认写入？" && seen.title == "fix bug")

    try await recorder.update(sessionID: "s1", state: .settled)
    try await cloud.exchange()
    #expect(try await phone.store.piSessionStates().first?.state == .known(.settled))

    try await recorder.end(sessionID: "s1")
    try await cloud.exchange()
    #expect(try await phone.store.piSessionStates().isEmpty)
  }

  @Test(.timeLimit(.minutes(1)))
  func deliveryRequestTravelsFromPhoneToMacAndTheResultComesBackThenIsCleanedUp() async throws {
    let executor = DeliveryExecutor(store: mac.store, hostID: "mac", retention: .seconds(60), timing: clock.timing) { _ in .succeeded }
    try await executor.start()
    let request = try await phone.store.requestDelivery("run this", to: SendTarget(kind: .piSession, name: "fix bug", ref: "s1"), on: "mac")

    try await cloud.exchange()  // 手机 → Mac
    _ = try await eventually(mac.store, watching: [.deliveryRequests], { try $0.deliveryRequests().first?.status }) { $0 == .known(.succeeded) }
    try await cloud.exchange()  // Mac → 手机：结果回来
    #expect(try await phone.store.deliveryRequest(request.id)?.status == .known(.succeeded))

    await clock.waitForSleeper()
    clock.advance(.seconds(61))
    _ = try await eventually(mac.store, watching: [.deliveryRequests], { try $0.deliveryRequests().count }) { $0 == 0 }
    try await cloud.exchange()  // 清理同步过去
    #expect(try await phone.store.deliveryRequest(request.id) == nil)
    await executor.stop()
  }
}
