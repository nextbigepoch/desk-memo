// 生成 App 图标：一张「壁纸」上面浮着一棵备忘树。
// 用法：swift scripts/make_icon.swift <输出.png>
import AppKit

let S: CGFloat = 1024
let out = CommandLine.arguments[1]

func hex(_ h: String, _ a: CGFloat = 1) -> NSColor {
    var v: UInt64 = 0
    Scanner(string: String(h.dropFirst())).scanHexInt64(&v)
    return NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                   blue: CGFloat(v & 0xFF) / 255, alpha: a)
}

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(S), pixelsHigh: Int(S), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

// macOS 图标网格：824×824 的圆角方块，四周留白
let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
let shape = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)

// 投影
NSGraphicsContext.saveGraphicsState()
let sh = NSShadow()
sh.shadowColor = NSColor.black.withAlphaComponent(0.35)
sh.shadowBlurRadius = 28
sh.shadowOffset = NSSize(width: 0, height: -12)
sh.set()
hex("#2B4C7E").setFill()
shape.fill()
NSGraphicsContext.restoreGraphicsState()

NSGraphicsContext.saveGraphicsState()
shape.addClip()

// 黄昏天空
NSGradient(colorsAndLocations: (hex("#1E3A66"), 0.0), (hex("#3F6AA6"), 0.45), (hex("#E89A63"), 0.85), (hex("#F6C27A"), 1.0))!
    .draw(in: tile, angle: -90)

// 太阳光晕
let sun = NSPoint(x: 700, y: 330)
NSGradient(colors: [hex("#FFE3A3", 0.9), hex("#FFB86B", 0.0)])!
    .draw(fromCenter: sun, radius: 0, toCenter: sun, radius: 260, options: [])

// 远山 / 近山
func hills(_ pts: [(CGFloat, CGFloat)], _ c: NSColor) {
    let p = NSBezierPath()
    p.move(to: NSPoint(x: tile.minX, y: tile.minY))
    p.line(to: NSPoint(x: tile.minX, y: pts[0].1))
    for i in 1..<pts.count {
        let a = pts[i - 1], b = pts[i]
        p.curve(to: NSPoint(x: b.0, y: b.1), controlPoint1: NSPoint(x: (a.0 + b.0) / 2, y: a.1),
                controlPoint2: NSPoint(x: (a.0 + b.0) / 2, y: b.1))
    }
    p.line(to: NSPoint(x: tile.maxX, y: tile.minY))
    p.close()
    c.setFill()
    p.fill()
}
hills([(100, 300), (330, 380), (560, 290), (760, 360), (924, 300)], hex("#3B4E7A", 0.85))
hills([(100, 220), (300, 170), (520, 240), (740, 180), (924, 230)], hex("#1F2B4A", 0.95))

// 备忘树（带一点阴影，像叠在壁纸上的字）
let tsh = NSShadow()
tsh.shadowColor = NSColor.black.withAlphaComponent(0.35)
tsh.shadowBlurRadius = 10
tsh.shadowOffset = NSSize(width: 0, height: -4)
tsh.set()

func bar(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ c: NSColor) {
    c.setFill()
    NSBezierPath(roundedRect: NSRect(x: x, y: y, width: w, height: h), xRadius: h / 2, yRadius: h / 2).fill()
}
func circle(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat, filled: NSColor?) {
    let p = NSBezierPath(ovalIn: NSRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2))
    if let f = filled {
        f.setFill(); p.fill()
        let ck = NSBezierPath()
        ck.move(to: NSPoint(x: cx - r * 0.45, y: cy + r * 0.02))
        ck.line(to: NSPoint(x: cx - r * 0.1, y: cy - r * 0.35))
        ck.line(to: NSPoint(x: cx + r * 0.5, y: cy + r * 0.38))
        ck.lineWidth = r * 0.28
        ck.lineCapStyle = .round
        ck.lineJoinStyle = .round
        NSColor.white.setStroke(); ck.stroke()
    } else {
        p.lineWidth = r * 0.26
        NSColor.white.setStroke(); p.stroke()
    }
}

let x0: CGFloat = 262, indent: CGFloat = 70, r: CGFloat = 26
// 分类标题
bar(x0, 726, 230, 48, hex("#FFD60A"))
// 子项
circle(x0 + indent + r, 650, r, filled: hex("#FFD60A"))
bar(x0 + indent + 2 * r + 26, 636, 300, 28, NSColor.white.withAlphaComponent(0.55))
circle(x0 + indent + r, 570, r, filled: nil)
bar(x0 + indent + 2 * r + 26, 556, 250, 28, .white)
circle(x0 + indent + r, 490, r, filled: nil)
bar(x0 + indent + 2 * r + 26, 476, 170, 28, .white)
bar(x0 + indent + 2 * r + 26 + 186, 474, 96, 32, hex("#FF453A"))   // 到期标签
// 层级连接线
hex("#FFD60A", 0.6).setFill()
NSRect(x: x0 + 18, y: 462, width: 7, height: 240).fill()

NSGraphicsContext.restoreGraphicsState()

// 细描边，增加质感
hex("#FFFFFF", 0.18).setStroke()
shape.lineWidth = 3
shape.stroke()

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
