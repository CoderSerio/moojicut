#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <Sparkle/Sparkle.h>
#import "native/macos/updates/MCUpdateController.h"

static BOOL require(BOOL condition, NSString *message) {
    if (!condition) fprintf(stderr, "FAIL updater: %s\n", message.UTF8String);
    return condition;
}

// Always supply the throwaway key over stdin. Never access the user's Keychain
// or put private key material into a command line, log, or fixture on disk.
static int signingTool(NSURL *tool, NSArray<NSString *> *arguments, NSData *seed, NSString **output) {
    NSTask *task = [NSTask new];
    task.executableURL = tool;
    task.arguments = [@[@"--ed-key-file", @"-"] arrayByAddingObjectsFromArray:arguments];
    NSPipe *input = NSPipe.pipe, *capture = NSPipe.pipe;
    task.standardInput = input;
    task.standardOutput = capture;
    task.standardError = capture;
    NSError *error = nil;
    if (![task launchAndReturnError:&error]) {
        fprintf(stderr, "FAIL updater: signing tool could not launch (%ld).\n", (long)error.code);
        return -1;
    }
    NSData *encodedSeed = [[[seed base64EncodedStringWithOptions:0] stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding];
    [input.fileHandleForWriting writeData:encodedSeed];
    [input.fileHandleForWriting closeFile];
    NSData *captured = [capture.fileHandleForReading readDataToEndOfFile];
    [task waitUntilExit];
    if (output) *output = [[[NSString alloc] initWithData:captured encoding:NSUTF8StringEncoding]
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return task.terminationReason == NSTaskTerminationReasonExit ? task.terminationStatus : -1;
}

static BOOL versionOrdering(void) {
    SUStandardVersionComparator *comparator = SUStandardVersionComparator.defaultComparator;
    NSArray<NSString *> *versions = @[@"0.1.0a1", @"0.1.0a2", @"0.1.0b1", @"0.1.0fc1", @"0.1.0", @"0.1.1a1"];
    for (NSUInteger i = 0; i < versions.count; i++) {
        for (NSUInteger j = 0; j < versions.count; j++) {
            NSComparisonResult expected = i < j ? NSOrderedAscending : i > j ? NSOrderedDescending : NSOrderedSame;
            if (!require([comparator compareVersion:versions[i] toVersion:versions[j]] == expected,
                [NSString stringWithFormat:@"Sparkle ordering %@ versus %@", versions[i], versions[j]])) return NO;
        }
    }
    NSString *frameworkVersion = [NSBundle bundleForClass:SUStandardVersionComparator.class].infoDictionary[@"CFBundleShortVersionString"];
    return require([frameworkVersion isEqualToString:@"2.10.1"], @"tests must load pinned Sparkle 2.10.1");
}

static NSBundle *bundleFixture(NSURL *directory, NSDictionary *configuration) {
    NSURL *url = [directory URLByAppendingPathComponent:[NSUUID.UUID.UUIDString stringByAppendingPathExtension:@"app"]];
    NSURL *contents = [url URLByAppendingPathComponent:@"Contents" isDirectory:YES];
    if (![NSFileManager.defaultManager createDirectoryAtURL:contents withIntermediateDirectories:YES attributes:nil error:NULL]) return nil;
    NSMutableDictionary *info = [@{@"CFBundleIdentifier":@"dev.moojicut.updater-fixture",
        @"CFBundleName":@"Updater Fixture", @"CFBundlePackageType":@"APPL", @"CFBundleVersion":@"0.1.0a1"} mutableCopy];
    [info addEntriesFromDictionary:configuration];
    if (![info writeToURL:[contents URLByAppendingPathComponent:@"Info.plist"] error:NULL]) return nil;
    return [NSBundle bundleWithURL:url];
}

static BOOL configurationAndBusyState(NSURL *directory) {
    NSString *feed = @"https://example.invalid/appcast.xml";
    // This is a format fixture, not a deployment key. Actual cryptographic
    // verification is exercised independently with fresh seeds below.
    NSString *key = [[NSMutableData dataWithLength:32] base64EncodedStringWithOptions:0];
    NSArray<NSDictionary *> *invalidConfigurations = @[
        @{}, @{@"SUFeedURL":feed}, @{@"SUPublicEDKey":key},
        @{@"SUFeedURL":@"http://example.invalid/appcast.xml", @"SUPublicEDKey":key},
        @{@"SUFeedURL":@"https://fixture-user@example.invalid/appcast.xml", @"SUPublicEDKey":key},
        @{@"SUFeedURL":feed, @"SUPublicEDKey":@"not-base64"},
        @{@"SUFeedURL":feed, @"SUPublicEDKey":[[NSMutableData dataWithLength:16] base64EncodedStringWithOptions:0]}
    ];
    for (NSDictionary *configuration in invalidConfigurations) {
        NSBundle *bundle = bundleFixture(directory, configuration);
        if (!require(bundle && [MCUpdateController configurationErrorForBundle:bundle].length > 0,
            @"missing, insecure, or malformed feed configuration must be rejected")) return NO;
        MCUpdateController *disabled = [[MCUpdateController alloc] initWithBundle:bundle];
        [disabled start];
        [disabled checkForUpdates:nil];
        disabled.automaticallyChecksForUpdates = YES;
        if (!require(!disabled.available && !disabled.canCheckForUpdates && !disabled.automaticallyChecksForUpdates && disabled.statusText.length > 0,
            @"an unconfigured updater must stay disabled without opening UI or contacting a feed")) return NO;
    }
    NSBundle *bundle = bundleFixture(directory, @{@"SUFeedURL":feed, @"SUPublicEDKey":key});
    if (!require(bundle && ![MCUpdateController configurationErrorForBundle:bundle], @"well-formed HTTPS feed configuration")) return NO;
    MCUpdateController *controller = [[MCUpdateController alloc] initWithBundle:bundle];
    __block BOOL busy = YES;
    __block NSUInteger installations = 0;
    controller.isOperationBusy = ^{ return busy; };
    id<SPUUpdaterDelegate> delegate = (id)controller;
    SPUUpdater *inactiveUpdater = nil; // These gate methods do not need an active updater or network session.
    SUAppcastItem *item = SUAppcastItem.emptyAppcastItem;
    for (NSInteger check = SPUUpdateCheckUpdates; check <= SPUUpdateCheckUpdateInformation; check++) {
        NSError *error = nil;
        if (!require(![delegate updater:inactiveUpdater mayPerformUpdateCheck:(SPUUpdateCheck)check error:&error] && error.localizedDescription.length > 0,
            @"all update check types must defer while capture/editing is busy")) return NO;
    }
    NSError *midCheckError = nil;
    if (!require(![delegate updater:inactiveUpdater shouldProceedWithUpdate:item updateCheck:SPUUpdateCheckUpdates error:&midCheckError] && midCheckError,
        @"an update found after capture starts must recheck the busy state")) return NO;
    if (!require([delegate updater:inactiveUpdater shouldPostponeRelaunchForUpdate:item untilInvokingBlock:^{ installations++; }] &&
        controller.installationPending, @"busy editing must postpone installation/relaunch")) return NO;
    [controller operationStateDidChange];
    if (!require(installations == 0, @"busy state changes must not install")) return NO;
    busy = NO;
    [controller operationStateDidChange];
    [controller operationStateDidChange];
    if (!require(installations == 1, @"becoming idle must release the pending installation exactly once")) return NO;
    NSError *error = nil;
    if (!require([delegate updater:inactiveUpdater mayPerformUpdateCheck:SPUUpdateCheckUpdates error:&error] && !error,
        @"idle editing must allow an update check")) return NO;

    // A cancelled update must discard its postponed installation, even when
    // the application later becomes idle and emits another activity change.
    busy = YES;
    if (!require([delegate updater:inactiveUpdater shouldPostponeRelaunchForUpdate:item untilInvokingBlock:^{ installations++; }],
        @"second update can be postponed")) return NO;
    [delegate updater:inactiveUpdater didFinishUpdateCycleForUpdateCheck:SPUUpdateCheckUpdates
        error:[NSError errorWithDomain:SUSparkleErrorDomain code:SUInstallationCanceledError userInfo:nil]];
    busy = NO;
    [controller operationStateDidChange];
    if (!require(installations == 1 && !controller.installationPending,
        @"cancelled updates must never execute an old installation callback")) return NO;
    [controller start];
    return require(!controller.available && !controller.canCheckForUpdates,
        @"a fixture bundle must not start an updater for the running test executable");
}

static BOOL signedFixtures(NSURL *tool, NSURL *directory) {
    NSMutableData *seed = [NSMutableData dataWithLength:32], *otherSeed = [NSMutableData dataWithLength:32];
    if (!require(SecRandomCopyBytes(kSecRandomDefault, seed.length, seed.mutableBytes) == errSecSuccess &&
        SecRandomCopyBytes(kSecRandomDefault, otherSeed.length, otherSeed.mutableBytes) == errSecSuccess,
        @"could not create ephemeral signing seeds")) return NO;
    NSURL *archive = [directory URLByAppendingPathComponent:@"synthetic-update.zip"];
    NSData *original = [@"Mooji Cut synthetic update bytes: no application or user data." dataUsingEncoding:NSUTF8StringEncoding];
    if (!require([original writeToURL:archive atomically:YES], @"write signed archive fixture")) return NO;
    NSString *signature = nil;
    if (!require(signingTool(tool, @[@"-p", archive.path], seed, &signature) == 0 &&
        [[NSData alloc] initWithBase64EncodedString:signature options:0].length == 64,
        @"Sparkle must create a 64-byte Ed25519 archive signature")) return NO;
    if (!require(signingTool(tool, @[@"--verify", archive.path, signature], seed, NULL) == 0,
        @"Sparkle must verify the unchanged archive")) return NO;
    if (!require(signingTool(tool, @[@"--verify", archive.path, signature], otherSeed, NULL) > 0,
        @"Sparkle must reject the archive with a different signing key")) return NO;
    NSMutableData *tampered = [original mutableCopy];
    ((uint8_t *)tampered.mutableBytes)[0] ^= 1;
    if (!require([tampered writeToURL:archive atomically:YES] &&
        signingTool(tool, @[@"--verify", archive.path, signature], seed, NULL) > 0,
        @"Sparkle must reject a one-byte change without relying on file length")) return NO;

    // SUAppcast has no public file parser. Exercise Sparkle's actual signed XML
    // tool instead of declaring private selectors or pretending to fetch a feed.
    NSURL *appcast = [directory URLByAppendingPathComponent:@"appcast.xml"];
    if (!require([original writeToURL:archive atomically:YES], @"restore archive matching the appcast signature")) return NO;
    NSString *xml = [NSString stringWithFormat:
        @"<?xml version=\"1.0\" encoding=\"utf-8\"?>\n"
         "<rss version=\"2.0\" xmlns:sparkle=\"http://www.andymatuschak.org/xml-namespaces/sparkle\"><channel>"
         "<title>Mooji Cut synthetic test feed</title><item><title>Alpha 2</title>"
         "<sparkle:version>0.1.0a2</sparkle:version><sparkle:shortVersionString>0.1.0-alpha.2</sparkle:shortVersionString>"
         "<sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>"
         "<enclosure url=\"https://example.invalid/synthetic-update.zip\" length=\"%lu\" type=\"application/octet-stream\" sparkle:edSignature=\"%@\"/>"
         "</item></channel></rss>\n", (unsigned long)original.length, signature];
    if (!require([xml writeToURL:appcast atomically:YES encoding:NSUTF8StringEncoding error:NULL] &&
        signingTool(tool, @[@"-p", appcast.path], seed, NULL) == 0 &&
        signingTool(tool, @[@"--verify", appcast.path], seed, NULL) == 0,
        @"Sparkle must sign and verify a local appcast without a network request")) return NO;
    NSString *signedXML = [NSString stringWithContentsOfURL:appcast encoding:NSUTF8StringEncoding error:NULL];
    NSString *alteredXML = [signedXML stringByReplacingOccurrencesOfString:@"0.1.0a2" withString:@"0.1.0a3"];
    if (!require(![signedXML isEqualToString:alteredXML] &&
        [alteredXML writeToURL:appcast atomically:YES encoding:NSUTF8StringEncoding error:NULL] &&
        signingTool(tool, @[@"--verify", appcast.path], seed, NULL) > 0,
        @"Sparkle must reject a tampered appcast version")) return NO;
    [seed resetBytesInRange:NSMakeRange(0, seed.length)];
    [otherSeed resetBytesInRange:NSMakeRange(0, otherSeed.length)];
    return YES;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 2) { fprintf(stderr, "Usage: updater-smoke /path/to/sparkle/bin/sign_update\n"); return 2; }
        NSURL *directory = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:
            [@"moojicut-updater-test-" stringByAppendingString:NSUUID.UUID.UUIDString]] isDirectory:YES];
        if (![NSFileManager.defaultManager createDirectoryAtURL:directory withIntermediateDirectories:NO
            attributes:@{NSFilePosixPermissions:@0700} error:NULL]) return 1;
        BOOL passed = versionOrdering() && configurationAndBusyState(directory) &&
            signedFixtures([NSURL fileURLWithPath:@(argv[1])], directory);
        [NSFileManager.defaultManager removeItemAtURL:directory error:NULL];
        puts(passed ? "PASS updater: Sparkle versions, configuration gates, busy/cancelled installation, signed archives/appcasts and tampering rejection" : "FAIL updater smoke");
        return passed ? 0 : 1;
    }
}
