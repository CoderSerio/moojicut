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
@property (readonly) NSSegmentedControl *tools;
@property (readonly) NSStackView *toolbar;
@property (readonly) NSStackView *properties;
@property (readonly) NSStackView *colorGroup;
@property (readonly) NSStackView *fontGroup;
@property (readonly) NSStackView *strokeGroup;
@property (readonly) NSTextField *lineWidth;
@property (readonly) NSStepper *strokeStepper;
@property (readonly) NSColorWell *color;
@property (readonly) NSTextField *fontSize;
@property (readonly) NSStepper *fontStepper;
@property (readonly) NSButton *ocrButton;
@property (readonly) NSButton *translateButton;
- (void)chooseTool:(id)sender;
- (void)styleChanged:(id)sender;
- (void)refresh;
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
    NSRect toolbarFrame = editor.floatingToolbar.frame;
    CHECK(editor.colorGroup.hidden && editor.fontGroup.hidden && editor.strokeGroup.hidden,
          "select without a text object shows no irrelevant properties");
    CHECK(editor.ocrButton.superview == editor.toolbar && editor.translateButton.superview == editor.toolbar &&
          !editor.ocrButton.enabled && !editor.translateButton.enabled &&
          !editor.ocrButton.isAccessibilityEnabled && !editor.translateButton.isAccessibilityEnabled &&
          [editor.ocrButton.toolTip containsString:@"尚未开放"] && [editor.translateButton.toolTip containsString:@"尚未开放"],
          "OCR and translation remain unavailable first-row actions with honest tooltips");
    NSNumber *revision = editor.document[@"revision"];
    [editor.ocrButton performClick:nil];
    [editor.translateButton performClick:nil];
    CHECK([editor.document[@"revision"] isEqual:revision], "disabled future actions never mutate the image");
    CHECK([editor.color isDescendantOf:editor.properties] && [editor.fontSize isDescendantOf:editor.properties] &&
          ![editor.color isDescendantOf:editor.toolbar] && ![editor.fontSize isDescendantOf:editor.toolbar],
          "color and font controls live only in the contextual second row");
    editor.tools.selectedSegment = 1;
    [editor chooseTool:editor.tools];
    CHECK(!editor.colorGroup.hidden && editor.fontGroup.hidden && !editor.strokeGroup.hidden,
          "rectangle exposes color and labelled line width only");
    editor.strokeStepper.doubleValue = 8;
    [editor.strokeStepper sendAction:editor.strokeStepper.action to:editor.strokeStepper.target];
    [canvas mouseDown:mouse(canvas, NSEventTypeLeftMouseDown, NSMakePoint(340, 240))];
    [canvas mouseDragged:mouse(canvas, NSEventTypeLeftMouseDragged, NSMakePoint(420, 290))];
    [canvas mouseUp:mouse(canvas, NSEventTypeLeftMouseUp, NSMakePoint(420, 290))];
    CHECK([editor.document[@"annotations"][0][@"stroke"] intValue] == 8,
          "contextual line width controls the real MoonBit shape annotation");
    [editor undo:nil];
    editor.tools.selectedSegment = 2;
    [editor chooseTool:editor.tools];
    CHECK(!editor.strokeGroup.hidden && editor.fontGroup.hidden, "arrow exposes the same meaningful shape properties");
    editor.tools.selectedSegment = 4;
    [editor chooseTool:editor.tools];
    CHECK(!editor.colorGroup.hidden && editor.fontGroup.hidden && editor.strokeGroup.hidden,
          "filled cover exposes color/opacity without unrelated stroke or font properties");
    editor.tools.selectedSegment = 3;
    [editor chooseTool:editor.tools];
    CHECK(!editor.colorGroup.hidden && !editor.fontGroup.hidden && editor.strokeGroup.hidden &&
          NSEqualRects(toolbarFrame, editor.floatingToolbar.frame),
          "changing tools swaps properties without relocating the floating HUD");
    [editor addTextAtPoint:NSMakePoint(120, 80)];
    CHECK(canvas.textView != nil && editor.window.attachedSheet == nil, "selection can immediately host inline text");
    [canvas.textView setMarkedText:@"yueliang" selectedRange:NSMakeRange(8, 0) replacementRange:NSMakeRange(NSNotFound, 0)];
    NSResponder *textResponder = editor.window.firstResponder;
    editor.tools.selectedSegment = 4;
    [editor chooseTool:editor.tools];
    CHECK(canvas.textView.hasMarkedText && editor.tools.selectedSegment == 3 &&
          editor.window.firstResponder == textResponder && NSEqualRects(toolbarFrame, editor.floatingToolbar.frame),
          "tool switching preserves ongoing IME composition and HUD placement");
    [canvas.textView insertText:@"原地编辑 🌙\n第二行" replacementRange:NSMakeRange(NSNotFound, 0)];
    editor.fontStepper.doubleValue = 32;
    [editor.fontStepper sendAction:editor.fontStepper.action to:editor.fontStepper.target];
    CHECK(editor.fontSize.doubleValue == 32 && [editor.document[@"annotations"] count] == 0,
          "native font stepper updates the text draft without premature document history");
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
    CHECK([editor.document[@"annotations"][0][@"fontSize"] intValue] == 32,
          "second-row font size is committed into the shared text document");
    editor.tools.selectedSegment = 0;
    [editor refresh];
    CHECK(!editor.colorGroup.hidden && !editor.fontGroup.hidden && editor.strokeGroup.hidden,
          "selecting an existing text object retains text properties in the select tool");
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
    NSRect expectedPinFrame = [editor.window convertRectToScreen:[canvas convertRect:
        NSMakeRect(100 * scale, 60 * scale, 400 * scale, 300 * scale) toView:nil]];
    __block NSRect pinnedFrame = NSZeroRect;
    __weak MCImageEditorController *weakEditor = editor;
    editor.onPinPNGData = ^BOOL(NSData *data) { pinned = data; pinnedFrame = weakEditor.pinScreenFrame; return YES; };
    [editor pinImage:nil];
    CHECK(pinned.length > 0 && editor.window == nil, "pin receives the final crop and finishes the capture");
    CHECK(NSEqualRects(expectedPinFrame, pinnedFrame), "pin carries the actual screen selection frame at every backing scale");
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
