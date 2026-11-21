import CueStore
import SwiftUI

extension EnvironmentValues {
    @Entry var pageActive = true
    @Entry var pagePrefetch = false
}

extension View {
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
