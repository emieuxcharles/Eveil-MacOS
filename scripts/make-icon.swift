import AppKit
let destination = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let image = NSImage(size: NSSize(width: pixels, height: pixels))
        image.lockFocus()
        let p = CGFloat(pixels)
        NSColor(calibratedRed: 0.97, green: 0.68, blue: 0.23, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: p * 0.055, y: p * 0.055, width: p * 0.89, height: p * 0.89), xRadius: p * 0.20, yRadius: p * 0.20).fill()
        NSColor(calibratedRed: 0.19, green: 0.13, blue: 0.055, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: p * 0.34, y: p * 0.34, width: p * 0.32, height: p * 0.32)).fill()
        for i in 0..<8 {
            let angle = CGFloat(i) * .pi / 4
            let line = NSBezierPath(); line.lineWidth = max(1, p * 0.035); line.lineCapStyle = .round
            line.move(to: NSPoint(x: p * 0.5 + cos(angle) * p * 0.235, y: p * 0.5 + sin(angle) * p * 0.235))
            line.line(to: NSPoint(x: p * 0.5 + cos(angle) * p * 0.315, y: p * 0.5 + sin(angle) * p * 0.315))
            NSColor(calibratedRed: 0.19, green: 0.13, blue: 0.055, alpha: 1).setStroke(); line.stroke()
        }
        image.unlockFocus()
        let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: destination.appendingPathComponent(name))
    }
}
