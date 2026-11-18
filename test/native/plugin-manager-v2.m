#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#import "native/macos/plugins/MCUserPluginManager.h"
#import "native/macos/plugins/MCPluginResultController.h"
#import "native/macos/preferences/MCToolRegistryStore.h"
#import "plugins/feature/capture/macos/MCCaptureController.h"
#import "plugins/feature/image_editor/macos/MCImageEditorController.h"
#import "capture-toolbar-fixture.h"
#include "bindings/c/image_session.h"
#include "bindings/c/capture_toolbar.h"
#include <signal.h>
#include <sys/stat.h>
#include <unistd.h>

@interface MCImageCanvas : NSView
@property (readonly) NSRect imageFrame;
@property (readonly) BOOL dragging;
- (void)cancelGesture;
@end
@interface MCImageEditorController (MCPluginManagerFixture)
@property (readonly) MCImageCanvas *canvas;
@property (readonly) MCSharedCanvasView *toolbar;
@property (readonly) int32_t imageSession;
@property (readonly) int32_t toolbarHandle;
@end

static void Check(BOOL valid,NSString *message) {
    if (!valid) { fprintf(stderr,"FAIL macOS v2 plugins: %s\n",message.UTF8String); exit(1); }
}
static void Wait(BOOL (^condition)(void),NSString *message) {
    NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:20];
    while (!condition() && deadline.timeIntervalSinceNow>0)
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.005]];
    Check(condition(),message);
}
static NSError *Operation(void (^start)(void (^)(NSError *))) {
    __block BOOL done=NO; __block NSError *failure=nil; __block NSUInteger calls=0;
    start(^(NSError *error) { Check(NSThread.isMainThread,@"completion uses the main thread"); failure=error; calls++; done=YES; });
    Wait(^BOOL { return done; },@"operation timed out"); Check(calls==1,@"operation completes exactly once"); return failure;
}
static void Stop(MCUserPluginManager *manager) {
    __block BOOL stopped=NO; [manager shutdownWithCompletion:^{ stopped=YES; }];
    Wait(^BOOL { return stopped; },@"worker drain before shutdown completion"); Check(!manager.busy,@"closed manager is idle");
}
static NSDictionary *Tool(MCToolRegistryStore *registry,NSString *identifier) {
    for (NSDictionary *tool in [registry toolsForGroup:@"screenshot"]) if ([tool[@"id"] isEqual:identifier]) return tool;
    return nil;
}
static NSData *Pixels(void) {
    NSBitmapImageRep *bitmap=[[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:320 pixelsHigh:180 bitsPerSample:8
        samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:1280 bitsPerPixel:32];
    memset(bitmap.bitmapData,255,bitmap.bytesPerRow*bitmap.pixelsHigh);
    return [bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
}
static NSEvent *Mouse(MCImageCanvas *canvas,NSEventType type,NSPoint imagePoint) {
    NSRect frame=canvas.imageFrame;
    NSPoint point=NSMakePoint(frame.origin.x+imagePoint.x*frame.size.width/320,
                             frame.origin.y+imagePoint.y*frame.size.height/180);
    return [NSEvent mouseEventWithType:type location:[canvas convertPoint:point toView:nil] modifierFlags:0 timestamp:0
        windowNumber:canvas.window.windowNumber context:nil eventNumber:0 clickCount:1 pressure:1];
}
static void HiddenShow(__unused id object,__unused SEL selector) {}
static NSArray *Results(MCUserPluginManager *manager) { return [[manager valueForKey:@"results"] copy]; }

int main(int argc,const char **argv) {
    @autoreleasepool {
        if ([[[NSString stringWithUTF8String:argv[0]] lastPathComponent] isEqual:@"manager-v2-stall"]) {
            signal(SIGTERM,SIG_IGN);
            NSString *ready=[[NSString stringWithUTF8String:argv[0]] stringByAppendingString:@".ready"];
            Check([[NSData data] writeToFile:ready atomically:YES],@"stall helper readiness");
            for (;;) pause();
        }
        Check(argc==3,@"usage: plugin-manager-v2 /absolute/helper /absolute/numbered-box.zip");
        moonbit_init(); [NSApplication sharedApplication]; [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
        Method show=class_getInstanceMethod(MCPluginResultController.class,@selector(show));
        IMP original=method_setImplementation(show,(IMP)HiddenShow);
        NSFileManager *files=NSFileManager.defaultManager;
        NSURL *scratch=[NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:
            [@"moojicut-manager-v2-" stringByAppendingString:NSUUID.UUID.UUIDString]] isDirectory:YES];
        Check([files createDirectoryAtURL:scratch withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:NULL],@"private fixture directory");
        NSURL *root=[scratch URLByAppendingPathComponent:@"plugins-v2" isDirectory:YES];
        NSURL *worker=[NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[1]]];
        NSURL *package=[NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[2]]];
        NSURL *index=[root URLByAppendingPathComponent:@"snapshot.bin"];
        NSString *domain=[@"dev.moojicut.plugins-v2-fixture." stringByAppendingString:NSUUID.UUID.UUIDString];
        NSUserDefaults *defaults=[[NSUserDefaults alloc] initWithSuiteName:domain];
        MCToolRegistryStore *registry=[[MCToolRegistryStore alloc] initWithDefaults:defaults];
        NSDictionary *originalDefaults=[defaults persistentDomainForName:domain];
        MCUserPluginManager *manager=[[MCUserPluginManager alloc] initWithRegistry:registry rootURL:root workerURL:worker];
        NSError *error=Operation(^(void (^done)(NSError *)) { [manager loadInstalledPluginsWithCompletion:done]; });
        Check(!error && ![files fileExistsAtPath:index.path],@"missing startup reads only and seeds built-ins");
        error=Operation(^(void (^done)(NSError *)) { [manager importZIPAtURL:package completion:done]; });
        Check(!error,[NSString stringWithFormat:@"real health and atomic installation: %@",error]);
        NSString *plugin=@"com.moojicut.examples.numbered-box", *box=[@"user." stringByAppendingFormat:@"%@/numbered-box",plugin];
        NSString *info=[@"user." stringByAppendingFormat:@"%@/describe",plugin];
        Check(manager.installedPluginIDs.count==1 && Tool(registry,box) && Tool(registry,info),@"verified v2 manifest publishes both declared tools");
        Check([files fileExistsAtPath:index.path] && ![files fileExistsAtPath:[root URLByAppendingPathComponent:@"catalog.json"].path],@"only shared snapshot storage is used");
        NSDictionary *afterDefaults=[defaults persistentDomainForName:domain];
        Check((!originalDefaults && !afterDefaults)||[originalDefaults isEqual:afterDefaults],@"v2 publication never writes a second legacy defaults authority");

        MCImageEditorController *first=[[MCImageEditorController alloc] initWithPNGData:Pixels() error:NULL];
        MCImageEditorController *second=[[MCImageEditorController alloc] initWithPNGData:Pixels() error:NULL];
        [first prepareOverlayInFrame:NSMakeRect(0,0,320,180)]; [second prepareOverlayInFrame:NSMakeRect(0,0,320,180)];
        MCCaptureController *captures=[MCCaptureController new];
        [captures setValue:@[first,second] forKey:@"overlayEditors"];
        __weak MCCaptureController *weakCaptures=captures;
        registry.prepareChange=^BOOL(NSDictionary *candidate,NSError **failure) { return [weakCaptures canApplyToolConfiguration:candidate error:failure]; };
        registry.applyChange=^(NSDictionary *candidate) { [weakCaptures applyToolConfiguration:candidate]; };
        registry.discardChange=^{ [weakCaptures discardToolConfigurationPublication]; };
        NSMapTable<NSNumber *,MCImageEditorController *> *editors=[NSMapTable strongToWeakObjectsMapTable];
        [editors setObject:first forKey:@(first.imageSession)]; [editors setObject:second forKey:@(second.imageSession)];
        manager.windowForCapture=^NSWindow *(int32_t session) { return [editors objectForKey:@(session)].window; };
        __block NSUInteger changed=0;
        manager.documentChanged=^(int32_t session) {
            Check([[editors objectForKey:@(session)] refreshPluginDocumentForSession:session],@"refresh accepted authoritative session"); changed++;
        };
        __weak MCUserPluginManager *weakManager=manager;
        __block NSUInteger dispatches=0;
        __block BOOL lastAccepted=NO;
        captures.onUserToolV2=^BOOL(MCImageEditorController *editor,NSString *tool,NSString *payload,int32_t session) {
            [editors setObject:editor forKey:@(session)];
            dispatches++; lastAccepted=[weakManager invokeTool:tool payload:payload capture:session]; return lastAccepted;
        };
        [captures applyToolConfiguration:registry.snapshot];
        // Overlay mode first needs a real selection, through the existing mouse
        // surface. The plugin gesture below uses that same production surface.
        for (MCImageEditorController *editor in @[first,second]) {
            [editor.canvas mouseDown:Mouse(editor.canvas,NSEventTypeLeftMouseDown,NSMakePoint(1,1))];
            [editor.canvas mouseDragged:Mouse(editor.canvas,NSEventTypeLeftMouseDragged,NSMakePoint(310,170))];
            [editor.canvas mouseUp:Mouse(editor.canvas,NSEventTypeLeftMouseUp,NSMakePoint(310,170))];
        }
        Check(first.pluginCaptureMetadata!=nil && MCToolbarEnabled(first.toolbar,info),@"real selection enables the declared text contribution");
        MCToolbarClick(first.toolbar,info);
        Check(dispatches==1 && lastAccepted,[NSString stringWithFormat:@"actual toolbar dispatch accepted exactly once (%lu/%d): %@",(unsigned long)dispatches,lastAccepted,manager.statusMessage]);
        Wait(^BOOL {return !manager.busy;},@"real text plugin drains");
        Check(Results(manager).count==1,[NSString stringWithFormat:@"accepted text output opens one actual result controller; status=%@, capture=%@",manager.statusMessage,first.pluginCaptureMetadata]);
        MCPluginResultController *result=Results(manager)[0][@"controller"];
        Check(result.window.parentWindow==first.window && result.window.level==first.window.level,@"result follows its screenshot window");
        NSPasteboard *board=[NSPasteboard pasteboardWithUniqueName];
        Check([result copyToPasteboard:board] && [[board stringForType:NSPasteboardTypeString] containsString:@"309"],@"result window copies actual v2 crop facts");
        [board releaseGlobally];
        [manager closeCapture:first.imageSession];
        Check(Results(manager).count==0 && result.window.parentWindow==nil,@"closing capture presentation releases child window");

        MCToolbarClick(first.toolbar,box);
        [first.canvas mouseDown:Mouse(first.canvas,NSEventTypeLeftMouseDown,NSMakePoint(20,20))];
        [first.canvas mouseDragged:Mouse(first.canvas,NSEventTypeLeftMouseDragged,NSMakePoint(150,90))];
        Check(image_session_count(first.imageSession)==0,@"drag preview has no document effects");
        [first.canvas mouseUp:Mouse(first.canvas,NSEventTypeLeftMouseUp,NSMakePoint(150,90))];
        Check(capture_toolbar_value(first.toolbarHandle,MC_CAPTURE_TOOLBAR_EFFECT)==0,@"toolbar dispatch is ACKed before asynchronous worker completion");
        Wait(^BOOL {return !manager.busy;},@"real numbered-box result drains");
        Check(changed==1 && image_session_count(first.imageSession)==2 && [first.document[@"annotations"] count]==2,@"real release applies rectangle and text to the authoritative document");
        [first undo:nil]; Check(image_session_count(first.imageSession)==0,@"one undo removes the complete plugin annotation batch");
        [first redo:nil]; Check(image_session_count(first.imageSession)==2,@"redo restores complete annotation batch");
        MCToolbarClick(first.toolbar,info);
        Check([first applyAnnotation:@{@"id":@"later-edit",@"type":@"rect",@"x":@5,@"y":@5,@"width":@12,@"height":@12,
            @"color":@"#ffffff",@"stroke":@1,@"opacity":@1}],@"edit while an asynchronous invocation is outstanding");
        Wait(^BOOL {return !manager.busy;},@"stale call acknowledges actual worker drain");
        Check(Results(manager).count==0 && image_session_count(first.imageSession)==3,@"late text result is discarded without undoing the newer edit");
        [first undo:nil];

        NSData *before=[NSData dataWithContentsOfURL:index]; NSDictionary *snapshot=registry.snapshot;
        MCToolbarClick(second.toolbar,box);
        [second.canvas mouseDown:Mouse(second.canvas,NSEventTypeLeftMouseDown,NSMakePoint(20,20))];
        [second.canvas mouseDragged:Mouse(second.canvas,NSEventTypeLeftMouseDragged,NSMakePoint(150,90))];
        Check(![registry setTool:box enabled:NO error:&error] && second.canvas.dragging,@"another live capture vetoes configuration without consuming its gesture");
        Check([[NSData dataWithContentsOfURL:index] isEqual:before] && [registry.snapshot isEqual:snapshot],@"multi-capture veto leaves durable and live registry unchanged");
        [second.canvas cancelGesture];
        Check([registry setTool:box enabled:NO error:&error],@"disable through shared transaction");
        Check(!MCToolbarEnabled(first.toolbar,box) && !MCToolbarEnabled(second.toolbar,box),@"both live editors publish the same disabled snapshot");
        Check(![manager invokeTool:box payload:@"{}" capture:first.imageSession],@"disabled contribution cannot invoke directly");
        Check([registry setTool:box enabled:YES error:&error] && [registry moveTool:box inGroup:@"screenshot" beforeTool:@"builtin.image.rectangle" error:&error],@"reenable and reorder through the same durable index");
        NSArray *order=[[registry toolsForGroup:@"screenshot"] valueForKey:@"id"];
        before=[NSData dataWithContentsOfURL:index];
        NSURL *bad=[scratch URLByAppendingPathComponent:@"bad.zip"];
        Check([[NSData dataWithBytes:"not zip" length:7] writeToURL:bad atomically:NO],@"bad fixture file");
        error=Operation(^(void (^done)(NSError *)) { [manager importZIPAtURL:bad completion:done]; });
        Check(error && [[NSData dataWithContentsOfURL:index] isEqual:before],@"failed ZIP import preserves installed digest and toolbar layout");
        [manager closeCapture:first.imageSession]; [manager closeCapture:second.imageSession];
        Stop(manager);
        [first.window close]; [second.window close];

        MCToolRegistryStore *restored=[[MCToolRegistryStore alloc] initWithDefaults:defaults];
        MCUserPluginManager *reopened=[[MCUserPluginManager alloc] initWithRegistry:restored rootURL:root workerURL:worker];
        error=Operation(^(void (^done)(NSError *)) { [reopened loadInstalledPluginsWithCompletion:done]; });
        Check(!error && [[[restored toolsForGroup:@"screenshot"] valueForKey:@"id"] isEqual:order],@"startup rehash restores the accepted package, order and enabled state");
        Stop(reopened);
        // Startup of an already approved package does not execute health again.
        // This real controlled child deliberately ignores SIGTERM; shutdown must
        // wait for the process adapter's kill/reap/drain, not just a cancel flag.
        NSURL *stall=[scratch URLByAppendingPathComponent:@"manager-v2-stall"];
        Check([files copyItemAtPath:[NSString stringWithUTF8String:argv[0]] toPath:stall.path error:NULL],@"isolated controlled worker executable");
        MCUserPluginManager *draining=[[MCUserPluginManager alloc] initWithRegistry:restored rootURL:root workerURL:stall];
        error=Operation(^(void (^done)(NSError *)) { [draining loadInstalledPluginsWithCompletion:done]; });
        Check(!error && ![files fileExistsAtPath:[stall.path stringByAppendingString:@".ready"]],@"bootstrap rehashes content without invoking the approved package");
        int32_t capture=image_session_create(320,180);
        Check([draining invokeTool:info payload:@"{}" capture:capture],@"start an actual cancellable worker");
        Wait(^BOOL {return [files fileExistsAtPath:[stall.path stringByAppendingString:@".ready"]];},@"child reaches controlled running state");
        Stop(draining); image_session_dispose(capture);
        Check(Results(draining).count==0,@"cancelled worker produces no late presentation");
        reopened=[[MCUserPluginManager alloc] initWithRegistry:restored rootURL:root workerURL:worker];
        error=Operation(^(void (^done)(NSError *)) { [reopened loadInstalledPluginsWithCompletion:done]; });
        Check(!error,@"reopen after a fully drained worker");
        error=Operation(^(void (^done)(NSError *)) { [reopened uninstallPlugin:plugin completion:done]; });
        Check(!error && reopened.installedPluginIDs.count==0 && !Tool(restored,box),@"uninstall removes the active package atomically");
        Stop(reopened);
        // Empty existing indexes must fail closed, rather than become missing.
        Check(chmod(index.fileSystemRepresentation,0600)==0,@"make owned fixture index writable for corruption case");
        Check([[NSData data] writeToURL:index options:0 error:NULL],@"fixture corrupt existing index");
        MCToolRegistryStore *brokenRegistry=[[MCToolRegistryStore alloc] initWithDefaults:defaults];
        MCUserPluginManager *broken=[[MCUserPluginManager alloc] initWithRegistry:brokenRegistry rootURL:root workerURL:worker];
        error=Operation(^(void (^done)(NSError *)) { [broken loadInstalledPluginsWithCompletion:done]; });
        Check(error && ![brokenRegistry setTool:@"builtin.image.arrow" enabled:NO error:&error] && [NSData dataWithContentsOfURL:index].length==0,@"invalid startup never rewrites the index or falls back to a legacy writer");
        Stop(broken);
        [defaults removePersistentDomainForName:domain];
        Check([files removeItemAtURL:scratch error:NULL],@"remove only isolated fixture files");
        method_setImplementation(show,original);
        puts("macOS v2 manager: real install, shared toolbar release, text result, atomic annotations/undo, multi-capture veto, settings, restore and uninstall passed");
    }
    return 0;
}
