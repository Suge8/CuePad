import MetalKit
import SwiftUI

/// 思考强度轨道里填满的那一段（模型气泡，`ThinkingTrack`）：一块铺满轨道的 Metal 画布，调用方按钮的位置遮出左边一截；色带从左端的靛长到
/// 填满处（`fill`，占轨道宽的几成）正好是这一档的颜色，
/// 里面两层星点往右流（近的大而快、远的小而慢），档越高（`energy` 0→1，`ThinkingMeter.energy`）星越密、流得越快、越亮；
/// 中档起有一道扫光，最高档整段的能量翻涌、右端一团光在呼吸。换档时颜色与星的密度在画布里平滑地过去（`ThinkingRenderer`），不跳。
/// `running` 为假（减弱动态效果、省电、页不在前台，`LoopsPlay`）时停在一帧；关（`energy` 为 nil）、过渡走完也停，不空转。
/// 着色器在运行时编（`ThinkingShaders`），不进构建：项目不另装 Metal 编译工具链（同 `FigureGPU`）；编好之前垫着同一套色的静止渐变。
/// 否决过：Core Animation 的渐变层叠两团光——只能翻色，做不出星点、扫光这一档一个样子的差别；SwiftUI 的网格渐变按帧走——气泡开着时 App 进程一直占约 5% CPU。
struct ThinkingField: View {
    let energy: Double?
    let fill: Double
    let running: Bool
    @Environment(\.palette) private var palette

    var body: some View {
        let ramp = [palette.thinkingLow, palette.thinkingMid, palette.thinkingHigh]
        LinearGradient(colors: [palette.thinkingLow, palette.thinking(energy ?? 0)], startPoint: .leading, endPoint: .trailing)
            .opacity(energy == nil ? 0 : 1)
            .overlay {
                ThinkingSurface(energy: energy, fill: fill, running: running, ramp: ramp.map { $0.resolve(in: EnvironmentValues()) })
            }
            .allowsHitTesting(false)
            .readerHidden(true)
    }
}

/// 显卡那一份，全 App 共用、只建一次；编译与建管线走异步接口，不占主线程。
final class ThinkingGPU {
    private(set) static var ready: ThinkingGPU?
    private static var warming: Task<Void, Never>?

    static func warm() {
        guard warming == nil else { return }
        warming = Task { ready = await ThinkingGPU() }
    }

    static func whenReady() async { await warming?.value }

    let device: MTLDevice
    let queue: MTLCommandQueue
    let pipeline: MTLRenderPipelineState

    private init() async {
        let device = MTLCreateSystemDefaultDevice()!
        self.device = device
        queue = device.makeCommandQueue()!
        let library = try! await device.makeLibrary(source: ThinkingShaders.source, options: nil)
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = library.makeFunction(name: "thinkingVertex")
        d.fragmentFunction = library.makeFunction(name: "thinkingFragment")
        d.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipeline = try! await device.makeRenderPipelineState(descriptor: d)
    }
}

/// 与着色器里的 `Uniforms` 逐字段对齐：全是 float4。
private struct ThinkingUniforms {
    var a: SIMD4<Float>  // 宽, 高（像素）, 时间, 能量
    var b: SIMD4<Float>  // 每点几像素, 关（1 是关）, 填满处（占宽几成）, 0
    var low, mid, high: SIMD4<Float>
}

final class ThinkingRenderer: NSObject, MTKViewDelegate {
    /// 要去的档与填满处；画出来的每帧往它们靠（时间常数 `settle` 秒），颜色与星的密度一起过去。
    var target: Double = 0
    var fill: Double = 1
    private var shownFill: Double?
    var off = false
    var ramp: [SIMD4<Float>] = []
    var running = true
    private var shown: Double?
    private var last: CFTimeInterval?
    private static let settle = 0.22

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    /// 动画放着时一直画；不放、关着、或过渡走完了停下（要画时 `update` 再点一下）。
    var settled: Bool { shown.map { abs($0 - target) < 0.002 } ?? false }

