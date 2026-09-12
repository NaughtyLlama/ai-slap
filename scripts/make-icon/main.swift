import AppKit

/// Renders Doug into an .iconset. He is the only picture this app has, and an app you
/// are asking ten people to trust should not arrive wearing the blank placeholder.
let out = CommandLine.arguments[1]
let palette = Doug.Palette.standard

/// macOS icons sit inside a rounded square with a margin — full-bleed artwork reads as
/// a foreign object next to everything else in the Dock.
func icon(px: CGFloat) -> Data {
    let image = NSImage(size: NSSize(width: px, height: px))
    image.lockFocus()
    let ctx = NSGraphicsContext.current!.cgContext

    let inset = px * 0.08
    let plate = NSRect(x: inset, y: inset, width: px - inset * 2, height: px - inset * 2)
    let radius = plate.width * 0.2237
    palette.ink.setFill()
    NSBezierPath(roundedRect: plate, xRadius: radius, yRadius: radius).fill()

    // Doug as large as he goes without touching the corners, centred on the plate.
    let unit = Doug.size(scale: 1)
    let scale = floor((plate.width * 0.74) / unit.width)
    let sprite = Doug.size(scale: scale)
    ctx.saveGState()
    ctx.translateBy(
        x: (px - sprite.width) / 2,
        y: (px - sprite.height) / 2 + sprite.height
    )
    ctx.scaleBy(x: 1, y: -1)  // the sprite grid draws from its top-left
    Doug.draw(mood: .content, scale: scale, legFrame: false, facingLeft: false)
    ctx.restoreGState()

    image.unlockFocus()
    let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
    return rep.representation(using: .png, properties: [:])!
}

let sizes: [(Int, Int)] = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2),
                           (256, 1), (256, 2), (512, 1), (512, 2)]
for (point, scale) in sizes {
    let name = scale == 1 ? "icon_\(point)x\(point).png" : "icon_\(point)x\(point)@2x.png"
    let data = icon(px: CGFloat(point * scale))
    try! data.write(to: URL(fileURLWithPath: "\(out)/\(name)"))
}
print("wrote \(sizes.count) sizes to \(out)")
