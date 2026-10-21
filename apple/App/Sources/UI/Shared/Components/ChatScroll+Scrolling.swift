import Synchronization
import SwiftUI

extension ChatScroll {
    /// 可见区变矮、内容没变时滑上去（键盘升起）。只在手机上：Mac 上可见区变矮是拖窗口，要跟手、当下补。
    #if os(iOS)
    static var followsKeyboard: Bool { true }
    #else
    static var followsKeyboard: Bool { false }
    #endif

    func margin(_ width: CGFloat) -> CGFloat { ChatLayout.margin(width, readingWidth: readingWidth, inset: inset) }

    /// 内容变高矮时底锚：贴着最新、用户没在滚、没在等和 iCloud 对完（或自己要回到最新）。滚走了、在对的期间新的长在下面，正在读的不动。
    var pinned: Bool { follow.wrappedValue.atNewest && !follow.wrappedValue.scrolling && (!holding || unheld) && !deferred }

    /// 内容底下让出浮着的回复框（Mac，`chatBottomInset`）的留白。发出时回复框当下收起，发出的话要等写进库才到：那之前留白不跟着变矮，
    /// 那句到了（内容真的长高）再收，与它出现在同一帧；跟着变矮的话贴着最新的整段对话先被拉下来一两帧，再一下顶上去。
    /// 看内容长高，不看 `followKey`：它还算着别的（之前那句的送达情况），可能比那句先变。
    /// 排在内容里而不是内容边距：Mac 的滚动区改边距要晚一次排版才生效，那时它自己把偏移一下挪到底，就滑不起来了。
    /// 键盘是安全区，不在这里：发出时键盘随即收起，对话跟着键盘的动画走，不留。
    var bottomPadding: CGFloat { max(bottomInset, held ?? 0) }

    /// 最近一次读数（偏移、最新处）与上一次交给读数 action 的读数。读数闭包不一定在主线程，所以带锁；
    /// 它不是状态，写它不触发任何更新。
    final class ScrollOffset: Sendable {
        private struct Values {
            /// 可见区顶边在内容里的位置。内容在下面或上面变高时滚动区不挪偏移，它就是变高之前的位置（往上排开一段时据它补高度差，`ChatFollow.prepending`）。
            var read: CGFloat = 0
            /// 最新处的偏移（`scrollTo(y:)` 的 y）。
            var end: CGFloat = 0
            /// 上一次交给 action 的读数。不用 action 给的旧值：那是上一次求值，中间几次变化（打开时排开更早的一段）可能求了值却没调 action，
            /// 拿它比内容变没变高会漏掉。
            var delivered: Reading?
            /// 补滚换着用的两种写法（`scroll(to:)`）：这一次用不用"滚到那一点"。
            var byPoint = false
        }

        private let values = Mutex(Values())

        func set(read: CGFloat, end: CGFloat) {
            values.withLock {
                $0.read = read
                $0.end = end
            }
        }

        var read: CGFloat { values.withLock { $0.read } }
        var end: CGFloat { values.withLock { $0.end } }

        /// 换上这次交给 action 的读数，返回上一次交过去的。
        func deliver(_ reading: Reading) -> Reading? {
            values.withLock { values in
                defer { values.delivered = reading }
                return values.delivered
            }
        }

        func flip() -> Bool { values.withLock { $0.byPoint.toggle(); return $0.byPoint } }
    }

    /// 滚动区的读数：只留下会让状态改变的几条越线（离最新处近不近、超没超一屏、离最早处近不近）与内容高、边距，每帧都变的偏移不进来。
    /// `action` 只在读数变了才跑，滚动时每帧不碰页面的状态。
    struct Reading: Equatable {
        var nearNewest: Bool
        var beyondScreen: Bool
        var nearOldest: Bool
        /// 内容的高，不含让出回复框的那段（它变高变矮是回复框的事，不滑）。
        var height: CGFloat
        /// 让出浮着的那一块的那段（`bottomPadding`）。
        var floating: CGFloat
        /// 滚到最新处时可见区顶边在内容里的位置（`scrollTo(y:)` 的 y，不含内容边距）。
        var end: CGFloat
        /// 顶部的内容边距：它一变系统就把偏移放回顶上，读数要跟着变，才会再补滚一次。
        var inset: CGFloat
        /// 可见区的高（扣掉上下边距）：手机上它从底下变矮是键盘升起来了。
        var container: CGFloat
    }

    /// 对完一次（`holding` 期间长在下面的）、键盘升起时，整段滑到最新处（减弱动态效果时直接到）；贴着最新时来的新内容不经这里，底锚当帧就排好（`pinned`）。用定长的 `Motion.move`，不用弹簧：弹簧最后那段一两像素的尾巴
    /// 要再画两百多毫秒，正好压在发出的话送达、状态变了的那几次更新上，那几帧本来不用画，一画就掉帧。
    /// 等这一帧提交了再滑：动画从这一帧起算的话，第一帧画出来时已经走了一大截，看着是一跳。
    /// 滑到的是那时的最新处（留白收起之后）；等的这一帧里用户开始滚了就不滑了。
    func slide() {
        sliding?.cancel()
        sliding = Task {
            await NextFrame.wait()
            guard !Task.isCancelled else { return }
            sliding = nil
            guard follow.wrappedValue.atNewest, !follow.wrappedValue.scrolling else { return }
            withAnimation(Motion.spatial(Motion.move, reduceMotion: reduceMotion)) { scroll(to: offset.end) }
        }
    }

    /// 补滚到了没有：读数报的最新处比滚动区真用上的内容高早一步（回复框一帧里接连长高两次，第二次补滚按旧的内容高被截在半路），
    /// 下一帧还没到最新处就再补一次。只补一次，不轮询。带上滑同一条曲线：正赶上整段在往上滑时（这时也还没到最新处）是顺着它
    /// 改个终点，不把滑到一半的截成一跳（滚动位置的动画没有可靠的"滑完了"回调，分不出这两种）。
    /// 在上面排开一段后停回最新处（`prepending`）也会被截在半路（打开时排开的那一段与上一次上滑挤在相邻两帧），那时不带动画：正在读的就是最新处，不该看到一段滑动。
    func settle(animated: Bool = true) {
        Task {
            await NextFrame.wait()
            guard follow.wrappedValue.atNewest, !follow.wrappedValue.scrolling, sliding == nil, offset.read < offset.end else { return }
            withAnimation(animated ? Motion.spatial(Motion.move, reduceMotion: reduceMotion) : nil) { scroll(to: offset.end) }
        }
    }

    /// 回到最新（点圆钮、发出一句）。发出时记下回复框此刻的高（`bottomPadding`）。已经在最新处就不用滚。
    func toNewest(sent: Bool) {
        held = sent ? bottomInset : nil
        if holding { unheld = true }
        // 对的期间报着"在最新处"，下面其实还压着没滑上来的
        guard !follow.wrappedValue.atNewest || deferred else { return }
        deferred = false
        withAnimation(reduceMotion ? nil : Motion.quick) { scroll(to: offset.end) }
    }

    /// 滚到偏移 `y`。不滚到底边：停在底边时内容一变高，滚动区自己就一下跳过去了。同一个请求再发一次时滚动位置的值不变、滚动区不动
    /// （偏移被内容边距的变化挪走、用户又没碰过时就是这样），所以在"滚到 y"与"滚到 (0, y)"两种等价的写法之间换着发。
    func scroll(to y: CGFloat) {
        if offset.flip() { position.scrollTo(point: CGPoint(x: 0, y: y)) } else { position.scrollTo(y: y) }
    }
}
