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

  /// 等你：标题"会话名 在等你"，正文是问题首行；没有问题（Cue 把歇着的它留给你回）是它最后那句回答的首行；都没有写"去看看它在问什么"。
  /// 完成：标题会话名，正文"完成了"。
  public static func content(title: String, question: String?, reply: String?, kind: PiAlert) -> (title: String, body: String) {
    switch kind {
    case .waitingForUser:
      let first = [question, reply].lazy.compactMap { $0.flatMap(Self.firstLine) }.first
      return ("\(title) 在等你", first ?? "去看看它在问什么")
    case .settled:
      return (title, "完成了")
    }
  }

  private static func firstLine(_ text: String) -> String? {
    text.split(whereSeparator: \.isNewline).lazy.map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
  }
}

/// 从通知取回的 Cue 消息与设置的记录里读出文案的材料，交给 `CueAlert`（文案规则只在那里）。
public enum CueAlertText {
  public static func content(message: CKRecord, profile: CKRecord?) -> (title: String, body: String)? {
    guard let text = message.encryptedValues["text"] as? String else { return nil }
    func decoded<T: Decodable>(_ key: String, as type: T.Type) -> T? {
      (message.encryptedValues[key] as? String).flatMap { try? JSONDecoder().decode(type, from: Data($0.utf8)) }
    }
    let asking = CueAsking(
      stored: (message["ask"] as? String).flatMap(CueAllow.init(stored:))?.ask.known, action: message.encryptedValues["askAction"] as? String,
      rule: message.encryptedValues["askRule"] as? String)
    return CueAlert.content(
      name: profile?.encryptedValues["name"] as? String, text: text, asking: asking, choices: decoded("choices", as: [String].self),
      looks: (decoded("askShots", as: [CueShot].self) ?? []).map(\.look))
  }
}

/// 一个账号私有数据库里的订阅（真实实现是 CKDatabase）。
protocol SubscriptionStore: Sendable {
  func subscriptions() async throws -> [CKSubscription.ID: CKSubscription]
  func save(_ subscription: CKSubscription) async throws
  func delete(_ id: CKSubscription.ID) async throws
}

/// CloudKit 服务端订阅（只有手机建）：同步区有变化时的静默推送（收到就拉一次），以及下面的可见通知。
/// Pi 会话状态记录（等你确认、完成两个）与 Cue 消息（一个）的 `notify` 标志置位时，服务端直接生成可见通知。
/// 等你类的两个（会话等你确认、Cue 的消息）另带 content-available：可见通知同时把 App 叫到后台拉一次，实时活动的等你随之更新（docs/sync.md「Agent 与 Cue 的通知」）。
/// 不依赖静默推送与 App 在后台运行。通知文案只用本地化 key 的通用句：标题与详情是加密字段，不可能出现在通知里；
/// 也不设 `desiredKeys`。只订阅创建与更新（删除不通知）。谓词按标志而不是按状态，因为"同一状态下的重复更新"
/// 与"从工作中进入完成"这类转换在谓词里表达不了；标志只在转换那一次写入上置位（见 `PiStateRecorder`）。
/// 标志在上传前会被同状态的更新沿用；状态已前进或会话已结束时未上传的标志作废（见 `PiStateRecorder`）。
/// 两张表的 `notify` 可查询索引由生成的数据结构声明（`RecordMapper.queryableColumns`，见 docs/release.md「CloudKit 数据结构」）。
/// 查询订阅是 schema 的一部分：改定义（谓词、选项、通知文案 key）要重新部署到生产，见 docs/release.md「CloudKit 数据结构」。
struct AlertSubscriptions {
  /// 通知标志字段（明文、可查询）。
  static let flagField = "notify"
  /// 本前缀下的订阅都是这里管的（多余的删掉）。
  static let prefix = "cuepad."
  static let waitingID = prefix + "pi.waiting"
  static let settledID = prefix + "pi.settled"
  static let cueID = prefix + "cue"
  /// 同步区有变化就给这台设备一个静默推送，收到就拉一次（App 的远程通知回调）。数据库订阅生产环境允许客户端直接建。
  static let changesID = prefix + "changes"
  /// 通知的本地化文案 key（App 的 Localizable.strings 里的通用句）：改写不成时显示它们。
  private static let waitingKey = "pi_alert_waiting", settledKey = "pi_alert_settled", cueKey = "cue_alert"

