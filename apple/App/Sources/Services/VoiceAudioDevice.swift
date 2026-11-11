import AudioToolbox
import Foundation
import Synchronization
@preconcurrency import WebRTC
#if os(macOS)
import WebRTCAudioDevice
#endif

/// WebRTC 这一侧的音频设备：声音由 `VoiceAudio` 的引擎进出，这里只把格式与两块实时回调交给它。
/// 协议方法在 WebRTC 的工作线程上调；开始、停止只记下：没开始时 WebRTC 自己出静音、丢上行（`ObjCAudioDeviceModule`）。
nonisolated final class VoiceAudioDevice: NSObject, RTCAudioDevice, Sendable {
    /// 下行固定这个格式；上行跟麦克风的硬件采样率（声源是文件时也用这个）。WebRTC 内部再重采样。
    static let rate = 48_000.0

    /// 实时线程拿着用，不进锁。
    struct Link: @unchecked Sendable {
        let playout: RTCAudioDeviceGetPlayoutDataBlock
        let deliver: RTCAudioDeviceDeliverRecordedDataBlock
    }

    /// WebRTC 的这个代理本就在各线程上调。
    private struct Delegate: @unchecked Sendable { let value: any RTCAudioDeviceDelegate }
    private struct State {
        var delegate: Delegate?
        var inputRate = VoiceAudioDevice.rate
        var playoutReady = false, playing = false, recordingReady = false, recording = false
    }
    private let state = Mutex(State())

    /// 建第一份 RTCPeerConnection 时 WebRTC 在工作线程上同步调 `initialize(with:)`（实测，工厂建好时还没有），之后到 `terminateDevice` 前都在。
    var link: Link? {
        state.withLock { state in state.delegate.map { Link(playout: $0.value.getPlayoutData, deliver: $0.value.deliverRecordedData) } }
    }

    /// 引擎按新硬件格式重建后、开始前调：WebRTC 先换好缓冲，实时回调此后可能换线程。
    func reconfigured(inputRate: Double) {
        guard let delegate = state.withLock({ state in
            state.inputRate = inputRate
            return state.delegate?.value
        }) else { return }
        delegate.dispatchSync {
            delegate.notifyAudioInputInterrupted()
            delegate.notifyAudioOutputInterrupted()
            delegate.notifyAudioInputParametersChange()
            delegate.notifyAudioOutputParametersChange()
        }
    }

    var deviceInputSampleRate: Double { state.withLock { $0.inputRate } }
    var inputIOBufferDuration: TimeInterval { 0.01 }
    var inputNumberOfChannels: Int { 1 }
    var inputLatency: TimeInterval { 0 }
    var deviceOutputSampleRate: Double { Self.rate }
    var outputIOBufferDuration: TimeInterval { 0.01 }
    var outputNumberOfChannels: Int { 1 }
    var outputLatency: TimeInterval { 0 }

    var isInitialized: Bool { state.withLock { $0.delegate != nil } }
    func initialize(with delegate: any RTCAudioDeviceDelegate) -> Bool {
        let delegate = Delegate(value: delegate)
        state.withLock { $0.delegate = delegate }
        return true
    }
    func terminateDevice() -> Bool {
        state.withLock { $0 = State() }
        return true
    }

    var isPlayoutInitialized: Bool { state.withLock { $0.playoutReady } }
    func initializePlayout() -> Bool { state.withLock { $0.playoutReady = true }; return true }
    var isPlaying: Bool { state.withLock { $0.playing } }
    func startPlayout() -> Bool { state.withLock { $0.playing = true }; return true }
    func stopPlayout() -> Bool { state.withLock { $0.playing = false }; return true }

    var isRecordingInitialized: Bool { state.withLock { $0.recordingReady } }
    func initializeRecording() -> Bool { state.withLock { $0.recordingReady = true }; return true }
    var isRecording: Bool { state.withLock { $0.recording } }
    func startRecording() -> Bool { state.withLock { $0.recording = true }; return true }
    func stopRecording() -> Bool { state.withLock { $0.recording = false }; return true }
}
