import AppKit
import SwiftUI
import UniformTypeIdentifiers

final class UIState: ObservableObject {
    @Published var contentHeight: CGFloat = 120
    @Published var layoutMode = false
    @Published var frontMode = false
    @Published var hovering = false
    var onWidth: (CGFloat) -> Void = { _ in }
    var openSettings: () -> Void = {}
    var snapshot = false     // 调试截图时在背后画一张模拟壁纸
}

private struct HeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private let chevronSlot: CGFloat = 16

struct MemoView: View {
    @ObservedObject var store: MemoStore
    @ObservedObject var settings: SettingsStore
    @ObservedObject var ui: UIState
    @ObservedObject var reminders: RemindersStore

    private var theme: Theme { settings.value.theme }

    var body: some View {
        let t = theme
        let rows = store.rows(hideDone: t.doneStyle == "hide")
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                if t.showHeader { HeaderView(settings: settings, ui: ui) }
                if let err = store.fileError {
                    Text("⚠️ 读不到备忘文件：\(err)\n菜单栏图标 → 设置 → 数据 里可以处理")
                        .font(.system(size: 12))
                        .foregroundStyle(Color(hex: "#FF9F0A"))
                        .padding(.leading, chevronSlot)
                        .padding(.bottom, 8)
                }
                ForEach(Array(rows.enumerated()), id: \.element.id) { i, row in
                    RowView(row: row, theme: t, isFirst: i == 0, store: store,
                            showIcon: settings.value.reminders.showIcon)
                }
                Text("＋ 新分类")
                    .font(t.font(size: t.itemSize * 0.9, weight: .medium))
                    .foregroundStyle(Color(hex: t.secondaryColor))
                    .padding(.leading, chevronSlot)
                    .padding(.top, 12)
                    .opacity(ui.hovering || store.roots.isEmpty ? 1 : 0)
                    .contentShape(Rectangle())
                    .onTapGesture { store.addGroup() }
            }
            .padding(.vertical, t.padding)
            .padding(.leading, max(t.padding - 12, 4))
            .padding(.trailing, t.padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                GeometryReader { g in Color.clear.preference(key: HeightKey.self, value: g.size.height) }
            )
            .background(
                Color.white.opacity(0.001)
                    .onTapGesture { store.focus(nil) }
            )
        }
        .scrollBounceBehavior(.basedOnSize)
        .onPreferenceChange(HeightKey.self) { ui.contentHeight = $0 }
        .background(background)
        .clipShape(RoundedRectangle(cornerRadius: t.cornerRadius, style: .continuous))
        .overlay { if ui.layoutMode { LayoutOverlay(ui: ui, radius: t.cornerRadius) } }
        .opacity(t.opacity)
        .background {
            if ui.snapshot {
                LinearGradient(colors: [Color(hex: "#2F4A63"), Color(hex: "#6A86A6"), Color(hex: "#C49A74")],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        }
        .onHover { ui.hovering = $0 }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder private var background: some View {
        let t = theme
        let mode = (ui.frontMode && t.background == "none") ? "blur" : t.background
        let opacity = ui.frontMode ? max(t.backgroundOpacity, 0.25) : t.backgroundOpacity
        switch mode {
        case "blur":
            ZStack {
                VisualEffect(dark: NSColor(hex: t.textColor).isLight)
                Color(hex: t.backgroundColor).opacity(opacity)
            }
        case "color":
            Color(hex: t.backgroundColor).opacity(opacity)
        default:
            Color.clear
        }
    }
}

// MARK: - 标题栏（也是拖动把手）

struct HeaderView: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var ui: UIState
    private var theme: Theme { settings.value.theme }
    private static let fmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日 EEE"
        return f
    }()

    var body: some View {
        let t = theme
        TimelineView(.periodic(from: .now, by: 60)) { ctx in
            HStack(alignment: .firstTextBaseline) {
                Text(t.headerText)
                    .font(t.font(size: t.groupSize * 1.2, weight: .bold))
                    .foregroundStyle(Color(hex: t.textColor))
                Spacer(minLength: 8)
                if t.showDate {
                    Text(Self.fmt.string(from: ctx.date))
                        .font(t.font(size: t.itemSize * 0.95, weight: .medium))
                        .foregroundStyle(Color(hex: t.secondaryColor))
                }
            }
        }
        .padding(.leading, chevronSlot)
        .padding(.bottom, t.groupSpacing * 0.7)
        .shadow(color: .black.opacity(t.textShadow ? 0.5 : 0), radius: 2.5, y: 1)
        .overlay(WindowDragArea())
        .contextMenu {
            Section("样式") {
                ForEach(Presets.names, id: \.self) { name in
                    Button(settings.value.preset == name ? "✓ \(name)" : "    \(name)") { settings.apply(preset: name) }
                }
            }
            Divider()
            Button("调整位置和宽度…") { ui.layoutMode = true }
            Button("设置…") { ui.openSettings() }
        }
        .help("按住拖动；右键换样式")
    }
}

