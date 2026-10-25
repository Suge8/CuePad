import CloudKit
import CueStore
import CueText
import Foundation

/// 点通知得到的路由信息：哪种通知、对应的 Pi 会话状态记录（`PiSessionState.id`）。
public struct PiAlertTap: Equatable, Sendable {
  public var kind: PiAlert
  public var sessionState: UUID

  public init(kind: PiAlert, sessionState: UUID) {
    self.kind = kind
    self.sessionState = sessionState
  }

  /// 通知中心里归哪一组：同一会话的提示（锁屏推送与本机通知）叠成一组，不刷屏。
  public var thread: String { sessionState.uuidString.lowercased() }
}

/// 点开的 CloudKit 通知指向哪里（通知自带触发它的订阅与记录 id）：Pi 会话状态记录，或 Cue 的那条消息（点开进 Cue 页）。
public enum CloudAlert: Equatable, Sendable {
  case session(PiAlertTap)
  case cue(message: UUID)

  /// 不是这里订阅的通知为 nil。
  public init?(userInfo: [AnyHashable: Any]) {
    guard let notification = CKNotification(fromRemoteNotificationDictionary: userInfo) as? CKQueryNotification,
      let name = notification.recordID?.recordName, let id = UUID(uuidString: name)
    else { return nil }
    switch notification.subscriptionID {
    case AlertSubscriptions.waitingID: self = .session(PiAlertTap(kind: .waitingForUser, sessionState: id))
    case AlertSubscriptions.settledID: self = .session(PiAlertTap(kind: .settled, sessionState: id))
    case AlertSubscriptions.replyID: self = .session(PiAlertTap(kind: .awaitsReply, sessionState: id))
    case AlertSubscriptions.cueID: self = .cue(message: id)
    default: return nil
    }
  }
}

/// 锁屏通知的具体文案：服务端只能发通用句（会话名、问题是加密字段），手机上的通知服务扩展收到后
/// 取回触发它的记录，在设备上解密，改写成"会话名 + 问题首句（或状态）"。取不到就保持通用句。
public enum PiAlertText {
  /// 改写后的标题与正文；记录里读不出会话名时为 nil（保持通用句）。
  public static func content(for record: CKRecord, kind: PiAlert) -> (title: String, body: String)? {
    let fields = record.encryptedValues
    guard let title = (fields["title"] as? String).flatMap({ $0.isEmpty ? nil : $0 }) else { return nil }
    let question = (fields["question"] as? String).flatMap(PiQuestion.init(stored:))?.text
    return content(title: title, question: question, reply: fields["lastReply"] as? String, kind: kind)
  }

  /// 等你：标题"会话名 等你拍板"（同名牌数字账的叫法），正文是问题首行；没有问题时是它最后那句回答的首行；都没有写"去看看它在问什么"。
  /// 待回复（Cue 把歇着的它留给你回）：标题"会话名 待回复"，正文是它最后那句回答的首行，没有写"去看看它说了什么"。
  /// 完成：标题会话名，正文"完成了"。
  public static func content(title: String, question: String?, reply: String?, kind: PiAlert) -> (title: String, body: String) {
    switch kind {
    case .waitingForUser:
      let first = [question, reply].lazy.compactMap { $0.flatMap(\.firstLine) }.first
      return (String(localized: "\(title) 等你拍板"), first ?? String(localized: "去看看它在问什么"))
    case .awaitsReply:
      return (String(localized: "\(title) 待回复"), reply.flatMap(\.firstLine) ?? String(localized: "去看看它说了什么"))
    case .settled:
      return (title, String(localized: "完成了"))
    }
  }
}

/// 从通知取回的 Cue 消息与设置的记录里读出文案的材料，交给 `CueAlert`（文案规则只在那里）。
public enum CueAlertText {
  public static func content(message: CKRecord, profile: CKRecord?) -> (title: String, body: String)? {
    func decoded<T: Decodable>(_ key: String, as type: T.Type) -> T? {
      (message.encryptedValues[key] as? String).flatMap { try? JSONDecoder().decode(type, from: Data($0.utf8)) }
    }
    guard let text = decoded("shownText", as: ShownText.self)?.text ?? message.encryptedValues["text"] as? String else { return nil }
    let asked = (message["ask"] as? String).flatMap(CueAsked.init(stored:))
    let asking = CueAsking(stored: asked?.ask.known, action: message.encryptedValues["askAction"] as? String, rule: message.encryptedValues["askRule"] as? String)
    let choices = decoded("choices", as: [String].self), places = decoded("places", as: [String: CuePlace].self) ?? [:]
    return CueAlert.content(
      name: profile?.encryptedValues["name"] as? String, text: text, asking: asking,
      choices: choices.map { $0.map { CueAsked.shownChoice($0, choices: choices, asked: asked, places: places) } },
      looks: (decoded("askShots", as: [CueShot].self) ?? []).map(\.look))
  }
}

