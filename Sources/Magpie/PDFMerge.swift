import Foundation
import PDFKit
import UniformTypeIdentifiers

/// Merging several PDFs into one. The gate is a pure predicate — the same shape
/// as `OCRMenu.shouldOfferMakeSearchable` — so the rule that decides whether the
/// row exists is unit-tested without building a menu.
enum PDFMerge {

    /// Offered only when the selection is two or more items that are *all* PDFs.
    ///
    /// Below two there is nothing to merge. The all-PDF half is not politeness:
    /// it is what lets `merge(inputs:into:)` stay a page copy with no image
    /// fallback, and an image fallback is the rasterizing trap that would drop
    /// the text layer `Make Searchable` exists to add.
    static func shouldOffer(forSourceUTIs utis: [UTType]) -> Bool {
        guard utis.count >= 2 else { return false }
        return utis.allSatisfy { $0.conforms(to: .pdf) }
    }

    /// Same rule, resolved from shelf items. Any item without a resolvable type
    /// disqualifies the whole selection rather than being skipped — a skipped
    /// input is the silent-short-output failure this feature is most exposed to.
    static func shouldOffer(for items: [ShelfItem]) -> Bool {
        let utis = items.compactMap(uti(for:))
        guard utis.count == items.count else { return false }
        return shouldOffer(forSourceUTIs: utis)
    }

    enum Failure: Error, Equatable {
        /// A named input could not be opened, is password-locked, or carries no
        /// pages. Named because a merge quietly missing pages is the failure the
        /// user files away without ever noticing.
        case unreadable(name: String)
        case writeFailed
    }

    /// Every page of every input, in the order given, into one new document.
    ///
    /// Never `PDFPage(image:)`. That rasterizes: five text-bearing pages come
    /// back as image-only pages with no selectable text, and `ImageActions`
    /// sits in this same codebase doing exactly that for its own (correct) job
    /// of turning images into a PDF. The gate guarantees PDF inputs here, so
    /// there is no image branch to write at all.
    ///
    /// Aborts on the first unreadable input rather than continuing: a short
    /// document that looks finished is worse than no document.
    static func merge(inputs: [URL], into destination: URL) throws {
        // Every source document is held open until after the write. A page
        // inserted into another document still reads its content through the
        // document it came from, so releasing them inside the loop would be a
        // use-after-free waiting for a large enough input.
        var sources: [(url: URL, document: PDFDocument)] = []
        for input in inputs {
            // A password-locked PDF is the reachable case, and the one this app
            // will actually meet: it opens, it reports a page count, and it
            // simply cannot be read. The page-count clause is a floor for a
            // document that loads with nothing in it — today's PDFKit fabricates
            // a page rather than admitting to zero, so that clause is untested.
            guard let document = PDFDocument(url: input),
                  !document.isLocked,
                  document.pageCount > 0
            else { throw Failure.unreadable(name: input.lastPathComponent) }
            sources.append((input, document))
        }

        let merged = PDFDocument()
        for source in sources {
            for index in 0..<source.document.pageCount {
                guard let page = source.document.page(at: index) else {
                    throw Failure.unreadable(name: source.url.lastPathComponent)
                }
                merged.insert(page, at: merged.pageCount)
            }
        }

        let wrote = merged.write(to: destination)
        withExtendedLifetime(sources) {}
        guard wrote else {
            // Fail closed: never leave a half-written document behind.
            try? FileManager.default.removeItem(at: destination)
            throw Failure.writeFailed
        }
    }

    /// `OCRMenu` and `ConversionMenu` each carry their own private copy of this
    /// three-line resolution; promoting one shared helper would mean editing
    /// files outside this change.
    private static func uti(for item: ShelfItem) -> UTType? {
        guard let url = item.fileURL else { return nil }
        if let values = try? url.resourceValues(forKeys: [.contentTypeKey]),
           let type = values.contentType { return type }
        return UTType(filenameExtension: url.pathExtension)
    }
}
