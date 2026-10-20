import AppKit

/// What a drag out of the shelf is asking for.
///
/// The destination always **copies** — that is the one thing the shelf permits
/// it to do, under every modifier (`DragModePolicy.sourceMask`). A move is a
/// copy the user asked to be followed by putting the original in the Trash, and
/// Magpie is the one that does that, under the conditions in `DragMove.swift`.
enum DragIntent: Equatable {
    case copy
    case move
}

/// The modifier contract, and what the shelf is willing to let a destination do.
///
/// Both halves are pure over the modifier flags, because the AppKit side of a
/// drag cannot be reached from a test: `NSDraggingSource` is only ever called
/// by a live tracking loop.
enum DragModePolicy {

    /// macOS's own drag modifiers: ⌘ moves, ⌥ copies, ⌥⌘ links.
    ///
    /// The shelf does not vend links, so ⌥⌘ resolves to a copy rather than to
    /// nothing — and ⌥ beats ⌘ for the same reason a plain drag copies: of the
    /// two readings of an ambiguous modifier, only one of them can lose the
    /// user a file from where they left it.
    static func intent(modifiers: NSEvent.ModifierFlags) -> DragIntent {
        let flags = modifiers.intersection(.deviceIndependentFlagsMask)
        guard !flags.contains(.option) else { return .copy }
        return flags.contains(.command) ? .move : .copy
    }

    /// The only operation the shelf ever permits a destination: **copy**.
    ///
    /// Not a function of the modifiers, and that is the fix. Two earlier
    /// attempts read `NSEvent.modifierFlags` here and widened the mask under ⌘,
    /// on the belief that the destination would then perform the move. Both
    /// failed against a real Finder window. What was measured, driving a real
    /// drag out of a Magpie-shaped floating panel into a real Finder window:
    ///
    ///     source mask                     ⌘ pressed   Finder did
    ///     .copy at rest → [.move,.copy,.generic] under ⌘   mid-drag   REFUSED (op 0)
    ///     the same                        before drag  MOVED
    ///     static [.copy, .move]           mid-drag     MOVED
    ///     static [.copy, .move]           never        MOVED — a plain drag!
    ///     static [.copy, .generic]        mid-drag     REFUSED
    ///     static .copy                    mid-drag     REFUSED
    ///
    /// Two facts fall out of that table, and together they close the door on a
    /// destination-performed move:
    ///
    /// 1. **AppKit latches the mask as a ceiling when the session is set up.**
    ///    Widening it mid-drag is ignored — which is why ⌘ *pressed during a
    ///    drag*, the gesture the shelf's own hint teaches, was refused every
    ///    time. Narrowing it mid-drag is honoured. `.generic` had nothing to do
    ///    with it: Finder ignores a generic-only offer and acts on `.move`,
    ///    the exact opposite of what ADR 0009's addendum concluded from a
    ///    synthetic destination.
    /// 2. **A ceiling containing `.move` lets Finder move an unmodified drag.**
    ///    Measured directly: a plain drag with `[.copy, .move]` took the file
    ///    out of its folder. Narrowing to `.copy` immediately afterwards is a
    ///    race the file loses — over nine fast drags Finder had negotiated
    ///    `.move` on seven of them.
    ///
    /// So there is no mask that means "a plain drag copies and ⌘ moves". `.copy`
    /// alone is the only ceiling under which a destination can never take the
    /// user's file, and `DragInitiatorView.ignoreModifierKeys(for:)` is what
    /// keeps ⌘ from filtering it to nothing and refusing the drop. The move
    /// itself is Magpie's, under the rules in `DragMove.swift`.
    static let sourceMask: NSDragOperation = .copy
}

/// What the shelf says while a card is on its way out.
///
/// The same shape as `EmptyShelfHint`, for the same reason: a value type with
/// no SwiftUI in it, so what the shelf claims can be asserted directly instead
/// of hoped at. Two short lines and no more — this is a panel glanced at for
/// two seconds, not a tutorial.
///
/// The title is also the feedback. Holding ⌘ swaps "Copying" for "Moving"
/// while the drag is still in flight, which is the only proof the user gets
/// that the modifier landed; the colour change beside it is the same claim
/// said again in a way you don't have to read.
struct DragOutHint: Equatable {
    /// What is about to happen, in one word.
    let title: String
    /// How to get the other one. Never nil: the whole point is that each mode
    /// names its counterpart, so the gesture is discoverable from either side.
    let subtitle: String

    static func from(intent: DragIntent) -> DragOutHint {
        switch intent {
        case .copy:
            return DragOutHint(
                title: L("drag.mode.copying"),
                subtitle: L("drag.mode.hold-command")
            )
        case .move:
            return DragOutHint(
                title: L("drag.mode.moving"),
                subtitle: L("drag.mode.release-command")
            )
        }
    }
}

/// Tracks what the modifiers are asking for *while* a drag is in flight.
///
/// A dragging source is told when the drag starts and when it ends, and
/// nothing in between — so ⌘ pressed halfway through a drag reaches AppKit
/// (which re-asks for the operation mask) but reaches no view. This samples
/// `NSEvent.modifierFlags`, which reads the live hardware state and needs no
/// event, no monitor and no accessibility permission.
///
/// `.common` run-loop mode is not optional, and it is the same lesson
/// `ToastPresenter` already paid for: AppKit spins a tracking loop for the
/// whole of a drag, and a default-mode timer does not fire inside it.
@MainActor
final class DragModeMonitor: ObservableObject {
    static let shared = DragModeMonitor()

    /// Fast enough that ⌘ feels instant, slow enough to be free.
    static let sampleInterval: TimeInterval = 0.05

    @Published private(set) var intent: DragIntent = .copy

    private var sampler: Timer?

    /// What the keys say right now, whether or not a drag is running.
    var liveIntent: DragIntent {
        DragModePolicy.intent(modifiers: NSEvent.modifierFlags)
    }

    func begin() {
        intent = liveIntent
        sampler?.invalidate()
        let timer = Timer(timeInterval: Self.sampleInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let sampled = self.liveIntent
                if sampled != self.intent { self.intent = sampled }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        sampler = timer
    }

    /// Stops sampling and returns the intent the drag ended on — read once
    /// more here, because the last timer tick can be up to a frame old and the
    /// answer decides whether the user is told their move became a copy.
    @discardableResult
    func end() -> DragIntent {
        sampler?.invalidate()
        sampler = nil
        let final = liveIntent
        intent = final
        return final
    }
}

/// What a dragged file puts on the pasteboard: the user's own file URL **and**
/// a file promise. `ShelfFilePromiseProvider` in `DragMove.swift` is both, and
/// carries the reasoning.
enum ShelfDragPasteboard {
    static func writer(for url: URL) -> NSPasteboardWriting {
        ShelfFilePromiseProvider(sourceURL: url)
    }
}