  let zoneID: CKRecordZone.ID

  func desired() -> [CKSubscription] {
    [
      make(.piSessionStates, id: Self.waitingID, flag: "waitingForUser", key: Self.waitingKey, wakes: true),
      make(.piSessionStates, id: Self.settledID, flag: "settled", key: Self.settledKey),
      make(.cueMessages, id: Self.cueID, flag: CueMessage.notifyFlag, key: Self.cueKey, wakes: true),
      changes(),
    ]
  }

  private func changes() -> CKDatabaseSubscription {
    let subscription = CKDatabaseSubscription(subscriptionID: Self.changesID)
    let info = CKSubscription.NotificationInfo()
    info.shouldSendContentAvailable = true
    subscription.notificationInfo = info
    return subscription
  }

  /// 幂等：缺的创建，与期望不一致的替换，本前缀下多余的删除；不是这里建的数据库订阅也删掉（CKSyncEngine 当年建的，
  /// 它的静默推送和 `changesID` 重复），别的查询订阅不碰。
  /// 账号切换后新账号的数据库里没有这些订阅，再调用一次即重建。失败不抛：结果就是状态，原因交给界面。
  func ensure(in store: any SubscriptionStore) async -> PiAlertSubscriptionStatus {
    do {
      let existing = try await store.subscriptions()
      let wanted = desired()
      let wantedIDs = Set(wanted.map(\.subscriptionID))
      for (id, subscription) in existing where !wantedIDs.contains(id) && (id.hasPrefix(Self.prefix) || subscription is CKDatabaseSubscription) {
        try await store.delete(id)
      }
      for subscription in wanted where !Self.matches(existing[subscription.subscriptionID], subscription) {
        try await store.save(subscription)
      }
      return .active
    } catch {
      return .failed(error.diagnosis)
    }
  }

  /// `wakes`：同时叫醒 App 在后台拉一次（content-available）。
  private func make(_ table: Table, id: String, flag: String, key: String, wakes: Bool = false) -> CKQuerySubscription {
    let subscription = CKQuerySubscription(
      recordType: table.rawValue, predicate: NSPredicate(format: "%K == %@", Self.flagField, flag),
      subscriptionID: id, options: [.firesOnRecordCreation, .firesOnRecordUpdate])
    subscription.zoneID = zoneID
    let info = CKSubscription.NotificationInfo()
    info.alertLocalizationKey = key
    info.soundName = "default"
    // 让手机上的通知服务扩展先拿到通知，按记录改写成会话名与问题、Cue 说的话（加密字段只能在设备上读）
    info.shouldSendMutableContent = true
    info.shouldSendContentAvailable = wakes
    subscription.notificationInfo = info
    return subscription
  }

  private static func matches(_ existing: CKSubscription?, _ wanted: CKSubscription) -> Bool {
    if wanted is CKDatabaseSubscription {
      return existing is CKDatabaseSubscription && existing?.notificationInfo?.shouldSendContentAvailable == true
    }
    guard let existing = existing as? CKQuerySubscription, let wanted = wanted as? CKQuerySubscription else { return false }
    return existing.recordType == wanted.recordType && existing.predicate.predicateFormat == wanted.predicate.predicateFormat
      && existing.zoneID == wanted.zoneID && existing.querySubscriptionOptions == wanted.querySubscriptionOptions
      && existing.notificationInfo?.alertLocalizationKey == wanted.notificationInfo?.alertLocalizationKey
      && existing.notificationInfo?.shouldSendContentAvailable == wanted.notificationInfo?.shouldSendContentAvailable
      && existing.notificationInfo?.shouldSendMutableContent == wanted.notificationInfo?.shouldSendMutableContent
  }
}

/// 私有数据库作为订阅存储。
struct DatabaseSubscriptions: SubscriptionStore {
  let database: CKDatabase

  func subscriptions() async throws -> [CKSubscription.ID: CKSubscription] {
    Dictionary(uniqueKeysWithValues: try await database.allSubscriptions().map { ($0.subscriptionID, $0) })
  }

  func save(_ subscription: CKSubscription) async throws { _ = try await database.save(subscription) }
  func delete(_ id: CKSubscription.ID) async throws { _ = try await database.deleteSubscription(withID: id) }
}
