#import "MCUpdateController.h"
#import <Sparkle/Sparkle.h>
#include "native/shared/update_release.h"

NSNotificationName const MCUpdateStateDidChangeNotification = @"MCUpdateStateDidChangeNotification";
static void *MCUpdateObservationContext = &MCUpdateObservationContext;
static NSString *const MCUpdateErrorDomain = @"MoojiCutUpdate";
static NSInteger const MCUpdateAwaitingSource = 100;
static NSArray<NSString *> *MCUpdateObservedKeys(void) {
    return @[@"canCheckForUpdates", @"automaticallyChecksForUpdates", @"sessionInProgress"];
}
static moonbit_string_t MCReleaseString(NSString *text) {
    moonbit_string_t value = moonbit_make_string_raw((int32_t)text.length);
    [text getCharacters:value range:NSMakeRange(0, text.length)];
    return value;
}
static NSString *MCReleaseText(int32_t handle, int32_t field) {
    moonbit_string_t value = update_release_text(handle, field);
    NSString *text = [[NSString alloc] initWithCharacters:value length:Moonbit_array_length(value)];
    moonbit_decref(value);
    return text;
}

@interface MCUpdateController () <SPUUpdaterDelegate>
@property NSBundle *bundle;
@property SPUStandardUpdaterController *controller;
@property (nonatomic, readwrite) BOOL available;
@property (nonatomic, readwrite) BOOL installationPending;
@property NSString *message;
@property BOOL started;
@property BOOL observing;
@property (nonatomic, copy) void (^pendingInstallation)(void);
@property id<MCReleaseSource> releaseSource;
@property (nonatomic, readwrite) BOOL checkingSource;
@property (nonatomic, readwrite) NSURL *releasePageURL;
@property NSString *resolvedFeedURL;
@property NSUInteger sourceGeneration;
@property BOOL sourceApproved;
@property BOOL backgroundLookup;
@property BOOL automaticCycleFinished;
@property NSInteger pendingResolvedCheck; // 0 none, 1 user, 2 background
@end

