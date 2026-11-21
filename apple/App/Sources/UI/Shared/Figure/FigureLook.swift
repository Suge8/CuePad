import CoreGraphics
import simd

/// 与着色器（`FigureShaders`）的 `Uniforms` 逐字段对齐。
nonisolated struct FigureUniforms {
    var body = matrix_identity_float3x3, ring = matrix_identity_float3x3
    var a = SIMD4<Float>(), b = SIMD4<Float>(), c = SIMD4<Float>(), d = SIMD4<Float>()
    var e = SIMD4<Float>(), f = SIMD4<Float>(), g = SIMD4<Float>()
    var sh = SIMD4<Float>(), mid = SIMD4<Float>(), lit = SIMD4<Float>(), tint = SIMD4<Float>(), rim = SIMD4<Float>()
    var dark = SIMD4<Float>(), eye = SIMD4<Float>(), cheek = SIMD4<Float>(), line = SIMD4<Float>()
    var r1 = SIMD4<Float>(), r2 = SIMD4<Float>(), r3 = SIMD4<Float>(), hl = SIMD4<Float>(), pool = SIMD4<Float>(), acc = SIMD4<Float>()
}

/// 与着色器的 `Sprite` 对齐：中心 x、y、边长、透明；rgb、发光。
nonisolated struct FigureSprite {
    var rect: SIMD4<Float>
    var col: SIMD4<Float>
}

/// `size` 是角色本身那一方块（排版只占这么大），画布四周多出来的给波纹、火星和碎开时飞走的格子。
nonisolated enum FigureLayout {
    static let size: CGFloat = 144
    static let tiles = 36
    /// 世界坐标里画布那一方块有多宽：角色连环、迷你方块都在里面。
    static let span: Float = 2.7
    static let tile = size / CGFloat(tiles)
    /// 碎开时格子往右上飞出一个多身位，画布往右、往上留出这一截。
    static let origin = CGPoint(x: 20, y: 32)
    static let canvas = CGSize(width: size + 180, height: size + 52)
}

/// 深色下格子是暗底上的光点（带底光）；浅色下光衬不出来，按像素画在浅底上的做法：
/// 最外一圈实心描边（`line`）、缝收小、暗面与中间调压深压饱和、身后一层投影代替发光。不用黄、绿、红：那是"等你""新回复""出错"。
nonisolated struct FigureColors {
    var sh, mid, lit, tint, rim, dark, eye, cheek, line: SIMD3<Float>
    /// 环的三段（靛、紫、青）与高光；点缀色从这四个里挑（`FigureMotion.accent`）。
    var r1, r2, r3, hl, pool: SIMD3<Float>

    func fill(_ u: inout FigureUniforms, accent: SIMD3<Float>) {
        func w(_ v: SIMD3<Float>) -> SIMD4<Float> { SIMD4(v, 1) }
        u.sh = w(sh); u.mid = w(mid); u.lit = w(lit); u.tint = w(tint); u.rim = w(rim)
        u.dark = w(dark); u.eye = w(eye); u.cheek = w(cheek); u.line = w(line)
        u.r1 = w(r1); u.r2 = w(r2); u.r3 = w(r3); u.hl = w(hl); u.pool = w(pool); u.acc = w(accent)
    }

    static func of(dark: Bool) -> FigureColors { dark ? night : day }

    private static func c(_ r: Int, _ g: Int, _ b: Int) -> SIMD3<Float> { SIMD3(Float(r), Float(g), Float(b)) / 255 }

    private static let night = FigureColors(
        sh: c(74, 62, 134), mid: c(178, 168, 208), lit: c(252, 246, 234), tint: c(124, 122, 252), rim: c(140, 222, 255),
        dark: c(42, 38, 82), eye: c(20, 18, 32), cheek: c(242, 168, 214), line: c(74, 62, 134),
        r1: c(86, 94, 238), r2: c(170, 112, 255), r3: c(104, 228, 255), hl: c(238, 250, 255), pool: c(96, 98, 232))
    private static let day = FigureColors(
        sh: c(136, 108, 176), mid: c(226, 206, 214), lit: c(255, 248, 234), tint: c(146, 134, 238), rim: c(96, 160, 226),
        dark: c(58, 46, 100), eye: c(24, 22, 36), cheek: c(246, 146, 192), line: c(82, 62, 132),
        r1: c(52, 58, 204), r2: c(118, 58, 222), r3: c(8, 140, 204), hl: c(36, 168, 244), pool: c(168, 156, 214))
}

