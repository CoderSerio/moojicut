// Compile against the complete native host, omitting main.m from the other
// translation units. The include path selects either current or baseline code.
#define main MCTerminationOriginalMain
#include "native/macos/main.m"
#undef main
#import "native/macos/plugins/MCPluginWorker.h"
#include <errno.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <signal.h>
#include <stdatomic.h>
#include <sys/wait.h>

static NSString *FixtureMode, *DefaultsSuite;
static NSURL *FixtureDirectory;
static atomic_int ChildPID;
static BOOL TerminationDelegateReturned;

static void Cleanup(void) {
    if (DefaultsSuite) [[NSUserDefaults standardUserDefaults] removePersistentDomainForName:DefaultsSuite];
    if (FixtureDirectory) [NSFileManager.defaultManager removeItemAtURL:FixtureDirectory error:NULL];
}
static void Check(BOOL condition, NSString *message) {
    if (condition) return;
    fprintf(stderr,"FAIL [%s]: %s\n",FixtureMode.UTF8String ?: "setup",message.UTF8String);
    pid_t pid=atomic_exchange(&ChildPID,0);
    if (pid>0) kill(pid,SIGKILL);
    Cleanup();
    _Exit(1);
}

@interface MCHostCaptureFixture : MCCaptureController
@property BOOL fixtureBusy;
@property NSString *lastNotice;
@end
@implementation MCHostCaptureFixture
- (BOOL)busy { return self.fixtureBusy; }
- (void)showEditingNotice:(NSString *)message { self.lastNotice = message; }
@end

@interface MCHostRecordingFixture : MCMacRecordingController
@property NSUInteger starts, resumes, stops;
@property BOOL fixtureBusy, fixtureCaptureInProgress, fixtureSaveFailure;
@end
@implementation MCHostRecordingFixture
- (BOOL)busy { return self.fixtureBusy; }
- (BOOL)captureInProgress { return self.fixtureCaptureInProgress; }
- (void)startRecording { self.starts++; }
- (void)resumeLastDraft { self.resumes++; }
- (void)stopRecording { self.stops++; }
- (BOOL)prepareForTermination:(NSError **)error {
    if (!self.fixtureSaveFailure) return YES;
    if (error) *error = [NSError errorWithDomain:@"DraftFixture" code:1
        userInfo:@{NSLocalizedDescriptionKey:@"Cannot save the retained editing draft"}];
    return NO;
}
@end

@interface MCHostDraftFailureFixture : MCNativeHost
@property NSError *saveError;
@end
@implementation MCHostDraftFailureFixture
- (void)showVideoDraftSaveError:(NSError *)error { self.saveError = error; }
@end

@interface MCHostStatusItemFixture : NSObject
@property NSMenu *menu;
@property NSStatusBarButton *button;
@end
@implementation MCHostStatusItemFixture
@end

