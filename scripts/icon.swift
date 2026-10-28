import AppKit
let root = CommandLine.arguments[1]
let image = NSImage(size: NSSize(width: 1024, height: 1024))
image.lockFocus()
let background = NSBezierPath(roundedRect: NSRect(x: 32, y: 32, width: 960, height: 960), xRadius: 210, yRadius: 210)
NSColor(calibratedRed: 0.06, green: 0.11, blue: 0.19, alpha: 1).setFill(); background.fill()
let monitor = NSBezierPath(roundedRect: NSRect(x: 162, y: 270, width: 700, height: 510), xRadius: 46, yRadius: 46)
NSColor(calibratedRed: 0.45, green: 0.9, blue: 0.62, alpha: 1).setFill(); monitor.fill()
NSColor(calibratedRed: 0.06, green: 0.11, blue: 0.19, alpha: 1).setFill()
NSBezierPath(roundedRect: NSRect(x: 192, y: 308, width: 640, height: 438), xRadius: 24, yRadius: 24).fill()
NSColor(calibratedRed: 0.45, green: 0.9, blue: 0.62, alpha: 1).setFill()
NSBezierPath(roundedRect: NSRect(x: 430, y: 174, width: 164, height: 32), xRadius: 16, yRadius: 16).fill()
NSBezierPath(rect: NSRect(x: 492, y: 198, width: 40, height: 75)).fill()
let head = NSBezierPath(roundedRect: NSRect(x: 352, y: 402, width: 320, height: 222), xRadius: 74, yRadius: 74); head.fill()
let antenna = NSBezierPath(); antenna.lineWidth = 17; antenna.lineCapStyle = .round
antenna.move(to: NSPoint(x: 395,y: 594)); antenna.line(to: NSPoint(x: 365,y: 659)); antenna.move(to: NSPoint(x: 629,y: 594)); antenna.line(to: NSPoint(x: 659,y: 659)); NSColor(calibratedRed: 0.45, green: 0.9, blue: 0.62, alpha: 1).setStroke(); antenna.stroke()
NSColor(calibratedRed: 0.06, green: 0.11, blue: 0.19, alpha: 1).setFill()
NSBezierPath(ovalIn: NSRect(x: 425, y: 517, width: 28, height: 28)).fill(); NSBezierPath(ovalIn: NSRect(x: 571,y: 517,width: 28,height: 28)).fill()
image.unlockFocus()
try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
for size in [16,32,128,256,512] {
 for scale in [1,2] {
  let pixels = size * scale
  let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
  NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
  image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels)); NSGraphicsContext.restoreGraphicsState()
  try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: root + "/icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"))
 }
}
