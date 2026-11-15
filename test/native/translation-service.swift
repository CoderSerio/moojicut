import Foundation
@preconcurrency import Translation

// Real, installed-only system service probe. This CLI has no app bundle ID,
// presents no download UI, and never substitutes a mock translation. A missing
// language is reported as notInstalled, not as a passing translation result.
@main
struct TranslationServiceProbe {
    static func write(_ object: [String: Any]) {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }

    nonisolated static func main() async {
        let arguments = CommandLine.arguments
        let source = Locale.Language(identifier: arguments.count > 1 ? arguments[1] : "en")
        let target = Locale.Language(identifier: arguments.count > 2 ? arguments[2] : "zh-Hans")
        let text = arguments.count > 3 ? arguments[3] : "Hello, world. This is a screenshot."
        let timeout = Task.detached {
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled else { return }
            write(["result": "timeout", "message": "System translation did not finish within 20 seconds."])
            exit(2)
        }
        defer { timeout.cancel() }
        let availability = LanguageAvailability()
        let languages = await availability.supportedLanguages
        let status = await availability.status(from: source, to: target)
        let statusName: String
        switch status {
        case .installed: statusName = "installed"
        case .supported: statusName = "supported"
        case .unsupported: statusName = "unsupported"
        @unknown default: statusName = "unknown"
        }
        let session = TranslationSession(installedSource: source, target: target)
        guard !session.canRequestDownloads else {
            write(["result": "failed", "message": "The CLI unexpectedly permits language downloads."])
            exit(1)
        }
        do {
            let response = try await session.translate(text)
            guard !response.targetText.isEmpty else {
                write(["result": "failed", "message": "The real service returned empty text."])
                exit(1)
            }
            write(["result": "translated", "availability": statusName, "supportedLanguageCount": languages.count,
                   "source": response.sourceLanguage.minimalIdentifier,
                   "target": response.targetLanguage.minimalIdentifier, "text": response.targetText])
        } catch TranslationError.notInstalled {
            write(["result": "notInstalled", "availability": statusName, "supportedLanguageCount": languages.count,
                   "message": "SKIP translation: real installed-only TranslationSession returned notInstalled; use the attached translationTask UI to request downloads."])
        } catch TranslationError.unsupportedSourceLanguage,
                TranslationError.unsupportedTargetLanguage,
                TranslationError.unsupportedLanguagePairing {
            write(["result": "unsupported", "availability": statusName, "supportedLanguageCount": languages.count, "message": "SKIP translation: the requested language pair is unsupported."])
        } catch {
            write(["result": "failed", "availability": statusName, "error": error.localizedDescription])
            exit(1)
        }
        session.cancel()
    }
}
