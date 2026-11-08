#if DEBUG
import Foundation
import Network

/// #89 临时可行性入口：-CuePadSplitVoice mac|ios -CuePadSplitLog <文件>。
/// Mac 另给 -CuePadSplitAuth <已有 auth.json>；只读取，不启动 Codex。只监听回环，不能用作正式跨设备信令。
/// iOS 只连接回环；-CuePadSplitInput <音频文件> 播合成语音，-CuePadSplitMic YES 验麦克风（两者不同时给）。
/// 每次运行两轮，控制回执后观察 15 秒；-CuePadSplitLog 旁的 .0.pcm / .1.pcm 为 24kHz 单声道 s16le。
/// 探针从不向媒体端传凭证。日志仅记录枚举节点、字节数及媒体统计；无服务端挂断确认，不声称计费已结束。
enum DebugSplitVoice {
    static var launched = false
    static let port: NWEndpoint.Port = 18789
    static func startIfAsked() {
        guard !launched, let role = DebugScene.defaults.string(forKey: "CuePadSplitVoice") else { return }
        launched = true
        Task {
            do {
                #if os(macOS)
                if role == "audit" { try await DebugSplitAudit.run() }
                else {
                    guard role == "mac" else { throw ProbeError.invalid }
                    try await DebugSplitHost.run()
                }
                #else
                guard role == "ios" else { throw ProbeError.invalid }
                try await DebugSplitMediaRun.run()
                #endif
                note("complete")
            } catch {
                // 真实服务错误可能含请求内容，不输出 localizedDescription 或原始 body。
                note("failed domain=\((error as NSError).domain) code=\((error as NSError).code)")
            }
        }
    }

    enum ProbeError: Error { case invalid, ended, credential, timeout }

    static func note(_ text: String) {
        guard let path = DebugScene.defaults.string(forKey: "CuePadSplitLog") else { return }
        do {
            if !FileManager.default.fileExists(atPath: path) { try Data().write(to: URL(filePath: path)) }
            let file = try FileHandle(forWritingTo: URL(filePath: path))
            defer { try? file.close() }
            try file.seekToEnd()
            try file.write(contentsOf: Data("\(Date.now.timeIntervalSince1970) \(text)\n".utf8))
        } catch { DebugScene.abandon("探针日志写入失败", error) }
    }

    struct Frame: Codable {
        let kind: String
        let session: UUID
        var sdp: String?
        var detail: String?
    }

    /// 一条回环 TCP 连接只传有类型的信令，限制帧长；生命周期随探针结束。
    final class Pipe {
        let connection: NWConnection
        let frames = AsyncThrowingStream<Frame, Error>.makeStream()
        private var buffer = Data()
        private let scope = DebugSplitScope()
        init(_ connection: NWConnection) { self.connection = connection }

        func start() {
            connection.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self else { return }
                    switch state {
                    case .failed(let error): self.frames.continuation.finish(throwing: error)
                    case .cancelled: self.frames.continuation.finish()
                    default: break
                    }
                }
            }
            connection.start(queue: .main)
            receive()
        }

        func send(_ frame: Frame) async throws {
            var data = try JSONEncoder().encode(frame)
            data.append(10)
            let _: Void = try await scope.wait { finish in
                connection.send(content: data, completion: .contentProcessed { error in
                    Task { @MainActor in
                        if let error { finish(.failure(error)) } else { finish(.success(())) }
                    }
                })
            }
        }

        func close() { scope.end(); connection.cancel(); frames.continuation.finish() }

        private func receive() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, ended, error in
                Task { @MainActor in
                    guard let self else { return }
                    if let data { self.buffer.append(data) }
                    guard self.buffer.count <= 131072 else {
                        self.frames.continuation.finish(throwing: ProbeError.invalid); self.connection.cancel(); return
                    }
                    do {
                        while let index = self.buffer.firstIndex(of: 10) {
                            let frame = try JSONDecoder().decode(Frame.self, from: self.buffer[..<index])
                            self.buffer.removeSubrange(...index)
                            self.frames.continuation.yield(frame)
                        }
                    } catch { self.frames.continuation.finish(throwing: error); self.connection.cancel(); return }
                    if let error { self.frames.continuation.finish(throwing: error) }
                    else if ended { self.frames.continuation.finish() }
                    else { self.receive() }
                }
            }
        }
    }
}
#endif
