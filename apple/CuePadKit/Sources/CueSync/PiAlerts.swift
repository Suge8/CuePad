import CloudKit
import Foundation

/// 手机锁屏上的 Pi 通知种类。
public enum PiAlertKind: Sendable, Equatable {
  case waitingForUser
  case settled

  init?(subscriptionID: String) {
    switch subscriptionID {
    case PiAlertSubscriptions.waitingID: self = .waitingForUser
    case PiAlertSubscriptions.settledID: self = .settled
    default: return nil
    }
  }
}

/// 点通知得到的路由信息：哪种通知、对应的 Pi 会话状态记录（`PiSessionState.id`）。
public struct PiAlertTap: Equatable, Sendable {
  public var kind: PiAlertKind
  public var sessionState: UUID

  public init(kind: PiAlertKind, sessionState: UUID) {
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
      let subscriptionID = notification.subscriptionID, let kind = PiAlertKind(subscriptionID: subscriptionID),
      let name = notification.recordID?.recordName, let id = UUID(uuidString: name)
    else { return nil }
    return PiAlertTap(kind: kind, sessionState: id)
  }
}

/// 一个账号私有数据库里的订阅（真实实现是 CKDatabase）。
protocol SubscriptionStore: Sendable {
  func subscriptions() async throws -> [CKSubscription.ID: CKSubscription]
  func save(_ subscription: CKSubscription) async throws
  func delete(_ id: CKSubscription.ID) async throws
}

/// 两个 CloudKit 服务端订阅：Pi 会话状态记录的 `notify` 标志置位时，服务端直接生成可见通知。
/// 不依赖静默推送与 App 在后台运行。通知文案只用本地化 key 的通用句：标题与详情是加密字段，不可能出现在通知里；
/// 也不设 `desiredKeys`。只订阅创建与更新（删除不通知）。谓词按标志而不是按状态，因为"同一状态下的重复更新"
/// 与"从工作中进入完成"这类转换在谓词里表达不了；标志只在转换那一次写入上置位（见 `PiStateRecorder`）。
/// 通知反映"服务端收到记录那一刻"的状态：标志所在的那次写入若在上传前被后续写入取代，就不会通知（有意如此）。
/// 上线前需在 CloudKit Dashboard 里为 `piSessionStates.notify` 建立可查询索引（开发环境自动建立）。
struct PiAlertSubscriptions {
  static let prefix = "cuepad.pi."
  static let waitingID = prefix + "waiting"
  static let settledID = prefix + "settled"

  let zoneID: CKRecordZone.ID

  func desired() -> [CKQuerySubscription] {
    [
      make(id: Self.waitingID, flag: "waitingForUser", key: PiAlertRoute.waitingLocalizationKey),
      make(id: Self.settledID, flag: "settled", key: PiAlertRoute.settledLocalizationKey),
    ]
  }

  /// 幂等：缺的创建，与期望不一致的替换，本前缀下多余的删除，别人的订阅不碰。
  /// 账号切换后新账号的数据库里没有这些订阅，再调用一次即重建。
  func ensure(in store: any SubscriptionStore) async throws {
    let existing = try await store.subscriptions()
    let wanted = desired()
    let wantedIDs = Set(wanted.map(\.subscriptionID))
    for id in existing.keys where id.hasPrefix(Self.prefix) && !wantedIDs.contains(id) { try await store.delete(id) }
    for subscription in wanted where !Self.matches(existing[subscription.subscriptionID], subscription) {
      try await store.save(subscription)
    }
  }

  private func make(id: String, flag: String, key: String) -> CKQuerySubscription {
    let subscription = CKQuerySubscription(
      recordType: RecordMapper.recordType(for: .piSessionStates), predicate: NSPredicate(format: "notify == %@", flag),
      subscriptionID: id, options: [.firesOnRecordCreation, .firesOnRecordUpdate])
    subscription.zoneID = zoneID
    let info = CKSubscription.NotificationInfo()
    info.alertLocalizationKey = key
    info.soundName = "default"
    subscription.notificationInfo = info
    return subscription
  }

  private static func matches(_ existing: CKSubscription?, _ wanted: CKQuerySubscription) -> Bool {
    guard let existing = existing as? CKQuerySubscription else { return false }
    return existing.recordType == wanted.recordType && existing.predicate.predicateFormat == wanted.predicate.predicateFormat
      && existing.zoneID == wanted.zoneID && existing.querySubscriptionOptions == wanted.querySubscriptionOptions
      && existing.notificationInfo?.alertLocalizationKey == wanted.notificationInfo?.alertLocalizationKey
      && existing.notificationInfo?.shouldSendContentAvailable == wanted.notificationInfo?.shouldSendContentAvailable
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
