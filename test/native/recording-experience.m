#import <AppKit/AppKit.h>
#import <AVFoundation/AVFoundation.h>
#import <AVKit/AVKit.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import "plugins/feature/recording/macos/MCMacRecordingController.h"
#import "plugins/feature/video_editor/macos/MCVideoEditor.h"
#include "moonbit.h"
#include <assert.h>

@interface MCVideoEditor (RecordingExperienceFixture)
- (void)exportToURL:(NSURL *)url copyToPasteboard:(BOOL)copy completion:(void (^)(NSURL *, NSError *))completion;
- (void)cancelExportKeepingDraft;
- (void)buildWindow;
- (void)toggleAdvanced:(NSButton *)sender;
- (BOOL)confirmCancelExport;
@end
@interface MCMacRecordingController (RecordingExperienceFixture)
- (BOOL)transition:(NSString *)event;
- (void)countdownTick;
- (void)beginCaptureWithFilter:(SCContentFilter *)filter;
- (void)openDraft:(NSURL *)directory;
- (void)captureStarted:(SCStream *)stream error:(NSError *)error;
- (void)recordingOutputDidStartRecording:(SCRecordingOutput *)output;
- (void)recordingOutputDidFinishRecording:(SCRecordingOutput *)output;
- (NSURL *)draftsDirectory;
- (MCVideoEditor *)latestRecoverableDraftWithError:(NSError **)error;
- (void)presentEditor:(MCVideoEditor *)editor;
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
// No picker interaction, windows, permissions or screen capture in this fixture.
- (void)endPicker {}
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
@end
@implementation FixtureVideoEditor
- (BOOL)confirmCancelExport {
    // Model a user leaving the close-confirmation modal open until the real
    // asynchronous encoder completes, then choosing stop-and-close.
    assert(Wait(^BOOL {return !self.exporting;},30)); return YES;
}
@end
static void CheckLifecycle(void) {
    FixtureRecorder *recorder = [FixtureRecorder new];
    assert(!recorder.busy && !recorder.canStop);
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
    NSFileManager *files = NSFileManager.defaultManager; NSError *error = nil;
    NSData *source = [NSData dataWithContentsOfURL:[mediaDirectory URLByAppendingPathComponent:@"source.mp4"]];
    NSData *edits = [NSData dataWithContentsOfURL:[mediaDirectory URLByAppendingPathComponent:@"edit.json"]];
    assert(source.length > 128 && edits.length);
    NSURL *root = [mediaDirectory URLByAppendingPathComponent:@"recovery" isDirectory:YES];
    assert([files createDirectoryAtURL:root withIntermediateDirectories:YES attributes:nil error:&error]);
    NSArray<NSString *> *names = @[@"oldest-good", @"latest-good", @"invalid-edit", @"incomplete", @"unreadable"];
    NSData *invalid = [@"not a recording" dataUsingEncoding:NSUTF8StringEncoding];
    NSArray<NSData *> *sources = @[source, source, source, [source subdataWithRange:NSMakeRange(0, 32)], invalid];
    NSMutableDictionary<NSURL *, NSData *> *originals = [NSMutableDictionary dictionary];
    NSDate *base = [NSDate dateWithTimeIntervalSince1970:1700000000];
    for (NSUInteger i=0; i<names.count; i++) {
        NSURL *draft = [root URLByAppendingPathComponent:names[i] isDirectory:YES];
        assert([files createDirectoryAtURL:draft withIntermediateDirectories:NO attributes:nil error:&error]);
        NSURL *movie = [draft URLByAppendingPathComponent:@"source.mp4"];
        NSURL *edit = [draft URLByAppendingPathComponent:@"edit.json"];
        NSData *saved = i==2 ? invalid : edits;
        assert([sources[i] writeToURL:movie options:0 error:&error]);
        assert([saved writeToURL:edit options:0 error:&error]);
        originals[movie] = sources[i]; originals[edit] = saved;
        assert([files setAttributes:@{NSFileModificationDate:[base dateByAddingTimeInterval:i]}
            ofItemAtPath:draft.path error:&error]);
    }
    FixtureDraftRecorder *recorder = [FixtureDraftRecorder new]; recorder.fixtureDirectory = root;
    [recorder resumeLastDraft];
    assert(recorder.presentations==1 && recorder.presentedEditor);
    assert([[[recorder.presentedEditor valueForKey:@"directory"] lastPathComponent] isEqual:@"latest-good"]);
    assert(![recorder.presentedEditor valueForKey:@"window"]); // Validation never creates windows.
    assert([[[recorder.presentedEditor valueForKey:@"state"] objectForKey:@"document"]
        isEqual:[NSJSONSerialization JSONObjectWithData:edits options:0 error:&error]]);
    for (NSURL *file in originals) assert([[NSData dataWithContentsOfURL:file] isEqual:originals[file]]);

    // Exhausting unreadable candidates produces one final result, with no
    // alerts during traversal and no modification to the retained files.
    NSURL *badRoot = [mediaDirectory URLByAppendingPathComponent:@"only-invalid" isDirectory:YES];
    assert([files createDirectoryAtURL:badRoot withIntermediateDirectories:NO attributes:nil error:&error]);
    assert([files copyItemAtURL:[root URLByAppendingPathComponent:@"incomplete"]
        toURL:[badRoot URLByAppendingPathComponent:@"incomplete"] error:&error]);
    assert([files copyItemAtURL:[root URLByAppendingPathComponent:@"unreadable"]
        toURL:[badRoot URLByAppendingPathComponent:@"unreadable"] error:&error]);
    recorder.fixtureDirectory = badRoot; error = nil;
    assert(![recorder latestRecoverableDraftWithError:&error] && error && recorder.presentations==1);
    assert([error.localizedDescription containsString:@"保留"]);
    assert([[NSData dataWithContentsOfURL:[badRoot URLByAppendingPathComponent:@"unreadable/source.mp4"]] isEqual:invalid]);
    recorder.fixtureDirectory = [mediaDirectory URLByAppendingPathComponent:@"missing-drafts"];
    error = nil; assert(![recorder latestRecoverableDraftWithError:&error] && error);
}
int main(int argc, const char *argv[]) {
    @autoreleasepool {
        assert(argc==2); moonbit_init(); [NSApplication sharedApplication]; [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited]; CheckLifecycle();
        NSURL *directory = [NSURL fileURLWithPath:@(argv[1]) isDirectory:YES]; NSError *error=nil;
        if (![MCVideoEditor runSmokeInDirectory:directory error:&error]) { NSLog(@"Media smoke: %@", error); return 1; }
        CheckDraftRecovery(directory);
        MCVideoEditor *editor = [[FixtureVideoEditor alloc] initWithDraftDirectory:directory error:&error]; assert(editor);
        [editor buildWindow]; // Hidden layout only; never show/register an App.
        NSWindow *window = [editor valueForKey:@"window"];
        NSButton *more = [NSButton new]; more.state=NSControlStateValueOn;
        [editor toggleAdvanced:more]; [window.contentView layoutSubtreeIfNeeded];
        for (NSString *name in @[@"trimStartSlider",@"trimEndSlider",@"confirm",@"cropHeight"]) {
            NSView *control = [editor valueForKey:name];
            NSRect frame=[control convertRect:control.bounds toView:window.contentView];
            assert(NSContainsRect(NSInsetRect(window.contentView.bounds,-1,-1),frame));
        }
        assert(!window.visible);
        NSURL *target = [directory URLByAppendingPathComponent:@"saved.mp4"];
        NSData *original = [@"previous file must survive failure/cancellation" dataUsingEncoding:NSUTF8StringEncoding];
        assert([original writeToURL:target options:0 error:&error]);
        __block BOOL done=NO; __block NSError *failure=nil; __block NSUInteger calls=0;
        [editor exportToURL:target copyToPasteboard:NO completion:^(NSURL *url,NSError *problem){calls++;failure=problem;done=YES;assert(url && !problem);}];
        assert(editor.exporting && Wait(^BOOL {return done;},30) && calls==1 && !failure && !editor.exporting);
        AVURLAsset *asset = [AVURLAsset URLAssetWithURL:target options:@{AVURLAssetPreferPreciseDurationAndTimingKey:@YES}];
        AVAssetTrack *track = nil; NSUInteger audioTracks=0;
        for (AVAssetTrack *candidate in asset.tracks) {
            if ([candidate.mediaType isEqual:AVMediaTypeVideo]) track=candidate;
            if ([candidate.mediaType isEqual:AVMediaTypeAudio]) audioTracks++;
        }
        assert(track && fabs(CMTimeGetSeconds(asset.duration)-2)<0.12 && track.naturalSize.width==160 && track.naturalSize.height==100);
        assert(audioTracks==0);
        assert([NSFileManager.defaultManager fileExistsAtPath:[directory URLByAppendingPathComponent:@"source.mp4"].path]);
        assert([NSFileManager.defaultManager fileExistsAtPath:[directory URLByAppendingPathComponent:@"edit.json"].path]);

        NSURL *cancelTarget=[directory URLByAppendingPathComponent:@"cancelled.mp4"];
        assert([original writeToURL:cancelTarget options:0 error:&error]); done=NO; calls=0;
        [editor exportToURL:cancelTarget copyToPasteboard:NO completion:^(NSURL *url,NSError *problem){calls++;failure=problem;done=YES;assert(!url);}];
        [editor cancelExportKeepingDraft];
        assert(Wait(^BOOL{return done;},30) && calls==1 && failure.code==NSUserCancelledError);
        assert([[NSData dataWithContentsOfURL:cancelTarget] isEqual:original]);
        done=NO;
        [editor exportToURL:[directory URLByAppendingPathComponent:@"source.mp4"] copyToPasteboard:NO completion:^(NSURL *url,NSError *problem){assert(!url && problem);done=YES;}];
        assert(done && !editor.exporting);
        done=NO;
        [editor exportToURL:[directory URLByAppendingPathComponent:@"close-race.mp4"] copyToPasteboard:NO completion:^(NSURL *url,NSError *problem){assert(url && !problem);done=YES;}];
        assert([editor windowShouldClose:window] && done && !editor.exporting);
        // We have not actually closed the fixture window. A later successful
        // export must not inherit a stale pending-close request.
        done=NO;
        [editor exportToURL:[directory URLByAppendingPathComponent:@"after-close-race.mp4"] copyToPasteboard:NO completion:^(NSURL *url,NSError *problem){assert(url && !problem);done=YES;}];
        assert(Wait(^BOOL{return done;},30));
        assert([editor valueForKey:@"window"]==window);
        MCVideoEditor *reopened=[[MCVideoEditor alloc] initWithDraftDirectory:directory error:&error]; assert(reopened);
        NSArray *files=[NSFileManager.defaultManager contentsOfDirectoryAtPath:directory.path error:&error];
        for (NSString *file in files) assert(![file hasPrefix:@".MoojiCut-export-"]);
        puts("PASS: countdown/late callbacks/start cancellation/status; real MP4 trim/crop/audio/readback, atomic save, cancellation, source protection and recovery past invalid newer drafts");
    }
}
