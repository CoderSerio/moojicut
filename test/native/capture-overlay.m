#import <AppKit/AppKit.h>
#import "plugins/feature/image_editor/macos/MCImageEditorController.h"
#import "components/style_controls/macos/MCStylePropertiesView.h"
#include "moonbit.h"
#include "bindings/c/tool_registry.h"
#include <math.h>
#import <objc/runtime.h>

// Synthetic images and events only. The window is never shown and the test
// does not ask for screen permission or write the general clipboard.
@interface MCImageCanvas : NSView
@property NSString *selectedID;
@property NSTextView *textView;
- (NSRect)imageFrame;
- (BOOL)finishTextEditing:(BOOL)commit;
- (NSRect)viewRectForImageRect:(NSRect)rect;
- (NSRect)selectionFrame;
@end
@interface MCImageEditorController (MCOverlayTest)
@property (readonly) MCImageCanvas *canvas;
@property (readonly) NSView *floatingToolbar;
@property (readonly) BOOL hasCaptureRegion;
@property (readonly) NSSegmentedControl *tools;
@property (readonly) NSStackView *toolbar;
@property (readonly) NSButton *pinButton;
@property (readonly) NSStackView *properties;
@property (readonly) NSStackView *colorGroup;
@property (readonly) NSStackView *fontGroup;
@property (readonly) NSStackView *strokeGroup;
@property (readonly) NSTextField *lineWidth;
@property (readonly) NSStepper *strokeStepper;
@property (readonly) MCColorSwatch *color;
@property (readonly) NSTextField *fontSize;
@property (readonly) NSStepper *fontStepper;
@property (readonly) NSArray<NSDictionary *> *visibleTools;
- (void)chooseTool:(id)sender;
- (void)styleChanged:(id)sender;
- (void)refresh;
- (void)addTextAtPoint:(NSPoint)point;
- (void)pinImage:(id)sender;
- (void)prepareWindow;
- (BOOL)setCaptureRegion:(NSRect)rect;
- (void)positionFloatingToolbar;
- (void)showError:(NSError *)error;
@end

#define CHECK(c, message) do { if (!(c)) { fprintf(stderr, "FAIL capture overlay: %s\n", message); passed = NO; } } while (0)

static void selectTool(MCImageEditorController *editor, NSInteger kind) {
    for (NSInteger index = 0; index < editor.tools.segmentCount; index++) {
        if ([editor.tools tagForSegment:index] == kind) {
            editor.tools.selectedSegment = index;
            [editor chooseTool:editor.tools];
            return;
        }
    }
}

