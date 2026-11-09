import AVFoundation
import Synchronization

/// 无人值守的声源（`-CuePadVoice <音频文件|目录>`，`DebugScene.voiceCallIfAsked`）：`play` 把一个文件按下行的渲染节拍实时送进上行，
/// 送完调 `finished`；没在播时上行是静音。`recording` 时录下下行、不外放（`write`）。只给一通电话的 `VoiceAudio` 用。
final class VoiceFixture {
    let recording: Bool
    var finished: (String) -> Void = { _ in }
    nonisolated let feed = Feed()
    private var watching: Task<Void, Never>?

    init(recording: Bool) { self.recording = recording }

    isolated deinit { watching?.cancel() }

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

    /// 录下的下行，24 kHz 单声道 16 位。
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

    /// 实时线程这一侧：锁只在主线程换文件、取录音时才有人争。
    nonisolated final class Feed: Sendable {
        private struct State {
            var pcm: [Int16] = []
            var at = 0
            var recorded: [Int16] = []
            var pending: Int32?
        }
        private let state = Mutex(State())
        /// 上行每次的帧数不超过渲染的一片（`VoiceAudio.maximumFrames`）。
        nonisolated(unsafe) private let scratch = UnsafeMutableBufferPointer<Int16>.allocate(capacity: VoiceAudio.maximumFrames)

        init() { state.withLock { $0.recorded.reserveCapacity(24_000 * 120) } }
        deinit { scratch.deallocate() }

        var done: Bool { state.withLock { $0.at >= $0.pcm.count } }

        func load(_ pcm: [Int16]) { state.withLock { $0.pcm = pcm; $0.at = 0 } }

        func recorded() -> [Int16] { state.withLock { $0.recorded } }

        /// 下行这一片记下（两点并一点降到 24 kHz），并按同样的帧数取出上行。
        func exchange(_ output: UnsafeBufferPointer<Int16>, recording: Bool) -> UnsafeBufferPointer<Int16> {
            let frames = min(output.count, scratch.count)
            state.withLock { state in
                if recording {
                    for index in output.indices {
                        if let first = state.pending {
                            state.recorded.append(Int16((first + Int32(output[index])) / 2))
                            state.pending = nil
                        } else { state.pending = Int32(output[index]) }
                    }
                }
                let take = min(frames, state.pcm.count - state.at)
                for index in 0..<frames { scratch[index] = index < take ? state.pcm[state.at + index] : 0 }
                state.at += max(0, take)
            }
            return UnsafeBufferPointer(rebasing: scratch[0..<frames])
        }
    }
}
