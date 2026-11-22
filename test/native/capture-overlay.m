#import <AppKit/AppKit.h>
#import "plugins/feature/image_editor/macos/MCImageEditorController.h"
#include "bindings/c/editor_style.h"
#include "moonbit.h"
#include "bindings/c/tool_registry.h"
#include "bindings/c/capture_edit.h"
#import "components/shared_canvas/macos/MCSharedCanvas.h"
#import "platform/macos/graphics/MCSharedTextInput.h"
#include <math.h>
#import <objc/runtime.h>
#import "capture-toolbar-fixture.h"

// Synthetic images and events only. The window is never shown and the test
// does not ask for screen permission or write the general clipboard.
@interface MCImageCanvas : NSView
@property NSString *selectedID;
@property NSTextView *textView;
@property (readonly) NSRect hoveredWindowRect;
- (NSRect)imageFrame;
- (BOOL)finishTextEditing:(BOOL)commit;
- (NSRect)viewRectForImageRect:(NSRect)rect;
- (NSRect)selectionFrame;
@end
@interface MCImageEditorController (MCOverlayTest)
@property (readonly) MCImageCanvas *canvas;
@property (readonly) NSDictionary<NSString *,MCSharedTextInputView *> *textPropertyInputs;
@property (readonly) MCSharedCanvasView *textPropertiesCanvas;
@property (readonly) int32_t textEdit;
@property (readonly) int32_t imageSession;
- (void)sharedColorChanged:(id)sender;
- (void)syncTextControls;
- (BOOL)finishSharedText:(BOOL)commit;
@property (readonly) NSView *floatingToolbar;
@property (readonly) BOOL hasCaptureRegion;
@property (readonly) MCSharedCanvasView *toolbar;
@property (readonly) NSInteger activeTool;
@property (readonly) NSTextField *propertyStatus;
- (void)refresh;
- (void)addTextAtPoint:(NSPoint)point;
- (void)pinImage:(id)sender;
- (void)prepareWindow;
- (BOOL)setCaptureRegion:(NSRect)rect;
- (void)positionFloatingToolbar;
- (void)showError:(NSError *)error;
@end

static void textNumber(MCImageEditorController *editor, NSString *id, NSString *raw) {
    MCSharedTextInputView *input = editor.textPropertyInputs[id];
    [input selectAll:nil]; [input insertText:raw replacementRange:NSMakeRange(0,input.string.length)];
}
static void textColor(MCImageEditorController *editor, NSColor *color) {
    NSColorPanel *panel = NSColorPanel.sharedColorPanel;
    panel.color = color; [editor sharedColorChanged:panel];
    textNumber(editor,@"style.opacity",[NSString stringWithFormat:@"%.12g",color.alphaComponent*100]);
}
static double propertyValue(MCImageEditorController *editor, int key) {
    return capture_text_value(editor.imageSession,editor.textEdit,key);
}
static BOOL propertyVisible(MCImageEditorController *editor, NSString *identifier) {
    if (editor.textPropertyInputs[identifier]) return YES;
    for (NSDictionary *item in editor.textPropertiesCanvas.frameDescription[@"semantics"])
        if ([item[@"id"] isEqual:identifier]) return YES;
    return NO;
}
#define CHECK(c, message) do { if (!(c)) { fprintf(stderr, "FAIL capture overlay: %s\n", message); passed = NO; } } while (0)

static void selectTool(MCImageEditorController *editor, NSInteger kind) {
    MCToolbarClick(editor.toolbar,MCToolbarToolID(kind));
}

static NSInteger contributionPosition(MCImageEditorController *editor, NSString *identifier) {
    return MCToolbarPosition(editor.toolbar,identifier);
}
static void invokeContribution(MCImageEditorController *editor, NSString *identifier) {
    MCToolbarClick(editor.toolbar,identifier);
}

static NSDictionary *registryConfiguration(NSArray<NSDictionary *> *entries, NSArray *manifests) {
    NSMutableArray *saved=[NSMutableArray array];
    for (NSDictionary *entry in entries) [saved addObject:@{@"id":entry[@"id"],@"enabled":([entry[@"enabled"] boolValue] ? @YES : @NO)}];
    NSDictionary *request=@{@"layout":@{@"version":@1,@"groups":@{@"screenshot":saved}},@"manifests":manifests};
    NSString *json=[[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:request options:0 error:NULL] encoding:NSUTF8StringEncoding];
    moonbit_string_t input=moonbit_make_string_raw((int32_t)json.length); [json getCharacters:input range:NSMakeRange(0,json.length)];
    moonbit_string_t result=tool_registry_resolve(input); moonbit_decref(input);
    NSString *text=[[NSString alloc] initWithCharacters:result length:Moonbit_array_length(result)]; moonbit_decref(result);
    NSDictionary *configuration=[NSJSONSerialization JSONObjectWithData:[text dataUsingEncoding:NSUTF8StringEncoding] options:0 error:NULL];
    NSCAssert([configuration[@"ok"] boolValue],@"Invalid overlay registry fixture: %@",configuration);
    return configuration;
}
static NSDictionary *setConfiguredTool(NSDictionary *configuration, NSString *identifier, BOOL enabled) {
    NSMutableArray *entries=[NSMutableArray array];
    for (NSDictionary *entry in configuration[@"layout"][@"groups"][@"screenshot"])
        [entries addObject:[entry[@"id"] isEqual:identifier] ? @{@"id":identifier,@"enabled":@(enabled)} : entry];
    return registryConfiguration(entries,configuration[@"manifests"] ?: @[]);
}
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
@interface MCSaveTestEditor : MCImageEditorController
@property NSURL *destination;
@property NSError *saveError;
@end
@implementation MCSaveTestEditor
- (void)chooseScreenshotDestination:(void (^)(NSURL *))completion { completion(self.destination); }
- (void)showError:(NSError *)error { self.saveError = error; }
@end

