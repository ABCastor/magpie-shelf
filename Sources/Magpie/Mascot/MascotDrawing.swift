import AppKit

/// The magpie, as drawn. Every figure here is copied from the final drawing
/// (the owner's own, split into moving parts by the design work's
/// `mascot.py`), in that drawing's own 500 × 620 units with y pointing down.
/// Nothing is redrawn or rounded: the app has to show the bird that was
/// approved, and the only way to be sure of that is to carry its numbers.
enum MascotDrawing {

    // MARK: - Parts

    static let body = "M302,33 C344,33 369,53 381,80 C405,84 429,96 441,108 C444,111 443,114 439,116 C424,122 404,127 383,130 C381,146 388,164 397,186 C412,223 417,266 412,309 C403,376 359,415 295,426 C272,431 249,431 228,426 C198,420 174,410 156,398 C142,386 128,370 122,351 C116,300 142,212 194,142 C203,129 208,114 215,93 C230,52 262,33 302,33 Z"
    static let tail = "M156,398 L100,535 C94,549 82,555 71,550 L52,578 C42,593 23,583 30,563 L122,351 C128,370 142,386 156,398 Z"
    static let legFront = "M295,426 L309,456 L325,458 C332,459 331,468 324,467 L286,466 C279,466 279,457 286,457 L296,456 L280,429 Z"
    static let legBack = "M243,429 L255,459 L272,462 C279,463 278,472 271,471 C257,469 243,469 230,471 C223,471 223,461 230,461 L242,459 L228,426 Z"
    static let wing = "M146,334 C163,245 210,176 262,176 C290,176 308,198 305,232 C299,290 242,341 160,349 C149,350 144,345 146,334 Z"
    static let belly = "M327,219 C345,252 369,268 397,271 C396,348 349,405 282,403 C244,402 221,378 221,349 C221,341 226,337 236,334 C286,316 314,275 318,222 C319,216 324,215 327,219 Z"
    static let spark = "M0,-26 C3,-6 6,-3 26,0 C6,3 3,6 0,26 C-3,6 -6,3 -26,0 C-6,-3 -3,-6 0,-26 Z"
    /// The X the magpie carries off in its beak, stroked at `heldXWidth`.
    static let heldX = "M426,100 L456,130 M456,100 L426,130"
    static let heldXWidth: CGFloat = 14

    static let eyeCenter = CGPoint(x: 328, y: 94)
    static let eyeRadius: CGFloat = 9.5
    /// Where the spark of a catch is drawn, and how much it is scaled there.
    static let sparkCenter = CGPoint(x: 474, y: 90)
    static let sparkScale: CGFloat = 1.7

    /// The wing patch's black outline, which keeps it drawn over the belly.
    static let wingOutline: CGFloat = 9
    /// The paper rim the dark drawing puts round the ink body.
    static let darkRim: CGFloat = 18

    // MARK: - Frame

    /// The drawing's frame: the part of its 500 × 620 space the bird occupies.
    static let viewBox = CGRect(x: 10, y: 20, width: 450, height: 580)
    /// The feet stand on this line, 77.8% of the way down the frame. The tail
    /// hangs below it, which is how it comes to hang over the shelf's edge.
    static let feetY: CGFloat = 471
    /// The tip of the bill, the point that bites the X.
    static let billTip = CGPoint(x: 441, y: 112)

    /// The bird's box on the shelf, in points, as the approved page draws it.
    static let size = CGSize(width: 58, height: 75)
    /// How far down the box the feet are: the pivot every scale and squash
    /// happens about, so the bird never leaves the line it stands on.
    static var feetFraction: CGFloat { (feetY - viewBox.minY) / viewBox.height }

    // MARK: - Pivots (the motion kit's transform origins)

    enum Pivot {
        static let tail = CGPoint(x: 142, y: 374)
        static let eye = CGPoint(x: 328, y: 94)
        static let lean = CGPoint(x: 268, y: 445)
        static let wing = CGPoint(x: 275, y: 195)
        static let belly = CGPoint(x: 300, y: 320)
        static let all = CGPoint(x: 268, y: 471)
        static let spark = CGPoint(x: 474, y: 90)
        /// The legs fold about this point in flight.
        static let legs = CGPoint(x: 268, y: 430)
    }

    // MARK: - Colour

    /// The drawing's two inks and the spark. The ink is the bird's black; the
    /// paper is its white. The spark is Castor's terracotta.
    enum Palette {
        static let ink = NSColor(srgbRed: 0x18 / 255, green: 0x1D / 255, blue: 0x1E / 255, alpha: 1)
        static let paper = NSColor(srgbRed: 0xF7 / 255, green: 0xF4 / 255, blue: 0xEC / 255, alpha: 1)
        static let spark = Design.Brand.terracottaValue
    }

    // MARK: - Path parsing

    /// Parses the subset of SVG path syntax the drawing uses: absolute
    /// `M L H V C Q Z`. A command the drawing does not use is a programming
    /// error, so it traps rather than silently dropping a segment.
    static func path(_ d: String) -> CGPath {
        let path = CGMutablePath()
        var tokens = tokenize(d)[...]
        var command: Character = "M"
        var current = CGPoint.zero
        var start = CGPoint.zero

        func number() -> CGFloat {
            guard case .number(let value)? = tokens.popFirst() else {
                preconditionFailure("MascotDrawing: malformed path \(d)")
            }
            return value
        }
        func point() -> CGPoint { CGPoint(x: number(), y: number()) }

        while let token = tokens.first {
            if case .command(let c) = token {
                command = c
                tokens.removeFirst()
                if c == "Z" || c == "z" {
                    path.closeSubpath()
                    current = start
                    continue
                }
            }
            switch command {
            case "M":
                current = point(); start = current
                path.move(to: current)
                command = "L"  // implicit lineto after a moveto
            case "L":
                current = point(); path.addLine(to: current)
            case "H":
                current = CGPoint(x: number(), y: current.y); path.addLine(to: current)
            case "V":
                current = CGPoint(x: current.x, y: number()); path.addLine(to: current)
            case "C":
                let c1 = point(), c2 = point(); current = point()
                path.addCurve(to: current, control1: c1, control2: c2)
            case "Q":
                let c = point(); current = point()
                path.addQuadCurve(to: current, control: c)
            default:
                preconditionFailure("MascotDrawing: unsupported path command \(command)")
            }
        }
        return path
    }

    private enum Token { case command(Character), number(CGFloat) }

    private static func tokenize(_ d: String) -> [Token] {
        var tokens: [Token] = []
        var buffer = ""
        func flush() {
            if !buffer.isEmpty, let value = Double(buffer) { tokens.append(.number(CGFloat(value))) }
            buffer = ""
        }
        for ch in d {
            if ch.isLetter && ch != "e" && ch != "E" {
                flush(); tokens.append(.command(ch))
            } else if ch == "," || ch == " " {
                flush()
            } else if ch == "-" && !buffer.isEmpty && buffer.last != "e" && buffer.last != "E" {
                flush(); buffer.append(ch)
            } else {
                buffer.append(ch)
            }
        }
        flush()
        return tokens
    }
}
