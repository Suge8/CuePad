#if os(macOS) && DEBUG
import Foundation

/// -CuePadVoiceMotion normal|rapid，配 -CuePadVoiceLayout idle。只注入媒体事件；连接、静音、结束和重连走正式动作。
/// -CuePadVoiceMotionTrace YES：记录声纹层的播放门与已挂循环数，可与 -CuePadRightCycle YES、-CuePadReduceMotion YES 合用。
/// normal 留足阅读时间；rapid 每 90ms 反向一次，短于 Motion.glide，用来检查中途改向。
/// 日志 voice-motion <秒> <事件> 是录像与 A/B 的事件指针；音量为隔离合成采样，不能证明真实音轨。
enum DebugVoiceMotion {
    static var enabled: Bool { DebugScene.defaults.string(forKey: "CuePadVoiceMotion") != nil }
    static let connectionDelay = Duration.milliseconds(700)
    static let recordingDelay = Duration.milliseconds(850)

    static func run(_ workspace: Workspace) async {
        await DebugScene.running("通话连续转场") {
            let began = ContinuousClock.now
            func mark(_ label: String) {
                let elapsed = began.duration(to: .now)
                FileHandle.standardError.write(Data("voice-motion \(elapsed) \(label)\n".utf8))
            }
            try await Task.sleep(for: .seconds(2))
            mark("connect")
            workspace.startVoiceCall()
            guard let call = workspace.voice else { throw CocoaError(.coderValueNotFound) }
            for await phase in Observations({ call.phase }) where phase == .listening { break }
            mark("listen")
            try await sound(call, side: .input, count: 30)
            mark("process")
            call.inputs.continuation.yield(.wire(.success(.delegation(.init(id: "motion-request", turn: nil, text: String(localized: "检查发布事项 \(1)", table: "Demo"))))))
            for await phase in Observations({ call.phase }) where phase == .handingOff { break }
            for await phase in Observations({ call.phase }) where phase == .listening { break }
            mark("speak")
            call.inputs.continuation.yield(.peer(.level(.output, loud: true, peak: 0.7)))
            try await sound(call, side: .output, count: 35)
            mark("interrupt")
            call.inputs.continuation.yield(.peer(.level(.output, loud: false, peak: 0)))
            try await sound(call, side: .input, count: 20)
            if DebugScene.defaults.string(forKey: "CuePadVoiceMotion") == "rapid" {
                for index in 0..<12 {
                    mark("reverse-\(index)")
                    call.inputs.continuation.yield(.peer(.level(.output, loud: index.isMultiple(of: 2), peak: 0.8)))
                    call.setMuted(index.isMultiple(of: 2))
                    try await Task.sleep(for: .milliseconds(90))
                }
            }
            mark("mute")
            call.setMuted(true)
            try await Task.sleep(for: .seconds(1))
            mark("unmute")
            call.setMuted(false)
            try await sound(call, side: .input, count: 20)
            mark("close")
            call.hangUp()
            for await live in Observations({ call.isLive }) where !live { break }
            mark("ended")
            try await Task.sleep(for: .seconds(1))
            mark("reconnect")
            workspace.startVoiceCall()
            for await phase in Observations({ call.phase }) where phase == .listening { break }
            try await sound(call, side: .input, count: 20)
            mark("failure")
            call.inputs.continuation.yield(.failed(.media))
            for await live in Observations({ call.isLive }) where !live { break }
            try await Task.sleep(for: .seconds(1))
            mark("recover")
            try await workspace.recoverVoice(.reconnect)
            for await phase in Observations({ call.phase }) where phase == .listening { break }
            try await sound(call, side: .input, count: 20)
            mark("finished")
        }
    }

    private static func sound(_ call: VoiceCall, side: VoicePeer.Side, count: Int) async throws {
        for index in 0..<count {
            let peak = 0.12 + 0.65 * abs(sin(Double(index) * 0.47))
            call.inputs.continuation.yield(.peer(.sample(side, peak: peak)))
            try await Task.sleep(for: .milliseconds(50))
        }
    }
}
#endif
