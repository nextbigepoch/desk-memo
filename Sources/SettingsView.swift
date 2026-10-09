import AppKit
import SwiftUI
import ServiceManagement
import EventKit

struct SettingsView: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var store: MemoStore
    @ObservedObject var ui: UIState
    @ObservedObject var reminders: RemindersStore
    var moveToICloud: () -> Void

    var body: some View {
        TabView {
            AppearanceTab(settings: settings).tabItem { Text("样式") }
            LayoutTab(settings: settings, ui: ui).tabItem { Text("位置") }
            RemindersTab(settings: settings, reminders: reminders).tabItem { Text("提醒事项") }
            DataTab(settings: settings, store: store, moveToICloud: moveToICloud).tabItem { Text("数据") }
            GeneralTab(settings: settings).tabItem { Text("通用") }
        }
        .frame(width: 560, height: 640)
    }
}

private func hexBinding(_ b: Binding<String>) -> Binding<Color> {
    Binding(get: { Color(hex: b.wrappedValue) },
            set: { b.wrappedValue = NSColor($0).hexString })
}

private struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 1
    var format = "%.0f"
    var body: some View {
        LabeledContent(title) {
            HStack {
                Slider(value: $value, in: range, step: step)
                Text(String(format: format, value)).monospacedDigit().frame(width: 38, alignment: .trailing)
            }
        }
    }
}

// MARK: 样式

private struct AppearanceTab: View {
    @ObservedObject var settings: SettingsStore
    private static let families: [String] = NSFontManager.shared.availableFontFamilies
        .filter { !$0.hasPrefix(".") }.sorted()