    func draw(in view: MTKView) {
        guard let gpu = ThinkingGPU.ready, ramp.count == 3,
              let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable, let commands = gpu.queue.makeCommandBuffer() else { return }
        let now = CACurrentMediaTime()
        let step = last.map { min(now - $0, 0.1) } ?? 0
        last = now
        let from = shown ?? target
        let keep = running ? exp(-step / Self.settle) : 0
        shown = target + (from - target) * keep
        shownFill = fill + ((shownFill ?? fill) - fill) * keep
        // 星与扫光按全局时钟走：两次打开同一档，接着上次的样子流，不从头起
        let time = running ? Float(now.truncatingRemainder(dividingBy: 3600)) : 0
        let size = view.drawableSize, scale = Float(size.width / max(view.bounds.width, 1))
        var uniforms = ThinkingUniforms(
            a: SIMD4(Float(size.width), Float(size.height), time, Float(shown ?? target)),
            b: SIMD4(scale, off ? 1 : 0, Float(shownFill ?? fill), 0), low: ramp[0], mid: ramp[1], high: ramp[2])
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        let render = commands.makeRenderCommandEncoder(descriptor: pass)!
        render.setRenderPipelineState(gpu.pipeline)
        render.setFragmentBytes(&uniforms, length: MemoryLayout<ThinkingUniforms>.stride, index: 0)
        render.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        render.endEncoding()
        commands.present(drawable)
        commands.commit()
        if !running || (off && settled) {
            view.isPaused = true
            last = nil
        }
    }
}

private struct ThinkingSurface {
    let energy: Double?
    let fill: Double
    let running: Bool
    let ramp: [Color.Resolved]

    func makeCoordinator() -> ThinkingRenderer { ThinkingRenderer() }

    func make(_ renderer: ThinkingRenderer) -> MTKView {
        ThinkingGPU.warm()
        let view = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        view.preferredFramesPerSecond = Int(Motion.Beat.frameRate)
        view.delegate = renderer
        #if os(iOS)
        view.isOpaque = false
        view.backgroundColor = .clear
        #else
        view.layer?.isOpaque = false
        view.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        #endif
        update(view, renderer)
        return view
    }

    func update(_ view: MTKView, _ renderer: ThinkingRenderer) {
        renderer.target = energy ?? 0
        renderer.fill = fill
        renderer.off = energy == nil
        renderer.ramp = ramp.map { SIMD4(Float($0.red), Float($0.green), Float($0.blue), 1) }
        renderer.running = running
        view.enableSetNeedsDisplay = !running
        view.isPaused = !running
        if !running { redraw(view) }
        // 着色器还没编好时这一帧画不出：编好再补一帧（动着的下一帧自己会画）
        if ThinkingGPU.ready == nil { Task { await ThinkingGPU.whenReady(); redraw(view) } }
    }

    private func redraw(_ view: MTKView) {
        #if os(iOS)
        view.setNeedsDisplay()
        #else
        view.needsDisplay = true
        #endif
    }
}

#if os(iOS)
extension ThinkingSurface: UIViewRepresentable {
    func makeUIView(context: Context) -> MTKView { make(context.coordinator) }
    func updateUIView(_ view: MTKView, context: Context) { update(view, context.coordinator) }
}
#else
extension ThinkingSurface: NSViewRepresentable {
    func makeNSView(context: Context) -> MTKView { make(context.coordinator) }
    func updateNSView(_ view: MTKView, context: Context) { update(view, context.coordinator) }
}
#endif

/// 思考场的着色器源码：App 运行时交给系统编（`ThinkingGPU.warm`），不进构建。写错由 `xc.sh check` 拦（scripts/shaders.swift 用本机的 Metal 编这一段），
/// 收尾的 `"""#` 顶格写：那个脚本按它切。与 `ThinkingUniforms` 逐字段对齐。
nonisolated enum ThinkingShaders {
    static let source = #"""
#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float4 a;   // 宽, 高（像素）, 时间, 能量
    float4 b;   // 每点几像素, 关, 填满处（占宽几成）
    float4 low, mid, high;
};

struct Out {
    float4 position [[position]];
    float2 uv;
};

vertex Out thinkingVertex(uint id [[vertex_id]]) {
    float2 p = float2(id & 1, id >> 1);
    Out o;
    o.position = float4(p.x * 2 - 1, 1 - p.y * 2, 0, 1);
    o.uv = p;
    return o;
}

