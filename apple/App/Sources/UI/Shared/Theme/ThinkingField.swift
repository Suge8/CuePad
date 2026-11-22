import MetalKit
import SwiftUI

/// 思考强度轨道里填满的那一段（模型气泡，`ThinkingTrack`）：一块铺满轨道的 Metal 画布，调用方按钮的位置遮出左边一截。
/// 画法同 Cue 页的天：格子一样大（`DitherGPU.cell`）、对齐设备像素，按同一张 8×8 阈值抖成网点（只抖明暗、不抖色相），整个 App 一种质感。
/// 色带从左端的钴蓝长到填满处（`fill`）正好是这一档的颜色；档越高（`energy` 0→1，`ThinkingMeter.energy`）流得越快、多一样东西，前面的都留着：
/// 最低档星点明灭 → 低档往右漂 → 中档拉成流光 → 高档一阵阵风吹到钮（吹过处流光亮起来）、钮外亮一圈 → 很高档多一层更快的流、风加密 → 最高档整段翻涌、钮边冒金色火花。
/// 每样东西按能量淡入，换档时在画布里连续地过去（`ThinkingRenderer`）；换档那一下整段亮一下、从钮荡开一圈，档越高越狠。
/// `running` 为假（减弱动态效果、省电、页不在前台，`LoopsPlay`）时停在一帧；关（`energy` 为 nil）、过渡走完也停，不空转。
/// 着色器在运行时编（`ThinkingShaders`），不进构建：项目不另装 Metal 编译工具链（同 `FigureGPU`）；编好之前垫着同一套色的静止渐变。
/// 否决过：Core Animation 的渐变层叠两团光——只能翻色，做不出一档一个样子的差别；SwiftUI 的网格渐变按帧走——气泡开着时 App 进程一直占约 5% CPU；
/// 平滑的光带不抖网点——和 Cue 页的天、像素的小 Cue 是两种质感。
struct ThinkingField: View {
    let energy: Double?
    let fill: Double
    let running: Bool
    @Environment(\.palette) private var palette

    var body: some View {
        LinearGradient(colors: [palette.thinkingLow, palette.thinking(energy ?? 0)], startPoint: .leading, endPoint: .trailing)
            .opacity(energy == nil ? 0 : 1)
            .overlay {
                ThinkingSurface(energy: energy, fill: fill, running: running, ramp: [palette.thinkingLow, palette.thinkingMid, palette.thinkingHigh, palette.thinkingSpark])
            }
            .allowsHitTesting(false)
            .readerHidden(true)
    }
}

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

private struct ThinkingUniforms {
    var a: SIMD4<Float>
    var b: SIMD4<Float>
    var c: SIMD4<Float>
    var d: SIMD4<Float>
    var low, mid, high, spark: SIMD4<Float>
}

final class ThinkingRenderer: NSObject, MTKViewDelegate {
    var target: Double = 0 {
        didSet { if target != oldValue, shown != nil { changedAt = CACurrentMediaTime() } }
    }
    private var changedAt = -Double.infinity
    var fill: Double = 1
    private var shownFill: Double?
    var off = false
    var ramp: [SIMD4<Float>] = []
    var running = true
    private var shown: Double?
    private var last: CFTimeInterval?
    private static let settle = 0.22
    private var flow = SIMD2(repeating: CACurrentMediaTime().truncatingRemainder(dividingBy: 97))
    private var sweeps = 0.0

    private static func fade(_ energy: Double, by stage: Double) -> Double {
        let t = min(max((energy * 5 - stage) / 0.8 + 1, 0), 1)
        return t * t * (3 - 2 * t)
    }
    private static func speed(_ energy: Double) -> Double { 0.05 + fade(energy, by: 1) * 0.8 * pow(12, energy) }
    private static func sweep(_ energy: Double) -> Double { 0.45 + 0.4 * min(max((energy - 0.6) / 0.4, 0), 1) }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    var settled: Bool { shown.map { abs($0 - target) < 0.002 } ?? false }

