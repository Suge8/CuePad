#if os(macOS) && DEBUG
import AVFoundation
import CoreAudio
import Foundation
import Synchronization

/// `-CuePadVoiceLoopback <目录>`：只抓本进程播放的 first.wav、interrupt.wav、stop.wav，公开成临时麦克风给 WebKit。
/// 不改默认设备与音量；抓取时静音本进程的播放，远端声音由 WebKit 进程播放，不进入这个 tap。
/// 用完先销毁聚合设备再销毁 tap。名称含进程号，避免并行实例相互选中。
final class VoiceLoopback: NSObject, AVAudioPlayerDelegate {
    var onFinished: (String, Bool) -> Void = { _, _ in }
    let name = "CuePad Voice \(getpid())"
    private var tap: AudioObjectID = 0
    private var device: AudioObjectID = 0
    private var io: AudioDeviceIOProcID?
    private let maximum = TapPeak()
    var peak: Float { maximum.value.withLock { $0 } }
    private let directory: URL
    private var player: AVAudioPlayer

    init(directory: URL) throws {
        self.directory = directory
        player = try AVAudioPlayer(contentsOf: directory.appending(path: "first.wav"))
        player.prepareToPlay()
        super.init()
        var pid = getpid(), process: AudioObjectID = 0, size = UInt32(MemoryLayout<AudioObjectID>.size)
        var property = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                                                  mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        try Self.check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &property,
                                                 UInt32(MemoryLayout<pid_t>.size), &pid, &size, &process))
        var output: AudioObjectID = 0
        property.mSelector = kAudioHardwarePropertyDefaultOutputDevice
        try Self.check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, &size, &output))
        property.mSelector = kAudioDevicePropertyDeviceUID
        var uidRef: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<CFString>.size)
        try Self.check(AudioObjectGetPropertyData(output, &property, 0, nil, &size, &uidRef))
        let uid = uidRef!.takeRetainedValue()
        let description = CATapDescription(stereoMixdownOfProcesses: [process])
        description.name = name
        description.isPrivate = false
        description.muteBehavior = .muted
        try Self.check(AudioHardwareCreateProcessTap(description, &tap))
        do {
            try Self.check(AudioHardwareCreateAggregateDevice([
                kAudioAggregateDeviceNameKey: name,
                kAudioAggregateDeviceUIDKey: UUID().uuidString,
                kAudioAggregateDeviceIsPrivateKey: false,
                kAudioAggregateDeviceMainSubDeviceKey: uid,
                kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: uid]],
                kAudioAggregateDeviceTapAutoStartKey: false,
                kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString]],
            ] as CFDictionary, &device))
            try Self.check(AudioDeviceCreateIOProcIDWithBlock(&io, device, DispatchQueue(label: "voice-tap")) { @Sendable [maximum] _, input, _, _, _ in
                var peak: Float = 0
                for buffer in UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input)) {
                    guard let data = buffer.mData else { continue }
                    let samples = data.assumingMemoryBound(to: Float.self)
                    for i in 0..<Int(buffer.mDataByteSize) / MemoryLayout<Float>.size { peak = max(peak, abs(samples[i])) }
                }
                maximum.value.withLock { $0 = max($0, peak) }
            })

        } catch {
            try close()
            throw error
        }
    }

    var duration: TimeInterval { player.duration }

    func play(_ file: String = "first.wav") throws {
        player = try AVAudioPlayer(contentsOf: directory.appending(path: file))
        player.delegate = self
        guard player.play() else { throw Failure.playback }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let id = ObjectIdentifier(player)
        Task { @MainActor [weak self] in
            guard let self, ObjectIdentifier(self.player) == id else { return }
            onFinished(self.player.url!.lastPathComponent, flag)
        }
    }

    // 权限确认可能阻塞 Core Audio；不把这个等待放在 App 主线程上。
    func start() async throws {
        let device = device, io = io
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global().async {
                let status = AudioDeviceStart(device, io)
                if status == noErr { continuation.resume() }
                else { continuation.resume(throwing: NSError(domain: NSOSStatusErrorDomain, code: Int(status))) }
            }
        }
    }

    func close() throws {
        player.stop()
        AudioDeviceStop(device, io)
        if let io { AudioDeviceDestroyIOProcID(device, io) }
        let deviceResult = AudioHardwareDestroyAggregateDevice(device)
        let tapResult = AudioHardwareDestroyProcessTap(tap)
        try Self.check(deviceResult)
        try Self.check(tapResult)
    }

    private enum Failure: Error { case audio(OSStatus), playback }
    private static func check(_ status: OSStatus) throws {
        if status != noErr { throw Failure.audio(status) }
    }
}
private nonisolated final class TapPeak: Sendable { let value = Mutex<Float>(0) }
#endif
