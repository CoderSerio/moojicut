#import <AppKit/AppKit.h>
#import "plugins/feature/capture_text/macos/MCTextToolsController.h"
#import "plugins/feature/capture_text/macos/MCTranslationBridge.h"

// Deterministic controller tests, not an Apple Translation engine test. Link
// the real controller/service .m files, but NOT MCTranslationBridge.swift.
// This controlled bridge never requests language downloads or opens system UI.
// All windows remain hidden; clipboard assertions use a unique pasteboard.
static void Check(BOOL condition, NSString *message) {
    if (!condition) { fprintf(stderr, "FAIL text tools: %s\n", message.UTF8String); exit(1); }
}

@interface MCControlledTranslation : NSObject
@property NSString *text;
@property NSString *source;
@property NSString *target;
@property (copy) MCTranslationCompletion completion;
- (void)reply:(NSString *)text;
@end
@implementation MCControlledTranslation
- (void)reply:(NSString *)text {
    dispatch_async(dispatch_get_main_queue(), ^{ self.completion(text, @"en", nil); });
}
@end

@interface MCTranslationBridge ()
@property NSMutableArray<MCControlledTranslation *> *requests;
@property NSUInteger cancellations;
@end
@implementation MCTranslationBridge
- (instancetype)init {
    if ((self = [super initWithNibName:nil bundle:nil])) _requests = [NSMutableArray array];
    return self;
}
- (void)loadView { self.view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 1, 1)]; }
+ (void)supportedLanguagesWithCompletion:(void (^)(NSArray<NSDictionary<NSString *,NSString *> *> *))completion {
    Check(NSThread.isMainThread, @"language choices use main thread"); completion(@[]);
}
- (void)translateText:(NSString *)text sourceLanguage:(NSString *)source targetLanguage:(NSString *)target completion:(MCTranslationCompletion)completion {
    Check(NSThread.isMainThread, @"translation starts on main thread");
    MCControlledTranslation *request = [MCControlledTranslation new];
    request.text = text; request.source = source; request.target = target; request.completion = completion;
    [self.requests addObject:request];
}
- (void)cancel { self.cancellations++; }
@end

@interface MCControlledRecognition : NSObject <MCTextRecognitionTask>
@property (copy) void (^completion)(NSString *, NSError *);
@property NSUInteger cancellations;
- (void)reply:(NSString *)text error:(NSError *)error;
@end
@implementation MCControlledRecognition
- (void)cancel { self.cancellations++; }
- (void)reply:(NSString *)text error:(NSError *)error {
    dispatch_async(dispatch_get_main_queue(), ^{ self.completion(text, error); });
}
@end

@interface MCControlledRecognizer : NSObject <MCTextRecognizing>
@property NSMutableArray<MCControlledRecognition *> *requests;
@end
@implementation MCControlledRecognizer
- (instancetype)init { if ((self = [super init])) _requests = [NSMutableArray array]; return self; }
- (id<MCTextRecognitionTask>)recognizePNGData:(__unused NSData *)data completion:(void (^)(NSString *, NSError *))completion {
    Check(NSThread.isMainThread, @"recognition starts on main thread");
    MCControlledRecognition *request = [MCControlledRecognition new]; request.completion = completion;
    [self.requests addObject:request]; return request;
}
@end

// Private entry points of the actual production result controller.
@interface MCTextResultWindowController : NSWindowController <NSTextViewDelegate>
@property id<MCTextRecognizing> recognizer;
@property MCTranslationBridge *translator;
@property NSTextView *sourceText;
@property NSTextView *resultText;
@property NSTextField *status;
@property NSPopUpButton *targetLanguage;
@property NSButton *translateButton;
@property NSButton *resultCopyButton;
@property NSButton *sourceCopyButton;
@property NSTimer *leaseTimer;
@property NSUInteger generation;
@property BOOL closed;
@property BOOL recognizing;
@property BOOL translating;
@property (copy) void (^onClose)(void);
- (instancetype)initWithPNGData:(NSData *)png isCurrent:(BOOL (^)(void))isCurrent;
- (void)recognizeAndTranslate:(BOOL)translate;
- (void)translate:(id)sender;
- (void)languageChanged:(id)sender;
- (void)cancelTask:(id)sender;
- (BOOL)copyText:(NSString *)text toPasteboard:(NSPasteboard *)pasteboard;
- (BOOL)validateLease;
@end

