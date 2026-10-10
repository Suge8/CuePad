import CueTestSupport
import Foundation
import Synchronization
import Testing
@testable import CueSync

/// "有理由等就拉"：每收到一个节奏就立即拉一次，之后按档位隔着拉，档位走完或不再等即停。
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
    let every5 = SyncPoller.Cadence(.every(.seconds(5)))
    var asks = condition.asks.makeAsyncIterator()
    let (task, count, fetches) = run(SyncPoller(timing: time.timing), condition)
    var fetched = fetches.makeAsyncIterator()

    await asks.next()
    condition.input.yield(every5)
    await fetched.next()  // 开始在等：立即拉
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
    #expect(count.current == 4)
  }

  @Test func aFiniteCadenceEndsAndANewOneStartsAgain() async throws {
    let condition = Condition()
    let limited = SyncPoller.Cadence(.every(.seconds(2), for: .seconds(6)))
    var asks = condition.asks.makeAsyncIterator()
    let (task, count, fetches) = run(SyncPoller(timing: time.timing), condition)
    var fetched = fetches.makeAsyncIterator()

    await asks.next()
    condition.input.yield(limited)
    await fetched.next()  // 0 秒：开始在等，立即拉
    for _ in 0..<2 {  // 2、4 秒
      await time.waitForSleeper()
      time.advance(.seconds(2))
      await fetched.next()
    }
    await time.waitForSleeper()
    time.advance(.seconds(2))  // 6 秒：档位走完，不再拉

    await asks.next()
    condition.input.yield(limited)  // 新的一次在等：立即拉
    await fetched.next()

    condition.input.finish()
    await task.value
    #expect(count.current == 4)
  }

  /// Mac 上有会话连着但没有要等的请求：先 2 秒一次拉两分钟，之后 10 秒一次一直拉；每小时的次数（原来每 2 秒一次，一小时 1801 次）。
  @Test func slowsDownToTheNextStepAfterTheFirstOneRunsOut() async throws {
    let condition = Condition()
    let idle = SyncPoller.Cadence(.every(.seconds(2), for: .seconds(120)), .every(.seconds(10)))
    var asks = condition.asks.makeAsyncIterator()
    let (task, count, fetches) = run(SyncPoller(timing: time.timing), condition)
    var fetched = fetches.makeAsyncIterator()

    await asks.next()
    condition.input.yield(idle)
    await fetched.next()
    // 前两分钟：每 2 秒（60 次）；之后每 10 秒，到一小时整（348 次）
    for _ in 0..<60 {
      await time.waitForSleeper()
      time.advance(.seconds(2))
      await fetched.next()
    }
    #expect(count.current == 61)
    for _ in 0..<348 {
      await time.waitForSleeper()
      time.advance(.seconds(10))
      await fetched.next()
    }
    condition.input.finish()
    await task.value
    #expect(count.current == 409)
  }

  @Test func aNewCadenceInterruptsTheSleepAndFetchesRightAway() async throws {
    let condition = Condition()
    let slow = SyncPoller.Cadence(.every(.seconds(10)))
    var asks = condition.asks.makeAsyncIterator()
    let (task, count, fetches) = run(SyncPoller(timing: time.timing), condition)
    var fetched = fetches.makeAsyncIterator()

    await asks.next()
    condition.input.yield(slow)
    await fetched.next()
    await time.waitForSleeper()  // 睡在 10 秒的间隔里

    await asks.next()
    condition.input.yield(SyncPoller.Cadence(.every(.seconds(2))))  // 来了要等的东西：不等睡醒，马上拉
    await fetched.next()

    condition.input.finish()
    await task.value
    #expect(count.current == 2)
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