// MARK: - 一行

struct RowView: View {
    let row: Row
    let theme: Theme
    let isFirst: Bool
    @ObservedObject var store: MemoStore
    var showIcon = true
    @State private var hover = false
    @State private var rowHeight: CGFloat = 20

    private var node: Node { row.node }
    private var isGroup: Bool { row.depth == 0 }
    private var size: Double { isGroup ? theme.groupSize : theme.itemSize }
    private var weightName: String { isGroup ? theme.groupWeight : "regular" }
    private var nsFont: NSFont { theme.nsFont(size: size, weight: weightName) }
    private var lineH: CGFloat { NSLayoutManager().defaultLineHeight(for: nsFont) }
    private var focused: Bool { store.focusedID == node.id }
    private var branchColor: Color { theme.groupColor(row.branch, override: row.branchColor) }
    private var secondary: Color { Color(hex: theme.secondaryColor) }
    private var hasMarker: Bool { !(isGroup && !theme.groupBullet && !node.isTask) }
    private var fromReminders: Bool { !node.isMemo }
    private var markerW: CGFloat { CGFloat(size) * 1.05 }

    private var textHex: String {
        if let c = node.color { return resolveColor(c) }
        if isGroup {
            if let c = row.branchColor { return resolveColor(c) }
            if theme.colorfulGroups, !theme.groupColors.isEmpty { return theme.groupColors[row.branch % theme.groupColors.count] }
        }
        return theme.textColor
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            chevron
            if hasMarker {
                marker.frame(width: markerW, height: lineH)
                Spacer().frame(width: 5)
            }
            content
            if hover && !focused && store.focusedID == nil {
                Image(systemName: "plus.circle")
                    .font(.system(size: theme.itemSize * 0.85))
                    .foregroundStyle(secondary)
                    .frame(height: lineH)
                    .padding(.leading, 6)
                    .contentShape(Rectangle())
                    .onTapGesture { store.addChild(node.id) }
                    .help("添加子项")
            }
        }
        .padding(.leading, CGFloat(row.depth) * theme.indent)
        .padding(.vertical, theme.rowSpacing / 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(alignment: .topLeading) { if theme.guides && row.depth > 0 { guides } }
        .shadow(color: .black.opacity(theme.textShadow ? 0.55 : 0), radius: 2.5, y: 1)
        .contentShape(Rectangle())
        .onTapGesture { store.focus(node.id) }
        .onHover { hover = $0 }
        .contextMenu { menu }
        .background(GeometryReader { g in Color.clear.onAppear { rowHeight = g.size.height }
            .onChange(of: g.size.height) { _, h in rowHeight = h } })
        .overlay(alignment: store.dropHint?.before == false ? .bottomLeading : .topLeading) {
            if store.dropHint?.id == node.id {
                // 拖动时的插入位置提示线
                Capsule().fill(Color.accentColor).frame(height: 3)
                    .padding(.leading, CGFloat(row.depth) * theme.indent + chevronSlot)
                    .offset(y: store.dropHint?.before == true ? -1.5 : 1.5)
                    .allowsHitTesting(false)
            }
        }
        .onDrag {
            store.dragging = node.id
            return NSItemProvider(object: node.id.uuidString as NSString)
        }
        .onDrop(of: [.plainText], delegate: RowDrop(id: node.id, store: store, height: rowHeight))
        .padding(.top, isGroup && !isFirst ? theme.groupSpacing : 0)
    }

