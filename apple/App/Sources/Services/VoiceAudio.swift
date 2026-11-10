import AVFoundation
import CueStore
import os
#if os(iOS)
import UIKit
#endif

/// 一通电话的声音，经 `VoiceAudioDevice` 接到 WebRTC；主线程开关，停了不复用。声源是 `VoiceFixture` 时上行由它送，下行看它的 `downlink`；
/// iOS 的音频会话与中断照常（中断与后台因此能在模拟器上验，`DebugScene+PhoneVoiceCall`）。
/// 麦克风走 AVAudioEngine，打开系统的语音处理（回声消除、降噪、自动增益），WebRTC 自己的那套关掉（`VoicePeer`）。
/// iOS 的音频会话只经 `VoiceAudioSession`：`start` 拿到、`stop` 交还，`start` 半途失败也交还。会话被系统收走即结束（`audioInterrupted`），
/// 不假装还在通。开了语音处理的引擎一开就自己停下并发一次配置变化（实测，iOS 27 模拟器：每台新引擎都这样，
/// 收到通知就另建新引擎因此会无限循环，每秒七八次）；换路由（蓝牙、耳机）或 Mac 换设备也是停下并发通知。
/// 停下就按此刻的硬件格式再开（两端怎么开见 `restart`）；重开抛错，或 `restartLimit` 内反复停，按 mediaFailed 结束。
/// 电平 50 ms 取一次，只给界面；iOS 进后台（含锁屏）就停，回前台接着取。
final class VoiceAudio {
    /// 一次渲染的帧数上限：引擎默认 4096，留余量。
    nonisolated private static let maximumFrames = 16_384
    let device = VoiceAudioDevice()
    private let fixture: VoiceFixture?
    private let levels = VoiceLevels()
    private var engine: AVAudioEngine?
    private var microphone: AVAudioSinkNode?
    /// 开语音处理那一下加上一次换路由，正常不过两三次；窗口里超过就当失控，不再重开。
    private static let restartLimit = (count: 5, within: Duration.seconds(2))
    private var events: (VoicePeer.Event) -> Void = { _ in }
    private var watching: [Task<Void, Never>] = []
    private var metering: Task<Void, Never>?
    private var gates = (input: VoiceLevels.Gate(), output: VoiceLevels.Gate())
    #if os(iOS)
    private var session: VoiceAudioSession?
    private var visibility: [any NSObjectProtocol] = []
    #endif
    private static let log = Logger(subsystem: AppIdentity.id, category: "voice")

    init(source: VoicePeer.Source) {
        if case .fixture(let fixture) = source { self.fixture = fixture } else { fixture = nil }
    }

