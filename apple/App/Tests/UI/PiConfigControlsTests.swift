import CueStore
import Foundation
import Testing
@testable import CuePad

/// 回复框下方的模型胶囊与思考强度条（iOS 与 Mac 共用）的显示规则：模型写短名；
/// 强度条的格数是当前模型支持的档位（"关"不占格，关着时格全空），拖到哪就是哪一档。
struct PiConfigControlsTests {
    private func model(_ name: String, provider: String = "anthropic", id: String = "m") -> PiModelOption {
        PiModelOption(key: PiModelKey(provider: provider, id: id), name: name, thinkingLevels: [])
    }

    @Test(arguments: [
        ("Claude Opus 5.5", "Opus 5.5"),
        ("claude-sonnet-5", "sonnet-5"),
        ("openai/gpt-6.1-sol", "gpt-6.1-sol"),
        ("gpt-6.1-sol-20260901", "gpt-6.1-sol"),
        ("GPT-6 Luna", "GPT-6 Luna"),
        ("Gemini 3 Pro", "Gemini 3 Pro"),
    ])
    func 模型短名_去掉提供方前缀与日期(name: String, short: String) {
        #expect(PiModelLabel.short(model(name)) == short)
    }

    @Test func 强度条_格数是支持的档位_关不占格() {
        let meter = PiThinkingMeter(levels: [.off, .low, .medium, .high], current: .medium)
        #expect(meter.bars == [.low, .medium, .high])
        #expect(meter.filled == 2)
        #expect(!meter.isOff)

        let off = PiThinkingMeter(levels: [.off, .low, .medium, .high], current: .off)
        #expect(off.filled == 0)
        #expect(off.isOff)
    }

    @Test func 强度条_拖到哪就是哪一档() {
        let meter = PiThinkingMeter(levels: [.off, .low, .medium, .high], current: .low)
        #expect(meter.level(at: 0) == .off)
        #expect(meter.level(at: 0.5) == .medium)
        #expect(meter.level(at: 0.99) == .high)
        #expect(meter.level(at: 1.4) == .high)
        #expect(PiThinkingMeter(levels: [.low, .high], current: nil).level(at: 0) == .low)
    }
}
