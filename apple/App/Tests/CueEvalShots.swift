#if os(macOS)
import AppKit
import CueStore
import Foundation
import SwiftUI
import Testing
@testable import CuePad

@MainActor
func mockShot(_ name: String) throws -> Data {
    let dark = name.contains("dark"), mac = name.contains("mac")
    let ink: Color = dark ? .white : .black, paper: Color = dark ? Color(white: 0.16) : .white, fill: Color = dark ? Color(white: 0.28) : Color(white: 0.92)
    @ViewBuilder var card: some View {
        if ["plan-", "wip-", "final-"].contains(where: name.hasPrefix) {
            VStack(alignment: .leading, spacing: 8) {
                Text("项目").font(.caption).foregroundStyle(.secondary)
                ForEach([("圆桌", 3), ("CuePad", 2), ("个人网站", 0)], id: \.0) { project, running in
                    HStack {
                        Circle().fill(running > 0 ? Color.green : fill).frame(width: 8, height: 8)
                        Text(project).font(.callout).foregroundStyle(ink)
                        Spacer()
                        if running > 0 { Text("\(running) 个会话在跑").font(.caption).foregroundStyle(.secondary) }
                    }
                    .padding(8).background(fill, in: .rect(cornerRadius: Radius.block))
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Text(name).font(.headline)
                ForEach(0..<4) { _ in RoundedRectangle(cornerRadius: Radius.block).fill(fill).frame(height: 36) }
            }
        }
    }
    let label = Text(name.replacingOccurrences(of: ".png", with: "")).font(.caption2).foregroundStyle(.secondary)
    let shot = VStack(alignment: .leading, spacing: 14) {
        label
        Spacer()
        card.padding(16).background(paper, in: .rect(cornerRadius: Radius.card)).shadow(radius: 4)
    }
    .padding(20).frame(width: mac ? 520 : 300, height: mac ? 340 : 600)
    .background(dark ? Color.black : Color(white: 0.96)).foregroundStyle(ink)
    return try png(shot)
}

@MainActor
func png(_ view: some View) throws -> Data {
    let renderer = ImageRenderer(content: view)
    renderer.scale = 2
    let image = try #require(renderer.cgImage)
    return try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
}

@MainActor
func loginShot() throws -> Data {
    func field(_ text: String) -> some View {
        Text(text).frame(width: 200, alignment: .leading).padding(8).overlay(RoundedRectangle(cornerRadius: Radius.chip).stroke(.gray))
    }
    func page(_ label: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(spacing: 12) {
            Text(label).font(.caption).foregroundStyle(.gray)
            content()
        }
        .padding(20).frame(width: 260, height: 300, alignment: .top).background(.white).overlay(RoundedRectangle(cornerRadius: Radius.block).stroke(.gray))
    }
    func login(forgot: Bool) -> some View {
        VStack(spacing: 12) {
            Text("登录").font(.title2.bold())
            field("邮箱")
            field("密码")
            Text("登录").foregroundStyle(.white).frame(width: 216, height: 34).background(.blue, in: .rect(cornerRadius: Radius.chip))
            if forgot { Text("忘记密码？").foregroundStyle(.blue) }
        }
    }
    let shot = HStack(spacing: 20) {
        page("改前") { login(forgot: false) }
        page("改后") { login(forgot: true) }
        page("改后 · 点了忘记密码") {
            Text("重置密码").font(.title2.bold())
            field("you@example.com")
            Text("发送重置邮件").foregroundStyle(.white).frame(width: 216, height: 34).background(.blue, in: .rect(cornerRadius: Radius.chip))
            Text("如果这个邮箱注册过，你会收到一封邮件").font(.footnote).foregroundStyle(.green)
        }
    }
    .padding(20).background(Color(white: 0.95)).foregroundStyle(.black)
    return try png(shot)
}

@MainActor
func pageShot(_ title: String, _ lines: [String]) throws -> Data {
    let page = VStack(alignment: .leading, spacing: 10) {
        Text(title).font(.title2.bold())
        ForEach(lines, id: \.self) { Text($0).font(.body.monospaced()) }
    }
    .padding(24).frame(width: 640, alignment: .leading).background(.white).foregroundStyle(.black)
    return try png(page)
}
#endif
