#import <AppKit/AppKit.h>
#import <AVFoundation/AVFoundation.h>
#import "plugins/feature/video_editor/macos/MCVideoMedia.h"
#import "components/shared_canvas/macos/MCSharedCanvas.h"
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import "plugins/feature/recording/macos/MCMacRecordingController.h"
#import "plugins/feature/recording/macos/MCRecordingSelectionView.h"
#import "plugins/feature/video_editor/macos/MCVideoEditor.h"
#include "moonbit.h"
#include <assert.h>

@interface MCVideoEditor (RecordingExperienceFixture)
- (void)exportToURL:(NSURL *)url copyToPasteboard:(BOOL)copy completion:(void (^)(NSURL *, NSError *))completion;
- (void)cancelExportKeepingDraft;
- (void)buildWindow;
- (void)sendUIEvent:(NSDictionary *)event;
- (BOOL)applyCommand:(NSDictionary *)command error:(NSError **)error;
- (BOOL)applyMediaPlan:(NSDictionary *)plan error:(NSError **)error;
- (BOOL)saveDraft:(NSError **)error;
- (void)tick;
- (BOOL)confirmCancelExport;
- (NSURL *)chooseExportDestination;
- (NSString *)defaultExportName;
@end
@interface MCMacRecordingController (RecordingExperienceFixture)
- (BOOL)transition:(NSString *)event;
- (void)countdownTick;
- (BOOL)countingDown;
- (void)beginCaptureWithFilter:(SCContentFilter *)filter;
- (void)openDraft:(NSURL *)directory;
- (void)captureStarted:(SCStream *)stream error:(NSError *)error;
- (void)recordingOutputDidStartRecording:(SCRecordingOutput *)output;
- (void)recordingOutputDidFinishRecording:(SCRecordingOutput *)output;
- (NSURL *)draftsDirectory;
- (MCVideoEditor *)latestRecoverableDraftWithError:(NSError **)error;
- (void)presentEditor:(MCVideoEditor *)editor;
- (void)selectFilter:(SCContentFilter *)filter;
- (SCStreamConfiguration *)streamConfiguration;
- (NSEventModifierFlags)selectionModifierFlags;
- (void)requestSelectionContent:(void (^)(SCShareableContent *, NSError *))completion;
- (NSArray<NSScreen *> *)selectionScreens;
- (void)snapshotDisplay:(SCDisplay *)display completion:(void (^)(NSData *, NSError *))completion;
- (void)showSelectionWithContent:(SCShareableContent *)content;
- (void)presentSelection;
@end
@interface FixtureStream : NSObject
@property NSUInteger stops;
@end
@implementation FixtureStream
- (void)stopCaptureWithCompletionHandler:(void (^)(NSError *))completion { self.stops++; if (completion) completion(nil); }
@end
@interface FixtureOutput : NSObject
@end
@implementation FixtureOutput
- (CMTime)recordedDuration { return CMTimeMake(65,1); }
@end
@interface FixtureRecorder : MCMacRecordingController
@property NSUInteger starts, openedDrafts;
@end
@implementation FixtureRecorder
- (void)beginCaptureWithFilter:(__unused SCContentFilter *)filter { self.starts++; }
- (void)openDraft:(__unused NSURL *)directory { self.openedDrafts++; }
// Keep the lifecycle/plan real, without opening a countdown or capturing screens.
- (void)showCountdown {}
@end
@interface FixtureFilter : NSObject
@end
@implementation FixtureFilter
- (CGRect)contentRect { return CGRectMake(0,0,1920,1080); }
- (float)pointPixelScale { return 2; }
@end
@interface FixtureDraftRecorder : MCMacRecordingController
@property NSURL *fixtureDirectory;
@property MCVideoEditor *presentedEditor;
@property NSUInteger presentations;
@end
@implementation FixtureDraftRecorder
- (NSURL *)draftsDirectory { return self.fixtureDirectory; }
- (void)presentEditor:(MCVideoEditor *)editor { self.presentedEditor = editor; self.presentations++; }
@end
static BOOL Wait(BOOL (^condition)(void), double seconds) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while (!condition() && deadline.timeIntervalSinceNow>0)
        [NSRunLoop.mainRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    return condition();
}
@interface FixtureVideoEditor : MCVideoEditor
@property BOOL rejectNextPlan;
@end
@implementation FixtureVideoEditor
- (NSURL *)chooseExportDestination {
    // Cancel only the OS dialog; all production busy/status logic still runs.
    assert(self.exporting);NSError *error=nil;assert(![self prepareForTermination:&error] && error);
    return nil;
}
- (BOOL)confirmCancelExport {
    // A modal close confirmation can finish the current real encoder.
    assert(Wait(^BOOL {return !self.exporting;},30)); return YES;
}
- (BOOL)applyMediaPlan:(NSDictionary *)plan error:(NSError **)error {
    if (self.rejectNextPlan) { self.rejectNextPlan=NO; return [super applyMediaPlan:@{} error:error]; }
    return [super applyMediaPlan:plan error:error];
}
@end
@interface CancelClosingEditor : MCVideoEditor
@end
@implementation CancelClosingEditor
- (BOOL)confirmCancelExport { return YES; }
@end
static NSDictionary *State(MCVideoEditor *editor) { return [editor valueForKey:@"state"]; }
static MCSharedCanvasView *Canvas(MCVideoEditor *editor) { return [editor valueForKey:@"canvas"]; }
static NSDictionary *Node(MCVideoEditor *editor,NSString *identifier) {
    for(NSDictionary *node in Canvas(editor).frameDescription[@"semantics"])
        if([node[@"id"] isEqual:identifier])return node;
    NSCAssert(NO,@"Missing production semantic %@",identifier);return nil;
}
static void Click(MCVideoEditor *editor,NSString *identifier) {
    NSDictionary *node=Node(editor,identifier); assert([node[@"enabled"] boolValue]);
    double x=[node[@"x"] doubleValue]+[node[@"width"] doubleValue]/2;
    double y=[node[@"y"] doubleValue]+[node[@"height"] doubleValue]/2;
    Canvas(editor).onEvent(@{@"type":@"pointerDown",@"x":@(x),@"y":@(y)});
    Canvas(editor).onEvent(@{@"type":@"pointerUp",@"x":@(x),@"y":@(y)});
}
static void SelectionMouse(MCRecordingSelectionView *view, NSEventType type, NSPoint point) {
    NSEvent *event = [NSEvent mouseEventWithType:type location:[view convertPoint:point toView:nil] modifierFlags:0
        timestamp:0 windowNumber:view.window.windowNumber context:nil eventNumber:1 clickCount:1 pressure:1];
    if (type == NSEventTypeMouseMoved) [view mouseMoved:event];
    else {
        // Include AppKit hit testing while keeping this automated fixture hidden.
        // Real WindowServer/global-hotkey delivery is a separate interactive check.
        static __weak NSView *recipient;
        if (type == NSEventTypeLeftMouseDown) {
            recipient=[view.superview hitTest:[view.superview convertPoint:event.locationInWindow fromView:nil]];
            assert(recipient==view && [recipient acceptsFirstMouse:event]);
            [recipient mouseDown:event];
        } else if (type == NSEventTypeLeftMouseDragged) [recipient mouseDragged:event];
        else { [recipient mouseUp:event]; recipient=nil; }
    }
}
static void SaveView(NSView *view, NSString *name) {
    NSString *directory = NSProcessInfo.processInfo.environment[@"MOOJICUT_RECORDING_PREVIEW_DIR"];
    if (!directory) return;
    [NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:NULL];
    NSBitmapImageRep *bitmap = [view bitmapImageRepForCachingDisplayInRect:view.bounds];
    [view cacheDisplayInRect:view.bounds toBitmapImageRep:bitmap];
    assert([[bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:[directory stringByAppendingPathComponent:name] atomically:YES]);
}
static void CheckSelection(void) {
    MCSelectionWindow *panel = [[MCSelectionWindow alloc] initWithContentRect:NSMakeRect(0,0,800,600) styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
    panel.releasedWhenClosed = NO; [panel configureForScreenFrame:panel.frame];
    assert(panel.opaque && !panel.ignoresMouseEvents && panel.canBecomeKeyWindow);
    MCRecordingSelectionView *view = [[MCRecordingSelectionView alloc] initWithFrame:NSMakeRect(0,0,800,600)]; panel.contentView = view;
    assert([view acceptsFirstMouse:nil]);
    view.windowCandidates = @[@{@"windowID":@42, @"rect":[NSValue valueWithRect:NSMakeRect(80,70,300,220)]},
                             @{@"windowID":@43, @"rect":[NSValue valueWithRect:NSMakeRect(50,50,500,400)]}];
    __block NSUInteger confirms=0, cancels=0; __block NSNumber *windowID=nil; __block NSRect selected; __block BOOL expectedAudio=YES;
    view.onConfirm = ^(NSRect rect, NSNumber *identifier, BOOL audio) { confirms++; selected=rect; windowID=identifier; assert(audio==expectedAudio); };
    view.onCancel = ^{ cancels++; };
    NSEvent *enter = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:0 timestamp:0 windowNumber:panel.windowNumber context:nil characters:@"\r" charactersIgnoringModifiers:@"\r" isARepeat:NO keyCode:36];
    SelectionMouse(view,NSEventTypeMouseMoved,NSMakePoint(120,100));
    SaveView(view,@"recording-hover.png");
    SelectionMouse(view,NSEventTypeLeftMouseDown,NSMakePoint(120,100)); SelectionMouse(view,NSEventTypeLeftMouseUp,NSMakePoint(120,100));
    [view keyDown:enter]; assert(confirms==1 && [windowID isEqual:@42] && NSEqualRects(selected,NSMakeRect(80,70,300,220)));
    expectedAudio=NO; [[view valueForKey:@"audioButton"] performClick:nil];
    [view resetSelection];
    SelectionMouse(view,NSEventTypeLeftMouseDown,NSMakePoint(150,100)); SelectionMouse(view,NSEventTypeLeftMouseDragged,NSMakePoint(650,400)); SelectionMouse(view,NSEventTypeLeftMouseUp,NSMakePoint(650,400));
    [view keyDown:enter]; assert(confirms==2 && !windowID && NSEqualRects(selected,NSMakeRect(150,100,500,300)));
    SaveView(view,@"recording-region.png");
    NSBitmapImageRep *pixels = [view bitmapImageRepForCachingDisplayInRect:view.bounds];
    [view cacheDisplayInRect:view.bounds toBitmapImageRep:pixels];
    assert([pixels colorAtX:200 y:200].alphaComponent==1); // No clear hole inside the selected region.

    // Reuse screenshot resize geometry, then switch back to a window selection.
    SelectionMouse(view,NSEventTypeLeftMouseDown,NSMakePoint(650,250)); SelectionMouse(view,NSEventTypeLeftMouseDragged,NSMakePoint(750,250)); SelectionMouse(view,NSEventTypeLeftMouseUp,NSMakePoint(750,250));
    assert(view.selection.size.width==600 && !view.selectedWindowID);
    [view resetSelection];
    SelectionMouse(view,NSEventTypeLeftMouseDown,NSMakePoint(790,590)); SelectionMouse(view,NSEventTypeLeftMouseUp,NSMakePoint(790,590));
    [view keyDown:enter]; assert(confirms==3 && !windowID && NSEqualRects(selected,view.bounds));
    NSEvent *escape = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:0 timestamp:0 windowNumber:panel.windowNumber context:nil characters:@"\e" charactersIgnoringModifiers:@"\e" isARepeat:NO keyCode:53];
    [view keyDown:escape]; assert(cancels==1);
    MCRecordingCountdownView *countdown = [[MCRecordingCountdownView alloc] initWithFrame:NSMakeRect(0,0,200,212)];
    countdown.onCancel = ^{ cancels++; }; countdown.remaining=2.5;
    [panel setContentSize:countdown.frame.size]; panel.contentView=countdown;
    SaveView(countdown,@"recording-countdown.png"); [countdown keyDown:escape]; assert(cancels==2);
    [(NSButton *)countdown.subviews.firstObject performClick:nil]; assert(cancels==3);
    [panel close];
}
@interface FixtureSelectionScreen : NSObject
@property NSRect frame;
@property NSDictionary *deviceDescription;
@end
@implementation FixtureSelectionScreen
@end
@interface FixtureSelectionDisplay : NSObject
@property CGRect frame;
@property CGDirectDisplayID displayID;
@end
@implementation FixtureSelectionDisplay
@end
@interface FixtureSelectionContent : NSObject
@property NSArray *displays, *windows;
@end
@implementation FixtureSelectionContent
@end
@interface FixtureSelectionRecorder : FixtureRecorder
@property NSEventModifierFlags heldModifiers;
@property NSUInteger contentRequests, presentations;
@property NSArray *fixtureScreens;
@property (copy) void (^contentReply)(SCShareableContent *, NSError *);
@property NSMutableArray *snapshotReplies;
@end
@implementation FixtureSelectionRecorder
- (NSEventModifierFlags)selectionModifierFlags { return self.heldModifiers; }
- (NSArray *)selectionScreens { return self.fixtureScreens; }
- (void)requestSelectionContent:(void (^)(SCShareableContent *, NSError *))completion { self.contentRequests++; self.contentReply=completion; }
- (void)snapshotDisplay:(__unused SCDisplay *)display completion:(void (^)(NSData *, NSError *))completion {
    if (!self.snapshotReplies) self.snapshotReplies=[NSMutableArray array];
    [self.snapshotReplies addObject:[completion copy]];
}
- (void)presentSelection {
    self.presentations++;
    for (NSWindow *window in [self valueForKey:@"selectionPanels"])
        assert(window.opaque && !window.visible && [(MCRecordingSelectionView *)window.contentView backdrop]);
}
@end
static void CheckSelectionEntry(void) {
    FixtureSelectionRecorder *recorder=[FixtureSelectionRecorder new];
    NSMutableArray *screens=[NSMutableArray array],*displays=[NSMutableArray array];
    for (int i=0;i<2;i++) {
        FixtureSelectionScreen *screen=[FixtureSelectionScreen new];
        screen.frame=NSMakeRect(i ? 0 : -320,0,320,240);screen.deviceDescription=@{@"NSScreenNumber":@(900+i)};[screens addObject:screen];
        FixtureSelectionDisplay *display=[FixtureSelectionDisplay new];display.frame=screen.frame;display.displayID=900+i;[displays addObject:display];
    }
    FixtureSelectionContent *content=[FixtureSelectionContent new];content.displays=displays;content.windows=@[];
    recorder.fixtureScreens=screens;
    NSBitmapImageRep *bitmap=[[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:2 pixelsHigh:2 bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:8 bitsPerPixel:32];
    memset(bitmap.bitmapData,255,16);NSData *png=[bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    recorder.heldModifiers=NSEventModifierFlagCommand;[recorder startRecording];assert(recorder.contentRequests==0);
    recorder.heldModifiers=0;assert(Wait(^BOOL{return recorder.contentRequests==1;},1));
    recorder.contentReply((SCShareableContent *)content,nil);
    assert(Wait(^BOOL{return recorder.snapshotReplies.count==2;},1));
    void (^first)(NSData *,NSError *)=recorder.snapshotReplies[0],(^second)(NSData *,NSError *)=recorder.snapshotReplies[1];
    second(png,nil);Wait(^BOOL{return recorder.presentations>0;},0.03);assert(recorder.presentations==0);
    first(png,nil);assert(Wait(^BOOL{return recorder.presentations==1;},1));
    assert([[recorder valueForKey:@"selectionPanels"] count]==2);
    [recorder stopRecording];assert(!recorder.busy && ![recorder valueForKey:@"selectionPanels"]);
    [recorder.snapshotReplies removeAllObjects];[recorder startRecording];assert(recorder.contentRequests==2);
    recorder.contentReply((SCShareableContent *)content,nil);assert(Wait(^BOOL{return recorder.snapshotReplies.count==2;},1));
    first=recorder.snapshotReplies[0];second=recorder.snapshotReplies[1];first(png,nil);
    [recorder stopRecording];second(png,nil);Wait(^BOOL{return recorder.presentations>1;},0.1);
    assert(recorder.presentations==1 && !recorder.busy && ![recorder valueForKey:@"selectionPanels"]);
    recorder.heldModifiers=NSEventModifierFlagCommand;[recorder startRecording];[recorder stopRecording];recorder.heldModifiers=0;
    Wait(^BOOL{return recorder.contentRequests>2;},0.15);assert(recorder.contentRequests==2);
}
static void CheckLifecycle(void) {
    FixtureRecorder *recorder = [FixtureRecorder new];
    assert(!recorder.busy && !recorder.canStop);
    assert([recorder transition:@"start"]);
    NSRect region=NSMakeRect(200,100,320,240);
    [recorder setValue:[NSValue valueWithRect:region] forKey:@"captureRegion"];
    [recorder setValue:@YES forKey:@"captureAudio"];
    [recorder selectFilter:(SCContentFilter *)[FixtureFilter new]];
    assert(recorder.countingDown);
    SCStreamConfiguration *configuration = [recorder streamConfiguration];
    assert(NSEqualRects(configuration.sourceRect,region)); // Points, not Retina pixels.
    assert(configuration.width==640 && configuration.height==480 && configuration.capturesAudio);
    [recorder stopRecording]; assert(!recorder.busy);
    assert([recorder transition:@"start"]);
    [recorder setValue:[NSValue valueWithRect:NSZeroRect] forKey:@"captureRegion"];
    [recorder selectFilter:(SCContentFilter *)[FixtureFilter new]];
    configuration = [recorder streamConfiguration];
    assert(NSIsEmptyRect(configuration.sourceRect) && configuration.width==3840 && configuration.height==2160);
    [recorder stopRecording]; assert(!recorder.busy);
    assert([recorder transition:@"start"] && recorder.busy && recorder.canStop && !recorder.recording);
    assert([recorder transition:@"selected"]);
    [recorder setValue:@(NSProcessInfo.processInfo.systemUptime-1) forKey:@"countdownDeadline"];
    [recorder countdownTick]; // Schedules capture after the countdown disappears.
    [recorder stopRecording];
    Wait(^BOOL { return recorder.starts>0; },0.3);
    assert(recorder.starts==0 && !recorder.busy && !recorder.canStop);

    assert([recorder transition:@"start"] && [recorder transition:@"selected"] && [recorder transition:@"countdown_finished"]);
    FixtureStream *stream = [FixtureStream new]; FixtureOutput *output = [FixtureOutput new];
    [recorder setValue:stream forKey:@"stream"]; [recorder setValue:output forKey:@"output"];
    [recorder stopRecording]; [recorder stopRecording];
    assert(stream.stops==1 && !recorder.recording && recorder.busy && !recorder.canStop);
    [recorder recordingOutputDidStartRecording:(SCRecordingOutput *)output];
    [recorder recordingOutputDidFinishRecording:(SCRecordingOutput *)output];
    assert(Wait(^BOOL { return !recorder.busy; },2));
    assert(!recorder.recording && recorder.openedDrafts==0);
    [recorder captureStarted:(SCStream *)stream error:nil];
    assert(stream.stops==2); // Stop a successful start arriving after cancellation.
    [recorder recordingOutputDidStartRecording:(SCRecordingOutput *)output];
    Wait(^BOOL { return recorder.recording; },0.03);
    assert(!recorder.recording); // A late output cannot resurrect cancelled work.

    assert([recorder transition:@"start"] && [recorder transition:@"selected"] && [recorder transition:@"countdown_finished"]);
    stream = [FixtureStream new]; output = [FixtureOutput new];
    [recorder setValue:stream forKey:@"stream"]; [recorder setValue:output forKey:@"output"];
    [recorder recordingOutputDidStartRecording:(SCRecordingOutput *)output];
    assert(Wait(^BOOL { return recorder.recording; },2));
    assert([recorder.statusText containsString:@"01:05"] && recorder.canStop);
    [recorder stopRecording];
    assert(!recorder.recording && recorder.busy);
    [recorder recordingOutputDidFinishRecording:(SCRecordingOutput *)output];
    assert(Wait(^BOOL { return !recorder.busy; },2));
    assert(recorder.openedDrafts==1 && stream.stops==1);
}
static void CheckDraftRecovery(NSURL *mediaDirectory) {
    NSFileManager *files=NSFileManager.defaultManager;NSError *error=nil;
    NSData *source=[NSData dataWithContentsOfURL:[mediaDirectory URLByAppendingPathComponent:@"source.mp4"]];
    NSData *edits=[NSData dataWithContentsOfURL:[mediaDirectory URLByAppendingPathComponent:@"edit-v2.json"]];
    NSData *legacy=[NSData dataWithContentsOfURL:[mediaDirectory URLByAppendingPathComponent:@"edit.json"]];
    assert(source.length>128 && edits.length && legacy.length);
    NSURL *root=[mediaDirectory URLByAppendingPathComponent:@"recovery" isDirectory:YES];
    assert([files createDirectoryAtURL:root withIntermediateDirectories:YES attributes:nil error:&error]);
    NSArray<NSString *> *names=@[@"oldest-good",@"latest-good",@"invalid-edit",@"incomplete",@"unreadable"];
    NSData *invalid=[@"not a recording" dataUsingEncoding:NSUTF8StringEncoding];
    NSArray<NSData *> *sources=@[source,source,source,[source subdataWithRange:NSMakeRange(0,32)],invalid];
    NSMutableDictionary<NSURL *,NSData *> *originals=[NSMutableDictionary dictionary];
    NSDate *base=[NSDate dateWithTimeIntervalSince1970:1700000000];
    for(NSUInteger i=0;i<names.count;i++) {
        NSURL *draft=[root URLByAppendingPathComponent:names[i] isDirectory:YES];
        assert([files createDirectoryAtURL:draft withIntermediateDirectories:NO attributes:nil error:&error]);
        NSURL *movie=[draft URLByAppendingPathComponent:@"source.mp4"],*edit=[draft URLByAppendingPathComponent:@"edit-v2.json"];
        NSData *saved=i==2 ? invalid:edits;
        assert([sources[i] writeToURL:movie options:0 error:&error]);assert([saved writeToURL:edit options:0 error:&error]);
        // A valid v1 cannot conceal broken v2, and malformed v1 cannot defeat valid v2.
        NSURL *old=[draft URLByAppendingPathComponent:@"edit.json"];
        NSData *oldData=i==2 ? legacy:invalid;assert([oldData writeToURL:old options:0 error:&error]);
        originals[movie]=sources[i];originals[edit]=saved;originals[old]=oldData;
        assert([files setAttributes:@{NSFileModificationDate:[base dateByAddingTimeInterval:i]} ofItemAtPath:draft.path error:&error]);
    }
    FixtureDraftRecorder *recorder=[FixtureDraftRecorder new];recorder.fixtureDirectory=root;
    [recorder resumeLastDraft];assert(recorder.presentations==1 && recorder.presentedEditor);
    assert([[[recorder.presentedEditor valueForKey:@"directory"] lastPathComponent] isEqual:@"latest-good"]);
    assert(![recorder.presentedEditor valueForKey:@"window"] && ![recorder.presentedEditor valueForKey:@"timer"]);
    assert([State(recorder.presentedEditor)[@"document"] isEqual:[NSJSONSerialization JSONObjectWithData:edits options:0 error:&error]]);
    for(NSURL *file in originals)assert([[NSData dataWithContentsOfURL:file] isEqual:originals[file]]);
    NSURL *badRoot=[mediaDirectory URLByAppendingPathComponent:@"only-invalid" isDirectory:YES];
    assert([files createDirectoryAtURL:badRoot withIntermediateDirectories:NO attributes:nil error:&error]);
    for(NSString *name in @[@"invalid-edit",@"incomplete",@"unreadable"])
        assert([files copyItemAtURL:[root URLByAppendingPathComponent:name] toURL:[badRoot URLByAppendingPathComponent:name] error:&error]);
    recorder.fixtureDirectory=badRoot;error=nil;assert(![recorder latestRecoverableDraftWithError:&error] && error && recorder.presentations==1);
    assert([error.localizedDescription containsString:@"保留"]);
    // A present unreadable/dangling v2 must not be interpreted as missing.
    NSURL *broken=[badRoot URLByAppendingPathComponent:@"invalid-edit/edit-v2.json"];
    assert([files removeItemAtURL:broken error:&error]);
    assert([files createSymbolicLinkAtURL:broken withDestinationURL:[badRoot URLByAppendingPathComponent:@"missing.json"] error:&error]);
    error=nil;assert(![[MCVideoEditor alloc] initWithDraftDirectory:broken.URLByDeletingLastPathComponent error:&error] && error);
    assert([files removeItemAtURL:broken error:&error]);assert([files createDirectoryAtURL:broken withIntermediateDirectories:NO attributes:nil error:&error]);
    error=nil;assert(![[MCVideoEditor alloc] initWithDraftDirectory:broken.URLByDeletingLastPathComponent error:&error] && error);
    recorder.fixtureDirectory=[mediaDirectory URLByAppendingPathComponent:@"missing-drafts"];
    error=nil;assert(![recorder latestRecoverableDraftWithError:&error] && error);
}

static void CheckProductionEditor(NSURL *directory) {
    NSFileManager *files=NSFileManager.defaultManager;NSError *error=nil;
    NSURL *sourceURL=[directory URLByAppendingPathComponent:@"source.mp4"],*draftURL=[directory URLByAppendingPathComponent:@"edit-v2.json"];
    NSURL *legacyURL=[directory URLByAppendingPathComponent:@"edit.json"];
    NSData *source=[NSData dataWithContentsOfURL:sourceURL],*legacy=[NSData dataWithContentsOfURL:legacyURL];
    FixtureVideoEditor *editor=[[FixtureVideoEditor alloc] initWithDraftDirectory:directory error:&error];assert(editor);
    [editor buildWindow];NSWindow *window=[editor valueForKey:@"window"];
    assert([window.contentView isKindOfClass:MCSharedCanvasView.class] && !window.visible);
    assert(editor.visibleWindowNumbers.count==0);
    assert(Wait(^BOOL{return [editor valueForKey:@"waveformTask"]==nil;},10));
    NSUInteger collapsedCommands=[Canvas(editor).frameDescription[@"commands"] count];
    Click(editor,@"project-audio-toggle");
    assert([Canvas(editor).frameDescription[@"commands"] count]>collapsedCommands+100);
    SaveView(Canvas(editor),@"audio-waveform");
    Click(editor,@"project-audio-toggle");
    for(NSString *identifier in @[@"play",@"project-split",@"project-mute",@"project-crop",@"export"]) {
        NSDictionary *node=Node(editor,identifier);
        NSRect rect=NSMakeRect([node[@"x"] doubleValue],[node[@"y"] doubleValue],[node[@"width"] doubleValue],[node[@"height"] doubleValue]);
        assert(NSContainsRect(NSInsetRect(window.contentView.bounds,-1,-1),rect));
    }
    // Production input -> MoonBit UI -> revisioned core -> media -> durable v2.
    MCVideoMedia *media=[editor valueForKey:@"media"];
    assert([media.player.currentItem.asset isKindOfClass:AVComposition.class]);
    assert(Wait(^BOOL{return media.player.currentItem.status==AVPlayerItemStatusReadyToPlay;},10));
    Click(editor,@"preview-rate");Click(editor,@"rate-2");assert(media.previewRate==2);
    Click(editor,@"end");assert(Wait(^BOOL{return ![[editor valueForKey:@"pendingSeek"] boolValue];},10));
    assert(media.currentOutputMilliseconds>1900);
    Click(editor,@"start");assert(Wait(^BOOL{return ![[editor valueForKey:@"pendingSeek"] boolValue];},10));
    assert(media.currentOutputMilliseconds<1);
    NSString *exportName = editor.defaultExportName;
    NSRegularExpression *pattern = [NSRegularExpression regularExpressionWithPattern:@"^moojicut_[0-9]{8}_[0-9]{6}\\.mp4$" options:0 error:NULL];
    assert([pattern numberOfMatchesInString:exportName options:0 range:NSMakeRange(0,exportName.length)]==1);
    double originalDuration = media.outputDurationMilliseconds;
    double rulerSpan = [Canvas(editor).frameDescription[@"viewport"][@"spanMs"] doubleValue];
    NSDictionary *right = Node(editor,@"project-trim-end");
    double hx=[right[@"x"] doubleValue]+[right[@"width"] doubleValue]/2, hy=[right[@"y"] doubleValue]+15;
    NSDictionary *left = Node(editor,@"project-trim-start");
    double originalRight = hx;
    double drag = (hx-[left[@"x"] doubleValue]-[left[@"width"] doubleValue]/2)/2;
    for (NSString *type in @[@"pointerDown",@"pointerMove",@"pointerUp"])
        Canvas(editor).onEvent(@{@"type":type,@"x":@([type isEqual:@"pointerDown"] ? hx : hx-drag),@"y":@(hy)});
    assert(media.outputDurationMilliseconds < originalDuration && !editor.exporting);
    assert([Canvas(editor).frameDescription[@"viewport"][@"spanMs"] doubleValue]==rulerSpan);
    assert([[NSData dataWithContentsOfURL:sourceURL] isEqual:source]);
    assert(Wait(^BOOL{return media.player.currentItem.status==AVPlayerItemStatusReadyToPlay && ![[editor valueForKey:@"pendingSeek"] boolValue];},10));
    right=Node(editor,@"project-trim-end"); hx=[right[@"x"] doubleValue]+[right[@"width"] doubleValue]/2;
    for (NSString *type in @[@"pointerDown",@"pointerMove",@"pointerUp"])
        Canvas(editor).onEvent(@{@"type":type,@"x":@([type isEqual:@"pointerDown"] ? hx : originalRight),@"y":@(hy)});
    assert(fabs(media.outputDurationMilliseconds-originalDuration)<1 && !editor.exporting);
    assert([[NSData dataWithContentsOfURL:sourceURL] isEqual:source]);
    NSDictionary *planBefore=State(editor)[@"plan"];
    editor.rejectNextPlan=YES;Click(editor,@"project-mute");
    assert(![[editor valueForKey:@"mediaSynchronized"] boolValue] && !media.playbackRequested);
    assert(![Node(editor,@"play")[@"enabled"] boolValue] && ![Node(editor,@"export")[@"enabled"] boolValue]);
    __block BOOL refused=NO;
    [editor exportToURL:[directory URLByAppendingPathComponent:@"must-not-export.mp4"] copyToPasteboard:NO completion:^(NSURL *url,NSError *problem){refused=YES;assert(!url && problem);}];
    assert(refused && ![files fileExistsAtPath:[directory URLByAppendingPathComponent:@"must-not-export.mp4"].path]);
    Click(editor,@"undo");assert([[editor valueForKey:@"mediaSynchronized"] boolValue]);assert([State(editor)[@"plan"] isEqual:planBefore]);

    // Real filesystem failure after a core commit keeps the authoritative edit
    // in memory; window close, app termination and export all remain retryable.
    NSURL *backup=[directory URLByAppendingPathComponent:@"backup-v2.json"];
    assert([files moveItemAtURL:draftURL toURL:backup error:&error]);
    assert([files createDirectoryAtURL:draftURL withIntermediateDirectories:NO attributes:nil error:&error]);
    assert([[@"do not overwrite" dataUsingEncoding:NSUTF8StringEncoding] writeToURL:[draftURL URLByAppendingPathComponent:@"marker"] options:0 error:&error]);
    NSNumber *revision=State(editor)[@"revision"];Click(editor,@"project-mute");
    assert([State(editor)[@"revision"] integerValue]>revision.integerValue && [[editor valueForKey:@"draftDirty"] boolValue]);
    NSDictionary *unsaved=State(editor)[@"document"];
    // Playback status/rate acknowledgements must not erase the unsaved warning.
    assert(Wait(^BOOL{return media.player.currentItem.status==AVPlayerItemStatusReadyToPlay;},10));
    Click(editor,@"preview-rate");Click(editor,@"rate-1");[editor tick];
    BOOL savedWarning=NO;
    for(NSDictionary *draw in Canvas(editor).frameDescription[@"commands"])
        if([draw[@"type"] isEqual:@"text"] && [draw[@"text"] containsString:@"草稿保存失败"]) savedWarning=YES;
    assert(savedWarning);
    Click(editor,@"export"); // Cancel the save panel without clearing the dirty warning.
    savedWarning=NO;
    for(NSDictionary *draw in Canvas(editor).frameDescription[@"commands"])
        if([draw[@"type"] isEqual:@"text"] && [draw[@"text"] containsString:@"草稿保存失败"]) savedWarning=YES;
    assert(savedWarning && !editor.exporting && [[editor valueForKey:@"draftDirty"] boolValue]);
    assert(![editor windowShouldClose:window]);error=nil;assert(![editor prepareForTermination:&error] && error);
    assert([editor valueForKey:@"window"]==window && [State(editor)[@"document"] isEqual:unsaved]);
    refused=NO;[editor exportToURL:[directory URLByAppendingPathComponent:@"unsaved.mp4"] copyToPasteboard:NO completion:^(NSURL *url,NSError *problem){refused=YES;assert(!url && problem);}];
    assert(refused && !editor.exporting);
    assert([files removeItemAtURL:draftURL error:&error]);assert([files moveItemAtURL:backup toURL:draftURL error:&error]);
    error=nil;assert([editor prepareForTermination:&error] && ![[editor valueForKey:@"draftDirty"] boolValue]);
    MCVideoEditor *reloaded=[[MCVideoEditor alloc] initWithDraftDirectory:directory error:&error];assert(reloaded && [State(reloaded)[@"document"] isEqual:unsaved]);
    Click(editor,@"undo");assert([State(editor)[@"plan"] isEqual:planBefore]);

    NSMutableArray<NSNumber *> *busy=[NSMutableArray array];__weak MCVideoEditor *weak=editor;
    editor.onStateChange=^{[busy addObject:@(weak.exporting)];};
    NSURL *target=[directory URLByAppendingPathComponent:@"saved.mp4"];
    NSData *original=[@"previous file must survive failure/cancellation" dataUsingEncoding:NSUTF8StringEncoding];
    assert([original writeToURL:target options:0 error:&error]);
    __block BOOL done=NO;__block NSError *failure=nil;__block NSUInteger calls=0;
    [editor exportToURL:target copyToPasteboard:NO completion:^(NSURL *url,NSError *problem){calls++;failure=problem;done=YES;assert(url && !problem);}];
    assert(editor.exporting && Wait(^BOOL{return done;},30) && calls==1 && !failure && !editor.exporting);
    assert([busy.firstObject boolValue] && ![busy.lastObject boolValue] && busy.count==2);
    AVURLAsset *saved=[AVURLAsset URLAssetWithURL:target options:@{AVURLAssetPreferPreciseDurationAndTimingKey:@YES}];
    NSUInteger audioCount=0;AVAssetTrack *track=nil;
    for(AVAssetTrack *candidate in saved.tracks){if([candidate.mediaType isEqual:AVMediaTypeVideo])track=candidate;if([candidate.mediaType isEqual:AVMediaTypeAudio])audioCount++;}
    assert(track && fabs(CMTimeGetSeconds(saved.duration)-2)<0.12 && track.naturalSize.width==160 && track.naturalSize.height==100 && audioCount==0);
    NSURL *cancelTarget=[directory URLByAppendingPathComponent:@"cancelled.mp4"];
    assert([original writeToURL:cancelTarget options:0 error:&error]);done=NO;calls=0;
    [editor exportToURL:cancelTarget copyToPasteboard:NO completion:^(NSURL *url,NSError *problem){calls++;failure=problem;done=YES;assert(!url);}];
    [editor cancelExportKeepingDraft];assert(Wait(^BOOL{return done;},30) && calls==1 && failure.code==NSUserCancelledError);
    assert([[NSData dataWithContentsOfURL:cancelTarget] isEqual:original]);
    done=NO;[editor exportToURL:sourceURL copyToPasteboard:NO completion:^(NSURL *url,NSError *problem){assert(!url && problem);done=YES;}];
    assert(done && !editor.exporting);
    done=NO;[editor exportToURL:[directory URLByAppendingPathComponent:@"missing/result.mp4"] copyToPasteboard:NO completion:^(NSURL *url,NSError *problem){assert(!url && problem);done=YES;}];
    assert(Wait(^BOOL{return done;},30) && !editor.exporting);
    done=NO;[editor exportToURL:[directory URLByAppendingPathComponent:@"close-race.mp4"] copyToPasteboard:NO completion:^(NSURL *url,NSError *problem){assert(url && !problem);done=YES;}];
    assert([editor windowShouldClose:window] && done && !editor.exporting);
    done=NO;[editor exportToURL:[directory URLByAppendingPathComponent:@"after-close-race.mp4"] copyToPasteboard:NO completion:^(NSURL *url,NSError *problem){assert(url && !problem);done=YES;}];
    assert(Wait(^BOOL{return done;},30) && [editor valueForKey:@"window"]==window);
    __block NSUInteger closed=0;editor.onClose=^{closed++;};[window close];
    assert(closed==1 && ![editor valueForKey:@"timer"] && [[editor valueForKey:@"ui"] intValue]==-1 && [[editor valueForKey:@"session"] intValue]==-1);
    [editor tick];[editor sendUIEvent:@{@"type":@"activate",@"id":@"play"}];assert(!media.playbackRequested);
    assert([[NSData dataWithContentsOfURL:sourceURL] isEqual:source] && [[NSData dataWithContentsOfURL:legacyURL] isEqual:legacy]);
    CancelClosingEditor *cancelEditor=[[CancelClosingEditor alloc] initWithDraftDirectory:directory error:&error];assert(cancelEditor);[cancelEditor buildWindow];
    NSWindow *cancelWindow=[cancelEditor valueForKey:@"window"];__block NSUInteger cancelClosed=0;cancelEditor.onClose=^{cancelClosed++;};done=NO;
    [cancelEditor exportToURL:cancelTarget copyToPasteboard:NO completion:^(NSURL *url,NSError *problem){assert(!url && problem.code==NSUserCancelledError);done=YES;}];
    assert(![cancelEditor windowShouldClose:cancelWindow]);assert(Wait(^BOOL{return done && cancelClosed==1;},30));
    assert([[NSData dataWithContentsOfURL:cancelTarget] isEqual:original]);
    // Direct window teardown also releases timers/ports and suppresses a late
    // encoder callback, even when an external owner bypasses performClose.
    MCVideoEditor *forced=[[MCVideoEditor alloc] initWithDraftDirectory:directory error:&error];assert(forced);[forced buildWindow];
    MCVideoMedia *forcedMedia=[forced valueForKey:@"media"];__block NSUInteger late=0;
    [forced exportToURL:cancelTarget copyToPasteboard:NO completion:^(__unused NSURL *url,__unused NSError *problem){late++;}];
    [[forced valueForKey:@"window"] close];
    assert(!forced.exporting && ![forced valueForKey:@"timer"]);
    assert(Wait(^BOOL{return !forcedMedia.exporting;},30) && late==0);
    assert([[NSData dataWithContentsOfURL:cancelTarget] isEqual:original]);
    for(NSString *name in [files contentsOfDirectoryAtPath:directory.path error:&error])assert(![name hasPrefix:@".MoojiCut-media-"]);
}
int main(int argc,const char *argv[]) {
    @autoreleasepool {
        assert(argc==2);moonbit_init();[NSApplication sharedApplication];[NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];CheckLifecycle();CheckSelection();CheckSelectionEntry();
        NSURL *directory=[NSURL fileURLWithPath:@(argv[1]) isDirectory:YES];NSError *error=nil;
        if(![MCVideoEditor runSmokeInDirectory:directory error:&error]){NSLog(@"Production media smoke: %@",error);return 1;}
        CheckDraftRecovery(directory);CheckProductionEditor(directory);
        puts("PASS: production shared v2 input/core/media, v1 read-only migration, strict v2 recovery, durable retries/termination refusal, export cancellation and close races; source/legacy retained");
    }
}
