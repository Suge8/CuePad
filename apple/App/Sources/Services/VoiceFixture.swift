import AVFoundation
import Synchronization

/// 无人值守的声源（`-CuePadVoice <音频文件|目录>`，`DebugScene.voiceCallIfAsked`）：自己按 10 ms 的节拍代替麦克风，`play` 把一个文件实时送进上行，
/// 送完调 `finished`；没在播时上行是静音。只给一通电话的 `VoiceAudio` 用。
/// 下行默认也由这个节拍从 WebRTC 取走、不碰音频硬件：模拟器的音频服务在负载高时初始化输出单元会 RPC 超时、整个 App 被中止（实测），CI 的 runner 也没有声卡。
final class VoiceFixture {
    nonisolated enum Downlink: Sendable {
        /// 录下（`write`），不出声
        case record
        case discard
        /// 照常走 `VoiceAudio` 的扬声器（静音）：只有真的在出声，iOS 才按后台音频让 App 在后台接着跑（模拟器实测：不出声的进后台即被挂起）。后台验收用
        case speaker
    }
    let downlink: Downlink
    var finished: (String) -> Void = { _ in }
    private let feed = Feed()
    private var clock: (any DispatchSourceTimer)?
    private var watching: Task<Void, Never>?

    init(downlink: Downlink) { self.downlink = downlink }

    isolated deinit {
        watching?.cancel()
        clock?.cancel()
    }

    func start(link: VoiceAudioDevice.Link, levels: VoiceLevels) {
        clock = feed.clock(link: link, levels: levels, downlink: downlink)
    }

    func stop() {
        clock?.cancel()
        clock = nil
    }

    func play(_ url: URL) throws {
        let name = url.lastPathComponent
        feed.load(try Self.decode(url))
        watching?.cancel()
        watching = Task { [feed] in
            while !feed.done {
                do { try await Task.sleep(for: .milliseconds(10)) } catch { return }
            }
            finished(name)
        }
    }

    /// 录下的下行（`.record`），24 kHz 单声道 16 位。
    func write(to url: URL) throws {
        let pcm = feed.recorded()
        func le<T: FixedWidthInteger>(_ value: T) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
        let rate: UInt32 = 24_000, bytes = UInt32(pcm.count * 2)
        var data = Data("RIFF".utf8) + le(36 + bytes) + Data("WAVEfmt ".utf8) + le(UInt32(16)) + le(UInt16(1)) + le(UInt16(1))
        data += le(rate) + le(rate * 2) + le(UInt16(2)) + le(UInt16(16)) + Data("data".utf8) + le(bytes)
        pcm.withUnsafeBytes { data.append(contentsOf: $0) }
        try data.write(to: url)
    }

    private static func decode(_ url: URL) throws -> [Int16] {
        let file = try AVAudioFile(forReading: url)
        let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: VoiceAudioDevice.rate, channels: 1, interleaved: true)!
        let source = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: source)
        guard let converter = AVAudioConverter(from: file.processingFormat, to: target) else { throw CocoaError(.fileReadCorruptFile) }
        let capacity = AVAudioFrameCount(Double(source.frameLength) * target.sampleRate / file.processingFormat.sampleRate) + 1024
        let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity)!
        var consumed = false
        var failure: NSError?
        let status = converter.convert(to: output, error: &failure) { _, state in
            if consumed { state.pointee = .endOfStream; return nil }
            consumed = true
            state.pointee = .haveData
            return source
        }
        if status == .error { throw failure ?? CocoaError(.fileReadCorruptFile) }
        return Array(UnsafeBufferPointer(start: output.int16ChannelData![0], count: Int(output.frameLength)))
    }

    /// 节拍那一侧：`tick` 只在节拍的串行队列上跑，两块缓冲只有它碰；锁只在主线程换文件、取录音时才有人争。
    private nonisolated final class Feed: Sendable {
        static let frames = Int(VoiceAudioDevice.rate / 100)
        private struct State {
            var pcm: [Int16] = []
            var at = 0
            var recorded: [Int16] = []
        }
        private let state = Mutex(State())
        nonisolated(unsafe) private let output = UnsafeMutableBufferPointer<Int16>.allocate(capacity: frames)
        nonisolated(unsafe) private let input = UnsafeMutableBufferPointer<Int16>.allocate(capacity: frames)
        nonisolated(unsafe) private var time = AudioTimeStamp()

        init() { state.withLock { $0.recorded.reserveCapacity(24_000 * 120) } }
        deinit {
            output.deallocate()
            input.deallocate()
        }

        var done: Bool { state.withLock { $0.at >= $0.pcm.count } }

        func load(_ pcm: [Int16]) { state.withLock { $0.pcm = pcm; $0.at = 0 } }

        func recorded() -> [Int16] { state.withLock { $0.recorded } }

        func clock(link: VoiceAudioDevice.Link, levels: VoiceLevels, downlink: Downlink) -> any DispatchSourceTimer {
            let clock = DispatchSource.makeTimerSource(flags: .strict, queue: DispatchQueue(label: "voice-fixture", qos: .userInteractive))
            clock.setEventHandler { [weak clock] in
                // 被耽搁时一次补上错过的几拍，上下行都不慢于实时
                for _ in 0..<max(1, Int(clock?.data ?? 1)) { self.tick(link: link, levels: levels, downlink: downlink) }
            }
            clock.schedule(deadline: .now(), repeating: .milliseconds(10), leeway: .milliseconds(1))
            clock.resume()
            return clock
        }

        private func tick(link: VoiceAudioDevice.Link, levels: VoiceLevels, downlink: Downlink) {
            let frames = UInt32(Self.frames)
            time.mSampleTime += Double(frames)
            time.mHostTime = mach_absolute_time()
            time.mFlags = [.sampleTimeValid, .hostTimeValid]
            var flags = AudioUnitRenderActionFlags()
            var list = Self.list(output)
            if downlink != .speaker {
                _ = link.playout(&flags, &time, 0, frames, &list)
                levels.output.record(UnsafeBufferPointer(output))
            }
            state.withLock { state in
                if downlink == .record {
                    // 两点并一点降到 24 kHz
                    for index in stride(from: 0, to: output.count, by: 2) {
                        state.recorded.append(Int16((Int32(output[index]) + Int32(output[index + 1])) / 2))
                    }
                }
                let take = min(output.count, state.pcm.count - state.at)
                for index in input.indices { input[index] = index < take ? state.pcm[state.at + index] : 0 }
                state.at += max(0, take)
            }
            levels.input.record(UnsafeBufferPointer(input))
            list = Self.list(input)
            flags = []
            _ = link.deliver(&flags, &time, 1, frames, &list, nil, nil)
        }

        private static func list(_ buffer: UnsafeMutableBufferPointer<Int16>) -> AudioBufferList {
            AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(buffer.count * 2), mData: buffer.baseAddress))
        }
    }
}
