import AppKit

/// Doug — a hermit crab who lives in a dead CRT.
///
/// The screen in his shell is his face, which is the whole reason the character works
/// at this size: mood is legible from across the room, and the art is one shell plus a
/// set of tiny faces rather than a full sprite sheet per emotion. He does not honk.
/// He clacks.
///
/// **The grids below are copied verbatim from `Doug.dc.html`,** the design canvas, and
/// are the same strings that file paints from. Keep them identical — if the sprite is
/// edited there, re-copy rather than redrawing by hand, or the app and the design drift
/// and neither is authoritative.
///
/// Three colours, three plates, painted in order: the accent plate is deliberately
/// misregistered by `misregistration` points so he reads as cheap print rather than
/// clean vector. That offset is the character, not a bug.
enum Doug {

    /// Mood is the retention loop from docs/04, expressed as a face rather than a
    /// number. It tracks escalation tier, and lands on `.delighted` when a handoff does.
    enum Mood: String, CaseIterable {
        case sleep, content, watch, annoyed, grumpy, delighted
    }

    static let gridWidth = 34
    static let gridHeight = 22

    /// How far the accent plate is pushed down and right, in points, at any scale.
    static let misregistration: CGFloat = 2

    /// Where the CRT screen sits inside the shell, in grid cells. The face is drawn
    /// into this window and nowhere else.
    static let screen = (x: 5, y: 5, width: 14, height: 7)

    /// `K` dark ink, `W` paper, `P` accent (the claw and base band), `S` accent (the
    /// glowing screen the face is drawn onto). `.` is transparent.
    static let shell: [String] = [
        "..................................",
        "..................................",
        "..KKKKKKKKKKKKKKKKKKKK............",
        "..KWWWWWWWWWWWWWWWWWWK...KKKK.....",
        "..KWKKKKKKKKKKKKKKKKWK..KKPPKK....",
        "..KWKSSSSSSSSSSSSSSKWK..KPPPPKK...",
        "..KWKSSSSSSSSSSSSSSKWK..KPPPPKKK..",
        "..KWKSSSSSSSSSSSSSSKWK..KPPKKPPK..",
        "..KWKSSSSSSSSSSSSSSKWK..KPPK.KKK..",
        "..KWKSSSSSSSSSSSSSSKWK..KPPK......",
        "..KWKSSSSSSSSSSSSSSKWK..KPPK.KKK..",
        "..KWKSSSSSSSSSSSSSSKWK..KPPKKPPK..",
        "..KWKKKKKKKKKKKKKKKKWK..KPPPPKK...",
        "..KWWWWWWWWWWWWWWWWWWK...KPPK.....",
        "..KKKKKKKKKKKKKKKKKKKK...KPPK.....",
        "..KPPPPPPPPPPPPPPPPPPKKKPPKK......",
        "..KPPPPPPPPPPPPPPPPPPKKKK.........",
        "..KKK..KKK..KKK..KKK..............",
        "..KK...KK...KK...KK...............",
        ".KK...KK...KK...KK................",
        ".KK...KK...KK...KK................",
        "KKK..KKK..KKK..KKK................"
    ]

    /// Rows 17–21 swapped in on the alternate walk frame. Two frames is enough: the
    /// legs are three pixels tall and any more reads as noise.
    static let legsAlternate: [String] = [
        "..KKK..KKK..KKK..KKK..............",
        "...KK...KK...KK...KK..............",
        "...KK...KK...KK...KK..............",
        "....KK...KK...KK...KK.............",
        "...KKK..KKK..KKK..KKK............."
    ]

    static let faces: [Mood: [String]] = [
        .sleep: [
            "..............",
            "..............",
            ".KKKK....KKKK.",
            "..............",
            "..............",
            "....KKKK......",
            ".............."
        ],
        .content: [
            "..............",
            "...KK....KK...",
            "...KK....KK...",
            "...KK....KK...",
            "..............",
            "..K......K....",
            "...KKKKKK....."
        ],
        .watch: [
            "..............",
            "..KKKK..KKKK..",
            "..K..K..K..K..",
            "..K.KK..K.KK..",
            "..K.KK..K.KK..",
            "..KKKK..KKKK..",
            "....KKKKKK...."
        ],
        .annoyed: [
            "..KK......KK..",
            "...KK....KK...",
            "..KKKK..KKKK..",
            "..K..K..K..K..",
            "..KKKK..KKKK..",
            "..............",
            "...KKKKKKKK..."
        ],
        .grumpy: [
            ".KK........KK.",
            "..KKK....KKK..",
            "...KKK..KKK...",
            "....K....K....",
            "..............",
            "...KKKKKK.....",
            "..KK......KK.."
        ],
        .delighted: [
            "..K.K....K.K..",
            "...K......K...",
            "..K.K....K.K..",
            "..............",
            "..KKKKKKKKKK..",
            "..KKKKKKKKKK..",
            "...KKKKKKKK..."
        ]
    ]

