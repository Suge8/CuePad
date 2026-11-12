import QuartzCore

/// 在跑的卡边上绕着走的一道光（`LoopLayer.Kind.aura`）：几层同一个头，一层比一层短而实，叠出拖尾。
/// 路径绕卡边两圈，头尾各在 0…1 里走半程：走完一圈正好接上，不用按周长算虚线。
extension LoopLayer.Host {
    private static let auraWidth: CGFloat = 1.5
    /// 每层拖多长（占一圈的几分之几）、多实。
    private static let auraTails: [(length: Double, alpha: CGFloat)] = [(0.32, 0.16), (0.18, 0.4), (0.07, 1)]
    private static let auraPeriod = 4.2

    static func makeAura() -> CALayer {
        let layer = CALayer()
        for tail in auraTails {
            let shape = CAShapeLayer()
            shape.fillColor = nil
            shape.lineCap = .round
            shape.lineWidth = auraWidth
            let head = CABasicAnimation(keyPath: "strokeEnd")
            head.fromValue = 0.5
            head.toValue = 1
            let end = CABasicAnimation(keyPath: "strokeStart")
            end.fromValue = 0.5 - tail.length / 2
            end.toValue = 1 - tail.length / 2
            let lap = CAAnimationGroup()
            lap.animations = [head, end]
            lap.duration = auraPeriod
            layer.addSublayer(loop(lap, on: shape))
        }
        return layer
    }

    static func layoutAura(_ layer: CALayer, in bounds: CGRect, radius: CGFloat, color: CGColor?) {
        layer.frame = bounds
        let edge = CGRect(origin: .zero, size: bounds.size).insetBy(dx: auraWidth / 2, dy: auraWidth / 2)
        // 还没排版时是零宽：圆角矩形的路径不收负的边长
        guard edge.width > 0, edge.height > 0 else { return }
        let corner = min(radius - auraWidth / 2, edge.width / 2, edge.height / 2)
        let path = CGMutablePath()
        for _ in 0..<2 { path.addRoundedRect(in: edge, cornerWidth: corner, cornerHeight: corner) }
        for (shape, tail) in zip((layer.sublayers ?? []).compactMap { $0 as? CAShapeLayer }, auraTails) {
            shape.frame = layer.bounds
            shape.path = path
            shape.strokeColor = color?.copy(alpha: (color?.alpha ?? 1) * tail.alpha)
        }
    }
}