    func start(_ events: @escaping (VoicePeer.Event) -> Void) throws {
        self.events = events
        guard let link = device.link else { throw VoicePeerError.unavailable }
        do {
            #if os(iOS)
            session = try VoiceAudioSession { [weak self] in self?.events(.ended(.audioInterrupted)) }
            watchVisibility()
            if UIApplication.shared.applicationState != .background { meter() }
            #else
            meter()
            #endif
            try run(link)
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        watching.forEach { $0.cancel() }
        watching = []
        metering?.cancel()
        metering = nil
        fixture?.stop()
        engine?.stop()
        engine = nil
        microphone = nil
        #if os(iOS)
        visibility.forEach(NotificationCenter.default.removeObserver)
        visibility = []
        session?.end()
        session = nil
        #endif
    }

    private func run(_ link: VoiceAudioDevice.Link) throws {
        if let fixture, fixture.downlink != .speaker {
            device.reconfigured(inputRate: VoiceAudioDevice.rate)
            return fixture.start(link: link, levels: levels)
        }
        try build(link)
        fixture?.start(link: link, levels: levels)
        let changes = NotificationCenter.default.notifications(named: .AVAudioEngineConfigurationChange)
        watching.append(Task {
            var restarts: [ContinuousClock.Instant] = []
            for await _ in changes {
                guard let engine, !engine.isRunning else { continue }
                let now = ContinuousClock.now
                restarts = restarts.filter { now - $0 < Self.restartLimit.within } + [now]
                guard restarts.count <= Self.restartLimit.count else {
                    Self.log.error("Voice audio keeps stopping: \(restarts.count) restarts within \(Self.restartLimit.within, privacy: .public)")
                    return events(.ended(.mediaFailed))
                }
                do {
                    let rate = try restart(engine, link: link)
                    Self.log.notice("Voice audio restarted, input \(rate, privacy: .public) Hz")
                } catch {
                    Self.log.error("Voice audio restart failed: \(String(describing: error), privacy: .public)")
                    return events(.ended(.mediaFailed))
                }
            }
        })
    }

    private func meter() {
        guard metering == nil else { return }
        _ = levels.input.take()
        _ = levels.output.take()
        metering = Task { [levels] in
            while (try? await Task.sleep(for: VoiceLevels.Gate.interval)) != nil {
                let heard = levels.input.take(), said = levels.output.take()
                events(.sample(.input, peak: heard))
                events(.sample(.output, peak: said))
                if let change = gates.input.update(heard) { events(.level(.input, loud: change.loud, peak: change.peak)) }
                if let change = gates.output.update(said) { events(.level(.output, loud: change.loud, peak: change.peak)) }
            }
        }
    }

    #if os(iOS)
    private func watchVisibility() {
        let center = NotificationCenter.default
        visibility = [
            center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.metering?.cancel()
                    self?.metering = nil
                }
            },
            center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.meter() }
            },
        ]
    }
    #endif

    /// iOS 开语音处理会让引擎自停、新建的又自停而循环，所以重开同一台；Mac 新建引擎才跟随换掉的设备，同一台重开在 Mac 上没验证过。
    private func restart(_ engine: AVAudioEngine, link: VoiceAudioDevice.Link) throws -> Double {
        #if os(iOS)
        try start(engine, link: link)
        #else
        try build(link)
        #endif
    }

    /// 声源是文件时只建扬声器这一半，且不外放（无人值守）。返回上行采样率。
    @discardableResult
    private func build(_ link: VoiceAudioDevice.Link) throws -> Double {
        engine?.stop()
        microphone = nil
        let engine = AVAudioEngine()
        if fixture == nil {
            try engine.inputNode.setVoiceProcessingEnabled(true)
            engine.inputNode.voiceProcessingOtherAudioDuckingConfiguration = .init(enableAdvancedDucking: false, duckingLevel: .min)
        } else {
            engine.mainMixerNode.outputVolume = 0
        }
        let output = Self.speaker(link: link, levels: levels)
        engine.attach(output)
        try engine.link(output, to: engine.mainMixerNode, format: Self.format)
        self.engine = engine
        return try start(engine, link: link)
    }

    /// 麦克风这一路按此刻的硬件格式重接（换格式后旧连接的格式不再成立，收声节点按格式取声道），告诉 WebRTC 新采样率，再开。返回上行采样率。
    private func start(_ engine: AVAudioEngine, link: VoiceAudioDevice.Link) throws -> Double {
        var inputRate = VoiceAudioDevice.rate
        if fixture == nil {
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            inputRate = format.sampleRate
            #if os(macOS)
            // 语音处理要两侧采样率一致，否则启动报 -10875。Mac 上实测：DGM20 USB 麦克风 + 内建扬声器时收声侧 48000、放声侧默认 44100；
            // 声道数不必一致（4 对 2 照常开）。放声侧的硬件格式此时读作 0 声道，声道数取它现接的。
            // 只在 Mac 改接：iOS 真机按现有接法已接通，这样改接没在真机上验过。
            let channels = engine.outputNode.inputFormat(forBus: 0).channelCount
            guard let speaker = AVAudioFormat(standardFormatWithSampleRate: inputRate, channels: channels) else { throw VoicePeerError.unavailable }
            try engine.link(engine.mainMixerNode, to: engine.outputNode, format: speaker)
            #endif
            if let microphone { engine.detach(microphone) }
            let sink = Self.microphone(format: format, link: link, levels: levels)
            engine.attach(sink)
            try engine.link(input, to: sink, format: format)
            microphone = sink
        }
        device.reconfigured(inputRate: inputRate)
        engine.prepare()
        do {
            try engine.start()
        } catch {
            Self.log.error("Voice audio start failed: \(Self.formats(engine), privacy: .public): \(String(describing: error), privacy: .public)")
            throw error
        }
        return inputRate
    }

    private static func formats(_ engine: AVAudioEngine) -> String {
        func shown(_ format: AVAudioFormat) -> String { "\(format.channelCount)ch \(Int(format.sampleRate))Hz" }
        let input = engine.inputNode, output = engine.outputNode
        return "input \(shown(input.outputFormat(forBus: 0))), output \(shown(output.inputFormat(forBus: 0)))"
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
