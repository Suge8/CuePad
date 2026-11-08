#if os(macOS) && DEBUG
import Foundation

/// -CuePadVoiceMotion normal|rapid，配 -CuePadVoiceLayout idle。注入隔离协议回合与音轨；连接、静音、结束和重连走正式动作。
/// -CuePadVoiceMotionTrace YES：记录声纹层的播放门与已挂循环数，可与 -CuePadRightCycle YES、-CuePadReduceMotion YES 合用。
/// normal 留足阅读时间；rapid 每 90ms 反向一次，短于 Motion.glide，用来检查中途改向。
/// 日志 voice-motion <秒> <事件> 是录像与 A/B 的事件指针；音量为隔离合成采样，不能证明真实音轨。
enum DebugVoiceMotion {
    static var enabled: Bool { DebugScene.defaults.string(forKey: "CuePadVoiceMotion") != nil }
    static let connectionDelay = Duration.milliseconds(700)
    private static let responseDelay = Duration.milliseconds(850)

    static func run(_ workspace: Workspace) async {
        await DebugScene.running("通话连续转场") {
            let began = ContinuousClock.now
            @MainActor func mark(_ label: String) {
                let elapsed = began.duration(to: .now)
                let state = "activity=\(String(describing: workspace.voicePresentation?.activity)) waiting=\(workspace.voice?.waitingForResponse == true) turns=\(workspace.voice?.assistantTurns.count ?? 0)"
                FileHandle.standardError.write(Data("voice-motion \(elapsed) \(label) \(state)\n".utf8))
            }
            try await Task.sleep(for: .seconds(2))
            mark("connect")
            workspace.startVoiceCall()
            guard let call = workspace.voice else { throw CocoaError(.coderValueNotFound) }
            for await phase in Observations({ call.phase }) where phase == .listening { break }
            mark("listen")
            call.inputs.continuation.yield(.wire(.success(.turn(id: "motion-user", assistant: false, done: false, text: ""))))
            try await sound(call, side: .input, count: 30)
            mark("process")
            let request = String(localized: "检查发布事项 \(1)", table: "Demo")
            call.inputs.continuation.yield(.wire(.success(.turn(id: "motion-user", assistant: false, done: true, text: request))))
            call.inputs.continuation.yield(.wire(.success(.delegation(.init(id: "motion-request", turn: "motion-user", text: request)))))
            // 隔离服务晚些才创建助手回合；写库不承担“等待回应”的显示语义。
            try await Task.sleep(for: responseDelay)
            mark("speak")
            call.inputs.continuation.yield(.wire(.success(.turn(id: "motion-assistant", assistant: true, done: false, text: ""))))
            call.inputs.continuation.yield(.peer(.level(.output, loud: true, peak: 0.7)))
            try await sound(call, side: .output, count: 15)
            call.inputs.continuation.yield(.peer(.level(.output, loud: false, peak: 0)))
            try await Task.sleep(for: .milliseconds(350))
            mark("quiet-within-turn")
            guard workspace.voicePresentation?.activity == .speaking else { throw CocoaError(.coderInvalidValue) }
            call.inputs.continuation.yield(.peer(.level(.output, loud: true, peak: 0.7)))
            try await sound(call, side: .output, count: 20)
            mark("interrupt")
            call.inputs.continuation.yield(.wire(.success(.turn(id: "motion-assistant", assistant: true, done: true, text: ""))))
            call.inputs.continuation.yield(.peer(.level(.output, loud: false, peak: 0)))
            try await sound(call, side: .input, count: 20)
            if DebugScene.defaults.string(forKey: "CuePadVoiceMotion") == "rapid" {
                for index in 0..<12 {
                    mark("reverse-\(index)")
                    call.inputs.continuation.yield(.wire(.success(.turn(
                        id: "motion-reverse-\(index / 2)", assistant: true, done: !index.isMultiple(of: 2), text: ""))))
                    // level 只选择波形读取哪条音轨，不能驱动听说阶段。
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