@implementation MCUpdateController
- (instancetype)init { return [self initWithBundle:NSBundle.mainBundle]; }
- (instancetype)initWithBundle:(NSBundle *)bundle {
    return [self initWithBundle:bundle releaseSource:[MCGitHubReleaseSource new]];
}
- (instancetype)initWithBundle:(NSBundle *)bundle releaseSource:(id<MCReleaseSource>)source {
    if ((self = [super init])) {
        _bundle = bundle;
        _releaseSource = source;
        _message = [self.class configurationErrorForBundle:bundle] ?: @"尚未检查更新。";
    }
    return self;
}
+ (NSString *)configurationErrorForBundle:(NSBundle *)bundle {
    id feed = [bundle objectForInfoDictionaryKey:@"SUFeedURL"];
    id key = [bundle objectForInfoDictionaryKey:@"SUPublicEDKey"];
    if (![feed isKindOfClass:NSString.class] || ![feed length] ||
        ![key isKindOfClass:NSString.class] || ![key length])
        return @"此版本尚未配置更新服务，请从发布页面下载新版本。";
    NSURLComponents *url = [NSURLComponents componentsWithString:feed];
    if (![url.scheme.lowercaseString isEqualToString:@"https"] || !url.host.length || url.user || url.password || url.fragment)
        return @"更新地址无效，暂时无法检查更新。";
    NSData *publicKey = [[NSData alloc] initWithBase64EncodedString:key options:0];
    if (publicKey.length != 32) return @"更新签名配置无效，暂时无法检查更新。";
    return nil;
}
- (BOOL)busy { return self.isOperationBusy && self.isOperationBusy(); }
- (void)notifyState {
    [NSNotificationCenter.defaultCenter postNotificationName:MCUpdateStateDidChangeNotification object:self];
}
- (NSString *)statusText {
    if (self.pendingInstallation) return @"更新已准备好，当前截图或录屏编辑结束后再安装并重启。";
    if (self.available && self.busy) return @"请先完成当前截图或录屏编辑，再检查更新。";
    return self.message;
}
- (BOOL)updaterCanCheckForUpdates { return self.controller.updater.canCheckForUpdates; }
- (BOOL)updaterSessionInProgress { return self.controller.updater.sessionInProgress; }
- (BOOL)canCheckForUpdates {
    return self.available && !self.busy && !self.installationPending && !self.checkingSource &&
        !self.pendingResolvedCheck && self.updaterCanCheckForUpdates;
}
- (BOOL)automaticallyChecksForUpdates { return self.available && self.controller.updater.automaticallyChecksForUpdates; }
- (void)setAutomaticallyChecksForUpdates:(BOOL)enabled {
    if (!self.available) return;
    // Sparkle owns and persists this preference. Never reset it during launch.
    self.controller.updater.automaticallyChecksForUpdates = enabled;
    if (!enabled && self.backgroundLookup) [self cancelCheck];
    [self notifyState];
}
+ (NSString *)installationErrorForBundleURL:(NSURL *)url profile:(id)profile identifier:(NSString *)identifier {
    // Legacy production builds have no profile key. Test/development apps must
    // never discover or install production releases, even if moved manually.
    if ((profile && ![profile isEqual:@"production"]) || ![identifier isEqualToString:@"dev.moojicut.native"])
        return @"此测试版本不使用正式更新服务。请从「应用程序」打开 Mooji Cut 检查更新。";
    NSString *path = url.path.stringByStandardizingPath;
    NSString *resolved = url.URLByResolvingSymlinksInPath.path.stringByStandardizingPath;
    NSString *installation = @"/Applications/Mooji Cut.app";
    // Check both paths: an alias elsewhere must not update the production app,
    // and an Applications symlink must not update a development checkout.
    if (!url.isFileURL || ![path isEqualToString:installation] || ![resolved isEqualToString:installation])
        return @"请先退出 Mooji Cut，将应用移至「应用程序」文件夹（/Applications/Mooji Cut.app），再从那里重新打开并检查更新。请勿使用指向开发目录的替身或符号链接。";
    return nil;
}
- (NSString *)installationError {
    return [self.class installationErrorForBundleURL:self.bundle.bundleURL
        profile:[self.bundle objectForInfoDictionaryKey:@"MoojiCutBuildProfile"] identifier:self.bundle.bundleIdentifier];
}
- (BOOL)mayStartForBundle {
    return [self.bundle.bundleURL isEqual:NSBundle.mainBundle.bundleURL] && !self.installationError;
}
- (BOOL)startSparkle:(NSError **)error {
    self.controller = [[SPUStandardUpdaterController alloc] initWithStartingUpdater:NO updaterDelegate:self userDriverDelegate:nil];
    if (![self.controller.updater startUpdater:error]) return NO;
    for (NSString *key in MCUpdateObservedKeys())
        [self.controller.updater addObserver:self forKeyPath:key options:0 context:MCUpdateObservationContext];
    self.observing = YES;
    return YES;
}
- (void)start {
    if (self.started) return;
    self.started = YES;
    NSString *errorMessage = [self.class configurationErrorForBundle:self.bundle];
    if (!errorMessage && !self.mayStartForBundle)
        errorMessage = self.installationError ?: @"仅可更新当前应用。";
    if (errorMessage) { self.message = errorMessage; [self notifyState]; return; }
    NSError *error = nil;
    if (![self startSparkle:&error]) {
        self.message = [@"更新服务无法启动：" stringByAppendingString:error.localizedDescription ?: @"请重新下载应用。"];
        [self notifyState]; return;
    }
    self.available = YES;
    [self notifyState];
}
- (void)checkForUpdates:(id)sender {
    (void)sender;
    if (!self.started) [self start];
    if (!self.canCheckForUpdates) { [self notifyState]; return; }
    // Sparkle may allow this action solely to focus its already-open window.
    // Do not start another discovery request in that case.
    if (self.updaterSessionInProgress) { [self performUpdateCheckInBackground:NO]; return; }
    [self beginReleaseLookupInBackground:NO];
}
- (void)performUpdateCheckInBackground:(BOOL)background {
    if (background) [self.controller.updater checkForUpdatesInBackground];
    else [self.controller checkForUpdates:nil];
}
- (NSString *)feedURLStringForUpdater:(__unused SPUUpdater *)updater {
    // The bundle URL only permits Sparkle initialization. mayPerform gates all
    // downloads until a fresh GitHub response selects a signed release feed.
    return self.resolvedFeedURL ?: [self.bundle objectForInfoDictionaryKey:@"SUFeedURL"];
}
- (void)cancelCheck {
    self.sourceGeneration++;
    self.checkingSource = NO; self.pendingResolvedCheck = 0; self.backgroundLookup = NO;
    self.sourceApproved = NO; self.automaticCycleFinished = NO;
    [self.releaseSource cancel];
    self.message = @"更新检查已取消。";
    [self notifyState];
}
- (void)openReleasePage:(__unused id)sender {
    if (self.releasePageURL) [NSWorkspace.sharedWorkspace openURL:self.releasePageURL];
}
- (void)beginReleaseLookupInBackground:(BOOL)background {
    if (self.checkingSource || self.pendingResolvedCheck || self.installationPending) return;
    self.checkingSource = YES; self.backgroundLookup = background;
    self.sourceApproved = NO; self.resolvedFeedURL = nil; self.releasePageURL = nil;
    self.message = @"正在从 GitHub 检查更新…";
    NSUInteger generation = ++self.sourceGeneration;
    [self notifyState];
    if (self.sourceGeneration != generation || !self.checkingSource) return;
    __weak MCUpdateController *weakSelf = self;
    [self.releaseSource fetchReleases:^(NSData *data, NSError *error) {
        // Injected transports may complete on arbitrary queues; the MoonBit
        // handle table and every Sparkle/AppKit call stay on the main thread.
        dispatch_async(dispatch_get_main_queue(), ^{
            MCUpdateController *owner = weakSelf;
            if (!owner || owner.sourceGeneration != generation || !owner.checkingSource) return;
            owner.checkingSource = NO;
            if (error) {
                owner.message = error.code == NSURLErrorTimedOut && [error.domain isEqual:NSURLErrorDomain] ?
                    @"更新检查超时，请检查网络后重试。" : [@"无法检查更新：" stringByAppendingString:error.localizedDescription];
                owner.backgroundLookup = NO; [owner notifyState]; return;
            }
            NSString *body = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
            NSString *version = [owner.bundle objectForInfoDictionaryKey:@"MoojiCutReleaseVersion"];
            int32_t handle = 0;
            if (body && version && data.length <= 4 * 1024 * 1024) {
                moonbit_string_t current = MCReleaseString(version), response = MCReleaseString(body);
                handle = update_release_create(current, MC_UPDATE_MACOS_ARM64, response);
                moonbit_decref(current); moonbit_decref(response);
            }
            if (!handle) {
                owner.message = @"更新信息无效，请稍后重试。"; owner.backgroundLookup = NO;
                [owner notifyState]; return;
            }
            int32_t status = update_release_status(handle);
            NSString *latest = MCReleaseText(handle, MC_UPDATE_VERSION);
            NSString *feed = MCReleaseText(handle, MC_UPDATE_FEED_URL);
            NSString *page = MCReleaseText(handle, MC_UPDATE_RELEASE_URL);
            update_release_dispose(handle);
            owner.releasePageURL = page.length ? [NSURL URLWithString:page] : nil;
            if (status == MC_UPDATE_INVALID) {
                owner.message = @"更新信息无效，请稍后重试。"; owner.backgroundLookup = NO;
            } else if (status == MC_UPDATE_CURRENT) {
                owner.message = @"当前已是最新版本。"; owner.backgroundLookup = NO;
            } else if (status == MC_UPDATE_INCOMPLETE) {
                owner.message = [NSString stringWithFormat:@"发现 %@，但 macOS 安装包尚未准备好。可打开发布页面查看。", latest];
                owner.backgroundLookup = NO;
            } else if (status != MC_UPDATE_AVAILABLE || !feed.length) {
                owner.message = [NSString stringWithFormat:@"发现 %@，但此版本尚未提供签名更新源。请从发布页面下载安装。", latest];
                owner.backgroundLookup = NO;
            } else {
                owner.resolvedFeedURL = feed;
                owner.pendingResolvedCheck = background ? 2 : 1;
                owner.message = @"已找到更新，正在验证签名更新源…";
                [owner resumeResolvedCheckIfPossible];
            }
            [owner notifyState];
        });
    }];
}
- (void)resumeResolvedCheckIfPossible {
    if (!self.pendingResolvedCheck || self.busy || self.installationPending || self.updaterSessionInProgress) return;
    BOOL background = self.pendingResolvedCheck == 2;
    if (background && !self.automaticCycleFinished) return;
    if (background && !self.automaticallyChecksForUpdates) {
        self.pendingResolvedCheck = 0; self.backgroundLookup = NO; return;
    }
    self.pendingResolvedCheck = 0; self.backgroundLookup = NO; self.sourceApproved = YES;
    self.message = @"正在验证签名更新源…";
    [self performUpdateCheckInBackground:background];
}
- (BOOL)validateMenuItem:(NSMenuItem *)item {
    return item.action != @selector(checkForUpdates:) || self.canCheckForUpdates;
}
- (void)operationStateDidChange {
    if (self.pendingInstallation && !self.busy) {
        void (^install)(void) = self.pendingInstallation;
        self.pendingInstallation = nil;
        self.message = @"正在安装更新…";
        [self notifyState];
        install();
    } else { [self resumeResolvedCheckIfPossible]; [self notifyState]; }
}
- (void)updaterStateDidChange {
    [self notifyState];
    // Sparkle briefly marks its scheduler's asynchronous installer probe as a
    // session too. A release response can arrive during that probe, after the
    // preceding cycle has already finished. Resume when the probe becomes idle,
    // on the next run-loop turn rather than inside Sparkle's KVO setter.
    __weak MCUpdateController *weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        [weakSelf resumeResolvedCheckIfPossible];
        [weakSelf notifyState];
    });
}
- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    if (context == MCUpdateObservationContext) [self updaterStateDidChange];
    else [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
}
- (BOOL)updaterShouldPromptForPermissionToCheckForUpdates:(__unused SPUUpdater *)updater { return NO; }
- (BOOL)updater:(__unused SPUUpdater *)updater mayPerformUpdateCheck:(__unused SPUUpdateCheck)check error:(NSError **)error {
    if (self.busy) {
        if (error) *error = [NSError errorWithDomain:MCUpdateErrorDomain code:1 userInfo:@{NSLocalizedDescriptionKey:@"请先完成当前截图或录屏编辑，再检查更新。"}];
        [self notifyState]; return NO;
    }
    if (!updater || self.sourceApproved) return YES;
    // Sparkle's scheduler is synchronous; asynchronously resolve the feed, let
    // this cycle end, then resume exactly once. Never fetch the old bundle URL.
    self.automaticCycleFinished = NO;
    if (!self.checkingSource && !self.pendingResolvedCheck) [self beginReleaseLookupInBackground:YES];
    if (error) *error = [NSError errorWithDomain:MCUpdateErrorDomain code:MCUpdateAwaitingSource
        userInfo:@{NSLocalizedDescriptionKey:@"正在读取发布版本。"}];
    return NO;
}
- (BOOL)updater:(SPUUpdater *)updater shouldProceedWithUpdate:(__unused SUAppcastItem *)item updateCheck:(SPUUpdateCheck)check error:(NSError **)error {
    // A capture may have started while the appcast was downloading.
    (void)updater; (void)check;
    if (!self.busy) return YES;
    if (error) *error = [NSError errorWithDomain:MCUpdateErrorDomain code:1
        userInfo:@{NSLocalizedDescriptionKey:@"请先完成当前截图或录屏编辑，再安装更新。"}];
    return NO;
}
- (void)updater:(__unused SPUUpdater *)updater didFindValidUpdate:(__unused SUAppcastItem *)item {
    self.message = @"发现可用更新，请在更新窗口中查看。"; [self notifyState];
}
- (void)userDidCancelDownload:(__unused SPUUpdater *)updater {
    // Sparkle reports download cancellation as a successful (nil-error) end
    // to the cycle, not SUInstallationCanceledError.
    self.message = @"更新下载已取消，可继续使用当前版本。";
    [self notifyState];
}
- (void)updater:(__unused SPUUpdater *)updater userDidMakeChoice:(SPUUserUpdateChoice)choice
    forUpdate:(__unused SUAppcastItem *)item state:(SPUUserUpdateState *)state {
    if (choice == SPUUserUpdateChoiceInstall) return;
    if (choice == SPUUserUpdateChoiceSkip)
        self.message = @"已跳过此版本，仍可手动检查更新。";
    else if (state.stage == SPUUserUpdateStageInstalling)
        self.message = @"更新已准备好，将在退出应用后安装。";
    else self.message = @"暂不更新，可继续使用当前版本。";
    [self notifyState];
}
- (void)updaterDidNotFindUpdate:(__unused SPUUpdater *)updater error:(__unused NSError *)error {
    // A feed may contain a newer release that is incompatible with this OS.
    self.message = @"当前没有可安装的更新。"; [self notifyState];
}
- (void)updater:(__unused SPUUpdater *)updater willInstallUpdate:(__unused SUAppcastItem *)item {
    self.installationPending = YES;
    [self notifyState];
}
- (BOOL)updater:(__unused SPUUpdater *)updater shouldPostponeRelaunchForUpdate:(__unused SUAppcastItem *)item untilInvokingBlock:(void (^)(void))installHandler {
    self.installationPending = YES;
    if (!self.busy) return NO;
    self.pendingInstallation = installHandler;
    [self notifyState]; return YES;
}
- (void)updater:(__unused SPUUpdater *)updater didFinishUpdateCycleForUpdateCheck:(__unused SPUUpdateCheck)check error:(NSError *)error {
    if ([error.domain isEqual:MCUpdateErrorDomain] && error.code == MCUpdateAwaitingSource) {
        self.automaticCycleFinished = YES;
        [self resumeResolvedCheckIfPossible];
        [self notifyState]; return;
    }
    self.sourceApproved = NO;
    if (error) {
        self.installationPending = NO; self.pendingInstallation = nil;
        if ([error.domain isEqualToString:SUSparkleErrorDomain] && error.code == SUNoUpdateError)
            self.message = @"当前没有可安装的更新。";
        else if ([error.domain isEqualToString:SUSparkleErrorDomain] && error.code == SUInstallationCanceledError)
            self.message = @"更新已取消。";
        else self.message = [@"未能完成更新：" stringByAppendingString:error.localizedDescription];
    } else if (!self.installationPending &&
        ([self.message isEqualToString:@"正在验证签名更新源…"] ||
         [self.message isEqualToString:@"发现可用更新，请在更新窗口中查看。"]))
        self.message = @"更新检查已结束，可继续使用当前版本。";
    [self notifyState];
}
- (void)dealloc {
    [_releaseSource cancel];
    if (_observing) for (NSString *key in MCUpdateObservedKeys())
        [_controller.updater removeObserver:self forKeyPath:key context:MCUpdateObservationContext];
}
@end
