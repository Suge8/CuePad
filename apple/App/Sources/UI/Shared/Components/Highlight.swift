import SwiftUI

enum Highlight {
    static func matches(_ text: String, _ query: String, base: AttributedString? = nil) -> AttributedString {
        var result = base ?? AttributedString(text)
        for term in query.split(whereSeparator: \.isWhitespace) {
            var searchStart = result.startIndex
            while searchStart < result.endIndex,
                  let range = result[searchStart...].range(of: term, options: .caseInsensitive) {
                result[range].backgroundColor = Palette.searchMatch
                searchStart = range.upperBound
            }
        }
        return result
    }
}

extension EnvironmentValues {
    @Entry var searchHighlight = ""
}
