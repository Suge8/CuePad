import CueStore
import Foundation
import SQLite3
import Testing
@testable import CuePad

/// 资料库打不开（更早或更新版本建的库）时进程不能终止：失败交给界面，带原文与库版本，界面据此写人话、可重试、可导出诊断。
@MainActor
struct LibraryFailureTests {
    /// 一个隔离位置，库文件是 `setup` 造出来的、结构版本为 `version` 的样子。
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
            _ = try AppServices.openLibrary(at: location)
        } catch {
            return LibraryFailure(error, location: location)
        }
        throw Unexpected.opened
    }

    private enum Unexpected: Error { case opened }

    @Test func 更早版本建的库_打不开但不终止_失败带原文与库版本() throws {
        let failure = try failure(of: library(version: 13, setup: "CREATE TABLE cards (id TEXT)"))

        #expect(failure.version == 13 && failure.olderLibrary && !failure.newerLibrary)
        #expect(failure.diagnostics.contains(failure.reason) && failure.diagnostics.contains("13"))
        // 给人看的说明不夹原文（原文折叠在详情里）
        #expect(!failure.summary.contains(failure.reason))
    }

    @Test func 更新版本建的库_说明要更新_而不是不再升级() throws {
        let newer = try failure(of: library(version: 99, setup: "CREATE TABLE cards (id TEXT)"))
        let older = try failure(of: library(version: 13, setup: "CREATE TABLE cards (id TEXT)"))

        #expect(newer.version == 99 && newer.newerLibrary && !newer.olderLibrary)
        #expect(newer.summary != older.summary)
    }

    @Test func 正常的库照常打开() throws {
        let location = try library(version: 0, setup: "SELECT 1")  // 空库：按新库建
        _ = try AppServices.openLibrary(at: location)
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

    @Test func 启动遇到正常的库_就绪() throws {
        guard case .ready = Launch.open(try library(version: 0, setup: "SELECT 1")) else {
            Issue.record("应该就绪")
            return
        }
    }
    #endif
}
