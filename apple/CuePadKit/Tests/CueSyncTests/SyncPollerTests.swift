import CueTestSupport
import Foundation
import Synchronization
import Testing
@testable import CueSync

/// "有理由等就拉"：在等时按给定间隔主动拉，不再等即停；给了上限时，每次收到"在等"起最多拉这么久。
@Suite(.timeLimit(.minutes(1)))
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
      mutating func next() async -> SyncPoller.Cadence?? {
        ask.yield()
        return await base.next()
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
    let every5 = SyncPoller.Cadence(interval: .seconds(5))
    var asks = condition.asks.makeAsyncIterator()
    let (task, count, fetches) = run(SyncPoller(timing: time.timing), condition)
    var fetched = fetches.makeAsyncIterator()

    await asks.next()
    condition.input.yield(every5)
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

  @Test func aLimitEndsTheWaitAndANewWaitStartsAgain() async throws {
    let condition = Condition()
    let limited = SyncPoller.Cadence(interval: .seconds(2), limit: .seconds(6))
    var asks = condition.asks.makeAsyncIterator()
    let (task, count, fetches) = run(SyncPoller(timing: time.timing), condition)
    var fetched = fetches.makeAsyncIterator()

    await asks.next()
    condition.input.yield(limited)
    for _ in 0..<3 {  // 2、4、6 秒
      await time.waitForSleeper()
      time.advance(.seconds(2))
      await fetched.next()
    }
    await time.waitForSleeper()
    time.advance(.seconds(2))  // 8 秒：超过上限，不再拉

    await asks.next()
    condition.input.yield(limited)  // 新的一次在等
    await asks.next()
    await time.waitForSleeper()
    time.advance(.seconds(2))
    await fetched.next()

    condition.input.finish()
    await task.value
    #expect(count.current == 4)
  }

  @Test func nothingIsFetchedWhileNotWaiting() async throws {
    let condition = Condition()
    var asks = condition.asks.makeAsyncIterator()
    let (task, count, _) = run(SyncPoller(timing: time.timing), condition)

    await asks.next()
    condition.input.yield(nil)
    await asks.next()
    time.advance(.seconds(10))
    condition.input.finish()
    await task.value
    #expect(count.current == 0)
    #expect(time.sleeperCount == 0)
  }
}
