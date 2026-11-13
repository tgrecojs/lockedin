// Draws LockedIn's app icon (a padlock on a macOS rounded square) and packs it into an .icns.
// The output is checked in; rerun only to change the icon: swift scripts/make-icon.swift Resources/AppIcon.icns
// Drawn by hand because the SF Symbols license does not allow symbols in app icons.
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.dropFirst().first ?? "AppIcon.icns"
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a) }

// Background: Apple's macOS icon grid, an 824 pt rounded square inset 100 pt, with a soft drop shadow.
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgb(0, 0, 0, 0.35))
ctx.addPath(tilePath); ctx.setFillColor(rgb(30, 41, 89)); ctx.fillPath()
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(tilePath); ctx.clip()
let bg = CGGradient(colorsSpace: space, colors: [rgb(76, 99, 230), rgb(33, 38, 110)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
ctx.restoreGState()

// Shackle: a thick U, drawn first so the body covers its feet.
let shackle = CGMutablePath()
let sx: CGFloat = 512, shackleTop: CGFloat = 760, halfW: CGFloat = 135, feet: CGFloat = 470
shackle.move(to: CGPoint(x: sx - halfW, y: feet))
shackle.addLine(to: CGPoint(x: sx - halfW, y: shackleTop - halfW))
shackle.addArc(center: CGPoint(x: sx, y: shackleTop - halfW), radius: halfW, startAngle: .pi, endAngle: 0, clockwise: true)
shackle.addLine(to: CGPoint(x: sx + halfW, y: feet))
ctx.saveGState()
ctx.addPath(shackle); ctx.setLineWidth(72); ctx.setLineCap(.butt)
ctx.setStrokeColor(rgb(214, 220, 240)); ctx.strokePath()
ctx.restoreGState()

// Body.
let body = CGRect(x: 512 - 225, y: 230, width: 450, height: 330)
let bodyPath = CGPath(roundedRect: body, cornerWidth: 64, cornerHeight: 64, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 18, color: rgb(0, 0, 0, 0.25))
ctx.addPath(bodyPath); ctx.setFillColor(.white); ctx.fillPath()
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(bodyPath); ctx.clip()
let bodyShade = CGGradient(colorsSpace: space, colors: [rgb(255, 255, 255), rgb(222, 227, 242)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bodyShade, start: CGPoint(x: 512, y: body.maxY), end: CGPoint(x: 512, y: body.minY), options: [])
ctx.restoreGState()

// Keyhole: a circle over a tapered slot, in the tile's dark blue.
let keyhole = CGMutablePath()
keyhole.move(to: CGPoint(x: 512 - 20, y: 420))
keyhole.addLine(to: CGPoint(x: 512 + 20, y: 420))
keyhole.addLine(to: CGPoint(x: 512 + 30, y: 310))
keyhole.addLine(to: CGPoint(x: 512 - 30, y: 310))
keyhole.closeSubpath()
ctx.setFillColor(rgb(33, 38, 110))
ctx.addEllipse(in: CGRect(x: 512 - 42, y: 405, width: 84, height: 84)); ctx.fillPath()
ctx.addPath(keyhole); ctx.fillPath()

// Every size iconutil expects, downscaled from the 1024 px master.
let master = ctx.makeImage()!
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = points * scale
        let small = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                              space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        small.interpolationQuality = .high
        small.draw(master, in: CGRect(x: 0, y: 0, width: px, height: px))
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try! NSBitmapImageRep(cgImage: small.makeImage()!).representation(using: .png, properties: [:])!
            .write(to: iconset.appendingPathComponent(name))
    }
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", out]
try! iconutil.run()
iconutil.waitUntilExit()
exit(iconutil.terminationStatus)
