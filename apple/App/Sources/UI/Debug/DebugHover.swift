#if DEBUG && os(macOS)
import Foundation

extension DebugScene {
    static var hoverPoints: [CGPoint] {
        (args.driveOpts.hover ?? "").split(separator: ";").compactMap { spot in
            let parts = spot.split(separator: ",").compactMap { Double($0) }
            return parts.count == 2 ? CGPoint(x: parts[0], y: parts[1]) : nil
        }
    }
}
#endif
