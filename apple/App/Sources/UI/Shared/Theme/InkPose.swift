import QuartzCore

/// 长时间挂着的几种状态（等你确认、该你了、歇着、待回复，可能挂几小时）隔十几秒才动一下：由这里按全局时钟敲，同屏同一种一起动，
/// 每次只给各个标挂一段放完就摘的动画。否决过：在层上挂一条长周期、大半时间停着的循环——动画挂着时渲染服务照样逐帧求值（推断，没实测），同屏几十个长挂的标会让它一直合成。
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

    /// 周期各不相同、互不成倍：同屏几种状态不一起动。
    private static func period(_ life: InkPose.Life) -> Double? {
        switch life {
        case .breathe: 9
        case .blink: 11
        case .nod: 13
        case .hop: 15
        default: nil
        }
    }
}

/// 状态标那根线此刻的样子（`shape`）与它常驻的动作（`life`）。
nonisolated struct InkPose: Hashable, Sendable {
    var shape: Shape
    var life: Life

    enum Shape: Hashable, Sendable {
        case heartbeat, ring, question, bigDot, relay, cursor, ellipsis, broken, period
        /// 线收进中心：上面叠着别的标（铃铛、徽、纸飞机）。
        case hidden

        static let most = 3

        var strands: [InkStrand] {
            switch self {
            case .heartbeat: InkStateGeometry.heartbeat
            case .ring: InkStateGeometry.ring
            case .question: InkStateGeometry.question
            case .bigDot: InkStateGeometry.bigDot
            case .relay: InkStateGeometry.relay
            case .cursor: InkStateGeometry.cursor
            case .ellipsis: InkStateGeometry.ellipsis
            case .broken: InkStateGeometry.broken
            case .period: InkStateGeometry.period
            case .hidden: []
            }
        }
    }

    enum Life: Hashable, Sendable {
        /// 心跳沿线走（在想、在说）
        case pulse
        /// 一截弧绕圈（用工具）
        case orbit
        /// 整根横着挤（压缩上下文）
        case squeeze
        /// 小点来回、大点接住（等子代理）
        case relay
        /// 隔十几秒歪一下头（等你确认）
        case nod
        /// 隔十几秒光标眨两下（该你了）
        case blink
        /// 隔十几秒三颗点挨个跳（歇着）
        case hop
        /// 隔几秒鼓一下（待回复）
        case breathe
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