static void CheckRecordingEntryRouting(void) {
    MCNativeHost *host = [MCNativeHost new];
    MCHostCaptureFixture *capture = [MCHostCaptureFixture new];
    MCHostRecordingFixture *recording = [MCHostRecordingFixture new];
    host.captureController = capture; host.recordingController = recording;
    host.recordMenuItem = [[NSMenuItem alloc] initWithTitle:@"录屏" action:NULL keyEquivalent:@""];
    MCHostStatusItemFixture *status = [MCHostStatusItemFixture new];
    status.menu = [NSMenu new]; status.menu.autoenablesItems = NO;
    NSMenuItem *resume = [[NSMenuItem alloc] initWithTitle:@"恢复草稿" action:@selector(resumeRecordingDraft:) keyEquivalent:@""];
    [status.menu addItem:resume]; host.statusItem = (NSStatusItem *)status;
    capture.fixtureBusy = YES;
    [host startRecording:nil]; [host resumeRecordingDraft:nil]; [host updateRecordingState];
    Check(!recording.starts && !recording.resumes && capture.lastNotice.length && !host.recordMenuItem.enabled,
          @"unfinished screenshot must block recording entries, show a notice, and disable the menu");
    [host stopRecording:nil];
    Check(recording.stops == 1, @"stop remains available when a screenshot is open");
    capture.fixtureBusy = NO; host.choosingImage = YES;
    [host startRecording:nil]; [host resumeRecordingDraft:nil];
    Check(!recording.starts && !recording.resumes, @"file picker must not stack recording UI");
    host.choosingImage = NO;
    [host startRecording:nil]; [host resumeRecordingDraft:nil]; [host updateRecordingState];
    Check(recording.starts == 1 && recording.resumes == 1 && host.recordMenuItem.enabled,
          @"recording entries become available after the screenshot finishes");
    recording.fixtureBusy = YES;
    [host updateRecordingState];
    Check(resume.enabled && !host.recordMenuItem.enabled,
          @"a hidden video editor remains reachable through resume after screenshot editing");
    recording.fixtureCaptureInProgress = YES;
    [host updateRecordingState];
    Check(!resume.enabled, @"draft recovery stays disabled during active recording");
    MCHostDraftFailureFixture *quitting = [MCHostDraftFailureFixture new];
    recording.fixtureCaptureInProgress = NO; recording.fixtureSaveFailure = YES;
    quitting.recordingController = recording;
    Check([quitting applicationShouldTerminate:NSApp] == NSTerminateCancel && quitting.saveError != nil,
          @"application quit must preserve an editor whose draft failed to save");
    recording.fixtureSaveFailure = NO;
    Check([quitting applicationShouldTerminate:NSApp] == NSTerminateNow,
          @"successful draft retry allows the normal application shutdown");
}

@interface MCTerminationApplication : NSApplication
@property NSUInteger replyCount;
@end
@implementation MCTerminationApplication
- (void)replyToApplicationShouldTerminate:(BOOL)shouldTerminate {
    Check(NSThread.isMainThread && shouldTerminate,@"termination reply must approve on the main thread");
    Check(TerminationDelegateReturned,@"termination reply must follow the delegate's return");
    Check(++self.replyCount==1,@"termination must be approved exactly once");
    [super replyToApplicationShouldTerminate:shouldTerminate];
}
@end

// Idle exercises the real manager's synchronous drain. For asynchronous cases
// this adapter controls completion timing without initializing editor/UI state.
// The worker case uses the real subprocess transport and cancellation path.
@interface MCTerminationManager : MCUserPluginManager
@property MCPluginWorker *fixtureWorker;
@property NSUInteger shutdownCalls;
@property BOOL completed, workerReaped, terminateReturned;
@property (copy) void (^pendingCompletion)(void);
- (void)finishFixtureShutdown;
@end
@implementation MCTerminationManager
- (void)finishFixtureShutdown {
    Check(NSThread.isMainThread,@"shutdown completion must run on the main thread");
    Check(!self.completed,@"shutdown completion must run exactly once");
    if (![FixtureMode isEqual:@"idle-gcd"])
        Check(self.terminateReturned,@"asynchronous shutdown must complete after the delegate returns");
    self.completed=YES;
    void (^completion)(void)=self.pendingCompletion;
    self.pendingCompletion=nil;
    Check(completion!=nil,@"shutdown must have a pending completion");
    completion();
}
- (void)shutdownWithCompletion:(void (^)(void))completion {
    Check(++self.shutdownCalls==1,@"AppKit must request shutdown once");
    self.pendingCompletion=completion;
    if ([FixtureMode isEqual:@"idle-gcd"]) {
        [super shutdownWithCompletion:^{ [self finishFixtureShutdown]; }];
    } else if ([FixtureMode isEqual:@"async-event"]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,50*NSEC_PER_MSEC),dispatch_get_main_queue(),^{
            [self finishFixtureShutdown];
        });
    } else {
        Check(self.fixtureWorker.running,@"quit must begin with a live worker");
        [self.fixtureWorker cancel];
    }
}
@end

