import AppKit

/// How see-through the shelf is: one slider, from the system's own glass to
/// fully solid, frosted by default.
///
/// The panel is the system's blur with a coat of the window ground over it,
/// and the slider sets how thick that coat is. At the light end there is no
/// coat at all: the shelf is exactly the material macOS draws for its own
/// translucent surfaces, with the system's own legibility, which is what the
/// owner asked for after finding a light end that was already 75% solid did
/// nothing visible (2026-10-20: "really like Apple does"). The coat grows
/// along a curve, `1 - (1 - v)^1.6`, faster at first and slower towards
/// solid, so the travel is spent where the eye sees a difference, yet the
/// last tenth still visibly closes the glass (a square curve left it 1%);
/// the default sits at 0.7 and gives the frosted look approved on the
/// design page (a coat of 0.85). Reduce Transparency still replaces all of it with
/// an opaque ground. `GlassTests` holds these three facts.
enum ShelfGlass {
    static let defaultsKey = "shelf.glass"
    /// Frosted: about two thirds along.
    static let defaultValue: Double = 0.7
    /// How the coat bends along the slider.
    static let curve: Double = 1.6

    /// The coat's opacity for a slider value in 0...1.
    static func groundAlpha(_ value: Double) -> CGFloat {
        let v = min(1, max(0, value))
        return CGFloat(1 - pow(1 - v, curve))
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
