// Generates the InkSweep app icon (1024px PNG) into Scripts/.
// Ink language: washi paper ground, sumi brush stroke, vermilion seal.
//
// Usage: swift Scripts/icongen.swift [output.png]

import AppKit

let size = 1024.0

guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(size), pixelsHigh: Int(size),
    bitsPerSample: 8, samplesPerPixel: 4,
    hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0, bitsPerPixel: 0
) else { fatalError("could not create bitmap") }
rep.size = NSSize(width: size, height: size)

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

// Washi paper ground.
NSColor(calibratedRed: 0.965, green: 0.957, blue: 0.933, alpha: 1).setFill()
ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))

// Sumi brush stroke — one tapered pass across the middle.
let sumi = NSColor(calibratedRed: 0.11, green: 0.10, blue: 0.09, alpha: 1)
sumi.setFill()
let stroke = CGMutablePath()
stroke.move(to: CGPoint(x: 110, y: 470))
stroke.addCurve(to: CGPoint(x: 900, y: 660),
                control1: CGPoint(x: 340, y: 780),
                control2: CGPoint(x: 660, y: 700))
stroke.addCurve(to: CGPoint(x: 790, y: 530),
                control1: CGPoint(x: 970, y: 700),
                control2: CGPoint(x: 900, y: 580))
stroke.addCurve(to: CGPoint(x: 150, y: 430),
                control1: CGPoint(x: 620, y: 480),
                control2: CGPoint(x: 330, y: 420))
stroke.closeSubpath()
ctx.addPath(stroke)
ctx.fillPath()

// Ink splatter dot, for hand-drawn character.
ctx.setFillColor(sumi.withAlphaComponent(0.55).cgColor)
ctx.fillEllipse(in: CGRect(x: 210, y: 330, width: 34, height: 26))
ctx.setFillColor(sumi.withAlphaComponent(0.35).cgColor)
ctx.fillEllipse(in: CGRect(x: 280, y: 290, width: 16, height: 13))

// Vermilion seal, bottom-right.
let sealRect = CGRect(x: 560, y: 110, width: 310, height: 310)
NSColor(calibratedRed: 0.80, green: 0.23, blue: 0.19, alpha: 1).setFill()
ctx.addPath(CGPath(roundedRect: sealRect, cornerWidth: 54, cornerHeight: 54, transform: nil))
ctx.fillPath()

// 掃 ("sweep") in the seal.
let paragraph = NSMutableParagraphStyle()
paragraph.alignment = .center
let attrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 196, weight: .semibold),
    .foregroundColor: NSColor.white,
    .paragraphStyle: paragraph,
]
let text = NSAttributedString(string: "掃", attributes: attrs)
let bounds = text.boundingRect(with: NSSize(width: sealRect.width, height: sealRect.height),
                               options: [.usesLineFragmentOrigin])
text.draw(in: CGRect(
    x: sealRect.minX,
    y: sealRect.minY + (sealRect.height - bounds.height) / 2 - 6,
    width: sealRect.width,
    height: sealRect.height
))

NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("could not encode png")
}
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Scripts/icon-1024.png"
try! png.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
