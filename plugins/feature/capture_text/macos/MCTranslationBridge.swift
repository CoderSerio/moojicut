import AppKit
import SwiftUI
// The system SDK has not annotated its session/availability classes Sendable.
// UI state and cancellation stay on MainActor; the framework owns its async work.
@preconcurrency import Translation

private let translationDomain = "dev.moojicut.translation"
private typealias TranslationCompletion = (String?, String?, NSError?) -> Void

private func bridgeError(_ code: Int, _ message: String, underlying: Error? = nil) -> NSError {
    var info: [String: Any] = [NSLocalizedDescriptionKey: message]
    if let underlying { info[NSUnderlyingErrorKey] = underlying }
    return NSError(domain: translationDomain, code: code, userInfo: info)
}

private func displayError(_ error: Error) -> NSError {
    switch error {
    case is CancellationError, TranslationError.alreadyCancelled:
        return bridgeError(6, "翻译已取消。", underlying: error)
    case TranslationError.unsupportedSourceLanguage, TranslationError.unsupportedTargetLanguage,
         TranslationError.unsupportedLanguagePairing:
        return bridgeError(3, "系统翻译暂不支持这组语言，请更换源语言或目标语言。", underlying: error)
    case TranslationError.notInstalled:
        return bridgeError(4, "尚未下载所需语言。请在翻译窗口中重试，并允许系统下载语言。", underlying: error)
    case TranslationError.unableToIdentifyLanguage:
        return bridgeError(5, "无法识别原文语言，请手动选择源语言后重试。", underlying: error)
    case TranslationError.nothingToTranslate:
        return bridgeError(1, "请输入需要翻译的文字。", underlying: error)
    default:
        return bridgeError(7, "系统翻译暂时不可用，请稍后重试。", underlying: error)
    }
}

private func languageIdentifier(_ language: Locale.Language) -> String {
    // Preserve the script distinction even when Foundation can minimize zh-Hans
    // to zh. The AppKit picker uses explicit zh-Hans / zh-Hant identifiers.
    if language.languageCode?.identifier == "zh", let script = language.script?.identifier {
        return "zh-" + script
    }
    return language.minimalIdentifier.replacingOccurrences(of: "_", with: "-")
}

@MainActor
private final class TranslationState: ObservableObject {
    struct Request {
        let generation = UUID()
        let text: String
        let source: String?
        let target: String
    }
    @Published var request: Request?
    private var completion: TranslationCompletion?
    private var session: TranslationSession?

    func start(text: String, source: String?, target: String, completion: @escaping TranslationCompletion) {
        cancel()
        self.completion = completion
        request = Request(text: text, source: source, target: target)
    }

    func cancel() {
        // Cancel while the owning view/configuration is still valid; changing
        // the request removes that view and invalidates its TranslationSession.
        session?.cancel()
        session = nil
        completion = nil
        request = nil
    }

    func viewDisappeared(_ generation: UUID) {
        guard request?.generation == generation else { return }
        // SwiftUI cancels its translationTask on disappearance. Do not touch its
        // session here: Apple's contract forbids using an invalidated session.
        session = nil
        completion = nil
        request = nil
    }

    func perform(_ job: Request, session: TranslationSession) async {
        guard request?.generation == job.generation, !Task.isCancelled else { return }
        self.session = session
        do {
            // translate itself requests missing language downloads. In automatic
            // source mode prepareTranslation would fail before seeing any text.
            let response = try await session.translate(job.text)
            guard request?.generation == job.generation else { return }
            if Task.isCancelled {
                finish(job, text: nil, source: nil, error: displayError(CancellationError()))
            } else {
                finish(job, text: response.targetText, source: languageIdentifier(response.sourceLanguage), error: nil)
            }
        } catch {
            guard request?.generation == job.generation else { return }
            finish(job, text: nil, source: nil, error: displayError(error))
        }
    }

    private func finish(_ job: Request, text: String?, source: String?, error: NSError?) {
        guard request?.generation == job.generation else { return }
        let callback = completion
        session = nil
        completion = nil
        request = nil
        callback?(text, source, error)
    }
}