    struct Palette {
        let paper: NSColor
        let ink: NSColor
        let accent: NSColor

        /// The design file's palette, and what the speech bubble is painted with: dark
        /// ink on paper. Doug commits to one look in both light and dark mode. He is a
        /// printed object, not a piece of system chrome, and a mascot that restyles
        /// itself with the system appearance stops being a character.
        static let standard = Palette(
            paper: NSColor(srgbRed: 0.937, green: 0.910, blue: 0.863, alpha: 1),  // #EFE8DC
            ink: NSColor(srgbRed: 0.110, green: 0.094, blue: 0.082, alpha: 1),    // #1C1815
            accent: NSColor(srgbRed: 1.000, green: 0.243, blue: 0.604, alpha: 1)  // #FF3E9A
        )

        /// **What Doug himself is painted with**, and the one place the design file's
        /// palette had to be reversed rather than copied.
        ///
        /// The canvas sits him on paper, so his silhouette is drawn in near-black ink and
        /// reads perfectly. A desktop is not paper. The first time he appeared on a real
        /// dark desktop the outline and all four legs vanished into the background and he
        /// read as a floating pink CRT with no body.
        ///
        /// So the two flat colours swap: cream silhouette, dark bezel, accent untouched.
        /// Deliberately *not* switched on the system appearance — he cannot see the
        /// wallpaper behind him without Screen Recording, which this app refuses, so
        /// following light mode would only move the failure rather than fix it. One look,
        /// chosen for the desktop he actually lives on.
        static let onDesktop = Palette(
            paper: standard.ink,
            ink: standard.paper,
            accent: standard.accent
        )
    }

    static func size(scale: CGFloat) -> NSSize {
        NSSize(
            width: CGFloat(gridWidth) * scale + misregistration,
            height: CGFloat(gridHeight) * scale + misregistration
        )
    }

    /// Paints Doug into the current graphics context, top-left origin, y increasing
    /// downward — so the view that calls this must be flipped and the grids can stay
    /// exactly as the design file writes them.
    static func draw(
        mood: Mood,
        scale: CGFloat,
        legFrame: Bool = false,
        facingLeft: Bool = false,
        palette: Palette = .onDesktop
    ) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.interpolationQuality = .none

        if facingLeft {
            // He is drawn claw-out to the right. Side-eye means turning to point the
            // screen at your window, so the whole sprite mirrors rather than gaining
            // a second set of grids.
            context.translateBy(x: size(scale: scale).width, y: 0)
            context.scaleBy(x: -1, y: 1)
        }

        var rows = shell
        if legFrame {
            for (offset, row) in legsAlternate.enumerated() { rows[17 + offset] = row }
        }

        let off = misregistration
        plate(rows, matching: ["P", "S"], color: palette.accent, scale: scale, offset: off)
        plate(rows, matching: ["W"], color: palette.paper, scale: scale, offset: 0)
        plate(rows, matching: ["K"], color: palette.ink, scale: scale, offset: 0)

        // The face rides on the accent plate, so it takes the same offset — otherwise
        // it floats free of the screen it is supposed to be inside.
        if let face = faces[mood] {
            palette.ink.setFill()
            for y in 0..<screen.height {
                let row = Array(face[y])
                for x in 0..<screen.width where row[x] == "K" {
                    NSRect(
                        x: CGFloat(screen.x + x) * scale + off,
                        y: CGFloat(screen.y + y) * scale + off,
                        width: scale, height: scale
                    ).fill()
                }
            }
        }

        context.restoreGState()
    }

    private static func plate(
        _ rows: [String], matching: Set<Character>, color: NSColor,
        scale: CGFloat, offset: CGFloat
    ) {
        color.setFill()
        for (y, row) in rows.enumerated() {
            for (x, character) in row.enumerated() where matching.contains(character) {
                NSRect(
                    x: CGFloat(x) * scale + offset,
                    y: CGFloat(y) * scale + offset,
                    width: scale, height: scale
                ).fill()
            }
        }
    }
}
