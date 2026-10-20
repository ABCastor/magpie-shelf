import AppKit
import XCTest
@testable import Magpie

/// What a multi-file drag looks like, and where it lands. Both were reported
/// with screenshots.
///
/// - Every dragging item carried its own copy of the picture at its own offset,
///   so eleven files trailed eleven overlapping thumbnails down the screen. The
///   owner read that as the app copying everything eleven times.
/// - A destination places each item at the point its dragging frame names, so
///   those same offsets scattered the files across the destination window
///   instead of landing them together.
///
/// A live drag needs a tracking loop no test can enter, which is why the whole
/// decision is a pure function and only its wiring is read off the source.
final class DragPreviewPlanTests: XCTestCase {

    private let frame = NSRect(x: 12, y: 30, width: 164, height: 30)

    func test_one_file_carries_its_own_picture_and_no_badge() {
        let plan = DragPreviewPlan.make(count: 1, previewFrame: frame)
        XCTAssertEqual(plan.frames, [frame])
        XCTAssertEqual(plan.imagedIndex, 0)
        XCTAssertNil(
            plan.badge,
            "a single-file drag wears a count badge, which says nothing its own picture did not"
        )
    }

    /// **The stacked-previews defect.** One picture for the set, whatever its
    /// size.
    func test_a_multi_file_drag_draws_exactly_one_picture() {
        let plan = DragPreviewPlan.make(count: 11, previewFrame: frame)
        XCTAssertEqual(plan.frames.count, 11, "a dragging item was dropped, so a file would not travel")
        XCTAssertEqual(
            plan.imagedIndex, 0,
            "more than one dragging item is drawn — eleven files trail eleven previews down the screen"
        )
        XCTAssertEqual(
            plan.badge, "11",
            "the drag does not say how many files it is carrying"
        )
    }

    /// **The cascaded-drop defect.** The frames are the drop points.
    func test_every_dragged_file_is_offered_the_same_drop_point() {
        let plan = DragPreviewPlan.make(count: 11, previewFrame: frame)
        XCTAssertEqual(
            Set(plan.frames.map(NSStringFromRect)).count, 1,
            "the dragging items carry different frames again, so the destination scatters them across its window instead of landing them together"
        )
        XCTAssertEqual(plan.frames.first, frame)
    }

    /// A shared frame is only worth setting if AppKit is not asked to re-lay
    /// the items out afterwards, which is exactly what `.stack` does.
    func test_appkit_is_not_asked_to_re_lay_the_items_out() {
        XCTAssertEqual(
            DragPreviewPlan.make(count: 5, previewFrame: frame).formation,
            NSDraggingFormation.none,
            "the session asks AppKit to arrange the items, which undoes the shared drop point above"
        )
    }

    func test_the_badge_counts_files_and_stays_quiet_for_one() {
        XCTAssertNil(DragPreviewPlan.badgeText(count: 0))
        XCTAssertNil(DragPreviewPlan.badgeText(count: 1))
        XCTAssertEqual(DragPreviewPlan.badgeText(count: 2), "2")
        XCTAssertEqual(DragPreviewPlan.badgeText(count: 137), "137")
    }

    func test_an_empty_drag_draws_nothing() {
        let plan = DragPreviewPlan.make(count: 0, previewFrame: frame)
        XCTAssertEqual(plan.frames, [])
        XCTAssertNil(plan.imagedIndex)
    }

    // MARK: - The picture itself

    private func plain() -> NSImage {
        NSImage(size: NSSize(width: 80, height: 40), flipped: false) { rect in
            NSColor.white.setFill()
            rect.fill()
            return true
        }
    }

    private func pixels(_ image: NSImage) throws -> NSBitmapImageRep {
        let data = try XCTUnwrap(image.tiffRepresentation)
        return try XCTUnwrap(NSBitmapImageRep(data: data))
    }

