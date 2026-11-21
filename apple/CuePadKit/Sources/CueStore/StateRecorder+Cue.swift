import Foundation

struct CueStateContent: Paced {
  var state: WorkState
  var detail: String?
  var step: CueActivity.Touch?
  var round: UUID?
  var context: CueContext?

  var isWorking: Bool { state.isWorking }
  var steady: CueStateContent { CueStateContent(state: .settled, round: round) }
}

extension StateRecorder {
  public func updateCue(
    _ state: WorkState, detail: String? = nil, step: CueActivity.Touch? = nil, round: UUID? = nil, context: CueContext? = nil
  ) async throws {
    let content = CueStateContent(state: state, detail: detail, step: step, round: round, context: context)
    let now = timing.now()
    switch cue.offer(content, at: now, interval: minInterval) {
    case .skip: return
    case .wait(let wait): cue.timer = after(wait) { await $0.flushCue(timer: $1) }
    case .now: try await writeCue(cue.commit(content, at: now))
    }
  }

  @discardableResult
  public func finishCueRound(
    _ id: UUID?, startedAt: Date, answersYou: Bool, tools: ChatMessage.Tools?, reply: String?, as author: CueAuthor, context: CueContext?, answeredRequests: [UUID] = []
  ) async throws -> UUID? {
    cue.cancel()
    let settled = cue.commit(CueStateContent(state: .settled, context: context), at: timing.now())
    do {
      return try await persist { [store, hostID, bootID] in
        try await store.finishCueRound(id, startedAt: startedAt, answersYou: answersYou, tools: tools, reply: reply, as: author, context: context, answeredRequests: answeredRequests, hostID: hostID, bootID: bootID)
      }
    } catch {
      cue.forget(settled)
      throw error
    }
  }

  private func flushCue(timer: UUID) async {
    guard let content = cue.due(timer) else { return }
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
