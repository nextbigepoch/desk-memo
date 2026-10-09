import AppKit
import SwiftUI
import Combine

enum AppPaths {
    static let support: URL = {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DeskMemo", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()
    static let settings = support.appendingPathComponent("settings.json")

    /// 默认放 iCloud 云盘，手机「文件」App 里也能看到；没开 iCloud 云盘就放「文稿」。
    static var defaultMemoFile: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let icloud = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        let base = FileManager.default.fileExists(atPath: icloud.path)
            ? icloud : home.appendingPathComponent("Documents", isDirectory: true)
        return base.appendingPathComponent("桌面备忘/备忘.md")
    }
}

// MARK: - 样式

struct Theme: Codable, Equatable {
    // 文字
    var fontFamily = ""              // 空 = 系统字体（苹方）
    var fontDesign = "default"       // default / rounded / serif / monospaced
    var groupSize = 20.0
    var itemSize = 14.0
    var groupWeight = "semibold"     // light / regular / medium / semibold / bold / heavy
    var textColor = "#FFFFFF"
    var secondaryColor = "#FFFFFFA6"
    var textShadow = true

    // 分类颜色
    var colorfulGroups = true
    var groupColors = ["#FFD60A", "#64D2FF", "#FF9F0A", "#30D158", "#BF5AF2", "#FF6482"]

    // 树形
    var bullet = "dot"               // dot / ring / square / diamond / dash / arrow / none
    var groupBullet = false          // 顶层分类前是否也画符号
    var checkbox = "circle"          // circle / square
    var guides = false               // 层级连接线
    var indent = 20.0
    var rowSpacing = 5.0
    var groupSpacing = 16.0
    var doneStyle = "strike"         // strike / fade / hide
    var showCounts = true            // 分类旁显示未完成数量

    // 背景
    var background = "none"          // none / color / blur
    var backgroundColor = "#000000"
    var backgroundOpacity = 0.3
    var cornerRadius = 16.0
    var padding = 18.0
    var opacity = 1.0

    // 标题
    var showHeader = true
    var headerText = "桌面备忘"
    var showDate = true
}

struct Layout: Codable, Equatable {
    var anchor = "topLeft"           // topLeft / topCenter / center / topRight / custom
    var x = 0.0                      // custom 时窗口左上角（全局坐标）
    var y = 0.0
    var width = 380.0
    var margin = 48.0
    var screen = ""                  // 显示器名称，空 = 主显示器
}

struct RemindersConfig: Codable, Equatable {
    var enabled = true
    var hiddenLists: [String] = []      // 不在桌面显示的列表
    var collapsedLists: [String] = []
    var showIcon = true                 // 来自提醒事项的条目后面显示小铃铛
}

struct AppSettings: Codable, Equatable {
    var theme = Theme()
    var layout = Layout()
    var preset = "极简白字"
    var memoFile = ""
    var iCloudFallback = false          // iCloud 云盘没权限，临时存在本机
    var launchAtLoginAsked = false
    var launchAtLogin = true            // 开机自动启动；每次启动都会检查一遍
    var reminders = RemindersConfig()
}

enum Presets {
    static let names = ["极简白字", "毛玻璃卡片", "便签纸", "杂志衬线", "深色终端"]