static void Deliver(void) {
    __block BOOL done = NO;
    dispatch_async(dispatch_get_main_queue(), ^{ done = YES; });
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:3];
    while (!done && deadline.timeIntervalSinceNow > 0)
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    Check(done, @"deliver controlled main-queue replies");
}

static void Edit(MCTextResultWindowController *controller, NSTextView *view, NSString *text) {
    view.string = text;
    [controller textDidChange:[NSNotification notificationWithName:NSTextDidChangeNotification object:view]];
}

static MCTextResultWindowController *Controller(BOOL (^current)(void), MCControlledRecognizer **recognizer) {
    MCTextResultWindowController *controller = [[MCTextResultWindowController alloc] initWithPNGData:[@"controlled input" dataUsingEncoding:NSUTF8StringEncoding] isCurrent:current];
    *recognizer = [MCControlledRecognizer new]; controller.recognizer = *recognizer;
    Check(!controller.window.visible, @"fixture must not show its window");
    return controller;
}

int main(void) {
    @autoreleasepool {
        [NSApplication sharedApplication]; [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
        __block BOOL current = YES;
        MCControlledRecognizer *recognizer = nil;
        MCTextResultWindowController *controller = Controller(^BOOL { return current; }, &recognizer);
        MCTranslationBridge *bridge = controller.translator;

        [controller recognizeAndTranslate:NO]; MCControlledRecognition *oldOCR = recognizer.requests.lastObject;
        Check(controller.recognizing && !controller.sourceText.editable, @"OCR temporarily prevents source edits");
        [controller recognizeAndTranslate:NO]; MCControlledRecognition *newOCR = recognizer.requests.lastObject;
        Check(oldOCR.cancellations == 1, @"restarting OCR cancels its predecessor");
        [oldOCR reply:@"stale OCR" error:nil]; Deliver();
        Check(controller.recognizing && controller.sourceText.string.length == 0, @"superseded OCR cannot finish or write the newer request");
        [newOCR reply:@"Fresh source text" error:nil]; Deliver();
        Check(!controller.recognizing && controller.sourceText.editable && [controller.sourceText.string isEqual:@"Fresh source text"], @"current OCR populates editable source");

        [controller translate:nil]; MCControlledTranslation *edited = bridge.requests.lastObject;
        Check([edited.text isEqual:@"Fresh source text"] && edited.source == nil && [edited.target isEqual:@"zh-Hans"], @"translation receives the current text and explicit target");
        Edit(controller, controller.sourceText, @"User corrected source");
        [edited reply:@"obsolete translation"]; Deliver();
        Check(!controller.translating && [controller.sourceText.string isEqual:@"User corrected source"] && controller.resultText.string.length == 0,
              @"editing source cancels and invalidates translation without overwriting the edit");

        [controller translate:nil]; MCControlledTranslation *oldTarget = bridge.requests.lastObject;
        [controller.targetLanguage selectItemAtIndex:1]; [controller languageChanged:controller.targetLanguage];
        [oldTarget reply:@"obsolete target"]; Deliver();
        Check(!controller.translating && controller.resultText.string.length == 0, @"changing target invalidates the previous translation");
        [controller translate:nil]; MCControlledTranslation *newTarget = bridge.requests.lastObject;
        Check([newTarget.target isEqual:@"en"], @"new translation uses changed target");
        [newTarget reply:@"Current translation"]; Deliver();
        Check([controller.resultText.string isEqual:@"Current translation"] && controller.resultText.editable && controller.resultCopyButton.enabled,
              @"current translation can be edited and copied");
        Edit(controller, controller.resultText, @"Manually edited translation 中文");
        NSPasteboard *pasteboard = [NSPasteboard pasteboardWithUniqueName];
        Check([controller copyText:controller.resultText.string toPasteboard:pasteboard] &&
              [[pasteboard stringForType:NSPasteboardTypeString] isEqual:@"Manually edited translation 中文"], @"copy edited translation only to the test pasteboard");

        NSUInteger translations = bridge.requests.count;
        [controller recognizeAndTranslate:YES]; [recognizer.requests.lastObject reply:@"" error:nil]; Deliver();
        Check(bridge.requests.count == translations && controller.sourceText.editable && !controller.translateButton.enabled,
              @"no-text OCR keeps editable source and does not start translation");
        [controller recognizeAndTranslate:YES];
        [recognizer.requests.lastObject reply:nil error:[NSError errorWithDomain:MCTextRecognitionErrorDomain code:MCTextRecognitionInvalidImage userInfo:@{NSLocalizedDescriptionKey:@"fixture invalid image"}]];
        Deliver();
        Check(bridge.requests.count == translations && [controller.status.stringValue containsString:@"fixture invalid image"], @"OCR failure does not start translation");
        [controller recognizeAndTranslate:YES]; [recognizer.requests.lastObject reply:@"Automatic translation source" error:nil]; Deliver();
        Check(bridge.requests.count == translations + 1 && controller.translating, @"translate action chains only successful nonempty OCR");
        [bridge.requests.lastObject reply:@"自动翻译结果"]; Deliver();
        Check([controller.resultText.string isEqual:@"自动翻译结果"], @"current chained translation is accepted");

        [controller recognizeAndTranslate:NO]; MCControlledRecognition *cancelled = recognizer.requests.lastObject;
        [controller cancelTask:nil]; Edit(controller, controller.sourceText, @"Input after cancellation");
        [cancelled reply:@"late cancelled OCR" error:nil]; Deliver();
        Check(cancelled.cancellations == 1 && [controller.sourceText.string isEqual:@"Input after cancellation"], @"cancelled OCR cannot overwrite later user input");

        [controller translate:nil]; MCControlledTranslation *closing = bridge.requests.lastObject;
        __block NSUInteger closes = 0; controller.onClose = ^{ closes++; };
        NSTimer *timer = controller.leaseTimer;
        [controller close]; [closing reply:@"late closed result"]; Deliver();
        Check(controller.closed && closes == 1 && !timer.valid && controller.sourceText.string.length == 0 && controller.resultText.string.length == 0,
              @"close cancels work, invalidates lease timer, clears text, and rejects late translation");
        [controller close]; Check(closes == 1, @"close callback runs once");

        MCControlledRecognizer *leaseRecognizer = nil;
        MCTextResultWindowController *lostLease = Controller(^BOOL { return current; }, &leaseRecognizer);
        [lostLease recognizeAndTranslate:NO]; MCControlledRecognition *pending = leaseRecognizer.requests.lastObject;
        current = NO; // Includes revision, crop, or uncommitted text/property snapshot loss.
        [pending reply:@"stale capture content" error:nil]; Deliver();
        Check(lostLease.closed && pending.cancellations == 1 && lostLease.sourceText.string.length == 0,
              @"capture content lease loss closes the window and rejects OCR output");
        Check(![lostLease copyText:@"stale copy" toPasteboard:pasteboard] &&
              [[pasteboard stringForType:NSPasteboardTypeString] isEqual:@"Manually edited translation 中文"], @"invalid capture cannot change the test pasteboard");
        [pasteboard releaseGlobally];
        for (NSWindow *window in NSApp.windows) Check(!window.visible, @"no test window may become visible");
        printf("Text tools passed: controlled OCR/translation generations, source and language edits, cancellation, close, capture-content lease loss, and unique-pasteboard copy. Apple Translation engine is not exercised by this fixture.\n");
    }
    return 0;
}
