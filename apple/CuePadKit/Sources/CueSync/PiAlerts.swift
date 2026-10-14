import CloudKit
import CueStore
import CueText
import Foundation

extension PiAlert {
  /// 哪个订阅触发的通知（锁屏通知种类就是 `PiAlert`）。
  init?(subscriptionID: String) {
    switch subscriptionID {
    case AlertSubscriptions.waitingID: self = .waitingForUser
    case AlertSubscriptions.settledID: self = .settled
    default: return nil
    }
  }
}

/// 点通知得到的路由信息：哪种通知、对应的 Pi 会话状态记录（`PiSessionState.id`）。
public struct PiAlertTap: Equatable, Sendable {
  public var kind: PiAlert
  public var sessionState: UUID

  public init(kind: PiAlert, sessionState: UUID) {
    self.kind = kind
    self.sessionState = sessionState
  }
}

public enum PiAlertRoute {
  /// 本地化文案 key：App 的 Localizable.strings 里提供"Pi 在等你确认"与"Pi 完成了"。
  public static let waitingLocalizationKey = "pi_alert_waiting"
  public static let settledLocalizationKey = "pi_alert_settled"

  /// 从点开的通知的 userInfo 里取出路由信息（CloudKit 通知自带触发它的记录 id 与订阅 id）；不是 Pi 通知返回 nil。
  public static func tap(from userInfo: [AnyHashable: Any]) -> PiAlertTap? {
    guard let notification = CKNotification(fromRemoteNotificationDictionary: userInfo) as? CKQueryNotification,
      let subscriptionID = notification.subscriptionID, let kind = PiAlert(subscriptionID: subscriptionID),
      let name = notification.recordID?.recordName, let id = UUID(uuidString: name)
    else { return nil }
    return PiAlertTap(kind: kind, sessionState: id)
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
    return content(title: title, question: question, kind: kind)
  }

  /// 等你确认：标题"会话名 在等你"，正文是问题首行（没有问题文案时写"去看看它在问什么"）；完成：标题会话名，正文"完成了"。
  public static func content(title: String, question: String?, kind: PiAlert) -> (title: String, body: String) {
    switch kind {
    case .waitingForUser:
      let first = question?.split(whereSeparator: \.isNewline).first.map(String.init)?.trimmingCharacters(in: .whitespaces)
      return ("\(title) 在等你", first.flatMap { $0.isEmpty ? nil : $0 } ?? "去看看它在问什么")
    case .settled:
      return (title, "完成了")
    }
  }
}

/// Cue 的手机通知（"等你"与 urgent 的 Cue 消息，值班的 Mac 置位 `cueMessages.notify`）：点开进 Cue 页；文案由通知服务扩展按记录改写。
public enum CueAlertRoute {
  /// 本地化文案 key：改写不成时显示的通用句。
  public static let localizationKey = "cue_alert"

  /// 点开的通知是 Cue 的就给出那条消息的 id；别的通知为 nil。
  public static func message(from userInfo: [AnyHashable: Any]) -> UUID? {
    guard let notification = CKNotification(fromRemoteNotificationDictionary: userInfo) as? CKQueryNotification,
      notification.subscriptionID == AlertSubscriptions.cueID, let name = notification.recordID?.recordName
    else { return nil }
    return UUID(uuidString: name)
  }
}

/// 从通知取回的 Cue 消息与设置记录里读出文案的材料，交给 `CueAlert`（文案规则只在那里）。
public enum CueAlertText {
  public static func content(message: CKRecord, profile: CKRecord?) -> (title: String, body: String)? {
    guard let text = message.encryptedValues["text"] as? String else { return nil }
    let choices = (message.encryptedValues["choices"] as? String).flatMap { try? JSONDecoder().decode([String].self, from: Data($0.utf8)) }
    return CueAlert.content(name: profile?.encryptedValues["name"] as? String, text: text, choices: choices)
  }
}

/// 一个账号私有数据库里的订阅（真实实现是 CKDatabase）。
protocol SubscriptionStore: Sendable {
  func subscriptions() async throws -> [CKSubscription.ID: CKSubscription]
  func save(_ subscription: CKSubscription) async throws
  func delete(_ id: CKSubscription.ID) async throws
}

