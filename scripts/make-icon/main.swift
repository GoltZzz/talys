// Renders the Talys app icon (and the README's SVG logo) from `TalysLogo`.
// Usage: make-icon <icon-1024.png> [logo.svg]
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let px = 1024
let args = Array(CommandLine.arguments.dropFirst())
let out = args.first ?? "AppIcon-1024.png"

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: a)
}

let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
// Work in y-down coordinates like the logo geometry.
ctx.translateBy(x: 0, y: CGFloat(px))
ctx.scaleBy(x: 1, y: -1)

// macOS icon grid: 824pt tile inset 100pt, continuous-ish corners.
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: 12), blur: 28, color: rgb(0x000000, 0.35))
ctx.addPath(tilePath)
ctx.setFillColor(rgb(0x1e1e2e))
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(tilePath)
ctx.clip()
let gradient = CGGradient(colorsSpace: nil, colors: [rgb(0x313244), rgb(0x11111b)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 924), options: [])
ctx.restoreGState()

var t = TalysLogo.transform(fitting: tile.insetBy(dx: 130, dy: 120))
let shells = TalysLogo.shells.copy(using: &t)!
let eyes = TalysLogo.eyes.copy(using: &t)!
let spots = TalysLogo.spots.copy(using: &t)!
let k = t.a

ctx.setLineJoin(.round)
ctx.setLineCap(.round)

ctx.addPath(shells)
ctx.setFillColor(rgb(0xf5e0dc, 0.08))
ctx.fillPath()

ctx.addPath(shells)
ctx.addPath(eyes)
ctx.setStrokeColor(rgb(0xf5e0dc))
ctx.setLineWidth(TalysLogo.shellStroke * k)
ctx.strokePath()

ctx.addPath(spots)
ctx.setStrokeColor(rgb(0xfab387))
ctx.setLineWidth(TalysLogo.spotStroke * k)
ctx.strokePath()

let image = ctx.makeImage()!
let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: out) as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, image, nil)
CGImageDestinationFinalize(dest)
print("Wrote \(out)")

// MARK: - SVG logo (adapts to light/dark on GitHub)

func svgPathData(_ path: CGPath) -> String {
    var d: [String] = []
    func f(_ p: CGPoint) -> String { String(format: "%g %g", p.x, p.y) }
    path.applyWithBlock { el in
        let pts = el.pointee.points
        switch el.pointee.type {
        case .moveToPoint: d.append("M\(f(pts[0]))")
        case .addLineToPoint: d.append("L\(f(pts[0]))")
        case .addQuadCurveToPoint: d.append("Q\(f(pts[0])) \(f(pts[1]))")
        case .addCurveToPoint: d.append("C\(f(pts[0])) \(f(pts[1])) \(f(pts[2]))")
        case .closeSubpath: d.append("Z")
        @unknown default: break
        }
    }
    return d.joined(separator: " ")
}

if args.count > 1 {
    let size = TalysLogo.designSize
    let svg = """
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 \(Int(size.width)) \(Int(size.height))" width="\(Int(size.width))" height="\(Int(size.height))">
      <style>
        .shell { fill: none; stroke: #1a1d27; stroke-width: \(TalysLogo.shellStroke); stroke-linejoin: round; stroke-linecap: round; }
        .spot { fill: none; stroke: #1a1d27; stroke-width: \(TalysLogo.spotStroke); stroke-linejoin: round; }
        @media (prefers-color-scheme: dark) {
          .shell { stroke: #f5e0dc; }
          .spot { stroke: #f5e0dc; }
        }
      </style>
      <path class="shell" d="\(svgPathData(TalysLogo.shells))"/>
      <path class="shell" d="\(svgPathData(TalysLogo.eyes))"/>
      <path class="spot" d="\(svgPathData(TalysLogo.spots))"/>
    </svg>

    """
    try! svg.write(toFile: args[1], atomically: true, encoding: .utf8)
    print("Wrote \(args[1])")
}
