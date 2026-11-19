#import <AppKit/AppKit.h>
#import <Sparkle/Sparkle.h>
#import "native/macos/updates/MCUpdateController.h"
#include "moonbit.h"
#include <stdatomic.h>

static BOOL require(BOOL condition, NSString *message) {
    if (!condition) fprintf(stderr, "FAIL update source: %s\n", message.UTF8String);
    return condition;
}
static void drain(void) {
    NSDate *until = [NSDate dateWithTimeIntervalSinceNow:.03];
    while ([until timeIntervalSinceNow] > 0) [NSRunLoop.mainRunLoop runMode:NSDefaultRunLoopMode beforeDate:until];
}
static BOOL waitFor(BOOL (^done)(void)) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:3];
    while (!done() && deadline.timeIntervalSinceNow > 0) drain();
    return done();
}

// Fake transport holds callbacks so cancellation and out-of-order completion
// can be tested. There is no NSURLSession or real installer in controller tests.
@interface MCQueuedReleaseSource : NSObject <MCReleaseSource>
@property NSMutableArray *callbacks;
@property NSUInteger cancellations;
@end
@implementation MCQueuedReleaseSource
- (instancetype)init { if ((self = [super init])) _callbacks = [NSMutableArray array]; return self; }
- (void)fetchReleases:(MCReleaseSourceCompletion)completion { [self.callbacks addObject:[completion copy]]; }
- (void)cancel { self.cancellations++; }
@end

@interface MCUpdateController (FixtureBoundary)
- (BOOL)mayStartForBundle;
- (BOOL)startSparkle:(NSError **)error;
- (BOOL)updaterCanCheckForUpdates;
- (BOOL)updaterSessionInProgress;
- (void)performUpdateCheckInBackground:(BOOL)background;
- (void)updaterStateDidChange;
@end
@interface MCFixtureUpdater : MCUpdateController
@property BOOL active;
@property BOOL automatic;
@property NSUInteger checks;
@property NSUInteger focusRequests;
@property BOOL lastBackground;
@property NSString *checkedFeed;
@end
@implementation MCFixtureUpdater
- (BOOL)mayStartForBundle { return YES; }
- (BOOL)startSparkle:(NSError **)error { (void)error; return YES; }
- (BOOL)updaterCanCheckForUpdates { return YES; }
- (BOOL)updaterSessionInProgress { return self.active; }
- (BOOL)automaticallyChecksForUpdates { return self.automatic; }
- (void)setAutomaticallyChecksForUpdates:(BOOL)value { self.automatic = value; [super setAutomaticallyChecksForUpdates:value]; }
- (void)performUpdateCheckInBackground:(BOOL)background {
    if (self.active) { self.focusRequests++; return; }
    self.checks++; self.lastBackground = background; self.active = YES;
    id<SPUUpdaterDelegate> delegate = (id)self;
    NSError *error = nil;
    // The argument is an opaque identity here; controller delegates never call
    // into it. The fake driver deliberately cannot download/install anything.
    if (![delegate updater:(id)self mayPerformUpdateCheck:background ? SPUUpdateCheckUpdatesInBackground : SPUUpdateCheckUpdates error:&error])
        [NSException raise:@"UnexpectedSourceGate" format:@"%@", error];
    self.checkedFeed = [delegate feedURLStringForUpdater:(id)self];
}
@end

// Sparkle's state object has no public initializer. This read-only state
// double supplies only the documented property used by the real delegate.
@interface MCFixtureUpdateState : NSObject
@property SPUUserUpdateStage stage;
@end
@implementation MCFixtureUpdateState
@end

