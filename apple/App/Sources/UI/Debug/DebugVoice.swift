#if os(macOS) && DEBUG
import Foundation
import WebKit

/// 回环处理开关只允许用在本次创建的临时设备上；生产麦克风的约束保持 VoicePeer 中的默认值。
/// `-CuePadVoiceProcessing <echo|noise|gain|all>` 将指定处理约束设为 false；未给时保持默认请求，实际支持与启用状态由 WebKit 决定。
/// `-CuePadVoiceMeter YES` 只测本地 getUserMedia，不建实时通话、不调用 Cue。
enum DebugVoice {
    static func wire(_ text: String) {
        guard let path = DebugScene.defaults.string(forKey: "CuePadVoiceWireLog") else { return }
        do {
            let url = URL(filePath: path)
            if !FileManager.default.fileExists(atPath: path) { try Data().write(to: url) }
            let file = try FileHandle(forWritingTo: url)
            defer { try? file.close() }
            try file.seekToEnd()
            try file.write(contentsOf: Data(("\(Date.now.timeIntervalSince1970) " + text + "\n").utf8))
        } catch { DebugScene.abandon("语音控制事件没能记录", error) }
    }

    static func configure(_ web: WKWebView, source: VoicePeer.Source) async throws {
        guard case .microphone(let device) = source,
              device == "CuePad Voice \(getpid())",
              DebugScene.defaults.string(forKey: "CuePadVoiceLoopback") != nil,
              let mode = DebugScene.defaults.string(forKey: "CuePadVoiceProcessing") else { return }
        let keys: [String]
        switch mode {
        case "echo": keys = ["echoCancellation"]
        case "noise": keys = ["noiseSuppression"]
        case "gain": keys = ["autoGainControl"]
        case "all": keys = ["echoCancellation", "noiseSuppression", "autoGainControl"]
        default: throw CocoaError(.coderInvalidValue)
        }
        _ = try await web.callAsyncJavaScript("for (const key of keys) audio[key] = false", arguments: ["keys": keys], contentWorld: .page)
    }

    static func meter(_ loopback: VoiceLoopback, note: @escaping (String) -> Void) async throws {
        let peer = VoicePeer(source: .microphone(device: loopback.name), recording: nil)
        peer.onEvent = { note("meter \($0)") }
        do {
            _ = try await peer.offer()
            note("play first.wav")
            try loopback.play()
            try await Task.sleep(for: .seconds(loopback.duration + 2))
            note("input-max \(await peer.inputMax()) tap-peak \(loopback.peak)")
            try await peer.close()
        } catch {
            try await peer.close()
            throw error
        }
    }
}
#endif
