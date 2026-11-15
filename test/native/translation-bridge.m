#import "plugins/feature/capture_text/macos/MCTranslationBridge.h"

// Link the real Swift implementation through its hand-written Objective-C
// contract. These requests fail before loading a view or contacting Translation;
// actual installed-language translation is a separate, explicitly opted-in CLI.
static void Check(BOOL condition, NSString *message) {
    if (!condition) {
        fprintf(stderr, "FAIL translation bridge: %s\n", message.UTF8String);
        exit(1);
    }
}

static void ExpectError(id<MCTextTranslating> bridge, NSString *text, NSString *source,
                        NSString *target, MCTranslationBridgeErrorCode expected) {
    __block NSUInteger callbacks = 0;
    __block BOOL finished = NO;
    [bridge translateText:text sourceLanguage:source targetLanguage:target
               completion:^(NSString *translated, NSString *resolvedSource, NSError *error) {
        callbacks++;
        Check(NSThread.isMainThread, @"completion must run on the main thread");
        Check(!translated && !resolvedSource, @"a rejected request must not fabricate translation output");
        Check([error.domain isEqualToString:@"dev.moojicut.translation"] && error.code == expected,
              [NSString stringWithFormat:@"expected error %ld, got %@", (long)expected, error]);
        Check(error.localizedDescription.length > 0, @"errors must contain a displayable explanation");
        finished = YES;
    }];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:1];
    while (!finished && deadline.timeIntervalSinceNow > 0) {
        [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
    Check(finished, @"rejected request completion did not arrive");
    [bridge cancel];
    [bridge cancel];
    NSDate *settle = [NSDate dateWithTimeIntervalSinceNow:0.01];
    while (settle.timeIntervalSinceNow > 0) [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:settle];
    Check(callbacks == 1, @"completion must occur exactly once; cancel must not deliver another callback");
}

int main(void) {
    @autoreleasepool {
        Check(NSApp == nil, @"fixture must not create NSApplication");
        MCTranslationBridge *bridge = [MCTranslationBridge new];
        Check([bridge conformsToProtocol:@protocol(MCTextTranslating)], @"real Swift class must conform to the Objective-C protocol");
        Check([bridge respondsToSelector:@selector(translateText:sourceLanguage:targetLanguage:completion:)], @"translation selector must match the static header");
        Check([bridge respondsToSelector:@selector(cancel)], @"cancellation selector must match the static header");
        [bridge cancel];
        ExpectError(bridge, @"", nil, @"en", MCTranslationBridgeInvalidInput);
        ExpectError(bridge, @" \n\t", @"en", @"zh-Hans", MCTranslationBridgeInvalidInput);
        // Each emoji is four UTF-8 bytes but only two UTF-16 code units. This
        // catches accidentally applying the 128 KiB cap to NSString.length.
        NSString *boundary = [@"" stringByPaddingToLength:65536 withString:@"😀" startingAtIndex:0];
        Check([boundary lengthOfBytesUsingEncoding:NSUTF8StringEncoding] == 128 * 1024, @"fixture must hit the exact UTF-8 byte boundary");
        ExpectError(bridge, [boundary stringByAppendingString:@"a"], nil, @"en", MCTranslationBridgeInvalidInput);
        ExpectError(bridge, @"Hello", nil, @"", MCTranslationBridgeInvalidInput);
        ExpectError(bridge, @"Hello", @"not a language", @"zh-Hans", MCTranslationBridgeInvalidInput);
        ExpectError(bridge, @"Hello", @"en", @"../zh", MCTranslationBridgeInvalidInput);
        ExpectError(bridge, boundary, nil, @"en", MCTranslationBridgeNotAttached);
        ExpectError(bridge, @"Hello", nil, @"zh-Hans", MCTranslationBridgeNotAttached);
        ExpectError(bridge, @"Hello", @"en", @"zh-Hans", MCTranslationBridgeNotAttached);
        Check(!bridge.isViewLoaded && NSApp == nil, @"validation must not create a view, app, translation session, or download UI");
        puts("PASS translation bridge: real Swift/ObjC ABI, protocol, UTF-8 limits, input rejection, detached lifecycle and main-thread completion (no app/window/download)");
    }
    return 0;
}
