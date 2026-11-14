import MetalKit
import SwiftUI

/// 显卡那一份，全 App 共用、只建一次：算格子的计算管线，格子与点各两种混合（深色底光叠加、其余预乘混合）。
/// 着色器在运行时编（`FigureShaders`）：对话页一出现就开编（`warm`），编译与建管线都走异步接口、不占主线程，编好之前角色不画。
final class FigureGPU {
    private(set) static var ready: FigureGPU?
    private static var warming: Task<Void, Never>?

    static func warm() {
        guard warming == nil else { return }
        warming = Task { ready = await FigureGPU() }
    }

    static func whenReady() async { await warming?.value }

    let device: MTLDevice
    let queue: MTLCommandQueue
    let tiles: MTLComputePipelineState
    private let tileGlow, tileBlend, spriteGlow, spriteBlend: MTLRenderPipelineState

    private init() async {
        let device = MTLCreateSystemDefaultDevice()!
        self.device = device
        queue = device.makeCommandQueue()!
        let library = try! await device.makeLibrary(source: FigureShaders.source, options: nil)
        tiles = try! await device.makeComputePipelineState(function: library.makeFunction(name: "figureTiles")!)
        func make(_ vertex: String, additive: Bool) async -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = library.makeFunction(name: vertex)
            d.fragmentFunction = library.makeFunction(name: "dotFragment")
            let color = d.colorAttachments[0]!
            color.pixelFormat = .bgra8Unorm
            color.isBlendingEnabled = true
            color.sourceRGBBlendFactor = .one
            color.sourceAlphaBlendFactor = .one
            color.destinationRGBBlendFactor = additive ? .one : .oneMinusSourceAlpha
            color.destinationAlphaBlendFactor = additive ? .one : .oneMinusSourceAlpha
            return try! await device.makeRenderPipelineState(descriptor: d)
        }
        tileGlow = await make("tileVertex", additive: true)
        tileBlend = await make("tileVertex", additive: false)
        spriteGlow = await make("spriteVertex", additive: true)
        spriteBlend = await make("spriteVertex", additive: false)
    }

    func pipeline(tiles: Bool, additive: Bool) -> MTLRenderPipelineState {
        switch (tiles, additive) {
        case (true, true): tileGlow
        case (true, false): tileBlend
        case (false, true): spriteGlow
        case (false, false): spriteBlend
        }
    }
}

/// 一块画布：每帧先在显卡上算格子（`figureTiles`），再画两遍——底光或投影、格子——点缀（脚下的光在格子下，波纹与火星在上）跟着画。
/// 点缀的存储三份轮着用、最多三帧在显卡上：写这一帧的点时不碰显卡还在读的那份，也不每帧新建。
final class FigureRenderer: NSObject, MTKViewDelegate {
    let motion: FigureMotion
    var dark = true
    private var store: Store?
    private var frame = 0
    private let inFlight = DispatchSemaphore(value: Store.depth)

    private struct Store {
        static let depth = 3
        /// 一帧的点数：脚下的光约一百五、波纹约一百一、火星与念头二三十，留出一倍。
        static let sprites = 512
        let tiles: MTLBuffer
        let sprites: [MTLBuffer]

        init(_ device: MTLDevice) {
            tiles = device.makeBuffer(length: FigureLayout.tiles * FigureLayout.tiles * MemoryLayout<SIMD4<Float>>.stride * 2, options: .storageModePrivate)!
            sprites = (0..<Self.depth).map { _ in device.makeBuffer(length: Self.sprites * MemoryLayout<FigureSprite>.stride, options: .storageModeShared)! }
        }
    }

    init(motion: FigureMotion) { self.motion = motion }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let gpu = FigureGPU.ready else { return }
        let t = CACurrentMediaTime()
        let (frameUniforms, sprites, under) = motion.step(at: t, dark: dark)
        let fps = motion.busy(at: t) ? 60 : 30
        if view.preferredFramesPerSecond != fps { view.preferredFramesPerSecond = fps }
        guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable, let commands = gpu.queue.makeCommandBuffer() else { return }
        let store = store ?? Store(gpu.device)
        self.store = store
        inFlight.wait()
        commands.addCompletedHandler { @Sendable [inFlight] _ in inFlight.signal() }
        let points = store.sprites[frame % Store.depth]
        frame += 1
        sprites.withUnsafeBytes { bytes in bytes.baseAddress.map { points.contents().copyMemory(from: $0, byteCount: bytes.count) } }

