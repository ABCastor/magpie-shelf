import AppKit
import Combine
import Foundation
import XCTest
@testable import Magpie

final class QueueServiceTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("QueueServiceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: tempDir, withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    @MainActor
    func test_conversion_enqueue_sets_progress_then_completes() async throws {
        let source = try makePNG(named: "enqueue")
        let itemID = UUID()
        let shelfID = UUID()
        let service = ConversionService()
        let completed = expectation(description: "conversion completed")
        var cancellables = Set<AnyCancellable>()
        service.completed.sink { url, actualShelfID in
            XCTAssertEqual(actualShelfID, shelfID)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
            completed.fulfill()
        }.store(in: &cancellables)

        service.enqueue(
            sourceItemID: itemID,
            shelfID: shelfID,
            source: source,
            target: .jpeg
        )

        XCTAssertEqual(service.progress[itemID], 0)
        await fulfillment(of: [completed], timeout: 5)
        XCTAssertNil(service.progress[itemID])
    }

    @MainActor
    func test_conversion_queue_completes_in_serial_fifo_order() async throws {
        let service = ConversionService()
        let shelfIDs = [UUID(), UUID(), UUID()]
        let sources = try (0..<3).map { try makePNG(named: "fifo-\($0)") }
        let completed = expectation(description: "all conversions completed")
        completed.expectedFulfillmentCount = shelfIDs.count
        var completionOrder: [UUID] = []
        var cancellables = Set<AnyCancellable>()
        service.completed.sink { _, shelfID in
            completionOrder.append(shelfID)
            completed.fulfill()
        }.store(in: &cancellables)

        for (shelfID, source) in zip(shelfIDs, sources) {
            service.enqueue(
                sourceItemID: UUID(),
                shelfID: shelfID,
                source: source,
                target: .jpeg
            )
        }

        await fulfillment(of: [completed], timeout: 5)
        XCTAssertEqual(completionOrder, shelfIDs)
    }

    @MainActor
    func test_conversion_cancel_removes_queued_task_before_run() async throws {
        let service = ConversionService()
        let runningID = UUID()
        let cancelledID = UUID()
        let runningShelfID = UUID()
        let cancelledShelfID = UUID()
        let source = try makePNG(named: "cancel-queued", size: 1_024)
        let runningCompleted = expectation(description: "running task completed")
        let cancelledCompleted = expectation(description: "cancelled queued task did not complete")
        cancelledCompleted.isInverted = true
        var cancellables = Set<AnyCancellable>()
        service.completed.sink { _, shelfID in
            if shelfID == cancelledShelfID {
                cancelledCompleted.fulfill()
            } else if shelfID == runningShelfID {
                runningCompleted.fulfill()
            }
        }.store(in: &cancellables)

        service.enqueue(
            sourceItemID: runningID,
            shelfID: runningShelfID,
            source: source,
            target: .jpeg
        )
        service.enqueue(
            sourceItemID: cancelledID,
            shelfID: cancelledShelfID,
            source: source,
            target: .jpeg
        )
        XCTAssertEqual(service.progress[cancelledID], 0)

        service.cancel(itemID: cancelledID)

        XCTAssertNil(service.progress[cancelledID])
        await fulfillment(of: [runningCompleted], timeout: 5)
        await fulfillment(of: [cancelledCompleted], timeout: 0.5)
    }

    @MainActor
    func test_conversion_cancel_inflight_image_does_not_complete_or_leave_output() async throws {
        let service = ConversionService()
        let itemID = UUID()
        let shelfID = UUID()
        let source = try makePNG(named: "cancel-inflight", size: 1_024)
        let output = tempDir.appendingPathComponent("cancel-inflight.jpg")
        let completed = expectation(description: "cancelled image did not complete")
        completed.isInverted = true
        let cancelled = expectation(description: "cancelled image emitted cancellation")
        var cancellables = Set<AnyCancellable>()
        service.completed.sink { _, _ in
            completed.fulfill()
        }.store(in: &cancellables)
        service.failed.sink { error in
            XCTAssertEqual(error, .cancelled)
            cancelled.fulfill()
        }.store(in: &cancellables)

        service.enqueue(
            sourceItemID: itemID,
            shelfID: shelfID,
            source: source,
            target: .jpeg
        )
        service.cancel(itemID: itemID)

        XCTAssertNil(service.progress[itemID])
        await fulfillment(of: [cancelled], timeout: 5)
        await fulfillment(of: [completed], timeout: 0.5)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    @MainActor
    func test_ocr_extract_image_emits_nonempty_text_and_clears_progress() async throws {
        let service = OCRService(extractImage: { _ in "SHELF OCR TEST 123" })
        let itemID = UUID()
        let shelfID = UUID()
        let source = try makeTextPNG(named: "ocr")
        let terminal = expectation(description: "OCR completed")
        var cancellables = Set<AnyCancellable>()
        service.completedExtracted.sink { text, actualShelfID in
            XCTAssertEqual(actualShelfID, shelfID)
            XCTAssertFalse(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            terminal.fulfill()
        }.store(in: &cancellables)
        service.failed.sink { error in
            XCTFail("OCR unexpectedly failed: \(error)")
            terminal.fulfill()
        }.store(in: &cancellables)

        service.enqueueExtractText(
            sourceItemID: itemID,
            shelfID: shelfID,
            source: source,
            isPDF: false
        )

        XCTAssertEqual(service.progress[itemID], 0)
        await fulfillment(of: [terminal], timeout: 15)
        XCTAssertNil(service.progress[itemID])
    }

    @MainActor
    func test_ocr_queue_completes_in_serial_fifo_order() async throws {
        let service = OCRService(extractImage: { _ in "SHELF OCR TEST 123" })
        let source = try makeTextPNG(named: "ocr-fifo")
        let shelfIDs = [UUID(), UUID()]
        let completed = expectation(description: "both OCR tasks completed")
        completed.expectedFulfillmentCount = shelfIDs.count
        var completionOrder: [UUID] = []
        var cancellables = Set<AnyCancellable>()
        service.completedExtracted.sink { text, shelfID in
            XCTAssertFalse(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            completionOrder.append(shelfID)
            completed.fulfill()
        }.store(in: &cancellables)
        service.failed.sink { error in
            XCTFail("OCR unexpectedly failed: \(error)")
        }.store(in: &cancellables)

        for shelfID in shelfIDs {
            service.enqueueExtractText(
                sourceItemID: UUID(),
                shelfID: shelfID,
                source: source,
                isPDF: false
            )
        }

        await fulfillment(of: [completed], timeout: 20)
        XCTAssertEqual(completionOrder, shelfIDs)
    }

    @MainActor
    func test_ocr_cancel_removes_queued_task_before_run() async throws {
        let service = OCRService(extractImage: { _ in "SHELF OCR TEST 123" })
        let source = try makeTextPNG(named: "ocr-cancel")
        let runningID = UUID()
        let cancelledID = UUID()
        let runningShelfID = UUID()
        let cancelledShelfID = UUID()
        let runningCompleted = expectation(description: "running OCR completed")
        let cancelledCompleted = expectation(description: "cancelled queued OCR did not complete")
        cancelledCompleted.isInverted = true
        var cancellables = Set<AnyCancellable>()
        service.completedExtracted.sink { text, shelfID in
            XCTAssertFalse(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if shelfID == cancelledShelfID {
                cancelledCompleted.fulfill()
            } else if shelfID == runningShelfID {
                runningCompleted.fulfill()
            }
        }.store(in: &cancellables)
        service.failed.sink { error in
            XCTFail("OCR unexpectedly failed: \(error)")
        }.store(in: &cancellables)

        service.enqueueExtractText(
            sourceItemID: runningID,
            shelfID: runningShelfID,
            source: source,
            isPDF: false
        )
        service.enqueueExtractText(
            sourceItemID: cancelledID,
            shelfID: cancelledShelfID,
            source: source,
            isPDF: false
        )
        XCTAssertEqual(service.progress[cancelledID], 0)

        service.cancel(itemID: cancelledID)

        XCTAssertNil(service.progress[cancelledID])
        await fulfillment(of: [runningCompleted], timeout: 15)
        await fulfillment(of: [cancelledCompleted], timeout: 0.5)
    }

    @MainActor
    private func makePNG(named name: String, size: Int = 32) throws -> URL {
        let url = tempDir.appendingPathComponent(name).appendingPathExtension("png")
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSRect(x: 0, y: 0, width: size, height: size).fill()
        image.unlockFocus()
        try writePNG(image, to: url)
        return url
    }

    @MainActor
    private func makeTextPNG(named name: String) throws -> URL {
        let url = tempDir.appendingPathComponent(name).appendingPathExtension("png")
        let size = NSSize(width: 1_200, height: 300)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        NSString(string: "SHELF OCR TEST 123").draw(
            in: NSRect(x: 40, y: 70, width: 1_120, height: 170),
            withAttributes: [
                .font: NSFont.systemFont(ofSize: 96, weight: .bold),
                .foregroundColor: NSColor.black,
            ]
        )
        image.unlockFocus()
        try writePNG(image, to: url)
        return url
    }

    private func writePNG(_ image: NSImage, to url: URL) throws {
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: tiff))
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: url)
    }
}
