#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN
// Error domain: dev.moojicut.translation. All calls and completions use the main
// thread. Cancellation/replacement is silent: only the current request completes.
typedef NS_ENUM(NSInteger, MCTranslationBridgeErrorCode) {
    MCTranslationBridgeInvalidInput = 1,
    MCTranslationBridgeNotAttached = 2,
    MCTranslationBridgeUnsupportedLanguage = 3,
    MCTranslationBridgeNotInstalled = 4,
    MCTranslationBridgeUnableToIdentifyLanguage = 5,
    MCTranslationBridgeCancelled = 6,
    MCTranslationBridgeServiceFailed = 7,
};
typedef void (^MCTranslationCompletion)(NSString * _Nullable translatedText,
                                       NSString * _Nullable resolvedSourceLanguage,
                                       NSError * _Nullable error);
@protocol MCTextTranslating <NSObject>
// sourceLanguage == nil asks the system to identify it. targetLanguage must be
// explicit (normally zh-Hans or en). Nonblank input is limited to 128 KiB UTF-8.
- (void)translateText:(NSString *)text
      sourceLanguage:(nullable NSString *)sourceLanguage
      targetLanguage:(NSString *)targetLanguage
          completion:(MCTranslationCompletion)completion;
- (void)cancel;
@end

API_AVAILABLE(macos(26.0))
@interface MCTranslationBridge : NSViewController <MCTextTranslating>
- (instancetype)init;
// Add this controller as a child and keep its view attached to the shown result
// window. A 1x1 view is sufficient; do not set hidden=YES. SwiftUI owns the live
// TranslationSession and presents Apple's language identification/download UI.
// Call cancel before closing/detaching the result window. Never retain or reuse
// a TranslationSession after its SwiftUI view disappears.
// https://developer.apple.com/documentation/swiftui/view/translationtask(_:action:)
+ (void)supportedLanguagesWithCompletion:(void (^)(NSArray<NSDictionary<NSString *, NSString *> *> *languages))completion;
@end
NS_ASSUME_NONNULL_END