@interface MCTerminationHost : MCNativeHost
@property MCTerminationManager *fixtureManager;
@property NSApplicationTerminateReply fixtureReply;
@property NSUInteger terminationCalls;
@property NSURL *workerExecutable;
@end
@implementation MCTerminationHost
- (void)applicationDidFinishLaunching:(__unused NSNotification *)notification {
    // Intentionally skip normal startup: no capture, clipboard, windows, tray,
    // shortcuts, updates, or access to the user's real preferences/packages.
    if ([FixtureMode isEqual:@"idle-gcd"]) {
        dispatch_async(dispatch_get_main_queue(),^{ [NSApp terminate:nil]; });
        return;
    }
    if ([FixtureMode isEqual:@"worker-event"]) {
        MCPluginWorkerLimits limits=MCPluginWorkerDefaultLimits();
        limits.wallTimeSeconds=6;
        MCTerminationManager *manager=self.fixtureManager;
        manager.fixtureWorker=[MCPluginWorker startWithExecutableURL:self.workerExecutable
            wasmData:[NSData dataWithBytes:"\0asm\1\0\0\0" length:8]
            inputData:[@"{}" dataUsingEncoding:NSUTF8StringEncoding] limits:limits
            completion:^(__unused NSData *output,NSError *error) {
                Check(NSThread.isMainThread,@"worker completion must run on the main thread");
                Check(manager.shutdownCalls==1 && [error.domain isEqual:MCPluginWorkerErrorDomain] &&
                    error.code==MCPluginWorkerCancelled,@"shutdown must cancel the actual worker");
                Check(!manager.fixtureWorker.running,@"worker cleanup must precede shutdown completion");
                pid_t pid=atomic_load(&ChildPID);
                Check(pid>0,@"worker must report readiness before cancellation");
                errno=0;
                Check(kill(pid,0)==-1 && errno==ESRCH,@"worker must no longer exist before app termination");
                int status=0; errno=0;
                Check(waitpid(pid,&status,WNOHANG)==-1 && errno==ECHILD,@"worker must already be reaped");
                atomic_store(&ChildPID,0);
                manager.workerReaped=YES;
                [manager finishFixtureShutdown];
            }];
    }
    // Native event delivery allows AppKit's termination modal loop to service
    // main GCD completions. A GCD-initiated async quit is a separate limitation.
    [NSTimer scheduledTimerWithTimeInterval:0.01 repeats:YES block:^(NSTimer *timer) {
        if ([FixtureMode isEqual:@"worker-event"]) {
            NSString *ready=[NSString stringWithContentsOfURL:[FixtureDirectory URLByAppendingPathComponent:@"ready"]
                encoding:NSUTF8StringEncoding error:NULL];
            pid_t pid=(pid_t)ready.intValue;
            if (pid<=0) return;
            atomic_store(&ChildPID,pid);
            Check(kill(pid,0)==0,@"worker readiness must identify a live child");
        }
        [timer invalidate];
        [NSApp terminate:nil];
    }];
}
- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender {
    Check(++self.terminationCalls==1,@"termination delegate must be called once");
    // This is the production implementation, not a copy of its algorithm.
    self.fixtureReply=[super applicationShouldTerminate:sender];
    self.fixtureManager.terminateReturned=YES;
    TerminationDelegateReturned=YES;
    return self.fixtureReply;
}
- (void)applicationWillTerminate:(__unused NSNotification *)notification {
    MCTerminationManager *manager=self.fixtureManager;
    Check(manager.shutdownCalls==1 && manager.completed,@"AppKit must wait for shutdown completion");
    BOOL idle=[FixtureMode isEqual:@"idle-gcd"];
    Check(self.fixtureReply==(idle ? NSTerminateNow : NSTerminateLater),@"delegate returned the wrong termination policy");
    // AppKit may internally reply even for NSTerminateNow. Deferred shutdown
    // must reply exactly once; immediate shutdown allows either AppKit path.
    NSUInteger replies=((MCTerminationApplication *)NSApp).replyCount;
    Check(idle ? replies<=1 : replies==1,@"deferred shutdown must receive exactly one AppKit reply");
    if ([FixtureMode isEqual:@"worker-event"])
        Check(manager.workerReaped && !manager.fixtureWorker.running,@"app must not exit before worker cleanup");
    Check(NSApp.windows.count==0,@"termination fixture must not create windows");
    Cleanup();
    printf("App termination [%s]: passed.\n",FixtureMode.UTF8String);
    fflush(stdout);
    // NSApplication terminates directly; code after run is not an exit hook.
    exit(0);
}
@end

