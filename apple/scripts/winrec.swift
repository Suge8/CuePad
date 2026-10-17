// 用法：winrec <pid> <秒> <宽> <高> <输出.mov>：用 ScreenCaptureKit 录这个进程屏上最大的那扇普通窗口本身（按窗口录，不录屏幕区域：
// 挡在上面的别的窗口、系统的录屏标记都不进画面），60fps、H.264，按给的像素尺寸出片（`xc.sh rec mac` 编译并调用它，尺寸来自就绪文件）。
// 窗口在屏上被系统缩放显示（调度中心、台前调度）时 ScreenCaptureKit 给的也是缩小的画面：这时直接失败，不出片。
import AppKit
import AVFoundation
import ScreenCaptureKit

let args = CommandLine.arguments
guard args.count == 6, let pid = pid_t(args[1]), let seconds = Double(args[2]), let width = Int(args[3]), let height = Int(args[4]) else {
    FileHandle.standardError.write(Data("用法：winrec <pid> <秒> <宽> <高> <输出.mov>\n".utf8))
    exit(2)
}
let out = URL(fileURLWithPath: args[5])
try? FileManager.default.removeItem(at: out)

final class Writer: NSObject, SCStreamOutput {
    let writer: AVAssetWriter
    private let receiver: AVAssetWriterInput.SampleBufferReceiver
    private var started = false
    private(set) var frames = 0

    init(_ out: URL, width: Int, height: Int) throws {
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

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

let done = DispatchSemaphore(value: 0)
Task {
    do {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let windows = content.windows.filter { $0.owningApplication?.processID == pid && $0.windowLayer == 0 }
        guard let window = windows.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) else { fail("没有找到 \(pid) 的窗口") }
        let scale = NSScreen.screens.first { $0.frame.intersects(window.frame) }?.backingScaleFactor ?? 1
        let shown = (Int(window.frame.width * scale), Int(window.frame.height * scale))
        guard abs(shown.0 - width) <= 2, abs(shown.1 - height) <= 2 else {
            fail("窗口在屏上被缩放显示（\(shown.0)×\(shown.1)，应为 \(width)×\(height)）：调度中心或台前调度开着？关掉再录")
        }
        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        let writer = try Writer(out, width: width, height: height)
        let stream = SCStream(filter: SCContentFilter(desktopIndependentWindow: window), configuration: config, delegate: nil)
        try stream.addStreamOutput(writer, type: .screen, sampleHandlerQueue: DispatchQueue(label: "winrec"))
        try await stream.startCapture()
        try await Task.sleep(for: .seconds(seconds))
        try await stream.stopCapture()
        guard writer.frames > 0 else { fail("没有录到画面（屏幕录制权限？）") }
        await writer.finish()
        print(out.path)
    } catch {
        fail("录屏失败：\(error)")
    }
    done.signal()
}
done.wait()
