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

  /// Agent 发到手机的预览：Mac 写预览记录与文件，手机拿到记录和一模一样的文件；Mac 过期清理后手机的记录与文件也没了。
  @Test func aPreviewAndItsFileTravelToThePhoneAndGoWhenTheMacDropsIt() async throws {
    let source = mac.fixture.directory.appending(path: "demo.html")
    try Data("<h1>登录页</h1>".utf8).write(to: source)
    let preview = try await mac.store.addPreview(fileAt: source, title: "登录页", sessionID: "s1").preview
    try await cloud.exchange()

    let seen = try #require(try await phone.store.previews(of: "s1").first)
    #expect(seen == preview)  // 标题、文件名、大小、哈希都到了
    #expect(try Data(contentsOf: #require(phone.store.files.fileURL(for: seen.hash))) == Data("<h1>登录页</h1>".utf8))

    try await mac.store.prunePiMessages(olderThan: 7 * 86_400, now: .now.addingTimeInterval(8 * 86_400))
    try await cloud.exchange()
    #expect(try await phone.store.previews(of: "s1").isEmpty && phone.store.files.fileURL(for: seen.hash) == nil)
  }

  /// 子代理列表（名字、角色、状态、在做什么与时刻）与"后台托管中"经同步往返保留。
  @Test func subagentsAndHostingTravelToThePhone() async throws {
    let recorder = PiStateRecorder(store: mac.store, hostID: "mac", timing: clock.timing)
    let subagents = [
      PiSubagentState(name: "ui", role: "工程师", phase: .known(.running), action: "运行 bun test", startedAt: Date(timeIntervalSince1970: 1_000)),
      PiSubagentState(name: "core", role: "审查员", phase: .known(.idle)),
    ]
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

  /// 上下文余量与命令清单（Mac 写）经同步到手机；手机据此画圆环、弹斜杠面板。
  @Test func contextUsageAndCommandsTravelToThePhone() async throws {
    let recorder = PiStateRecorder(store: mac.store, hostID: "mac", timing: clock.timing)
    let commands = [
      PiSlashCommand(name: "compact", summary: "压缩上下文", source: .known(.builtin), hint: "[说明]"),
      PiSlashCommand(name: "skill:review", summary: "审查改动", source: .known(.skill)),
    ]
    try await recorder.update(sessionID: "s1", state: .settled, title: "t", context: PiContextUsage(tokens: 150_000, window: 200_000), commands: commands)
    try await cloud.exchange()

    let seen = try #require(try await phone.store.allPiSessionStates().first)
    #expect(seen.context == PiContextUsage(tokens: 150_000, window: 200_000) && seen.commands == commands)
  }

  /// 手机请 Mac 绑文件夹：请求（只带"从哪个会话的目录取"，不带路径）到 Mac，Mac 读出同一个内容。
  @Test func bindRequestTravelsFromPhoneToTheMac() async throws {
    let project = try await phone.store.createProject(name: "圆桌", color: "#111")
    let bind = PiBind(project: project.id, folder: .besideSession("s1"))
    let made = try await phone.store.requestBind(bind, title: "圆桌", on: "mac")
    try await cloud.exchange()
    #expect(try await mac.store.deliveryRequest(made.id)?.bind == bind)
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

  /// 一条状态记录带着大字段（三百个模型的清单）：第二次上传只带改动的字段，服务器并进整条记录，手机上模型清单还在、状态是新的。
  @Test func aPartialUploadLeavesTheLargeFieldsOnTheOtherDeviceIntact() async throws {
    let recorder = PiStateRecorder(store: mac.store, hostID: "mac", timing: clock.timing)
    let options = (0..<300).map { PiModelOption(key: PiModelKey(provider: "p", id: "model-\($0)-with-a-long-identifier"), name: "Model \($0)", thinkingLevels: [.off, .high]) }
    try await recorder.update(sessionID: "s1", state: .thinking, title: "t", modelState: PiModelState(model: options[0], models: options))
    try await cloud.exchange()
    #expect(try await phone.store.allPiSessionStates().first?.models.count == 300)

    try await recorder.update(sessionID: "s1", state: .settled, detail: "做完了")
    try await cloud.exchange()

    let seen = try #require(try await phone.store.allPiSessionStates().first)
    #expect(seen.state == .known(.settled) && seen.detail == "做完了")
    #expect(seen.models.count == 300)
  }
}
