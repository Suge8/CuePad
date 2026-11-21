#if os(macOS)
import CoreMedia
import Foundation
import VideoToolbox

/// 硬件 H.264 的低延迟档：不重排帧，不定期出关键帧（走的是 TCP，不丢；有人新连上、跟丢了才要一个）。
/// 出的是 AVCC（每个 NAL 前 4 字节长度），网页的 `VideoDecoder` 直接吃。只在 `ScreenServer` 的队列上用。
final class ScreenEncoder {
  struct Frame: Sendable {
    /// 关键帧带着 avcC（SPS、PPS）：解码器照它配置。
    let description: Data?
    let data: Data
  }

  private var session: VTCompressionSession?
  private var size = (width: 0, height: 0)
  private var count: Int64 = 0

  /// `done` 在 VideoToolbox 的线程上回；没编出来（压力大时它自己丢帧、会话建不起来）是 nil。
  func encode(_ buffer: CVPixelBuffer, key: Bool, done: @escaping @Sendable (Frame?) -> Void) {
    let now = (CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer))
    if session == nil || now != size {
      size = now
      session = Self.session(width: now.0, height: now.1)
    }
    guard let session else { return done(nil) }
    count += 1
    let options = key ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
    let status = VTCompressionSessionEncodeFrame(
      session, imageBuffer: buffer, presentationTimeStamp: CMTime(value: count, timescale: Self.rate), duration: .invalid, frameProperties: options, infoFlagsOut: nil
    ) { status, flags, sample in
      guard status == noErr, !flags.contains(.frameDropped), let sample else { return done(nil) }
      done(Self.frame(sample))
    }
    if status != noErr { done(nil) }
  }

  private static let rate: Int32 = 60

  private static func session(width: Int, height: Int) -> VTCompressionSession? {
    var made: VTCompressionSession?
    // 低延迟码控：码流里标明不缓冲，解码端来一帧出一帧；不开的话网页那头攒够几帧才出画面，慢约 300 ms
    let lowLatency = [kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true] as CFDictionary
    VTCompressionSessionCreate(
      allocator: nil, width: Int32(width), height: Int32(height), codecType: kCMVideoCodecType_H264, encoderSpecification: lowLatency, imageBufferAttributes: nil,
      compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &made)
    guard let made else { return nil }
    let settings: [CFString: Any] = [
      kVTCompressionPropertyKey_RealTime: true,
      kVTCompressionPropertyKey_ProfileLevel: kVTProfileLevel_H264_High_AutoLevel,
      kVTCompressionPropertyKey_AllowFrameReordering: false,
      kVTCompressionPropertyKey_ExpectedFrameRate: rate,
      kVTCompressionPropertyKey_MaxKeyFrameInterval: Int32.max,
      // 界面是大片不动加小块在动：平均码率只在整屏滚动时用满，停下来的那几帧（`ScreenServer.settle`）把字补清楚
      kVTCompressionPropertyKey_AverageBitRate: min(16_000_000, max(4_000_000, width * height * 3)),
    ]
    VTSessionSetProperties(made, propertyDictionary: settings as CFDictionary)
    VTCompressionSessionPrepareToEncodeFrames(made)
    return made
  }

  private static func frame(_ sample: CMSampleBuffer) -> Frame? {
    guard let block = sample.dataBuffer, let data = try? block.dataBytes() else { return nil }
    let attachments = sample.sampleAttachments.first
    let key = attachments?[.notSync] as? Bool != true
    return Frame(description: key ? sample.formatDescription.flatMap(description) : nil, data: data)
  }

  /// avcC（ISO/IEC 14496-15 5.2.4.1）：一组 SPS、一组 PPS，NAL 长度占 4 字节。
  private static func description(_ format: CMFormatDescription) -> Data? {
    let sets = format.parameterSets
    guard sets.count >= 2, sets[0].count >= 4 else { return nil }
    let sps = sets[0], pps = sets[1]
    var blob = Data([1, sps[sps.startIndex + 1], sps[sps.startIndex + 2], sps[sps.startIndex + 3], 0xFF, 0xE1, UInt8(sps.count >> 8), UInt8(sps.count & 0xFF)])
    blob.append(sps)
    blob.append(contentsOf: [1, UInt8(pps.count >> 8), UInt8(pps.count & 0xFF)])
    blob.append(pps)
    return blob
  }
}
#endif