    // 折叠箭头：悬停或已折叠时出现
    private var chevron: some View {
        let show = !node.children.isEmpty && (hover || node.collapsed)
        return Image(systemName: "chevron.right")
            .font(.system(size: max(size * 0.5, 8), weight: .bold))
            .foregroundStyle(secondary)
            .rotationEffect(.degrees(node.collapsed ? 0 : 90))
            .frame(width: chevronSlot, height: lineH)
            .contentShape(Rectangle())
            .opacity(show ? 1 : 0)
            .onTapGesture { if !node.children.isEmpty { store.toggleCollapse(node.id) } }
    }

    @ViewBuilder private var marker: some View {
        if node.isTask {
            let square = theme.checkbox == "square"
            Image(systemName: node.done ? (square ? "checkmark.square.fill" : "checkmark.circle.fill") : (square ? "square" : "circle"))
                .font(.system(size: size * 0.9, weight: .medium))
                .foregroundStyle(node.done ? branchColor : secondary)
                .contentShape(Rectangle())
                .onTapGesture { store.toggleDone(node.id) }
        } else {
            Bullet(style: theme.bullet, size: size, color: branchColor)
        }
    }

    @ViewBuilder private var content: some View {
        if focused {
            OutlineField(
                text: node.text,
                font: nsFont,
                color: NSColor(hex: textHex),
                caretAtStart: store.caretAtStart,
                onChange: { store.setText(node.id, $0) },
                onCommand: handle
            )
            .padding(.leading, -2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onAppear { store.caretAtStart = false }
        } else {
            let (shown, due) = DueDate.split(node.text)
            let doneLook = node.isTask && node.done
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(shown.isEmpty ? (node.text.isEmpty ? "新条目" : " ") : shown)
                    .font(theme.font(size: size, weight: Theme.weight(weightName)))
                    .foregroundStyle(node.text.isEmpty || (doneLook && theme.doneStyle == "strike") ? secondary : Color(hex: textHex))
                    .strikethrough(doneLook && theme.doneStyle == "strike", color: secondary)
                    .opacity(doneLook && theme.doneStyle == "fade" ? 0.45 : 1)
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(1)
                if let due, !doneLook { dueBadge(due) }
                if showIcon && fromReminders {
                    Image(systemName: "bell.fill")
                        .font(.system(size: max(size * 0.55, 8)))
                        .foregroundStyle(secondary.opacity(0.7))
                        .help("来自「提醒事项」，会和手机同步")
                }
                if theme.showCounts || node.collapsed { countBadge }
            }
        }
    }

    @ViewBuilder private var countBadge: some View {
        let open = node.openTaskCount + row.extraOpen
        if (isGroup || node.collapsed) && open > 0 {
            Text("\(open)")
                .font(.system(size: max(theme.itemSize * 0.78, 9), weight: .semibold, design: .rounded))
                .foregroundStyle(secondary)
        } else if node.collapsed && !node.children.isEmpty {
            Text("…\(node.children.count)")
                .font(.system(size: max(theme.itemSize * 0.78, 9), weight: .medium, design: .rounded))
                .foregroundStyle(secondary)
        }
    }