/// CloudKit 服务端订阅：Pi 会话状态记录（等你确认、完成两个）与 Cue 消息（一个）的 `notify` 标志置位时，服务端直接生成可见通知。
/// 不依赖静默推送与 App 在后台运行。通知文案只用本地化 key 的通用句：标题与详情是加密字段，不可能出现在通知里；
/// 也不设 `desiredKeys`。只订阅创建与更新（删除不通知）。谓词按标志而不是按状态，因为"同一状态下的重复更新"
/// 与"从工作中进入完成"这类转换在谓词里表达不了；标志只在转换那一次写入上置位（见 `PiStateRecorder`）。
/// 标志在上传前会被同状态的更新沿用；状态已前进或会话已结束时未上传的标志作废（见 `PiStateRecorder`）。
/// 两张表的 `notify` 可查询索引由生成的数据结构声明（`RecordMapper.queryableColumns`，见 docs/release.md「CloudKit 数据结构」）。
/// 生产环境拒绝客户端创建没部署过的查询订阅（"attempting to create a subscription in a production container"，
/// 区域与数据库订阅不受限）：订阅类型是 schema 的一部分，不在 .ckdb 里，只能在开发环境用同样的定义建一次，再在控制台
/// 「Deploy Schema Changes」。所以改订阅定义（谓词、选项、通知文案 key）等于改 schema，要重做这两步。
struct AlertSubscriptions {
  /// 通知标志字段（明文、可查询）。
  static let flagField = "notify"
  /// 本前缀下的订阅都是这里管的（多余的删掉）。
  static let prefix = "cuepad."
  static let waitingID = prefix + "pi.waiting"
  static let settledID = prefix + "pi.settled"
  static let cueID = prefix + "cue"

  let zoneID: CKRecordZone.ID

  func desired() -> [CKQuerySubscription] {
    [
      make(.piSessionStates, id: Self.waitingID, flag: "waitingForUser", key: PiAlertRoute.waitingLocalizationKey),
      make(.piSessionStates, id: Self.settledID, flag: "settled", key: PiAlertRoute.settledLocalizationKey),
      make(.cueMessages, id: Self.cueID, flag: CueMessage.notifyFlag, key: CueAlertRoute.localizationKey),
    ]
  }

  /// 幂等：缺的创建，与期望不一致的替换，本前缀下多余的删除，别人的订阅不碰。
  /// 账号切换后新账号的数据库里没有这些订阅，再调用一次即重建。失败不抛：结果就是状态，原因交给界面。
  func ensure(in store: any SubscriptionStore) async -> PiAlertSubscriptionStatus {
    do {
      let existing = try await store.subscriptions()
      let wanted = desired()
      let wantedIDs = Set(wanted.map(\.subscriptionID))
      for id in existing.keys where id.hasPrefix(Self.prefix) && !wantedIDs.contains(id) { try await store.delete(id) }
      for subscription in wanted where !Self.matches(existing[subscription.subscriptionID], subscription) {
        try await store.save(subscription)
      }
      return .active
    } catch {
      return .failed(error.diagnosis)
    }
  }

  private func make(_ table: Table, id: String, flag: String, key: String) -> CKQuerySubscription {
    let subscription = CKQuerySubscription(
      recordType: RecordMapper.recordType(for: table), predicate: NSPredicate(format: "%K == %@", Self.flagField, flag),
      subscriptionID: id, options: [.firesOnRecordCreation, .firesOnRecordUpdate])
    subscription.zoneID = zoneID
    let info = CKSubscription.NotificationInfo()
    info.alertLocalizationKey = key
    info.soundName = "default"
    // 让手机上的通知服务扩展先拿到通知，按记录改写成会话名与问题、Cue 说的话（加密字段只能在设备上读）
    info.shouldSendMutableContent = true
    subscription.notificationInfo = info
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

/// 私有数据库作为订阅存储。
struct DatabaseSubscriptions: SubscriptionStore {
  let database: CKDatabase

  func subscriptions() async throws -> [CKSubscription.ID: CKSubscription] {
    Dictionary(uniqueKeysWithValues: try await database.allSubscriptions().map { ($0.subscriptionID, $0) })
  }

  func save(_ subscription: CKSubscription) async throws { _ = try await database.save(subscription) }
  func delete(_ id: CKSubscription.ID) async throws { _ = try await database.deleteSubscription(withID: id) }
}
