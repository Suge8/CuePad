#if DEBUG
import Foundation

/// 通话验收的两份日志：`-CuePadVoiceLog <文件>` 每行 `<距起点秒> <节点>`（每记一行整份重写），
/// `-CuePadVoiceWireLog <文件>` 是控制连接收到的原始事件。
final class DebugVoiceLog {
    private let file = DebugScene.args.voiceOpts.log.map { URL(filePath: $0) }
    private let started = Date.now
    private var lines: [String] = []

    func note(_ line: String) {
        lines.append(String(format: "%.3f ", Date.now.timeIntervalSince(started)) + line)
        guard let file else { return }
        do { try lines.joined(separator: "\n").appending("\n").write(to: file, atomically: true, encoding: .utf8) }
        catch { DebugScene.abandon("通话节点没能记录", error) }
    }

    static func wire(_ text: String) {
        guard let path = DebugScene.args.voiceOpts.wireLog else { return }
        do {
            let url = URL(filePath: path)
            if !FileManager.default.fileExists(atPath: path) { try Data().write(to: url) }
            let file = try FileHandle(forWritingTo: url)
            defer { try? file.close() }
            try file.seekToEnd()
            try file.write(contentsOf: Data(("\(Date.now.timeIntervalSince1970) " + text + "\n").utf8))
        } catch { DebugScene.abandon("语音控制事件没能记录", error) }
    }
}
#endif