    func draw(in view: MTKView) {
        guard let gpu = ThinkingGPU.ready, ramp.count == 4,
              let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable, let commands = gpu.queue.makeCommandBuffer() else { return }
        let now = CACurrentMediaTime()
        let step = last.map { min(now - $0, 0.1) } ?? 0
        last = now
        let from = shown ?? target
        let keep = running ? exp(-step / Self.settle) : 0
        shown = target + (from - target) * keep
        shownFill = fill + ((shownFill ?? fill) - fill) * keep
        let energy = shown ?? target, streak = Self.fade(energy, by: 2)
        let blaze = Self.fade(energy, by: 5)
        let stretch = SIMD2(1 + 3.5 * streak + 2 * blaze, 1 + 5 * streak + 3 * blaze)
        if running {
            flow += step * Self.speed(energy) * SIMD2(1, 1.7)
            sweeps += step * Self.sweep(energy)
        }
        let time = running ? Float(now.truncatingRemainder(dividingBy: 3600)) : 0
        let size = view.drawableSize, scale = Float(size.width / max(view.bounds.width, 1))
        var uniforms = ThinkingUniforms(
            a: SIMD4(Float(size.width), Float(size.height), time, Float(energy)),
            b: SIMD4(scale, off ? 1 : 0, Float(shownFill ?? fill), Float(min(now - changedAt, 10))),
            c: SIMD4(Float(DitherGPU.cell) * max(1, scale.rounded()), Float(sweeps.truncatingRemainder(dividingBy: 1)), Float(streak), 0),
            d: SIMD4(Float(flow.x), Float(flow.y), Float(stretch.x), Float(stretch.y)), low: ramp[0], mid: ramp[1], high: ramp[2], spark: ramp[3])
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        let render = commands.makeRenderCommandEncoder(descriptor: pass)!
        render.setRenderPipelineState(gpu.pipeline)
        render.setFragmentBytes(&uniforms, length: MemoryLayout<ThinkingUniforms>.stride, index: 0)
        render.setFragmentBytes(Halftone.table, length: Halftone.table.count * MemoryLayout<Float>.stride, index: 1)
        render.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        render.endEncoding()
        commands.present(drawable)
        commands.commit()
        if !running || (off && settled && now - changedAt > 1) {
            view.isPaused = true
            last = nil
        }
    }
}

private struct ThinkingSurface {
    let energy: Double?
    let fill: Double
    let running: Bool
    let ramp: [Color]

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
        return view
    }

    func update(_ view: MTKView, _ renderer: ThinkingRenderer, in environment: EnvironmentValues) {
        renderer.target = energy ?? 0
        renderer.fill = fill
        renderer.off = energy == nil
        renderer.ramp = ramp.map {
            let c = $0.resolve(in: environment)
            return SIMD4(c.red, c.green, c.blue, 1)
        }
        renderer.running = running
        view.enableSetNeedsDisplay = !running
        view.isPaused = !running
        if !running { redraw(view) }
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
    func updateUIView(_ view: MTKView, context: Context) { update(view, context.coordinator, in: context.environment) }
}
#else
extension ThinkingSurface: NSViewRepresentable {
    func makeNSView(context: Context) -> MTKView { make(context.coordinator) }
    func updateNSView(_ view: MTKView, context: Context) { update(view, context.coordinator, in: context.environment) }
}
#endif

nonisolated enum ThinkingShaders {
    static let source = #"""
#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float4 a;   // 宽, 高（像素）, 时间, 能量
    float4 b;   // 每点几像素, 关, 填满处（占宽几成）, 换档后过了几秒
    float4 c;   // 网点一格几像素, 风吹过了几趟, 拉成流光几成
    float4 d;   // 两层星各流过了多远（几个轨道高）、各拉长几倍
    float4 low, mid, high, spark;
};

struct Out {
    float4 position [[position]];
};

vertex Out thinkingVertex(uint id [[vertex_id]]) {
    float2 p = float2(id & 1, id >> 1);
    Out o;
    o.position = float4(p.x * 2 - 1, 1 - p.y * 2, 0, 1);
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

// 一层星：按格子撒，每格至多一颗；整层往右流（shift 是流过的路程，画布外按帧累加）。stretch 把每颗星自己沿流向拉长成流光、同时收细，不动它在哪。
// 格宽是格高的 3.5 倍：拉到最长的一道光伸不出左右相邻的格，看周围九格就不被格子切断。density 变时星淡入淡出，不凭空冒出来。
// 否决过：把整片格子横向拉开——换档时拉长的倍数一变，整片从轨道左端被放大出去，看着是猛冲一阵再慢回来，降档时还往回缩。
static float motes(float2 p, float row, float shift, float stretch, float density, float seed, float time, float grain) {
    float2 cell = float2(row * 3.5, row);
    float2 q = float2(p.x - shift, p.y);
    float2 home = floor(q / cell);
    float2 size = row * grain * float2(stretch, pow(stretch, -0.25));
    float sum = 0;
    for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
            float2 id = home + float2(dx, dy);
            float h = hash(id + seed);
            // 竖向不贴格边：星不被轨道的上下沿切掉，上下两行的也不叠在一起
            float2 d = (q - (id + float2(hash(id + seed + 3.1), 0.2 + 0.6 * hash(id + seed + 7.7))) * cell) / size;
            // 点是明灭的；拉成流光后只微微闪，不在半路上灭掉
            float depth = 0.55 / sqrt(stretch);
            float twinkle = 1.0 - depth + depth * sin(time * (1.5 + 3.0 * h) + h * 40.0);
            sum += twinkle * smoothstep(density, density - 0.08, h) * exp(-dot(d, d));
        }
    }
    return sum;
}

