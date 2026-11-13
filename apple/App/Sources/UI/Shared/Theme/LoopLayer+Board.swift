import QuartzCore

/// 看板上的两种循环。在跑的卡边上绕着走的光（`LoopLayer.Kind.aura`）：一张绕卡心转的锥形渐变，只从卡边那一圈细线里透出来。
/// 两道光隔半圈，各拖一条渐隐的尾。否决过：几段描边叠出拖尾——段与段的接缝看得见，像一粗一细几截。
extension LoopLayer.Host {
    private static let auraWidth: CGFloat = 1.5
    private static let auraPeriod = 6.0
    /// 半圈里：前面空着，尾巴从这里渐亮到头，头后很快收掉。
    private static let auraStops: [Double] = [0, 0.2, 0.47, 0.5]

    static func makeAura() -> CALayer {
        let layer = CALayer()
        let ring = CAShapeLayer()
        ring.fillColor = nil
        ring.strokeColor = CGColor(gray: 0, alpha: 1)
        ring.lineWidth = auraWidth
        layer.mask = ring
        let light = CAGradientLayer()
        light.type = .conic
        light.startPoint = CGPoint(x: 0.5, y: 0.5)
        light.endPoint = CGPoint(x: 0.5, y: 0)
        light.locations = (auraStops + auraStops.dropFirst().map { $0 + 0.5 }).map(NSNumber.init(value:))
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.byValue = Double.pi * 2
        spin.duration = auraPeriod
        layer.addSublayer(loop(spin, on: light))
        return layer
    }

    static func layoutAura(_ layer: CALayer, in bounds: CGRect, radius: CGFloat, color: CGColor?) {
        layer.frame = bounds
        let edge = CGRect(origin: .zero, size: bounds.size).insetBy(dx: auraWidth / 2, dy: auraWidth / 2)
        // 还没排版时是零宽：圆角矩形的路径不收负的边长
        guard edge.width > 0, edge.height > 0, let ring = layer.mask as? CAShapeLayer, let light = layer.sublayers?.first as? CAGradientLayer else { return }
        let corner = min(radius - auraWidth / 2, edge.width / 2, edge.height / 2)
        ring.frame = layer.bounds
        ring.path = CGPath(roundedRect: edge, cornerWidth: corner, cornerHeight: corner, transform: nil)
        // 转着也盖得住四角：边长取对角线
        let side = hypot(bounds.width, bounds.height)
        light.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        light.position = CGPoint(x: bounds.width / 2, y: bounds.height / 2)
        let clear = color?.copy(alpha: 0)
        light.colors = [clear, clear, color, clear, clear, color, clear].compactMap { $0 }
    }
}
