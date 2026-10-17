// Draws the distractorRemover app icon and writes Resources/AppIcon.icns plus
// docs/images/icon.png. Drawn from vector paths (no SF Symbols, whose license
// excludes app icons), so every size is crisp.
//
//   swift scripts/make_icon.swift
import AppKit
import Foundation

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// The shield outline in a 1024-point canvas (origin bottom-left).
func shieldPath() -> CGPath {
    let path = CGMutablePath()
    path.move(to: CGPoint(x: 512, y: 812))                                   // top centre
    path.addCurve(to: CGPoint(x: 302, y: 732),
                  control1: CGPoint(x: 440, y: 772), control2: CGPoint(x: 372, y: 744))
    path.addLine(to: CGPoint(x: 302, y: 520))
    path.addCurve(to: CGPoint(x: 512, y: 212),
                  control1: CGPoint(x: 302, y: 372), control2: CGPoint(x: 398, y: 268))
    path.addCurve(to: CGPoint(x: 722, y: 520),
                  control1: CGPoint(x: 626, y: 268), control2: CGPoint(x: 722, y: 372))
    path.addLine(to: CGPoint(x: 722, y: 732))
    path.addCurve(to: CGPoint(x: 512, y: 812),
                  control1: CGPoint(x: 652, y: 744), control2: CGPoint(x: 584, y: 772))
    path.closeSubpath()
    return path
}

func drawIcon(in ctx: CGContext) {
    // Body on Apple's macOS icon grid: 824×824 centred, corner radius 185.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let bodyPath = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

    // Soft drop shadow under the body.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.28))
    ctx.addPath(bodyPath)
    ctx.setFillColor(color(0x1E3A8A))
    ctx.fillPath()
    ctx.restoreGState()

    // Calm blue-to-teal gradient.
    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                              colors: [color(0x2563EB), color(0x0D9488)] as CFArray,
                              locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    // Gentle top highlight.
    let shine = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                           colors: [color(0xFFFFFF, 0.18), color(0xFFFFFF, 0)] as CFArray,
                           locations: [0, 1])!
    ctx.drawLinearGradient(shine, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 560), options: [])
    ctx.restoreGState()

    // White shield with a slight shadow.
    let shield = shieldPath()
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: color(0x0B1F4D, 0.35))
    ctx.addPath(shield)
    ctx.setFillColor(color(0xFFFFFF))
    ctx.fillPath()
    ctx.restoreGState()

    // A rounded "blocked" bar across the shield, in the gradient's mid colour.
    let bar = CGRect(x: 392, y: 482, width: 240, height: 72)
    ctx.addPath(CGPath(roundedRect: bar, cornerWidth: 36, cornerHeight: 36, transform: nil))
    ctx.setFillColor(color(0x1D6FD1))
    ctx.fillPath()
}

func renderPNG(size: Int, to url: URL) throws {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                              space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        throw NSError(domain: "icon", code: 1)
    }
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high
    ctx.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    drawIcon(in: ctx)
    guard let image = ctx.makeImage(),
          let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
        throw NSError(domain: "icon", code: 2)
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { throw NSError(domain: "icon", code: 3) }
}

let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    try renderPNG(size: points, to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    try renderPNG(size: points * 2, to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}

let resources = root.appendingPathComponent("Resources")
try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
let icns = resources.appendingPathComponent("AppIcon.icns")
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }

try renderPNG(size: 512, to: root.appendingPathComponent("docs/images/icon.png"))
try? FileManager.default.removeItem(at: iconset)
print("wrote \(icns.path) and docs/images/icon.png")
