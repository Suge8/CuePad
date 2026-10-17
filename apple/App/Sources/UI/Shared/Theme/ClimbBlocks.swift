// 由 design/tools/cue-symbols.py 生成，改形状改那里（符号 cue.climb 出自同一份）。
import CoreGraphics

/// "话在路上"三块实心 V 的顶点：22 × 22、y 朝下的格子，从下往上排（`LoopLayer.climb` 画它）。
enum ClimbBlocks {
    static let blocks: [[CGPoint]] = [
        [CGPoint(x: 11, y: 12.1), CGPoint(x: 17.8, y: 17.2), CGPoint(x: 17.8, y: 20.4), CGPoint(x: 11, y: 15.3), CGPoint(x: 4.2, y: 20.4), CGPoint(x: 4.2, y: 17.2)],
        [CGPoint(x: 11, y: 6.9), CGPoint(x: 17.8, y: 12), CGPoint(x: 17.8, y: 15.2), CGPoint(x: 11, y: 10.1), CGPoint(x: 4.2, y: 15.2), CGPoint(x: 4.2, y: 12)],
        [CGPoint(x: 11, y: 1.7), CGPoint(x: 17.8, y: 6.8), CGPoint(x: 17.8, y: 10), CGPoint(x: 11, y: 4.9), CGPoint(x: 4.2, y: 10), CGPoint(x: 4.2, y: 6.8)],
    ]
}