    static func theme(_ name: String) -> Theme {
        var t = Theme()
        switch name {
        case "毛玻璃卡片":
            t.background = "blur"; t.backgroundOpacity = 0.12; t.textShadow = false
            t.bullet = "ring"; t.cornerRadius = 20; t.padding = 22
        case "便签纸":
            t.background = "color"; t.backgroundColor = "#FFF3A3"; t.backgroundOpacity = 0.96
            t.textColor = "#3B3420"; t.secondaryColor = "#3B342099"; t.textShadow = false
            t.groupColors = ["#B4541A", "#1F6AA8", "#2F7D32", "#8B3DB0", "#C0352B", "#5D4037"]
            t.fontDesign = "rounded"; t.bullet = "dash"; t.checkbox = "square"; t.cornerRadius = 4
        case "杂志衬线":
            t.fontDesign = "serif"; t.groupSize = 26; t.itemSize = 15; t.groupWeight = "bold"
            t.bullet = "diamond"; t.guides = true; t.colorfulGroups = false; t.groupSpacing = 22
        case "深色终端":
            t.fontDesign = "monospaced"; t.textColor = "#9AF5A8"; t.secondaryColor = "#9AF5A899"
            t.background = "color"; t.backgroundColor = "#0B0F0C"; t.backgroundOpacity = 0.75
            t.textShadow = false; t.bullet = "arrow"; t.checkbox = "square"; t.guides = true
            t.colorfulGroups = false; t.groupSize = 16; t.itemSize = 13; t.groupWeight = "bold"
            t.cornerRadius = 8
        default: break
        }
        return t
    }
}

// MARK: - 存储（JSON，可以手改，改完自动生效）

final class SettingsStore: ObservableObject {
    @Published var value: AppSettings {
        didSet { if value != oldValue { scheduleSave() } }
    }
    private var saveWork: DispatchWorkItem?
    private var lastMTime: Date?
    private var timer: Timer?

    init() {
        value = Self.read() ?? AppSettings()
        lastMTime = Self.mtime()
        if !FileManager.default.fileExists(atPath: AppPaths.settings.path) { saveNow() }
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in self?.reloadIfEdited() }
    }

    var memoFileURL: URL {
        if let env = ProcessInfo.processInfo.environment["DESKMEMO_FILE"] { return URL(fileURLWithPath: env) }
        return value.memoFile.isEmpty ? AppPaths.defaultMemoFile : URL(fileURLWithPath: value.memoFile)
    }

    /// 文件读写不了（比如拒绝了 iCloud 云盘访问）就改存到「应用支持」目录，保证能用。
    func usableMemoFileURL() -> URL {
        let url = memoFileURL
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !fm.fileExists(atPath: url.path) {
                try Markdown.seed.write(to: url, atomically: true, encoding: .utf8)
            }
            _ = try String(contentsOf: url, encoding: .utf8)
            return url
        } catch {
            NSLog("DeskMemo: cannot use \(url.path): \(error)")
            let fallback = AppPaths.support.appendingPathComponent("备忘.md")
            if ProcessInfo.processInfo.environment["DESKMEMO_FILE"] == nil {
                value.memoFile = fallback.path
                value.iCloudFallback = true
            }
            return fallback
        }
    }

    private static func mtime() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: AppPaths.settings.path))?[.modificationDate] as? Date
    }

    /// 宽松读取：JSON 里缺的字段用默认值补上，手改漏了字段也不会坏。
    private static func read() -> AppSettings? {
        guard let data = try? Data(contentsOf: AppPaths.settings),
              let user = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let base = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(AppSettings())) as? [String: Any]
        else { return nil }
        func merge(_ a: [String: Any], _ b: [String: Any]) -> [String: Any] {
            var r = a
            for (k, v) in b {
                if let av = a[k] as? [String: Any], let bv = v as? [String: Any] { r[k] = merge(av, bv) }
                else if a[k] != nil { r[k] = v }
            }
            return r
        }
        guard let merged = try? JSONSerialization.data(withJSONObject: merge(base, user)) else { return nil }
        return try? JSONDecoder().decode(AppSettings.self, from: merged)
    }

    private func reloadIfEdited() {
        guard saveWork == nil, let m = Self.mtime(), m != lastMTime else { return }
        lastMTime = m
        if let v = Self.read(), v != value { value = v; saveWork?.cancel(); saveWork = nil }
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: w)
    }

    func saveNow() {
        saveWork?.cancel()
        saveWork = nil
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        if let data = try? enc.encode(value) {
            try? data.write(to: AppPaths.settings, options: .atomic)
            lastMTime = Self.mtime()
        }
    }

    func apply(preset: String) {
        value.preset = preset
        // 换样式时保留自己改过的标题
        let title = value.theme.headerText
        value.theme = Presets.theme(preset)
        value.theme.headerText = title
    }
}