    /// What `color` looks like after the same trip through `NSImage` and TIFF
    /// the badge takes. Read from a rendered swatch rather than converted
    /// directly: a TIFF representation lands in calibrated RGB, which moves a
    /// system accent colour by roughly a tenth of a channel — enough for a
    /// direct comparison to find nothing and call it a missing badge.
    private func rendered(_ color: NSColor) throws -> NSColor {
        let swatch = NSImage(size: NSSize(width: 4, height: 4), flipped: false) { rect in
            color.setFill()
            rect.fill()
            return true
        }
        let rep = try pixels(swatch)
        return try XCTUnwrap(rep.colorAt(x: 1, y: 1)?.usingColorSpace(.sRGB))
    }

    /// Pixels within a small per-channel tolerance of `target`, the same
    /// convention `SelectionEmphasisTests` measures a selection fill with.
    private func count(_ rep: NSBitmapImageRep, matching target: NSColor) -> Int {
        guard let wanted = target.usingColorSpace(.sRGB) else { return 0 }
        var matches = 0
        for x in 0..<rep.pixelsWide {
            for y in 0..<rep.pixelsHigh {
                guard let pixel = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if abs(pixel.redComponent - wanted.redComponent) < 0.03,
                   abs(pixel.greenComponent - wanted.greenComponent) < 0.03,
                   abs(pixel.blueComponent - wanted.blueComponent) < 0.03 {
                    matches += 1
                }
            }
        }
        return matches
    }

    func test_a_badge_is_actually_drawn_onto_the_picture() throws {
        let original = try pixels(plain())
        let badged = try pixels(DragPreviewImage.badged(plain(), badge: "3"))
        XCTAssertNotEqual(
            original.representation(using: .png, properties: [:]),
            badged.representation(using: .png, properties: [:]),
            "the count is computed and never drawn, so a multi-file drag looks exactly like a single-file one"
        )
    }

    func test_no_badge_leaves_the_picture_untouched() throws {
        let original = plain()
        XCTAssertEqual(
            try pixels(original).representation(using: .png, properties: [:]),
            try pixels(DragPreviewImage.badged(original, badge: nil)).representation(using: .png, properties: [:]),
            "a single-file drag's picture is being redrawn, so it can pick up a mark it should not have"
        )
    }

    /// ADR 0006 binds: the badge wears the selection pair, which is the one
    /// AppKit guarantees legible together, rather than a colour mixed here.
    func test_the_badge_wears_the_selection_colour() throws {
        let fill = try rendered(SelectionColor.fillColor(emphasized: true))
        let badged = try pixels(DragPreviewImage.badged(plain(), badge: "7"))
        XCTAssertGreaterThan(
            count(badged, matching: fill), 20,
            "the count badge is not drawn in SelectionColor's active fill — an inline colour that no appearance test measures"
        )
        XCTAssertEqual(
            count(try pixels(plain()), matching: fill), 0,
            "the unbadged picture already contains the selection fill, so the assertion above proves nothing"
        )
    }

    // MARK: - The wiring

    private func source(_ path: String) throws -> String {
        try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent(path),
            encoding: .utf8
        )
    }

    /// A plan nothing consults is not a plan.
    func test_the_drag_session_is_built_from_the_plan() throws {
        let text = magpieCodeOnly(try source("Sources/Magpie/ShelfDragSource.swift"))
        XCTAssertTrue(text.contains("beginDraggingSession"), "read the wrong file")
        XCTAssertTrue(
            text.contains("DragPreviewPlan.make("),
            "the drag builds its items without the plan, so nothing above describes what actually leaves the shelf"
        )
        XCTAssertTrue(
            text.contains("session.draggingFormation = plan.formation"),
            "the session sets its own formation, so AppKit re-lays the items out and the shared drop point is lost"
        )
        // The plan can name one imaged item and the loop can still hand the
        // picture to all of them — which is precisely the shipped defect, and
        // nothing but this line notices.
        XCTAssertTrue(
            text.contains("index == plan.imagedIndex ? previewImage : nil"),
            "every dragging item is given the picture again: eleven files trail eleven overlapping previews down the screen"
        )
        XCTAssertFalse(
            text.contains("CGFloat(index) * 4"),
            "the per-item frame offset is back: N previews on the cursor and N cascaded files at the destination"
        )
    }
}
