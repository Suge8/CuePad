@_exported import CueTestSupport
import CueStore
import Foundation
import Testing

func bodies(_ cards: [Card]) -> [String] { cards.map(\.body) }

func sameInstant(_ a: Date?, _ b: Date, sourceLocation: SourceLocation = #_sourceLocation) {
  guard let a else {
    Issue.record("date is nil", sourceLocation: sourceLocation)
    return
  }
  #expect(abs(a.timeIntervalSince(b)) < 0.002, sourceLocation: sourceLocation)
}

