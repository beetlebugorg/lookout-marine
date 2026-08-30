//  frame-device.swift — draw a device body around a simulator screenshot.
//
//  The simulator writes the screen only. The README frames put a body around it,
//  so a phone frame and a tablet frame read as devices next to the desktop
//  windows. The screenshot protocol (docs/docs/screenshots.md) states the sizes.
//
//  swift apple/frame-device.swift <in.png> <out.png> <bezel> <bodyRadius> \
//        <screenRadius> [camera:0|1]

import AppKit
import CoreGraphics
import UniformTypeIdentifiers
let a = CommandLine.arguments
guard a.count >= 6,
      let src = NSImage(contentsOfFile: a[1])?
          .cgImage(forProposedRect: nil, context: nil, hints: nil),
      let bezel = Double(a[3]), let bodyRadius = Double(a[4]), let screenRadius = Double(a[5])
else {
    FileHandle.standardError.write(Data("usage: frame in out bezel bodyR screenR [camera]\n".utf8))
    exit(2)
}
let camera = a.count > 6 ? a[6] == "1" : true

let sw = Double(src.width), sh = Double(src.height)
let bw = sw + bezel * 2, bh = sh + bezel * 2
let margin = bezel * 1.2                       // room for the shadow
let cw = Int(bw + margin * 2), ch = Int(bh + margin * 2)

guard let ctx = CGContext(data: nil, width: cw, height: ch, bitsPerComponent: 8, bytesPerRow: 0,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
else { exit(3) }

let body = CGRect(x: margin, y: margin, width: bw, height: bh)
let screen = CGRect(x: margin + bezel, y: margin + bezel, width: sw, height: sh)

ctx.setShadow(offset: CGSize(width: 0, height: -bezel * 0.35), blur: bezel * 1.1,
              color: CGColor(gray: 0, alpha: 0.35))
ctx.addPath(CGPath(roundedRect: body, cornerWidth: bodyRadius, cornerHeight: bodyRadius, transform: nil))
ctx.setFillColor(CGColor(red: 0.09, green: 0.09, blue: 0.10, alpha: 1))
ctx.fillPath()
ctx.setShadow(offset: .zero, blur: 0, color: nil)

// The rim catches the light, as the metal edge of a device does.
ctx.addPath(CGPath(roundedRect: body.insetBy(dx: 1.5, dy: 1.5),
                   cornerWidth: bodyRadius, cornerHeight: bodyRadius, transform: nil))
ctx.setStrokeColor(CGColor(red: 0.35, green: 0.36, blue: 0.38, alpha: 1))
ctx.setLineWidth(3)
ctx.strokePath()

ctx.saveGState()
ctx.addPath(CGPath(roundedRect: screen, cornerWidth: screenRadius, cornerHeight: screenRadius, transform: nil))
ctx.clip()
ctx.draw(src, in: screen)
ctx.restoreGState()

if camera {
    let r = bezel * 0.13
    let dot = CGRect(x: margin + bw / 2 - r, y: margin + bh - bezel / 2 - r, width: r * 2, height: r * 2)
    ctx.addEllipse(in: dot)
    ctx.setFillColor(CGColor(red: 0.16, green: 0.17, blue: 0.19, alpha: 1))
    ctx.fillPath()
}

guard let out = ctx.makeImage(),
      let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: a[2]) as CFURL,
                                                 UTType.png.identifier as CFString, 1, nil)
else { exit(4) }
CGImageDestinationAddImage(dest, out, nil)
guard CGImageDestinationFinalize(dest) else { exit(5) }
print("wrote \(a[2]) \(out.width)x\(out.height)")
