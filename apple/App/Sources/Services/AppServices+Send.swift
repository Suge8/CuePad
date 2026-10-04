import CueStore
import Foundation
import UniformTypeIdentifiers
#if os(macOS)
import CueDispatch
import CuePi
#else
import UIKit
#endif

/// 发送：正文解析 → 按目标落地 → 成功后记一条发送记录。
extension AppServices {
    func deliver(_ content: SendContent, to destination: Destination) async throws -> SendTarget {
        switch destination {
        #if os(macOS)
        case .pi(let id, let mode): try await sendToPi(content, session: id, mode: mode)
        case .app(let selector): try await dispatch(content, to: selector, submit: settings.autoSubmit)
        #endif
        case .clipboard: try copyToClipboard(content)
        }
    }

    /// 投送已经成功：记录写失败时抛 `SendError.unrecorded`，与投送失败区分开，界面按已发出处理（不重发）并提示。
    func recordSend(_ storedText: String, to target: SendTarget, card: UUID?, task: UUID?) async throws {
        do {
            try await store.recordSend(storedText, to: target, card: card, task: task)
        } catch {
            throw SendError.unrecorded(error.localizedDescription)
        }
    }

    private func copyToClipboard(_ content: SendContent) throws -> SendTarget {
        #if os(macOS)
        try channels.copy(payload(content))
        #else
        // 每段文字、每张图片各一个条目，按原顺序：目标应用能取到哪些由它决定
        pasteboard.setItems(try content.segments.compactMap { segment -> [String: Any]? in
            switch segment {
            case .text(let text): text.isEmpty ? nil : [UTType.utf8PlainText.identifier: text]
            case .image(let hash): [UTType.png.identifier: try pngData(for: hash)]
            }
        })
        #endif
        return SendTarget(kind: .clipboard, name: "剪贴板")
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
    /// Mac 上发给 Pi 会话：写一条指定本机的投送请求，由本机执行器按远端请求的同一流程执行（送达、发送记录、任务关联），
    /// 发给 Pi 的东西不论来自哪台设备都只有投送请求这一种记录。直接发送而会话正忙时不写请求，抛 `SendError.piSessionBusy`。
    func requestPiDelivery(
        _ storedText: String, to id: CuePi.PiSession.ID, mode: DeliveryMode, card: UUID? = nil, task: UUID? = nil
    ) async throws -> DeliveryRequest {
        guard let session = channels.piSession(id) else { throw PiBridgeError.unknownSession(id) }
        if mode == .send, session.isBusy { throw SendError.piSessionBusy }
        return try await store.requestDelivery(storedText, to: session.target, on: hostID, mode: mode, card: card, task: task)
    }

    /// 等到投送请求有结果（已送达或没能送达）。请求在等待期间被删掉时抛 `CueStoreError.notFound`。
    func outcome(of request: UUID) async throws -> DeliveryRequest {
        for try await current in store.observe([.deliveryRequests], { try $0.deliveryRequest(request) }) {
            guard let current else { throw CueStoreError.notFound }
            if current.status != .known(.pending), current.status != .known(.executing) { return current }
        }
        throw CancellationError()
    }

    /// Pi 桥只认插话/排队两种入队方式：发送方式在这里一次性落到桥的消息上。
    private func sendToPi(_ content: SendContent, session id: CuePi.PiSession.ID, mode: DeliveryMode) async throws -> SendTarget {
        guard let session = channels.piSession(id) else { throw PiBridgeError.unknownSession(id) }
        let whenBusy: PiQueueMode?
        switch mode {
        case .paste:
            guard !content.hasImages else { throw SendError.imagesNotSupported }
            try await channels.paste(content.plainText, into: id)
            return session.target
        case .send:
            guard !session.isBusy else { throw SendError.piSessionBusy }
            whenBusy = nil
        case .steer: whenBusy = .steer
        case .followUp: whenBusy = .followUp
        }
        let images = try content.segments.compactMap { segment -> PiImage? in
            guard case .image(let hash) = segment else { return nil }
            let data = try imageData(hash)
            guard let mimeType = ImageFiles.mimeType(of: data) else { throw SendError.imageUnavailable(hash) }
            return PiImage(mimeType: mimeType, data: data)
        }
        try await channels.send(PiMessage(text: content.plainText, images: images, whenBusy: whenBusy), to: id)
        return session.target
    }

    /// 预检失败时窗口不动；预检通过后先隐藏窗口，投送失败再恢复。
    private func dispatch(_ content: SendContent, to selector: TargetSelector, submit: Bool) async throws -> SendTarget {
        let payload = try payload(content)
        try await channels.preflight(selector)
        windowShell?.hide()
        do {
            let app = try await channels.dispatch(payload, to: selector, submit: submit)
            return SendTarget(kind: .app, name: app.name, ref: app.bundleID)
        } catch {
            windowShell?.show()
            throw error
        }
    }

    func payload(_ content: SendContent) throws -> Payload {
        Payload(try content.segments.map { segment in
            switch segment {
            case .text(let text):
                return .text(text)
            case .image(let hash):
                return .image(try pngData(for: hash))
            }
        })
    }
}
#endif
