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
      sessionID: "s1", state: .waitingForUser, detail: "确认写入？", title: "fix bug", directory: "cuepad", question: question, times: times)
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
    let preview = try await mac.store.addPreviews(filesAt: [source], title: "登录页", sessionID: "s1")[0].preview
    try await cloud.exchange()

    let seen = try #require(try await phone.store.previews(of: "s1").first)
    #expect(seen == preview)  // 标题、文件名、大小、哈希都到了
    #expect(try Data(contentsOf: #require(phone.store.files.fileURL(for: seen.hash))) == Data("<h1>登录页</h1>".utf8))

    try await mac.store.prunePiMessages(olderThan: 7 * 86_400, now: .now.addingTimeInterval(8 * 86_400))
    try await cloud.exchange()
    #expect(try await phone.store.previews(of: "s1").isEmpty && phone.store.files.fileURL(for: seen.hash) == nil)
  }

  /// 会话的模型、思考强度（Mac 写）与它所在目录可换的模型、命令经同步到手机；手机的配置请求（手机写）到 Mac，读出同一个配置。
  @Test func modelChoicesTravelToThePhoneAndTheConfigRequestTravelsBackToTheMac() async throws {
    let recorder = PiStateRecorder(store: mac.store, hostID: "mac", timing: clock.timing)
    let sonnet = PiModelOption(key: PiModelKey(provider: "anthropic", id: "sonnet"), name: "Sonnet", thinkingLevels: [.off, .low, .medium])
    let opus = PiModelOption(key: PiModelKey(provider: "anthropic", id: "opus"), name: "Opus", thinkingLevels: [.off, .high])
    let compact = PiSlashCommand(name: "compact", summary: "压缩上下文", source: .known(.builtin))
    try await recorder.update(
      sessionID: "s1", state: .settled, title: "t", directory: "/Users/me/app",
      modelState: PiModelState(model: sonnet, thinking: .known(.low), models: [sonnet, opus]), commands: [compact])
    try await cloud.exchange()

    let seen = try #require(try await phone.store.allPiSessionStates().first)
    #expect(seen.model == sonnet && seen.thinking == .known(.low))
    let catalogID = try #require(seen.catalogID)
    let catalog = try #require(try await phone.store.agentCatalog(catalogID))
    #expect(catalog.models == [sonnet, opus] && catalog.commands == [compact])

    let config = PiConfig(model: opus.key, thinking: .high)
    let target = SendTarget(kind: .piSession, name: "t", ref: "s1")
    let made = try await phone.store.requestConfig(config, to: target, on: "mac")
    try await cloud.exchange()
    #expect(try await mac.store.deliveryRequest(made.id)?.config == config)
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
    _ = try await eventually(mac.store, { try $0.deliveryRequests().first?.status }) { $0 == .known(.succeeded) }
    try await cloud.exchange()  // Mac → 手机：结果回来
    let back = try #require(try await phone.store.deliveryRequest(request.id))
    #expect(back.status == .known(.succeeded))
    let roundTrip = try #require(back.roundTrip)  // 发起的手机用本机时钟算：创建 → 看到结果
    #expect(roundTrip >= .zero && roundTrip < .seconds(60))
    #expect(try await mac.store.deliveryRequest(request.id)?.roundTrip == nil)  // 执行方不算往返

    await clock.waitForSleeper()
    clock.advance(.seconds(61))
    _ = try await eventually(mac.store, { try $0.deliveryRequests().count }) { $0 == 0 }
    try await cloud.exchange()  // 清理同步过去
    #expect(try await phone.store.deliveryRequest(request.id) == nil)
    await executor.stop()
  }

  /// 断网时手机说的话（发给会话、对 Cue 说）：马上传失败，同步状态是连不上 iCloud、话是同步不通，Mac 那边还没有；
  /// 记录不丢，恢复后的同步（发送者把待推送发出去、拉取）把它们传到 Mac；Mac 执行、交给 Cue 后的回执经同步回到手机，
  /// 两句都是已送达，同步状态回到空闲。
  @Test(.timeLimit(.minutes(1)))
  func wordsSaidOfflineReachTheMacAfterRecoveryAndTheReceiptsComeBack() async throws {
    let executor = DeliveryExecutor(store: mac.store, hostID: "mac", timing: clock.timing, onIssue: { Issue.record("\($0)") }) { _ in .succeeded }
    try await executor.start()
    _ = try await phone.store.updateCueProfile {
      $0.hostID = "mac"
      $0.enabledAt = .now
    }
    let request = try await phone.store.requestDelivery("改完再跑一遍", to: SendTarget(kind: .piSession, name: "fix bug", ref: "s1"), on: "mac")
    let message = try await phone.store.addCueMessage(.you, text: "在吗")
    let sender = RecordSender(uploader: Offline(), coordinator: phone.coordinator)
    await sender.start()
    for id in [request.id, message.id] { #expect(await !sender.send([phone.id(id)])) }
    await sender.stop()

    #expect(await phone.coordinator.status == .offline)
    #expect(Speech.trip(request, at: Speech.Moment(now: .now, reachableSince: nil)) == .failed(.offline))
    #expect(try await mac.store.deliveryRequest(request.id) == nil)

    try await cloud.exchange()  // 恢复：手机的待推送传出去
    _ = try await eventually(mac.store, { try $0.deliveryRequest(request.id)?.status }) { $0 == .known(.succeeded) }
    try await mac.store.markCueMessagesDelivered([message.id])  // Mac 上值班的管理器交给 Cue
    try await cloud.exchange()  // 回执回到手机

    let back = try #require(try await phone.store.deliveryRequest(request.id))
    let heard = try #require(try await phone.store.cueMessages().first { $0.id == message.id })
    #expect(Speech.trip(back, at: .always()) == .delivered)
    #expect(Speech.trip(said: heard.createdAt, delivered: heard.deliveredAt, host: "mac", at: .always()) == .delivered)
    #expect(await phone.coordinator.status == .idle)
    await executor.stop()
  }

  /// 没有网络：整个上传请求失败。
  private struct Offline: RecordUploader {
    func upload(saving records: [CKRecord], deleting ids: [CKRecord.ID]) async throws -> SentRecords { throw CKError(.networkUnavailable) }
    func saveZone() async throws { throw CKError(.networkUnavailable) }
  }

  /// 三百个模型的清单：报的一样的会话共用一份，状态变化不再带着它上传；同一目录里报的不一样的（如 `--models` 限定了范围）各看各的；
  /// 会话结束了还留着（已结束的也能换模型），会话记录都没了才删掉。
  @Test func sessionsReportingTheSameModelListShareOneThatStateChangesDoNotResend() async throws {
    let recorder = PiStateRecorder(store: mac.store, hostID: "mac", timing: clock.timing)
    let options = (0..<300).map { PiModelOption(key: PiModelKey(provider: "p", id: "model-\($0)-with-a-long-identifier"), name: "Model \($0)", thinkingLevels: [.off, .high]) }
    let models = PiModelState(model: options[0], models: options)
    try await recorder.update(sessionID: "s1", state: .thinking, title: "t", directory: "/Users/me/app", modelState: models)
    try await recorder.update(sessionID: "s2", state: .thinking, title: "u", directory: "/Users/me/app", modelState: models)
    let scoped = PiModelState(model: options[0], models: Array(options.prefix(2)))
    try await recorder.update(sessionID: "s3", state: .thinking, title: "v", directory: "/Users/me/app", modelState: scoped)
    try await cloud.exchange()
    let states = Dictionary(uniqueKeysWithValues: try await phone.store.allPiSessionStates().map { ($0.sessionID, $0.catalogID) })
    let shared = try #require(states["s1"] ?? nil)
    #expect(states["s2"] == shared && states["s3"] != shared)
    let own = try #require(states["s3"] ?? nil)
    #expect(try await phone.store.agentCatalog(own)?.models == scoped.models)
    let sent = try #require(try await mac.store.agentCatalog(shared))

    try await recorder.update(sessionID: "s1", state: .settled, detail: "做完了")
    try await cloud.exchange()

    let seen = try #require(try await phone.store.allPiSessionStates().first { $0.sessionID == "s1" })
    #expect(seen.state == .known(.settled) && seen.detail == "做完了")
    #expect(try await mac.store.agentCatalog(shared) == sent)  // 没改，不再上传
    #expect(try await phone.store.agentCatalog(shared)?.models.count == 300)

    try await recorder.end(sessionID: "s1")
    try await recorder.end(sessionID: "s2")
    try await cloud.exchange()
    #expect(try await phone.store.agentCatalog(shared)?.models.count == 300)

    try await recorder.exited(sessionID: "s1", spoke: false)
    try await recorder.exited(sessionID: "s2", spoke: false)
    try await cloud.exchange()
    #expect(try await phone.store.agentCatalog(shared) == nil)
  }
}
