import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

func shot(_ tail: Bool, _ path: String) {
    let nudge = NudgePanel()
    nudge.show(
        copy: "Still on that one email. Want a draft instead?",
        prompt: "Here's an email I need to reply to. Draft a concise reply in my voice.",
        anchor: tail ? NSRect(x: 400, y: 100, width: 104, height: 68) : nil
    ) { _ in }
    guard let view = nudge.panelForPreview?.contentView else { print("no view"); return }
    view.layoutSubtreeIfNeeded()
    guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
    view.cacheDisplay(in: view.bounds, to: rep)
    let png = rep.representation(using: .png, properties: [:])!
    try! png.write(to: URL(fileURLWithPath: path))
    nudge.close()
}

shot(true, CommandLine.arguments[1])
shot(false, CommandLine.arguments[2])
