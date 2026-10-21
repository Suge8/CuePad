#if os(macOS)
import AppKit
import CueAgent
import CuePi
import CueStore
import CueTestSupport
import CueText
import Darwin
import Foundation
import SwiftUI
import Testing
@testable import CuePad

/// 会话发来的一张效果图：按文件名画出那个方案的提问卡（决定单、对话里问、郑重放行；original 是现在的提问卡，作对比），手机或 Mac、浅色或深色；
/// 侧栏改版的几张（plan-、wip-、final- 开头）是一列项目行，在跑的带会话数与一颗状态点；别的改动的截图是一页设置。Cue 用读文件工具打开看得出是哪个方案、哪一种样子。
@MainActor
func mockShot(_ name: String) throws -> Data {
    let dark = name.contains("dark"), mac = name.contains("mac")
    let ink: Color = dark ? .white : .black, paper: Color = dark ? Color(white: 0.16) : .white, fill: Color = dark ? Color(white: 0.28) : Color(white: 0.92)
    func button(_ text: String, primary: Bool = false) -> some View {
        Text(text).font(.callout.weight(.semibold)).frame(maxWidth: .infinity).padding(.vertical, 10)
            .background(primary ? Color.orange : fill, in: .rect(cornerRadius: 10)).foregroundStyle(primary ? .white : ink)
    }
    let question = Text("可以推送 scheduler 的重连修复吗？").font(.headline)
    let why = Text("推上去别人就拉得到，撤不回来。").font(.caption).foregroundStyle(.secondary)
    @ViewBuilder var card: some View {
        if name.contains("original") {
            // 改动前的原样：现在的提问卡，一行小字的问题与两个小选项
            VStack(alignment: .leading, spacing: 8) {
                Text("现在的样子").font(.caption2).foregroundStyle(.secondary)
                Text("可以推送 scheduler 的重连修复吗？").font(.footnote)
                HStack {
                    Text(CueAsk.once).font(.caption).padding(6).background(fill, in: .capsule)
                    Text("以后不用问").font(.caption).padding(6).background(fill, in: .capsule)
                }
            }
        } else if name.hasPrefix("decision-sheet") {
            VStack(alignment: .leading, spacing: 10) {
                question
                why
                button("可以", primary: true)
                button("以后推送代码都不用问")
            }
        } else if name.hasPrefix("in-thread") {
            VStack(alignment: .leading, spacing: 10) {
                Text("重连用例补上了，全过。").font(.callout).padding(10).background(fill, in: .rect(cornerRadius: 12))
                Text("要推送吗？").font(.callout).padding(10).background(fill, in: .rect(cornerRadius: 12))
                Spacer().frame(height: 30)
                HStack { button("可以", primary: true); button("以后不用问") }
                Text("对 Cue 说").font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(10)
                    .background(fill, in: .capsule)
            }
        } else if name.hasPrefix("slide-to-allow") {
            VStack(alignment: .leading, spacing: 12) {
                question
                why
                HStack {
                    Circle().fill(Color.orange).frame(width: 34, height: 34)
                    Text("滑动以允许 →").font(.callout).foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(4).background(fill, in: .capsule)
                HStack { Text("以后不用问").font(.callout); Spacer(); Capsule().fill(fill).frame(width: 44, height: 24) }
            }
        } else if ["plan-", "wip-", "final-"].contains(where: name.hasPrefix) {
            VStack(alignment: .leading, spacing: 8) {
                Text("项目").font(.caption).foregroundStyle(.secondary)
                ForEach([("圆桌", 3), ("CuePad", 2), ("个人网站", 0)], id: \.0) { project, running in
                    HStack {
                        Circle().fill(running > 0 ? Color.green : fill).frame(width: 8, height: 8)
                        Text(project).font(.callout).foregroundStyle(ink)
                        Spacer()
                        if running > 0 { Text("\(running) 个会话在跑").font(.caption).foregroundStyle(.secondary) }
                    }
                    .padding(8).background(fill, in: .rect(cornerRadius: 8))
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Text(name).font(.headline)
                ForEach(0..<4) { _ in RoundedRectangle(cornerRadius: 8).fill(fill).frame(height: 36) }
            }
        }
    }
    let label = Text(name.replacingOccurrences(of: ".png", with: "")).font(.caption2).foregroundStyle(.secondary)
    let shot = VStack(alignment: .leading, spacing: 14) {
        label
        Spacer()
        card.padding(16).background(paper, in: .rect(cornerRadius: 18)).shadow(radius: 4)
    }
    .padding(20).frame(width: mac ? 520 : 300, height: mac ? 340 : 600)
    .background(dark ? Color.black : Color(white: 0.96)).foregroundStyle(ink)
    let renderer = ImageRenderer(content: shot)
    renderer.scale = 2
    let image = try #require(renderer.cgImage)
    return try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
}

/// 会话发到手机的那张截图：改前、改后的登录页与点了忘记密码之后的页面（Cue 用读文件工具打开看）。
@MainActor
func loginShot() throws -> Data {
    func field(_ text: String) -> some View {
        Text(text).frame(width: 200, alignment: .leading).padding(8).overlay(RoundedRectangle(cornerRadius: 6).stroke(.gray))
    }
    func page(_ label: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(spacing: 12) {
            Text(label).font(.caption).foregroundStyle(.gray)
            content()
        }
        .padding(20).frame(width: 260, height: 300, alignment: .top).background(.white).overlay(RoundedRectangle(cornerRadius: 10).stroke(.gray))
    }
    func login(forgot: Bool) -> some View {
        VStack(spacing: 12) {
            Text("登录").font(.title2.bold())
            field("邮箱")
            field("密码")
            Text("登录").foregroundStyle(.white).frame(width: 216, height: 34).background(.blue, in: .rect(cornerRadius: 6))
            if forgot { Text("忘记密码？").foregroundStyle(.blue) }
        }
    }
    let shot = HStack(spacing: 20) {
        page("改前") { login(forgot: false) }
        page("改后") { login(forgot: true) }
        page("改后 · 点了忘记密码") {
            Text("重置密码").font(.title2.bold())
            field("you@example.com")
            Text("发送重置邮件").foregroundStyle(.white).frame(width: 216, height: 34).background(.blue, in: .rect(cornerRadius: 6))
            Text("如果这个邮箱注册过，你会收到一封邮件").font(.footnote).foregroundStyle(.green)
        }
    }
    .padding(20).background(Color(white: 0.95)).foregroundStyle(.black)
    let renderer = ImageRenderer(content: shot)
    renderer.scale = 2
    let image = try #require(renderer.cgImage)
    return try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
}
#endif
