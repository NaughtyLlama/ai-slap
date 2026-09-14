import AppKit

/// Renders the review dialog offscreen, at both of its shapes, so it can be looked at
/// without triggering a handoff — and on a Mac whose display is asleep, where
/// screenshotting returns black.
let out = CommandLine.arguments[1]
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

func pixel(_ w: Int, _ h: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(red: 0.13, green: 0.14, blue: 0.16, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    ctx.setFillColor(CGColor(red: 1, green: 0.24, blue: 0.60, alpha: 1))
    ctx.fill(CGRect(x: 40, y: 40, width: w - 80, height: 60))
    ctx.setFillColor(CGColor(red: 0.93, green: 0.91, blue: 0.86, alpha: 1))
    for row in 0..<6 {
        ctx.fill(CGRect(x: 40, y: 140 + row * 40, width: w - 80 - row * 30, height: 16))
    }
    return ctx.makeImage()!
}

func render(_ alert: NSAlert, to name: String) {
    alert.layout()
    let window = alert.window
    window.setFrame(window.frame, display: true)
    guard let view = window.contentView,
          let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
        print("could not render \(name)"); return
    }
    view.cacheDisplay(in: view.bounds, to: rep)
    guard let png = rep.representation(using: .png, properties: [:]) else { return }
    try? png.write(to: URL(fileURLWithPath: "\(out)/\(name).png"))
    print("wrote \(name).png  \(Int(view.bounds.width))x\(Int(view.bounds.height))")
}

let withShot = HandoffRecovery.makeReviewAlert(
    image: pixel(880, 520), hasPermission: true, prompt: HandoffRecovery.defaultPrompt
)
render(withShot.alert, to: "dialog-with-screenshot")

let noShot = HandoffRecovery.makeReviewAlert(
    image: nil, hasPermission: false, prompt: HandoffRecovery.defaultPrompt
)
render(noShot.alert, to: "dialog-no-screenshot")

render(Onboarding.makeWelcomeAlert().0, to: "welcome")
render(Onboarding.makePermissionsAlert(.init(accessibility: false, screen: false)), to: "permissions-both")
render(Onboarding.makePermissionsAlert(.init(accessibility: true, screen: false)), to: "permissions-screenshots")