int main(int argc,const char **argv) {
    @autoreleasepool {
        NSString *executable=[NSString stringWithUTF8String:argv[0]];
        if ([executable.lastPathComponent isEqual:@"termination-worker-stall"]) {
            signal(SIGTERM,SIG_IGN);
            alarm(10); // Bound the stub's lifetime even if its parent crashes.
            NSString *ready=[executable.stringByDeletingLastPathComponent stringByAppendingPathComponent:@"ready"];
            Check([[NSString stringWithFormat:@"%d",getpid()] writeToFile:ready atomically:YES
                encoding:NSUTF8StringEncoding error:NULL],@"write worker readiness");
            for (;;) pause();
        }
        Check(argc==2,@"usage: app-termination-test idle-gcd|async-event|worker-event");
        FixtureMode=[NSString stringWithUTF8String:argv[1]];
        Check([@[@"idle-gcd",@"async-event",@"worker-event"] containsObject:FixtureMode],@"unknown fixture mode");
        FixtureDirectory=[NSURL fileURLWithPath:[NSTemporaryDirectory()
            stringByAppendingPathComponent:[@"moojicut-termination-" stringByAppendingString:NSUUID.UUID.UUIDString]] isDirectory:YES];
        Check([NSFileManager.defaultManager createDirectoryAtURL:FixtureDirectory withIntermediateDirectories:YES
            attributes:nil error:NULL],@"create isolated fixture directory");
        DefaultsSuite=[@"dev.moojicut.termination-test." stringByAppendingString:NSUUID.UUID.UUIDString];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,8*NSEC_PER_SEC),dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
            @autoreleasepool { Check(NO,@"AppKit termination hung (8 second watchdog)"); }
        });
        moonbit_init();
        MCTerminationApplication *application=[MCTerminationApplication sharedApplication];
        [application setActivationPolicy:NSApplicationActivationPolicyProhibited];
        CheckRecordingEntryRouting();
        MCTerminationHost *host=[MCTerminationHost new];
        NSUserDefaults *defaults=[[NSUserDefaults alloc] initWithSuiteName:DefaultsSuite];
        MCToolRegistryStore *registry=[[MCToolRegistryStore alloc] initWithDefaults:defaults];
        MCPluginPackageStore *packages=[[MCPluginPackageStore alloc] initWithRootURL:FixtureDirectory];
        host.workerExecutable=[FixtureDirectory URLByAppendingPathComponent:@"termination-worker-stall"];
        if ([FixtureMode isEqual:@"worker-event"]) {
            char path[PATH_MAX]; uint32_t size=sizeof(path);
            Check(_NSGetExecutablePath(path,&size)==0,@"locate fixture executable");
            Check([NSFileManager.defaultManager linkItemAtPath:[NSString stringWithUTF8String:path]
                toPath:host.workerExecutable.path error:NULL],@"create worker stub hardlink");
        }
        host.fixtureManager=[[MCTerminationManager alloc] initWithRegistry:registry packages:packages workerURL:host.workerExecutable];
        host.userPlugins=host.fixtureManager;
        application.delegate=host;
        [application run];
        Check(NO,@"NSApplication run returned without applicationWillTerminate");
    }
    return 1;
}
