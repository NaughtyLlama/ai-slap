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

    /// One cell of clear space on every side, so the keyline has somewhere to be drawn.
    /// Without it the halo falls outside the view and is clipped away on three sides.
    static let haloPad = 1

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

        /// The one-pixel halo drawn around Doug's whole silhouette, and the reason he
        /// can stand anywhere.
        ///
        /// This is the second attempt. The first was a palette swap: the canvas sits him
        /// on paper, so his silhouette is near-black ink, and on a dark desktop that
        /// silhouette *is* the background — the outline and all four legs vanished and he
        /// read as a floating pink CRT. Reversing the two flat colours fixed the dark
        /// desktop and broke the light one, because a mascot does not stay on the
        /// desktop: he stands on top of whatever window you are working in, and half of
        /// those are white.
        ///
        /// **No single choice of silhouette colour survives both.** Following the system
        /// appearance does not either — it describes the desktop, and he is rarely on it.
        /// So he carries both colours: the design file's ink silhouette exactly as drawn,
        /// wrapped in a paper keyline. One of the two always contrasts, on any backdrop,
        /// without needing to know what the backdrop is — which matters because reading
        /// it would need Screen Recording, and this app refuses that.
        static let keyline = standard.paper
    }

    /// The cells that are empty but touch a solid one — the halo's footprint.
    ///
    /// Computed once. It is only a few hundred cells, but it is otherwise recomputed on
    /// every frame of every walk, and `docs/04` budgets this character in fractions of a
    /// percent of CPU.
    ///
    /// Note this is a *ring*, not a fill. Filling the silhouette and drawing on top of it
    /// looks identical on a shape with no holes and swallows Doug's legs, which have gaps
    /// between them that the ring is supposed to trace.
    static let halo: [(x: Int, y: Int)] = {
        func solid(_ x: Int, _ y: Int) -> Bool {
            guard y >= 0, y < shell.count else { return false }
            let row = Array(shell[y])
            guard x >= 0, x < row.count else { return false }
            return row[x] != "."
        }
        var cells: [(x: Int, y: Int)] = []
        for y in -1...gridHeight {
            for x in -1...gridWidth where !solid(x, y) {
                let touching = (-1...1).contains { dy in
                    (-1...1).contains { dx in solid(x + dx, y + dy) }
                }
                if touching { cells.append((x, y)) }
            }
        }
        return cells
    }()

    static func size(scale: CGFloat) -> NSSize {
        let padding = CGFloat(haloPad * 2) * scale
        return NSSize(
            width: CGFloat(gridWidth) * scale + padding + misregistration,
            height: CGFloat(gridHeight) * scale + padding + misregistration
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
        palette: Palette = .standard
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

        // Every coordinate below is pushed in by one cell to leave room for the keyline,
        // which is the only thing allowed to occupy that margin.
        let pad = CGFloat(haloPad) * scale

        // Drawn before anything else, so every plate lands on top of it.
        Palette.keyline.setFill()
        for cell in halo {
            NSRect(x: CGFloat(cell.x) * scale + pad, y: CGFloat(cell.y) * scale + pad,
                   width: scale, height: scale).fill()
        }

        let off = misregistration + pad
        plate(rows, matching: ["P", "S"], color: palette.accent, scale: scale, offset: off)
        plate(rows, matching: ["W"], color: palette.paper, scale: scale, offset: pad)
        plate(rows, matching: ["K"], color: palette.ink, scale: scale, offset: pad)

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
