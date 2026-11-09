#if DEBUG

nonisolated struct SyncBenchArgs: Decodable, DebugArgGroup {
    static let prefix = "SyncBench"
    /// `-CuePadSyncBenchBudget <个>`：没给 `-CuePadSharedCloud` 时，这个进程的请求上限
    let budget: Int?
    /// `-CuePadSyncBenchNoRelay YES`：不连门铃，只靠按节奏的拉取（门铃不通的那条路）
    let noRelay: Bool
    /// `-CuePadSyncBenchRounds <轮>`（默认 10）：测这么多轮后记 `done`
    let rounds: Int
}
#endif