// MARK: - 颜色 / 字体工具

extension NSColor {
    convenience init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        let r, g, b, a: Double
        if s.count == 8 {
            r = Double((v >> 24) & 0xFF); g = Double((v >> 16) & 0xFF); b = Double((v >> 8) & 0xFF); a = Double(v & 0xFF)
        } else {
            r = Double((v >> 16) & 0xFF); g = Double((v >> 8) & 0xFF); b = Double(v & 0xFF); a = 255
        }
        self.init(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a / 255)
    }

    var hexString: String {
        let c = usingColorSpace(.sRGB) ?? self
        let r = Int(round(c.redComponent * 255)), g = Int(round(c.greenComponent * 255)), b = Int(round(c.blueComponent * 255))
        let a = Int(round(c.alphaComponent * 255))
        return a >= 255 ? String(format: "#%02X%02X%02X", r, g, b) : String(format: "#%02X%02X%02X%02X", r, g, b, a)
    }

    var isLight: Bool {
        let c = usingColorSpace(.sRGB) ?? self
        return 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent > 0.6
    }
}

extension Color {
    init(hex: String) { self.init(nsColor: NSColor(hex: hex)) }
}

/// 节点右键可选的颜色
let namedColors: [(name: String, key: String, hex: String)] = [
    ("红", "red", "#FF453A"), ("橙", "orange", "#FF9F0A"), ("黄", "yellow", "#FFD60A"),
    ("绿", "green", "#30D158"), ("蓝", "blue", "#0A84FF"), ("紫", "purple", "#BF5AF2"), ("灰", "gray", "#8E8E93"),
]

func resolveColor(_ key: String) -> String {
    namedColors.first { $0.key == key }?.hex ?? key
}

extension Theme {
    private var design: Font.Design {
        switch fontDesign {
        case "rounded": return .rounded
        case "serif": return .serif
        case "monospaced": return .monospaced
        default: return .default
        }
    }

    static func weight(_ s: String) -> Font.Weight {
        switch s {
        case "light": return .light
        case "regular": return .regular
        case "medium": return .medium
        case "bold": return .bold
        case "heavy": return .heavy
        default: return .semibold
        }
    }

    func font(size: Double, weight: Font.Weight) -> Font {
        if !fontFamily.isEmpty { return .custom(fontFamily, size: size).weight(weight) }
        return .system(size: size, weight: weight, design: design)
    }

    func nsFont(size: Double, weight: String) -> NSFont {
        let w: NSFont.Weight
        let fmWeight: Int
        switch weight {
        case "light": w = .light; fmWeight = 3
        case "medium": w = .medium; fmWeight = 6
        case "semibold": w = .semibold; fmWeight = 8
        case "bold": w = .bold; fmWeight = 9
        case "heavy": w = .heavy; fmWeight = 11
        default: w = .regular; fmWeight = 5
        }
        if !fontFamily.isEmpty,
           let f = NSFontManager.shared.font(withFamily: fontFamily, traits: [], weight: fmWeight, size: size) {
            return f
        }
        let base = NSFont.systemFont(ofSize: size, weight: w)
        let d: NSFontDescriptor.SystemDesign
        switch fontDesign {
        case "rounded": d = .rounded
        case "serif": d = .serif
        case "monospaced": d = .monospaced
        default: return base
        }
        if let desc = base.fontDescriptor.withDesign(d), let f = NSFont(descriptor: desc, size: size) { return f }
        return base
    }

    func groupColor(_ branch: Int, override: String?) -> Color {
        if let o = override { return Color(hex: resolveColor(o)) }
        guard colorfulGroups, !groupColors.isEmpty else { return Color(hex: textColor) }
        return Color(hex: groupColors[branch % groupColors.count])
    }
}
