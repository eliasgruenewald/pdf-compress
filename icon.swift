// Renders the 1024×1024 app icon PNG. Usage: swift icon.swift out.png
import AppKit

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

// macOS icon grid: ~10% inset, continuous rounded rect
let rect = NSRect(x: 100, y: 100, width: 824, height: 824)
let path = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)
NSGradient(colors: [
    NSColor(red: 0.86, green: 0.20, blue: 0.18, alpha: 1),
    NSColor(red: 0.62, green: 0.08, blue: 0.14, alpha: 1),
])!.draw(in: path, angle: -90)

let config = NSImage.SymbolConfiguration(pointSize: 430, weight: .regular)
    .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
if let symbol = NSImage(systemSymbolName: "arrow.down.right.and.arrow.up.left", accessibilityDescription: nil)?
    .withSymbolConfiguration(config) {
    let s = symbol.size
    symbol.draw(in: NSRect(x: (size - s.width) / 2, y: (size - s.height) / 2 + 40,
                           width: s.width, height: s.height))
}

let label = "PDF" as NSString
let attrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 150, weight: .heavy),
    .foregroundColor: NSColor.white.withAlphaComponent(0.92),
]
let ls = label.size(withAttributes: attrs)
label.draw(at: NSPoint(x: (size - ls.width) / 2, y: 165), withAttributes: attrs)

image.unlockFocus()

let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!
    .write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
