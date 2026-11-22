import MetalKit
import SwiftUI

struct DitherImage: View {
    let asset: String
    let placement: CGRect
    let size: CGSize
    var fade: CGFloat = 0
    var onDraw: () -> Void = {}
    @Environment(\.displayScale) private var scale
    @State private var image: CGImage?
    @State private var drawn: DitherGPU.Job?

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let image {
                Image(decorative: image, scale: 1).resizable().interpolation(.none)
                    .frame(width: CGFloat(job.width) * cellPx / scale, height: CGFloat(job.height) * cellPx / scale)
                    .transition(.opacity)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .debugSettling(drawn != job)
        // 换一份就换一个视图起任务，不用 task(id:)：它靠 onChange，同一帧里变两次（气泡量出高、云跟着挪）第二次被丢掉，停在旧的一份上
        .background {
            Color.clear.task { [job] in
                if image != nil { do { try await Task.sleep(for: .milliseconds(120)) } catch { return } }
                let rendered = await DitherGPU.shared.render(job)
                guard !Task.isCancelled else { return }
                withAnimation(Motion.fade) { image = rendered }
                drawn = job
                onDraw()
            }
            .id(job)
        }
    }

    private var cellPx: CGFloat { DitherGPU.cell * max(1, scale.rounded()) }

    private var job: DitherGPU.Job {
        let px = { (v: CGFloat) in Float(v * scale) }
        let cells = { (v: CGFloat) in UInt32(max(1, (v * scale / cellPx).rounded(.up))) }
        return DitherGPU.Job(
            asset: asset, width: cells(size.width), height: cells(size.height),
            origin: SIMD2(px(placement.minX), px(placement.minY)), extent: SIMD2(px(placement.width), px(placement.height)),
            cell: Float(cellPx), fade: px(fade))
    }
}

/// 显卡那一份，全 App 共用：着色器第一次用时在运行时编（同 `FigureGPU`，项目不装 Metal 编译工具链），只留最近用的那张原图（带 mip 约 8 MB）：一天里会换着用八张，全留着就是几十 MB。
final class DitherGPU {
    static let shared = DitherGPU()
    static let cell: CGFloat = 2

    struct Job: Hashable {
        let asset: String
        let width: UInt32
        let height: UInt32
        let origin: SIMD2<Float>
        let extent: SIMD2<Float>
        let cell: Float
        let fade: Float
    }

    private struct Uniforms {
        var origin, extent, texel: SIMD2<Float>
        var width, height: UInt32
        var cell, fade: Float
    }

    private let device = MTLCreateSystemDefaultDevice()!
    private lazy var queue = device.makeCommandQueue()!
    private var pipeline: MTLComputePipelineState?
    private var loaded: (asset: String, texture: MTLTexture)?

    func render(_ job: Job) async -> CGImage {
        let pipeline = await pipeline()
        let source = await source(job.asset)
        let width = Int(job.width), height = Int(job.height)
        let out = device.makeBuffer(length: width * height * 4, options: .storageModeShared)!
        var uniforms = Uniforms(
            origin: job.origin, extent: job.extent, texel: SIMD2(1 / Float(source.width), 1 / Float(source.height)),
            width: job.width, height: job.height, cell: job.cell, fade: job.fade)
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
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: pixels, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    private func pipeline() async -> MTLComputePipelineState {
        if let pipeline { return pipeline }
        let library = try! await device.makeLibrary(source: Self.shader, options: nil)
        let made = try! await device.makeComputePipelineState(function: library.makeFunction(name: "dither")!)
        pipeline = made
        return made
    }

    private func source(_ asset: String) async -> MTLTexture {
        if let loaded, loaded.asset == asset { return loaded.texture }
        let renderer = ImageRenderer(content: Image(decorative: asset))
        renderer.scale = 1
        let texture = try! await MTKTextureLoader(device: device).newTexture(cgImage: renderer.cgImage!, options: [.SRGB: false, .generateMipmaps: true])
        loaded = (asset, texture)
        return texture
    }

    private static let shader = #"""
#include <metal_stdlib>
using namespace metal;

struct Job {
    float2 origin;   // 图左上角（像素）
    float2 extent;   // 图的宽高（像素）
    float2 texel;    // 原图一个像素在 uv 里的大小
    uint width, height;  // 出图多少格（一格一像素）
    float cell, fade;    // 一格、上沿散开那一截（设备像素）
};

constant float bayer[64] = {
     0, 32,  8, 40,  2, 34, 10, 42, 48, 16, 56, 24, 50, 18, 58, 26,
    12, 44,  4, 36, 14, 46,  6, 38, 60, 28, 52, 20, 62, 30, 54, 22,
     3, 35, 11, 43,  1, 33,  9, 41, 51, 19, 59, 27, 49, 17, 57, 25,
    15, 47,  7, 39, 13, 45,  5, 37, 63, 31, 55, 23, 61, 29, 53, 21 };

kernel void dither(texture2d<float> src [[texture(0)]], constant Job &j [[buffer(0)]], device uchar4 *out [[buffer(1)]],
                   uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= j.width || gid.y >= j.height) return;
    constexpr sampler s(filter::linear, mip_filter::linear, address::clamp_to_edge);
    float t = (bayer[(gid.y % 8) * 8 + gid.x % 8] + 0.5) / 64.0;
    uint index = gid.y * j.width + gid.x;
    float2 at = (float2(gid) + 0.5) * j.cell;
    if (at.y < j.fade && at.y / j.fade <= t) { out[index] = uchar4(0); return; }
    float2 uv = (at - j.origin) / j.extent;
    // 九点取平均压掉原图的压缩块；临近下沿起改取越来越粗的一级 mip，出了下沿一小截就只剩一片匀的颜色：边上那一行的起伏不往下拉成竖纹
    float lod = clamp((uv.y - 0.98) * 150.0, 0.0, 7.0);
    float3 c = 0;
    for (int y = -1; y <= 1; y++)
        for (int x = -1; x <= 1; x++)
            c += src.sample(s, uv + float2(x, y) * j.texel * 1.5, level(lod)).rgb;
    c /= 9.0;
    // 先略提饱和与对比：每通道只剩四级，抖完的颜色比原图灰一点
    c = saturate((mix(float3(dot(c, float3(0.2126, 0.7152, 0.0722))), c, 1.1) - 0.5) * 1.05 + 0.5);
    float3 o = floor(c * 3.0 + t) / 3.0;
    out[index] = uchar4(uchar3(round(saturate(o) * 255.0)), 255);
}
"""#
}
