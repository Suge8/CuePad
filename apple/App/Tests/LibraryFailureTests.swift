import CueStore
import Foundation
import SQLite3
import Testing
@testable import CuePad

@Suite(.releasesLibraries)
struct LibraryFailureTests {
    private func library(version: Int, setup: String) throws -> LibraryLocation {
        let directory = TestLibraries.makeDirectory()
        var db: OpaquePointer?
        try #require(sqlite3_open(directory.appending(path: "cuepad.db").path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        try #require(sqlite3_exec(db, "\(setup); PRAGMA user_version = \(version);", nil, nil, nil) == SQLITE_OK)
        return try LibraryLocation.resolve(environment: [LibraryLocation.environmentKey: directory.path])
    }

    private func failure(of location: LibraryLocation) throws -> LibraryFailure {
        do {
            _ = try CueStore(location: location)
        } catch {
            return LibraryFailure(error, location: location)
        }
        throw Unexpected.opened
    }

    private enum Unexpected: Error { case opened }

    @Test func 更早或更新版本建的库_打不开但不终止_失败带原文与库版本_说明各自怎么办() throws {
        let older = try failure(of: library(version: 13, setup: "CREATE TABLE cards (id TEXT)"))
        let newer = try failure(of: library(version: 99, setup: "CREATE TABLE cards (id TEXT)"))

        #expect(older.version == 13 && older.olderLibrary && !older.newerLibrary)
        #expect(newer.version == 99 && newer.newerLibrary && !newer.olderLibrary)
        // 更新版本的库要说更新 App，而不是"不再升级"
        #expect(newer.summary != older.summary)
        #expect(older.diagnostics.contains(older.reason) && older.diagnostics.contains("13"))
        #expect(!older.summary.contains(older.reason))
    }

    #if os(iOS)
    @Test func 启动遇到打不开的库_得到失败而不是终止() throws {
        let location = try library(version: 13, setup: "CREATE TABLE cards (id TEXT)")
        guard case .failed(let failure) = Launch.open(location) else {
            Issue.record("应该得到失败")
            return
        }
        #expect(failure.version == 13)
    }
    #endif
}
