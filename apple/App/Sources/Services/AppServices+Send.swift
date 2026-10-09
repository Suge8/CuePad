import CueStore
import Foundation
import UniformTypeIdentifiers
#if os(macOS)
import CuePi
#else
import UIKit
#endif

/// 发给 Agent 与复制：正文解析 → 落地 → 发给 Agent 成功后记一条发送记录（复制不是发送，不记）。
extension AppServices {
    /// 发送已经成功：记录写失败时抛 `SendError.unrecorded`，与发送失败区分开，界面按已发出处理（不重发）并提示。
    func recordSend(_ storedText: String, to target: SendTarget, card: UUID?) async throws {
        do {
            try await store.recordSend(storedText, to: target, card: card)
        } catch {
            throw SendError.unrecorded(error.localizedDescription)
        }
    }

    /// 复制正文（存储格式，变量已填）：文字与图片按原顺序放进系统剪贴板。
    func copy(_ storedText: String) throws {
        let content = SendContent(stored: storedText)
        #if os(macOS)
        try channels.copy(ClipboardContent(try content.segments.map { segment in
            switch segment {
            case .text(let text): .text(text)
            case .image(let hash): .image(try pngData(for: hash))
            }
        }))
        #else
        // 每段文字、每张图片各一个条目，按原顺序：目标应用能取到哪些由它决定
        pasteboard.setItems(try content.segments.compactMap { segment -> [String: Any]? in
            switch segment {
            case .text(let text): text.isEmpty ? nil : [UTType.utf8PlainText.identifier: text]
            case .image(let hash): [UTType.png.identifier: try pngData(for: hash)]
            }
        })
        #endif
    }

    func pngData(for hash: String) throws -> Data {
        guard let png = ImageFiles.png(from: try imageData(hash)) else { throw SendError.imageUnavailable(hash) }
        return png
    }

    func imageData(_ hash: String) throws -> Data {
        guard let url = images.fileURL(for: hash), let data = try? ImageFiles.original(at: url) else {
            throw SendError.imageUnavailable(hash)
        }
        return data
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
        guard let session = channels.piSession(id) else { throw PiBridgeError.unknownSession(id) }
        if mode == .send, session.isBusy { throw SendError.piSessionBusy }
        guard deliveryExecutor != nil else { throw SendError.executorUnavailable }
        let request = try await store.requestDelivery(storedText, to: session.target, on: hostID, mode: mode, card: card)
        let result = try await outcome(of: request.id)
        if let reason = result.failure { throw SendError.notDelivered(reason) }
    }
}
#endif
