import CueTestSupport
import Synchronization
import Testing
@testable import CueSync

/// "有理由等就拉"：按档位隔着拉，节奏变了先立即拉一次，档位走完或不再等即停。
@Suite
struct SyncPollerTests {
  let time = ManualTiming()

  /// 条件流：每次被消费方要下一个值时发信号，测试据此确认上一个值已经处理完。
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
    condition.input.yield(every5)  // 开始在等：开始时的那一拉由 App 的立即同步拉，这里等第一个间隔
    for _ in 0..<3 {
      await time.waitForSleeper()
      time.advance(.seconds(5))
      await fetched.next()
    }

    condition.input.yield(nil)
    await asks.next()
    await asks.next()  // 不再等已处理
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
    await time.waitForSleeper()  // 睡在 10 秒的间隔里

    await asks.next()
    condition.input.yield(SyncPoller.Cadence(every: .seconds(2)))  // 来了要等的东西：不等睡醒，马上拉
    await fetched.next()

    condition.input.finish()
    await task.value
    #expect(count.current == 1)
  }

}
