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

  @Test func piSessionStateWrittenOnTheMacIsVisibleOnThePhoneAndKeptAsEndedWhenTheSessionEnds() async throws {
    let recorder = PiStateRecorder(store: mac.store, hostID: "mac", timing: clock.timing)
    let question = PiQuestion(promptID: "p-1", kind: .select, text: "确认写入？", options: ["是", "否"])
    let recap = PiRecap(lastPrompt: "修好登录", lastReply: "改好了：\n- 换了令牌", pendingPrompt: "再跑一遍测试")
    let times = PiTimes(stateSince: Date(timeIntervalSince1970: 2_000), busySince: Date(timeIntervalSince1970: 1_000))
    try await recorder.update(
      sessionID: "s1", state: .waitingForUser, detail: "确认写入？", title: "fix bug", folder: "cuepad", question: question, times: times)
    let said = PiChatMessage(sessionID: "s1", entryID: "u1", seq: 2, role: .user, text: "再跑一遍测试", at: Date(timeIntervalSince1970: 3_000), deliveryID: UUID())
    try await mac.store.writePiTranscript(PiTranscript(sessionID: "s1", messages: [said], recap: recap))
    try await cloud.exchange()

    let seen = try #require(try await phone.store.allPiSessionStates().first)
    #expect(seen.sessionID == "s1" && seen.state == .known(.waitingForUser) && seen.detail == "确认写入？" && seen.title == "fix bug")
    #expect(seen.folder == "cuepad")  // 手机没有工作目录，副行靠它写出文件夹名
    #expect(seen.lastPrompt == recap.lastPrompt && seen.lastReply == recap.lastReply && seen.question == question)
    #expect(seen.pendingPrompt == recap.pendingPrompt)
    // 对话经同步到手机，按先后排、带着送进来的投送请求 id
    #expect(try await phone.store.piMessages(of: "s1").map { [$0.text, $0.deliveryID?.uuidString] } == [[said.text, said.deliveryID?.uuidString]])
    #expect(seen.stateSince == times.stateSince && seen.busySince == times.busySince)

    try await recorder.update(sessionID: "s1", state: .settled)
    try await cloud.exchange()
    #expect(try await phone.store.allPiSessionStates().first?.state == .known(.settled))

    try await recorder.end(sessionID: "s1")
    try await cloud.exchange()
    let ended = try #require(try await phone.store.allPiSessionStates().first)
    #expect(ended.state == .known(.ended) && ended.lastReply == recap.lastReply)  // 跑完的结论在手机上还看得到
  }

  /// 子代理列表（名字与此刻在干什么）与"后台托管中"经同步往返保留。
  @Test func subagentsAndHostingTravelToThePhone() async throws {
    let recorder = PiStateRecorder(store: mac.store, hostID: "mac", timing: clock.timing)
    let subagents = [PiSubagentState(name: "ui", activity: .known(.working)), PiSubagentState(name: "core", activity: .known(.idle))]
    try await recorder.update(sessionID: "s1", state: .delegating, title: "指挥官", hosted: true, subagents: subagents)
    try await cloud.exchange()

    let seen = try #require(try await phone.store.allPiSessionStates().first)
    #expect(seen.subagents == subagents && seen.hosted)
  }

  /// 会话的模型、思考强度与可选模型（Mac 写）经同步到手机；手机的配置请求（手机写）到 Mac，读出同一个配置。
  @Test func modelChoicesTravelToThePhoneAndTheConfigRequestTravelsBackToTheMac() async throws {
    let recorder = PiStateRecorder(store: mac.store, hostID: "mac", timing: clock.timing)
    let sonnet = PiModelOption(key: PiModelKey(provider: "anthropic", id: "sonnet"), name: "Sonnet", thinkingLevels: [.off, .low, .medium])
    let opus = PiModelOption(key: PiModelKey(provider: "anthropic", id: "opus"), name: "Opus", thinkingLevels: [.off, .high])
    try await recorder.update(
      sessionID: "s1", state: .settled, title: "t", modelState: PiModelState(model: sonnet, thinking: .known(.low), models: [sonnet, opus]))
    try await cloud.exchange()

    let seen = try #require(try await phone.store.allPiSessionStates().first)
    #expect(seen.model == sonnet && seen.thinking == .known(.low) && seen.models == [sonnet, opus])

    let config = PiConfig(model: opus.key, thinking: .high)
    let target = SendTarget(kind: .piSession, name: "t", ref: "s1")
    let made = try await phone.store.requestConfig(config, to: target, on: "mac")
    try await cloud.exchange()
    #expect(try await mac.store.deliveryRequest(made.id)?.config == config)
  }

  @Test(.timeLimit(.minutes(1)))
  func deliveryRequestTravelsFromPhoneToMacAndTheResultComesBackThenIsCleanedUp() async throws {
    let executor = DeliveryExecutor(
      store: mac.store, hostID: "mac", retention: .seconds(60), timing: clock.timing, onIssue: { Issue.record("\($0)") }
    ) { _ in .succeeded }
    try await executor.start()
    let request = try await phone.store.requestDelivery("run this", to: SendTarget(kind: .piSession, name: "fix bug", ref: "s1"), on: "mac")

    try await cloud.exchange()  // 手机 → Mac
    _ = try await eventually(mac.store, watching: [.deliveryRequests], { try $0.deliveryRequests().first?.status }) { $0 == .known(.succeeded) }
    try await cloud.exchange()  // Mac → 手机：结果回来
    let back = try #require(try await phone.store.deliveryRequest(request.id))
    #expect(back.status == .known(.succeeded))
    let roundTrip = try #require(back.roundTrip)  // 发起的手机用本机时钟算：创建 → 看到结果
    #expect(roundTrip >= .zero && roundTrip < .seconds(60))
    #expect(try await mac.store.deliveryRequest(request.id)?.roundTrip == nil)  // 执行方不算往返

    await clock.waitForSleeper()
    clock.advance(.seconds(61))
    _ = try await eventually(mac.store, watching: [.deliveryRequests], { try $0.deliveryRequests().count }) { $0 == 0 }
    try await cloud.exchange()  // 清理同步过去
    #expect(try await phone.store.deliveryRequest(request.id) == nil)
    await executor.stop()
  }
}
