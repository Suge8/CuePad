import SwiftUI

/// 只在给定的时刻重画的内容：此刻画一次，睡到 `next` 给的下一个时刻（等到那一刻是业务语义：`task(id:)` 睡到那一刻，不周期刷新）再画，
/// 画完再等下一个；输入变了照常重画、重新算下一个时刻。额度的重置（`QuotaMoments`）与计时文字（`LiveText`）都经它。
/// 否决的方案：`TimelineView(.explicit(时刻))`——iOS 27 模拟器实测只在头一次画时调用内容（给的日期是时刻表里第一个时刻，
/// 还没到就按已到画），到了那一刻并不重画。
struct Moments<Content: View>: View {
    /// 此刻之后下一次要重画的时刻，必须严格晚于给它的此刻（不晚于的话睡醒时它还是同一个时刻，任务不再重起，内容停住）。
    let next: (Date) -> Date?
    @ViewBuilder let content: (Date) -> Content
    /// 睡到的那个时刻：读数不早于它（醒来与重画之间读 `.now` 不会还差一丝没到）
    @State private var reached = Date.distantPast

    var body: some View {
        let now = max(Date.now, reached)
        let next = next(now)
        content(now)
            .task(id: next) {
                guard let next, (try? await Task.sleep(for: .seconds(next.timeIntervalSinceNow))) != nil else { return }
                reached = next
            }
    }
}

/// 按时刻换字的文字（会话计时、额度倒计时、"x 分钟前"）：字是 `style` 此刻的格式，只在它说会变的那一刻（`discreteInput(after:)`）重画，
/// 画出来是一段普通的字。`text` 把这段字排进一句（默认就是它本身）。
/// 不用系统时间文本 `Text(.currentDate, format:)`：Mac 上窗口每画一帧（任何一处在滚、在动）它都重新格式化、重画一遍，
/// 挂着的页里看不见的也算——Agent 页挂着时 Cue 页滚轮滚动的指令数是 5.8G 对 1.1G、超 16ms 的圈 35 对 1。
struct LiveText<Style: DiscreteFormatStyle>: View where Style.FormatInput == Date, Style.FormatOutput == String {
    let style: Style
    var text: (String) -> Text = { Text($0) }

    var body: some View {
        Moments(next: style.discreteInput(after:)) { now in text(style.format(now)) }
    }
}
