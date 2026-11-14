import QuartzCore
import simd

nonisolated enum FigurePose: Equatable {
    case listening, thinking, tool, compacting, delegating
    /// 一轮刚停、回复还没到：轻轻一跳等着交棒（`LiveFigure` 的 `lingering`）。
    case done
}

/// Cue 此刻的动作：姿势各项用弹簧追目标（略过冲再回来）、换姿势先蹲后弹，加上波纹、火星这些点缀。
/// 每帧给出一份 `FigureUniforms` 与一串点，画在显卡上（`FigureCanvas`）。一个实例只活一次出场：拼起（或本来就在）→ 在场 → 碎开。
final class FigureMotion {
    private enum Life { case arriving, here, leaving }

    private var pose: FigurePose
    private var life: Life
    private var lifeAt: Double = 0
    private var values: SIMD16<Float>
    private var velocity = SIMD16<Float>()
    private var boing: Float = 0, boingVelocity: Float = 0
    private var accent: SIMD3<Float>?
    private var ringAngle: Float = 0, miniAngle: Float = 0
    private var stateAt: Double = 0, pulseAt: Double = -9, last: Double = 0
    private var particles: [Particle] = []
    private var sprites: [FigureSprite] = []
    private var dark = true

    static let leaveDuration = 0.6
    static let arriveDuration = 1.5

    init(pose: FigurePose, arrives: Bool, at t: Double) {
        self.pose = pose
        values = Self.target(pose)
        life = arrives ? .arriving : .here
        lifeAt = t
        last = t
    }

    /// 换姿势：迸几颗火星、脚下一圈波纹、先往下一蹲。
    func set(_ next: FigurePose, at t: Double) {
        guard next != pose else { return }
        pose = next
        stateAt = t
        pulseAt = t
        boingVelocity = 2.4
        burst(next == .tool ? 10 : 7, warm: next == .tool)
    }

    func leave(at t: Double) {
        guard life != .leaving else { return }
        life = .leaving
        lifeAt = t
    }

    /// 停在一帧（减弱动态效果、省电、看不见时）：各项直接到位，不留飞行中的格子。
    func settle() {
        values = Self.target(pose)
        velocity = .init()
        boing = 0
        boingVelocity = 0
        if life == .arriving { life = .here }
        accent = nil
        particles = []
    }

    /// 还在过渡里（拼起、碎开、刚换姿势、环转快了甩火星）就要 60 帧，平时 30 帧就够顺。
    func busy(at t: Double) -> Bool { life != .here || t - stateAt < 1.5 || pose == .tool }