        var uniforms = frameUniforms
        let size = MemoryLayout<FigureUniforms>.stride, n = FigureLayout.tiles
        let compute = commands.makeComputeCommandEncoder()!
        compute.setComputePipelineState(gpu.tiles)
        compute.setBytes(&uniforms, length: size, index: 0)
        compute.setBuffer(store.tiles, offset: 0, index: 1)
        compute.dispatchThreads(MTLSize(width: n, height: n, depth: 1), threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
        compute.endEncoding()

        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        let render = commands.makeRenderCommandEncoder(descriptor: pass)!
        for step in 0..<2 {
            uniforms.f.w = Float(step)
            render.setVertexBytes(&uniforms, length: size, index: 0)
            render.setFragmentBytes(&uniforms, length: size, index: 0)
            let additive = step == 0 && dark
            func dots(_ range: Range<Int>) {
                guard !range.isEmpty else { return }
                render.setRenderPipelineState(gpu.pipeline(tiles: false, additive: additive))
                render.setVertexBuffer(points, offset: 0, index: 1)
                render.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: range.count, baseInstance: range.lowerBound)
            }
            dots(0..<under)
            render.setRenderPipelineState(gpu.pipeline(tiles: true, additive: additive))
            render.setVertexBuffer(store.tiles, offset: 0, index: 1)
            render.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: n * n)
            dots(under..<sprites.count)
        }
        render.endEncoding()
        commands.present(drawable)
        commands.commit()
    }
}

/// Cue 角色画在一块透明的 Metal 画布上，排版只占角色本身那一方块（`FigureLayout.size`），画布四周伸出去给点缀，不接点击。
/// 一块画布只陪角色出场一次：`arrives` 为真就从格子拼起来（否则本来就在），`leaving` 一变真就碎开。
/// `running` 为假（减弱动态效果、省电、页不在前台、滚出屏幕）时停在一帧：各项到位、不再每帧画。
struct FigureCanvas: View {
    let pose: FigurePose
    let arrives: Bool
    let leaving: Bool
    let running: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        FigureSurface(pose: pose, arrives: arrives, leaving: leaving, running: running, dark: colorScheme == .dark)
            .frame(width: FigureLayout.canvas.width, height: FigureLayout.canvas.height)
            .allowsHitTesting(false)
            .readerHidden(true)
    }
}

private struct FigureSurface {
    let pose: FigurePose
    let arrives: Bool
    let leaving: Bool
    let running: Bool
    let dark: Bool

    func makeCoordinator() -> FigureRenderer {
        FigureRenderer(motion: FigureMotion(pose: pose, arrives: arrives && running, at: CACurrentMediaTime()))
    }

    func make(_ renderer: FigureRenderer) -> MTKView {
        let view = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        view.preferredFramesPerSecond = 30
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

    func update(_ view: MTKView, _ renderer: FigureRenderer) {
        let t = CACurrentMediaTime()
        renderer.dark = dark
        renderer.motion.set(pose, at: t)
        if leaving { renderer.motion.leave(at: t) }
        view.isPaused = !running
        view.enableSetNeedsDisplay = !running
        guard !running else { return }
        renderer.motion.settle()
        redraw(view)
        // 停着的画布只在要它画时画一次：着色器还没编好的话等编好再补这一帧
        if FigureGPU.ready == nil { Task { await FigureGPU.whenReady(); redraw(view) } }
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
extension FigureSurface: UIViewRepresentable {
    func makeUIView(context: Context) -> MTKView { make(context.coordinator) }
    func updateUIView(_ view: MTKView, context: Context) { update(view, context.coordinator) }
}
#else
extension FigureSurface: NSViewRepresentable {
    func makeNSView(context: Context) -> MTKView { make(context.coordinator) }
    func updateNSView(_ view: MTKView, context: Context) { update(view, context.coordinator) }
}
#endif
