import CloudKit
import CueSync
import OSLog
import Synchronization
import UserNotifications

/// 通知服务扩展：Pi 与 Cue 的锁屏通知到达时，取回触发它的记录（同一 iCloud 容器，加密字段在设备上解密），
/// 把通用句改写成"会话名 + 问题首句（或状态）"、"Cue 的名字 + 它说的话"（"等你"是要你定什么与选项，消息与 Cue 的设置一次取回）。
/// 取不到（没网、超时、记录已删）就保持通用句。
/// 系统在任意线程调用 `didReceive` 与 `serviceExtensionTimeWillExpire`，取回记录的回调又在另一条线程：
/// 手里的内容与交付回调放在一把锁里，只交付一次。
@objc(NotificationService)
final class NotificationService: UNNotificationServiceExtension, @unchecked Sendable {
    /// 内容与回调是系统框架的非 Sendable 类型，只在锁里碰。
    private struct Pending: @unchecked Sendable {
        var content: UNMutableNotificationContent
        var deliver: (UNNotificationContent) -> Void
    }

    private static let container = "iCloud.com.sugeh.cuepad"
    private static let log = Logger(subsystem: "com.sugeh.cuepad", category: "notify")
    private let pending = Mutex<Pending?>(nil)

    override func didReceive(_ request: UNNotificationRequest, withContentHandler handler: @escaping (UNNotificationContent) -> Void) {
        let userInfo = request.content.userInfo
        guard let content = request.content.mutableCopy() as? UNMutableNotificationContent,
              let notification = CKNotification(fromRemoteNotificationDictionary: userInfo) as? CKQueryNotification,
              let recordID = notification.recordID
        else { return handler(request.content) }
        let database = CKContainer(identifier: Self.container).privateCloudDatabase
        switch CloudAlert(userInfo: userInfo) {
        case .cue:
            pending.withLock { $0 = Pending(content: content, deliver: handler) }
            let profile = CKRecord.ID(recordName: CueProfile.syncRecordName, zoneID: recordID.zoneID)
            database.fetch(withRecordIDs: [recordID, profile]) { result in
                let records = (try? result.get()) ?? [:]
                guard let message = try? records[recordID]?.get() else { return self.finish() }
                if let text = CueAlertText.content(message: message, profile: try? records[profile]?.get()) { self.apply(text) }
                self.finish()
            }
        case .session(let tap):
            pending.withLock { $0 = Pending(content: content, deliver: handler) }
            let kind = tap.kind
            database.fetch(withRecordID: recordID) { record, _ in
                if let record, let text = PiAlertText.content(for: record, kind: kind) { self.apply(text) }
                self.finish()
            }
        case nil: handler(request.content)
        }
    }

    /// 时间快用完：交出手里已有的（改写过就是改写后的，否则是通用句）。
    override func serviceExtensionTimeWillExpire() {
        finish()
    }

    private func apply(_ text: (title: String, body: String)) {
        Self.log.notice("改写通知：标题 \(text.title, privacy: .private)，正文 \(text.body, privacy: .private)")
        pending.withLock {
            $0?.content.title = text.title
            $0?.content.body = text.body
        }
    }

    private func finish() {
        guard let done = pending.withLock({ pending in defer { pending = nil }; return pending }) else { return }
        done.deliver(done.content)
    }
}
