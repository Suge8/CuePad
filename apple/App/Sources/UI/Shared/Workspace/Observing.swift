import CueStore
import SwiftUI

extension EnvironmentValues {
    /// Mac 的内容区把去过的页都挂着（`Workspace.mountedPages`），不在前台的页暂停订阅、不读实时状态；其余地方没有"挂着不看"的页，默认 true。
    @Entry var pageActive = true
    /// 不在前台、但要先读一份数据的页（空闲时先挂上的 `Workspace.premount`、收着的 ⌘K）：只读第一份，不跟着变。
    @Entry var pagePrefetch = false
}

extension View {
    /// 读到的和上一次一样就不写：在 Store 一侧比一次，重新订阅后手里已有的值当作"上一次"，没变的数据不送到主线程、界面也不重算。
    /// 在前台、手里还没有值时当场读（`CueStore.snapshot`，`onAppear` 在第一帧之前做完）再从它接着订阅：本机库里的东西第一帧就排好，页面没有"还没读到"这一态。读失败时留给订阅报告，不报两次。
    /// `animation`：读到的值带着它落下（当场读的那一份也是），给内容空着插进来、读到才长开的地方（会话条展开的项目）；不给时当场读的不播动画。
    /// `onError` 收到订阅读不下去的错（库此刻的暂时性错误 Store 自己退避重读，不到这里）：页面交给 `Workspace.fail`，有意不报的显式写空。
    func observing<T: Sendable & Equatable>(
        _ store: CueStore, id: some Equatable = 0, into value: Binding<T?>, animation: Animation? = nil,
        onError: @escaping (any Error) -> Void,
        _ read: @escaping @Sendable (isolated CueStore) throws -> T
    ) -> some View {
        modifier(Observing(store: store, id: id, value: value, animation: animation, onError: onError, read: read))
    }
}

private struct Observing<T: Sendable & Equatable, ID: Equatable>: ViewModifier {
    let store: CueStore
    let id: ID
    @Binding var value: T?
    let animation: Animation?
    let onError: (any Error) -> Void
    let read: @Sendable (isolated CueStore) throws -> T
    @Environment(\.pageActive) private var active
    @Environment(\.pagePrefetch) private var prefetch
    @State private var start: Snapshot<T>?

    private struct Run: Equatable {
        let id: ID
        let active: Bool
    }

    func body(content: Content) -> some View {
        content
            .onAppear(perform: readNow)
            .onChange(of: Run(id: id, active: active), readNow)
            .task(id: Run(id: id, active: active)) {
                guard active || prefetch && value == nil else { return }
                let updates = start.map { store.observe(from: $0, read) } ?? store.observe(after: value, read)
                start = nil
                await follow(updates)
            }
    }

    private func readNow() {
        guard active, value == nil, let snapshot = try? store.snapshot(read) else { return }
        start = snapshot
        // 当场读到的是这一页本来的样子，不是变化：页面上挂在这些值上的动画（`animation(_:value:)`）不播，
        // 不然从"还没读到"到读到的那一截连同同一次更新里的版面变化（冷启动时内容区从占位尺寸到真实尺寸）一帧帧排过去
        var transaction = Transaction(animation: animation)
        transaction.disablesAnimations = animation == nil
        withTransaction(transaction) { value = snapshot.value }
        DebugHooks.observed(snapshot.value)
    }

    private func follow(_ updates: AsyncThrowingStream<T, any Error>) async {
        do {
            for try await next in updates {
                if let animation { withAnimation(animation) { value = next } } else { value = next }
                DebugHooks.observed(next)
                if !active { return }
            }
        } catch is CancellationError {
        } catch {
            onError(error)
        }
    }
}
