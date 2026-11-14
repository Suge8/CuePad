import QuartzCore

/// 不在干活、又要你看见的几种状态（等你确认、新回复、被打断、已结束，可能挂几小时、一列几十行）隔几秒到十几秒动一下：由这里按全局时钟敲，
/// 同屏同一种一起动，每次只给各个标挂一段放完就摘的动画。否决过：在层上挂一条长周期、大半时间停着的循环——动画挂着时渲染服务照样逐帧求值（推断，没实测），同屏几十个长挂的标会让它一直合成。
@MainActor final class InkBeat {
    static let shared = InkBeat()
    private var hosts: [InkPose.Life: [ObjectIdentifier: Weak]] = [:]
    private var clocks: [InkPose.Life: Task<Void, Never>] = [:]

    private struct Weak {
        weak var host: StateInk.Host?
    }

    func join(_ host: StateInk.Host, _ life: InkPose.Life) {
        hosts[life, default: [:]][ObjectIdentifier(host)] = Weak(host: host)
        guard clocks[life] == nil, let period = Self.period(life) else { return }
        clocks[life] = Task { [weak self] in
            while let self {
                // 对齐到周期的整数倍：各个标与重建出来的标同相
                let wait = period - CACurrentMediaTime().truncatingRemainder(dividingBy: period)
                guard (try? await Task.sleep(for: .seconds(wait))) != nil else { return }
                let live = (self.hosts[life] ?? [:]).compactMapValues { $0.host == nil ? nil : $0 }
                self.hosts[life] = live
                if live.isEmpty {
                    self.clocks[life] = nil
                    return
                }
                for entry in live.values { entry.host?.beat(life) }
            }
        }
    }

    func leave(_ host: StateInk.Host) {
        for life in hosts.keys { hosts[life]?[ObjectIdentifier(host)] = nil }
    }

    /// 要你的（确认、新回复）几秒一下；停下的十几秒一下。周期互不成倍：同屏几种状态不一起动。
    private static func period(_ life: InkPose.Life) -> Double? {
        switch life {
        case .nod: 4.2
        case .flap: 5
        case .jitter: 17
        case .rock: 19
        default: nil
        }
    }
}

/// 状态标那根线此刻的样子（`shape`）与它常驻的动作（`life`）。
nonisolated struct InkPose: Hashable, Sendable {
    var shape: Shape
    var life: Life

    enum Shape: Hashable, Sendable {
        case heartbeat, wrench, spring, ask, mail, bot, plug, moon
        /// 线收进中心：上面叠着别的标（出错、没能送达、纸飞机），或者什么都不画（空闲）。
        case hidden

        static let most = 6

        var strands: [InkStrand] {
            switch self {
            case .heartbeat: InkStateGeometry.heartbeat
            case .wrench: InkStateGeometry.wrench
            case .spring: InkStateGeometry.spring
            case .ask: InkStateGeometry.ask
            case .mail: InkStateGeometry.mail
            case .bot: InkStateGeometry.bot
            case .plug: InkStateGeometry.plug
            case .moon: InkStateGeometry.moon
            case .hidden: []
            }
        }
    }

    /// 在干活的四种一直动；其余由 `InkBeat` 隔几秒敲一下。
    enum Life: Hashable, Sendable {
        /// 心跳沿线走（在想、在说）
        case pulse
        /// 扳手来回拧（用工具）
        case twist
        /// 两块板压弹簧（压缩上下文）
        case press
        /// 小机器人飘着、隔一会儿眨眼（等子代理）
        case bot
        /// 歪一下头（等你确认）
        case nod
        /// 信封盖掀一下（新回复）
        case flap
        /// 拔开的插头两半往外一弹（被打断）
        case jitter
        /// 月牙晃一下（已结束）
        case rock
        case still
    }

    static let hidden = InkPose(shape: .hidden, life: .still)

    static func points(_ strand: InkStrand) -> [CGPoint] {
        stride(from: 0, to: strand.xy.count, by: 2).map { CGPoint(x: strand.xy[$0], y: strand.xy[$0 + 1]) }
    }
}

/// 一根线：`xy` 是 x、y 交替的点（格，24 格见方、原点在中心、y 朝下），每根同样点数（`InkStateGeometry.strandPoints`）；`width` 是线宽（格）。
nonisolated struct InkStrand: Sendable {
    let width: CGFloat
    let xy: [CGFloat]
}
