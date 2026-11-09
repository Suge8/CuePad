import AVFoundation
import CueStore
import os

/// 一通电话的声音，经 `VoiceAudioDevice` 接到 WebRTC；主线程开关，停了不复用。声源是 `VoiceFixture` 时上行由它送，下行看它的 `downlink`；
/// iOS 的音频会话与中断照常（中断与后台因此能在模拟器上验，`DebugScene+PhoneVoiceCall`）。
/// 麦克风走 AVAudioEngine，打开系统的语音处理（回声消除、降噪、自动增益），WebRTC 自己的那套关掉（`VoicePeer`）。
/// iOS 的音频会话归这里：playAndRecord + voiceChat，默认扬声器、可走蓝牙；会话被打断（来电、Siri、闹钟）或媒体服务重置即结束（`audioInterrupted`），
/// 不假装还在通。换路由（蓝牙、耳机）或 Mac 换设备时引擎自己停下并发配置变化：按新硬件格式重建再开，开不起来才结束。
final class VoiceAudio {
    /// 一次渲染的帧数上限：引擎默认 4096，留余量。
    nonisolated private static let maximumFrames = 16_384
    let device = VoiceAudioDevice()
    private let fixture: VoiceFixture?
    private let levels = VoiceLevels()
    private var engine: AVAudioEngine?
    private var events: (VoicePeer.Event) -> Void = { _ in }
    private var watching: [Task<Void, Never>] = []
    private static let log = Logger(subsystem: AppIdentity.id, category: "voice")

    init(source: VoicePeer.Source) {
        if case .fixture(let fixture) = source { self.fixture = fixture } else { fixture = nil }
    }

