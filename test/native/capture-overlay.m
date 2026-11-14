#import <AppKit/AppKit.h>
#import "capture/MCImageEditorController.h"
#include "moonbit.h"
#include <math.h>

// Synthetic images and events only. The window is never shown and the test
// does not ask for screen permission or write the general clipboard.
@interface MCImageCanvas : NSView
@property NSString *selectedID;
@property NSTextView *textView;
- (NSRect)imageFrame;
@end
@interface MCImageEditorController (MCOverlayTest)
@property (readonly) MCImageCanvas *canvas;
@property (readonly) NSView *floatingToolbar;
@property (readonly) BOOL hasCaptureRegion;
- (void)addTextAtPoint:(NSPoint)point;
- (void)pinImage:(id)sender;
@end

#define CHECK(c, message) do { if (!(c)) { fprintf(stderr, "FAIL capture overlay: %s\n", message); passed = NO; } } while (0)

static NSEvent *mouse(MCImageCanvas *canvas, NSEventType type, NSPoint point) {
    NSRect frame = canvas.imageFrame;
    NSPoint local = NSMakePoint(frame.origin.x + point.x * frame.size.width / 800,
                                frame.origin.y + point.y * frame.size.height / 500);
    return [NSEvent mouseEventWithType:type location:[canvas convertPoint:local toView:nil] modifierFlags:0
        timestamp:0 windowNumber:canvas.window.windowNumber context:nil eventNumber:0 clickCount:1 pressure:1];
}
static NSData *fixture(void) {
    NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:800 pixelsHigh:500
        bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:3200 bitsPerPixel:32];
    for (NSInteger y = 0; y < 500; y++) for (NSInteger x = 0; x < 800; x++) {
        unsigned char *p = bitmap.bitmapData + y * bitmap.bytesPerRow + x * 4;
        p[0] = 24 + x * 80 / 800; p[1] = 34 + y * 65 / 500; p[2] = 58 + (x + y) * 80 / 1300; p[3] = 255;
    }
    return [bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
}
static BOOL exercise(CGFloat scale) {
    BOOL passed = YES;
    NSError *error = nil;
    MCImageEditorController *editor = [[MCImageEditorController alloc] initWithPNGData:fixture() error:&error];
    NSBitmapImageRep *baseline = [NSBitmapImageRep imageRepWithData:[editor renderPNGData:&error]];
    CHECK(baseline.pixelsWide == 800 && baseline.pixelsHigh == 500, "rendering a document does not require an open editor window");
    [editor prepareOverlayInFrame:NSMakeRect(-900, 120, 800 * scale, 500 * scale)];
    CHECK(editor.window.styleMask == NSWindowStyleMaskBorderless && editor.window.canBecomeKeyWindow,
          "overlay is borderless but accepts native text input");
    CHECK(!editor.window.visible && NSEqualRects(editor.canvas.imageFrame, editor.canvas.bounds),
          "frozen image fills the selected screen without editor-window margins");
    CHECK(editor.floatingToolbar.hidden, "editing toolbar stays hidden until a region exists");
    CHECK([editor renderPNGData:&error] == nil, "confirming without a region cannot export the whole screen");
    MCImageCanvas *canvas = editor.canvas;
    [canvas mouseDown:mouse(canvas, NSEventTypeLeftMouseDown, NSMakePoint(100, 60))];
    [canvas mouseDragged:mouse(canvas, NSEventTypeLeftMouseDragged, NSMakePoint(500, 360))];
    [canvas mouseUp:mouse(canvas, NSEventTypeLeftMouseUp, NSMakePoint(500, 360))];
    NSDictionary *viewport = editor.document[@"viewport"];
    CHECK(editor.hasCaptureRegion && !editor.floatingToolbar.hidden && [viewport[@"x"] intValue] == 100 &&
          [viewport[@"y"] intValue] == 60 && [viewport[@"width"] intValue] == 400 && [viewport[@"height"] intValue] == 300,
          "selection transitions directly into editing in image-pixel coordinates");
    CHECK([editor.document[@"undo"] count] == 0, "initial selection establishes the editing baseline");
    CHECK(NSContainsRect(editor.window.contentView.bounds, editor.floatingToolbar.frame),
          "floating toolbar stays within its screen");
    [editor addTextAtPoint:NSMakePoint(120, 80)];
    CHECK(canvas.textView != nil && editor.window.attachedSheet == nil, "selection can immediately host inline text");
    [canvas.textView insertText:@"原地编辑 🌙\n第二行" replacementRange:NSMakeRange(NSNotFound, 0)];
    NSString *previewPath = NSProcessInfo.processInfo.environment[@"MOOJICUT_OVERLAY_PREVIEW"];
    if (previewPath.length && scale == 1.5) {
        NSView *content = editor.window.contentView;
        [content layoutSubtreeIfNeeded];
        [content displayIfNeeded];
        NSBitmapImageRep *preview = [content bitmapImageRepForCachingDisplayInRect:content.bounds];
        [content cacheDisplayInRect:content.bounds toBitmapImageRep:preview];
        [[preview representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:previewPath atomically:YES];
    }
    error = nil;
    NSData *result = [editor renderPNGData:&error];
    NSBitmapImageRep *bitmap = [NSBitmapImageRep imageRepWithData:result];
    CHECK(bitmap.pixelsWide == 400 && bitmap.pixelsHigh == 300 && [editor.document[@"annotations"] count] == 1,
          "export commits live text and uses the selected pixel dimensions");
    // An untouched point must come from the same source location, not from a
    // downscaled full-screen image. This catches crop-origin/Retina regressions.
    NSColor *pixel = [[bitmap colorAtX:5 y:290] colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    NSColor *expected = [[baseline colorAtX:105 y:350] colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    CHECK(fabs(pixel.redComponent - expected.redComponent) < .005 && fabs(pixel.greenComponent - expected.greenComponent) < .005,
          "crop translates source coordinates without scaling the entire desktop");
    canvas.selectedID = nil;
    NSUInteger history = [editor.document[@"undo"] count];
    [canvas mouseDown:mouse(canvas, NSEventTypeLeftMouseDown, NSMakePoint(500, 360))];
    [canvas mouseDragged:mouse(canvas, NSEventTypeLeftMouseDragged, NSMakePoint(550, 400))];
    [canvas mouseUp:mouse(canvas, NSEventTypeLeftMouseUp, NSMakePoint(550, 400))];
    CHECK([editor.document[@"viewport"][@"width"] intValue] == 450 && [editor.document[@"viewport"][@"height"] intValue] == 340 &&
          [editor.document[@"undo"] count] == history + 1, "selection resize is one undoable crop operation");
    [editor undo:nil];
    CHECK([editor.document[@"viewport"] isEqual:viewport] && [editor.document[@"annotations"] count] == 1,
          "undoing a selection resize preserves its annotations");
    __block NSData *pinned = nil;
    editor.onPinPNGData = ^BOOL(NSData *data) { pinned = data; return YES; };
    [editor pinImage:nil];
    CHECK(pinned.length > 0 && editor.window == nil, "pin receives the final crop and finishes the capture");
    NSBitmapImageRep *pin = [NSBitmapImageRep imageRepWithData:pinned];
    CHECK(pin.pixelsWide == 400 && pin.pixelsHigh == 300, "pin does not receive the uncropped desktop");
    return passed;
}
int main(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
        moonbit_init();
        BOOL passed = exercise(.5);
        passed = exercise(1.5) && passed;
        puts(passed ? "PASS capture overlay: borderless frozen canvas, direct edit, scaled region handles, exact crop and pin output"
                    : "FAIL capture overlay");
        return passed ? 0 : 1;
    }
}
