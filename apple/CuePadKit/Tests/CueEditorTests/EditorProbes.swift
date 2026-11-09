#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif
import CueEditor
import CueTestSupport

extension EditorHarness {
    func load(_ stored: String) {
        textView.storedText = stored
        layout()
    }

    var stored: String { textView.storedText }

    /// 让出主线程直到条件成立。上限只是"确实不会来了"的兜底。
    func wait(until condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(TimeInterval(conditionBudget.components.seconds))
        while !condition() {
            if Date() > deadline { return false }
            await pump(0.02)
        }
        return true
    }
}

@MainActor
func highlightedRanges(in textView: CueTextView, color: CueColor) -> [NSRange] {
    let layout = textView.textLayoutManager!
    let content = layout.textContentManager!
    var ranges: [NSRange] = []
    layout.enumerateRenderingAttributes(from: content.documentRange.location, reverse: false) { _, attributes, range in
        if let background = attributes[.backgroundColor] as? CueColor, background == color {
            let location = content.offset(from: content.documentRange.location, to: range.location)
            ranges.append(NSRange(location: location, length: content.offset(from: range.location, to: range.endLocation)))
        }
        return true
    }
    return ranges
}

