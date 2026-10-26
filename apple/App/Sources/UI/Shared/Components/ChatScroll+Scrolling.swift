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

    /// 离开最新处后来过新内容："回到最新"圆钮上带一个点。
    var unseen: Bool { leftAt.map { $0 != followKey } ?? false }

    /// 内容变高矮时底锚：贴着最新、用户没在滚、没在等和 iCloud 对完（或自己要回到最新）。滚走了、在对的期间新的长在下面，正在读的不动。
    var pinned: Bool { follow.wrappedValue.atNewest && !follow.wrappedValue.scrolling && (!holding || unheld) && !deferred }

    /// 内容底下让出浮着的回复框（Mac，`chatBottomInset`）的留白。发出时回复框当下收起，发出的话要等写进库才到：那之前留白不跟着变矮，
    /// 那句到了（内容真的长高）再收，与它出现在同一帧；跟着变矮的话贴着最新的整段对话先被拉下来一两帧，再一下顶上去。
    /// 看内容长高，不看 `followKey`：它还算着别的（之前那句的送达情况），可能比那句先变。
    /// 排在内容里而不是内容边距：Mac 的滚动区改边距要晚一次排版才生效，那时它自己把偏移一下挪到底，就滑不起来了。
    /// 键盘是安全区，不在这里：发出时键盘随即收起，对话跟着键盘的动画走，不留。
    var bottomPadding: CGFloat { max(bottomInset, held ?? 0) }

    /// 最近一次读数里的可见区（偏移、最新处、可见区的高）与上一次交给读数 action 的读数。读数闭包不一定在主线程，所以带锁；
    /// 它不是状态，写它不触发任何更新。
    final class ScrollOffset: Sendable {
        private struct Values {
            /// 可见区顶边在内容里的位置。
            var read: CGFloat = 0
            /// 最新处的偏移（`scrollTo(y:)` 的 y）。
            var end: CGFloat = 0
            /// 可见区的高（扣掉上下边距）。
            var container: CGFloat = 0
            /// 上一次交给 action 的读数与那时可见区的高。不用 action 给的旧值：那是上一次求值，中间几次变化（打开时排开更早的一段）可能求了值却没调 action，
            /// 拿它比内容变没变高会漏掉。
            var delivered: (reading: Reading, container: CGFloat)?
            /// 上一回记下的最新一条新到的（`arrival`）；还没有过为 nil。
            var arrival: UUID?
        }

        /// 交给 action 时上一次交过去的读数，与这之间可见区从底下变矮了没有。
        struct Delivered {
            let reading: Reading?
            let viewShrank: Bool
        }

        private let values = Mutex(Values())

        func set(read: CGFloat, end: CGFloat, container: CGFloat) {
            values.withLock {
                $0.read = read
                $0.end = end
                $0.container = container
            }
        }

        var read: CGFloat { values.withLock { $0.read } }
        var end: CGFloat { values.withLock { $0.end } }

        /// 换上这次交给 action 的读数。
        func deliver(_ reading: Reading) -> Delivered {
            values.withLock { values in
                defer { values.delivered = (reading, values.container) }
                return Delivered(reading: values.delivered?.reading, viewShrank: values.delivered.map { values.container < $0.container } ?? false)
            }
        }

        /// 换上这次读数时的 `arrival`，返回它是不是刚换成的一条。第一回有它时只记下：打开时已在的（对话读进来那一下）不算新到。
        func arrived(_ arrival: UUID?) -> Bool {
            values.withLock { values in
                guard let arrival else { return false }
                defer { values.arrival = arrival }
                return values.arrival.map { $0 != arrival } ?? false
            }
        }
    }

    /// 滚动区的读数：只留下会让状态改变的几条越线（离最新处近不近、超没超一屏、离最早处近不近）与内容自己的高、让出浮着那一块的那段，
    /// action 只在它们变了才跑：滚动时每帧不碰页面的状态。可见区自己的尺寸与边距（偏移、最新处、可见区的高）只记在 `ScrollOffset`，不进读数：
    /// 推入页面、App 刚打开时系统要排好几遍才定下导航栏的高与短内容贴底的那段边距，一帧里接连变好几次，进了读数 action 在一帧里就跑好几遍，
    /// 系统丢掉第三遍起的（连同最后定下来的那次）。系统挪走了偏移时越线变了照样会来（`nearNewest`）。
    struct Reading: Equatable {
        var nearNewest: Bool
        var beyondScreen: Bool
        var nearOldest: Bool
        /// 内容的高，不含让出回复框的那段（它变高变矮是回复框的事，不滑）。
        var height: CGFloat
        /// 让出浮着的那一块的那段（`bottomPadding`）。
        var floating: CGFloat
    }

    /// 对完一次（`holding` 期间长在下面的）、键盘升起时，整段滑到最新处（减弱动态效果时直接到）；贴着最新时来的新内容不经这里，底锚当帧就排好（`pinned`）。用定长的 `Motion.move`，不用弹簧：弹簧最后那段一两像素的尾巴
    /// 要再画两百多毫秒，正好压在发出的话送达、状态变了的那几次更新上，那几帧本来不用画，一画就掉帧。
    /// 等这一帧提交了再滑：动画从这一帧起算的话，第一帧画出来时已经走了一大截，看着是一跳。
    /// 滑到的是那时的最新处（留白收起之后）；等的这一帧里用户开始滚了就不滑了。
    func slide(_ reader: ScrollViewProxy) {
        sliding?.cancel()
        sliding = Task {
            await NextFrame.wait()
            guard !Task.isCancelled else { return }
            sliding = nil
            guard follow.wrappedValue.atNewest, !follow.wrappedValue.scrolling else { return }
            withAnimation(Motion.spatial(Motion.move, reduceMotion: reduceMotion)) { toEnd(reader) }
        }
    }

    /// 补滚到了没有：读数报的最新处比滚动区真用上的内容高早一步（回复框一帧里接连长高两次，第二次补滚按旧的内容高被截在半路），
    /// 下一帧还没到最新处就再补一次。只补一次，不轮询。带上滑同一条曲线：正赶上整段在往上滑时（这时也还没到最新处）是顺着它
    /// 改个终点，不把滑到一半的截成一跳（滚动位置的动画没有可靠的"滑完了"回调，分不出这两种）。
    /// 在上面排开一段后停回最新处（`prepending`）也会被截在半路（打开时排开的那一段与上一次上滑挤在相邻两帧），那时不带动画：正在读的就是最新处，不该看到一段滑动。
    func settle(_ reader: ScrollViewProxy, animated: Bool = true) {
        Task {
            await NextFrame.wait()
            guard follow.wrappedValue.atNewest, !follow.wrappedValue.scrolling, sliding == nil, offset.read < offset.end else { return }
            withAnimation(animated ? Motion.spatial(Motion.move, reduceMotion: reduceMotion) : nil) { toEnd(reader) }
        }
    }

    /// 回到最新（点圆钮、发出一句）。发出时记下回复框此刻的高（`bottomPadding`）。已经在最新处就不用滚。
    func toNewest(sent: Bool, _ reader: ScrollViewProxy) {
        held = sent ? bottomInset : nil
        if holding { unheld = true }
        // 对的期间报着"在最新处"，下面其实还压着没滑上来的
        guard !follow.wrappedValue.atNewest || deferred else { return }
        deferred = false
        withAnimation(reduceMotion ? nil : HandOff.quick) { toEnd(reader) }
    }

    /// 新到的那一条长高了 `height`：整段内容在渲染端先往下挪这么多（上面的对话看着还在原处），无回弹地归零（`ContentLift`），它让开了再淡入（`CueBubble.arrival`）。
    /// 插进来那一次已排在终位，之后每帧主线程不动。减弱动态效果时不挪，新的一条只淡入。
    func rise(by height: CGFloat) {
        guard !reduceMotion else { return }
        lift.slide(by: height)
    }

    /// 内容末尾那个不占高的点（`toEnd`）。
    static var end: String { "chat.end" }

    /// 滚到最新处：内容末尾那个点贴着可见区下沿（按条的 id 跳，`ScrollViewReader`）。不写进滚动位置（`position`）：那里存着的点
    /// 内容一变就过时了，之后哪次更新滚动区把它再用一遍，整段就退回那时的最新处（Mac 上发出一句后退回发送前、之后的全在下面看不见）；
    /// 每长一下改记一次又要多排一遍版。也不用滚动位置的"滚到底边"：存着它时内容一变高滚动区自己就一下跳过去，在对的期间、跳去某一条之后都不该跟。
    func toEnd(_ reader: ScrollViewProxy) { reader.scrollTo(Self.end, anchor: .bottom) }
}