    private func dueBadge(_ date: Date) -> some View {
        let (label, days) = DueDate.describe(date)
        let urgent = days <= 3
        let c: Color = days < 0 ? Color(hex: "#FF453A") : urgent ? Color(hex: "#FF9F0A") : secondary
        // 快到期/过期的用实心标签，叠在照片上也一眼能看到
        return Text(label)
            .font(.system(size: max(theme.itemSize * 0.78, 9), weight: .semibold))
            .foregroundStyle(urgent ? Color.white : c)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule().fill(urgent ? c : c.opacity(0.18)))
            .fixedSize()
    }

    // 层级连接线：每一层祖先一条竖线
    private var guides: some View {
        let groupW = theme.groupSize * 1.05, itemW = theme.itemSize * 1.05
        return Canvas { ctx, sz in
            for level in 0..<row.depth {
                let x: CGFloat
                if level == 0 {
                    x = theme.groupBullet ? chevronSlot + groupW / 2 : chevronSlot + 2
                } else {
                    x = CGFloat(level) * theme.indent + chevronSlot + itemW / 2
                }
                var p = Path()
                p.move(to: CGPoint(x: x, y: 0))
                p.addLine(to: CGPoint(x: x, y: sz.height))
                ctx.stroke(p, with: .color(level == 0 ? branchColor.opacity(0.5) : secondary.opacity(0.35)), lineWidth: 1)
            }
        }
    }

    @ViewBuilder private var menu: some View {
        switch node.kind {
        case .memo: memoMenu
        case .list(let lid):
            Button("新建提醒") { store.addChild(node.id) }
            Button(node.collapsed ? "展开" : "折叠") { store.toggleCollapse(node.id) }
            Divider()
            Button("移到最前") { store.moveToEdge(node.id, first: true) }
            Button("上移") { store.move(node.id, by: -1) }
            Button("下移") { store.move(node.id, by: 1) }
            Divider()
            Button("不在桌面显示这个列表") { store.reminders?.setHidden(lid, true) }
            Button("打开「提醒事项」") { store.reminders?.openRemindersApp() }
        case .reminder, .pending:
            Button(node.done ? "取消完成" : "标记完成") { store.toggleDone(node.id) }
            Button("在下方新建提醒") { store.enter(node.id, splitAt: nil) }
            Divider()
            Button("打开「提醒事项」") { store.reminders?.openRemindersApp() }
            Divider()
            Button("删除这条提醒", role: .destructive) { store.delete(node.id) }
        }
    }

    @ViewBuilder private var memoMenu: some View {
        Button("添加子项") { store.addChild(node.id) }
        Button("在下方新建") { store.enter(node.id, splitAt: nil) }
        Divider()
        Button(node.isTask ? "改为普通文本" : "改为待办（带勾选框）") { store.toggleTask(node.id) }
        if node.isTask { Button(node.done ? "取消完成" : "标记完成") { store.toggleDone(node.id) } }
        Menu("颜色") {
            Button("默认") { store.setColor(node.id, nil) }
            ForEach(namedColors, id: \.key) { c in
                Button(c.name) { store.setColor(node.id, c.key) }
            }
        }
        if !node.children.isEmpty {
            Button(node.collapsed ? "展开" : "折叠") { store.toggleCollapse(node.id) }
        }
        Divider()
        Button("移到最前") { store.moveToEdge(node.id, first: true) }
        Button("上移") { store.move(node.id, by: -1) }
        Button("下移") { store.move(node.id, by: 1) }
        Button("移到最后") { store.moveToEdge(node.id, first: false) }
        Divider()
        Button(node.children.isEmpty ? "删除" : "删除（连同 \(node.children.count) 个子项）", role: .destructive) {
            store.delete(node.id)
        }
    }

    private func handle(_ cmd: FieldCommand) {
        let hideDone = theme.doneStyle == "hide"
        switch cmd {
        case .enter(let at): store.enter(node.id, splitAt: at)
        case .tab: store.indent(node.id)
        case .backtab: store.outdent(node.id)
        case .deleteEmpty:
            if node.children.isEmpty { store.delete(node.id) }
        case .up: store.focusNeighbor(of: node.id, -1, hideDone: hideDone)
        case .down: store.focusNeighbor(of: node.id, 1, hideDone: hideDone)
        case .escape: store.focus(nil)
        }
    }
}

struct Bullet: View {
    let style: String
    let size: Double
    let color: Color

