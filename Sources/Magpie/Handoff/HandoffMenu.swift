import Foundation

/// Whether the "Send to Claude for Filing" row exists at all, and in what
/// state — decided here, once, as a pure predicate both menu surfaces call
/// (the `OCRMenu.shouldOfferMakeSearchable` shape, per ADR 0007's surface
/// rule: contextual gating, unit-tested directly).
///
/// The gate this exists for: a stranger without Claude Code must never see a
/// row naming a product that is not on their Mac. Before this, the row was
/// gated only on having files; clicking it staged a copy of the user's files
/// into a drop folder and *then* discovered there was nowhere to send them,
/// ending in a "Couldn't open Claude" toast. A dead-end that copies your
/// files first is the worst kind.
enum HandoffMenu {
    enum Row: Equatable {
        /// Claude is not installed: no row. Absence, not disablement — a
        /// greyed row would still advertise a product the user may not have.
        case absent
        /// Claude is here but the selection has nothing sendable: visible and
        /// greyed, the same way Show in Finder behaves, so the action stays
        /// learnable.
        case disabled
        case enabled
    }

    static func row(claudeInstalled: Bool, hasSendableFiles: Bool) -> Row {
        guard claudeInstalled else { return .absent }
        return hasSendableFiles ? .enabled : .disabled
    }
}
