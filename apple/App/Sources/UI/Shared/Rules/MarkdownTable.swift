import Foundation

nonisolated struct MarkdownTable: Equatable, Sendable {
    enum Alignment: Equatable, Sendable { case leading, center, trailing }

    var alignments: [Alignment]
    var header: [String]
    var rows: [[String]]

    static func alignments(_ line: String) -> [Alignment]? {
        let cells = cells(line)
        guard !cells.isEmpty, cells.allSatisfy(isAlignment) else { return nil }
        return cells.map { cell in
            switch (cell.hasPrefix(":"), cell.hasSuffix(":")) {
            case (true, true): .center
            case (false, true): .trailing
            default: .leading
            }
        }
    }

    private static func isAlignment(_ cell: String) -> Bool {
        var marks = Substring(cell)
        if marks.first == ":" { marks = marks.dropFirst() }
        if marks.last == ":" { marks = marks.dropLast() }
        return !marks.isEmpty && marks.allSatisfy { $0 == "-" }
    }

    static func cells(_ line: String) -> [String] {
        var body = Substring(line.trimmingCharacters(in: .whitespaces))
        if body.hasPrefix("|") { body = body.dropFirst() }
        if body.hasSuffix("|"), !body.hasSuffix("\\|") { body = body.dropLast() }
        var cells: [String] = []
        var cell = ""
        while let character = body.popFirst() {
            if character == "\\", body.first == "|" {
                cell.append("|")
                body.removeFirst()
            } else if character == "|" {
                cells.append(cell)
                cell = ""
            } else {
                cell.append(character)
            }
        }
        cells.append(cell)
        return cells.map { $0.trimmingCharacters(in: .whitespaces) }
    }
}