static NSBundle *fixtureBundle(NSURL *directory) {
    NSURL *contents = [[directory URLByAppendingPathComponent:@"Updater.app"] URLByAppendingPathComponent:@"Contents"];
    [NSFileManager.defaultManager createDirectoryAtURL:contents withIntermediateDirectories:YES attributes:nil error:NULL];
    NSDictionary *info = @{@"CFBundleIdentifier":@"dev.moojicut.update-source-fixture", @"CFBundleName":@"Fixture",
        @"CFBundlePackageType":@"APPL", @"CFBundleVersion":@"0.1.0a8", @"MoojiCutReleaseVersion":@"0.1.0-alpha.8",
        @"SUFeedURL":@"https://example.invalid/never-fetch.xml", @"SUPublicEDKey":[[NSMutableData dataWithLength:32] base64EncodedStringWithOptions:0],
        @"SURequireSignedFeed":@YES, @"SUVerifyUpdateBeforeExtraction":@YES};
    [info writeToURL:[contents URLByAppendingPathComponent:@"Info.plist"] error:NULL];
    return [NSBundle bundleWithURL:contents.URLByDeletingLastPathComponent];
}
static NSData *releases(NSString *version, BOOL package, BOOL feed) {
    NSString *prefix = [NSString stringWithFormat:@"https://github.com/CoderSerio/moojicut/releases/download/v%@/", version];
    NSString *name = [NSString stringWithFormat:@"moojicut-%@-macos-arm64.zip", version];
    NSMutableArray *assets = [NSMutableArray array];
    if (package) [assets addObject:@{@"name":name, @"state":@"uploaded", @"size":@1024,
        @"digest":@"sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
        @"browser_download_url":[prefix stringByAppendingString:name]}];
    if (feed) [assets addObject:@{@"name":@"macos.xml", @"state":@"uploaded", @"size":@1024,
        @"browser_download_url":[prefix stringByAppendingString:@"macos.xml"]}];
    return [NSJSONSerialization dataWithJSONObject:@[@{@"tag_name":[@"v" stringByAppendingString:version],
        @"draft":@NO, @"prerelease":@YES, @"published_at":@"2026-11-14T00:00:00Z", @"assets":assets,
        @"html_url":[@"https://github.com/CoderSerio/moojicut/releases/tag/v" stringByAppendingString:version]}] options:0 error:NULL];
}
static void complete(MCQueuedReleaseSource *source, NSUInteger index, NSData *data, NSError *error) {
    MCReleaseSourceCompletion completion = source.callbacks[index]; completion(data, error); drain();
}
static BOOL controllerFixtures(NSBundle *bundle) {
    BOOL passed = YES;
    MCQueuedReleaseSource *source = [MCQueuedReleaseSource new];
    MCFixtureUpdater *controller = [[MCFixtureUpdater alloc] initWithBundle:bundle releaseSource:source];
    [controller start];
    __block BOOL busy = NO;
    controller.isOperationBusy = ^{ return busy; };
    [controller checkForUpdates:nil]; [controller checkForUpdates:nil];
    passed &= require(controller.checkingSource && !controller.canCheckForUpdates && source.callbacks.count == 1,
        @"discovery immediately gates duplicate clicks");
    complete(source, 0, releases(@"0.1.0-alpha.9", YES, NO), nil);
    passed &= require(!controller.checkingSource && controller.checks == 0 && controller.canCheckForUpdates &&
        [controller.statusText containsString:@"签名更新源"] && controller.releasePageURL != nil,
        @"an unsigned release offers its verified release page, never a synthetic Sparkle feed");
    [controller checkForUpdates:nil];
    complete(source, 1, releases(@"0.1.0-alpha.9", NO, YES), nil);
    passed &= require(controller.checks == 0 && [controller.statusText containsString:@"安装包尚未准备好"],
        @"a feed alone cannot install a missing platform package");
    [controller checkForUpdates:nil];
    complete(source, 2, releases(@"0.1.0-alpha.8", YES, YES), nil);
    passed &= require(controller.checks == 0 && [controller.statusText containsString:@"最新版本"], @"equal versions never downgrade or launch installer");
    [controller checkForUpdates:nil]; [controller cancelCheck];
    complete(source, 3, releases(@"0.1.0-alpha.9", YES, YES), nil);
    passed &= require(controller.checks == 0 && [controller.statusText containsString:@"取消"], @"cancel discards late network completion");
    [controller checkForUpdates:nil];
    busy = YES;
    complete(source, 4, releases(@"0.1.0-alpha.9", YES, YES), nil);
    passed &= require(controller.checks == 0 && !controller.canCheckForUpdates, @"capture starting during discovery defers Sparkle");
    busy = NO; [controller operationStateDidChange]; [controller operationStateDidChange];
    passed &= require(controller.checks == 1 && !controller.lastBackground &&
        [controller.checkedFeed isEqual:@"https://moojicut-downloads.pages.dev/v0.1.0-alpha.9/macos.xml"],
        @"idle resumes exactly once using the mirrored signed-feed asset");
    [controller checkForUpdates:nil];
    passed &= require(controller.focusRequests == 1 && source.callbacks.count == 5,
        @"Sparkle canCheck while showing UI focuses it without duplicate discovery");
    id<SPUUpdaterDelegate> delegate = (id)controller;
    controller.active = NO;
    [delegate updater:(id)controller didFinishUpdateCycleForUpdateCheck:SPUUpdateCheckUpdates
        error:[NSError errorWithDomain:SUSparkleErrorDomain code:SUAppcastError userInfo:nil]];
    drain();
    passed &= require(controller.checks == 2 &&
        [controller.checkedFeed isEqual:@"https://github.com/CoderSerio/moojicut/releases/download/v0.1.0-alpha.9/macos.xml"],
        @"Sparkle retries with the GitHub feed after the mirror fails");
    controller.active = NO; controller.checks = 1;
    [delegate updater:(id)controller didFinishUpdateCycleForUpdateCheck:SPUUpdateCheckUpdates error:nil];
    [controller checkForUpdates:nil];
    complete(source, 5, [@"malformed" dataUsingEncoding:NSUTF8StringEncoding], nil);
    passed &= require(controller.checks == 1 && [controller.statusText containsString:@"信息无效"], @"malformed data cannot become an update");
    [controller checkForUpdates:nil];
    complete(source, 6, nil, [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorTimedOut userInfo:nil]);
    passed &= require(controller.canCheckForUpdates && [controller.statusText containsString:@"超时"], @"timeout releases check gate and explains retry");

    // The timer must wait for both async source discovery AND the aborted
    // Sparkle cycle. In particular a fast response cannot overlap the cycle.
    controller.automaticallyChecksForUpdates = YES;
    controller.active = YES;
    NSError *pending = nil;
    passed &= require(![delegate updater:(id)controller mayPerformUpdateCheck:SPUUpdateCheckUpdatesInBackground error:&pending] &&
        pending.code == 100 && controller.checkingSource, @"automatic timer enters discovery instead of old bundle feed");
    complete(source, 7, releases(@"0.1.0-alpha.9", YES, YES), nil);
    passed &= require(controller.checks == 1, @"fast discovery does not overlap the finishing Sparkle cycle");
    controller.active = NO;
    [delegate updater:(id)controller didFinishUpdateCycleForUpdateCheck:SPUUpdateCheckUpdatesInBackground error:pending];
    passed &= require(controller.checks == 2 && controller.lastBackground, @"automatic source discovery resumes one background cycle");
    controller.active = NO;
    [delegate updater:(id)controller didFinishUpdateCycleForUpdateCheck:SPUUpdateCheckUpdatesInBackground error:nil];
    controller.active = YES;
    pending = nil;
    [delegate updater:(id)controller mayPerformUpdateCheck:SPUUpdateCheckUpdatesInBackground error:&pending];
    controller.active = NO;
    [delegate updater:(id)controller didFinishUpdateCycleForUpdateCheck:SPUUpdateCheckUpdatesInBackground error:pending];
    controller.automaticallyChecksForUpdates = NO;
    complete(source, 8, releases(@"0.1.0-alpha.9", YES, YES), nil);
    passed &= require(controller.checks == 2 && !controller.checkingSource, @"disabling automatic checks cancels pending source work");

    // Sparkle starts another asynchronous installer probe when scheduling its
    // next check after didFinish. It reports canCheck=YES before session=NO.
    // A release result arriving in that gap must be resumed by state KVO alone.
    controller.automaticallyChecksForUpdates = YES;
    controller.active = YES; pending = nil;
    [delegate updater:(id)controller mayPerformUpdateCheck:SPUUpdateCheckUpdatesInBackground error:&pending];
    controller.active = NO;
    [delegate updater:(id)controller didFinishUpdateCycleForUpdateCheck:SPUUpdateCheckUpdatesInBackground error:pending];
    controller.active = YES;
    complete(source, 9, releases(@"0.1.0-alpha.9", YES, YES), nil);
    passed &= require(controller.checks == 2 && !controller.canCheckForUpdates, @"a scheduler probe defers the resolved feed");
    [controller updaterStateDidChange]; // canCheck notification, still active
    controller.active = NO;
    [controller updaterStateDidChange]; // session notification, now idle
    passed &= require(controller.checks == 2, @"state notifications do not re-enter Sparkle synchronously");
    drain();
    passed &= require(controller.checks == 3 && controller.lastBackground,
        @"scheduler becoming idle resumes once without an unrelated capture event");
    controller.active = NO;
    [delegate updater:(id)controller didFinishUpdateCycleForUpdateCheck:SPUUpdateCheckUpdatesInBackground error:nil];
    controller.active = YES; pending = nil;
    [delegate updater:(id)controller mayPerformUpdateCheck:SPUUpdateCheckUpdatesInBackground error:&pending];
    controller.active = NO;
    [delegate updater:(id)controller didFinishUpdateCycleForUpdateCheck:SPUUpdateCheckUpdatesInBackground error:pending];
    controller.active = YES;
    complete(source, 10, releases(@"0.1.0-alpha.9", YES, YES), nil);
    controller.active = NO;
    [controller updaterStateDidChange];
    [controller cancelCheck];
    drain();
    passed &= require(controller.checks == 3 && controller.canCheckForUpdates,
        @"canceling before deferred KVO recovery discards the pending check");
    return passed;
}

