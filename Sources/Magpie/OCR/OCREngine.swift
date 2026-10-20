import Foundation
import Vision
import CoreGraphics

/// One recognized line of text. `boundingBox` uses Vision's native
/// normalized-bottom-up convention: origin at lower-left of the image,
/// values in 0...1.
struct RecognizedLine: Equatable, Sendable {
    let text: String
    let boundingBox: CGRect
}

/// Pure async Vision wrapper. Designed to be called off the main thread.
enum OCREngine {
    static func recognize(image: CGImage) async throws -> [RecognizedLine] {
        try await firstResult { finish in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    finish(.failure(error))
                    return
                }
                let observations = (request.results as? [VNRecognizedTextObservation]) ?? []
                let lines = observations.compactMap { obs -> RecognizedLine? in
                    guard let candidate = obs.topCandidates(1).first else { return nil }
                    return RecognizedLine(
                        text: candidate.string,
                        boundingBox: obs.boundingBox
                    )
                }
                finish(.success(lines))
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.automaticallyDetectsLanguage = true

            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            do {
                try handler.perform([request])
            } catch {
                finish(.failure(error))
            }
        }
    }

    static func firstResult(
        _ start: (@escaping (Result<[RecognizedLine], Error>) -> Void) -> Void
    ) async throws -> [RecognizedLine] {
        try await withCheckedThrowingContinuation { continuation in
            let gate = ResumeGate()
            start { result in
                guard gate.claim() else { return }
                continuation.resume(with: result)
            }
        }
    }

    private final class ResumeGate: @unchecked Sendable {
        private let lock = NSLock()
        private var claimed = false

        func claim() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !claimed else { return false }
            claimed = true
            return true
        }
    }
}
