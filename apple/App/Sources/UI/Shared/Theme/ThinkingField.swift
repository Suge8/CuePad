import MetalKit
import SwiftUI

/// 思考强度轨道里填满的那一段（模型气泡，`ThinkingTrack`）：一块铺满轨道的 Metal 画布，调用方按钮的位置遮出左边一截。
/// 画法同 Cue 页的天：格子一样大（`DitherGPU.cell`）、对齐设备像素，按同一张 8×8 阈值抖成网点（只抖明暗、不抖色相），整个 App 一种质感。
/// 色带从左端的钴蓝长到填满处（`fill`）正好是这一档的颜色；档越高（`energy` 0→1，`ThinkingMeter.energy`）多一样东西，前面的都留着：
/// 最低档星点明灭 → 低档往右漂 → 中档拉成流光 → 高档一阵阵脉冲冲到钮、钮外亮一圈 → 很高档多一层更快的流、脉冲加密 → 最高档整段翻涌、钮边冒金色火花。
/// 每样东西按能量淡入，换档时在画布里连续地过去（`ThinkingRenderer`）；换档那一下从钮荡开一圈。
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
    var b: SIMD4<Float>  // 每点几像素, 关（1 是关）, 填满处（占宽几成）, 换档后过了几秒
    var c: SIMD4<Float>  // 网点一格几像素
    var low, mid, high, spark: SIMD4<Float>
}

final class ThinkingRenderer: NSObject, MTKViewDelegate {
    /// 要去的档与填满处；画出来的每帧往它们靠（时间常数 `settle` 秒），颜色与星的密度一起过去。
    var target: Double = 0 {
        didSet { if target != oldValue, shown != nil { changedAt = CACurrentMediaTime() } }
    }
    /// 上一次换档的时刻：从钮荡开的那一圈按它走；打开气泡那一下不算换档
    private var changedAt = -Double.infinity
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
        guard let gpu = ThinkingGPU.ready, ramp.count == 4,
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
            b: SIMD4(scale, off ? 1 : 0, Float(shownFill ?? fill), Float(min(now - changedAt, 10))),
            c: SIMD4(Float(DitherGPU.cell) * max(1, scale.rounded()), 0, 0, 0), low: ramp[0], mid: ramp[1], high: ramp[2], spark: ramp[3])
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        let render = commands.makeRenderCommandEncoder(descriptor: pass)!
        render.setRenderPipelineState(gpu.pipeline)
        render.setFragmentBytes(&uniforms, length: MemoryLayout<ThinkingUniforms>.stride, index: 0)
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
    func updateUIView(_ view: MTKView, context: Context) { update(view, context.coordinator, in: context.environment) }
}
#else
extension ThinkingSurface: NSViewRepresentable {
    func makeNSView(context: Context) -> MTKView { make(context.coordinator) }
    func updateNSView(_ view: MTKView, context: Context) { update(view, context.coordinator, in: context.environment) }
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
    float4 b;   // 每点几像素, 关, 填满处（占宽几成）, 换档后过了几秒
    float4 c;   // 网点一格几像素
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

// 8×8 有序抖动的阈值，与 Cue 页的天同一张表：按位交错算出来，不另抄一份。
static float bayer(uint2 c) {
    uint x = c.x ^ c.y, y = c.y, v = 0;
    for (uint b = 0; b < 3; b++) v |= ((x >> b) & 1) << (5 - 2 * b) | ((y >> b) & 1) << (4 - 2 * b);
    return (float(v) + 0.5) / 64.0;
}

static float3 ramp(float x, constant Uniforms &u) {
    x = clamp(x, 0.0, 1.0);
    return x < 0.5 ? mix(u.low.rgb, u.mid.rgb, x * 2) : mix(u.mid.rgb, u.high.rgb, x * 2 - 1);
}

// 一层星：按格子撒，每格至多一颗；整层往右流。stretch 把星沿流向拉长成流光。看周围九格：拉长的光不被格子切断。
static float motes(float2 p, float cell, float speed, float stretch, float density, float seed, float time, float grain) {
    p.x -= time * speed;
    float2 q = float2(p.x / stretch, p.y);
    float2 home = floor(q / cell);
    float sum = 0;
    for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
            float2 id = home + float2(dx, dy);
            float h = hash(id + seed);
            if (h > density) continue;
            float2 d = q - (id + float2(hash(id + seed + 3.1), hash(id + seed + 7.7))) * cell;
            float size = cell * grain;
            float twinkle = 0.45 + 0.55 * sin(time * (1.5 + 3.0 * h) + h * 40.0);
            sum += twinkle * exp(-dot(d, d) / (size * size));
        }
    }
    return sum;
}