    /// 返回这一帧的参数、点缀，以及前多少个点缀画在格子下面（脚下的光）。
    func step(at t: Double, dark: Bool) -> (FigureUniforms, [FigureSprite], Int) {
        let dt = Float(min(max(t - last, 0.001), 0.07))
        last = t
        self.dark = dark
        let colors = FigureColors.of(dark: dark)
        let accentTarget = colors[keyPath: Self.accent(pose)]
        accent = accent.map { mix($0, accentTarget, t: 1 - exp(-dt * 4)) } ?? accentTarget
        var target = Self.target(pose)
        miniAngle += 1.5 * dt * values[Key.minis]
        if values[Key.minis] > 0.3 {   // 迷你方块绕着转时眼睛跟着前面那个看
            let front = sin(miniAngle) < 0 ? miniAngle : miniAngle + .pi
            target[Key.lookX] = cos(front) * 0.9
            target[Key.lookY] = 0.1
        }
        let (stiffness, damping): (Float, Float) = pose == .done ? (170, 17) : (95, 12.5)
        velocity += ((target - values) * stiffness - velocity * damping) * dt
        values += velocity * dt
        boingVelocity += (-boing * 190 - boingVelocity * 9) * dt
        boing += boingVelocity * dt
        ringAngle += values[Key.spin] * dt
        if life == .arriving, t - lifeAt > Self.arriveDuration { life = .here }

        let time = Float(t), since = Float(t - stateAt)
        var hop: Float = 0, squash: Float = 0
        if pose == .done {
            let u = since / 0.7
            if u < 1 { hop = sin(u * .pi) * 0.24; squash = u > 0.82 ? (1 - u) * 2.4 : u < 0.14 ? (0.14 - u) * 2 : 0 }
        }
        squash += max(0, values[Key.squeeze]) * pow(0.5 - 0.5 * cos(time * 2.6), 2) * 0.3 + boing
        let lift = sin(time * 1.6) * values[Key.bob] + hop
        let sway = sin(time * 0.8) * 0.05
        let blink: Float = fmod(time, 3.7) > 3.58 || (pose == .thinking && fmod(time, 5.3) > 5.15) ? 0.12 : 1
        let pulse = exp(-Float(t - pulseAt) * 3.2)
        let flash = pose == .done ? max(0, 1 - since * 1.4) : 0
        let lifeCode: Float = switch life { case .here: 0; case .arriving: 1; case .leaving: 2 }

        var u = FigureUniforms()
        u.body = Self.rotY(-values[Key.yaw] - sway) * Self.rotX(-values[Key.pitch])
        u.ring = Self.rotX(-values[Key.ringTilt]) * Self.rotZ(-0.05)
        u.a = [lift, Self.off, Self.floor, squash]
        u.b = [ringAngle, blink, values[Key.squint], time]
        u.c = [values[Key.lookX], values[Key.lookY], values[Key.hand], values[Key.minis]]
        u.d = [miniAngle, pulse, flash, dark ? 0 : 1]
        u.e = [Float(FigureLayout.tiles), FigureLayout.span, lifeCode, Float(t - lifeAt)]
        u.f = [Float(FigureLayout.canvas.width), Float(FigureLayout.canvas.height), Float(FigureLayout.tile), 0]
        u.g = [Float(FigureLayout.origin.x), Float(FigureLayout.origin.y), 0, 0]
        colors.fill(&u, accent: accent ?? accentTarget)

        let under = decorate(t: t, dt: dt, colors: colors, lift: lift, hop: hop)
        return (u, sprites, under)
    }

    /// 身子中心比画布中心低多少、脚底在哪（世界坐标）。
    private static let off: Float = 0.08, floor: Float = -0.98
}

// MARK: - 点缀：脚下的光、波纹、火星

extension FigureMotion {
    private struct Particle {
        var x, y, vx, vy, gravity, life, max: Float
        var color: SIMD3<Float>
        var grows = false
    }

    private static let ember: SIMD3<Float> = [1, 0.86, 0.63]

    private func point(_ bx: Float, _ by: Float, lift: Float) -> SIMD2<Float> {
        let s = Float(FigureLayout.size), span = FigureLayout.span
        return [Float(FigureLayout.origin.x) + (bx / span + 0.5) * s, Float(FigureLayout.origin.y) + (0.5 - (by - Self.off + lift + 0.06) / span) * s]
    }

    private func burst(_ count: Int, warm: Bool) {
        let colors = FigureColors.of(dark: dark), center = point(0, -0.2, lift: 0), s = Float(FigureLayout.size)
        for i in 0..<count {
            let a = Float.random(in: 0..<(2 * .pi)), speed = Float.random(in: 30..<70)
            let color = warm ? Self.ember : i.isMultiple(of: 2) ? colors[keyPath: Self.accent(pose)] : colors.hl
            particles.append(Particle(x: center.x + cos(a) * s * 0.4, y: center.y + sin(a) * s * 0.07, vx: cos(a) * speed, vy: sin(a) * speed * 0.5 - 18,
                                      gravity: 50, life: 0.7, max: 0.7, color: color))
        }
    }

