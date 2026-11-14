#import "MCUpdateController.h"
#import <Sparkle/Sparkle.h>

NSNotificationName const MCUpdateStateDidChangeNotification = @"MCUpdateStateDidChangeNotification";
static void *MCUpdateObservationContext = &MCUpdateObservationContext;

@interface MCUpdateController () <SPUUpdaterDelegate>
@property NSBundle *bundle;
@property SPUStandardUpdaterController *controller;
@property (nonatomic, readwrite) BOOL available;
@property (nonatomic, readwrite) BOOL installationPending;
@property NSString *message;
@property BOOL started;
@property BOOL observing;
@property (nonatomic, copy) void (^pendingInstallation)(void);
@end

@implementation MCUpdateController
- (instancetype)init { return [self initWithBundle:NSBundle.mainBundle]; }
- (instancetype)initWithBundle:(NSBundle *)bundle {
    if ((self = [super init])) {
        _bundle = bundle;
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
- (BOOL)canCheckForUpdates { return self.available && !self.busy && !self.pendingInstallation && self.controller.updater.canCheckForUpdates; }
- (BOOL)automaticallyChecksForUpdates { return self.available && self.controller.updater.automaticallyChecksForUpdates; }
- (void)setAutomaticallyChecksForUpdates:(BOOL)enabled {
    if (!self.available) return;
    // Sparkle owns and persists this preference. Never reset it during launch.
    self.controller.updater.automaticallyChecksForUpdates = enabled;
    [self notifyState];
}
- (void)start {
    if (self.started) return;
    self.started = YES;
    NSString *errorMessage = [self.class configurationErrorForBundle:self.bundle];
    if (!errorMessage && ![self.bundle.bundleURL isEqual:NSBundle.mainBundle.bundleURL])
        errorMessage = @"仅可更新当前应用。";
    if (errorMessage) { self.message = errorMessage; [self notifyState]; return; }
    self.controller = [[SPUStandardUpdaterController alloc] initWithStartingUpdater:NO updaterDelegate:self userDriverDelegate:nil];
    NSError *error = nil;
    if (![self.controller.updater startUpdater:&error]) {
        self.message = [@"更新服务无法启动：" stringByAppendingString:error.localizedDescription ?: @"请重新下载应用。"];
        [self notifyState]; return;
    }
    self.available = YES;
    for (NSString *key in @[@"canCheckForUpdates", @"automaticallyChecksForUpdates"])
        [self.controller.updater addObserver:self forKeyPath:key options:0 context:MCUpdateObservationContext];
    self.observing = YES;
    [self notifyState];
}
- (void)checkForUpdates:(id)sender {
    if (!self.started) [self start];
    if (!self.canCheckForUpdates) { [self notifyState]; return; }
    self.message = @"正在检查更新…";
    [self notifyState];
    [self.controller checkForUpdates:sender];
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
    } else [self notifyState];
}
- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    if (context == MCUpdateObservationContext) [self notifyState];
    else [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
}
- (BOOL)updaterShouldPromptForPermissionToCheckForUpdates:(__unused SPUUpdater *)updater { return NO; }
- (BOOL)updater:(__unused SPUUpdater *)updater mayPerformUpdateCheck:(__unused SPUUpdateCheck)check error:(NSError **)error {
    if (!self.busy) return YES;
    if (error) *error = [NSError errorWithDomain:@"MoojiCutUpdate" code:1 userInfo:@{NSLocalizedDescriptionKey:@"请先完成当前截图或录屏编辑，再检查更新。"}];
    [self notifyState]; return NO;
}
- (BOOL)updater:(SPUUpdater *)updater shouldProceedWithUpdate:(__unused SUAppcastItem *)item updateCheck:(SPUUpdateCheck)check error:(NSError **)error {
    // A capture may have started while the appcast was downloading.
    return [self updater:updater mayPerformUpdateCheck:check error:error];
}
- (void)updater:(__unused SPUUpdater *)updater didFindValidUpdate:(__unused SUAppcastItem *)item {
    self.message = @"发现可用更新，请在更新窗口中查看。"; [self notifyState];
}
- (void)updaterDidNotFindUpdate:(__unused SPUUpdater *)updater error:(__unused NSError *)error {
    // A feed may contain a newer release that is incompatible with this OS.
    self.message = @"当前没有可安装的更新。"; [self notifyState];
}
- (void)updater:(__unused SPUUpdater *)updater willInstallUpdate:(__unused SUAppcastItem *)item {
    self.installationPending = YES;
}
- (BOOL)updater:(__unused SPUUpdater *)updater shouldPostponeRelaunchForUpdate:(__unused SUAppcastItem *)item untilInvokingBlock:(void (^)(void))installHandler {
    self.installationPending = YES;
    if (!self.busy) return NO;
    self.pendingInstallation = installHandler;
    [self notifyState]; return YES;
}
- (void)updater:(__unused SPUUpdater *)updater didFinishUpdateCycleForUpdateCheck:(__unused SPUUpdateCheck)check error:(NSError *)error {
    if (error) {
        self.installationPending = NO; self.pendingInstallation = nil;
        if ([error.domain isEqualToString:SUSparkleErrorDomain] && error.code == SUNoUpdateError)
            self.message = @"当前没有可安装的更新。";
        else if ([error.domain isEqualToString:SUSparkleErrorDomain] && error.code == SUInstallationCanceledError)
            self.message = @"更新已取消。";
        else self.message = [@"未能完成更新：" stringByAppendingString:error.localizedDescription];
    } else if ([self.message isEqualToString:@"正在检查更新…"]) self.message = @"更新检查已结束。";
    [self notifyState];
}
- (void)dealloc {
    if (_observing) for (NSString *key in @[@"canCheckForUpdates", @"automaticallyChecksForUpdates"])
        [_controller.updater removeObserver:self forKeyPath:key context:MCUpdateObservationContext];
}
@end
