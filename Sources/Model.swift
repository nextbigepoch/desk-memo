import Foundation

// 一个树节点。整棵树以 Markdown 列表保存在磁盘上，任何编辑器都能改。
struct Node: Identifiable, Equatable {
    var id = UUID()
    var text: String
    var isTask = false
    var done = false
    var collapsed = false
    var color: String? = nil
    var children: [Node] = []
    var kind: NodeKind = .memo

    var isMemo: Bool { kind == .memo }

    var openTaskCount: Int {
        children.reduce(0) { $0 + ($1.isTask && !$1.done ? 1 : 0) + $1.openTaskCount }
    }
}

/// 节点来源：自己的备忘树，或者来自「提醒事项」
enum NodeKind: Equatable {
    case memo
    case reminder(String)   // calendarItemIdentifier
    case pending(String)    // 正在新建、还没存进提醒事项的条目；值是列表 id
    case list(String)       // 提醒事项的列表（显示成一个分类）
}

extension Array where Element == Node {
    func path(of id: UUID) -> [Int]? {
        for (i, n) in enumerated() {
            if n.id == id { return [i] }
            if let p = n.children.path(of: id) { return [i] + p }
        }
        return nil
    }

    subscript(path path: [Int]) -> Node {
        get { path.count == 1 ? self[path[0]] : self[path[0]].children[path: [Int](path.dropFirst())] }
        set {
            if path.count == 1 { self[path[0]] = newValue }
            else { self[path[0]].children[path: [Int](path.dropFirst())] = newValue }
        }
    }

    /// 修改某个父节点下的子列表；parent 为空表示根列表。
    mutating func withList<R>(_ parent: [Int], _ body: (inout [Node]) -> R) -> R {
        if parent.isEmpty { return body(&self) }
        return self[parent[0]].children.withList([Int](parent.dropFirst()), body)
    }

    func removingDone() -> [Node] {
        compactMap { n in
            if n.isTask && n.done { return nil }
            var m = n
            m.children = n.children.removingDone()
            return m
        }
    }
}

// MARK: - Markdown 读写

enum Markdown {
    /// 支持：`- 文本`、`- [ ] 待办`、`- [x] 已完成`、`# 标题`（作为顶层分类），任意缩进宽度。
    /// 行尾的 `<!-- fold color=red -->` 保存折叠状态和颜色。
    static func parse(_ s: String) -> [Node] {
        var roots: [Node] = []
        var stack: [(indent: Int, path: [Int])] = []

        for raw in s.components(separatedBy: .newlines) {
            if raw.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            var indent = 0
            for ch in raw {
                if ch == " " { indent += 1 } else if ch == "\t" { indent += 4 } else { break }
            }
            var line = raw.trimmingCharacters(in: .whitespaces)
            var node = Node(text: "")

            if line.hasPrefix("#") {
                line = String(line.drop(while: { $0 == "#" })).trimmingCharacters(in: .whitespaces)
                indent = -1
                stack.removeAll()
            } else if let r = line.range(of: #"^([-*+]|\d+[.)])\s+"#, options: .regularExpression) {
                line = String(line[r.upperBound...])
            } else if line == "-" || line == "*" || line == "+" {
                line = ""
            }

            if let r = line.range(of: #"^\[( |x|X)\](\s|$)"#, options: .regularExpression) {
                node.isTask = true
                node.done = line[r].lowercased().contains("x")
                line = String(line[r.upperBound...])
            }

            if let r = line.range(of: #"\s*<!--.*?-->\s*$"#, options: .regularExpression) {
                let meta = line[r].replacingOccurrences(of: "<!--", with: "").replacingOccurrences(of: "-->", with: "")
                for token in meta.split(separator: " ") {
                    if token == "fold" { node.collapsed = true }
                    else if token.hasPrefix("color=") { node.color = String(token.dropFirst(6)) }
                }
                line = String(line[..<r.lowerBound])
            }
            node.text = line

            while let last = stack.last, last.indent >= indent { stack.removeLast() }
            if let parent = stack.last {
                let idx = roots.withList(parent.path) { list -> Int in
                    list.append(node)
                    return list.count - 1
                }
                stack.append((indent, parent.path + [idx]))
            } else {
                roots.append(node)
                stack.append((indent, [roots.count - 1]))
            }
        }
        return roots
    }

    static func serialize(_ nodes: [Node], depth: Int = 0) -> String {
        var out = ""
        for n in nodes {
            out += String(repeating: "  ", count: depth) + "- "
            if n.isTask { out += n.done ? "[x] " : "[ ] " }
            out += n.text.replacingOccurrences(of: "\n", with: " ")
            var meta: [String] = []
            if n.collapsed { meta.append("fold") }
            if let c = n.color { meta.append("color=\(c)") }
            if !meta.isEmpty { out += " <!-- \(meta.joined(separator: " ")) -->" }
            out += "\n"
            out += serialize(n.children, depth: depth + 1)
        }
        return out
    }

    static let seed = """
    - 使用说明（看完可以删掉：右键 → 删除）
      - 点任意一条就能编辑；回车新建一条，Tab 变成子项，⇧Tab 提升一级
      - 右键标题「桌面备忘」可以换样式；按住标题可以拖动位置
      - 按住分类拖动可以排序；右键条目可以改颜色、折叠、删除
      - 在待办后面写 @10-15 会显示到期倒计时
      - 被窗口挡住时，按 ⌃⌥M 把它叫到最前面
      - 「提醒事项」里的待办会自动显示在这里，和手机同步
    - 工作
      - [ ] 示例：周五前交周报
      - [ ] 示例：跟进客户合同
        - [ ] 确认报价
    - 生活
      - [ ] 示例：买牛奶
      - 常用信息也可以记在这里，比如会员号
    """
}

// MARK: - 截止日期：文本里写 @10-15 或 @2026-10-15

enum DueDate {
    private static let pattern = #"\s*@(?:(\d{4})[-/.])?(\d{1,2})[-/.](\d{1,2})"#

    static func split(_ text: String) -> (text: String, date: Date?) {
        guard let r = text.range(of: pattern, options: .regularExpression) else { return (text, nil) }
        let token = String(text[r])
        let nums = token.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        var comps = DateComponents()
        if nums.count == 3 {
            comps.year = nums[0]; comps.month = nums[1]; comps.day = nums[2]
        } else if nums.count == 2 {
            comps.year = cal.component(.year, from: today); comps.month = nums[0]; comps.day = nums[1]
        } else { return (text, nil) }
        guard var date = cal.date(from: comps) else { return (text, nil) }
        // 没写年份、而且已经过去很久了，多半指的是明年
        if nums.count == 2, let d = cal.dateComponents([.day], from: date, to: today).day, d > 180 {
            date = cal.date(byAdding: .year, value: 1, to: date) ?? date
        }
        var rest = text
        rest.removeSubrange(r)
        return (rest.trimmingCharacters(in: .whitespaces), date)
    }

    /// 带年份的日期标记，比如 @2026-10-15
    static func token(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return "@\(c.year!)-\(c.month!)-\(c.day!)"
    }

    /// 返回（显示文字, 距今天数）
    static func describe(_ date: Date) -> (String, Int) {
        let cal = Calendar.current
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: Date()), to: cal.startOfDay(for: date)).day ?? 0
        let md = "\(cal.component(.month, from: date))/\(cal.component(.day, from: date))"
        switch days {
        case 0: return ("今天", 0)
        case 1: return ("明天", 1)
        case 2...: return ("\(md) · \(days)天后", days)
        default: return ("\(md) · 已过\(-days)天", days)
        }
    }
}
