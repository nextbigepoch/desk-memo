import Foundation
import Combine

struct Row: Identifiable {
    let node: Node
    let depth: Int
    let branch: Int        // 属于第几个顶层分类
    let branchColor: String?
    var extraOpen = 0      // 并进来的提醒事项里还没完成的数量
    var id: UUID { node.id }
}

/// 树的状态 + 所有编辑操作 + 和磁盘文件的双向同步。
final class MemoStore: ObservableObject {
    @Published private(set) var roots: [Node] = []
    @Published var focusedID: UUID? {
        didSet {
            if let old = oldValue, old != focusedID, reminders?.commit(old) != true { dropIfEmpty(old) }
            if focusedID == nil { reloadIfChangedOnDisk() }
        }
    }
    /// 新建/拆分后，编辑框光标放在开头而不是结尾
    var caretAtStart = false

    weak var reminders: RemindersStore?
    /// 读文件出错时记下原因，并且停止写入，避免用空内容覆盖掉原文件
    @Published private(set) var fileError: String?
    private(set) var fileURL: URL
    private var lastSaved = ""
    private var lastMTime: Date?
    private var saveWork: DispatchWorkItem?
    private var timer: Timer?
    private var history: [[Node]] = []

    var canUndo: Bool { !history.isEmpty }

