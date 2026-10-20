import AppKit

/// How see-through the shelf is: one slider, from a light frost to fully
/// solid, frosted by default.
///
/// The panel is the system's blur with a coat of the window ground over it,
/// and the slider sets how thick that coat is. **The light end is not
/// "transparent", it is the thinnest coat that keeps every file name
/// readable over anything at all**, measured with no credit given to the
/// blur: the worst case is a white page behind a dark shelf, or a black one
/// behind a light shelf, and the floor is the coat at which a file's name
/// still clears 4.5:1 and its size-and-kind line 3:1 over both.
/// `GlassTests` re-derives that from the live colours.
enum ShelfGlass {
    static let defaultsKey = "shelf.glass"
    /// Frosted: a little under halfway along.
    static let defaultValue: Double = 0.4
    /// The coat at the slider's light end.
    static let floor: CGFloat = 0.75

    /// The coat's opacity for a slider value in 0...1.
    static func groundAlpha(_ value: Double) -> CGFloat {
        let v = CGFloat(min(1, max(0, value)))
        return floor + (1 - floor) * v
    }

    static var current: Double {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: defaultsKey) != nil else { return defaultValue }
        return defaults.double(forKey: defaultsKey)
    }
}

/// Whether summoned shelves open as an island under the notch. Off unless
/// the user switches it on, so an unset key reading false is the default and
/// the key is deliberately not registered.
enum ShelfNotch {
    static let defaultsKey = "shelf.notch"

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: defaultsKey) }

    /// The camera housing's height on a screen that has one, else nil.
    static func notchHeight(of screen: NSScreen) -> CGFloat? {
        let top = screen.safeAreaInsets.top
        return top > 0 ? top : nil
    }

    /// The island for a shelf of `size` under `screen`'s notch: centred on
    /// the notch, its top flush with the screen's top, the band under the
    /// camera left empty above the header. The magpie stands on the island's
    /// bottom edge like on any shelf.
    static func islandFrame(size: CGSize, screen: NSRect, notchHeight: CGFloat) -> NSRect {
        let height = size.height + notchHeight
        return NSRect(
            x: screen.midX - size.width / 2,
            y: screen.maxY - height,
            width: size.width,
            height: height
        )
    }
}

/// Whether the magpie is on the shelves. Registered on: it is there until the
/// user sends it away with its X, or switches it off in Settings.
enum MascotPreference {
    static let defaultsKey = "shelf.mascot.shown"

    static var isShown: Bool { UserDefaults.standard.bool(forKey: defaultsKey) }

    static func set(_ shown: Bool) {
        UserDefaults.standard.set(shown, forKey: defaultsKey)
    }
}
