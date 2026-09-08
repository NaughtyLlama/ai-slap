import AppKit

let moods = Doug.Mood.allCases
let scale: CGFloat = 6
let cell = Doug.size(scale: scale)
let pad: CGFloat = 24
let cols = 3
let rows = 3
let W = (cell.width + pad) * CGFloat(cols) + pad
let H = (cell.height + pad) * CGFloat(rows) + pad

let image = NSImage(size: NSSize(width: W, height: H))
image.lockFocus()
// A dark ground, because that is what Doug.Palette.onDesktop is drawn for.
NSColor(srgbRed: 0.07, green: 0.07, blue: 0.07, alpha: 1).setFill()
NSRect(x: 0, y: 0, width: W, height: H).fill()

var tiles: [(String, Doug.Mood, Bool, Bool)] = moods.map { ($0.rawValue, $0, false, false) }
tiles.append(("walk", .grumpy, true, false))
tiles.append(("mirrored", .watch, false, true))

for (index, tile) in tiles.enumerated() {
    let col = index % cols
    let row = index / cols
    let x = pad + (cell.width + pad) * CGFloat(col)
    let y = H - cell.height - pad - (cell.height + pad) * CGFloat(row)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.saveGState()
    ctx.translateBy(x: x, y: y + cell.height)
    ctx.scaleBy(x: 1, y: -1)   // flip so the sprite's top-left grid draws upright
    Doug.draw(mood: tile.1, scale: scale, legFrame: tile.2, facingLeft: tile.3)
    ctx.restoreGState()

    let label = NSAttributedString(string: tile.0, attributes: [
        .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .bold),
        .foregroundColor: NSColor.white,
    ])
    label.draw(at: NSPoint(x: x, y: y - 16))
}
image.unlockFocus()

let data = image.tiffRepresentation!
let png = NSBitmapImageRep(data: data)!.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
