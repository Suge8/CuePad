#if os(iOS)
import CueStore
import SwiftUI

/// 窄屏进展页的竖版看板：Mac 看板转 90°——待办、推进中、等你、已完成四行竖着排，每行一条（`BoardRowLane`），
/// 行头竖在左端，卡在行里横着排、放不下就在这一行里横划。iPhone 17 上四行一屏放下；矮屏与大字号放不下时整页竖着滚。
/// 横拖的归属（`PagerArbiter`）：整页认领横拖（`claimsHorizontalDrags`）——不贴边的横拖都是行的，滑到头只回弹；贴屏幕左右边起手才切页。
/// 在等你那一行写回答时，别的行退开（淡出、不接点按，点一下收起键盘）：整页为键盘上推时，顶上浮着的搜索、项目与"+"下面只剩页底色，不压着别的卡。
/// 点"+"添加任务时整页先回到待办那一行。
struct PhoneBoard: View {
    let board: TaskBoard
    @Binding var adding: Bool
    let newTaskProject: UUID?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var replying = false

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: Self.gap) {
                    ForEach(TaskBoard.Column.allCases) { column in
                        let away = replying && column != .waiting
                        BoardColumn(column: column, board: board, adding: $adding, newTaskProject: newTaskProject, row: true)
                            .opacity(away ? 0 : 1)
                            .overlay { if away { Color.clear.contentShape(.rect).onTapGesture(perform: endEditing) } }
                            .id(column)
                    }
                }
                .claimsHorizontalDrags()
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollIndicators(.never)
            // 一滚就收键盘（等你行的回答框）
            .scrollDismissesKeyboard(.immediately)
            .onPreferenceChange(BoardReplying.self) { writing in
                withAnimation(HandOff.quick) { replying = writing }
            }
            .onChange(of: adding) {
                if adding { withAnimation(Motion.spatial(Motion.snappy, reduceMotion: reduceMotion)) { proxy.scrollTo(TaskBoard.Column.todo, anchor: .top) } }
            }
        }
    }

    private func endEditing() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    /// 行与行之间：行没有底，靠这段留白分开。
    static let gap: CGFloat = 20
}
#endif
