#import <AppKit/AppKit.h>
#import "native/macos/plugins/MCUserPluginManager.h"
#import "native/macos/plugins/MCPluginPackageStore.h"
#import "native/macos/plugins/MCPluginWorker.h"
#import "native/macos/plugins/MCPluginResultController.h"
#import "native/macos/preferences/MCToolRegistryStore.h"
#include "moonbit.h"
#include <objc/runtime.h>
#include <sys/stat.h>
#include <signal.h>
#include <unistd.h>
#include <zlib.h>

static void Check(BOOL condition, NSString *message) {
    if (!condition) { fprintf(stderr,"FAIL plugin manager: %s\n",message.UTF8String); exit(1); }
}
static void Wait(BOOL (^condition)(void), NSString *message) {
    NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:20];
    while (!condition() && deadline.timeIntervalSinceNow>0)
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.005]];
    Check(condition(),message);
}
static NSError *Operation(void (^start)(void (^)(NSError *))) {
    __block BOOL done=NO; __block NSError *failure=nil; __block NSUInteger calls=0;
    start(^(NSError *error) { Check(NSThread.isMainThread,@"operation completion uses main queue"); failure=error; calls++; done=YES; });
    Wait(^BOOL { return done; },@"operation timed out"); Check(calls==1,@"operation completes once"); return failure;
}
static void Stop(MCUserPluginManager *manager) {
    __block BOOL done=NO; [manager shutdownWithCompletion:^{done=YES;}]; Wait(^BOOL { return done; },@"shutdown did not drain");
}
static NSDictionary *Tool(MCToolRegistryStore *registry, NSString *identifier) {
    for (NSDictionary *tool in [registry toolsForGroup:@"screenshot"]) if ([tool[@"id"] isEqual:identifier]) return tool;
    return nil;
}
static NSArray *Order(MCToolRegistryStore *registry) { return [[registry toolsForGroup:@"screenshot"] valueForKey:@"id"]; }
static NSDictionary *Invoke(MCUserPluginManager *manager, NSString *tool, NSString *owner) {
    __block BOOL done=NO; __block NSDictionary *result=nil; __block NSError *failure=nil;
    [manager invokeTool:tool owner:owner capture:@{@"width":@320,@"height":@180,@"format":@"png",@"revision":@7}
        isCurrent:^BOOL {return YES;} completion:^(NSDictionary *output,NSError *error) {result=output; failure=error; done=YES;}];
    Wait(^BOOL {return done;},@"real invocation timed out");
    Check(result && !failure,[NSString stringWithFormat:@"real invocation failed: %@",failure]); return result;
}
static void Word(NSMutableData *data,uint16_t value) { uint8_t b[]={(uint8_t)value,(uint8_t)(value>>8)}; [data appendBytes:b length:2]; }
static void DWord(NSMutableData *data,uint32_t value) { Word(data,(uint16_t)value); Word(data,(uint16_t)(value>>16)); }
static NSURL *ZIP(NSURL *directory, NSDictionary *manifest, NSData *wasm, NSData *icon) {
    NSData *json=[NSJSONSerialization dataWithJSONObject:manifest options:NSJSONWritingSortedKeys error:NULL];
    NSArray *names=icon ? @[@"manifest.json",@"plugin.wasm",@"assets/icon.png"] : @[@"manifest.json",@"plugin.wasm"];
    NSArray *payloads=icon ? @[json,wasm,icon] : @[json,wasm];
    NSMutableData *bytes=[NSMutableData data], *central=[NSMutableData data];
    for (NSUInteger index=0;index<names.count;index++) {
        NSData *name=[names[index] dataUsingEncoding:NSUTF8StringEncoding], *payload=payloads[index];
        uint32_t offset=(uint32_t)bytes.length, size=(uint32_t)payload.length, crc=(uint32_t)crc32(0,payload.bytes,size);
        DWord(bytes,0x04034b50); Word(bytes,20); Word(bytes,0); Word(bytes,0); DWord(bytes,0);
        DWord(bytes,crc); DWord(bytes,size); DWord(bytes,size); Word(bytes,(uint16_t)name.length); Word(bytes,0);
        [bytes appendData:name]; [bytes appendData:payload];
        DWord(central,0x02014b50); Word(central,0x0314); Word(central,20); Word(central,0); Word(central,0); DWord(central,0);
        DWord(central,crc); DWord(central,size); DWord(central,size); Word(central,(uint16_t)name.length);
        Word(central,0); Word(central,0); Word(central,0); Word(central,0); DWord(central,(S_IFREG|0644)<<16); DWord(central,offset); [central appendData:name];
    }
    uint32_t offset=(uint32_t)bytes.length; [bytes appendData:central];
    DWord(bytes,0x06054b50); Word(bytes,0); Word(bytes,0); Word(bytes,(uint16_t)names.count); Word(bytes,(uint16_t)names.count);
    DWord(bytes,(uint32_t)central.length); DWord(bytes,offset); Word(bytes,0);
    NSURL *url=[directory URLByAppendingPathComponent:[NSUUID.UUID.UUIDString stringByAppendingString:@".zip"]];
    Check([bytes writeToURL:url options:0 error:NULL],@"write isolated ZIP fixture"); return url;
}
static NSData *Icon(void) {
    NSBitmapImageRep *bitmap=[[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:1 pixelsHigh:1 bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:4 bitsPerPixel:32];
    memset(bitmap.bitmapData,255,4); return [bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
}
// Keep the fixture invisible: real result controllers/windows and their close
// delegates run, but show never activates the app or orders a window onscreen.
static void HiddenShow(__unused id object,__unused SEL selector) {}
static NSArray *Results(MCUserPluginManager *manager) { return [[manager valueForKey:@"results"] copy]; }

int main(int argc,const char **argv) {
    @autoreleasepool {
        if ([[[NSString stringWithUTF8String:argv[0]] lastPathComponent] isEqual:@"plugin-manager-stall"]) {
            // Only cancellation uses this controlled real subprocess. It is not
            // an Extism success fixture; every installation/probe below is real.
            signal(SIGTERM,SIG_IGN); for (;;) pause();
        }
        Check(argc==3,@"usage: plugin-manager-test /absolute/MoojiPluginWorker /absolute/capture-info.zip");
        moonbit_init(); [NSApplication sharedApplication]; [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
        Method show=class_getInstanceMethod(MCPluginResultController.class,@selector(show));
        IMP previousShow=method_setImplementation(show,(IMP)HiddenShow);
        NSFileManager *files=NSFileManager.defaultManager;
        NSURL *scratch=[NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:[@"moojicut-manager-" stringByAppendingString:NSUUID.UUID.UUIDString]]];
        Check([files createDirectoryAtURL:scratch withIntermediateDirectories:YES attributes:nil error:NULL],@"create isolated test directory");
        NSURL *root=[scratch URLByAppendingPathComponent:@"packages"], *helper=[NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[1]]];
        NSURL *example=[NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[2]]];
        NSString *domain=[@"dev.moojicut.plugin-manager-test." stringByAppendingString:NSUUID.UUID.UUIDString];
        NSUserDefaults *defaults=[[NSUserDefaults alloc] initWithSuiteName:domain];
        MCToolRegistryStore *registry=[[MCToolRegistryStore alloc] initWithDefaults:defaults];
        MCPluginPackageStore *packages=[[MCPluginPackageStore alloc] initWithRootURL:root];
        MCUserPluginManager *manager=[[MCUserPluginManager alloc] initWithRegistry:registry packages:packages workerURL:helper];
        NSError *error=nil;
        MCPluginPackageCandidate *sample=[packages prepareZIPAtURL:example error:&error]; Check(sample && !error,@"read actual example ZIP");
        NSDictionary *manifest=[NSJSONSerialization JSONObjectWithData:sample.manifestData options:0 error:NULL];
        NSString *pluginID=manifest[@"pluginId"], *describe=[NSString stringWithFormat:@"user.%@/describe",pluginID], *size=[NSString stringWithFormat:@"user.%@/copy-size",pluginID];
        error=Operation(^(void (^done)(NSError *)) {[manager importZIPAtURL:example completion:done];});
        Check(!error,[NSString stringWithFormat:@"real installation: %@",error]);
        Check(manager.installedPluginIDs.count==1 && Tool(registry,describe) && Tool(registry,size),@"both declared tools publish after actual probes");
        NSDictionary *description=Invoke(manager,describe,@"description"), *dimensions=Invoke(manager,size,@"dimensions");
        Check([description[@"text"] containsString:@"320"] && [dimensions[@"text"] isEqual:@"320 × 180"],@"both actual MoonBit tools return validated text");

        NSWindow *parent=[[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,100,100) styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
        parent.releasedWhenClosed=NO; parent.level=NSScreenSaverWindowLevel;
        [manager presentResult:description toolID:describe owner:@"description" parentWindow:parent];
        [manager presentResult:dimensions toolID:size owner:@"dimensions" parentWindow:nil];
        Check(Results(manager).count==2,@"independent tools own independent result windows");
        MCPluginResultController *child=Results(manager)[0][@"controller"];
        Check(child.window.parentWindow==parent && child.window.level==parent.level && [parent.childWindows containsObject:child.window],@"result follows its editor window level and parent relation");
        NSPasteboard *copyBoard=[NSPasteboard pasteboardWithUniqueName];
        BOOL copied=[child copyToPasteboard:copyBoard];
        NSString *copiedText=[copyBoard stringForType:NSPasteboardTypeString];
        [copyBoard releaseGlobally];
        Check(copied && [copiedText isEqual:description[@"text"]],@"real result window copies exact validated text to an isolated pasteboard");
        [manager presentResult:description toolID:describe owner:@"description" parentWindow:parent];
        Check(Results(manager).count==2,@"one invocation cannot present twice");
        Check([registry setTool:size enabled:NO error:&error],@"disable one tool");
        Check(Results(manager).count==1 && [Results(manager)[0][@"toolId"] isEqual:describe],@"disabling one tool closes only that tool's result even when sibling remains enabled");
        [manager cancelInvocationsForOwner:@"description"];
        Check(Results(manager).count==0 && child.window.parentWindow==nil && parent.childWindows.count==0,@"owner close releases window and child relation"); [parent close];

        Check([registry moveTool:describe inGroup:@"screenshot" beforeTool:@"builtin.image.rectangle" error:&error],@"custom tool reorder succeeds");
        NSArray *order=Order(registry); NSDictionary *preferences=[defaults persistentDomainForName:domain];
        NSDictionary *oldResult=Invoke(manager,describe,@"old-window"), *lateResult=Invoke(manager,describe,@"late-window");
        [manager presentResult:oldResult toolID:describe owner:@"old-window" parentWindow:nil];
        NSMutableDictionary *updated=[manifest mutableCopy]; updated[@"version"]=@"1.1.0"; updated[@"name"]=@"截图信息新版";
        NSURL *upgrade=ZIP(scratch,updated,sample.wasmData,Icon());
        error=Operation(^(void (^done)(NSError *)) {[manager importZIPAtURL:upgrade completion:done];});
        Check(!error && [Order(registry) isEqual:order] && ![Tool(registry,size)[@"enabled"] boolValue],@"successful update preserves ordering and disabled tool preference");
        Check(Results(manager).count==0,@"update closes result windows from old package digest");
        [manager presentResult:lateResult toolID:describe owner:@"late-window" parentWindow:nil];
        Check(Results(manager).count==0,@"late presentation from prior package generation is rejected");
        Check([[manager nameForPlugin:pluginID] isEqual:@"截图信息新版"] && [manager iconForPlugin:pluginID],@"new validated metadata and icon are published");
        preferences=[defaults persistentDomainForName:domain];
        NSURL *catalogURL=[root URLByAppendingPathComponent:@"catalog.json"];
        NSData *catalogBefore=[NSData dataWithContentsOfURL:catalogURL];
        NSDictionary *snapshotBefore=registry.snapshot;

        NSMutableDictionary *badManifest=[updated mutableCopy]; badManifest[@"version"]=@"1.2.0";
        NSMutableArray *badTools=[updated[@"tools"] mutableCopy]; [badTools addObject:@{@"toolId":@"not-implemented",@"title":@"不支持的操作",@"target":@"screenshot",@"action":@"run"}]; badManifest[@"tools"]=badTools;
        NSURL *badTool=ZIP(scratch,badManifest,sample.wasmData,nil);
        error=Operation(^(void (^done)(NSError *)) {[manager importZIPAtURL:badTool completion:done];});
        Check(error && [[NSData dataWithContentsOfURL:catalogURL] isEqual:catalogBefore] && [registry.snapshot isEqual:snapshotBefore],@"every declared tool is probed; failed third tool leaves installed version and layout intact");
        NSURL *badWasm=ZIP(scratch,updated,[NSData dataWithBytes:"bad wasm" length:8],nil);
        error=Operation(^(void (^done)(NSError *)) {[manager importZIPAtURL:badWasm completion:done];});
        Check(error && [[NSData dataWithContentsOfURL:catalogURL] isEqual:catalogBefore],@"invalid Wasm failure preserves previous installation");

        registry.prepareChange=^BOOL(__unused NSDictionary *candidate,__unused NSError **failure) {return NO;};
        error=Operation(^(void (^done)(NSError *)) {[manager importZIPAtURL:upgrade completion:done];});
        Check(error && [[NSData dataWithContentsOfURL:catalogURL] isEqual:catalogBefore],@"preflight NO without NSError is still an import failure");
        error=Operation(^(void (^done)(NSError *)) {[manager uninstallPlugin:pluginID completion:done];});
        Check(error && manager.installedPluginIDs.count==1,@"preflight NO without NSError is still an uninstall failure");
        error=Operation(^(void (^done)(NSError *)) {[manager loadInstalledPluginsWithCompletion:done];});
        Check(error && [registry.snapshot isEqual:snapshotBefore] && [[defaults persistentDomainForName:domain] isEqual:preferences],@"startup preflight veto preserves current runtime and preferences");
        registry.prepareChange=nil;

        // The real worker can finish successfully after the capture revision has
        // changed. Its output must be discarded by the manager, not presented.
        __block BOOL current=YES, lateDone=NO; __block NSDictionary *late=nil; __block NSError *lateError=nil;
        [manager invokeTool:describe owner:@"revision" capture:@{@"width":@1,@"height":@1,@"format":@"png",@"revision":@0}
            isCurrent:^BOOL {return current;} completion:^(NSDictionary *result,NSError *failure) {late=result; lateError=failure; lateDone=YES;}];
        current=NO; Wait(^BOOL {return lateDone;},@"late actual worker output timed out");
        Check(!late && lateError && [[manager valueForKey:@"calls"] count]==0,@"real late success is rejected after capture changes and worker cleanup drains");

        NSURL *stall=[scratch URLByAppendingPathComponent:@"plugin-manager-stall"];
        Check([files linkItemAtPath:[NSString stringWithUTF8String:argv[0]] toPath:stall.path error:NULL],@"create cancellation-only process fixture");
        [manager setValue:stall forKey:@"workerURL"];
        __block BOOL cancelled=NO; __block NSDictionary *cancelResult=nil; __block NSError *cancelError=nil;
        [manager invokeTool:describe owner:@"active-cancel" capture:@{@"width":@1,@"height":@1,@"format":@"png",@"revision":@0}
            isCurrent:^BOOL {return YES;} completion:^(NSDictionary *result,NSError *failure) {cancelResult=result; cancelError=failure; cancelled=YES;}];
        id call=[[manager valueForKey:@"calls"] firstObject]; MCPluginWorker *worker=[call valueForKey:@"worker"];
        Wait(^BOOL {return [[worker valueForKey:@"task"] isRunning];},@"controlled subprocess did not launch");
        Check([registry setTool:describe enabled:NO error:&error],@"disable tool while subprocess is running");
        Check([registry setTool:describe enabled:YES error:&error],@"re-enable request can be saved while old subprocess drains");
        Wait(^BOOL {return cancelled;},@"cancelled subprocess did not drain");
        Check(!cancelResult && cancelError && !worker.running && [[manager valueForKey:@"calls"] count]==0,@"cancelled invocation drains before completing and does not return output");
        [manager setValue:helper forKey:@"workerURL"]; Invoke(manager,describe,@"after-cancel");
        Check([registry setTool:describe enabled:NO error:&error],@"disable every plugin tool before restart");
        Stop(manager);

        // New host objects and the same isolated disk/defaults prove restart.
        MCToolRegistryStore *reopenedRegistry=[[MCToolRegistryStore alloc] initWithDefaults:defaults];
        MCPluginPackageStore *reopenedPackages=[[MCPluginPackageStore alloc] initWithRootURL:root];
        NSURL *missingHelper=[scratch URLByAppendingPathComponent:@"worker-that-does-not-exist"];
        MCUserPluginManager *reopened=[[MCUserPluginManager alloc] initWithRegistry:reopenedRegistry packages:reopenedPackages workerURL:missingHelper];
        __block BOOL publicationSawMetadata=NO; __weak MCUserPluginManager *weakReopened=reopened;
        reopenedRegistry.applyChange=^(__unused NSDictionary *snapshot) {
            publicationSawMetadata=[[weakReopened nameForPlugin:pluginID] isEqual:@"截图信息新版"] && [weakReopened iconForPlugin:pluginID]!=nil;
        };
        preferences=[defaults persistentDomainForName:domain];
        error=Operation(^(void (^done)(NSError *)) {[reopened loadInstalledPluginsWithCompletion:done];});
        Check(!error && publicationSawMetadata && [Order(reopenedRegistry) isEqual:order] &&
            ![Tool(reopenedRegistry,size)[@"enabled"] boolValue] && ![Tool(reopenedRegistry,describe)[@"enabled"] boolValue] &&
            [reopened valueForKey:@"probe"]==nil && [reopened.installedPluginIDs containsObject:pluginID],
            @"disabled package restores with an unavailable worker: startup validates metadata and hashes without executing any tool");
        Check([[defaults persistentDomainForName:domain] isEqual:preferences],@"restart registry publication does not rewrite defaults");
        [reopened setValue:helper forKey:@"workerURL"];
        Check([reopenedRegistry setTool:describe enabled:YES error:&error],@"explicitly enable tool after read-only restart");
        NSDictionary *uninstallResult=Invoke(reopened,describe,@"uninstall-window");
        [reopened presentResult:uninstallResult toolID:describe owner:@"uninstall-window" parentWindow:nil];
        error=Operation(^(void (^done)(NSError *)) {[reopened uninstallPlugin:pluginID completion:done];});
        Check(!error && reopened.installedPluginIDs.count==0 && !Tool(reopenedRegistry,describe) && Results(reopened).count==0,@"uninstall removes tools and result windows together");
        error=Operation(^(void (^done)(NSError *)) {[reopened importZIPAtURL:upgrade completion:done];});
        Check(!error && [Order(reopenedRegistry) isEqual:order] && ![Tool(reopenedRegistry,size)[@"enabled"] boolValue],@"reinstall restores previously retained tool preferences");

        __block BOOL shutdownDone=NO;
        reopenedRegistry.prepareChange=^BOOL(__unused NSDictionary *candidate,__unused NSError **failure) {
            [weakReopened shutdownWithCompletion:^{shutdownDone=YES;}]; return YES;
        };
        catalogBefore=[NSData dataWithContentsOfURL:catalogURL];
        NSMutableDictionary *third=[updated mutableCopy]; third[@"version"]=@"1.3.0";
        NSURL *thirdZIP=ZIP(scratch,third,sample.wasmData,nil);
        error=Operation(^(void (^done)(NSError *)) {[reopened importZIPAtURL:thirdZIP completion:done];});
        Wait(^BOOL {return shutdownDone;},@"reentrant shutdown did not drain import");
        Check(error && [[NSData dataWithContentsOfURL:catalogURL] isEqual:catalogBefore],@"shutdown during editor preflight cancels the final catalog commit");
        reopenedRegistry.prepareChange=nil; reopenedRegistry.applyChange=nil;

        NSString *digest=[packages catalogWithError:NULL][pluginID];
        NSURL *damaged=[[[root URLByAppendingPathComponent:@"packages"] URLByAppendingPathComponent:digest] URLByAppendingPathComponent:@"plugin.wasm"];
        chmod(damaged.fileSystemRepresentation,0644); [[NSData dataWithBytes:"broken" length:6] writeToURL:damaged options:0 error:NULL];
        MCToolRegistryStore *damagedRegistry=[[MCToolRegistryStore alloc] initWithDefaults:defaults];
        MCUserPluginManager *damagedManager=[[MCUserPluginManager alloc] initWithRegistry:damagedRegistry packages:packages workerURL:helper];
        error=Operation(^(void (^done)(NSError *)) {[damagedManager loadInstalledPluginsWithCompletion:done];});
        Check(error && [damagedManager.installedPluginIDs containsObject:pluginID] && !Tool(damagedRegistry,describe) && [[damagedManager nameForPlugin:pluginID] isEqual:pluginID],@"corrupt package remains uninstallable without trusting its manifest or publishing tools");
        error=Operation(^(void (^done)(NSError *)) {[damagedManager uninstallPlugin:pluginID completion:done];});
        Check(!error && [packages catalogWithError:NULL].count==0,@"uninstall repairs a corrupt installed package through catalog identity alone"); Stop(damagedManager);

        NSURL *cancelRoot=[scratch URLByAppendingPathComponent:@"cancel-during-probe"];
        MCPluginPackageStore *cancelPackages=[[MCPluginPackageStore alloc] initWithRootURL:cancelRoot];
        MCToolRegistryStore *cancelRegistry=[[MCToolRegistryStore alloc] initWithDefaults:defaults];
        MCUserPluginManager *cancelManager=[[MCUserPluginManager alloc] initWithRegistry:cancelRegistry packages:cancelPackages workerURL:helper];
        __weak MCUserPluginManager *weakCancelManager=cancelManager;
        __block BOOL stopQueued=NO, probeWasActive=NO, probeShutdownDone=NO;
        id observer=[NSNotificationCenter.defaultCenter addObserverForName:MCUserPluginsDidChangeNotification object:cancelManager queue:nil usingBlock:^(__unused NSNotification *note) {
            if (!stopQueued && [weakCancelManager.statusMessage hasPrefix:@"正在验证"]) {
                stopQueued=YES;
                // Queue before the worker can enqueue its completion. The real
                // worker has been created when this next main-queue turn runs.
                dispatch_async(dispatch_get_main_queue(), ^{
                    probeWasActive=[weakCancelManager valueForKey:@"probe"]!=nil;
                    [weakCancelManager shutdownWithCompletion:^{probeShutdownDone=YES;}];
                });
            }
        }];
        error=Operation(^(void (^done)(NSError *)) {[cancelManager importZIPAtURL:example completion:done];});
        Wait(^BOOL {return probeShutdownDone;},@"shutdown during real probe did not drain");
        Check(error && probeWasActive && !cancelManager.busy && [cancelPackages catalogWithError:NULL].count==0 &&
            ![files fileExistsAtPath:cancelRoot.path],@"shutdown during real worker probe prevents staging and catalog publication");
        [NSNotificationCenter.defaultCenter removeObserver:observer];
        [defaults removePersistentDomainForName:domain]; method_setImplementation(show,previousShow);
        for (NSURL *url in [files enumeratorAtURL:scratch includingPropertiesForKeys:nil options:0 errorHandler:nil]) {
            BOOL directory=NO; [files fileExistsAtPath:url.path isDirectory:&directory]; if (directory) chmod(url.fileSystemRepresentation,0700);
        }
        [files removeItemAtURL:scratch error:NULL];
        puts("plugin manager: real install/probe/invoke/update, disabled no-worker restart without probe or defaults writes, isolated result copy, transactional veto, stale results, hidden windows, corrupt uninstall, and cancellation passed");
        return 0;
    }
}
