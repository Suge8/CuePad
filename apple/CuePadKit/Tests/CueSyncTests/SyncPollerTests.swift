import CueTestSupport
import Synchronization
import Testing
@testable import CueSync

@Suite
struct SyncPollerTests {
  let time = ManualTiming()

  final class Condition: AsyncSequence, Sendable {
    typealias Element = SyncPoller.Cadence?
    let (values, input) = AsyncStream<SyncPoller.Cadence?>.makeStream()
    let (asks, ask) = AsyncStream<Void>.makeStream()

    struct Iterator: AsyncIteratorProtocol {
      var base: AsyncStream<SyncPoller.Cadence?>.Iterator
      let ask: AsyncStream<Void>.Continuation
      mutating func next(isolation actor: isolated (any Actor)?) async -> SyncPoller.Cadence?? {
        ask.yield()
        return await base.next(isolation: actor)
      }
    }

    func makeAsyncIterator() -> Iterator { Iterator(base: values.makeAsyncIterator(), ask: ask) }
  }

  final class Count: Sendable {
    private let value = Mutex(0)
    func increment() { value.withLock { $0 += 1 } }
    var current: Int { value.withLock { $0 } }
  }

  private func run(_ poller: SyncPoller, _ condition: Condition) -> (Task<Void, Never>, Count, AsyncStream<Void>) {
    let (fetches, fetched) = AsyncStream<Void>.makeStream()
    let count = Count()
    let task = Task {
      await poller.run(while: condition) {
        count.increment()
        fetched.yield()
      }
    }
    return (task, count, fetches)
  }

  @Test func fetchesEveryIntervalWhileWaitingAndStopsWhenTheConditionClears() async throws {
    let condition = Condition()
    let every5 = SyncPoller.Cadence(every: .seconds(5))
    var asks = condition.asks.makeAsyncIterator()
    let (task, count, fetches) = run(SyncPoller(timing: time.timing), condition)
    var fetched = fetches.makeAsyncIterator()

    await asks.next()
    condition.input.yield(every5)
    for _ in 0..<3 {
      try await time.waitForSleeper()
      time.advance(.seconds(5))
      await fetched.next()
    }

    condition.input.yield(nil)
    await asks.next()
    await asks.next()
    time.advance(.seconds(5))
    time.advance(.seconds(5))
    condition.input.finish()
    await task.value
    #expect(count.current == 3)
  }

  @Test func aNewCadenceInterruptsTheSleepAndFetchesRightAway() async throws {
    let condition = Condition()
    let slow = SyncPoller.Cadence(every: .seconds(10))
    var asks = condition.asks.makeAsyncIterator()
    let (task, count, fetches) = run(SyncPoller(timing: time.timing), condition)
    var fetched = fetches.makeAsyncIterator()

    await asks.next()
    condition.input.yield(slow)
    try await time.waitForSleeper()

    await asks.next()
    condition.input.yield(SyncPoller.Cadence(every: .seconds(2)))
    await fetched.next()

    condition.input.finish()
    await task.value
    #expect(count.current == 1)
  }

}
