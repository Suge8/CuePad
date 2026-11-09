import SwiftUI

/// 主题文件唯一的交付接口。坐标 220×100，左上为原点，x 向右、y 向下；路径可用小数与贝塞尔曲线。
/// pigments 是主题私有的 0xRRGGBB 装饰色盘（4–6 色），第 0 色铺底，不引用语义 Palette。
/// layers 从后向前叠放；ink 是色盘索引，coverage 为 0…1 的 Bayer 覆盖率，1 保留实心剪影。
/// 所有路径按 even-odd 填充，子路径可挖孔。主题只返回此值，不缓存、不注册、不自行采样。
nonisolated struct ProjectIllustration {
    let pigments: [UInt32]
    let layers: [Layer]

    struct Layer {
        let path: Path
        let ink: Int
        var coverage: Double = 1
    }
}