    /// 把这一帧的点写进 `sprites`（沿用上一帧的存储），返回前多少个画在格子下面。
    private func decorate(t: Double, dt: Float, colors: FigureColors, lift: Float, hop: Float) -> Int {
        sprites.removeAll(keepingCapacity: true)
        let n = FigureLayout.tiles, tile = Float(FigureLayout.tile), s = Float(FigureLayout.size), accent = accent ?? colors.hl
        let ox = Float(FigureLayout.origin.x), oy = Float(FigureLayout.origin.y), span = FigureLayout.span
        let age = Float(t - lifeAt)
        let presence: Float = switch life {
        case .here: 1
        case .arriving: min(1, age / 0.9)
        case .leaving: max(0, 1 - age / 0.5)
        }
        // 脚下的光：跳起来时变小变淡
        let poolAlpha = (1 - hop * 3) * (dark ? 0.55 : 0.32) * presence
        let row = (0.5 - (Self.floor - Self.off + 0.06) / span) * Float(n) - 0.5
        if poolAlpha > 0 {
            for r in Int(row.rounded(.down)) - 1...Int(row.rounded(.up)) + 2 {
                for c in 0..<n {
                    let dx = (Float(c) + 0.5 - Float(n) / 2) / (Float(n) * 0.27), dy = (Float(r) + 0.5 - row - 0.6) / 1.7, d = dx * dx + dy * dy
                    guard d < 1 else { continue }
                    sprites.append(FigureSprite(rect: [ox + (Float(c) + 0.5) * tile, oy + (Float(r) + 0.5) * tile, tile, (1 - d) * poolAlpha],
                                                col: SIMD4(mix(colors.pool, accent, t: 0.45), dark ? (1 - d) * 0.6 : 0)))
                }
            }
        }
        let under = sprites.count
        // 换姿势时脚下扩出一圈像素波纹，吸在格子上
        let wave = Float(t - pulseAt) / 0.75
        if wave < 1, life != .leaving {
            let e = 1 - pow(1 - wave, 3), rx = s * (0.26 + 0.3 * e), ry = rx * 0.2
            let cx = ox + s / 2, cy = oy + (row + 0.6) * tile, count = Int((2 * .pi * rx / (tile * 1.15)).rounded())
            for i in 0..<count {
                let a = Float(i) / Float(count) * 2 * .pi
                let x = ((cx + cos(a) * rx) / tile).rounded() * tile, y = ((cy + sin(a) * ry) / tile).rounded() * tile
                let alpha = pow(1 - wave, 1.4) * (0.45 + 0.55 * max(0, sin(a)))
                sprites.append(FigureSprite(rect: [x, y, tile, alpha], col: SIMD4(accent, dark ? 1.2 : 0)))
            }
        }
        emit(dt: dt, colors: colors, lift: lift)
        particles.removeAll { $0.life <= 0 }
        for i in particles.indices {
            particles[i].life -= dt
            particles[i].x += particles[i].vx * dt
            particles[i].y += particles[i].vy * dt
            particles[i].vy += particles[i].gravity * dt
            let p = particles[i], f = max(0, p.life / p.max), size = tile * (p.grows ? 0.7 + 0.6 * (1 - f) : 1)
            sprites.append(FigureSprite(rect: [p.x, p.y, size, min(1, f * 1.6)], col: SIMD4(p.color, dark ? f * 1.3 : 0)))
        }
        return under
    }

    private func emit(dt: Float, colors: FigureColors, lift: Float) {
        guard life == .here else { return }
        let s = Float(FigureLayout.size), roll = Float.random(in: 0..<1)
        switch pose {
        case .listening where roll < 5 * dt:   // 你的话从输入框那边飘上来
            particles.append(Particle(x: Float(FigureLayout.origin.x) + s * Float.random(in: 0.25..<0.75), y: Float(FigureLayout.canvas.height),
                                      vx: Float.random(in: -3..<3), vy: -36, gravity: 0, life: 1.5, max: 1.5, color: colors.r3))
        case .thinking where roll < 1.6 * dt:   // 头顶冒念头
            let p = point(0.4, 0.78, lift: lift)
            particles.append(Particle(x: p.x, y: p.y, vx: Float.random(in: 5..<10), vy: -14, gravity: 0, life: 1.8, max: 1.8, color: colors.r2, grows: true))
        case .tool where roll < 16 * dt:   // 环转快了甩出火星
            let a = ringAngle + Float.random(in: 0..<0.6), c = point(0, -0.2, lift: lift)
            particles.append(Particle(x: c.x + cos(a) * s * 0.4, y: c.y + sin(a) * s * 0.07, vx: -sin(a) * 64, vy: cos(a) * 12 - 22, gravity: 70, life: 0.6, max: 0.6,
                                      color: [Self.ember, colors.r3, [1, 1, 1]].randomElement()!))
        default: break
        }
    }
}
