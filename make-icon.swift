// Draws the app icon: Steam-style navy-to-blue background with "GPTK" in white.
// Usage: swift make-icon.swift out.png
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

func rgb(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: 1)
}

// macOS icon grid: 824 pt tile centred in the 1024 canvas.
let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
let shape = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)

// Soft drop shadow under the tile.
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
shadow.shadowBlurRadius = 28
shadow.shadowOffset = NSSize(width: 0, height: -12)
shadow.set()
rgb(0x171a21).setFill()
shape.fill()
NSGraphicsContext.restoreGraphicsState()

// Steam colours: dark navy at the top left into Steam blue at the bottom right.
NSGraphicsContext.saveGraphicsState()
shape.addClip()
NSGradient(colors: [rgb(0x171a21), rgb(0x1b2838), rgb(0x2a475e), rgb(0x1a9fff)],
           atLocations: [0, 0.35, 0.72, 1], colorSpace: .sRGB)!.draw(in: tile, angle: -50)
// Light-blue glow in the lower right, like Steam's client accents.
NSGradient(colors: [rgb(0x66c0f4).withAlphaComponent(0.45), rgb(0x66c0f4).withAlphaComponent(0)])!
    .draw(fromCenter: NSPoint(x: 800, y: 220), radius: 0, toCenter: NSPoint(x: 800, y: 220), radius: 520, options: [])
NSGraphicsContext.restoreGraphicsState()

// Thin inner edge highlight.
rgb(0x66c0f4).withAlphaComponent(0.35).setStroke()
let edge = NSBezierPath(roundedRect: tile.insetBy(dx: 3, dy: 3), xRadius: 182, yRadius: 182)
edge.lineWidth = 6
edge.stroke()

// "GPTK"
let font = NSFont.systemFont(ofSize: 250, weight: .black)
let para = NSMutableParagraphStyle()
para.alignment = .center
let textShadow = NSShadow()
textShadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
textShadow.shadowBlurRadius = 14
textShadow.shadowOffset = NSSize(width: 0, height: -6)
let attrs: [NSAttributedString.Key: Any] = [
    .font: font, .foregroundColor: NSColor.white, .paragraphStyle: para,
    .kern: -6, .shadow: textShadow,
]
let text = NSAttributedString(string: "GPTK", attributes: attrs)
let h = text.size().height
text.draw(in: NSRect(x: 100, y: 512 - h / 2 + 10, width: 824, height: h))

// Accent bar under the word, in Steam's light blue.
rgb(0x66c0f4).setFill()
NSBezierPath(roundedRect: NSRect(x: 362, y: 330, width: 300, height: 22), xRadius: 11, yRadius: 11).fill()

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
