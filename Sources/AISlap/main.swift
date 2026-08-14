import AppKit

// Phase 0 signal spike. See docs/08-roadmap-and-risks.md.
// Menu-bar only: no Dock icon, no mascot, no interruptions, no network.

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