extension FigureMotion {
    /// 姿势的各项，按下标放进一个 SIMD16 一起过弹簧。
    nonisolated enum Key {
        static let yaw = 0, pitch = 1, lookX = 2, lookY = 3, ringTilt = 4, spin = 5, hand = 6, bob = 7
        static let squint = 8, squeeze = 9, minis = 10
    }

    private static func pose(_ changes: KeyValuePairs<Int, Float>) -> SIMD16<Float> {
        var v = SIMD16<Float>()
        v[Key.ringTilt] = 1.2
        v[Key.spin] = 0.6
        v[Key.bob] = 0.025
        for (key, value) in changes { v[key] = value }
        return v
    }

    /// 在听：身子往输入框那边倾、眼睛往下看。在想：侧身、眼睛往上、手托腮。用工具：环转快、眯眼。压缩：被压扁再弹起。
    /// 等子代理：两个迷你方块绕着转。想完：轻轻一跳。
    static func target(_ pose: FigurePose) -> SIMD16<Float> {
        switch pose {
        case .listening: listening
        case .thinking: thinking
        case .tool: tool
        case .compacting: compacting
        case .delegating: delegating
        case .done: done
        }
    }

    private static let listening = pose([Key.yaw: -0.14, Key.pitch: 0.2, Key.lookX: -0.3, Key.lookY: -0.9, Key.spin: 0.4, Key.bob: 0.02])
    private static let thinking = pose([Key.yaw: 0.3, Key.pitch: -0.06, Key.lookX: 0.7, Key.lookY: 0.8, Key.ringTilt: 1.16, Key.spin: 0.8, Key.hand: 1, Key.bob: 0.035])
    private static let tool = pose([Key.yaw: -0.04, Key.pitch: 0.03, Key.lookY: -0.2, Key.ringTilt: 1.24, Key.spin: 4.6, Key.bob: 0.015, Key.squint: 0.55])
    private static let compacting = pose([Key.squeeze: 1, Key.squint: 0.7])
    private static let delegating = pose([Key.ringTilt: 1.16, Key.spin: 0.5, Key.minis: 1])
    private static let done = pose([Key.pitch: -0.06, Key.lookY: 0.3, Key.ringTilt: 1.14, Key.spin: 1.4, Key.bob: 0.02])

    /// 每种姿势一种点缀色：脚下的光、波纹、环都慢慢过渡过去，光看颜色也知道换了。
    static func accent(_ pose: FigurePose) -> KeyPath<FigureColors, SIMD3<Float>> {
        switch pose {
        case .listening: \.r3
        case .thinking, .compacting: \.r2
        case .tool, .done: \.hl
        case .delegating: \.r1
        }
    }

    static func rotX(_ a: Float) -> simd_float3x3 {
        let c = cos(a), s = sin(a)
        return simd_float3x3(columns: ([1, 0, 0], [0, c, s], [0, -s, c]))
    }

    static func rotY(_ a: Float) -> simd_float3x3 {
        let c = cos(a), s = sin(a)
        return simd_float3x3(columns: ([c, 0, -s], [0, 1, 0], [s, 0, c]))
    }

    static func rotZ(_ a: Float) -> simd_float3x3 {
        let c = cos(a), s = sin(a)
        return simd_float3x3(columns: ([c, s, 0], [-s, c, 0], [0, 0, 1]))
    }
}
