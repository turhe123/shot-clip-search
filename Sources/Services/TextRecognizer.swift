import Foundation
import ImageIO
import Vision

/// Runs Vision text recognition one image at a time on a background task, capped at 20 pending items.
@MainActor
final class TextRecognizer {
    static let maxPending = 20

    private weak var store: ClipStore?
    private var pending: [ClipEntry] = []
    private var isRunning = false

    init(store: ClipStore) {
        self.store = store
    }

    /// Languages Vision can recognize at the accurate level on this Mac.
    static var supportedLanguages: [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        return (try? request.supportedRecognitionLanguages()) ?? ["en-US"]
    }

    func enqueue(_ entry: ClipEntry) {
        guard entry.ocr == .pending else { return }
        pending.append(entry)
        while pending.count > Self.maxPending {
            let dropped = pending.removeFirst()
            store?.setRecognition(id: dropped.id, text: "", state: .dropped)
        }
        pump()
    }

    private func pump() {
        guard !isRunning, let store, !pending.isEmpty else { return }
        let entry = pending.removeFirst()
        let url = store.imageURL(for: entry)
        let language = UserDefaults.standard.string(forKey: "ocrLanguage") ?? "auto"
        isRunning = true
        Task {
            let text = await Task.detached(priority: .utility) {
                Self.recognize(url: url, language: language)
            }.value
            store.setRecognition(id: entry.id, text: text, state: .done)
            isRunning = false
            pump()
        }
    }

    nonisolated static func recognize(url: URL, language: String) -> String {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return "" }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        if language == "auto" {
            request.automaticallyDetectsLanguage = true
        } else {
            request.recognitionLanguages = [language]
        }
        do {
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        } catch {
            return ""
        }
        return (request.results ?? [])
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
    }
}
