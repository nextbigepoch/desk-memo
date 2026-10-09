import AppKit
import SwiftUI

enum FieldCommand {
    case enter(splitAt: Int?)
    case tab, backtab, deleteEmpty, up, down, escape
}

/// 原生输入框：回车新建、Tab 缩进、Shift-Tab 反缩进、空行退格删除、上下键切换。
struct OutlineField: NSViewRepresentable {
    var text: String
    var font: NSFont
    var color: NSColor
    var caretAtStart: Bool
    var onChange: (String) -> Void
    var onCommand: (FieldCommand) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let f = NSTextField(string: text)
        f.isBordered = false
        f.drawsBackground = false
        f.focusRingType = .none
        f.isEditable = true
        f.usesSingleLineMode = false
        f.cell?.wraps = true
        f.cell?.isScrollable = false
        f.lineBreakMode = .byWordWrapping
        f.maximumNumberOfLines = 0
        f.font = font
        f.textColor = color
        f.placeholderString = ""
        f.delegate = context.coordinator
        f.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        f.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let atStart = caretAtStart
        DispatchQueue.main.async { [weak f] in
            guard let f, let w = f.window else { return }
            w.makeFirstResponder(f)
            if let ed = f.currentEditor() as? NSTextView {
                ed.insertionPointColor = color
                let len = (f.stringValue as NSString).length
                ed.selectedRange = NSRange(location: atStart ? 0 : len, length: 0)
            }
        }
        return f
    }

    func updateNSView(_ f: NSTextField, context: Context) {
        context.coordinator.parent = self
        if f.font != font { f.font = font }
        if f.textColor != color { f.textColor = color }
        if let ed = f.currentEditor() as? NSTextView {
            if ed.string != text { ed.string = text }
        } else if f.stringValue != text {
            f.stringValue = text
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextField, context: Context) -> CGSize? {
        guard let w = proposal.width, w.isFinite, w > 0 else { return nil }
        let s = text.isEmpty ? "国" : text
        let rect = (s as NSString).boundingRect(
            with: NSSize(width: max(w - 4, 10), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font])
        return CGSize(width: w, height: ceil(rect.height) + 1)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: OutlineField
        init(_ p: OutlineField) { parent = p }

        func controlTextDidChange(_ n: Notification) {
            guard let f = n.object as? NSTextField else { return }
            parent.onChange(f.stringValue)
        }

        func control(_ control: NSControl, textView tv: NSTextView, doCommandBy sel: Selector) -> Bool {
            switch sel {
            case #selector(NSResponder.insertNewline(_:)):
                let loc = tv.selectedRange().location
                parent.onCommand(.enter(splitAt: loc < (tv.string as NSString).length ? loc : nil))
            case #selector(NSResponder.insertLineBreak(_:)), #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
                break
            case #selector(NSResponder.insertTab(_:)):
                parent.onCommand(.tab)
            case #selector(NSResponder.insertBacktab(_:)):
                parent.onCommand(.backtab)
            case #selector(NSResponder.deleteBackward(_:)):
                guard tv.string.isEmpty else { return false }
                parent.onCommand(.deleteEmpty)
            case #selector(NSResponder.moveUp(_:)):
                guard isOnEdgeLine(tv, top: true) else { return false }
                parent.onCommand(.up)
            case #selector(NSResponder.moveDown(_:)):
                guard isOnEdgeLine(tv, top: false) else { return false }
                parent.onCommand(.down)
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onCommand(.escape)
            default:
                return false
            }
            return true
        }

        /// 折行的长条目里，上下键先在行内移动，到了首/末行才跳到别的条目。
        private func isOnEdgeLine(_ tv: NSTextView, top: Bool) -> Bool {
            guard let lm = tv.layoutManager, let tc = tv.textContainer, lm.numberOfGlyphs > 0 else { return true }
            let caret = lm.glyphIndexForCharacter(at: tv.selectedRange().location)
            let g = min(caret, lm.numberOfGlyphs - 1)
            let line = lm.lineFragmentRect(forGlyphAt: g, effectiveRange: nil)
            let used = lm.usedRect(for: tc)
            return top ? line.minY <= used.minY + 1 : line.maxY >= used.maxY - 1
        }
    }
}