static BOOL completedChoiceFixtures(NSBundle *bundle) {
    NSArray<NSDictionary *> *cases = @[
        @{@"choice":@(-1), @"stage":@(SPUUserUpdateStageNotDownloaded), @"status":@"下载已取消"},
        @{@"choice":@(SPUUserUpdateChoiceSkip), @"stage":@(SPUUserUpdateStageNotDownloaded), @"status":@"已跳过"},
        @{@"choice":@(SPUUserUpdateChoiceDismiss), @"stage":@(SPUUserUpdateStageNotDownloaded), @"status":@"暂不更新"},
        @{@"choice":@(SPUUserUpdateChoiceDismiss), @"stage":@(SPUUserUpdateStageDownloaded), @"status":@"暂不更新"},
        @{@"choice":@(SPUUserUpdateChoiceDismiss), @"stage":@(SPUUserUpdateStageInstalling), @"status":@"退出应用后安装"},
        @{@"choice":@(-2), @"stage":@(SPUUserUpdateStageNotDownloaded), @"status":@"更新检查已结束"}
    ];
    for (NSDictionary *fixture in cases) {
        MCQueuedReleaseSource *source = [MCQueuedReleaseSource new];
        MCFixtureUpdater *controller = [[MCFixtureUpdater alloc] initWithBundle:bundle releaseSource:source];
        [controller start]; [controller checkForUpdates:nil];
        complete(source, 0, releases(@"0.1.0-alpha.9", YES, YES), nil);
        id<SPUUpdaterDelegate> delegate = (id)controller;
        SUAppcastItem *item = SUAppcastItem.emptyAppcastItem;
        [delegate updater:(id)controller didFindValidUpdate:item];
        NSInteger choice = [fixture[@"choice"] integerValue];
        // Sparkle checks these optional selectors before delivering callbacks.
        if (choice == -1 && [delegate respondsToSelector:@selector(userDidCancelDownload:)])
            [delegate userDidCancelDownload:(id)controller];
        else if (choice >= 0 && [delegate respondsToSelector:@selector(updater:userDidMakeChoice:forUpdate:state:)]) {
            MCFixtureUpdateState *state = [MCFixtureUpdateState new];
            state.stage = [fixture[@"stage"] integerValue];
            [delegate updater:(id)controller userDidMakeChoice:(SPUUserUpdateChoice)choice forUpdate:item state:(id)state];
        }
        controller.active = NO;
        [delegate updater:(id)controller didFinishUpdateCycleForUpdateCheck:SPUUpdateCheckUpdates error:nil];
        if (!require(controller.canCheckForUpdates && !controller.installationPending &&
            [controller.statusText containsString:fixture[@"status"]],
            @"nil-error completion preserves choice status, ends stale progress and releases manual retry")) return NO;
        [controller checkForUpdates:nil];
        if (!require(source.callbacks.count == 2 && controller.checkingSource,
            @"a completed or cancelled update cycle can start a fresh release lookup")) return NO;
        complete(source, 1, releases(@"0.1.0-alpha.8", YES, YES), nil);
        [delegate updater:(id)controller didFinishUpdateCycleForUpdateCheck:SPUUpdateCheckUpdates error:nil];
        if (!require(controller.canCheckForUpdates && [controller.statusText containsString:@"最新版本"],
            @"normal cycle cleanup does not overwrite the specific current-version status")) return NO;
    }
    return YES;
}

