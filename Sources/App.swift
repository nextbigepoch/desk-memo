import AppKit
import SwiftUI
import Combine
import Carbon
import ServiceManagement

@main
enum Main {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)   // 不占程序坞
        withExtendedLifetime(delegate) { app.run() }
    }
}

/// 可以接收键盘输入的无边框窗口
final class DeskWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let settings = SettingsStore()
    lazy var store = MemoStore(fileURL: settings.usableMemoFileURL())
    lazy var reminders = RemindersStore(settings: settings)
    let ui = UIState()

    var window: DeskWindow!
    var statusItem: NSStatusItem!
    var settingsWindow: NSWindow?
    var hotKey: HotKey?
    var bag = Set<AnyCancellable>()
    var moveWork: DispatchWorkItem?
    var repositioning = false

    /// 比桌面图标高一层、比所有普通窗口低：看起来就像壁纸的一部分
    static let desktopLevel = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)

    func applicationDidFinishLaunching(_ n: Notification) {
        let snapshotMode = CommandLine.arguments.contains("--snapshot")
        if !snapshotMode && !checkInstallLocation() { return }
        if !snapshotMode {
            store.reminders = reminders
            if settings.value.reminders.enabled && reminders.status == .notDetermined {
                reminders.requestAccess()
            }
            if settings.value.iCloudFallback { _ = moveToICloud(interactive: false) }
        }
        buildMainMenu()
        buildWindow()
        buildStatusItem()

        hotKey = HotKey(keyCode: UInt32(kVK_ANSI_M), modifiers: UInt32(controlKey | optionKey)) { [weak self] in
            self?.toggleFront()
        }

        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self else { return e }
            return self.handleKey(e) ? nil : e
        }

        // 点别的应用 → 结束编辑、放回桌面层
        NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)
            .sink { [weak self] _ in
                self?.store.focus(nil)
                self?.setFront(false)
            }
            .store(in: &bag)

        // 开始编辑某条 → 激活应用，让键盘输入进到这里
        store.$focusedID
            .sink { [weak self] id in
                guard let self, id != nil else { return }
                NSApp.activate(ignoringOtherApps: true)
                self.window.makeKey()
            }
            .store(in: &bag)

        if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
            runSnapshots(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
            return
        }

        // 开机自启：只要设置是开着的，每次启动都确认一遍已经登记
        if settings.value.launchAtLogin && SMAppService.mainApp.status != .enabled {
            try? SMAppService.mainApp.register()
        }
        let login = "launchAtLogin=\(settings.value.launchAtLogin) status=\(SMAppService.mainApp.status.rawValue)"
        try? login.write(to: AppPaths.support.appendingPathComponent("login-status.txt"), atomically: true, encoding: .utf8)
    }

    /// 从「下载」或安装盘里直接打开时，提示放进「应用程序」，否则开机自启会失效。
    /// 返回 false 表示正在搬家重启，这次启动不用继续了。
    private func checkInstallLocation() -> Bool {
        let path = Bundle.main.bundlePath
        if path.hasPrefix("/Applications/") || path.hasPrefix(NSHomeDirectory() + "/Applications/") { return true }
        let a = NSAlert()
        a.messageText = "请把「桌面备忘」放进「应用程序」文件夹"
        a.informativeText = "现在它是从「下载」或安装盘里直接打开的，这样开机不能自动启动。\n点「帮我放进去」会自动复制到「应用程序」并重新打开。"
        a.addButton(withTitle: "帮我放进去")
        a.addButton(withTitle: "先这样用")
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { return true }
        let dest = URL(fileURLWithPath: "/Applications/桌面备忘.app")
        do {
            if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
            try FileManager.default.copyItem(at: Bundle.main.bundleURL, to: dest)
        } catch {
            let e = NSAlert()
            e.messageText = "没能自动放进去"
            e.informativeText = "请打开访达，把「桌面备忘」手动拖到左边的「应用程序」里，再从那里打开。\n（\(error.localizedDescription)）"
            e.runModal()
            return true
        }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: dest, configuration: cfg) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
        return false
    }

    /// 再次打开 App（双击、聚焦搜索）→ 打开设置窗口
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings()
        return false
    }

    func applicationWillTerminate(_ n: Notification) {
        store.focus(nil)
        store.saveNow()
        settings.saveNow()
    }

    // MARK: 窗口

    private func buildWindow() {
        window = DeskWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 200),
                            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = Self.desktopLevel
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.isReleasedWhenClosed = false

        let host = FirstMouseHostingView(rootView: MemoView(store: store, settings: settings, ui: ui, reminders: reminders))
        host.sizingOptions = []
        window.contentView = host

        ui.openSettings = { [weak self] in self?.openSettings() }
        ui.onWidth = { [weak self] w in
            self?.settings.value.layout.width = min(max(w.rounded(), 220), 1400)
        }

        Publishers.CombineLatest(settings.$value.map(\.layout).removeDuplicates(), ui.$contentHeight.removeDuplicates())
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.reposition() }
            .store(in: &bag)

        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in self?.reposition() }
            .store(in: &bag)

        // 用户拖动后记住新位置
        NotificationCenter.default.publisher(for: NSWindow.didMoveNotification, object: window)
            .sink { [weak self] _ in self?.windowMoved() }
            .store(in: &bag)

        reposition()
        window.orderFront(nil)
    }

    private func screen(for l: Layout) -> NSScreen {
        NSScreen.screens.first { $0.localizedName == l.screen } ?? NSScreen.screens.first ?? NSScreen.main!
    }

    func reposition() {
        let l = settings.value.layout
        var sc = screen(for: l)
        var vf = sc.visibleFrame
        let w = CGFloat(l.width), m = CGFloat(l.margin)
        let content = max(ui.contentHeight, 60)

        var top: CGPoint
        switch l.anchor {
        case "topCenter": top = CGPoint(x: vf.midX - w / 2, y: vf.maxY - m)
        case "center":
            let h = min(content, vf.height - 2 * m)
            top = CGPoint(x: vf.midX - w / 2, y: vf.midY + h / 2)
        case "topRight": top = CGPoint(x: vf.maxX - m - w, y: vf.maxY - m)
        case "custom":
            top = CGPoint(x: l.x, y: l.y)
            // 显示器拔掉了之类：找不到所在屏幕就回到左上
            if let s = NSScreen.screens.first(where: { $0.frame.insetBy(dx: -1, dy: -1).contains(CGPoint(x: l.x + 20, y: l.y - 20)) }) {
                sc = s; vf = s.visibleFrame
            } else {
                top = CGPoint(x: vf.minX + m, y: vf.maxY - m)
            }
        default: top = CGPoint(x: vf.minX + m, y: vf.maxY - m)
        }
        let maxH = max(top.y - vf.minY - m, 120)
        let h = min(content, maxH)
        let frame = NSRect(x: top.x, y: top.y - h, width: w, height: h).integral
        guard frame != window.frame else { return }
        repositioning = true
        window.setFrame(frame, display: true)
        repositioning = false
    }

    private func windowMoved() {
        guard !repositioning else { return }
        moveWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let f = self.window.frame
            self.settings.value.layout.anchor = "custom"
            self.settings.value.layout.x = f.minX
            self.settings.value.layout.y = f.maxY
        }
        moveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: w)
    }

    // MARK: 前台模式（⌃⌥M）

    @objc func toggleFront() { setFront(!ui.frontMode) }

    func setFront(_ on: Bool) {
        guard ui.frontMode != on else { return }
        ui.frontMode = on
        if on {
            window.level = .floating
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            if store.roots.isEmpty { store.addGroup() }
        } else {
            window.level = Self.desktopLevel
            store.focus(nil)
            if NSApp.isActive && settingsWindow?.isKeyWindow != true { NSApp.deactivate() }
        }
    }

    // MARK: 键盘

    private func handleKey(_ e: NSEvent) -> Bool {
        guard e.window === window else { return false }
        let f = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if let id = store.focusedID {
            switch (e.keyCode, f) {
            case (36, [.command]), (76, [.command]): store.toggleDone(id); return true
            case (126, [.command, .shift]): store.move(id, by: -1); return true
            case (125, [.command, .shift]): store.move(id, by: 1); return true
            case (17, [.command]): store.toggleTask(id); return true
            default: return false
            }
        }
        if e.keyCode == 6 && f == [.command] { store.undo(); return true }
        if e.keyCode == 53 { setFront(false); ui.layoutMode = false; return true }
        return false
    }

    /// 没有主菜单的话，⌘C / ⌘V 在输入框里不起作用
    private func buildMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "退出桌面备忘", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: "编辑")
        edit.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        NSApp.mainMenu = main
    }

    // MARK: 菜单栏图标

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "list.bullet.rectangle", accessibilityDescription: "桌面备忘")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        func add(_ title: String, _ sel: Selector?, key: String = "", to m: NSMenu = menu) -> NSMenuItem {
            let i = m.addItem(withTitle: title, action: sel, keyEquivalent: key)
            i.target = self
            return i
        }
        let front = add("叫到前面编辑", #selector(toggleFront))
        front.keyEquivalent = "m"
        front.keyEquivalentModifierMask = [.control, .option]
        _ = add("新建分类", #selector(newGroup))
        menu.addItem(.separator())

        let styleItem = menu.addItem(withTitle: "样式", action: nil, keyEquivalent: "")
        let styleMenu = NSMenu()
        for name in Presets.names {
            let i = add(name, #selector(pickPreset(_:)), to: styleMenu)
            i.representedObject = name
            i.state = settings.value.preset == name && settings.value.theme == Presets.theme(name) ? .on : .off
        }
        styleMenu.addItem(.separator())
        _ = add("细调样式…", #selector(openSettings), to: styleMenu)
        styleItem.submenu = styleMenu

        let posItem = menu.addItem(withTitle: "位置", action: nil, keyEquivalent: "")
        let posMenu = NSMenu()
        for (key, title) in [("topLeft", "左上"), ("topCenter", "上方居中"), ("center", "正中"), ("topRight", "右上")] {
            let i = add(title, #selector(pickAnchor(_:)), to: posMenu)
            i.representedObject = key
            i.state = settings.value.layout.anchor == key ? .on : .off
        }
        posMenu.addItem(.separator())
        _ = add("拖动调整位置和宽度…", #selector(enterLayoutMode), to: posMenu)
        posItem.submenu = posMenu

        menu.addItem(.separator())
        if settings.value.iCloudFallback || store.fileError != nil {
            _ = add("⚠️ 改存到 iCloud 云盘（手机可看）…", #selector(moveToICloudAction))
        }
        if settings.value.reminders.enabled && !reminders.granted {
            _ = add("⚠️ 允许读取「提醒事项」…", #selector(fixReminders))
        }
        let undo = add("撤销上一步", store.canUndo ? #selector(undo) : nil)
        undo.isEnabled = store.canUndo
        _ = add("清除所有已完成的待办", #selector(clearDone))
        _ = add("打开备忘文件", #selector(openFile))
        menu.addItem(.separator())
        _ = add("设置…", #selector(openSettings), key: ",")
        _ = add("退出", #selector(quit), key: "q")
    }

    @objc func moveToICloudAction() { _ = moveToICloud(interactive: true) }

    @objc func fixReminders() {
        if reminders.status == .notDetermined { reminders.requestAccess() }
        else { Self.openPrivacy("Privacy_Reminders") }
    }

    static func openPrivacy(_ pane: String) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
    }

    /// 把备忘文件搬到 iCloud 云盘。没权限时（interactive）弹窗说明怎么开。
    func moveToICloud(interactive: Bool) -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let target = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/桌面备忘/备忘.md")
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            store.saveNow()
            let mdate = { (u: URL) in (try? fm.attributesOfItem(atPath: u.path))?[.modificationDate] as? Date ?? .distantPast }
            let local = store.fileURL
            if local.path != target.path, store.fileError == nil, let current = try? String(contentsOf: local, encoding: .utf8) {
                // 云盘里已经有一份：哪份新用哪份；被覆盖的那份先备份
                if !fm.fileExists(atPath: target.path) || mdate(local) > mdate(target) {
                    if fm.fileExists(atPath: target.path) {
                        let bak = AppPaths.support.appendingPathComponent("backups/覆盖前的云盘版本-\(Int(Date().timeIntervalSince1970)).md")
                        try? fm.copyItem(at: target, to: bak)
                    }
                    try current.write(to: target, atomically: true, encoding: .utf8)
                }
            } else if !fm.fileExists(atPath: target.path) {
                try Markdown.seed.write(to: target, atomically: true, encoding: .utf8)
            }
            _ = try String(contentsOf: target, encoding: .utf8)
        } catch {
            NSLog("DeskMemo iCloud move failed: \(error)")
            if interactive {
                let a = NSAlert()
                a.messageText = "还没有访问 iCloud 云盘的权限"
                a.informativeText = """
                备忘内容想存到 iCloud 云盘，这样手机「文件」App 里也能看到、换电脑也不丢。

                之前点了「不允许」，系统会记住，不会再自动问。请这样打开：
                系统设置 → 隐私与安全性 → 文件与文件夹 → 桌面备忘 → 打开「iCloud 云盘」

                如果那里找不到，在「终端」里运行这一行，然后重新打开桌面备忘，系统会重新询问：
                tccutil reset All com.cox.deskmemo
                """
                a.addButton(withTitle: "打开系统设置")
                a.addButton(withTitle: "先不用")
                NSApp.activate(ignoringOtherApps: true)
                if a.runModal() == .alertFirstButtonReturn { Self.openPrivacy("Privacy_FilesAndFolders") }
            }
            return false
        }
        settings.value.memoFile = ""
        settings.value.iCloudFallback = false
        store.switchFile(to: target)
        return true
    }

    @objc func newGroup() { setFront(true); store.addGroup() }
    @objc func pickPreset(_ s: NSMenuItem) { settings.apply(preset: s.representedObject as! String) }
    @objc func pickAnchor(_ s: NSMenuItem) { settings.value.layout.anchor = s.representedObject as! String }
    @objc func enterLayoutMode() { ui.layoutMode = true; NSApp.activate(ignoringOtherApps: true) }
    @objc func undo() { store.undo() }
    @objc func clearDone() { store.clearDone() }
    @objc func openFile() { NSWorkspace.shared.open(store.fileURL) }
    @objc func quit() { NSApp.terminate(nil) }

    @objc func openSettings() {
        if settingsWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 640),
                             styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            w.title = "桌面备忘 · 设置"
            w.contentViewController = NSHostingController(rootView: SettingsView(
                settings: settings, store: store, ui: ui, reminders: reminders,
                moveToICloud: { [weak self] in _ = self?.moveToICloud(interactive: true) }))
            w.isReleasedWhenClosed = false
            w.center()
            settingsWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - 调试：把每个预设样式渲染成图片（叠在模拟壁纸上）

extension AppDelegate {
    func runSnapshots(to dir: URL) {
        let original = settings.value
        var names = Presets.names
        var shots: [(String, NSBitmapImageRep)] = []
        ui.snapshot = true
        settings.value.layout.width = 340
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        func finish() {
            // 拼成一张对比图
            let gap: CGFloat = 36, label: CGFloat = 44
            let w = shots.reduce(gap) { $0 + $1.1.size.width + gap }
            let h = (shots.map { $0.1.size.height }.max() ?? 0) + label + gap * 1.5
            let img = NSImage(size: NSSize(width: w, height: h))
            img.lockFocus()
            NSColor(hex: "#1C1C1E").setFill()
            NSRect(x: 0, y: 0, width: w, height: h).fill()
            var x = gap
            for (name, rep) in shots {
                let top = h - label - gap / 2
                (name as NSString).draw(at: NSPoint(x: x, y: top + 10), withAttributes: [
                    .font: NSFont.systemFont(ofSize: 20, weight: .semibold), .foregroundColor: NSColor.white])
                rep.draw(in: NSRect(x: x, y: top - rep.size.height, width: rep.size.width, height: rep.size.height))
                x += rep.size.width + gap
            }
            img.unlockFocus()
            if let tiff = img.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: dir.appendingPathComponent("样式一览.png"))
            }
            settings.value = original
            settings.saveNow()
            exit(0)
        }
        func next() {
            guard !names.isEmpty else { return finish() }
            let name = names.removeFirst()
            var t = Presets.theme(name)
            t.showHeader = true
            settings.value.theme = t
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [self] in
                if let v = window.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                    v.cacheDisplay(in: v.bounds, to: rep)
                    shots.append((name, rep))
                }
                next()
            }
        }
        next()
    }
}

// MARK: - 全局快捷键（Carbon，不需要辅助功能权限）

final class HotKey {
    private var ref: EventHotKeyRef?
    private static var action: (() -> Void)?

    init(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        HotKey.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { HotKey.action?() }
            return noErr
        }, 1, &spec, nil, nil)
        let id = EventHotKeyID(signature: OSType(0x444D454D), id: 1)
        RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &ref)
    }
}
