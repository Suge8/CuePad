#if os(macOS)
import SwiftUI

/// 采样到达才更新路径；插值交给渲染服务，主线程没有帧循环。新路径从 presentation layer 接续，插话不排队。
/// 静音与断线只收回一次，随后静止；减弱动态、不可见与省电直接落定。等待的唯一循环由上层 LoopLayer 承担。
struct CueVoiceField: NSViewRepresentable {
    let form: CueVoiceRibbon.Form
    let samples: [CGFloat]
    let moving: Bool
    let colors: [Color]

    func makeNSView(context: Context) -> Host { Host() }
    func updateNSView(_ host: Host, context: Context) {
        host.show(form: form, samples: samples, moving: moving, colors: colors.map { $0.resolve(in: context.environment).cgColor })
    }

    final class Host: NSView {
        private let lines = (0..<CueVoiceRibbon.strands).map { _ in CAShapeLayer() }
        private let silk = CAGradientLayer()
        private let contours = CALayer()
        private var drawing: Drawing?
        private var drawnBounds = CGRect.zero

        private struct Drawing: Equatable {
            let form: CueVoiceRibbon.Form
            let samples: [CGFloat]
            let moving: Bool
            let colors: [CGColor]
        }

        init() {
            super.init(frame: .zero)
            wantsLayer = true
            silk.startPoint = CGPoint(x: 0.15, y: 0)
            silk.endPoint = CGPoint(x: 0.85, y: 1)
            silk.mask = contours
            layer?.addSublayer(silk)
            for (index, line) in lines.enumerated() {
                line.fillColor = nil
                line.lineWidth = index == lines.count - 1 ? 1.4 : 0.75
                line.strokeColor = CGColor(gray: 1, alpha: 1)
                contours.addSublayer(line)
            }
            setAccessibilityElement(false)
        }
        required init?(coder: NSCoder) { fatalError() }
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func layout() {
            super.layout()
            if bounds != drawnBounds, let drawing { draw(drawing, transition: false) }
        }

        func show(form: CueVoiceRibbon.Form, samples: [CGFloat], moving: Bool, colors: [CGColor]) {
            let next = Drawing(form: form, samples: samples, moving: moving, colors: colors)
            guard next != drawing || bounds != drawnBounds else { return }
            let transition = drawing?.form != form
            drawing = next
            draw(next, transition: transition)
        }

        private func draw(_ drawing: Drawing, transition: Bool) {
            guard bounds.width > 0 else { return }
            let resized = drawnBounds != bounds
            drawnBounds = bounds
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            silk.frame = bounds
            contours.frame = bounds
            silk.colors = drawing.colors
            for (index, line) in lines.enumerated() {
                let path = CueVoiceRibbon.path(form: drawing.form, samples: drawing.samples, strand: index, in: bounds)
                let from = line.presentation()?.path ?? line.path
                line.frame = bounds
                line.path = path
                line.removeAllAnimations()
                if drawing.moving, !resized, let from {
                    let morph = CABasicAnimation(keyPath: "path")
                    morph.fromValue = from
                    morph.toValue = path
                    morph.duration = transition ? Motion.Glide.duration : Motion.Fade.duration
                    morph.timingFunction = Motion.Fade.timing
                    line.add(morph, forKey: "voice")
                }
            }
            CATransaction.commit()
        }
    }
}
#endif
