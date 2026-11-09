#if DEBUG
import QuartzCore

/// -CuePadVoiceLightProbe YES：直接驱动已挂载声纹的等待/退出/90ms 重入，只验图层连续性，不代表通话业务路径。
enum DebugVoiceLightProbe {
    private static let requested = DebugScene.args.voiceOpts.lightProbe
    private static var started = false

    static func start(_ layer: VoiceRibbonLayer) {
        guard requested, !started else { return }
        started = true
        Task {
            await DebugScene.running("声纹亮度重入") {
                try await Task.sleep(for: .seconds(2))
                let color = (layer.sublayers?.first as? CAShapeLayer)?.fillColor
                for index in 0..<8 {
                    let activity: CueVoiceActivity = index.isMultiple(of: 2) ? .processing : .listening
                    let before = opacities(layer)
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    layer.show(VoiceRibbon(activity: activity, muted: false, samples: [], playing: true, reduced: false),
                               in: layer.frame, color: color)
                    CATransaction.commit()
                    var previous = before
                    var steps: [Float] = []
                    for _ in 0..<(index.isMultiple(of: 2) ? 10 : 4) {
                        try await Task.sleep(for: .milliseconds(20))
                        let after = opacities(layer)
                        steps.append(zip(previous, after).map { abs($0 - $1) }.max() ?? 0)
                        previous = after
                    }
                    FileHandle.standardError.write(Data("voice-light \(index) \(activity) maxStep=\(steps.max() ?? 0) steps=\(steps)\n".utf8))
                    try await Task.sleep(for: index.isMultiple(of: 2) ? .milliseconds(420) : .milliseconds(10))
                }
            }
        }
    }

    private static func opacities(_ layer: CALayer) -> [Float] {
        (layer.sublayers ?? []).map { $0.presentation()?.opacity ?? $0.opacity }
    }
}
#endif