    var body: some View {
        let t = $settings.value.theme
        Form {
            Section("预设") {
                Picker("样式预设", selection: Binding(
                    get: { settings.value.preset },
                    set: { settings.apply(preset: $0) })) {
                    ForEach(Presets.names, id: \.self) { Text($0).tag($0) }
                }
                Text("先选一个接近的预设，再在下面细调。所有改动立即生效。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("文字") {
                Picker("字体", selection: t.fontFamily) {
                    Text("系统字体（苹方）").tag("")
                    Divider()
                    ForEach(Self.families, id: \.self) { Text($0).tag($0) }
                }
                if settings.value.theme.fontFamily.isEmpty {
                    Picker("字形", selection: t.fontDesign) {
                        Text("标准").tag("default"); Text("圆体").tag("rounded")
                        Text("衬线").tag("serif"); Text("等宽").tag("monospaced")
                    }
                }
                SliderRow(title: "分类字号", value: t.groupSize, range: 12...40)
                SliderRow(title: "条目字号", value: t.itemSize, range: 10...30)
                Picker("分类粗细", selection: t.groupWeight) {
                    Text("细").tag("light"); Text("常规").tag("regular"); Text("中等").tag("medium")
                    Text("半粗").tag("semibold"); Text("粗").tag("bold"); Text("特粗").tag("heavy")
                }
                ColorPicker("文字颜色", selection: hexBinding(t.textColor), supportsOpacity: true)
                ColorPicker("次要文字颜色", selection: hexBinding(t.secondaryColor), supportsOpacity: true)
                Toggle("文字阴影（照片壁纸上更清楚）", isOn: t.textShadow)
            }

            Section("分类颜色") {
                Toggle("每个分类用不同颜色", isOn: t.colorfulGroups)
                if settings.value.theme.colorfulGroups {
                    HStack {
                        ForEach(settings.value.theme.groupColors.indices, id: \.self) { i in
                            ColorPicker("", selection: hexBinding(t.groupColors[i])).labelsHidden()
                        }
                    }
                    Text("按顺序给第 1、2、3… 个分类上色；也可以在条目上右键单独设颜色。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("树形结构") {
                Picker("条目符号", selection: t.bullet) {
                    Text("● 圆点").tag("dot"); Text("○ 圆圈").tag("ring"); Text("■ 方块").tag("square")
                    Text("◆ 菱形").tag("diamond"); Text("— 短横").tag("dash"); Text("› 箭头").tag("arrow")
                    Text("无").tag("none")
                }
                Toggle("分类名前也显示符号", isOn: t.groupBullet)
                Picker("待办勾选框", selection: t.checkbox) {
                    Text("圆形").tag("circle"); Text("方形").tag("square")
                }
                Toggle("显示层级连接线", isOn: t.guides)
                SliderRow(title: "缩进", value: t.indent, range: 8...48)
                SliderRow(title: "行间距", value: t.rowSpacing, range: 0...20)
                SliderRow(title: "分类间距", value: t.groupSpacing, range: 0...48)
                Picker("已完成的待办", selection: t.doneStyle) {
                    Text("划掉").tag("strike"); Text("变淡").tag("fade"); Text("隐藏").tag("hide")
                }
                Toggle("分类旁显示未完成数量", isOn: t.showCounts)
            }

            Section("背景") {
                Picker("背景", selection: t.background) {
                    Text("透明（直接叠在壁纸上）").tag("none"); Text("纯色").tag("color"); Text("毛玻璃").tag("blur")
                }
                if settings.value.theme.background != "none" {
                    ColorPicker("背景颜色", selection: hexBinding(t.backgroundColor))
                    SliderRow(title: "背景浓度", value: t.backgroundOpacity, range: 0...1, step: 0.01, format: "%.2f")
                    SliderRow(title: "圆角", value: t.cornerRadius, range: 0...40)
                }
                SliderRow(title: "内边距", value: t.padding, range: 4...48)
                SliderRow(title: "整体不透明度", value: t.opacity, range: 0.2...1, step: 0.01, format: "%.2f")
            }

            Section("标题") {
                Toggle("显示标题", isOn: t.showHeader)
                if settings.value.theme.showHeader {
                    TextField("标题文字", text: t.headerText)
                    Toggle("显示日期", isOn: t.showDate)
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: 位置

private struct LayoutTab: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var ui: UIState

    var body: some View {
        let l = $settings.value.layout
        Form {
            Section("位置") {
                Picker("停靠", selection: l.anchor) {
                    Text("左上").tag("topLeft"); Text("上方居中").tag("topCenter"); Text("正中").tag("center")
                    Text("右上").tag("topRight"); Text("自定义（拖动后）").tag("custom")
                }
                if NSScreen.screens.count > 1 {
                    Picker("显示器", selection: l.screen) {
                        Text("主显示器").tag("")
                        ForEach(NSScreen.screens, id: \.localizedName) { Text($0.localizedName).tag($0.localizedName) }
                    }
                }
                SliderRow(title: "宽度", value: l.width, range: 220...1400)
                SliderRow(title: "离屏幕边缘", value: l.margin, range: 0...200)
                Button("在桌面上拖动调整…") { ui.layoutMode = true }
                Text("也可以直接按住标题拖动。拖动后停靠方式自动变成「自定义」。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: 数据

private struct DataTab: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var store: MemoStore
    var moveToICloud: () -> Void

    private var inICloud: Bool { store.fileURL.path.contains("Mobile Documents/com~apple~CloudDocs") }

    var body: some View {
        Form {
            Section("备忘文件") {
                LabeledContent("状态") {
                    if let err = store.fileError {
                        Text("⚠️ 读取失败：\(err)").foregroundStyle(.orange)
                    } else if inICloud {
                        Text("✅ 存在 iCloud 云盘，手机上也能看")
                    } else {
                        Text("存在本机（手机上看不到）").foregroundStyle(.secondary)
                    }
                }
                if !inICloud || store.fileError != nil {
                    Button("改存到 iCloud 云盘…") { moveToICloud() }
                }
                LabeledContent("位置") {
                    Text(store.fileURL.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .textSelection(.enabled).lineLimit(3).font(.callout)
                }
                HStack {
                    Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([store.fileURL]) }
                    Button("用其他编辑器打开") { NSWorkspace.shared.open(store.fileURL) }
                    Button("换一个文件…") { choose() }
                }
                Text("""
                内容保存成普通 Markdown 文件，默认在 iCloud 云盘「桌面备忘」文件夹，手机「文件」App 里也能看。
                用别的编辑器改了也会自动刷新。格式：
                - 分类
                  - [ ] 待办 @10-15      ← @月-日 会显示倒计时
                  - [x] 已完成
                  - 普通文字
                """)
                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Section("备份") {
                Text("每天第一次启动会自动备份一份，保留最近 30 天。")
                    .font(.caption).foregroundStyle(.secondary)
                Button("打开备份文件夹") {
                    NSWorkspace.shared.open(AppPaths.support.appendingPathComponent("backups"))
                }
            }
            Section("样式文件") {
                Text("所有样式设置也保存在一个 JSON 文件里，可以直接改，保存后自动生效。")
                    .font(.caption).foregroundStyle(.secondary)
                Button("打开样式文件") { NSWorkspace.shared.open(AppPaths.settings) }
            }
        }
        .formStyle(.grouped)
    }

    private func choose() {
        let p = NSSavePanel()
        p.allowedContentTypes = [.init(filenameExtension: "md")!]
        p.nameFieldStringValue = "备忘.md"
        p.message = "选一个已有的 .md 文件，或新建一个"
        p.directoryURL = store.fileURL.deletingLastPathComponent()
        if p.runModal() == .OK, let url = p.url {
            settings.value.memoFile = url.path
            store.switchFile(to: url)
        }
    }
}

// MARK: 提醒事项

private struct RemindersTab: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var reminders: RemindersStore

    var body: some View {
        Form {
            Section {
                Toggle("在桌面上显示「提醒事项」", isOn: $settings.value.reminders.enabled)
                LabeledContent("权限") {
                    switch reminders.status {
                    case .fullAccess:
                        Text("✅ 已允许")
                    case .notDetermined:
                        Button("允许读取提醒事项") { reminders.requestAccess() }
                    default:
                        VStack(alignment: .trailing, spacing: 4) {
                            Text("⚠️ 没有权限").foregroundStyle(.orange)
                            Button("打开系统设置") { AppDelegate.openPrivacy("Privacy_Reminders") }
                        }
                    }
                }
            } footer: {
                Text("""
                和手机上的「提醒事项」是同一份数据：在桌面上勾选、改字、新建、删除，都会同步到 iPhone；用 Siri 说「提醒我……」加的事项也会出现在这里。
                • 列表名和桌面上的分类同名（比如都叫「财务」），提醒会自动并到那个分类下面
                • 其余列表各自显示成一个分类
                • 在提醒里写 @10-15 就是设截止日期
                """)
                .font(.caption).foregroundStyle(.secondary)
            }

            if reminders.granted && settings.value.reminders.enabled {
                Section("显示哪些列表") {
                    ForEach(reminders.lists, id: \.calendarIdentifier) { cal in
                        Toggle(isOn: Binding(
                            get: { !settings.value.reminders.hiddenLists.contains(cal.calendarIdentifier) },
                            set: { reminders.setHidden(cal.calendarIdentifier, !$0) })) {
                            HStack(spacing: 6) {
                                Circle().fill(Color(nsColor: cal.color ?? .gray)).frame(width: 9, height: 9)
                                Text(cal.title)
                                let n = (reminders.byList[cal.calendarIdentifier] ?? []).filter { !$0.isCompleted }.count
                                if n > 0 { Text("\(n)").foregroundStyle(.secondary) }
                            }
                        }
                    }
                    if reminders.lists.isEmpty {
                        Text("还没有读到任何列表").foregroundStyle(.secondary)
                    }
                }
                Section {
                    Toggle("提醒事项的条目后面显示小铃铛", isOn: $settings.value.reminders.showIcon)
                    Button("立即刷新") { reminders.reload() }
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: 通用

private struct GeneralTab: View {
    @ObservedObject var settings: SettingsStore
    @State private var login = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Section {
                Toggle("开机自动启动", isOn: Binding(get: { login }, set: { on in
                    try? on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
                    settings.value.launchAtLogin = on
                    login = SMAppService.mainApp.status == .enabled
                }))
            }
            Section("快捷键") {
                shortcut("⌃⌥M", "随时把备忘叫到最前面编辑；再按一次或 Esc 放回桌面")
                shortcut("回车", "新建下一条（光标在中间会拆成两条）")
                shortcut("Tab / ⇧Tab", "缩进成子项 / 提升一级")
                shortcut("↑ / ↓", "切换到上一条 / 下一条")
                shortcut("⌘↩", "勾选 / 取消完成")
                shortcut("⌘⇧↑ / ⌘⇧↓", "上移 / 下移")
                shortcut("⌘T", "在「待办」和「普通文字」之间切换")
                shortcut("⌘Z", "撤销（不在编辑文字时，撤销结构上的改动）")
                shortcut("空行按退格", "删除这一条")
                shortcut("Esc", "结束编辑")
                shortcut("右键", "颜色、折叠、移动、删除")
            }
        }
        .formStyle(.grouped)
    }

    private func shortcut(_ k: String, _ d: String) -> some View {
        LabeledContent { Text(d).foregroundStyle(.secondary) } label: { Text(k).monospaced() }
    }
}