static float hash(float2 p) {
    p = fract(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

static float noise(float2 p) {
    float2 i = floor(p), f = fract(p);
    float2 u = f * f * (3 - 2 * f);
    return mix(mix(hash(i), hash(i + float2(1, 0)), u.x), mix(hash(i + float2(0, 1)), hash(i + float2(1, 1)), u.x), u.y);
}

static float3 ramp(float x, constant Uniforms &u) {
    x = clamp(x, 0.0, 1.0);
    return x < 0.5 ? mix(u.low.rgb, u.mid.rgb, x * 2) : mix(u.mid.rgb, u.high.rgb, x * 2 - 1);
}

// 一层星：按格子撒，每格至多一颗、按能量决定有没有；整层往右流，近的层格大、流得快。
// 每个像素看周围九格：光晕比格子边近时也画完整，不被格子切成方块。
static float stars(float2 p, float cell, float speed, float time, float density, float seed) {
    p.x -= time * speed;
    float2 home = floor(p / cell);
    float sum = 0;
    for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
            float2 id = home + float2(dx, dy);
            float h = hash(id + seed);
            if (h > density) continue;
            float2 at = (id + float2(hash(id + seed + 3.1), hash(id + seed + 7.7))) * cell;
            float d = length(p - at);
            float twinkle = 0.55 + 0.45 * sin(time * (2.0 + 3.0 * h) + h * 40.0);
            float size = cell * (0.06 + 0.05 * hash(id + seed + 11.0));
            sum += twinkle * (smoothstep(size, 0.0, d) + 0.35 * exp(-d * d / (size * size * 9.0)));
        }
    }
    return sum;
}

fragment float4 thinkingFragment(Out in [[stage_in]], constant Uniforms &u [[buffer(0)]]) {
    float2 size = u.a.xy / u.b.x;          // 按点算：星的大小、流速在各种屏上一样
    float2 p = in.uv * size;
    float time = u.a.z, e = u.a.w, h = size.y;
    if (u.b.y > 0.5 && e < 0.002) return float4(0);
    // 底：左端靛，往右长到填满处正好是这一档的颜色；上沿受光、下沿沉
    float along = clamp(in.uv.x / max(u.b.z, 0.05), 0.0, 1.0);
    float3 c = ramp(along * e, u);
    c *= 1.1 - 0.25 * in.uv.y;
    // 能量翻涌：一层慢慢漂的噪声，档越高越明显
    float flow = noise(float2(p.x / h * 1.3 - time * (0.3 + 1.2 * e), p.y / h * 1.6 + time * 0.2));
    c += (flow - 0.5) * 0.22 * e * c;
    // 星：越往右越密越亮（能量从左边流进来）
    float lean = smoothstep(0.0, 0.9, along);
    float density = mix(0.0, 0.55, e) * lean;
    float glow = stars(p, h * 0.5, h * (0.4 + 2.6 * e), time, density, 0.0)
               + 0.6 * stars(p + 13.0, h * 0.32, h * (0.2 + 1.3 * e), time, density * 0.8, 5.0);
    c += glow * (0.35 + 0.65 * e) * float3(1.0, 0.97, 1.0);
    // 扫光：中档起一道斜光从左扫到右
    float sweepOn = smoothstep(0.35, 0.6, e);
    float phase = fract(time / 2.4) * 1.6 - 0.3;
    float band = exp(-pow((along - phase - (in.uv.y - 0.5) * 0.25) / 0.07, 2.0));
    c += band * 0.28 * sweepOn;
    // 最高档：右端一团光在呼吸
    float peak = smoothstep(0.85, 1.0, e);
    float breathe = 0.75 + 0.25 * sin(time * 3.2);
    float right = exp(-pow((u.b.z - in.uv.x) * size.x / (h * 1.4), 2.0));
    c += right * peak * breathe * 0.35 * float3(1.0, 0.85, 0.95);
    // 颗粒：免得渐变起色阶
    c += (hash(floor(p * u.b.x)) - 0.5) * 0.02;
    return float4(clamp(c, 0.0, 1.0), 1);
}
"""#
}
