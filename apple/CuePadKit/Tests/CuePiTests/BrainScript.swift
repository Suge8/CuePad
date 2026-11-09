#if os(macOS)
import CueTestSupport
import Foundation

/// 大脑与开工用例的话写成真模型也照做的英文；假模型照这几句演，各家共用（`RealBrainTests`、`RealCueStartTests`）。
/// 一串 echo 调用的第二次请求停在 `chain` 上：插话在下一次请求才进对话，测试在插话交出去之后放行。
extension FakeModel {
    func playBrain(chain: FakeGate) {
        on({ Self.word(in: $0.prompt) != nil }) { .say(Self.word(in: $0.prompt)!) }
        on("What word did I ask you to remember") { request in
            .say(request.said.lazy.compactMap { $0.firstMatch(of: /Remember the word (\w+)/)?.1 }.first.map(String.init) ?? "UNKNOWN")
        }
        on("What is your codename") { .say($0.system.firstMatch(of: /codename is ([A-Z0-9-]+)/).map { String($0.1) } ?? "UNKNOWN") }
        on("What color is this image") { .say($0.images.isEmpty ? "I see no image" : "red") }
        on({ $0.prompt.contains("Create a file named") }) { request in
            request.step == 0 ? .call("write", ["path": "hack.txt", "content": "x"]) : .say("I could not create it.")
        }
        on({ $0.prompt.contains("Call the echo tool") }) { request in
            let next = FakeReply.call("echo", ["text": request.results.last ?? "x"])
            return switch request.step {
            case 0: .call("echo", ["text": "x"])
            case 1: .held(chain, then: next)
            case 8...: .say(request.results.last ?? "")
            default: next
            }
        }
    }

    private static func word(in prompt: String) -> String? {
        prompt.firstMatch(of: /(?i:reply with (?:exactly |only )?(?:the (?:single )?word ))([A-Z][A-Z0-9]+)\b/).map { String($0.1) }
    }
}
#endif