static NSData *protocolBody;
static NSInteger protocolStatus;
static NSDictionary *protocolHeaders;
static NSError *protocolError;
static BOOL protocolHold;
static atomic_uint protocolStarts;
static atomic_uint githubStarts;
static BOOL protocolHealthyFallback;
@interface MCOfflineURLProtocol : NSURLProtocol
@end
@implementation MCOfflineURLProtocol
+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
    return [@[@"moojicut-downloads.pages.dev", @"api.github.com"] containsObject:request.URL.host];
}
+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request { return request; }
- (void)startLoading {
    atomic_fetch_add(&protocolStarts, 1);
    BOOL github = [self.request.URL.host isEqual:@"api.github.com"];
    if (github) atomic_fetch_add(&githubStarts, 1);
    if (protocolHold) return;
    if (protocolError) { [self.client URLProtocol:self didFailWithError:protocolError]; return; }
    NSData *body = github && protocolHealthyFallback ? [@"[]" dataUsingEncoding:NSUTF8StringEncoding] : protocolBody;
    NSInteger status = github && protocolHealthyFallback ? 200 : protocolStatus;
    NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:self.request.URL statusCode:status
        HTTPVersion:@"HTTP/1.1" headerFields:protocolHeaders];
    [self.client URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    for (NSUInteger offset = 0; offset < body.length; offset += 65536)
        [self.client URLProtocol:self didLoadData:[body subdataWithRange:NSMakeRange(offset, MIN((NSUInteger)65536, body.length - offset))]];
    [self.client URLProtocolDidFinishLoading:self];
}
- (void)stopLoading {}
@end