/// 一个账号私有数据库里的订阅（真实实现是 `CloudDatabase`）。
protocol SubscriptionStore: Sendable {
  func subscriptions() async throws -> [CKSubscription.ID: CKSubscription]
  func save(_ subscription: CKSubscription) async throws
  func delete(_ id: CKSubscription.ID) async throws
}

/// CloudKit 服务端订阅（只有手机建）：只订阅要紧的变化——给你的话、请求结果、等你、做完，收到就在后台拉一次（App 的远程通知回调）。
/// 不订阅整个同步区的变化：Mac 每小时写三百次上下（会话细节、在线续期、预览），每次一条静默推送，远超系统每小时两三条的预算，
/// 被合并、节流后要紧的也跟着晚到（docs/sync.md「Agent 与 Cue 的通知」）。
/// 可见通知：Pi 会话状态记录（等你确认、待回复、完成三个）与 Cue 消息（一个）的 `notify` 标志置位时，服务端直接生成；它们都另带 content-available，
/// 把 App 叫到后台拉一次，实时活动随之更新。只靠静默推送的两个（Cue 对你说的话、发往 Mac 的请求有了结果）不出通知，只叫醒 App 拉。
/// 通知文案只用本地化 key 的通用句：标题与详情是加密字段，不可能出现在通知里；也不设 `desiredKeys`。删除不通知。
/// 谓词按标志而不是按状态，因为"同一状态下的重复更新"与"从工作中进入完成"这类转换在谓词里表达不了；标志只在转换那一次写入上置位（见 `PiStateRecorder`）。
/// 标志在上传前会被同状态的更新沿用；状态已前进或会话已结束时未上传的标志作废（见 `PiStateRecorder`）。
/// 谓词用到的明文字段由谓词本身推出（`queriedColumns`），生成的数据结构据此建可查询索引（见 docs/release.md「CloudKit 数据结构」）；加密字段服务端看不见，不能出现在谓词里。
/// 查询订阅是 schema 的一部分：改定义（谓词、选项、通知文案 key）要重新部署到生产，见 docs/release.md「CloudKit 数据结构」。
struct AlertSubscriptions {
  /// 通知标志字段（明文、可查询）。
  static let flagField = "notify"
  /// 本前缀下的订阅都是这里管的（多余的删掉）。
  static let prefix = "cuepad."
  static let waitingID = prefix + "pi.waiting"
  static let settledID = prefix + "pi.settled"
  static let replyID = prefix + "pi.reply"
  static let cueID = prefix + "cue"
  /// Cue 对你说的话（不论要不要提示）：静默推送。
  static let cueSaidID = prefix + "cue.said"
  /// 发往 Mac 的请求有了结果（成功或失败）：静默推送，回执在后台也拉得回来。
  static let resultID = prefix + "delivery.result"
  /// 通知的本地化文案 key（App 的 String Catalog 里手动加的通用句）：改写不成时显示它们。
  private static let waitingKey = "pi_alert_waiting", settledKey = "pi_alert_settled", replyKey = "pi_alert_reply", cueKey = "cue_alert"

  let zoneID: CKRecordZone.ID

  /// 谓词用到的字段（按表）：字段名只写在谓词里这一处。
  static let queriedColumns: [Table: Set<String>] = AlertSubscriptions(zoneID: CloudSync.zoneID).desired().reduce(into: [:]) { columns, subscription in
    guard let table = subscription.recordType.flatMap(Table.init(rawValue:)), let field = (subscription.predicate as? NSComparisonPredicate)?.leftExpression.keyPath
    else { preconditionFailure("订阅谓词只用一个字段的比较：\(subscription.predicate)") }
    columns[table, default: []].insert(field)
  }

  func desired() -> [CKQuerySubscription] {
    [
      alert(.piSessionStates, id: Self.waitingID, flag: PiAlert.waitingForUser.rawValue, key: Self.waitingKey),
      alert(.piSessionStates, id: Self.settledID, flag: PiAlert.settled.rawValue, key: Self.settledKey),
      alert(.piSessionStates, id: Self.replyID, flag: PiAlert.awaitsReply.rawValue, key: Self.replyKey),
      alert(.cueMessages, id: Self.cueID, flag: CueMessage.notifyFlag, key: Self.cueKey),
      silent(.cueMessages, id: Self.cueSaidID, NSPredicate(format: "author == %@", CueAuthor.cue.rawValue), on: .firesOnRecordCreation),
      silent(
        .deliveryRequests, id: Self.resultID, NSPredicate(format: "status IN %@", [DeliveryStatus.succeeded.rawValue, DeliveryStatus.failed.rawValue]),
        on: [.firesOnRecordCreation, .firesOnRecordUpdate]),
    ]
  }