static BOOL saveScreenshot(void) {
    BOOL passed = YES;
    MCSaveTestEditor *editor = [[MCSaveTestEditor alloc] initWithPNGData:fixture() error:NULL];
    [editor prepareOverlayInFrame:NSMakeRect(0, 0, 800, 500)];
    [editor setCaptureRegion:NSMakeRect(30, 40, 220, 130)];
    selectTool(editor, 1);
    [editor.canvas mouseDown:mouse(editor.canvas,NSEventTypeLeftMouseDown,NSMakePoint(50,65))];
    [editor.canvas mouseDragged:mouse(editor.canvas,NSEventTypeLeftMouseDragged,NSMakePoint(95,90))];
    [editor.canvas mouseUp:mouse(editor.canvas,NSEventTypeLeftMouseUp,NSMakePoint(95,90))];
    NSDictionary *document = editor.document;
    CHECK([document[@"annotations"] count] == 1, "local PNG fixture contains an annotation");
    NSData *expected = [editor renderPNGData:NULL];
    invokeContribution(editor, @"host.save");
    CHECK(!editor.saveError && [editor.document isEqual:document], "cancelling local save preserves the edit");
    NSURL *directory = [NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES];
    NSURL *file = [directory URLByAppendingPathComponent:[NSUUID.UUID.UUIDString stringByAppendingPathExtension:@"png"]];
    editor.destination = [file URLByAppendingPathComponent:@"missing.png"];
    invokeContribution(editor, @"host.save");
    CHECK(editor.saveError && [editor.document isEqual:document], "failed write leaves capture available for retry");
    editor.destination = file;
    editor.saveError = nil;
    invokeContribution(editor, @"host.save");
    NSData *saved = [NSData dataWithContentsOfURL:file];
    NSBitmapImageRep *image = saved ? [NSBitmapImageRep imageRepWithData:saved] : nil;
    CHECK(!editor.saveError && [saved isEqual:expected] && image.pixelsWide == 220 && image.pixelsHigh == 130,
          "right-group save exports the cropped annotated PNG through the actual toolbar action");
    [NSFileManager.defaultManager removeItemAtURL:file error:NULL];
    return passed;
}
static BOOL windowSnap(CGFloat scale) {
    BOOL passed = YES;
    MCImageEditorController *editor = [[MCImageEditorController alloc] initWithPNGData:fixture() error:NULL];
    [editor prepareOverlayInFrame:NSMakeRect(-900,120,800*scale,500*scale)];
    NSRect front = NSMakeRect(100*scale,60*scale,360*scale,220*scale);
    NSRect back = NSMakeRect(40*scale,30*scale,600*scale,400*scale);
    [editor setWindowCandidates:@[@{@"windowID":@42,@"rect":[NSValue valueWithRect:front]},
                                   @{@"windowID":@43,@"rect":[NSValue valueWithRect:back]}]];
    MCImageCanvas *canvas = editor.canvas;
    NSPoint inside = NSMakePoint(200,100), outside = NSMakePoint(700,450), drag = NSMakePoint(500,300);
    [canvas mouseMoved:mouse(canvas,NSEventTypeMouseMoved,inside)];
    CHECK(NSEqualRects(canvas.hoveredWindowRect,front) && !editor.hasCaptureRegion && editor.floatingToolbar.hidden,
          "hover previews the frontmost overlapping window before entering editing");
    [canvas mouseDown:mouse(canvas,NSEventTypeLeftMouseDown,outside)];
    [canvas mouseUp:mouse(canvas,NSEventTypeLeftMouseUp,outside)];
    CHECK(NSIsEmptyRect(canvas.hoveredWindowRect) && !editor.hasCaptureRegion,
          "a background click clears the hover and leaves selection open");
    [canvas mouseDown:mouse(canvas,NSEventTypeLeftMouseDown,inside)];
    [canvas mouseDragged:mouse(canvas,NSEventTypeLeftMouseDragged,drag)];
    [canvas mouseDragged:mouse(canvas,NSEventTypeLeftMouseDragged,inside)];
    [canvas mouseUp:mouse(canvas,NSEventTypeLeftMouseUp,inside)];
    CHECK(!editor.hasCaptureRegion, "an intentional drag that returns to its anchor does not select a window");
    [canvas mouseDown:mouse(canvas,NSEventTypeLeftMouseDown,inside)];
    [canvas mouseDragged:mouse(canvas,NSEventTypeLeftMouseDragged,NSMakePoint(201,101))];
    [canvas mouseUp:mouse(canvas,NSEventTypeLeftMouseUp,NSMakePoint(201,101))];
    NSDictionary *viewport = editor.document[@"viewport"];
    NSBitmapImageRep *output = [NSBitmapImageRep imageRepWithData:[editor renderPNGData:NULL]];
    CHECK(editor.hasCaptureRegion && !editor.floatingToolbar.hidden && [editor.document[@"undo"] count] == 0 &&
          [viewport[@"x"] intValue] == 100 && [viewport[@"y"] intValue] == 60 &&
          output.pixelsWide == 360 && output.pixelsHigh == 220,
          "clicking a window with pointer jitter establishes its exact frozen-pixel crop and editing baseline");
    [editor cancel:nil];
    editor = [[MCImageEditorController alloc] initWithPNGData:fixture() error:NULL];
    [editor prepareOverlayInFrame:NSMakeRect(-900,120,800*scale,500*scale)];
    [editor setWindowCandidates:@[@{@"windowID":@42,@"rect":[NSValue valueWithRect:front]}]];
    canvas = editor.canvas;
    [canvas mouseDown:mouse(canvas,NSEventTypeLeftMouseDown,inside)];
    [canvas mouseDragged:mouse(canvas,NSEventTypeLeftMouseDragged,drag)];
    [canvas mouseUp:mouse(canvas,NSEventTypeLeftMouseUp,drag)];
    viewport = editor.document[@"viewport"];
    CHECK(editor.hasCaptureRegion && [viewport[@"x"] intValue] == 200 && [viewport[@"y"] intValue] == 100 &&
          [viewport[@"width"] intValue] == 300 && [viewport[@"height"] intValue] == 200,
          "dragging from within a window overrides snapping with a free crop");
    [editor cancel:nil];
    return passed;
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
    NSRect selectionInRoot = [canvas convertRect:[canvas viewRectForImageRect:NSMakeRect([viewport[@"x"] doubleValue], [viewport[@"y"] doubleValue], [viewport[@"width"] doubleValue], [viewport[@"height"] doubleValue])] toView:editor.window.contentView];
    CHECK(NSMaxX(selectionInRoot) >= NSWidth(editor.floatingToolbar.frame) + 8 ?
          fabs(NSMaxX(editor.floatingToolbar.frame) - NSMaxX(selectionInRoot)) < 1 :
          NSMinX(editor.floatingToolbar.frame) == 8,
          "toolbar aligns to the right edge, or clamps to the display for a narrow scaled crop");
    CHECK(NSMaxY(editor.floatingToolbar.frame) < NSMinY(selectionInRoot) &&
          NSMinY(selectionInRoot) - NSMaxY(editor.floatingToolbar.frame) <= 8,
          "toolbar sits just below the selection when there is space");
    CHECK(NSHeight(editor.floatingToolbar.frame) <= 44,
          "selecting a region does not reserve an empty property row");
    selectTool(editor,1);
    CHECK(NSHeight(editor.floatingToolbar.frame) > 44 && NSHeight(editor.floatingToolbar.frame) <= 84,
          "editable properties expand to a compact second row without reducing hit targets");
    CHECK(NSMaxX(selectionInRoot) >= NSWidth(editor.floatingToolbar.frame) + 8 ?
          fabs(NSMaxX(editor.floatingToolbar.frame) - NSMaxX(selectionInRoot)) < 1 :
          NSMinX(editor.floatingToolbar.frame) == 8,
          "property widths retain the trailing anchor without moving controls offscreen");
    selectTool(editor,0);
    [editor showError:[NSError errorWithDomain:@"test" code:1 userInfo:@{NSLocalizedDescriptionKey:@"An actionable error"}]];
    CHECK(NSHeight(editor.floatingToolbar.frame) > 44 && !editor.propertyStatus.hidden,
          "an error expands a collapsed property row so the message remains visible");
    [editor refresh];
    CHECK(NSHeight(editor.floatingToolbar.frame) <= 44, "clearing the message collapses the unused row again");
    CHECK(editor.textPropertiesCanvas.hidden && editor.textPropertyInputs.count == 0,
          "select without a text object shows no irrelevant properties");
    NSInteger ocr=contributionPosition(editor,@"builtin.capture.ocr"), translate=contributionPosition(editor,@"builtin.capture.translate");
    CHECK(ocr == -1 && translate == -1, "an editor without a text backend hides the text action");
    selectTool(editor, 1);
    CHECK(propertyVisible(editor,@"style.color") && !propertyVisible(editor,@"style.fontSize") && propertyVisible(editor,@"style.stroke"),
          "rectangle exposes color and labelled line width only");
    textNumber(editor,@"style.stroke",@"8");
    CHECK([editor.textPropertyInputs[@"style.stroke"] isDescendantOf:editor.textPropertiesCanvas] &&
          ![editor.textPropertyInputs[@"style.stroke"] isDescendantOf:editor.toolbar],
          "native numeric input lives only in the shared contextual second row");
    [canvas mouseDown:mouse(canvas, NSEventTypeLeftMouseDown, NSMakePoint(340, 240))];
    [canvas mouseDragged:mouse(canvas, NSEventTypeLeftMouseDragged, NSMakePoint(420, 290))];
    [canvas mouseUp:mouse(canvas, NSEventTypeLeftMouseUp, NSMakePoint(420, 290))];
    CHECK([editor.document[@"annotations"][0][@"stroke"] intValue] == 8,
          "contextual line width controls the real MoonBit shape annotation");
    CHECK(MCToolbarEnabled(editor.toolbar,@"host.undo"), "a fresh defaults transaction does not disable document undo after drawing");
    MCToolbarClick(editor.toolbar,@"host.undo");
    CHECK([editor.document[@"annotations"] count] == 0 && MCToolbarEnabled(editor.toolbar,@"host.redo"),
          "the actual toolbar undo removes the shape and enables document redo");
    selectTool(editor, 2);
    CHECK(propertyVisible(editor,@"style.stroke") && !propertyVisible(editor,@"style.fontSize"), "arrow exposes the same meaningful shape properties");
    selectTool(editor, 4);
    CHECK(propertyVisible(editor,@"style.color") && propertyVisible(editor,@"style.opacity") &&
          !propertyVisible(editor,@"style.fontSize") && !propertyVisible(editor,@"style.stroke"),
          "filled cover exposes color/opacity without unrelated stroke or font properties");
    selectTool(editor, 3);
    CHECK(!editor.textPropertiesCanvas.hidden && editor.textPropertyInputs.count == 2 &&
          NSContainsRect(editor.window.contentView.bounds, editor.floatingToolbar.frame),
          "changing tools fits the current properties within the screen");
    NSRect toolbarFrame = editor.floatingToolbar.frame;
    [editor addTextAtPoint:NSMakePoint(120, 80)];
    CHECK(canvas.textView != nil && editor.window.attachedSheet == nil, "selection can immediately host inline text");
    [canvas.textView setMarkedText:@"yueliang" selectedRange:NSMakeRange(8, 0) replacementRange:NSMakeRange(NSNotFound, 0)];
    NSResponder *textResponder = editor.window.firstResponder;
    CHECK([editor capturePNGData:&error] == nil && canvas.textView.hasMarkedText && editor.window.firstResponder == textResponder,
          "content actions reject unfinished IME without accepting or discarding composition");
    selectTool(editor, 4);
    CHECK(canvas.textView.hasMarkedText && editor.activeTool == 3 && MCToolbarSelected(editor.toolbar,@"builtin.image.text") &&
          editor.window.firstResponder == textResponder && NSEqualRects(toolbarFrame, editor.floatingToolbar.frame),
          "tool switching preserves ongoing IME composition and HUD placement");
    [canvas.textView insertText:@"原地编辑 🌙\n第二行" replacementRange:NSMakeRange(NSNotFound, 0)];
    textNumber(editor,@"style.fontSize",@"32");
    CHECK([editor.textPropertyInputs[@"style.fontSize"].string doubleValue] == 32 && [editor.document[@"annotations"] count] == 0,
          "shared font input updates the text draft without premature document history");
    NSBitmapImageRep *snapshot = [NSBitmapImageRep imageRepWithData:[editor capturePNGData:&error]];
    CHECK(snapshot.pixelsWide == 400 && snapshot.pixelsHigh == 300 && canvas.textView != nil &&
          [editor.document[@"annotations"] count] == 0,
          "content snapshot includes the current crop without ending the pending text transaction");
    NSString *previewPath = NSProcessInfo.processInfo.environment[@"MOOJICUT_OVERLAY_PREVIEW"];
    if (previewPath.length && scale == 1.5) {
        NSView *content = editor.window.contentView;
        [content layoutSubtreeIfNeeded];
        [content displayIfNeeded];
        NSBitmapImageRep *preview = [content bitmapImageRepForCachingDisplayInRect:content.bounds];
        [content cacheDisplayInRect:content.bounds toBitmapImageRep:preview];
        [[preview representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:previewPath atomically:YES];
        for (NSString *mode in @[@"light",@"dark"]) {
            editor.window.appearance = [NSAppearance appearanceNamed:[mode isEqual:@"dark"] ? NSAppearanceNameDarkAqua : NSAppearanceNameAqua];
            [editor syncTextControls]; [content layoutSubtreeIfNeeded];
            [editor.window.effectiveAppearance performAsCurrentDrawingAppearance:^{
                NSBitmapImageRep *themed = [content bitmapImageRepForCachingDisplayInRect:content.bounds];
                [content cacheDisplayInRect:content.bounds toBitmapImageRep:themed];
                NSString *path = [[[previewPath stringByDeletingPathExtension] stringByAppendingFormat:@"-%@",mode] stringByAppendingPathExtension:@"png"];
                [[themed representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:path atomically:YES];
            }];
        }
    }
    error = nil;
    NSData *result = [editor renderPNGData:&error];
    NSBitmapImageRep *bitmap = [NSBitmapImageRep imageRepWithData:result];
    CHECK(bitmap.pixelsWide == 400 && bitmap.pixelsHigh == 300 && [editor.document[@"annotations"] count] == 1,
          "export commits live text and uses the selected pixel dimensions");
    CHECK([editor.document[@"annotations"][0][@"fontSize"] intValue] == 32,
          "second-row font size is committed into the shared text document");
    NSString *textID = canvas.selectedID;
    selectTool(editor, 0);
    canvas.selectedID = textID;
    [editor refresh];
    CHECK(!editor.textPropertiesCanvas.hidden && editor.textPropertyInputs.count == 2,
          "selecting an existing text object retains shared text properties in the select tool");
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
    CHECK(NSEqualRects(editor.captureScreenFrame,expectedPinFrame), "capture consumers share the real scaled screen selection coordinates");
    __block NSRect pinnedFrame = NSZeroRect;
    __weak MCImageEditorController *weakEditor = editor;
    editor.onPinPNGData = ^BOOL(NSData *data) { (void)data; return NO; };
    [editor pinImage:nil];
    CHECK(editor.window != nil && [editor.document[@"viewport"] isEqual:viewport],
          "a pin rejected by the feature gate keeps the crop and editor alive");
    editor.onPinPNGData = nil;
    CHECK(!MCToolbarEnabled(editor.toolbar,@"builtin.image.pin") &&
          MCToolbarPosition(editor.toolbar,@"builtin.image.pin") > MCToolbarPosition(editor.toolbar,@"host.redo"),
          "removing pin capability disables its completion-group action");
    editor.onPinPNGData = ^BOOL(NSData *data) { pinned = data; pinnedFrame = weakEditor.pinScreenFrame; return YES; };
    [editor pinImage:nil];
    CHECK(pinned.length > 0 && editor.window == nil, "pin receives the final crop and finishes the capture");
    CHECK(NSEqualRects(expectedPinFrame, pinnedFrame), "pin carries the actual screen selection frame at every backing scale");
    NSBitmapImageRep *pin = [NSBitmapImageRep imageRepWithData:pinned];
    CHECK(pin.pixelsWide == 400 && pin.pixelsHigh == 300, "pin does not receive the uncropped desktop");
    return passed;
}
static BOOL independentToolStyles(void) {
    BOOL passed = YES;
    NSError *error = nil;
    MCImageEditorController *editor = [[MCImageEditorController alloc] initWithPNGData:fixture() error:&error];
    [editor prepareWindow];
    const int colors[] = {0, 0xff0000, 0x00ff00, 0x0000ff, 0x883399};
    for (NSInteger tool = 1; tool <= 4; tool++) {
        selectTool(editor, tool);
        int rgb = colors[tool];
        textColor(editor,[NSColor colorWithSRGBRed:((rgb>>16)&255)/255.0 green:((rgb>>8)&255)/255.0 blue:(rgb&255)/255.0 alpha:tool*.2]);
        if (tool <= 2) textNumber(editor,@"style.stroke",[NSString stringWithFormat:@"%ld",3*tool]);
    }
    CHECK([editor.document[@"undo"] count] == 0, "changing creation defaults never creates document undo entries");
    for (NSInteger tool = 4; tool >= 1; tool--) {
        selectTool(editor, tool);
        CHECK(propertyValue(editor,MC_CAPTURE_TEXT_RGB) == colors[tool] && fabs(propertyValue(editor,MC_CAPTURE_TEXT_OPACITY) - tool * .2) < .001,
              "each tool restores its own RGBA values after visiting every other tool");
        if (tool <= 2) CHECK(propertyValue(editor,MC_CAPTURE_TEXT_STROKE) == 3 * tool, "rectangle and arrow have independent line widths");
    }
    MCImageEditorController *other = [[MCImageEditorController alloc] initWithPNGData:fixture() error:&error];
    [other prepareWindow];
    CHECK(propertyValue(other,MC_CAPTURE_TEXT_RGB) == editor_style_default(MC_STYLE_COLOR),
          "another editor instance retains its own defaults");
    NSDictionary *unchanged = other.document;
    NSString *otherStroke = other.textPropertyInputs[@"style.stroke"].string;
    [editor syncTextControls]; [other syncTextControls];
    CHECK([other.document isEqual:unchanged] && [other.textPropertyInputs[@"style.stroke"].string isEqual:otherStroke],
          "rebinding shared frames does not emit edits or change another owner");
    textNumber(editor,@"style.stroke",@"13");
    CHECK(propertyValue(editor,MC_CAPTURE_TEXT_STROKE) == 13 && [other.textPropertyInputs[@"style.stroke"].string isEqual:otherStroke],
          "real native numeric input remains isolated to its root session");
    selectTool(editor, 3);
    [editor addTextAtPoint:NSMakePoint(30, 30)];
    [editor.canvas.textView insertText:@"第一段" replacementRange:NSMakeRange(NSNotFound, 0)];
    CHECK([editor.canvas finishTextEditing:YES], "new styled text commits through the normal inline editor");
    NSUInteger history = [editor.document[@"undo"] count];
    [editor syncTextControls]; textColor(editor,[NSColor colorWithSRGBRed:1 green:1 blue:0 alpha:.9]);
    CHECK([editor finishSharedText:YES], "selected shared RGBA draft commits once");
    NSDictionary *changed = [editor.document[@"annotations"] firstObject];
    CHECK([changed[@"color"] isEqual:@"#ffff00"] && fabs([changed[@"opacity"] doubleValue] - .9) < .001 &&
          [editor.document[@"undo"] count] == history + 1,
          "editing a selected annotation commits RGBA together as one undoable change");
    [editor undo:nil];
    CHECK([editor.document[@"annotations"][0][@"color"] isEqual:@"#0000ff"], "one undo restores the selected object's color");
    [editor redo:nil];
    selectTool(editor,3);
    CHECK(capture_text_value(editor.imageSession,editor.textEdit,MC_CAPTURE_TEXT_RGB) == 0x0000ff && fabs(capture_text_value(editor.imageSession,editor.textEdit,MC_CAPTURE_TEXT_OPACITY) - .6) < .001,
          "modifying an existing object never overwrites text creation defaults");
    [editor addTextAtPoint:NSMakePoint(30, 180)];
    [editor.canvas.textView insertText:@"第二段" replacementRange:NSMakeRange(NSNotFound, 0)];
    CHECK([editor.canvas finishTextEditing:YES], "a subsequent text annotation commits");
    CHECK([editor.document[@"annotations"][0][@"color"] isEqual:@"#ffff00"] &&
          [editor.document[@"annotations"][1][@"color"] isEqual:@"#0000ff"],
          "existing objects and new annotations retain independent styles");
    [editor cancel:nil]; [other cancel:nil];

    return passed;
}
static NSView *cursorCanvas;
static NSMutableArray<NSDictionary *> *cursorRecords;
static void (*originalAddCursor)(id, SEL, NSRect, NSCursor *);
static void recordCursor(id view, SEL selector, NSRect rect, NSCursor *cursor) {
    if (view == cursorCanvas) [cursorRecords addObject:@{@"rect":[NSValue valueWithRect:rect], @"cursor":cursor}];
    originalAddCursor(view, selector, rect, cursor);
}
static NSArray<NSDictionary *> *canvasCursors(MCImageCanvas *canvas) {
    cursorCanvas = canvas; cursorRecords = [NSMutableArray array];
    Method method = class_getInstanceMethod(NSView.class, @selector(addCursorRect:cursor:));
    originalAddCursor = (void (*)(id, SEL, NSRect, NSCursor *))method_setImplementation(method, (IMP)recordCursor);
    [canvas discardCursorRects]; [canvas resetCursorRects];
    method_setImplementation(method, (IMP)originalAddCursor);
    NSArray *result = [cursorRecords copy]; cursorCanvas = nil; cursorRecords = nil;
    return result;
}
static BOOL hasCursor(NSArray<NSDictionary *> *records, NSPoint point, NSCursor *cursor) {
    for (NSDictionary *record in records)
        if (NSPointInRect(point, [record[@"rect"] rectValue]) && (!cursor || record[@"cursor"] == cursor)) return YES;
    return NO;
}
static NSDictionary *overlayConfiguration(NSSet<NSNumber *> *disabled, NSUInteger pluginCount) {
    NSArray *ids=@[@"builtin.image.rectangle",@"builtin.image.arrow",@"builtin.image.text",@"builtin.image.cover"];
    NSMutableArray *entries=[NSMutableArray array], *tools=[NSMutableArray array];
    for (NSUInteger index=0; index<ids.count; index++)
        [entries addObject:@{@"id":ids[index],@"enabled":@(![disabled containsObject:@(index+1)])}];
    [entries addObject:@{@"id":@"builtin.image.pin",@"enabled":@(![disabled containsObject:@100])}];
    [entries addObject:@{@"id":@"builtin.capture.ocr",@"enabled":@(![disabled containsObject:@101])}];
    [entries addObject:@{@"id":@"builtin.capture.scroll",@"enabled":@NO}];
    [entries addObject:@{@"id":@"builtin.image.numberedRectangle",@"enabled":@NO}];
    for (NSUInteger index=0; index<pluginCount; index++) {
        NSString *tool=[NSString stringWithFormat:@"tool-%lu",(unsigned long)index];
        [entries addObject:@{@"id":[@"user.com.example.capture/" stringByAppendingString:tool],@"enabled":@YES}];
        [tools addObject:@{@"toolId":tool,@"title":@"截图信息",@"target":@"screenshot",@"action":@"run"}];
    }
    NSArray *manifests=pluginCount ? @[@{@"apiVersion":@1,@"pluginId":@"com.example.capture",@"name":@"Capture fixture",@"version":@"1.0.0",
        @"entry":@"plugin.wasm",@"runtime":@"extism-1",@"capabilities":@[@"capture.metadata",@"result.text"],@"tools":tools}] : @[];
    return registryConfiguration(entries,manifests);
}
static BOOL adaptiveOverlay(CGFloat scale) {
    BOOL passed = YES;
    MCImageEditorController *editor = [[MCImageEditorController alloc] initWithPNGData:fixture() error:NULL];
    [editor prepareOverlayInFrame:NSMakeRect(-1200, -300, 800*scale, 500*scale)];
    CHECK(editor.onScrollCapture == nil && contributionPosition(editor,@"builtin.capture.scroll") == -1,
          "the experimental scroll contribution is disabled by default");
    MCImageCanvas *canvas = editor.canvas;
    NSArray *cursors = canvasCursors(canvas);
    CHECK(hasCursor(cursors, NSMakePoint(20,20), NSCursor.crosshairCursor), "initial region selection uses a canvas crosshair");
    CHECK([editor setCaptureRegion:NSMakeRect(600,440,190,40)], "bottom-edge fixture selects a region");
    NSRect bottomSelection = [canvas convertRect:[canvas viewRectForImageRect:NSMakeRect(600,440,190,40)] toView:editor.window.contentView];
    CHECK(NSMinY(editor.floatingToolbar.frame) > NSMaxY(bottomSelection) &&
          fabs(NSMaxX(editor.floatingToolbar.frame)-NSMaxX(bottomSelection)) < 1,
          "when the bottom edge has no space, the menu moves above while staying right-aligned");
    CHECK([editor setCaptureRegion:NSMakeRect(1,150,80,80)] &&
          NSContainsRect(editor.window.contentView.bounds,editor.floatingToolbar.frame) && NSMinX(editor.floatingToolbar.frame) == 8,
          "a narrow crop at the left display edge keeps the whole toolbar reachable");
    // A nearly full-screen crop forces the toolbar over the selection, exactly
    // where sibling cursor rectangles used to leak through native controls.
    CHECK([editor setCaptureRegion:NSMakeRect(10,10,780,480)], "large crop establishes overlay layout");
    CGFloat defaultWidth = NSWidth(editor.floatingToolbar.frame);
    NSRect selectionRoot = [canvas convertRect:[canvas viewRectForImageRect:NSMakeRect(10,10,780,480)] toView:editor.window.contentView];
    CHECK(fabs(NSMaxX(editor.floatingToolbar.frame) - NSMaxX(selectionRoot)) < 1 &&
          NSMinY(editor.floatingToolbar.frame) < NSMidY(selectionRoot),
          "a full-screen crop keeps the menu at the lower right inside the selection");
    CHECK(defaultWidth < 450, "default screenshot toolbar fits its actual controls instead of a fixed 500-point shell");
    selectTool(editor,1);
    cursors = canvasCursors(canvas);
    NSRect hud = [canvas convertRect:editor.floatingToolbar.bounds fromView:editor.floatingToolbar];
    for (NSDictionary *record in cursors)
        CHECK(NSIsEmptyRect(NSIntersectionRect([record[@"rect"] rectValue], hud)), "no canvas cursor registration covers the floating native controls");
    NSPoint inside = NSMakePoint(650*scale,350*scale);
    CHECK(hasCursor(cursors, inside, NSCursor.crosshairCursor), "drawing crosshair tracks the scaled crop");
    CHECK(!hasCursor(cursors, NSMakePoint(1,1), nil), "outside the selected crop retains the normal arrow");
    selectTool(editor,0);
    CHECK(!hasCursor(canvasCursors(canvas), inside, nil), "the selection tool does not register a drawing cursor inside the crop");
    selectTool(editor,3);
    CHECK(hasCursor(canvasCursors(canvas), inside, NSCursor.IBeamCursor), "text mode uses an I-beam only inside the crop");
    [editor addTextAtPoint:NSMakePoint(350,250)];
    [canvas.textView insertText:@"文字缩放" replacementRange:NSMakeRange(NSNotFound,0)];
    NSRect textFrame = canvas.selectionFrame;
    CHECK(hasCursor(canvasCursors(canvas), NSMakePoint(NSMaxX(textFrame),NSMidY(textFrame)), NSCursor.resizeLeftRightCursor),
          "text resize handles retain their cursor at each display scale");
    NSResponder *responder = editor.window.firstResponder;
    NSRect fieldFrame = editor.textPropertyInputs[@"style.fontSize"].frame;
    [editor positionFloatingToolbar];
    CHECK(editor.window.firstResponder == responder && NSEqualRects(editor.textPropertyInputs[@"style.fontSize"].frame,fieldFrame),
          "relayout preserves native text focus and numeric field width");
    CHECK([canvas finishTextEditing:YES], "layout leaves inline text committable");
    selectTool(editor,0);
    [editor applyToolConfiguration:overlayConfiguration([NSSet setWithArray:@[@2,@3,@4,@100]],0)];
    CGFloat reduced = NSWidth(editor.floatingToolbar.frame);
    CHECK(reduced < defaultWidth - 50, "disabling tools removes their actual width from the floating panel");
    [editor applyToolConfiguration:overlayConfiguration([NSSet set],3)];
    CGFloat threePlugins = NSWidth(editor.floatingToolbar.frame);
    CHECK(threePlugins > defaultWidth && threePlugins <= NSWidth(editor.window.contentView.bounds)-24,
          "adding two plugin actions expands only to their measured content");
    [editor applyToolConfiguration:overlayConfiguration([NSSet set],16)];
    CGFloat manyPlugins = NSWidth(editor.floatingToolbar.frame);
    CHECK(manyPlugins <= 400 && MCToolbarSemantic(editor.toolbar,@"__toolbar.next") != nil,
          "extra plugins use shared bounded paging instead of widening the panel indefinitely");
    CHECK(MCToolbarReveal(editor.toolbar,@"user.com.example.capture/tool-15") != nil,
          "the last plugin is reachable through actual shared paging controls");
    [editor applyToolConfiguration:overlayConfiguration([NSSet setWithArray:@[@2,@100]],0)];
    selectTool(editor,4); CGFloat cover = NSWidth(editor.floatingToolbar.frame), coverProperties = propertyValue(editor,MC_CAPTURE_TEXT_ROW_WIDTH);
    selectTool(editor,1); CGFloat shape = NSWidth(editor.floatingToolbar.frame), shapeProperties = propertyValue(editor,MC_CAPTURE_TEXT_ROW_WIDTH);
    selectTool(editor,3); CGFloat text = NSWidth(editor.floatingToolbar.frame), textProperties = propertyValue(editor,MC_CAPTURE_TEXT_ROW_WIDTH);
    CHECK(coverProperties < shapeProperties && cover <= shape && textProperties <= text && coverProperties <= cover,
          "property groups use their natural widths and fit the measured toolbar");
    CGFloat naturalFieldWidth = NSWidth(editor.textPropertyInputs[@"style.fontSize"].frame);
    CHECK(naturalFieldWidth == 36, "the numeric control keeps its 36-point text area beside the stepper");
    __block NSUInteger contentActions = 0;
    editor.onOCR = ^(__unused MCImageEditorController *source) { contentActions++; };
    editor.onTranslate = ^(__unused MCImageEditorController *source) { contentActions++; };
    editor.onScrollCapture = ^(__unused MCImageEditorController *source) { contentActions++; };
    NSInteger ocr=contributionPosition(editor,@"builtin.capture.ocr"), translate=contributionPosition(editor,@"builtin.capture.translate");
    CHECK(ocr >= 0 && translate == -1 && MCToolbarEnabled(editor.toolbar,@"builtin.capture.ocr"),
          "OCR provides the single toolbar entry even when translation is available");
    CHECK(contributionPosition(editor,@"builtin.capture.scroll") == -1, "attaching a scroll backend does not override its saved disabled preference");
    invokeContribution(editor,@"builtin.capture.ocr");
    CHECK(contentActions == 1, "the unified text entry invokes recognition exactly once");
    [editor applyToolConfiguration:setConfiguredTool(editor.toolConfiguration,@"builtin.capture.scroll",YES)];
    NSInteger scroll=contributionPosition(editor,@"builtin.capture.scroll");
    CHECK(scroll >= 0 && MCToolbarEnabled(editor.toolbar,@"builtin.capture.scroll"), "scroll appears only after explicit enable plus backend availability");
    invokeContribution(editor,@"builtin.capture.scroll");
    CHECK(contentActions == 2, "the explicitly enabled scroll contribution invokes exactly once");
    [editor applyToolConfiguration:overlayConfiguration([NSSet set],0)];
    CGFloat withContentActions = NSWidth(editor.floatingToolbar.frame);
    // Tiny synthetic display: preserve action/field hit targets and scroll them
    // instead of letting fixed-width rows escape the screen or compress input.
    [editor.window setFrame:NSMakeRect(-1000,80,160,200) display:NO]; [editor positionFloatingToolbar];
    CHECK(NSContainsRect(editor.window.contentView.bounds, editor.floatingToolbar.frame), "small/offset screens contain the entire floating panel");
    CHECK(NSWidth(editor.textPropertyInputs[@"style.fontSize"].frame) == naturalFieldWidth,
          "small screen layout scrolls without squeezing the font editor");
    CHECK(editor.textPropertiesCanvas.enclosingScrollView.documentVisibleRect.size.width < editor.textPropertiesCanvas.frame.size.width,
          "properties remain reachable through scrolling on exceptionally small screens");
    cursors = canvasCursors(canvas); hud = [canvas convertRect:editor.floatingToolbar.bounds fromView:editor.floatingToolbar];
    for (NSDictionary *record in cursors)
        CHECK(NSIsEmptyRect(NSIntersectionRect([record[@"rect"] rectValue],hud)), "resizing the overlay recalculates cursor exclusion");
    printf("overlay %.1fx widths: default=%.0f reduced=%.0f threePlugins=%.0f manyPlugins=%.0f cover=%.0f shape=%.0f text=%.0f contentActions=%.0f\n",
           scale,defaultWidth,reduced,threePlugins,manyPlugins,cover,shape,text,withContentActions);
    [editor cancel:nil]; return passed;
}
static BOOL contentSnapshots(void) {
    BOOL passed = YES;
    MCImageEditorController *editor = [[MCImageEditorController alloc] initWithPNGData:fixture() error:NULL];
    [editor prepareOverlayInFrame:NSMakeRect(-900,120,800,500)];
    CHECK(editor.captureContentSnapshot == nil, "unselected overlays have no usable capture content identity");
    [editor setCaptureRegion:NSMakeRect(20,20,700,440)];
    NSDictionary *unannotated = editor.captureContentSnapshot;
    selectTool(editor,1);
    textNumber(editor,@"style.stroke",@"12");
    selectTool(editor,2);
    CHECK([unannotated isEqual:editor.captureContentSnapshot],
          "tool switching and unused creation defaults do not invalidate OCR content");
    selectTool(editor,3); [editor addTextAtPoint:NSMakePoint(80,80)];
    [editor.canvas.textView insertText:@"原稿" replacementRange:NSMakeRange(NSNotFound,0)];
    NSNumber *revision = editor.document[@"revision"];
    NSDictionary *original = editor.captureContentSnapshot;
    CHECK([editor capturePNGData:NULL] != nil && [original isEqual:editor.captureContentSnapshot],
          "taking a PNG snapshot does not change its lightweight content identity");
    [editor.canvas.textView insertText:@"追加" replacementRange:NSMakeRange(NSNotFound,0)];
    CHECK([editor.document[@"revision"] isEqual:revision] && ![original isEqual:editor.captureContentSnapshot],
          "uncommitted text invalidates asynchronous results even while the document revision is unchanged");
    CHECK([original[@"annotations"][0][@"text"] isEqual:@"原稿"], "saved snapshot strings do not alias the live text storage");
    NSDictionary *beforeStyle = editor.captureContentSnapshot;
    textNumber(editor,@"style.fontSize",@"40");
    CHECK([editor.document[@"revision"] isEqual:revision] && ![beforeStyle isEqual:editor.captureContentSnapshot] &&
          [beforeStyle[@"annotations"][0][@"fontSize"] intValue] != 40,
          "uncommitted annotation styling changes identity without mutating the older draft snapshot");
    NSTextView *input = editor.textPropertyInputs[@"style.fontSize"];
    [editor.window makeFirstResponder:input];
    CHECK(input != nil, "the snapshot regression exercises a real native numeric field editor");
    NSDictionary *beforeField = editor.captureContentSnapshot;
    input.string = @"48";
    CHECK([editor.document[@"revision"] isEqual:revision] && ![beforeField isEqual:editor.captureContentSnapshot],
          "pending numeric field text invalidates results before its control value or document is committed");
    NSTextView *numericInput = (NSTextView *)input;
    NSDictionary *pendingNumber = editor.captureContentSnapshot;
    NSData *pendingPixels = [editor capturePNGData:NULL];
    [editor.window makeFirstResponder:editor.canvas.textView];
    CHECK([pendingNumber isEqual:editor.captureContentSnapshot] &&
          [pendingPixels isEqual:[editor capturePNGData:NULL]],
          "ending a valid numeric field edit preserves actual candidate content and rendered pixels");
    NSDictionary *pendingText = editor.captureContentSnapshot;
    NSData *pendingTextPixels = [editor capturePNGData:NULL];
    CHECK([editor.canvas finishTextEditing:YES] && ![editor.document[@"revision"] isEqual:revision] &&
          [pendingText isEqual:editor.captureContentSnapshot] &&
          [pendingTextPixels isEqual:[editor capturePNGData:NULL]],
          "committing the same pending text keeps the OCR lease despite revision and history changes");
    selectTool(editor,1);
    CHECK([pendingText isEqual:editor.captureContentSnapshot],
          "clearing the selected annotation and choosing another tool preserves rendered content");
    [editor setCaptureRegion:NSMakeRect(25,20,695,440)];
    CHECK(![pendingText isEqual:editor.captureContentSnapshot], "crop changes invalidate capture content");
    selectTool(editor,3); [editor addTextAtPoint:NSMakePoint(300,80)];
    [editor.canvas.textView insertText:@"待编辑" replacementRange:NSMakeRange(NSNotFound,0)];
    revision = editor.document[@"revision"];
    numericInput = editor.textPropertyInputs[@"style.fontSize"];
    [editor.window makeFirstResponder:numericInput];
    numericInput.string = @"invalid";
    CHECK(editor.captureContentSnapshot == nil && [editor capturePNGData:NULL] == nil,
          "invalid pending numeric text cannot keep a stale OCR lease alive");
    numericInput.string = @"48";
    [numericInput setMarkedText:@"49" selectedRange:NSMakeRange(2,0) replacementRange:NSMakeRange(0, numericInput.string.length)];
    NSString *numericComposition = [numericInput.string copy];
    NSRange numericMarkedRange = numericInput.markedRange;
    NSError *compositionError = nil;
    CHECK(numericInput.hasMarkedText && editor.captureContentSnapshot == nil &&
          [editor capturePNGData:&compositionError] == nil && compositionError != nil,
          "content actions reject numeric IME even when its unconfirmed text parses as a valid number");
    CHECK(numericInput.hasMarkedText && [numericComposition isEqual:numericInput.string] &&
          NSEqualRanges(numericMarkedRange,numericInput.markedRange) &&
          editor.window.firstResponder == numericInput && [editor.document[@"revision"] isEqual:revision],
          "rejecting numeric IME preserves its composition, focus, draft and document history");
    [numericInput insertText:@"48" replacementRange:NSMakeRange(NSNotFound,0)];
    [editor.window makeFirstResponder:editor.canvas.textView];
    [editor.canvas.textView setMarkedText:@"zhong" selectedRange:NSMakeRange(5,0) replacementRange:NSMakeRange(NSNotFound,0)];
    CHECK([editor.document[@"revision"] isEqual:revision] && editor.captureContentSnapshot == nil &&
          editor.canvas.textView.hasMarkedText,
          "IME composition invalidates results without forcing a document commit");
    [editor.canvas.textView insertText:@"中文" replacementRange:NSMakeRange(NSNotFound,0)];
    selectTool(editor,1);
    revision = editor.document[@"revision"];
    NSDictionary *beforeDrawing = editor.captureContentSnapshot;
    [editor.canvas mouseDown:mouse(editor.canvas,NSEventTypeLeftMouseDown,NSMakePoint(400,250))];
    [editor.canvas mouseDragged:mouse(editor.canvas,NSEventTypeLeftMouseDragged,NSMakePoint(500,320))];
    CHECK([editor.document[@"revision"] isEqual:revision] && editor.captureContentSnapshot == nil,
          "a pending drawing gesture invalidates results before its undoable edit commits");
    [editor.canvas mouseUp:mouse(editor.canvas,NSEventTypeLeftMouseUp,NSMakePoint(500,320))];
    CHECK(editor.captureContentSnapshot != nil && ![beforeDrawing isEqual:editor.captureContentSnapshot],
          "a committed drawing returns a new valid content identity");
    [editor cancel:nil];
    CHECK(editor.captureContentSnapshot == nil, "closed editors have no valid content snapshot");
    return passed;
}
static BOOL propertyTransactionBoundaries(void) {
    BOOL passed = YES;
    NSMutableArray<MCImageEditorController *> *editors = [NSMutableArray array];
    for (int i=0;i<2;i++) {
        MCImageEditorController *editor = [[MCImageEditorController alloc] initWithPNGData:fixture() error:NULL];
        [editor prepareWindow];
        [editor applyToolConfiguration:overlayConfiguration([NSSet set],0)]; selectTool(editor,1);
        [editor.canvas mouseDown:mouse(editor.canvas,NSEventTypeLeftMouseDown,NSMakePoint(30,30))];
        [editor.canvas mouseDragged:mouse(editor.canvas,NSEventTypeLeftMouseDragged,NSMakePoint(150,100))];
        [editor.canvas mouseUp:mouse(editor.canvas,NSEventTypeLeftMouseUp,NSMakePoint(150,100))];
        selectTool(editor,0);
        [editor.canvas mouseDown:mouse(editor.canvas,NSEventTypeLeftMouseDown,NSMakePoint(70,30))];
        [editor.canvas mouseUp:mouse(editor.canvas,NSEventTypeLeftMouseUp,NSMakePoint(70,30))];
        CHECK(editor.canvas.selectedID && editor.textEdit && editor.textPropertyInputs[@"style.stroke"],
              "select tool opens shared properties for an existing shape");
        NSDictionary *before = editor.document;
        int32_t oldEdit = editor.textEdit;
        MCSharedTextInputView *field = editor.textPropertyInputs[@"style.stroke"];
        [editor.window makeFirstResponder:field]; field.string = @"-";
        [field cancelOperation:nil];
        CHECK(editor.textEdit && editor.textEdit != oldEdit && [editor.document isEqual:before] &&
              [editor.textPropertyInputs[@"style.stroke"].string doubleValue] == 4,
              "Esc cancels an invalid property and immediately restores a usable row without document history");
        textNumber(editor,@"style.stroke",i ? @"8.5" : @"7.5");
        [editors addObject:editor];
    }
    MCImageEditorController *first=editors[0], *second=editors[1];
    NSDictionary *beforeFirst=first.document, *beforeSecond=second.document;
    NSDictionary *disabled=setConfiguredTool(first.toolConfiguration,@"builtin.image.rectangle",NO);
    textNumber(second,@"style.stroke",@"invalid");
    CHECK([first preparedToolConfigurationPublication:disabled error:NULL] &&
          ![second preparedToolConfigurationPublication:disabled error:NULL] &&
          [first.document isEqual:beforeFirst] && [second.document isEqual:beforeSecond],
          "one invalid selected shape vetoes multi-window disable without a partial commit");
    textNumber(second,@"style.stroke",@"8.5");
    NSDictionary *a=[first preparedToolConfigurationPublication:disabled error:NULL];
    NSDictionary *b=[second preparedToolConfigurationPublication:disabled error:NULL];
    CHECK(a.count && b.count, "both selected-shape transactions prepare while host selection remains active");
    if (a.count && b.count) {
        NSString *json=[[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:@[a,b] options:0 error:NULL] encoding:NSUTF8StringEncoding];
        moonbit_string_t request=moonbit_make_string_raw((int32_t)json.length);
        [json getCharacters:request range:NSMakeRange(0,json.length)];
        int accepted=capture_toolbar_config_commit_many(request); moonbit_decref(request);
        CHECK(accepted, "shared authority atomically publishes both selected shape drafts");
        if (accepted) for (MCImageEditorController *editor in editors) [editor completeToolConfigurationPublication:disabled];
        CHECK(!first.textEdit && !second.textEdit && first.textPropertyInputs.count==0 && second.textPropertyInputs.count==0 &&
              !first.canvas.selectedID && !second.canvas.selectedID && first.textPropertiesCanvas.hidden && second.textPropertiesCanvas.hidden,
              "post-publication completion retires native input from the prepared plan even after root edit handles close");
        CHECK([first.document[@"annotations"][0][@"stroke"] doubleValue]==7.5 &&
              [second.document[@"annotations"][0][@"stroke"] doubleValue]==8.5 &&
              [first.document[@"undo"] count]==[beforeFirst[@"undo"] count]+1 &&
              [second.document[@"undo"] count]==[beforeSecond[@"undo"] count]+1,
              "both refreshed render snapshots include exactly one committed property change");
    }
    for (MCImageEditorController *editor in editors) [editor cancel:nil];
    return passed;
}
int main(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
        moonbit_init();
        BOOL passed = exercise(.5);
        passed = exercise(1.5) && passed;
        passed = saveScreenshot() && passed;
        passed = windowSnap(1) && passed;
        passed = windowSnap(.5) && passed;
        passed = independentToolStyles() && passed;
        passed = adaptiveOverlay(1) && passed;
        passed = adaptiveOverlay(1.5) && passed;
        passed = contentSnapshots() && passed;
        passed = propertyTransactionBoundaries() && passed;
        puts(passed ? "PASS capture overlay: borderless frozen canvas, direct edit, scaled region handles, exact crop and pin output"
                    : "FAIL capture overlay");
        return passed ? 0 : 1;
    }
}
