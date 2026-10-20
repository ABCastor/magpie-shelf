import Foundation

/// Matching for the Settings search field.
///
/// A value type with no SwiftUI in it, so the thing that decides what a query
/// finds is testable without a window — the same split the rest of the app
/// uses, and the reason the ⌘K bug was findable only by hand.
///
/// Matching is deliberately forgiving. Someone looking for the auto-paste
/// switch types "paste", "clipboard", or "accessibility" depending on what they
/// remember, and a settings search that only matches the visible label is a
/// search that fails exactly when the user could not remember the label — which
/// is the only time they open it.
struct SettingsSearch: Equatable {
    var query: String = ""

    var isActive: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// True when the row should be shown: either nothing is being searched, or
    /// one of its terms matches.
    ///
    /// `terms` should carry the row's visible label **plus** the words a person
    /// might reach for instead. Diacritic- and case-insensitive, so "reglages"
    /// finds "Réglages" — a French user on a US keyboard would otherwise get
    /// nothing.
    func matches(_ terms: [String]) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return true }
        return terms.contains { term in
            term.range(
                of: needle,
                options: [.caseInsensitive, .diacriticInsensitive],
                range: nil,
                locale: nil
            ) != nil
        }
    }

    /// True when a section should appear at all. A section whose rows all fail
    /// must be hidden entirely — a lone header over nothing reads as a bug.
    func sectionMatches(_ rows: [[String]]) -> Bool {
        guard isActive else { return true }
        return rows.contains { matches($0) }
    }
}
