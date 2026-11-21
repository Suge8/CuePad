import Foundation

extension CueStore {
  public func wantsSuggestedName(_ sessionID: String) throws -> Bool {
    guard try latestRenames(to: [sessionID]).isEmpty else { return false }
    return try !tasks(boundTo: sessionID).contains { $0.task.piSessionID == sessionID && !$0.task.heading.isEmpty }
  }
}
