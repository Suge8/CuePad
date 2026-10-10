import CueStore
import Foundation
import UniformTypeIdentifiers
#if os(macOS)
import CuePi
#else
import UIKit
#endif

/// 复制：正文解析 → 放进系统剪贴板。复制不是发送，不记发送记录；发给 Agent 见 `MacExecutor`。
extension AppServices {
    /// 复制正文（存储格式，变量已填）：文字与图片按原顺序放进系统剪贴板。
    func copy(_ storedText: String) throws {
        let content = SendContent(stored: storedText)
        #if os(macOS)
        try Clipboard.write(ClipboardContent(try content.segments.map { segment in
            switch segment {
            case .text(let text): .text(text)
            case .image(let hash): .image(try store.files.png(hash))
            }
        }), to: pasteboard)
        #else
        // 每段文字、每张图片各一个条目，按原顺序：目标应用能取到哪些由它决定
        pasteboard.setItems(try content.segments.compactMap { segment -> [String: Any]? in
            switch segment {
            case .text(let text): text.isEmpty ? nil : [UTType.utf8PlainText.identifier: text]
            case .image(let hash): [UTType.png.identifier: try store.files.png(hash)]
            }
        })
        #endif
    }
}

#if os(macOS)
extension AppServices {
    /// Mac 上发给 Pi 会话：写一条指定本机的投送请求，等本机执行器按远端请求的同一流程执行（送达、发送记录、任务关联）
    /// 后返回；发给 Pi 的东西不论来自哪台设备都只有投送请求这一种记录，真正调用 Pi 桥的只有执行器。
    /// 直接发送而会话正忙时不写请求，抛 `SendError.piSessionBusy`；执行器没在运行时不写请求（写了也没人执行）。
    func send(
        _ storedText: String, to id: CuePi.PiSession.ID, mode: DeliveryMode, card: UUID?
    ) async throws {
        guard let session = pi.session(id: id) else { throw PiBridgeError.unknownSession(id) }
        if mode == .send, session.state.isTurnRunning { throw SendError.piSessionBusy }
        guard executor.isRunning else { throw SendError.executorUnavailable }
        let request = try await store.requestDelivery(storedText, to: session.sendTarget, on: hostID, mode: mode, card: card)
        let result = try await outcome(of: request.id)
        if let reason = result.failure { throw SendError.notDelivered(reason) }
    }
}

extension CuePi.PiSession {
    /// 发送记录与投送请求里指这个会话的目标（`ref` 是 Pi 自己的会话 id）。
    var sendTarget: SendTarget { SendTarget(kind: .piSession, name: displayName, ref: sessionID) }
}
#endif
