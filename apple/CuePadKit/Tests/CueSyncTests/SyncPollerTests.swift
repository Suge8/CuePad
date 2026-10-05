import CueTestSupport
import Foundation
import Synchronization
import Testing
@testable import CueSync

/// "有理由等就拉"：条件为真时按间隔主动拉，条件解除即停；给了上限时，每次收到"在等"起最多拉这么久。
@Suite(.timeLimit(.minutes(1)))
struct SyncPollerTests {
  let time = ManualTiming()

  /// 条件流：每次被消费方要下一个值时发信号，测试据此确认上一个值已经处理完。
  final class Condition: AsyncSequence, Sendable {
    typealias Element = Bool
    let (values, input) = AsyncStream<Bool>.makeStream()
    let (asks, ask) = AsyncStream<Void>.makeStream()

    struct Iterator: AsyncIteratorProtocol {
      var base: AsyncStream<Bool>.Iterator
      let ask: AsyncStream<Void>.Continuation
      mutating func next() async -> Bool? {
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
    var asks = condition.asks.makeAsyncIterator()
    let (task, count, fetches) = run(SyncPoller(interval: .seconds(5), timing: time.timing), condition)
    var fetched = fetches.makeAsyncIterator()

    await asks.next()
    condition.input.yield(true)
    for _ in 0..<3 {
      await time.waitForSleeper()
      time.advance(.seconds(5))
      await fetched.next()
    }

    condition.input.yield(false)
    await asks.next()
    await asks.next()  // false 已处理
    time.advance(.seconds(5))
    time.advance(.seconds(5))
    condition.input.finish()
    await task.value
    #expect(count.current == 3)
  }

  @Test func aLimitEndsTheWaitAndANewWaitStartsAgain() async throws {
    let condition = Condition()
    var asks = condition.asks.makeAsyncIterator()
    let (task, count, fetches) = run(SyncPoller(interval: .seconds(2), limit: .seconds(6), timing: time.timing), condition)
    var fetched = fetches.makeAsyncIterator()

    await asks.next()
    condition.input.yield(true)
    for _ in 0..<3 {  // 2、4、6 秒
      await time.waitForSleeper()
      time.advance(.seconds(2))
      await fetched.next()
    }
    await time.waitForSleeper()
    time.advance(.seconds(2))  // 8 秒：超过上限，不再拉

    await asks.next()
    condition.input.yield(true)  // 新的一次在等
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
    let (task, count, _) = run(SyncPoller(interval: .seconds(2), timing: time.timing), condition)

    await asks.next()
    condition.input.yield(false)
    await asks.next()
    time.advance(.seconds(10))
    condition.input.finish()
    await task.value
    #expect(count.current == 0)
    #expect(time.sleeperCount == 0)
  }
}
