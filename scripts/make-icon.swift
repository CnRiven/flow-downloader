import AppKit
import Foundation

let directory = CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let image = NSImage(size: NSSize(width: pixels, height: pixels))
        image.lockFocus()
        let ctx = NSGraphicsContext.current!.cgContext
        ctx.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
        NSColor(calibratedRed: 0.12, green: 0.19, blue: 0.18, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 48, y: 48, width: 928, height: 928), xRadius: 215, yRadius: 215).fill()
        NSColor(calibratedRed: 0.85, green: 0.93, blue: 0.88, alpha: 1).setStroke()
        let path = NSBezierPath(); path.lineWidth = 60; path.lineCapStyle = .round; path.lineJoinStyle = .round
        path.move(to: NSPoint(x: 512, y: 740)); path.line(to: NSPoint(x: 512, y: 365))
        path.move(to: NSPoint(x: 355, y: 510)); path.line(to: NSPoint(x: 512, y: 352)); path.line(to: NSPoint(x: 669, y: 510))
        path.move(to: NSPoint(x: 326, y: 245)); path.line(to: NSPoint(x: 698, y: 245)); path.stroke()
        image.unlockFocus()
        let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
        let name = "icon_\(size)x\(size)" + (scale == 2 ? "@2x" : "") + ".png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
    }
}
