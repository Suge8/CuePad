import CloudKit
import CueStore
import CueText
import Foundation

public struct AlertTap: Equatable, Sendable {
  public var kind: AlertKind
  public var sessionState: UUID

  public init(kind: AlertKind, sessionState: UUID) {
    self.kind = kind
    self.sessionState = sessionState
  }

  /// 通知中心里归哪一组：同一会话的提示（锁屏推送与本机通知）叠成一组，不刷屏。
  public var thread: String { sessionState.uuidString.lowercased() }
}

public enum CloudAlert: Equatable, Sendable {
  case session(AlertTap)
  case cue(message: UUID)

  /// 不是这里订阅的通知为 nil。
  public init?(userInfo: [AnyHashable: Any]) {
    guard let notification = CKNotification(fromRemoteNotificationDictionary: userInfo) as? CKQueryNotification,
      let name = notification.recordID?.recordName, let id = UUID(uuidString: name)
    else { return nil }
    switch notification.subscriptionID {
    case AlertSubscriptions.waitingID: self = .session(AlertTap(kind: .waitingForUser, sessionState: id))
    case AlertSubscriptions.settledID: self = .session(AlertTap(kind: .settled, sessionState: id))
    case AlertSubscriptions.replyID: self = .session(AlertTap(kind: .awaitsReply, sessionState: id))
    case AlertSubscriptions.cueID: self = .cue(message: id)
    default: return nil
    }
  }
}

/// 锁屏通知的具体文案：服务端只能发通用句（会话名、问题是加密字段），手机上的通知服务扩展收到后
/// 取回触发它的记录，在设备上解密，改写成"会话名 + 问题首句（或状态）"。取不到就保持通用句。
public enum AlertText {
  /// 读不出会话名时为 nil（保持通用句）。
  public static func content(for record: CKRecord, kind: AlertKind) -> (title: String, body: String)? {
    let fields = record.encryptedValues
    guard let title = (fields["title"] as? String).flatMap({ $0.isEmpty ? nil : $0 }) else { return nil }
    let question = (fields["question"] as? String).flatMap(Question.init(stored:))?.text
    let failure = record["state"] as? String == WorkState.error.rawValue ? fields["detail"] as? String : nil
    return content(title: title, question: question, reply: fields["lastReply"] as? String, failure: failure, kind: kind)
  }

  public static func content(title: String, question: String?, reply: String?, failure: String?, kind: AlertKind) -> (title: String, body: String) {
    switch kind {
    case .waitingForUser:
      let first = [question, reply].lazy.compactMap { $0.flatMap(\.firstLine) }.first
      return (String(localized: "\(title) 等你拍板"), first ?? String(localized: "去看看它在问什么"))
    case .awaitsReply:
      return (String(localized: "\(title) 待回复"), (failure ?? reply).flatMap(\.firstLine) ?? String(localized: "去看看它说了什么"))
    case .settled:
      return (title, String(localized: "完成了"))
    }
  }
}

/// 文案规则只在 `CueAlert`，这里只读出材料。
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

protocol SubscriptionStore: Sendable {
  func subscriptions() async throws -> [CKSubscription.ID: CKSubscription]
  func save(_ subscription: CKSubscription) async throws
  func delete(_ id: CKSubscription.ID) async throws
}

/// 不订阅整个同步区的变化：Mac 每小时写三百次上下（会话细节、在线续期、预览），每次一条静默推送，远超系统每小时两三条的预算，
/// 被合并、节流后要紧的也跟着晚到。
/// 通知文案只用本地化 key 的通用句：标题与详情是加密字段，不可能出现在通知里；也不设 `desiredKeys`。删除不通知。
/// 谓词按标志而不是按状态，因为"同一状态下的重复更新"与"从工作中进入完成"这类转换在谓词里表达不了；标志只在转换那一次写入上置位（见 `StateRecorder`）。
/// 标志是一次性事件，通知反映服务端收到记录那一刻的状态：上传前会被同状态的更新沿用；状态已前进或会话已结束时未上传的标志作废、不送出（见 `StateRecorder`）。
/// 要保证每个事件都送达得另建追加式的通知事件记录，那是另一种设计，没有采用。
/// 谓词用到的明文字段由谓词本身推出（`queriedColumns`），生成的数据结构据此建可查询索引；加密字段服务端看不见，不能出现在谓词里。
/// 查询订阅是 schema 的一部分：改定义（谓词、选项、通知文案 key）要重新部署到生产，见 docs/release.md「CloudKit 数据结构」。
struct AlertSubscriptions {
  static let flagField = "notify"
  /// 本前缀下的订阅都是这里管的（多余的删掉）。
  static let prefix = "cuepad."
  static let waitingID = prefix + "pi.waiting"
  static let settledID = prefix + "pi.settled"
  static let replyID = prefix + "pi.reply"
  /// 该你接、你正在 Mac 上开着的会话：静默推送（与上面三个按 `AlertPush` 分开，一条只命中一个）。
  static let sessionWakeID = prefix + "pi.wake"
  static let cueID = prefix + "cue"
  /// Cue 对你说的、不出通知的话：静默推送（与 `cueID` 按 `CuePush` 分开，一条只命中一个）。
  static let cueSaidID = prefix + "cue.said"
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
      alert(.piSessionStates, id: Self.waitingID, flag: AlertPush.alert(.waitingForUser).rawValue, key: Self.waitingKey),
      alert(.piSessionStates, id: Self.settledID, flag: AlertPush.alert(.settled).rawValue, key: Self.settledKey),
      alert(.piSessionStates, id: Self.replyID, flag: AlertPush.alert(.awaitsReply).rawValue, key: Self.replyKey),
      silent(.piSessionStates, id: Self.sessionWakeID, Self.flagged(AlertPush.wake.rawValue), on: [.firesOnRecordCreation, .firesOnRecordUpdate]),
      alert(.cueMessages, id: Self.cueID, flag: CuePush.alert.rawValue, key: Self.cueKey),
      silent(.cueMessages, id: Self.cueSaidID, Self.flagged(CuePush.wake.rawValue), on: .firesOnRecordCreation),
      silent(
        .deliveryRequests, id: Self.resultID, NSPredicate(format: "status IN %@", [DeliveryStatus.succeeded.rawValue, DeliveryStatus.failed.rawValue]),
        on: [.firesOnRecordCreation, .firesOnRecordUpdate]),
    ]
  }

  /// 每个订阅各建各的，一个被拒（如生产环境还没部署的）不挡别的。账号切换后新账号的数据库里没有这些订阅，再调用一次即重建。失败不抛：结果就是状态，原因交给界面；全是连不上的（`SyncFault`）是连不上，不算没建成。
  func ensure(in store: any SubscriptionStore) async -> AlertSubscriptionStatus {
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

  private static func status(_ failures: [(id: String?, error: any Error)]) -> AlertSubscriptionStatus {
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

  private func alert(_ table: Table, id: String, flag: String, key: String) -> CKQuerySubscription {
    let subscription = query(table, id: id, Self.flagged(flag), on: [.firesOnRecordCreation, .firesOnRecordUpdate])
    let info = CKSubscription.NotificationInfo()
    info.alertLocalizationKey = key
    info.soundName = "default"
    // 让手机上的通知服务扩展先拿到通知，按记录改写成会话名与问题、Cue 说的话（加密字段只能在设备上读）
    info.shouldSendMutableContent = true
    info.shouldSendContentAvailable = true
    subscription.notificationInfo = info
    return subscription
  }

  private static func flagged(_ flag: String) -> NSPredicate { NSPredicate(format: "%K == %@", flagField, flag) }

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
