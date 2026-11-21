import Foundation

public protocol CueFileStore: Sendable {
    func store(_ data: Data) throws -> String
    func store(fileAt url: URL) throws -> String
    func fileURL(for key: String) -> URL?
}