  /// 幂等：缺的创建，与期望不一致的替换，本前缀下多余的删除，别人的订阅不碰。每个订阅各建各的，一个被拒（如生产环境还没部署的）不挡别的。
  /// 账号切换后新账号的数据库里没有这些订阅，再调用一次即重建。失败不抛：结果就是状态，原因交给界面；全是连不上的（`SyncFault`）是连不上，不算没建成。
  func ensure(in store: any SubscriptionStore) async -> PiAlertSubscriptionStatus {
    let existing: [CKSubscription.ID: CKSubscription]
    do { existing = try await store.subscriptions() } catch { return Self.status([(nil, error)]) }
    let wanted = desired()
    let wantedIDs = Set(wanted.map(\.subscriptionID))
    let failures: [(id: String?, error: any Error)] = await withTaskGroup(of: (String?, any Error)?.self) { group in
      for id in existing.keys where !wantedIDs.contains(id) && id.hasPrefix(Self.prefix) {
        group.addTask { await Self.attempt(id) { try await store.delete(id) } }
      }
      for subscription in wanted where !Self.matches(existing[subscription.subscriptionID], subscription) {
        group.addTask { await Self.attempt(subscription.subscriptionID) { try await store.save(subscription) } }
      }
      return await group.reduce(into: []) { failures, failure in if let failure { failures.append(failure) } }
    }
    return failures.isEmpty ? .active : Self.status(failures)
  }

  private static func status(_ failures: [(id: String?, error: any Error)]) -> PiAlertSubscriptionStatus {
    guard !failures.allSatisfy({ SyncFault($0.error).isOffline }) else { return .offline }
    return .failed(failures.map { [$0.id, $0.error.diagnosis].compactMap { $0 }.joined(separator: "：") }.sorted().joined(separator: "\n"))
  }

  private static func attempt(_ id: String, _ change: () async throws -> Void) async -> (String?, any Error)? {
    do {
      try await change()
      return nil
    } catch {
      return (id, error)
    }
  }

  /// 可见通知（`notify` 标志置位时），同时叫醒 App 在后台拉一次（content-available）。
  private func alert(_ table: Table, id: String, flag: String, key: String) -> CKQuerySubscription {
    let subscription = query(table, id: id, NSPredicate(format: "%K == %@", Self.flagField, flag), on: [.firesOnRecordCreation, .firesOnRecordUpdate])
    let info = CKSubscription.NotificationInfo()
    info.alertLocalizationKey = key
    info.soundName = "default"
    // 让手机上的通知服务扩展先拿到通知，按记录改写成会话名与问题、Cue 说的话（加密字段只能在设备上读）
    info.shouldSendMutableContent = true
    info.shouldSendContentAvailable = true
    subscription.notificationInfo = info
    return subscription
  }

  /// 只叫醒 App 在后台拉一次，不出通知。
  private func silent(_ table: Table, id: String, _ predicate: NSPredicate, on options: CKQuerySubscription.Options) -> CKQuerySubscription {
    let subscription = query(table, id: id, predicate, on: options)
    let info = CKSubscription.NotificationInfo()
    info.shouldSendContentAvailable = true
    subscription.notificationInfo = info
    return subscription
  }

  private func query(_ table: Table, id: String, _ predicate: NSPredicate, on options: CKQuerySubscription.Options) -> CKQuerySubscription {
    let subscription = CKQuerySubscription(recordType: table.rawValue, predicate: predicate, subscriptionID: id, options: options)
    subscription.zoneID = zoneID
    return subscription
  }

  private static func matches(_ existing: CKSubscription?, _ wanted: CKQuerySubscription) -> Bool {
    guard let existing = existing as? CKQuerySubscription else { return false }
    return existing.recordType == wanted.recordType && existing.predicate.predicateFormat == wanted.predicate.predicateFormat
      && existing.zoneID == wanted.zoneID && existing.querySubscriptionOptions == wanted.querySubscriptionOptions
      && existing.notificationInfo?.alertLocalizationKey == wanted.notificationInfo?.alertLocalizationKey
      && existing.notificationInfo?.shouldSendContentAvailable == wanted.notificationInfo?.shouldSendContentAvailable
      && existing.notificationInfo?.shouldSendMutableContent == wanted.notificationInfo?.shouldSendMutableContent
  }
}
