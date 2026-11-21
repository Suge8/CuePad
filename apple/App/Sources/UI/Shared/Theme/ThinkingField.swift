import SwiftUI

/// 思考强度选中那一档的一块色（模型气泡里的分段，`ModelPick`）：色取色带上这一档左右一段（左冷右暖），上面两团光慢慢绕圈，色就跟着翻动
/// （`LoopLayer` 的 `field`，渲染服务画）。档越高（`energy` 0→1，`ThinkingMeter.energy`）色越往玫红偏、铺得越开、光绕得越快越远越浓，
/// 底下透出的光也越浓；最低档几乎是一块静静的靛。系统不让放动画时（`LoopsPlay`）是同一套色的静止渐变。
/// 否决过：Metal 着色器——要每台编译的机器（本机、云端 CI）另装 Metal 工具链；SwiftUI 的网格渐变按帧走——气泡开着时 App 进程一直占约 5% CPU。
struct ThinkingField: View {
    let energy: Double
    @Environment(\.palette) private var palette
    @LoopsPlay private var loops

    var body: some View {
        let spread = 0.08 + 0.3 * energy
        let tone = { (shift: Double) in palette.thinking(min(max(energy + shift, 0), 1)) }
        let ground = [tone(-spread), tone(0), tone(spread)]
        Group {
            if loops {
                let glows = [tone(spread + 0.1).mix(with: palette.onFill, by: 0.05 + 0.1 * energy * energy), tone(-spread - 0.1)]
                LoopLayer(kind: .field(energy: energy, stops: (ground + glows).map { $0.resolve(in: EnvironmentValues()).cgColor }), color: .clear)
            } else {
                LinearGradient(colors: ground, startPoint: .leading, endPoint: .trailing)
            }
        }
        // 上沿受光、下沿略沉，读成浮起的一块
        .overlay { LinearGradient(colors: [palette.thinkingSheen, palette.thinkingSheen.opacity(0), palette.thinkingShade], startPoint: .top, endPoint: .bottom) }
        .clipShape(.capsule)
        .overlay { Capsule().strokeBorder(LinearGradient(colors: [palette.thinkingRim, palette.thinkingRim.opacity(0)], startPoint: .top, endPoint: .center), lineWidth: ControlMetrics.stroke) }
        .shadow(color: palette.thinkingGlow(energy), radius: 2 + 4 * energy, y: 1)
    }
}
