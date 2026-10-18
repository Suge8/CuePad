// 用法：wincap shot <pid> <宽> <高> <图.png>
//       wincap rec <pid> <秒> <宽> <高> <片.mov>
// 用 ScreenCaptureKit 拍这个进程屏上最大的那扇普通窗口本身：挡在上面的窗口、阴影、指针、录屏标记都不进画面。
// 按给的像素尺寸（App 写在就绪文件里的窗口像素尺寸，见 DebugScene.shotSize）出 PNG，或 60fps 的 H.264 视频。app.py 编译并调用它。
// 窗口在屏上被系统缩小显示（调度中心、台前调度）时拍到的也是缩小的：比就绪尺寸小 2% 以上就失败、不出文件
// （2% 以内是就绪后窗口按内容又长了几个点，缩小显示差的是一半上下）。
import AppKit
import AVFoundation
import ScreenCaptureKit
import UniformTypeIdentifiers

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

let args = Array(CommandLine.arguments.dropFirst())
let recording = args.first == "rec"
guard args.count == (recording ? 6 : 5), let pid = pid_t(args[1]) else {
    fail("用法：wincap shot <pid> <宽> <高> <图.png> | wincap rec <pid> <秒> <宽> <高> <片.mov>", code: 2)
}
let seconds = recording ? Double(args[2]) ?? 0 : 0
let size = args.dropFirst(recording ? 3 : 2).prefix(2).compactMap { Int($0) }
guard size.count == 2 else { fail("宽、高要是整数", code: 2) }
let (width, height) = (size[0], size[1])
let out = URL(fileURLWithPath: args.last!)
try? FileManager.default.removeItem(at: out)

final class Writer: NSObject, SCStreamOutput {
    let writer: AVAssetWriter
    private let receiver: AVAssetWriterInput.SampleBufferReceiver
    private var started = false
    private(set) var frames = 0

    init(_ out: URL) throws {
        writer = try AVAssetWriter(outputURL: out, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
        ])
        receiver = writer.inputReceiver(for: input)
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        // 内容没变时 ScreenCaptureKit 也会送不带画面的帧，跳过
        guard type == .screen, buffer.isValid, buffer.imageBuffer != nil else { return }
        if !started {
            guard (try? writer.start()) != nil else { return }
            writer.startSession(atSourceTime: buffer.presentationTimeStamp)
            started = true
        }
        // 实时录：编码器忙不过来时丢这一帧，不排队
        if (try? receiver.appendImmediately(CMReadySampleBuffer(unsafeBuffer: buffer))) == true { frames += 1 }
    }

    func finish() async {
        receiver.finish()
        await writer.finishWriting()
    }
}

func record(_ filter: SCContentFilter, _ config: SCStreamConfiguration) async throws {
    config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
    let writer = try Writer(out)
    let stream = SCStream(filter: filter, configuration: config, delegate: nil)
    try stream.addStreamOutput(writer, type: .screen, sampleHandlerQueue: DispatchQueue(label: "wincap"))
    try await stream.startCapture()
    try await Task.sleep(for: .seconds(seconds))
    try await stream.stopCapture()
    guard writer.frames > 0 else { fail("没有录到画面（屏幕录制权限？）") }
    await writer.finish()
}

func shoot(_ filter: SCContentFilter, _ config: SCStreamConfiguration) async throws {
    let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    guard let file = CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil) else { fail("写不了 \(out.path)") }
    CGImageDestinationAddImage(file, image, nil)
    guard CGImageDestinationFinalize(file) else { fail("写不了 \(out.path)") }
}

let done = DispatchSemaphore(value: 0)
Task {
    do {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let windows = content.windows.filter { $0.owningApplication?.processID == pid && $0.windowLayer == 0 }
        guard let window = windows.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) else { fail("没有找到 \(pid) 的窗口") }
        let scale = NSScreen.screens.first { $0.frame.intersects(window.frame) }?.backingScaleFactor ?? 1
        let shown = (Int(window.frame.width * scale), Int(window.frame.height * scale))
        guard Double(shown.0) >= Double(width) * 0.98, Double(shown.1) >= Double(height) * 0.98 else {
            fail("窗口在屏上被缩小显示（\(shown.0)×\(shown.1)，应为 \(width)×\(height)）：调度中心或台前调度开着，关掉再拍")
        }
        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        let filter = SCContentFilter(desktopIndependentWindow: window)
        if recording { try await record(filter, config) } else { try await shoot(filter, config) }
        print("\(out.path)  \(width)×\(height)\(scale < 2 ? "（1x 屏，1 倍像素）" : "")")
    } catch {
        fail("拍窗口失败：\(error)")
    }
    done.signal()
}
done.wait()
