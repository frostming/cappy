// Renders the app icon: swift Scripts/make_icon.swift <output.png>
import AppKit

let size = 1024
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
ctx.addPath(CGPath(roundedRect: tile, cornerWidth: 186, cornerHeight: 186, transform: nil))
ctx.clip()
let colors = [CGColor(srgbRed: 0.40, green: 0.49, blue: 0.92, alpha: 1),
              CGColor(srgbRed: 0.46, green: 0.29, blue: 0.64, alpha: 1)] as CFArray
let gradient = CGGradient(colorsSpace: nil, colors: colors, locations: nil)!
ctx.drawLinearGradient(gradient, start: CGPoint(x: tile.minX, y: tile.maxY), end: CGPoint(x: tile.maxX, y: tile.minY), options: [])

// Viewfinder corners.
ctx.setStrokeColor(.white)
ctx.setLineWidth(58)
ctx.setLineCap(.round)
ctx.setLineJoin(.round)
let frame = tile.insetBy(dx: 190, dy: 190)
let arm: CGFloat = 130, r: CGFloat = 60
for (cx, cy, sx, sy) in [(frame.minX, frame.minY, 1.0, 1.0), (frame.maxX, frame.minY, -1.0, 1.0),
                         (frame.minX, frame.maxY, 1.0, -1.0), (frame.maxX, frame.maxY, -1.0, -1.0)] {
    ctx.move(to: CGPoint(x: cx + sx * arm, y: cy))
    ctx.addArc(tangent1End: CGPoint(x: cx, y: cy), tangent2End: CGPoint(x: cx, y: cy + sy * arm), radius: r)
    ctx.addLine(to: CGPoint(x: cx, y: cy + sy * arm))
    ctx.strokePath()
}
ctx.setFillColor(.white)
ctx.fillEllipse(in: CGRect(x: 512 - 74, y: 512 - 74, width: 148, height: 148))

let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