@MainActor
private struct TranslationTaskView: View {
    let job: TranslationState.Request
    let state: TranslationState
    var body: some View {
        Color.clear.frame(width: 1, height: 1)
            .translationTask(source: job.source.map(Locale.Language.init(identifier:)),
                             target: Locale.Language(identifier: job.target)) { session in
                await state.perform(job, session: session)
            }
            .onDisappear { state.viewDisappeared(job.generation) }
    }
}

@MainActor
private struct TranslationHostView: View {
    @ObservedObject var state: TranslationState
    var body: some View {
        if let job = state.request {
            // A new identity also restarts a request with unchanged languages;
            // each translation gets a session whose lifetime stays in this view.
            TranslationTaskView(job: job, state: state).id(job.generation)
        } else {
            Color.clear.frame(width: 1, height: 1)
        }
    }
}

@MainActor
@objc(MCTextTranslating)
public protocol MCTextTranslating: NSObjectProtocol {
    @objc(translateText:sourceLanguage:targetLanguage:completion:)
    func translateText(_ text: String, sourceLanguage: String?, targetLanguage: String,
                       completion: @escaping (String?, String?, NSError?) -> Void)
    func cancel()
}

/// Objective-C declarations live in MCTranslationBridge.h. No production app or
/// external translation API is required to compile or test the service bridge.
@MainActor
@objc(MCTranslationBridge)
public final class MCTranslationBridge: NSViewController, MCTextTranslating {
    private let state = TranslationState()
    private var hosting: NSHostingController<TranslationHostView>?

    @objc public init() { super.init(nibName: nil, bundle: nil) }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init()") }

    public override func loadView() {
        let controller = NSHostingController(rootView: TranslationHostView(state: state))
        hosting = controller
        addChild(controller)
        view = NSView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
        controller.view.frame = view.bounds
        controller.view.autoresizingMask = [.width, .height]
        view.addSubview(controller.view)
    }

    public override func viewWillDisappear() {
        cancel()
        super.viewWillDisappear()
    }

    @objc(translateText:sourceLanguage:targetLanguage:completion:)
    public func translateText(_ text: String, sourceLanguage: String?, targetLanguage: String,
                              completion: @escaping (String?, String?, NSError?) -> Void) {
        state.cancel()
        guard text.utf8.count <= 128 * 1024 else {
            completion(nil, nil, bridgeError(1, "文字过长，请将内容缩短至 128 KiB 以内。")); return
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            completion(nil, nil, bridgeError(1, "请输入需要翻译的文字。")); return
        }
        let pattern = "^[A-Za-z]{2,8}([_-][A-Za-z0-9]{1,8})*$"
        guard targetLanguage.range(of: pattern, options: .regularExpression) != nil,
              sourceLanguage == nil || sourceLanguage!.range(of: pattern, options: .regularExpression) != nil else {
            completion(nil, nil, bridgeError(1, "请选择有效的源语言和目标语言。")); return
        }
        guard isViewLoaded, view.window != nil, !view.isHiddenOrHasHiddenAncestor else {
            completion(nil, nil, bridgeError(2, "请先打开翻译结果窗口，再开始翻译。")); return
        }
        state.start(text: text, source: sourceLanguage, target: targetLanguage, completion: completion)
    }

    @objc public func cancel() { state.cancel() }

    @objc(supportedLanguagesWithCompletion:)
    public static func supportedLanguages(completion: @escaping ([[String: String]]) -> Void) {
        Task { @MainActor in
            let languages = await Task.detached { await LanguageAvailability().supportedLanguages }.value
            var seen = Set<String>()
            let preferred = ["zh-Hans", "en", "zh-Hant"]
            let choices = languages.compactMap { language -> [String: String]? in
                let id = languageIdentifier(language)
                guard seen.insert(id).inserted else { return nil }
                return ["id": id, "name": Locale.current.localizedString(forIdentifier: id) ?? id]
            }.sorted { left, right in
                let a = preferred.firstIndex(of: left["id"]!) ?? preferred.count
                let b = preferred.firstIndex(of: right["id"]!) ?? preferred.count
                return a != b ? a < b : left["name"]!.localizedStandardCompare(right["name"]!) == .orderedAscending
            }
            completion(choices)
        }
    }
}
