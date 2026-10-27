#if DEBUG
import SwiftUI

/// 演示库里会话发来、Cue 点名给你看的截图与报告：每张都画的是它说明里那件事（预发上的发言顺序就是 6 个人的顺序、测试报告就是那几条用例），
/// 内容铺满整张、要看的在上半截（缩略图怎么裁都看得到），不留像截坏了的空白与灰条。
extension DebugScene {
    /// 圆桌预发环境上一场 6 人房间的发言顺序（`deployShots`：推送那条"等你"）：按首次加入时间排，重连过的人还在原位。
    static func stagingOrderPNG() -> Data {
        let people: [(name: String, note: String?, joined: String, tint: Color)] = [
            (String(localized: "小林", table: "Demo"), String(localized: "主持人", table: "Demo"), "20:01", .orange), (String(localized: "阿杰", table: "Demo"), nil, "20:02", .teal), ("Mia", nil, "20:02", .pink),
            (String(localized: "老王", table: "Demo"), String(localized: "重连过 · 位置没变", table: "Demo"), "20:03", .indigo), ("Sora", nil, "20:05", .green), ("Kai", nil, "20:06", .brown),
        ]
        let view = VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text("预发", tableName: "Demo").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                    .padding(.horizontal, 7).padding(.vertical, 3).background(.orange, in: .capsule)
                Text("staging-2.roundtable.app").font(.system(size: 11)).foregroundStyle(.gray)
            }
            .padding(.top, 46)
            Text("周会 · 发言顺序", tableName: "Demo").font(.system(size: 24, weight: .bold)).padding(.top, 14)
            Text("6 人 · 按首次加入时间排", tableName: "Demo").font(.system(size: 12)).foregroundStyle(.gray).padding(.top, 4)
            // 6 行落在正中那一块：缩略图裁成方的也是完整的 6 个人
            VStack(spacing: 6) {
                ForEach(Array(people.enumerated()), id: \.offset) { index, person in
                    HStack(spacing: 10) {
                        Text("\(index + 1)").font(.system(size: 13, weight: .bold).monospacedDigit()).foregroundStyle(.gray).frame(width: 14)
                        Circle().fill(person.tint.opacity(0.8)).frame(width: 30, height: 30)
                            .overlay { Text(person.name.prefix(1)).font(.system(size: 13, weight: .bold)).foregroundStyle(.white) }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(person.name).font(.system(size: 15, weight: .semibold))
                            if let note = person.note { Text(note).font(.system(size: 11)).foregroundStyle(index == 0 ? .orange : .indigo) }
                        }
                        Spacer()
                        Text("\(person.joined) 加入", tableName: "Demo").font(.system(size: 11).monospacedDigit()).foregroundStyle(.gray)
                    }
                    .padding(.horizontal, 12).frame(height: 44)
                    .background(.white, in: .rect(cornerRadius: Radius.block))
                }
            }
            .padding(.top, 20)
            Spacer(minLength: 16)
            Text("轮到小林发言", tableName: "Demo").font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                .frame(maxWidth: .infinity).frame(height: 48).background(Color.indigo, in: .capsule)
        }
        .padding(20).frame(width: 320, height: 640).background(Color(white: 0.95)).foregroundStyle(.black)
        return render(view)
    }

    /// 重连用例的测试报告（PDF，一页）：与"等你"正文里那段输出同样四条，都过了。
    static func reconnectReportPDF() -> Data {
        let cases = [(String(localized: "重连后保留首次加入时间", table: "Demo"), "0.21s"), (String(localized: "6 人同时重连顺序不变", table: "Demo"), "0.48s"), (String(localized: "断线超过 5 分钟按新人排", table: "Demo"), "0.12s"), (String(localized: "主持人重连仍在第一位", table: "Demo"), "0.09s")]
        let page = VStack(alignment: .leading, spacing: 0) {
            Text("重连测试报告", tableName: "Demo").font(.system(size: 30, weight: .bold))
            HStack(spacing: 10) {
                Text("4 / 4 通过", tableName: "Demo").font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 6).background(Color.green, in: .capsule)
                Text("scheduler · 预发 staging-2", tableName: "Demo").font(.system(size: 13)).foregroundStyle(.gray)
            }
            .padding(.top, 10)
            VStack(spacing: 0) {
                ForEach(cases, id: \.0) { name, took in
                    HStack {
                        Circle().fill(.green).frame(width: 18, height: 18).overlay { Text("✓").font(.system(size: 11, weight: .bold)).foregroundStyle(.white) }
                        Text(name).font(.system(size: 17))
                        Spacer()
                        Text(took).font(.system(size: 15).monospacedDigit()).foregroundStyle(.gray)
                    }
                    .frame(height: 56)
                    Divider()
                }
            }
            .padding(.top, 24)
            Text("$ swift test --filter Reconnect\nExecuted 4 tests, with 0 failures (0.90s)").font(.system(size: 14).monospaced()).foregroundStyle(.gray).padding(.top, 20)
            Spacer()
        }
        .padding(48).frame(width: 600, height: 560).background(.white).foregroundStyle(.black)
        return pdf(page)
    }

    /// 三档价格对比表（PDF，两页）：定价区那件的会话发来的一份。
    static func pricingPDF() -> Data {
        let page = VStack(alignment: .leading, spacing: 12) {
            Text("定价对比", tableName: "Demo").font(.system(size: 28, weight: .bold))
            ForEach([String(localized: "基础 · ¥0 · 3 个项目", table: "Demo"), String(localized: "专业 · ¥68 · 不限项目", table: "Demo"), String(localized: "团队 · ¥198 · 10 人协作", table: "Demo")], id: \.self) { line in
                Text(line).font(.system(size: 16))
                Divider()
            }
            Spacer()
        }
        .padding(48).frame(width: 595, height: 842).background(.white)
        return pdf(page, pages: 2)
    }

    /// 新版 App 的样子（一扇窗：侧栏、Cue 的对话），你交给 Cue 换 README 截图时贴的参考图。
    static func appShotPNG() -> Data { render(appWindow.padding(24).frame(width: 640, height: 420).background(Color(red: 0.86, green: 0.88, blue: 0.93))) }

    /// 换好的 README（浅色）：项目名、一句话、徽章，下面是新截图（与参考图同一扇窗）。方的：缩略图裁成方的也是整张。
    static func readmePNG() -> Data {
        let view = VStack(spacing: 10) {
            Text("CuePad").font(.system(size: 30, weight: .bold))
            Text("记灵感、管任务、指挥 Agent 的原生 App", tableName: "Demo").font(.system(size: 15)).foregroundStyle(.gray)
            HStack(spacing: 6) {
                ForEach(["macOS · iOS · iPadOS", "Swift 6", "MIT"], id: \.self) { badge in
                    Text(badge).font(.system(size: 11, weight: .medium)).padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Color(white: 0.92), in: .capsule)
                }
            }
            appWindow.padding(.top, 14)
        }
        .padding(28).frame(width: 560, height: 560).background(.white).foregroundStyle(.black)
        return render(view)
    }

    /// 截图里的那扇窗：左边侧栏（Cue 与几个项目），右边一段对话。
    private static var appWindow: some View {
        let paper = Color(red: 0.99, green: 0.985, blue: 0.97), desk = Color(red: 0.93, green: 0.92, blue: 0.9)
        return HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 5) { ForEach([Color.red, .yellow, .green], id: \.self) { Circle().fill($0.opacity(0.8)).frame(width: 9) } }
                HStack(spacing: 6) {
                    Circle().fill(.white).frame(width: 24).overlay { Circle().stroke(Color(red: 0.55, green: 0.42, blue: 0.1), lineWidth: 2) }
                    Text("Cue").font(.system(size: 13, weight: .semibold))
                }
                .padding(.top, 6)
                ForEach([(String(localized: "圆桌", table: "Demo"), Color.orange), ("Flow", .teal), ("CuePad", .purple), (String(localized: "读书", table: "Demo"), .pink)], id: \.0) { name, tint in
                    HStack(spacing: 6) { RoundedRectangle(cornerRadius: Radius.chip).fill(tint).frame(width: 9, height: 9); Text(name).font(.system(size: 11)) }
                }
                Spacer()
            }
            .padding(12).frame(width: 130, alignment: .leading).background(Color(red: 0.89, green: 0.88, blue: 0.86))
            VStack(alignment: .leading, spacing: 8) {
                Text("圆桌那个乱序交给你", tableName: "Demo").font(.system(size: 11)).padding(8).background(Color(red: 0.88, green: 0.85, blue: 0.8), in: .rect(cornerRadius: Radius.block))
                    .frame(maxWidth: .infinity, alignment: .trailing)
                Text("好。拆成四步：复现、改排序、补用例、部署到预发。", tableName: "Demo").font(.system(size: 11)).padding(8).background(paper, in: .rect(cornerRadius: Radius.block))
                Text("「README 截图换成 Swift 版」做完了", tableName: "Demo").font(.system(size: 11, weight: .semibold)).padding(8).background(paper, in: .rect(cornerRadius: Radius.block))
                Spacer()
                Capsule().fill(paper).frame(height: 26).overlay(alignment: .leading) { Text("对 Cue 说", tableName: "Demo").font(.system(size: 10)).foregroundStyle(.gray).padding(.leading, 10) }
            }
            .padding(12).frame(maxWidth: .infinity).background(desk)
        }
        .frame(height: 300).clipShape(.rect(cornerRadius: Radius.block)).foregroundStyle(.black)
        .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
    }

    /// 登录回调超时修好后的样子（流程演示里做完的那件）：等授权超过 10 秒，回到登录页并说明原因。
    static func loginTimeoutPNG() -> Data {
        let view = VStack(alignment: .leading, spacing: 14) {
            Text("登录", tableName: "Demo").font(.system(size: 30, weight: .bold)).padding(.top, 60)
            HStack(alignment: .top, spacing: 8) {
                Circle().fill(.orange).frame(width: 18, height: 18).overlay { Text("!").font(.system(size: 12, weight: .bold)).foregroundStyle(.white) }
                VStack(alignment: .leading, spacing: 3) {
                    Text("登录超时，请重新登录", tableName: "Demo").font(.system(size: 14, weight: .semibold))
                    Text("等待授权超过 10 秒，已停止等待", tableName: "Demo").font(.system(size: 12)).foregroundStyle(.gray)
                }
            }
            .padding(12).frame(maxWidth: .infinity, alignment: .leading).background(Color.orange.opacity(0.12), in: .rect(cornerRadius: Radius.block))
            loginFields()
            Spacer()
            Text("使用其他方式登录", tableName: "Demo").font(.system(size: 13)).foregroundStyle(.indigo).frame(maxWidth: .infinity)
        }
        .padding(24).frame(width: 320, height: 640).background(.white).foregroundStyle(.black)
        return render(view)
    }

    /// 手机登录页的截图：`covered` 时键盘挡住了登录钮。
    static func phonePNG(covered: Bool) -> Data {
        let view = ZStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 14) {
                Text("登录", tableName: "Demo").font(.system(size: 30, weight: .bold)).padding(.top, 70)
                loginFields(buttonGap: covered ? 150 : 0)
                Spacer()
            }
            .padding(24)
            keyboard
        }
        .frame(width: 320, height: 640).background(.white).foregroundStyle(.black)
        return render(view)
    }

    private static func loginFields(buttonGap: CGFloat = 0) -> some View {
        VStack(spacing: 14) {
            ForEach([String(localized: "邮箱", table: "Demo"), String(localized: "密码", table: "Demo")], id: \.self) { field in
                RoundedRectangle(cornerRadius: Radius.block).stroke(.gray.opacity(0.4)).frame(height: 46)
                    .overlay(alignment: .leading) { Text(field).foregroundStyle(.gray).padding(.leading, 12) }
            }
            RoundedRectangle(cornerRadius: Radius.block).fill(.indigo).frame(height: 48)
                .overlay { Text("登录", tableName: "Demo").foregroundStyle(.white).bold() }
                .padding(.top, buttonGap)
        }
    }

    /// 系统键盘的样子（三排字母键与空格），一眼看得出是键盘而不是截坏的灰条。
    private static var keyboard: some View {
        VStack(spacing: 10) {
            ForEach(["QWERTYUIOP", "ASDFGHJKL", "ZXCVBNM"], id: \.self) { row in
                HStack(spacing: 5) {
                    ForEach(row.map(String.init), id: \.self) { key in
                        Text(key).font(.system(size: 13)).frame(width: 26, height: 38).background(.white, in: .rect(cornerRadius: Radius.chip))
                    }
                }
            }
            HStack(spacing: 5) {
                RoundedRectangle(cornerRadius: Radius.chip).fill(Color(white: 0.7)).frame(width: 60, height: 38)
                Text("空格", tableName: "Demo").font(.system(size: 13)).frame(maxWidth: .infinity).frame(height: 38).background(.white, in: .rect(cornerRadius: Radius.chip))
                Text("登录", tableName: "Demo").font(.system(size: 13)).frame(width: 60, height: 38).background(Color(white: 0.7), in: .rect(cornerRadius: Radius.chip))
            }
            .padding(.horizontal, 6)
        }
        .padding(.vertical, 10).frame(maxWidth: .infinity).frame(height: 230).background(Color(white: 0.82))
    }

    static func widePNG() -> Data {
        let view = HStack(spacing: 16) {
            ForEach([String(localized: "基础", table: "Demo"), String(localized: "专业", table: "Demo"), String(localized: "团队", table: "Demo")], id: \.self) { tier in
                VStack(spacing: 10) {
                    Text(tier).font(.title3.bold())
                    Text(tier == String(localized: "专业", table: "Demo") ? "¥68" : tier == String(localized: "基础", table: "Demo") ? "¥0" : "¥198").font(.system(size: 34, weight: .heavy))
                    RoundedRectangle(cornerRadius: Radius.block).fill(tier == String(localized: "专业", table: "Demo") ? .indigo : .gray.opacity(0.3)).frame(height: 34)
                }
                .padding(18).frame(maxWidth: .infinity).background(.white, in: .rect(cornerRadius: Radius.card))
            }
        }
        .padding(28).frame(width: 640, height: 360).background(Color(red: 0.93, green: 0.94, blue: 0.99))
        return render(view)
    }

    static func render(_ view: some View) -> Data {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        return renderer.cgImage.map { DemoLibrary.encode($0) } ?? Data()
    }

    private static func pdf(_ page: some View, pages: Int = 1) -> Data {
        let data = NSMutableData()
        let renderer = ImageRenderer(content: page)
        renderer.render { size, draw in
            var box = CGRect(origin: .zero, size: size)
            guard let consumer = CGDataConsumer(data: data), let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { return }
            for _ in 0..<pages {
                context.beginPDFPage(nil)
                draw(context)
                context.endPDFPage()
            }
            context.closePDF()
        }
        return data as Data
    }
}
#endif