    func start(_ events: @escaping (VoicePeer.Event) -> Void) throws {
        self.events = events
        guard let link = device.link else { throw VoicePeerError.unavailable }
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetoothHFP])
        try session.setActive(true)
        #endif
        watching = [
            Task { [levels] in
                var input = VoiceLevels.Gate(), output = VoiceLevels.Gate()
                while (try? await Task.sleep(for: VoiceLevels.Gate.interval)) != nil {
                    let heard = levels.input.take(), said = levels.output.take()
                    events(.sample(.input, peak: heard))
                    events(.sample(.output, peak: said))
                    if let change = input.update(heard) { events(.level(.input, loud: change.loud, peak: change.peak)) }
                    if let change = output.update(said) { events(.level(.output, loud: change.loud, peak: change.peak)) }
                }
            },
        ]
        #if os(iOS)
        watching += [
            // 自己停用前已不再听（`stop`），这里收到的都是被系统或别处收走了会话
            Task {
                for await _ in NotificationCenter.default.notifications(named: AVAudioSession.didBecomeInactiveNotification) {
                    return events(.ended(.audioInterrupted))
                }
            },
            Task {
                for await _ in NotificationCenter.default.notifications(named: AVAudioSession.mediaServicesWereResetNotification) {
                    return events(.ended(.audioInterrupted))
                }
            },
        ]
        #endif
        if let fixture, fixture.downlink != .speaker {
            device.reconfigured(inputRate: VoiceAudioDevice.rate)
            return fixture.start(link: link, levels: levels)
        }
        try build(link)
        fixture?.start(link: link, levels: levels)
        watching.append(Task {
            for await _ in NotificationCenter.default.notifications(named: .AVAudioEngineConfigurationChange) {
                // 引擎停下才发；还在跑的（开语音处理时自己发的那一下）不用重建
                guard let engine, !engine.isRunning else { continue }
                do { try build(link) }
                catch { fail("rebuild", error); return }
            }
        })
    }

    func stop() {
        watching.forEach { $0.cancel() }
        watching = []
        fixture?.stop()
        engine?.stop()
        engine = nil
        #if os(iOS)
        do { try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
        catch { Self.log.error("Voice audio session stayed active: \(error.localizedDescription, privacy: .public)") }
        #endif
    }

    private func fail(_ stage: String, _ error: Error) {
        Self.log.error("Voice audio \(stage, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        events(.ended(.audioInterrupted))
    }

    /// 每次按此刻的硬件格式建一台新引擎：AVAudioEngine 换格式后旧连接的格式不再成立。
    /// 声源是文件时只建扬声器这一半，且不外放（无人值守）。
    private func build(_ link: VoiceAudioDevice.Link) throws {
        engine?.stop()
        let engine = AVAudioEngine()
        var inputRate = VoiceAudioDevice.rate
        if fixture == nil {
            let input = engine.inputNode
            try input.setVoiceProcessingEnabled(true)
            input.voiceProcessingOtherAudioDuckingConfiguration = .init(enableAdvancedDucking: false, duckingLevel: .min)
            let format = input.outputFormat(forBus: 0)
            inputRate = format.sampleRate
            let sink = Self.microphone(format: format, link: link, levels: levels)
            engine.attach(sink)
            try engine.link(input, to: sink, format: format)
        } else {
            engine.mainMixerNode.outputVolume = 0
        }
        let output = Self.speaker(link: link, levels: levels)
        engine.attach(output)
        try engine.link(output, to: engine.mainMixerNode, format: Self.format)
        self.engine = engine
        device.reconfigured(inputRate: inputRate)
        engine.prepare()
        try engine.start()
    }

    nonisolated private static let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: VoiceAudioDevice.rate, channels: 1, interleaved: true)!

    /// 下行：从 WebRTC 取一片。
    nonisolated private static func speaker(link: VoiceAudioDevice.Link, levels: VoiceLevels) -> AVAudioSourceNode {
        AVAudioSourceNode(format: format) { silence, timestamp, frames, buffers in
            var flags = AudioUnitRenderActionFlags()
            let status = link.playout(&flags, timestamp, 0, frames, buffers)
            guard status == noErr, let data = buffers.pointee.mBuffers.mData else { return status }
            levels.output.record(UnsafeBufferPointer(start: data.assumingMemoryBound(to: Int16.self), count: Int(frames)))
            silence.pointee = ObjCBool(flags.contains(.unitRenderAction_OutputIsSilence))
            return noErr
        }
    }

    /// 上行：麦克风（语音处理后）的第一声道转成 16 位交给 WebRTC。
    nonisolated private static func microphone(format: AVAudioFormat, link: VoiceAudioDevice.Link, levels: VoiceLevels) -> AVAudioSinkNode {
        let scratch = Scratch()
        let stride = format.isInterleaved ? Int(format.channelCount) : 1
        return AVAudioSinkNode { timestamp, frames, buffers in
            guard let data = buffers.pointee.mBuffers.mData else { return noErr }
            let samples = data.assumingMemoryBound(to: Float.self)
            let count = min(Int(frames), scratch.samples.count)
            for index in 0..<count { scratch.samples[index] = Int16(max(-1, min(1, samples[index * stride])) * Float(Int16.max)) }
            let input = UnsafeBufferPointer(rebasing: scratch.samples[0..<count])
            levels.input.record(input)
            var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                mNumberChannels: 1, mDataByteSize: UInt32(count * 2), mData: UnsafeMutableRawPointer(scratch.samples.baseAddress)))
            var flags = AudioUnitRenderActionFlags()
            return link.deliver(&flags, timestamp, 1, UInt32(count), &list, nil, nil)
        }
    }

    /// 只在实时线程上写的缓冲，随节点一起释放。
    private nonisolated final class Scratch: @unchecked Sendable {
        let samples = UnsafeMutableBufferPointer<Int16>.allocate(capacity: VoiceAudio.maximumFrames)
        deinit { samples.deallocate() }
    }
}

private extension AVAudioEngine {
    /// iOS 27 起只留会抛错的连接；Mac 还要支持 26。
    func link(_ source: AVAudioNode, to target: AVAudioNode, format: AVAudioFormat) throws {
        #if os(iOS)
        try connectNode(source, to: target, format: format)
        #else
        connect(source, to: target, format: format)
        #endif
    }
}
