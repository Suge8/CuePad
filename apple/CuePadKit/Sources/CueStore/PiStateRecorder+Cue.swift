import Foundation

/// Cue 此刻的样子里由值班的 Mac 写的部分（`CueState` 除去留给你回的会话）。
struct CueStateContent: Paced {
  var state: PiWorkState
  var detail: String?
  var step: CueActivity.Touch?
  var round: UUID?
  var context: CueContext?

  var isWorking: Bool { state.isWorking }
  /// 换了一轮（`round`）是关键变化；工作中只换了此刻那一步（`detail`、`step`，含在想与用工具之间切换）或上下文用量的合并
  var steady: CueStateContent { CueStateContent(state: .settled, round: round) }
}

extension PiStateRecorder {
  /// 值班的 Mac 写下 Cue 此刻的样子（`CueStore.setCueState`），与会话状态同一个节拍（`Pace`）、同一条落盘链：
  /// 进入或离开工作（在想、用工具 ↔ 歇着、出错）与换了一轮立即写，工作中的细节合并。不在值班写歇着、没有上下文：立即写并丢掉挂起的。
  /// "等你"是 Cue 消息、"做完"是一轮收尾（`finishCueRound`），都不等节拍。
  public func updateCue(
    _ state: PiWorkState, detail: String? = nil, step: CueActivity.Touch? = nil, round: UUID? = nil, context: CueContext? = nil
  ) async throws {
    let content = CueStateContent(state: state, detail: detail, step: step, round: round, context: context)
    let now = timing.now()
    switch cue.offer(content, at: now, interval: minInterval) {
    case .skip: return
    case .wait(let wait): cue.timer = after(wait) { await $0.flushCue() }
    case .now: try await writeCue(cue.commit(content, at: now))
    }
  }

  /// 一轮收尾：`CueStore.finishCueRound`（这一轮的话与歇着一次写下）排进同一条落盘链，不等节拍；挂起的那一步丢掉，不会落在歇着之后。
  /// 记为已写下歇着（`context` 是这个班次的上下文），随后同样的歇着不再写。
  @discardableResult
  public func finishCueRound(
    _ id: UUID?, startedAt: Date, answersYou: Bool, tools: PiChatMessage.Tools?, reply: String?, as author: CueAuthor, context: CueContext?
  ) async throws -> UUID? {
    cue.cancel()
    let settled = cue.commit(CueStateContent(state: .settled, context: context), at: timing.now())
    do {
      return try await persist { [store, hostID, bootID] in
        try await store.finishCueRound(id, startedAt: startedAt, answersYou: answersYou, tools: tools, reply: reply, as: author, context: context, hostID: hostID, bootID: bootID)
      }
    } catch {
      cue.forget(settled)
      throw error
    }
  }

  private func flushCue() async {
    guard let content = cue.due() else { return }
    // 定时写入没有调用方可报告；记为未写入，下一次会重写
    try? await writeCue(cue.commit(content, at: timing.now()))
  }

  private func writeCue(_ content: CueStateContent) async throws {
    do {
      try await persist { [store, hostID, bootID] in
        try await store.setCueState(content.state, detail: content.detail, step: content.step, round: content.round, context: content.context, hostID: hostID, bootID: bootID)
      }
    } catch {
      cue.forget(content)
      throw error
    }
  }
}
