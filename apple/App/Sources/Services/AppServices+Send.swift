import CueStore
import Foundation
import UniformTypeIdentifiers
#if os(macOS)
import CuePi
#else
import UIKit
#endif

/// 复制：正文解析 → 放进系统剪贴板。复制不是发送，不记发送记录；交给 Agent 见 `MacExecutor`。
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
        try await deliver(storedText, to: session.sendTarget, mode: mode, card: card)
    }

    /// 发给别的 Mac 上在线的会话：与手机同一条通路，写一条指定那台 Mac 的投送请求并立即上传，由它的执行器送达；这里不等结果
    /// （会话行上有送达的进度，没送到会写"没能送达"）。直接发送而会话正忙时不写请求，抛 `SendError.piSessionBusy`。
    func send(_ storedText: String, toRemote session: PiSessionState, mode: DeliveryMode, card: UUID?) async throws {
        if mode == .send, session.state.known?.isTurnRunning == true { throw SendError.piSessionBusy }
        try await requestMacDelivery(storedText, to: session, mode: mode, card: card)
    }

    /// 发给已结束的会话（`name` 是它的会话名）：同样写一条指定本机的投送请求，执行器先用会话索引里的会话文件在后台把它恢复起来再送达。
    /// 索引里没有这个会话（会话文件不在这台 Mac 上）时请求带原因失败，抛 `SendError.notDelivered`。
    /// 固定直接发送（`.send`）：会话已结束，没有正在跑的一轮，"马上说""等它做完再说"都不适用。
    func send(_ storedText: String, toEnded sessionID: String, named name: String, card: UUID?) async throws {
        try await deliver(storedText, to: SendTarget(kind: .piSession, name: name, ref: sessionID), mode: .send, card: card)
    }

    private func deliver(_ storedText: String, to target: SendTarget, mode: DeliveryMode, card: UUID?) async throws {
        guard executor.isRunning else { throw SendError.executorUnavailable }
        let request = try await store.requestDelivery(storedText, to: target, on: hostID, mode: mode, card: card)
        let result = try await outcome(of: request.id)
        if let reason = result.failure { throw SendError.notDelivered(reason) }
    }
}

extension CuePi.PiSession {
    /// 发送记录与投送请求里指这个会话的目标（`ref` 是 Pi 自己的会话 id）。
    var sendTarget: SendTarget { SendTarget(kind: .piSession, name: displayName, ref: sessionID) }
}
#endif