static NSInteger contributionSegment(MCImageEditorController *editor, NSString *identifier) {
    for (NSUInteger index = 0; index < editor.visibleTools.count; index++)
        if ([editor.visibleTools[index][@"id"] isEqual:identifier]) return (NSInteger)index;
    return -1;
}
static void invokeContribution(MCImageEditorController *editor, NSString *identifier) {
    NSInteger index=contributionSegment(editor,identifier);
    NSCAssert(index >= 0,@"Expected visible contribution %@",identifier);
    editor.tools.selectedSegment=index; [editor chooseTool:editor.tools];
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
    CHECK(NSHeight(editor.floatingToolbar.frame) <= 40,
          "selecting a region does not reserve an empty property row");
    selectTool(editor,1);
    CHECK(NSHeight(editor.floatingToolbar.frame) > 40 && NSHeight(editor.floatingToolbar.frame) <= 72,
          "editable properties expand to a compact second row without reducing hit targets");
    CHECK(NSMaxX(selectionInRoot) >= NSWidth(editor.floatingToolbar.frame) + 8 ?
          fabs(NSMaxX(editor.floatingToolbar.frame) - NSMaxX(selectionInRoot)) < 1 :
          NSMinX(editor.floatingToolbar.frame) == 8,
          "property widths retain the trailing anchor without moving controls offscreen");
    selectTool(editor,0);
    [editor showError:[NSError errorWithDomain:@"test" code:1 userInfo:@{NSLocalizedDescriptionKey:@"An actionable error"}]];
    CHECK(NSHeight(editor.floatingToolbar.frame) > 40 && !((MCStylePropertiesView *)editor.properties).status.hidden,
          "an error expands a collapsed property row so the message remains visible");
    [editor refresh];
    CHECK(NSHeight(editor.floatingToolbar.frame) <= 40, "clearing the message collapses the unused row again");
    CHECK(editor.colorGroup.hidden && editor.fontGroup.hidden && editor.strokeGroup.hidden,
          "select without a text object shows no irrelevant properties");
    NSInteger ocr=contributionSegment(editor,@"builtin.capture.ocr"), translate=contributionSegment(editor,@"builtin.capture.translate");
    CHECK(ocr >= 0 && translate >= 0 && ![editor.tools isEnabledForSegment:ocr] && ![editor.tools isEnabledForSegment:translate] &&
          [[editor.tools toolTipForSegment:ocr] containsString:@"后端不可用"] && [[editor.tools toolTipForSegment:translate] containsString:@"后端不可用"] &&
          [editor.tools imageForSegment:ocr].accessibilityDescription.length > 0 && [editor.tools imageForSegment:translate].accessibilityDescription.length > 0,
          "enabled contributions remain visible with explicit unavailable state and accessible descriptions until a backend is supplied");
    NSNumber *revision = editor.document[@"revision"];
    invokeContribution(editor,@"builtin.capture.ocr"); invokeContribution(editor,@"builtin.capture.translate");
    CHECK([editor.document[@"revision"] isEqual:revision], "unavailable contribution dispatch never mutates the image");
    CHECK([editor.color isDescendantOf:editor.properties] && [editor.fontSize isDescendantOf:editor.properties] &&
          ![editor.color isDescendantOf:editor.toolbar] && ![editor.fontSize isDescendantOf:editor.toolbar],
          "color and font controls live only in the contextual second row");
    selectTool(editor, 1);
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
    selectTool(editor, 2);
    CHECK(!editor.strokeGroup.hidden && editor.fontGroup.hidden, "arrow exposes the same meaningful shape properties");
    selectTool(editor, 4);
    CHECK(!editor.colorGroup.hidden && editor.fontGroup.hidden && editor.strokeGroup.hidden,
          "filled cover exposes color/opacity without unrelated stroke or font properties");
    selectTool(editor, 3);
    CHECK(!editor.colorGroup.hidden && !editor.fontGroup.hidden && editor.strokeGroup.hidden &&
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
    CHECK(canvas.textView.hasMarkedText && [editor.tools tagForSegment:editor.tools.selectedSegment] == 3 &&
          editor.window.firstResponder == textResponder && NSEqualRects(toolbarFrame, editor.floatingToolbar.frame),
          "tool switching preserves ongoing IME composition and HUD placement");
    [canvas.textView insertText:@"原地编辑 🌙\n第二行" replacementRange:NSMakeRange(NSNotFound, 0)];
    editor.fontStepper.doubleValue = 32;
    [editor.fontStepper sendAction:editor.fontStepper.action to:editor.fontStepper.target];
    CHECK(editor.fontSize.doubleValue == 32 && [editor.document[@"annotations"] count] == 0,
          "native font stepper updates the text draft without premature document history");
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
    CHECK(NSEqualRects(editor.captureScreenFrame,expectedPinFrame), "capture consumers share the real scaled screen selection coordinates");
    __block NSRect pinnedFrame = NSZeroRect;
    __weak MCImageEditorController *weakEditor = editor;
    editor.onPinPNGData = ^BOOL(NSData *data) { (void)data; return NO; };
    [editor pinImage:nil];
    CHECK(editor.window != nil && [editor.document[@"viewport"] isEqual:viewport],
          "a pin rejected by the feature gate keeps the crop and editor alive");
    editor.onPinPNGData = nil;
    NSInteger pinSegment = -1;
    for (NSInteger index = 0; index < editor.tools.segmentCount; index++)
        if ([editor.tools tagForSegment:index] == 100) pinSegment = index;
    CHECK(pinSegment == -1 && !editor.pinButton.enabled,
          "removing pin capability disables its workflow action without an annotation segment");
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
    MCStylePropertiesView *properties = (MCStylePropertiesView *)editor.properties;
    const int colors[] = {0, 0xff0000, 0x00ff00, 0x0000ff, 0x883399};
    for (NSInteger tool = 1; tool <= 4; tool++) {
        selectTool(editor, tool);
        MCStyleValues values = properties.values;
        values.rgb = colors[tool]; values.opacity = tool * .2;
        properties.values = values;
        properties.colorControl.onChange(properties.colorControl.well);
        if (tool <= 2) {
            editor.strokeStepper.doubleValue = 3 * tool;
            [editor.strokeStepper sendAction:editor.strokeStepper.action to:editor.strokeStepper.target];
        }
    }
    CHECK([editor.document[@"undo"] count] == 0, "changing creation defaults never creates document undo entries");
    for (NSInteger tool = 4; tool >= 1; tool--) {
        selectTool(editor, tool);
        MCStyleValues values = properties.values;
        CHECK(values.rgb == colors[tool] && fabs(values.opacity - tool * .2) < .001,
              "each tool restores its own RGBA values after visiting every other tool");
        if (tool <= 2) CHECK(values.stroke == 3 * tool, "rectangle and arrow have independent line widths");
    }
    MCImageEditorController *other = [[MCImageEditorController alloc] initWithPNGData:fixture() error:&error];
    [other prepareWindow];
    CHECK(((MCStylePropertiesView *)other.properties).values.rgb == (int32_t)editor_style_default(MC_STYLE_COLOR),
          "another editor instance retains its own defaults");
    selectTool(editor, 3);
    [editor addTextAtPoint:NSMakePoint(30, 30)];
    [editor.canvas.textView insertText:@"第一段" replacementRange:NSMakeRange(NSNotFound, 0)];
    CHECK([editor.canvas finishTextEditing:YES], "new styled text commits through the normal inline editor");
    NSUInteger history = [editor.document[@"undo"] count];
    properties.colorControl.color = [NSColor colorWithSRGBRed:1 green:1 blue:0 alpha:.9];
    properties.colorControl.onChange(properties.colorControl.well);
    NSDictionary *changed = [editor.document[@"annotations"] firstObject];
    CHECK([changed[@"color"] isEqual:@"#ffff00"] && fabs([changed[@"opacity"] doubleValue] - .9) < .001 &&
          [editor.document[@"undo"] count] == history + 1,
          "editing a selected annotation commits RGBA together as one undoable change");
    [editor undo:nil];
    CHECK([editor.document[@"annotations"][0][@"color"] isEqual:@"#0000ff"], "one undo restores the selected object's color");
    [editor redo:nil];
    [editor chooseTool:editor.tools];
    CHECK(properties.values.rgb == 0x0000ff && fabs(properties.values.opacity - .6) < .001,
          "modifying an existing object never overwrites text creation defaults");
    [editor addTextAtPoint:NSMakePoint(30, 180)];
    [editor.canvas.textView insertText:@"第二段" replacementRange:NSMakeRange(NSNotFound, 0)];
    CHECK([editor.canvas finishTextEditing:YES], "a subsequent text annotation commits");
    CHECK([editor.document[@"annotations"][0][@"color"] isEqual:@"#ffff00"] &&
          [editor.document[@"annotations"][1][@"color"] isEqual:@"#0000ff"],
          "existing objects and new annotations retain independent styles");
    [editor cancel:nil]; [other cancel:nil];

    // Reuse the same native component outside an editor. Rebinding values must
    // not emit user actions or route callbacks to another component instance.
    MCStylePropertiesView *first = [[MCStylePropertiesView alloc] initWithFrame:NSZeroRect];
    MCStylePropertiesView *second = [[MCStylePropertiesView alloc] initWithFrame:NSZeroRect];
    first.propertyMask = second.propertyMask = editor_style_property_mask(MC_STYLE_TOOL_RECTANGLE);
    __block NSInteger firstChanges = 0, secondChanges = 0;
    first.onChange = ^(__unused id sender) { firstChanges++; };
    second.onChange = ^(__unused id sender) { secondChanges++; };
    MCStyleValues rebound = first.values; rebound.stroke = 12;
    first.values = rebound;
    CHECK(firstChanges == 0 && secondChanges == 0, "rebinding component values never masquerades as user input");
    first.strokeControl.stepper.doubleValue = 13;
    [first.strokeControl.stepper sendAction:first.strokeControl.stepper.action to:first.strokeControl.stepper.target];
    CHECK(firstChanges == 1 && secondChanges == 0 && second.values.stroke == editor_style_default(MC_STYLE_STROKE),
          "native numeric callbacks stay within their own component instance");
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
    [entries addObject:@{@"id":@"builtin.capture.translate",@"enabled":@(![disabled containsObject:@102])}];
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
    CHECK(editor.onScrollCapture == nil && contributionSegment(editor,@"builtin.capture.scroll") == -1,
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
    NSRect fieldFrame = editor.fontSize.frame;
    [editor positionFloatingToolbar];
    CHECK(editor.window.firstResponder == responder && NSEqualRects(editor.fontSize.frame,fieldFrame),
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
    NSScrollView *toolsScroll = editor.tools.enclosingScrollView;
    CHECK(manyPlugins <= threePlugins + 1 && toolsScroll.documentVisibleRect.size.width < editor.tools.frame.size.width,
          "extra plugins use bounded horizontal overflow instead of widening the panel indefinitely");
    [editor.tools scrollRectToVisible:NSMakeRect(NSMaxX(editor.tools.bounds)-30,0,30,28)];
    CHECK(NSMaxX(toolsScroll.documentVisibleRect) >= NSMaxX(editor.tools.bounds)-1, "last plugin is reachable through the bounded tool scroller");
    [editor applyToolConfiguration:overlayConfiguration([NSSet setWithArray:@[@2,@100]],0)];
    selectTool(editor,4); CGFloat cover = NSWidth(editor.floatingToolbar.frame), coverProperties = editor.properties.fittingSize.width;
    selectTool(editor,1); CGFloat shape = NSWidth(editor.floatingToolbar.frame), shapeProperties = editor.properties.fittingSize.width;
    selectTool(editor,3); CGFloat text = NSWidth(editor.floatingToolbar.frame), textProperties = editor.properties.fittingSize.width;
    CHECK(coverProperties < shapeProperties && cover <= shape && textProperties <= text && coverProperties <= cover,
          "property groups use their natural widths and fit the measured toolbar");
    CHECK(NSWidth(editor.fontSize.frame) >= 44 && NSWidth(editor.lineWidth.frame) >= 44, "contextual numeric fields keep their natural width");
    __block NSUInteger contentActions = 0;
    editor.onOCR = ^(__unused MCImageEditorController *source) { contentActions++; };
    editor.onTranslate = ^(__unused MCImageEditorController *source) { contentActions++; };
    editor.onScrollCapture = ^(__unused MCImageEditorController *source) { contentActions++; };
    NSInteger ocr=contributionSegment(editor,@"builtin.capture.ocr"), translate=contributionSegment(editor,@"builtin.capture.translate");
    CHECK(ocr >= 0 && translate >= 0 && [editor.tools isEnabledForSegment:ocr] && [editor.tools isEnabledForSegment:translate],
          "OCR and translation occupy their own declared tool slots when their respective backends are attached");
    CHECK(contributionSegment(editor,@"builtin.capture.scroll") == -1, "attaching a scroll backend does not override its saved disabled preference");
    invokeContribution(editor,@"builtin.capture.ocr"); invokeContribution(editor,@"builtin.capture.translate");
    CHECK(contentActions == 2, "both declared content actions route through the shared segmented control");
    [editor applyToolConfiguration:setConfiguredTool(editor.toolConfiguration,@"builtin.capture.scroll",YES)];
    NSInteger scroll=contributionSegment(editor,@"builtin.capture.scroll");
    CHECK(scroll >= 0 && [editor.tools isEnabledForSegment:scroll], "scroll appears only after explicit enable plus backend availability");
    invokeContribution(editor,@"builtin.capture.scroll");
    CHECK(contentActions == 3, "the explicitly enabled scroll contribution invokes exactly once");
    [editor applyToolConfiguration:overlayConfiguration([NSSet set],0)];
    CGFloat withContentActions = NSWidth(editor.floatingToolbar.frame);
    // Tiny synthetic display: preserve action/field hit targets and scroll them
    // instead of letting fixed-width rows escape the screen or compress input.
    [editor.window setFrame:NSMakeRect(-1000,80,160,200) display:NO]; [editor positionFloatingToolbar];
    CHECK(NSContainsRect(editor.window.contentView.bounds, editor.floatingToolbar.frame), "small/offset screens contain the entire floating panel");
    CHECK(NSWidth(editor.fontSize.frame) >= 44, "small screen layout never squeezes the font editor");
    CHECK(editor.properties.enclosingScrollView.documentVisibleRect.size.width < editor.properties.frame.size.width,
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
    editor.strokeStepper.doubleValue = 12;
    [editor.strokeStepper sendAction:editor.strokeStepper.action to:editor.strokeStepper.target];
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
    editor.fontStepper.doubleValue = 40;
    [editor.fontStepper sendAction:editor.fontStepper.action to:editor.fontStepper.target];
    CHECK([editor.document[@"revision"] isEqual:revision] && ![beforeStyle isEqual:editor.captureContentSnapshot] &&
          [beforeStyle[@"annotations"][0][@"fontSize"] intValue] != 40,
          "uncommitted annotation styling changes identity without mutating the older draft snapshot");
    [editor.window makeFirstResponder:editor.fontSize];
    NSText *input = editor.fontSize.currentEditor;
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
    [editor.window makeFirstResponder:editor.fontSize];
    numericInput = (NSTextView *)editor.fontSize.currentEditor;
    numericInput.string = @"invalid";
    CHECK(editor.captureContentSnapshot == nil && [editor capturePNGData:NULL] == nil,
          "invalid pending numeric text cannot keep a stale OCR lease alive");
    numericInput.string = @"48";
    [numericInput setMarkedText:@"49" selectedRange:NSMakeRange(2,0) replacementRange:NSMakeRange(0, input.string.length)];
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
int main(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
        moonbit_init();
        BOOL passed = exercise(.5);
        passed = exercise(1.5) && passed;
        passed = independentToolStyles() && passed;
        passed = adaptiveOverlay(1) && passed;
        passed = adaptiveOverlay(1.5) && passed;
        passed = contentSnapshots() && passed;
        puts(passed ? "PASS capture overlay: borderless frozen canvas, direct edit, scaled region handles, exact crop and pin output"
                    : "FAIL capture overlay");
        return passed ? 0 : 1;
    }
}
