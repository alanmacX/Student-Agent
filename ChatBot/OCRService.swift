import Vision
import AppKit
import Foundation

// MARK: - OCR Service
// Provides macOS-native text recognition for images embedded in Chaoxing messages.
// Uses Vision framework's VNRecognizeTextRequest with accurate mode.
// Supports downloading remote image URLs and recognising local Data blobs.

struct OCRService {
    /// Recognise text from raw image data (PNG/JPEG/etc.).
    /// Returns the extracted string, or nil if no text was found or recognition failed.
    static func recogniseText(from imageData: Data) async -> String? {
        await withCheckedContinuation { continuation in
            guard let cgImage = Self.cgImage(from: imageData) else {
                continuation.resume(returning: nil)
                return
            }
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            let request = VNRecognizeTextRequest { req, error in
                guard error == nil,
                      let results = req.results as? [VNRecognizedTextObservation],
                      !results.isEmpty
                else {
                    continuation.resume(returning: nil)
                    return
                }
                let lines = results.compactMap { $0.topCandidates(1).first?.string }
                let joined = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                continuation.resume(returning: joined.isEmpty ? nil : joined)
            }
            // Prioritise Simplified Chinese → Traditional → English
            request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(returning: nil)
            }
        }
    }

    /// Download an image from a URL and run OCR on it.
    /// Respects task cancellation. Returns nil on network or recognition failure.
    static func recogniseText(from url: URL) async -> String? {
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              let http = response as? HTTPURLResponse,
              http.statusCode == 200,
              !data.isEmpty
        else { return nil }
        return await recogniseText(from: data)
    }

    /// Download from a URL string and run OCR.
    static func recogniseText(fromURLString urlString: String) async -> String? {
        guard let url = URL(string: urlString) else { return nil }
        return await recogniseText(from: url)
    }

    // MARK: - Private helpers

    private static func cgImage(from data: Data) -> CGImage? {
        guard let nsImage = NSImage(data: data),
              let cgRef = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return nil }
        return cgRef
    }
}

// MARK: - Batch OCR helper for Chaoxing messages

extension OCRService {
    /// Enrich a collection of Chaoxing messages by running OCR on any image attachments.
    /// Returns the same messages with image text appended to the existing `text` field.
    /// Processes images concurrently (up to 4 at a time) to avoid saturating the network.
    static func enrichMessagesWithOCR(_ messages: [ChaoxingMessage]) async -> [ChaoxingMessage] {
        await withTaskGroup(of: ChaoxingMessage.self) { group in
            // Limit concurrency
            let semaphore = AsyncSemaphore(limit: 4)
            for message in messages {
                group.addTask {
                    await semaphore.wait()
                    let result = await enrichSingleMessage(message)
                    await semaphore.signal()
                    return result
                }
            }
            var enriched: [ChaoxingMessage] = []
            for await msg in group { enriched.append(msg) }
            // Preserve original order
            return messages.compactMap { orig in
                enriched.first { $0.id == orig.id }
            }
        }
    }

    private static func enrichSingleMessage(_ message: ChaoxingMessage) async -> ChaoxingMessage {
        guard let imageURLs = message.imageURLs, !imageURLs.isEmpty else {
            return message
        }
        var ocrLines: [String] = []
        for urlString in imageURLs {
            if let text = await recogniseText(fromURLString: urlString),
               !text.isEmpty {
                ocrLines.append("[图片文字: \(text)]")
            }
        }
        guard !ocrLines.isEmpty else { return message }
        var enriched = message
        let ocrSuffix = "\n" + ocrLines.joined(separator: "\n")
        enriched.text += ocrSuffix
        return enriched
    }
}

// MARK: - Async semaphore (lightweight concurrency gate)

private actor AsyncSemaphore {
    private var count: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) { count = limit }

    func wait() async {
        if count > 0 {
            count -= 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func signal() {
        if waiters.isEmpty {
            count += 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}