fragment float4 thinkingFragment(Out in [[stage_in]], constant Uniforms &u [[buffer(0)]], constant float *halftone [[buffer(1)]]) {
    float scale = u.b.x, time = u.a.z, e = u.a.w, fill = max(u.b.z, 0.05);
    if (u.b.y > 0.5 && e < 0.002) return float4(0);
    // 格里每个像素取格心的值
    float cellPx = u.c.x;
    uint2 cell = uint2(in.position.xy / cellPx);
    float2 size = u.a.xy / scale;
    float2 p = (float2(cell) + 0.5) * cellPx / scale;
    float h = size.y;
    float along = clamp(p.x / (size.x * fill), 0.0, 1.0);
    float knob = size.x * fill - h * 0.5;
    // 每跨一档多一样东西，到它那一档正好全亮：0 最低 … 5 最高
    float stage = e * 5.0;
    float streak = u.c.z, pulse = smoothstep(2.2, 3.0, stage);
    float layer = smoothstep(3.2, 4.0, stage), blaze = smoothstep(4.2, 5.0, stage);

    // 明暗：0 是这一档的颜色压暗，1 是它本身，往上是光（白，最高档偏金）。低档整段暗而静，档越高底子越亮；左暗右亮、上沿受光，最高档翻涌
    float churn = noise(float2(p.x / h * 1.1 - time * 1.4, p.y / h * 2.2 + time * 0.6));
    float tone = 0.2 + 0.4 * e + 0.4 * along + 0.1 * (0.5 - p.y / h) + blaze * (churn - 0.5) * 0.6;

    // 低档是密而小的点，拉成流光后一道占的地方长了，留下的少一些
    float light = (1.8 + 0.8 * streak + 0.8 * e) * motes(p, h * 0.5, u.d.x * h, u.d.z, 0.85 - 0.35 * streak, 0.0, time, 0.26);
    light += layer * 1.4 * motes(p + 17.0, h * 0.34, u.d.y * h, u.d.w, 0.2, 5.0, time, 0.18);
    // 一阵阵的风：一段宽而软的亮从左边外头吹进来、穿过钮出去，吹到哪里哪里的流光亮起来；高档一阵，很高两阵，最高三阵。
    // 否决过：一道竖的细亮线扫过去——横着流的一片里立着几根白线，像扫描仪。
    float gust = 0;
    for (int k = 0; k < 3; k++) {
        float weight = k == 0 ? pulse : k == 1 ? layer : blaze;
        float x = along - (fract(u.c.y + float(k) / 3.0) * 1.7 - 0.35);
        gust += weight * exp(-pow(x / 0.17, 2.0));
    }
    light = light * (1.0 + 1.2 * gust) + 0.2 * gust;
    float2 toKnob = float2(p.x - knob, p.y - h * 0.5);
    float dk = length(toKnob);
    light += exp(-pow(dk / (h * 0.85), 2.0)) * (0.3 * pulse + 0.4 * blaze * (0.75 + 0.25 * sin(time * 3.2)));
    // 换档那一下：整段亮一下、偏向光的颜色，同时从钮荡开一圈，半秒散尽；档越高亮得越狠。只动明暗与颜色、不动流速：
    // 冲一下再慢回来，看着像刚提上去的速度又掉了。
    float since = u.b.w;
    float kick = exp(-since * 4.5) * (0.3 + 0.7 * e);
    light += exp(-pow((dk - since * h * 6.0) / (h * 0.4), 2.0)) * kick * 1.6;
    tone += light * (0.6 + 0.4 * along) + kick * 0.7;

    // 只抖明暗、不抖色相（同一种墨深浅两级相间，不冒杂色），四级一档，阈值是 `Halftone.table`
    float q = floor(max(tone, 0.0) * 4.0 + halftone[(cell.y & 7) * 8 + (cell.x & 7)]) / 4.0;
    float3 hue = ramp(along * e, u);
    float3 glow = mix(float3(1.0), u.spark.rgb, blaze * 0.6);
    float3 c = q <= 1.0 ? mix(hue * 0.55, hue, q) : mix(hue, glow, min((q - 1.0) * 1.6, 1.0));
    c = mix(c, glow, kick * 0.25);
    // 最高档的火花：钮边的格子一闪一闪地变金
    float near = exp(-pow((p.x - knob) / (h * 1.6), 2.0));
    c = mix(c, u.spark.rgb, step(1.0 - 0.025 * blaze * near, hash(float2(cell) + floor(time * 8.0))));
    return float4(c, 1);
}
"""#
}