    var body: some View {
        switch style {
        case "ring":
            Circle().strokeBorder(color, lineWidth: max(size * 0.09, 1.2)).frame(width: size * 0.4, height: size * 0.4)
        case "square":
            RoundedRectangle(cornerRadius: 1.5).fill(color).frame(width: size * 0.32, height: size * 0.32)
        case "diamond":
            Rectangle().fill(color).frame(width: size * 0.28, height: size * 0.28).rotationEffect(.degrees(45))
        case "dash":
            Capsule().fill(color).frame(width: size * 0.5, height: max(size * 0.12, 1.5))
        case "arrow":
            Image(systemName: "chevron.right").font(.system(size: size * 0.55, weight: .heavy)).foregroundStyle(color)
        case "none":
            Color.clear.frame(width: 1, height: 1)
        default:
            Circle().fill(color).frame(width: size * 0.34, height: size * 0.34)
        }
    }
}

/// 拖到某一行的上半部分 = 放到它前面；下半部分 = 放到它后面
struct RowDrop: DropDelegate {
    let id: UUID
    let store: MemoStore
    let height: CGFloat

    private func hint(_ info: DropInfo) -> MemoStore.DropHint {
        .init(id: id, before: info.location.y < height / 2)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        let h = hint(info)
        if store.dropHint != h { store.dropHint = h }
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        if store.dropHint?.id == id { store.dropHint = nil }
    }

    func performDrop(info: DropInfo) -> Bool {
        let h = hint(info)
        store.dropHint = nil
        guard let d = store.dragging else { return false }
        store.dragging = nil
        store.moveNode(d, relativeTo: id, before: h.before)
        return true
    }
}

// MARK: - 布局调整模式

struct LayoutOverlay: View {
    @ObservedObject var ui: UIState
    let radius: Double

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: max(radius, 8)).fill(Color.accentColor.opacity(0.12))
            WindowDragArea(resizable: true, onWidth: ui.onWidth)
            RoundedRectangle(cornerRadius: max(radius, 8))
                .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
                .allowsHitTesting(false)
            HStack {
                Spacer()
                Capsule().fill(Color.accentColor).frame(width: 5, height: 44).padding(.trailing, 3)
            }
            .allowsHitTesting(false)
            VStack(spacing: 10) {
                Text("拖动任意位置移动 · 拖右侧边缘调整宽度")
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(.regularMaterial, in: Capsule())
                    .allowsHitTesting(false)
                Button("完成") { ui.layoutMode = false }
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}

/// 鼠标拖动它 = 拖动整个窗口；resizable 时右侧 14pt 用来改宽度。
struct WindowDragArea: NSViewRepresentable {
    var resizable = false
    var onWidth: (CGFloat) -> Void = { _ in }

    func makeNSView(context: Context) -> DragView {
        let v = DragView()
        v.cfg = self
        return v
    }

    func updateNSView(_ v: DragView, context: Context) { v.cfg = self }

    final class DragView: NSView {
        var cfg = WindowDragArea()
        private var resizing = false
        private var startX: CGFloat = 0
        private var startW: CGFloat = 0
        private let edge: CGFloat = 14

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func resetCursorRects() {
            if cfg.resizable {
                addCursorRect(NSRect(x: 0, y: 0, width: bounds.width - edge, height: bounds.height), cursor: .openHand)
                addCursorRect(NSRect(x: bounds.width - edge, y: 0, width: edge, height: bounds.height), cursor: .resizeLeftRight)
            }
        }

        override func mouseDown(with e: NSEvent) {
            let p = convert(e.locationInWindow, from: nil)
            if cfg.resizable, p.x > bounds.width - edge, let w = window {
                resizing = true
                startX = NSEvent.mouseLocation.x
                startW = w.frame.width
            } else {
                window?.performDrag(with: e)
            }
        }

        override func mouseDragged(with e: NSEvent) {
            guard resizing else { return }
            cfg.onWidth(startW + NSEvent.mouseLocation.x - startX)
        }

        override func mouseUp(with e: NSEvent) { resizing = false }
    }
}

struct VisualEffect: NSViewRepresentable {
    var dark: Bool
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        v.appearance = NSAppearance(named: dark ? .vibrantDark : .vibrantLight)
    }
}
