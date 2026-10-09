import AppKit
import EventKit

/// 和「提醒事项」双向同步：读出列表和提醒，桌面上的勾选、改字、新建、删除都写回去。
/// 提醒事项列表名和桌面上的分类同名时，提醒会并到那个分类下面。
final class RemindersStore: ObservableObject {
    private let ek = EKEventStore()
    private let settings: SettingsStore

    @Published private(set) var status = EKEventStore.authorizationStatus(for: .reminder)
    @Published private(set) var lists: [EKCalendar] = []
    @Published private(set) var byList: [String: [EKReminder]] = [:]
    @Published private(set) var drafts: [UUID: String] = [:]
    @Published private(set) var pending: [(id: UUID, list: String)] = []

    private var ids: [String: UUID] = [:]
    private var kinds: [UUID: NodeKind] = [:]
    private var reloadWork: DispatchWorkItem?

    init(settings: SettingsStore) {
        self.settings = settings
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: ek, queue: .main) { [weak self] _ in
            self?.scheduleReload()
        }
        if granted { reload() }
    }

    var granted: Bool { status == .fullAccess }
    var config: RemindersConfig { settings.value.reminders }
    var active: Bool { granted && config.enabled }

    /// 显示在桌面上的列表
    var visibleLists: [EKCalendar] {
        active ? lists.filter { !config.hiddenLists.contains($0.calendarIdentifier) } : []
    }

    /// 诊断用：把同步状态写到 ~/Library/Application Support/DeskMemo/status.txt（只有列表名和数量，不含内容）
    func writeStatus() {
        var lines = ["reminders.status=\(status.rawValue) granted=\(granted) enabled=\(config.enabled)"]
        for l in lists {
            let n = byList[l.calendarIdentifier]?.count ?? 0
            let hidden = config.hiddenLists.contains(l.calendarIdentifier) ? " (hidden)" : ""
            lines.append("list \(l.title) [account: \(l.source?.title ?? "?") type=\(l.source?.sourceType.rawValue ?? -1)]: \(n)\(hidden)")
        }
        try? lines.joined(separator: "\n").write(to: AppPaths.support.appendingPathComponent("status.txt"), atomically: true, encoding: .utf8)
    }

    func requestAccess() {
        ek.requestFullAccessToReminders { [weak self] _, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.status = EKEventStore.authorizationStatus(for: .reminder)
                self.reload()
                self.writeStatus()
            }
        }
    }

    // MARK: 读取

    private func scheduleReload() {
        reloadWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.reload() }
        reloadWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: w)
    }

    func reload() {
        status = EKEventStore.authorizationStatus(for: .reminder)
        guard granted else { lists = []; byList = [:]; return }
        let cals = ek.calendars(for: .reminder)
        let open = ek.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: cals)
        // 今天勾掉的也留着（按样式划掉/变淡/隐藏），免得一勾就消失
        let doneToday = ek.predicateForCompletedReminders(
            withCompletionDateStarting: Calendar.current.startOfDay(for: Date()), ending: nil, calendars: cals)
        ek.fetchReminders(matching: open) { [weak self] a in
            self?.ek.fetchReminders(matching: doneToday) { b in
                let all = (a ?? []) + (b ?? [])
                DispatchQueue.main.async {
                    guard let self else { return }
                    var map: [String: [EKReminder]] = [:]
                    for r in all { map[r.calendar.calendarIdentifier, default: []].append(r) }
                    for k in map.keys { map[k]!.sort(by: Self.order) }
                    self.lists = cals.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
                    self.byList = map
                    self.writeStatus()
                }
            }
        }
    }

    private static func due(_ r: EKReminder) -> Date? {
        r.dueDateComponents.flatMap { Calendar.current.date(from: $0) }
    }

    /// 未完成在前；有日期的按日期，没日期的按创建时间
    private static func order(_ a: EKReminder, _ b: EKReminder) -> Bool {
        if a.isCompleted != b.isCompleted { return !a.isCompleted }
        switch (due(a), due(b)) {
        case let (x?, y?) where x != y: return x < y
        case (.some, nil): return true
        case (nil, .some): return false
        default: return (a.creationDate ?? .distantPast) < (b.creationDate ?? .distantPast)
        }
    }

    // MARK: 转成树节点

    private func uid(_ key: String, _ kind: NodeKind) -> UUID {
        if let u = ids[key] { return u }
        let u = UUID()
        ids[key] = u
        kinds[u] = kind
        return u
    }

    func kind(of id: UUID) -> NodeKind? {
        if let k = kinds[id] { return k }
        if let p = pending.first(where: { $0.id == id }) { return .pending(p.list) }
        return nil
    }

    func owns(_ id: UUID) -> Bool { kind(of: id) != nil }

    /// 这一条属于哪个提醒事项列表
    func listID(of id: UUID) -> String? {
        switch kind(of: id) {
        case .reminder(let key): return (ek.calendarItem(withIdentifier: key) as? EKReminder)?.calendar.calendarIdentifier
        case .pending(let l), .list(let l): return l
        default: return nil
        }
    }

    private static func text(of r: EKReminder) -> String {
        let title = r.title ?? ""
        guard let d = due(r) else { return title }
        return "\(title) \(DueDate.token(d))"
    }

    func nodes(inList listID: String) -> [Node] {
        var out = (byList[listID] ?? []).map { r -> Node in
            let key = r.calendarItemIdentifier
            let id = uid(key, .reminder(key))
            return Node(id: id, text: drafts[id] ?? Self.text(of: r), isTask: true, done: r.isCompleted, kind: .reminder(key))
        }
        for p in pending where p.list == listID {
            out.append(Node(id: p.id, text: drafts[p.id] ?? "", isTask: true, kind: .pending(listID)))
        }
        return out
    }

    func groupNode(_ cal: EKCalendar) -> Node {
        let lid = cal.calendarIdentifier
        return Node(id: uid("list:" + lid, .list(lid)),
                    text: cal.title,
                    collapsed: config.collapsedLists.contains(lid),
                    color: cal.color.map { NSColor(cgColor: $0.cgColor)?.hexString ?? "" }.flatMap { $0.isEmpty ? nil : $0 },
                    children: nodes(inList: lid),
                    kind: .list(lid))
    }

    // MARK: 修改（全部写回提醒事项）

    func setDraft(_ id: UUID, _ text: String) {
        if drafts[id] != text { drafts[id] = text }
    }

    @discardableResult
    func newPending(in listID: String) -> UUID {
        let id = UUID()
        pending.append((id, listID))
        return id
    }

    /// 编辑结束时调用：把草稿写进提醒事项。返回 false 表示这条不归我管。
    @discardableResult
    func commit(_ id: UUID) -> Bool {
        guard let k = kind(of: id) else { return false }
        switch k {
        case .pending(let listID):
            let text = drafts.removeValue(forKey: id) ?? ""
            pending.removeAll { $0.id == id }
            let (title, date) = DueDate.split(text)
            guard !title.trimmingCharacters(in: .whitespaces).isEmpty,
                  let cal = ek.calendar(withIdentifier: listID) else { return true }
            let r = EKReminder(eventStore: ek)
            r.calendar = cal
            r.title = title
            if let date { r.dueDateComponents = Self.day(date) }
            if save(r) {
                // 沿用同一个 id，界面上这一行不会闪一下
                ids[r.calendarItemIdentifier] = id
                kinds[id] = .reminder(r.calendarItemIdentifier)
                byList[listID, default: []].append(r)
            }
        case .reminder(let key):
            guard let text = drafts.removeValue(forKey: id),
                  let r = ek.calendarItem(withIdentifier: key) as? EKReminder else { return true }
            let (title, date) = DueDate.split(text)
            if title.trimmingCharacters(in: .whitespaces).isEmpty {
                try? ek.remove(r, commit: true)
                return true
            }
            var changed = false
            if r.title != title { r.title = title; changed = true }
            let old = r.dueDateComponents
            let sameDay = old?.year == date.map { Calendar.current.component(.year, from: $0) }
                && old?.month == date.map { Calendar.current.component(.month, from: $0) }
                && old?.day == date.map { Calendar.current.component(.day, from: $0) }
            if !(old == nil && date == nil) && !sameDay {
                r.dueDateComponents = date.map(Self.day)
                changed = true
            }
            if changed { save(r) }
        case .list:
            break
        case .memo:
            return false
        }
        return true
    }

    func toggle(_ id: UUID) {
        guard case .reminder(let key) = kind(of: id),
              let r = ek.calendarItem(withIdentifier: key) as? EKReminder else { return }
        r.isCompleted.toggle()
        save(r)
    }

    func delete(_ id: UUID) {
        switch kind(of: id) {
        case .reminder(let key):
            drafts[id] = nil
            if let r = ek.calendarItem(withIdentifier: key) as? EKReminder { try? ek.remove(r, commit: true) }
        case .pending:
            drafts[id] = nil
            pending.removeAll { $0.id == id }
        default: break
        }
    }

    func moveToList(_ id: UUID, _ listID: String) {
        guard case .reminder(let key) = kind(of: id),
              let r = ek.calendarItem(withIdentifier: key) as? EKReminder,
              let cal = ek.calendar(withIdentifier: listID) else { return }
        r.calendar = cal
        save(r)
    }

    func toggleCollapse(_ id: UUID) {
        guard case .list(let lid) = kind(of: id) else { return }
        if let i = settings.value.reminders.collapsedLists.firstIndex(of: lid) {
            settings.value.reminders.collapsedLists.remove(at: i)
        } else {
            settings.value.reminders.collapsedLists.append(lid)
        }
    }

    func setHidden(_ listID: String, _ hidden: Bool) {
        settings.value.reminders.hiddenLists.removeAll { $0 == listID }
        if hidden { settings.value.reminders.hiddenLists.append(listID) }
    }

    func openRemindersApp() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Reminders.app"))
    }

    @discardableResult
    private func save(_ r: EKReminder) -> Bool {
        do { try ek.save(r, commit: true); return true }
        catch { NSLog("DeskMemo reminder save failed: \(error)"); return false }
    }

    private static func day(_ d: Date) -> DateComponents {
        Calendar.current.dateComponents([.year, .month, .day], from: d)
    }
}
