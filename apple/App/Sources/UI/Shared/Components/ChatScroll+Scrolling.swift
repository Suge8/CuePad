import SwiftUI

extension ChatScroll {
    #if os(iOS)
    static var followsKeyboard: Bool { true }
    #else
    static var followsKeyboard: Bool { false }
    #endif

    func margin(_ width: CGFloat) -> CGFloat { ChatLayout.margin(width, readingWidth: readingWidth, inset: inset) }

    var unseen: Bool { leftAt.map { $0 != followKey } ?? false }

    var pinned: Bool { follow.wrappedValue.pinned(holding: holding) }

    /// 贴着最新时对话底下让出的高先留成留白（`held`），接着长出来的先填它，填进去的那一截对话不动，填不下的才上滑；留白不自己收，等下一次长出来。
    /// 让出高的两处：发出时回复框当下收起、发出的话要等写进库才到；一轮做完小人收走、收起一格。跟着变矮的话贴着最新的整段对话先沉下去，
    /// 接着到的那句、长出的回答又把它顶上来；到时自己收的话回答显完后整段再沉一下。代价是短回答之后回复框上方空着一截，直到下一句。
    /// 看内容长高，不看 `followKey`：它还算着别的（之前那句的送达情况），可能比那句先变。
    /// 排在内容里而不是内容边距：Mac 的滚动区改边距要晚一次排版才生效，那时它自己把偏移一下挪到底，就滑不起来了。
    /// 键盘是安全区，不在这里：发出时键盘随即收起，对话跟着键盘的动画走，不留。
    /// 叠在那一块上方的提示不在这里让：它落在对话末尾常驻的那一行的位置上（`ChatLiveSlot`）。
    var bottomPadding: CGFloat { max(bottomInset, held ?? 0) }

    func keep(_ shrunk: CGFloat) { held = bottomPadding + shrunk }

    /// 长出来的先填留白，返回没填下、要滑上去的那一截。
    func fill(_ grown: CGFloat) -> CGFloat {
        guard let held, grown > 0 else { return grown }
        self.held = held - grown > bottomInset ? held - grown : nil
        return grown - min(grown, max(0, held - bottomInset))
    }

    final class ScrollOffset {
        private(set) var read: CGFloat = 0
        private(set) var end: CGFloat = 0
        private(set) var container: CGFloat = 0
        private var width: CGFloat = 0
        /// 不用 action 给的旧值：那是上一次求值，中间几次变化（打开时排开更早的一段）可能求了值却没调 action，拿它比内容变没变高会漏掉。
        private var delivered: (reading: Reading, container: CGFloat, width: CGFloat, read: CGFloat)?

        struct Delivered {
            let reading: Reading?
            let viewShrank: Bool
            let widthChanged: Bool
            let moved: Bool
        }

        func set(read: CGFloat, end: CGFloat, container: CGFloat, width: CGFloat) {
            (self.read, self.end, self.container, self.width) = (read, end, container, width)
        }

        func deliver(_ reading: Reading) -> Delivered {
            defer { delivered = (reading, container, width, read) }
            return Delivered(
                reading: delivered?.reading, viewShrank: delivered.map { container < $0.container } ?? false,
                widthChanged: delivered.map { width != $0.width } ?? true, moved: delivered.map { $0.read != read } ?? true)
        }
    }

    /// action 只在读数变了才跑，滚动时每帧不碰页面的状态；所以可见区自己的尺寸与边距（偏移、最新处、可见区的高）只记在 `ScrollOffset`，不进读数：
    /// 推入页面、App 刚打开时系统要排好几遍才定下导航栏的高与短内容贴底的那段边距，一帧里接连变好几次，进了读数 action 在一帧里就跑好几遍，
    /// 系统丢掉第三遍起的（连同最后定下来的那次）。系统挪走了偏移时越线变了照样会来（`nearNewest`）。
    struct Reading: Equatable {
        var nearNewest: Bool
        var beyondScreen: Bool
        var nearOldest: Bool
        var height: CGFloat
        var floating: CGFloat
        var anchor: ChatAnchor.Tracked
    }

    /// 用定长的 `Motion.glide`，不用弹簧：弹簧最后那段一两像素的尾巴
    /// 要再画两百多毫秒，正好压在发出的话送达、状态变了的那几次更新上，那几帧本来不用画，一画就掉帧。
    /// 等这一帧提交了再滑：动画从这一帧起算的话，第一帧画出来时已经走了一大截，看着是一跳。
    func slide(_ reader: ScrollViewProxy) {
        sliding?.cancel()
        sliding = Task {
            await NextFrame.wait()
            guard !Task.isCancelled else { return }
            sliding = nil
            guard follow.wrappedValue.atNewest, !follow.wrappedValue.scrolling else { return }
            withAnimation(Motion.spatial(Motion.glide, reduceMotion: reduceMotion)) { toEnd(reader) }
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
            withAnimation(animated ? Motion.spatial(Motion.glide, reduceMotion: reduceMotion) : nil) { toEnd(reader) }
        }
    }

    func toNewest(sent: Bool, _ reader: ScrollViewProxy) {
        held = sent ? bottomPadding : nil
        withAnimation(Motion.spatial(Motion.fade, reduceMotion: reduceMotion)) { toEnd(reader) }
    }

    func rise(by height: CGFloat) {
        guard !reduceMotion else { return }
        lift.slide(by: height)
        rose = ChatRise(count: rose.count + 1, height: height)
    }

    static var end: String { "chat.end" }

    /// 不写进滚动位置（`position`）：那里存着的点
    /// 内容一变就过时了，之后哪次更新滚动区把它再用一遍，整段就退回那时的最新处（Mac 上发出一句后退回发送前、之后的全在下面看不见）；
    /// 每长一下改记一次又要多排一遍版。也不用滚动位置的"滚到底边"：存着它时内容一变高滚动区自己就一下跳过去，在对的期间、跳去某一条之后都不该跟。
    func toEnd(_ reader: ScrollViewProxy) { reader.scrollTo(Self.end, anchor: .bottom) }
}
