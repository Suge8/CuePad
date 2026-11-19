#if os(iOS)
import CueStore
import SwiftUI

/// 个数与"更早"那一页读同一个查询（`SessionListData.earlier`），两边才对得上。
struct EarlierTile: View {
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @State private var total: Int?

    var body: some View {
        Group {
            if let total, total > 0 {
                // 一颗玻璃圆钮，同右边回复框那一排的圆钮：写着"历史 10"的一张小纸像又一个会话格
                Button("历史", icon: .history) { workspace.push(.earlier) }
                    .glassCircle()
                    .accessibilityValue(Text(total, format: .number))
            } else {
                // 读库的订阅要挂在一个真的视图上：订阅等视图出现才启动，什么都不排它就不启动，页面永远空白
                Color.clear.frame(height: 0)
            }
        }
        .padding(.horizontal, SessionRail.phoneInset)
        .frame(width: SessionRail.Form.phone.width)
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        .observing(services.store, id: services.speech, into: $total, onError: workspace.fail) { [moment = services.speech] store in
            try SessionListData.earlier(SessionQuery(limit: 1), at: moment, from: store).total
        }
    }
}
#endif
