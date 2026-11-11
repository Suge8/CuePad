#if os(macOS)
import CueStore
import CueTestSupport
import Foundation
import Testing
@testable import CueBridge

extension RealBrainTests {
    /// 最后一次请求结束之后、这一轮收尾之前插进的话，Grok 1.0.70 把它们搁浅，之后按先后各开一轮：每句由自己那一轮收下、各得到回答。
    /// 这段窗口由停止钩子撑开：大脑的 Grok 配置目录是它自己的临时目录，壳在起 Grok 前往那里放一个停止钩子，钩子停在闸门上，
    /// 两句都插进去了才放行。不撑开时窗口只有 Grok 收尾的几十到一百多毫秒（实测 44–142 ms），忙的 CI 上插话落到窗口外，就并进下一轮。
    @Test(RealAgents.needs(.grok))
    func interjectionsStrandedAfterTheLastRequestAreReceivedByTheTurnsGrokOpensForThem() async throws {
        let bench = try makeTempDirectory()
        let reached = bench.appending(path: "stop-reached"), open = bench.appending(path: "stop-open")
        let hold = bench.appending(path: "hold.sh"), grok = bench.appending(path: "grok")
        // 起它的 Grok 退了就不再等：用例没走到放行就失败时不留进程
        try TestScript.install("""
            #!/bin/sh
            . "$0.env"
            cat >/dev/null
            touch "$REACHED"
            while [ ! -e "$OPEN" ] && kill -0 $PPID 2>/dev/null; do sleep 0.01; done
            """, at: hold, variables: ["REACHED": reached.path, "OPEN": open.path])
        try TestScript.install("""
            #!/bin/sh
            . "$0.env"
            mkdir -p "$GROK_HOME/hooks"
            printf '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"%s","timeout":600}]}]}}' "$HOLD" > "$GROK_HOME/hooks/hold.json"
            exec "$GROK" "$@"
            """, at: grok, variables: ["GROK": RealAgents.pinned(.grok).executable.path, "HOLD": hold.path])

        try await withRig(.grok, executable: grok) { rig in
        let first = UUID(), second = UUID(), third = UUID()
        try await rig.brain.send("Reply with only the single word ALPHA.", images: [], id: first)
        try await eventually("第一轮的停止钩子在跑") { FileManager.default.fileExists(atPath: reached.path) }
        try await rig.brain.send("Reply with only the single word BETA.", images: [], id: second)
        try await rig.brain.send("Reply with only the single word GAMMA.", images: [], id: third)
        try Data().write(to: open)
        try await rig.finished(3)

        #expect(rig.failures == [], "\(rig.events)")
        let turns = rig.turns.map { ($0.received, $0.reply ?? "") }
        #expect(turns.map(\.0) == [[first], [second], [third]], "\(rig.events)")
        #expect(turns.map(\.1) == ["ALPHA", "BETA", "GAMMA"], "\(rig.events)")
        }
    }
}
#endif