fragment float4 thinkingFragment(Out in [[stage_in]], constant Uniforms &u [[buffer(0)]]) {
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
    float drift = smoothstep(0.2, 1.0, stage), streak = smoothstep(1.2, 2.0, stage), pulse = smoothstep(2.2, 3.0, stage);
    float layer = smoothstep(3.2, 4.0, stage), blaze = smoothstep(4.2, 5.0, stage);

    // 明暗：0 是这一档的颜色压暗，1 是它本身，往上是光（白，最高档偏金）。低档整段暗而静，档越高底子越亮；左暗右亮、上沿受光，最高档翻涌
    float churn = noise(float2(p.x / h * 1.1 - time * 1.4, p.y / h * 2.2 + time * 0.6));
    float tone = 0.2 + 0.4 * e + 0.4 * along + 0.1 * (0.5 - p.y / h) + blaze * (churn - 0.5) * 0.6;

    float light = 0;
    float speed = h * (0.05 + 0.8 * drift + 1.6 * streak + 1.6 * layer + 1.6 * blaze);
    light += (1.8 + 0.6 * streak) * motes(p, h * 0.5, speed, 1.0 + 3.5 * streak, 0.25 + 0.2 * e, 0.0, time, 0.26);
    light += layer * 1.2 * motes(p + 17.0, h * 0.34, speed * 1.7, 1.0 + 5.0 * streak, 0.25, 5.0, time, 0.18);
    // 扫描光：一道竖的亮线从左扫到钮，后面拖一截渐暗的余辉；高档一道，很高两道，最高三道
    float period = mix(2.4, 1.5, blaze);
    for (int k = 0; k < 3; k++) {
        float weight = k == 0 ? pulse : k == 1 ? layer : blaze;
        float x = along - fract(time / period + float(k) / 3.0);
        light += weight * (exp(-pow(x / 0.012, 2.0)) * 1.4 + step(x, 0.0) * exp(x / 0.07) * 0.35) * smoothstep(0.0, 0.15, along);
    }
    float2 toKnob = float2(p.x - knob, p.y - h * 0.5);
    float dk = length(toKnob);
    light += exp(-pow(dk / (h * 0.85), 2.0)) * (0.3 * pulse + 0.4 * blaze * (0.75 + 0.25 * sin(time * 3.2)));
    // 换档那一下：从钮荡开一圈，半秒散尽
    float since = u.b.w;
    light += exp(-pow((dk - since * h * 5.0) / (h * 0.3), 2.0)) * exp(-since * 5.0) * 0.9;
    tone += light * (0.6 + 0.4 * along);

    // 只抖明暗、不抖色相（同一种墨深浅两级相间，不冒杂色），四级一档，阈值同 Cue 页的天
    float q = floor(max(tone, 0.0) * 4.0 + bayer(cell)) / 4.0;
    float3 hue = ramp(along * e, u);
    float3 glow = mix(float3(1.0), u.spark.rgb, blaze * 0.6);
    float3 c = q <= 1.0 ? mix(hue * 0.55, hue, q) : mix(hue, glow, min((q - 1.0) * 1.6, 1.0));
    // 最高档的火花：钮边的格子一闪一闪地变金
    float near = exp(-pow((p.x - knob) / (h * 1.6), 2.0));
    c = mix(c, u.spark.rgb, step(1.0 - 0.025 * blaze * near, hash(float2(cell) + floor(time * 8.0))));
    return float4(c, 1);
}
"""#
}