    init(fileURL: URL) {
        self.fileURL = fileURL
        ensureFile()
        load()
        backup()
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.reloadIfChangedOnDisk()
        }
    }

    // MARK: 文件

    private func ensureFile() {
        let fm = FileManager.default
        try? fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: fileURL.path) {
            try? Markdown.seed.write(to: fileURL, atomically: true, encoding: .utf8)
        }
    }

    private func mtime() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: fileURL.path))?[.modificationDate] as? Date
    }

    func load() {
        do {
            let s = try String(contentsOf: fileURL, encoding: .utf8)
            roots = Markdown.parse(s)
            lastSaved = s
            fileError = nil
        } catch {
            fileError = error.localizedDescription
            NSLog("DeskMemo read failed: \(error)")
        }
        lastMTime = mtime()
    }

    func switchFile(to url: URL) {
        saveNow()
        fileURL = url
        history.removeAll()
        ensureFile()
        load()
    }

    /// 用别的编辑器（或手机上）改了文件，就重新读入；正在编辑时先不动。
    func reloadIfChangedOnDisk() {
        guard focusedID == nil, saveWork == nil else { return }
        guard let m = mtime(), m != lastMTime else { return }
        lastMTime = m
        guard let s = try? String(contentsOf: fileURL, encoding: .utf8) else { return }
        if s != lastSaved || fileError != nil {
            fileError = nil
            roots = Markdown.parse(s)
            lastSaved = s
        }
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: w)
    }

    func saveNow() {
        saveWork?.cancel()
        saveWork = nil
        let s = Markdown.serialize(roots)
        guard s != lastSaved, fileError == nil else { return }
        do {
            try s.write(to: fileURL, atomically: true, encoding: .utf8)
            lastSaved = s
            lastMTime = mtime()
        } catch {
            NSLog("DeskMemo save failed: \(error)")
        }
    }

    /// 每天第一次启动时备份一份，保留最近 30 份。
    private func backup() {
        let fm = FileManager.default
        let dir = AppPaths.support.appendingPathComponent("backups", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        let dest = dir.appendingPathComponent("备忘-\(f.string(from: Date())).md")
        if !fm.fileExists(atPath: dest.path) { try? fm.copyItem(at: fileURL, to: dest) }
        let all = ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "md" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        for old in all.dropFirst(30) { try? fm.removeItem(at: old) }
    }

    // MARK: 修改

    private func edit(structural: Bool = true, _ body: (inout [Node]) -> Void) {
        if structural {
            history.append(roots)
            if history.count > 100 { history.removeFirst() }
        }
        body(&roots)
        scheduleSave()
    }

    func undo() {
        guard let prev = history.popLast() else { return }
        focusedID = nil
        roots = prev
        scheduleSave()
    }

    func node(_ id: UUID) -> Node? {
        roots.path(of: id).map { roots[path: $0] }
    }

    func setText(_ id: UUID, _ text: String) {
        if let r = reminders, r.owns(id) { r.setDraft(id, text); return }
        guard let p = roots.path(of: id), roots[path: p].text != text else { return }
        edit(structural: false) { $0[path: p].text = text }
    }

    func toggleDone(_ id: UUID) {
        if let r = reminders, r.owns(id) { r.toggle(id); return }
        guard let p = roots.path(of: id) else { return }
        edit {
            if !$0[path: p].isTask { $0[path: p].isTask = true; $0[path: p].done = true }
            else { $0[path: p].done.toggle() }
        }
    }

    func toggleTask(_ id: UUID) {
        guard let p = roots.path(of: id) else { return }
        edit {
            $0[path: p].isTask.toggle()
            if !$0[path: p].isTask { $0[path: p].done = false }
        }
    }

    func toggleCollapse(_ id: UUID) {
        if let r = reminders, r.owns(id) { r.toggleCollapse(id); return }
        guard let p = roots.path(of: id) else { return }
        edit(structural: false) { $0[path: p].collapsed.toggle() }
    }

    func setColor(_ id: UUID, _ color: String?) {
        guard let p = roots.path(of: id) else { return }
        edit { $0[path: p].color = color }
    }

    func addGroup() {
        let n = Node(text: "")
        edit { $0.append(n) }
        focus(n.id)
    }

    func addChild(_ id: UUID) {
        if let r = reminders, case .list(let l)? = r.kind(of: id) { focus(r.newPending(in: l)); return }
        guard let p = roots.path(of: id) else { return }
        let parent = roots[path: p]
        let n = Node(text: "", isTask: parent.children.last?.isTask ?? true)
        edit {
            $0[path: p].collapsed = false
            $0[path: p].children.append(n)
        }
        focus(n.id)
    }

    /// 回车：光标在中间就拆成两条；有展开的子项就插到第一个子项，否则插到下方。
    func enter(_ id: UUID, splitAt: Int?) {
        if let r = reminders, r.owns(id) {
            if let l = r.listID(of: id) { focus(r.newPending(in: l)) }
            return
        }
        guard let p = roots.path(of: id) else { return }
        let cur = roots[path: p]
        var head = cur.text, tail = ""
        if let i = splitAt, i < (cur.text as NSString).length {
            head = (cur.text as NSString).substring(to: i)
            tail = (cur.text as NSString).substring(from: i)
        }
        let intoChildren = !cur.children.isEmpty && !cur.collapsed
        let isTask = intoChildren ? cur.children[0].isTask : (p.count == 1 ? false : cur.isTask)
        let n = Node(text: tail, isTask: isTask)
        edit {
            $0[path: p].text = head
            if intoChildren {
                $0[path: p].children.insert(n, at: 0)
            } else {
                $0.withList(Array(p.dropLast())) { $0.insert(n, at: p.last! + 1) }
            }
        }
        caretAtStart = !tail.isEmpty
        focus(n.id)
    }

    func indent(_ id: UUID) {
        guard let p = roots.path(of: id), p.last! > 0 else { return }
        let parent = Array(p.dropLast()), i = p.last!
        edit {
            $0.withList(parent) { list in
                let n = list.remove(at: i)
                list[i - 1].collapsed = false
                list[i - 1].children.append(n)
            }
        }
    }

    func outdent(_ id: UUID) {
        guard let p = roots.path(of: id), p.count >= 2 else { return }
        let parentPath = Array(p.dropLast())
        let grand = Array(parentPath.dropLast())
        edit {
            let n = $0.withList(parentPath) { $0.remove(at: p.last!) }
            $0.withList(grand) { $0.insert(n, at: parentPath.last! + 1) }
        }
    }

    // MARK: 排序（拖动 / 移到最前最后）

    struct DropHint: Equatable { let id: UUID; let before: Bool }
    @Published var dropHint: DropHint?
    var dragging: UUID?

    /// 提醒事项列表要参与排序时，先在备忘树里建一个同名分类「占位」，提醒会自动并到它下面
    private func materialize(_ id: UUID) -> UUID? {
        guard let r = reminders, case .list(let lid)? = r.kind(of: id) else { return id }
        guard let cal = r.lists.first(where: { $0.calendarIdentifier == lid }) else { return nil }
        let n = Node(text: cal.title)
        edit { $0.append(n) }
        return n.id
    }

    /// 把 id 拖到 target 的前面/后面，和 target 成为同级
    func moveNode(_ id: UUID, relativeTo target: UUID, before: Bool) {
        guard id != target else { return }
        if let r = reminders {
            switch r.kind(of: id) {
            case .reminder?:
                // 提醒拖到别的列表 → 改到那个列表
                if let l = r.listID(of: target), l != r.listID(of: id) { r.moveToList(id, l) }
                return
            case .pending?: return
            default: break
            }
            switch r.kind(of: target) {
            case .reminder?, .pending?: return
            default: break
            }
        }
        guard let dragged = materialize(id), let tgt = materialize(target),
              let dp = roots.path(of: dragged), let tp = roots.path(of: tgt) else { return }
        if tp.count >= dp.count && Array(tp.prefix(dp.count)) == dp { return }   // 不能拖进自己的子项里
        edit {
            let n = $0.withList(Array(dp.dropLast())) { $0.remove(at: dp.last!) }
            guard let p = $0.path(of: tgt) else { return }
            $0.withList(Array(p.dropLast())) { $0.insert(n, at: p.last! + (before ? 0 : 1)) }
        }
    }

    func moveToEdge(_ id: UUID, first: Bool) {
        guard let real = materialize(id), let p = roots.path(of: real) else { return }
        edit {
            $0.withList(Array(p.dropLast())) { list in
                let n = list.remove(at: p.last!)
                if first { list.insert(n, at: 0) } else { list.append(n) }
            }
        }
    }

    func move(_ id: UUID, by delta: Int) {
        guard let real = materialize(id) else { return }
        let id = real
        guard let p = roots.path(of: id) else { return }
        let i = p.last!, j = i + delta
        edit {
            $0.withList(Array(p.dropLast())) { list in
                guard list.indices.contains(j) else { return }
                list.swapAt(i, j)
            }
        }
    }

    func delete(_ id: UUID) {
        let visible = rows(hideDone: false).map(\.id)
        var next: UUID?
        if let i = visible.firstIndex(of: id) {
            next = i > 0 ? visible[i - 1] : (visible.count > 1 ? visible[1] : nil)
        }
        let wasEditing = focusedID == id
        if let r = reminders, r.owns(id) {
            r.delete(id)
        } else if let p = roots.path(of: id) {
            edit { $0.withList(Array(p.dropLast())) { _ = $0.remove(at: p.last!) } }
        }
        if wasEditing { focusedID = next }
    }

    func clearDone() {
        edit { $0 = $0.removingDone() }
    }

    private func dropIfEmpty(_ id: UUID) {
        guard let n = node(id), n.text.trimmingCharacters(in: .whitespaces).isEmpty, n.children.isEmpty,
              let p = roots.path(of: id) else { return }
        edit(structural: false) { $0.withList(Array(p.dropLast())) { _ = $0.remove(at: p.last!) } }
    }

    // MARK: 焦点 / 导航

    func focus(_ id: UUID?) { focusedID = id }

    func focusNeighbor(of id: UUID, _ delta: Int, hideDone: Bool) {
        let ids = rows(hideDone: hideDone).map(\.id)
        guard let i = ids.firstIndex(of: id), ids.indices.contains(i + delta) else { return }
        focusedID = ids[i + delta]
    }

    func rows(hideDone: Bool) -> [Row] {
        var out: [Row] = []
        func walk(_ nodes: [Node], depth: Int, branch: Int, color: String?) {
            for n in nodes {
                if hideDone && n.isTask && n.done && n.id != focusedID { continue }
                out.append(Row(node: n, depth: depth, branch: branch, branchColor: color))
                if !n.collapsed { walk(n.children, depth: depth + 1, branch: branch, color: color) }
            }
        }
        let lists = reminders?.visibleLists ?? []
        var merged = Set<String>()
        for (i, n) in roots.enumerated() {
            // 提醒事项里同名的列表，并到这个分类下面
            let name = n.text.trimmingCharacters(in: .whitespaces)
            var extra: [Node] = []
            if !name.isEmpty, let r = reminders {
                for l in lists where l.title.trimmingCharacters(in: .whitespaces) == name {
                    merged.insert(l.calendarIdentifier)
                    extra += r.nodes(inList: l.calendarIdentifier)
                }
            }
            var row = Row(node: n, depth: 0, branch: i, branchColor: n.color)
            row.extraOpen = extra.filter { $0.isTask && !$0.done }.count
            out.append(row)
            if !n.collapsed {
                walk(n.children, depth: 1, branch: i, color: n.color)
                walk(extra, depth: 1, branch: i, color: n.color)
            }
        }
        // 其余的提醒事项列表各自成为一个分类
        if let r = reminders {
            for (j, l) in lists.enumerated() where !merged.contains(l.calendarIdentifier) {
                let g = r.groupNode(l)
                walk([g], depth: 0, branch: roots.count + j, color: g.color)
            }
        }
        return out
    }
}