static BOOL transportFixtures(void) {
    BOOL passed = YES;
    NSURLSessionConfiguration *config = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    config.protocolClasses = @[MCOfflineURLProtocol.class];
    MCReleaseIndexSource *source = [[MCReleaseIndexSource alloc] initWithConfiguration:config];
    for (NSInteger scenario = 0; scenario < 9; scenario++) {
        protocolBody = [@"[]" dataUsingEncoding:NSUTF8StringEncoding];
        protocolStatus = 200; protocolError = nil; protocolHeaders = @{}; protocolHold = NO;
        if (scenario == 1) protocolStatus = 429;
        if (scenario == 2) protocolHeaders = @{@"Content-Length":@"4194305"};
        if (scenario == 3) protocolBody = [NSMutableData dataWithLength:4194305];
        if (scenario == 4) protocolError = [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorTimedOut userInfo:nil];
        if (scenario == 5) protocolHeaders = @{@"Link":@"<https://api.github.com/repos/CoderSerio/moojicut/releases?page=2>; rel=\"next\""};
        if (scenario == 6) protocolHold = YES;
        protocolHealthyFallback = scenario >= 7;
        if (scenario == 7) protocolStatus = 404;
        if (scenario == 8) protocolBody = [@"malformed" dataUsingEncoding:NSUTF8StringEncoding];
        __block NSUInteger calls = 0;
        __block NSData *result = nil;
        __block NSError *error = nil;
        unsigned before = atomic_load(&protocolStarts);
        unsigned githubBefore = atomic_load(&githubStarts);
        [source fetchReleases:^(NSData *body, NSError *failure) { calls++; result = body; error = failure; }];
        if (scenario == 6) {
            passed &= require(waitFor(^BOOL{ return atomic_load(&protocolStarts) > before; }), @"held request starts only in fake URL protocol");
            __block BOOL rejected = NO;
            [source fetchReleases:^(NSData *body, NSError *failure) { rejected = !body && failure != nil; }];
            passed &= require(rejected, @"transport rejects overlapping fetches without replacing callback");
            [source cancel];
        }
        passed &= require(waitFor(^BOOL{ return calls > 0; }), @"transport completes every response/error/cancel without hanging");
        BOOL succeeds = scenario == 0 || scenario >= 7;
        passed &= require(calls == 1 && (succeeds ? result.length == 2 && !error : !result && error != nil),
            [NSString stringWithFormat:@"bounded transport scenario %ld", (long)scenario]);
        drain();
        passed &= require(calls == 1, @"late URLSession cancellation events cannot call completion twice");
        passed &= require(atomic_load(&githubStarts) - githubBefore == (scenario != 0 && scenario != 6 ? 1u : 0u),
            @"GitHub is contacted once per failed mirror attempt and never on success or cancellation");
    }
    return passed;
}

int main(void) {
    @autoreleasepool {
        moonbit_init();
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
        NSURL *directory = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString]];
        NSBundle *bundle = fixtureBundle(directory);
        BOOL passed = controllerFixtures(bundle) && completedChoiceFixtures(bundle) && transportFixtures();
        [NSFileManager.defaultManager removeItemAtURL:directory error:NULL];
        puts(passed ? "PASS update source: release discovery, signed-feed routing, busy/cancel/duplicate gates, download/choice cancellation and retry, automatic checks and bounded offline transport" : "FAIL update source");
        return passed ? 0 : 1;
    }
}
