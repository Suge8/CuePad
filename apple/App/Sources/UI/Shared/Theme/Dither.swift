import MetalKit
import SwiftUI

/// 一张连续色调的图，按屏幕上的格子抖成三种墨色的点（有序抖动，8×8 Bayer），同印刷的网点。
/// 格子对齐设备像素才清楚：按要画出来的那块的像素尺寸当场算一张静止的图，不预先烤好再缩放（缩放过的网点糊、起摩尔纹），也不逐帧算。
/// 尺寸变了（Mac 拖窗口）先把上一张拉伸着顶着，停下来再算，不每一帧都算。
struct DitherImage: View {
    let asset: String
    /// 图在这块里的位置与大小（点）；图外的格子取图边上的颜色。
    let placement: CGRect
    let size: CGSize
    /// 由暗到亮的三种墨。
    let inks: [Color]
    /// 原图的明暗落在这一段里，拉开成整段再抖：原图偏柔，不拉开的话一屏只剩一两种点。
    let tone: ClosedRange<Double>
    @Environment(\.displayScale) private var scale
    @Environment(\.colorScheme) private var scheme
    @Environment(\.self) private var environment
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            if let image {
                Image(decorative: image, scale: scale).resizable().interpolation(.none).transition(.opacity)
            }
        }
        .frame(width: size.width, height: size.height)
        .task(id: job) { [job] in
            if image != nil { do { try await Task.sleep(for: .milliseconds(120)) } catch { return } }
            let rendered = await DitherGPU.shared.render(job)
            guard !Task.isCancelled else { return }
            withAnimation(Motion.fade) { image = rendered }
        }
    }

    private var job: DitherGPU.Job {
        let px = { (v: CGFloat) in Float(v * scale) }
        let resolved = inks.map { $0.resolve(in: environment) }.map { SIMD4<Float>($0.red, $0.green, $0.blue, 1) }
        return DitherGPU.Job(
            asset: asset, dark: scheme == .dark,
            width: UInt32((size.width * scale).rounded()), height: UInt32((size.height * scale).rounded()),
            origin: SIMD2(px(placement.minX), px(placement.minY)), extent: SIMD2(px(placement.width), px(placement.height)),
            cell: Float(max(1, scale.rounded())), tone: SIMD2(Float(tone.lowerBound), Float(tone.upperBound)), inks: resolved)
    }
}

/// 显卡那一份，全 App 共用：着色器第一次用时在运行时编（同 `FigureGPU`，项目不装 Metal 编译工具链），原图按外观各载一次。
final class DitherGPU {
    static let shared = DitherGPU()

    struct Job: Hashable {
        let asset: String
        let dark: Bool
        let width: UInt32
        let height: UInt32
        let origin: SIMD2<Float>
        let extent: SIMD2<Float>
        let cell: Float
        let tone: SIMD2<Float>
        let inks: [SIMD4<Float>]
    }

    /// 与着色器里的 `Job` 逐字段对齐。
    private struct Uniforms {
        var origin, extent, texel: SIMD2<Float>
        var width, height: UInt32
        var cell, lo, hi: Float
        var inks: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)
    }

    private let device = MTLCreateSystemDefaultDevice()!
    private lazy var queue = device.makeCommandQueue()!
    private var pipeline: MTLComputePipelineState?
    private var sources: [String: MTLTexture] = [:]

    func render(_ job: Job) async -> CGImage {
        let pipeline = await pipeline()
        let source = await source(job.asset, dark: job.dark)
        let width = Int(job.width), height = Int(job.height)
        let out = device.makeBuffer(length: width * height * 4, options: .storageModeShared)!
        var uniforms = Uniforms(
            origin: job.origin, extent: job.extent, texel: SIMD2(1 / Float(source.width), 1 / Float(source.height)),
            width: job.width, height: job.height, cell: job.cell, lo: job.tone.x, hi: job.tone.y,
            inks: (job.inks[0], job.inks[1], job.inks[2]))
        let commands = queue.makeCommandBuffer()!, encoder = commands.makeComputeCommandEncoder()!
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(source, index: 0)
        encoder.setBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setBuffer(out, offset: 0, index: 1)
        encoder.dispatchThreads(MTLSize(width: width, height: height, depth: 1), threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        encoder.endEncoding()
        await withCheckedContinuation { done in
            commands.addCompletedHandler { @Sendable _ in done.resume() }
            commands.commit()
        }
        let pixels = CGDataProvider(data: Data(bytes: out.contents(), count: out.length) as CFData)!
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: pixels, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    private func pipeline() async -> MTLComputePipelineState {
        if let pipeline { return pipeline }
        let library = try! await device.makeLibrary(source: Self.shader, options: nil)
        let made = try! await device.makeComputePipelineState(function: library.makeFunction(name: "dither")!)
        pipeline = made
        return made
    }

    /// 资源目录里的图按外观取：深浅两张对齐过，交给 SwiftUI 按配色解析，不各端另写。
    private func source(_ asset: String, dark: Bool) async -> MTLTexture {
        let key = "\(asset)/\(dark)"
        if let texture = sources[key] { return texture }
        let renderer = ImageRenderer(content: Image(decorative: asset).environment(\.colorScheme, dark ? .dark : .light))
        renderer.scale = 1
        let texture = try! await MTKTextureLoader(device: device).newTexture(cgImage: renderer.cgImage!, options: [.SRGB: false])
        sources[key] = texture
        return texture
    }

    private static let shader = #"""
#include <metal_stdlib>
using namespace metal;

struct Job {
    float2 origin;   // 图左上角（像素）
    float2 extent;   // 图的宽高（像素）
    float2 texel;    // 原图一个像素在 uv 里的大小
    uint width, height;
    float cell, lo, hi;
    float4 inks[3];
};

constant float bayer[64] = {
     0, 32,  8, 40,  2, 34, 10, 42, 48, 16, 56, 24, 50, 18, 58, 26,
    12, 44,  4, 36, 14, 46,  6, 38, 60, 28, 52, 20, 62, 30, 54, 22,
     3, 35, 11, 43,  1, 33,  9, 41, 51, 19, 59, 27, 49, 17, 57, 25,
    15, 47,  7, 39, 13, 45,  5, 37, 63, 31, 55, 23, 61, 29, 53, 21 };

kernel void dither(texture2d<float> src [[texture(0)]], constant Job &j [[buffer(0)]], device uchar4 *out [[buffer(1)]],
                   uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= j.width || gid.y >= j.height) return;
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    uint2 cell = uint2(float2(gid) / j.cell);
    float2 uv = ((float2(cell) + 0.5) * j.cell - j.origin) / j.extent;
    // 九点取平均：原图是 JPEG，平的渐变里压缩的方块边会被抖成一道道竖纹
    float3 c = 0;
    for (int y = -1; y <= 1; y++)
        for (int x = -1; x <= 1; x++)
            c += src.sample(s, uv + float2(x, y) * j.texel * 1.5).rgb;
    float l = smoothstep(j.lo, j.hi, dot(c / 9.0, float3(0.2126, 0.7152, 0.0722))) * 2.0;
    int i = min(int(l), 1);
    float t = (bayer[(cell.y % 8) * 8 + cell.x % 8] + 0.5) / 64.0;
    float3 o = (l - float(i) > t ? j.inks[i + 1] : j.inks[i]).rgb;
    out[gid.y * j.width + gid.x] = uchar4(uchar3(round(saturate(o) * 255.0)), 255);
}
"""#
}
