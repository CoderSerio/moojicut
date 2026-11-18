#import <AppKit/AppKit.h>
#import "plugins/feature/image_editor/macos/MCImageEditorController.h"
#import "plugins/feature/capture/macos/MCCaptureController.h"
#import "components/style_controls/macos/MCStylePropertiesView.h"
#import "components/icons/macos/MCIcon.h"
#include "moonbit.h"
#include "bindings/c/tool_registry.h"
#include "bindings/c/capture_edit.h"
#import "components/shared_canvas/macos/MCSharedCanvas.h"
#import "platform/macos/graphics/MCSharedTextInput.h"
#include <math.h>
#import <objc/runtime.h>

// Hidden synthetic windows only: no real capture, system clipboard or events.
@interface MCImageCanvas : NSView
@property NSTextView *textView;
@property NSMutableDictionary *textDraft;
@property NSString *selectedID;
@property NSDictionary *pending;
- (NSRect)imageFrame;
- (BOOL)finishTextEditing:(BOOL)commit;
@end
@interface MCImageEditorController (MCToolLayoutTest)
@property (readonly) MCImageCanvas *canvas;
@property (readonly) NSDictionary<NSString *,MCSharedTextInputView *> *textPropertyInputs;
@property (readonly) MCSharedCanvasView *textPropertiesCanvas;
@property (readonly) int32_t textEdit;
@property (readonly) int32_t imageSession;
- (void)sharedColorChanged:(id)sender;
- (void)syncTextControls;
- (BOOL)finishSharedText:(BOOL)commit;
@property (readonly) NSSegmentedControl *tools;
@property (readonly) NSInteger activeTool;
@property (readonly) MCStylePropertiesView *properties;
@property (readonly) NSStackView *toolbar;
@property (readonly) NSButton *pinButton;
@property (readonly) NSArray<NSDictionary *> *visibleTools;
@property (readonly) NSButton *undoButton;
@property (readonly) NSButton *redoButton;
@property (readonly) NSButton *cancelButton;
@property (readonly) NSButton *confirmButton;
@property (readonly) NSView *workflowDivider;
@property (readonly) NSView *floatingToolbar;
- (void)prepareWindow;
- (void)chooseTool:(id)sender;
- (BOOL)setCaptureRegion:(NSRect)rect;
@end
@interface MCCaptureController (MCToolLayoutTest)
- (MCImageEditorController *)editorForSnapshot:(NSDictionary *)snapshot error:(NSError **)error;
@end
@interface MCColorControl (MCColorPanelTest)
- (void)showColorPanel:(id)sender;
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
#define CHECK(c, message) do { if (!(c)) { fprintf(stderr, "FAIL tool layout: %s\n", message); passed = NO; } } while (0)

static NSDictionary *registryConfiguration(NSArray<NSDictionary *> *entries, NSArray *manifests) {
    NSMutableArray *saved = [NSMutableArray array];
    for (NSDictionary *entry in entries) [saved addObject:@{@"id":entry[@"id"], @"enabled":([entry[@"enabled"] boolValue] ? @YES : @NO)}];
    NSDictionary *request = @{@"layout":@{@"version":@1,@"groups":@{@"screenshot":saved}}, @"manifests":manifests};
    NSString *json = [[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:request options:0 error:NULL] encoding:NSUTF8StringEncoding];
    moonbit_string_t input = moonbit_make_string_raw((int32_t)json.length);
    [json getCharacters:input range:NSMakeRange(0,json.length)];
    moonbit_string_t result = tool_registry_resolve(input); moonbit_decref(input);
    NSString *text = [[NSString alloc] initWithCharacters:result length:Moonbit_array_length(result)]; moonbit_decref(result);
    NSDictionary *configuration = [NSJSONSerialization JSONObjectWithData:[text dataUsingEncoding:NSUTF8StringEncoding] options:0 error:NULL];
    NSCAssert([configuration[@"ok"] boolValue], @"Invalid registry fixture: %@", configuration);
    return configuration;
}
static NSDictionary *configuration(NSArray<NSNumber *> *order, NSSet<NSNumber *> *disabled) {
    NSArray *ids = @[@"builtin.image.rectangle", @"builtin.image.arrow", @"builtin.image.text", @"builtin.image.cover"];
    NSMutableArray *entries = [NSMutableArray array];
    NSArray *ordered = [order containsObject:@100] ? order : [order arrayByAddingObject:@100];
    for (NSNumber *kind in ordered) [entries addObject:@{@"id":kind.integerValue == 100 ? @"builtin.image.pin" : ids[kind.integerValue - 1],
        @"enabled":@(![disabled containsObject:kind])}];
    // These fixtures isolate annotation interactions. Content actions are tested
    // separately against the actual default catalog and host capabilities.
    for (NSString *identifier in @[@"builtin.capture.ocr",@"builtin.capture.translate"])
        [entries addObject:@{@"id":identifier,@"enabled":@NO}];
    return registryConfiguration(entries,@[]);
}
static NSDictionary *setConfiguredTool(NSDictionary *configuration, NSString *identifier, BOOL enabled) {
    NSMutableArray *entries = [NSMutableArray array];
    for (NSDictionary *entry in configuration[@"layout"][@"groups"][@"screenshot"])
        [entries addObject:[entry[@"id"] isEqual:identifier] ? @{@"id":identifier,@"enabled":@(enabled)} : entry];
    return registryConfiguration(entries,configuration[@"manifests"] ?: @[]);
}
static NSInteger contributionSegment(MCImageEditorController *editor, NSString *identifier) {
    for (NSUInteger index = 0; index < editor.visibleTools.count; index++)
        if ([editor.visibleTools[index][@"id"] isEqual:identifier]) return (NSInteger)index;
    return -1;
}
static void invokeContribution(MCImageEditorController *editor, NSString *identifier) {
    NSInteger index = contributionSegment(editor,identifier);
    NSCAssert(index >= 0,@"Contribution must have a visible segment: %@",identifier);
    editor.tools.selectedSegment=index; [editor.tools sendAction:editor.tools.action to:editor.tools.target];
}
static NSData *pixels(void) {
    NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:800 pixelsHigh:500
        bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:3200 bitsPerPixel:32];
    memset(bitmap.bitmapData, 255, bitmap.bytesPerRow * bitmap.pixelsHigh);
    return [bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
}
static MCImageEditorController *editor(void) {
    MCImageEditorController *result = [[MCImageEditorController alloc] initWithPNGData:pixels() error:NULL];
    [result prepareWindow];
    return result;
}
static NSInteger segment(MCImageEditorController *editor, NSInteger kind) {
    for (NSInteger index = 0; index < editor.tools.segmentCount; index++)
        if ([editor.tools tagForSegment:index] == kind) return index;
    return -1;
}
static void choose(MCImageEditorController *editor, NSInteger kind) {
    if (kind == 100) { [editor.pinButton sendAction:editor.pinButton.action to:editor.pinButton.target]; return; }
    editor.tools.selectedSegment = segment(editor, kind);
    [editor.tools sendAction:editor.tools.action to:editor.tools.target];
}
static void clickSegment(NSSegmentedControl *control, NSInteger segment, CGFloat offset) {
    NSPoint point = [control convertPoint:NSMakePoint(segment * 30 + offset, 14) toView:nil];
    NSEvent *down = [NSEvent mouseEventWithType:NSEventTypeLeftMouseDown location:point modifierFlags:0
        timestamp:0 windowNumber:control.window.windowNumber context:nil eventNumber:0 clickCount:1 pressure:1];
    NSEvent *up = [NSEvent mouseEventWithType:NSEventTypeLeftMouseUp location:point modifierFlags:0
        timestamp:.1 windowNumber:control.window.windowNumber context:nil eventNumber:1 clickCount:1 pressure:0];
    [NSApp postEvent:up atStart:YES];
    [control mouseDown:down];
}
static NSEvent *mouse(MCImageCanvas *canvas, NSEventType type, NSPoint point) {
    NSRect frame = canvas.imageFrame;
    NSPoint local = NSMakePoint(frame.origin.x + point.x * frame.size.width / 800,
                                frame.origin.y + point.y * frame.size.height / 500);
    return [NSEvent mouseEventWithType:type location:[canvas convertPoint:local toView:nil] modifierFlags:0
        timestamp:0 windowNumber:canvas.window.windowNumber context:nil eventNumber:0 clickCount:1 pressure:1];
}
static void draw(MCImageEditorController *editor, NSPoint from, NSPoint to) {
    [editor.canvas mouseDown:mouse(editor.canvas, NSEventTypeLeftMouseDown, from)];
    [editor.canvas mouseDragged:mouse(editor.canvas, NSEventTypeLeftMouseDragged, to)];
    [editor.canvas mouseUp:mouse(editor.canvas, NSEventTypeLeftMouseUp, to)];
}
static void color(MCImageEditorController *editor, NSColor *color) {
    if (editor.textEdit) { textColor(editor,color); return; }
    editor.properties.colorControl.color = color;
    MCColorControl *control = editor.properties.colorControl;
    if (control.onChange) control.onChange(control.well);
}
static BOOL interactions(void) {
    BOOL passed = YES;
    MCImageEditorController *e = editor();
    NSArray *order = @[@3,@4,@1,@2];
    NSDictionary *base = configuration(order, [NSSet setWithObject:@1]);
    CHECK([e canApplyToolConfiguration:base error:NULL], "initial configuration preflights");
    [e applyToolConfiguration:base];
    CHECK(e.activeTool == 0 && segment(e, 0) == 0 && segment(e, 1) == -1, "hidden current rectangle falls back to permanent host selection");
    choose(e, 2);
    CHECK(e.activeTool == 2 && e.tools.selectedSegment == 3, "arrow identity is independent of its reordered button index");
    color(e, [NSColor colorWithSRGBRed:1 green:0 blue:0 alpha:.7]);
    NSStepper *stroke = e.properties.strokeControl.stepper;
    stroke.doubleValue = 7; [stroke sendAction:stroke.action to:stroke.target];
    draw(e, NSMakePoint(30, 30), NSMakePoint(250, 120));
    NSDictionary *arrow = [e.document[@"annotations"] lastObject];
    CHECK([arrow[@"type"] isEqual:@"arrow"] && [arrow[@"stroke"] intValue] == 7 && [arrow[@"color"] isEqual:@"#ff0000"], "reordered arrow draws the right kind and style");
    choose(e, 3);
    color(e, [NSColor colorWithSRGBRed:0 green:0 blue:1 alpha:1]);
    textNumber(e,@"style.fontSize",@"36");
    [e.canvas mouseDown:mouse(e.canvas, NSEventTypeLeftMouseDown, NSMakePoint(50, 220))];
    CHECK(e.canvas.textView != nil, "reordered text enters the real inline editor");
    [e.canvas.textView insertText:@"中文工具 ✅" replacementRange:NSMakeRange(NSNotFound, 0)];
    choose(e, 4);
    NSDictionary *text = [e.document[@"annotations"] lastObject];
    CHECK([text[@"type"] isEqual:@"text"] && [text[@"fontSize"] intValue] == 36 && [text[@"color"] isEqual:@"#0000ff"], "text transaction commits the correct independent style");
    color(e, [NSColor colorWithSRGBRed:0 green:1 blue:0 alpha:.25]);
    draw(e, NSMakePoint(400, 20), NSMakePoint(600, 150));
    NSDictionary *cover = [e.document[@"annotations"] lastObject];
    CHECK([cover[@"type"] isEqual:@"redact"] && [cover[@"color"] isEqual:@"#00ff00"], "reordered cover creates a redact annotation");
    NSDictionary *before = e.document;
    NSData *png = [e renderPNGData:NULL];
    NSDictionary *noCover = configuration(order, [NSSet setWithArray:@[@1,@4]]);
    CHECK([e canApplyToolConfiguration:noCover error:NULL], "cover disable preflights");
    [e applyToolConfiguration:noCover];
    CHECK(e.activeTool == 0 && [e.document isEqual:before] && [[e renderPNGData:NULL] isEqual:png], "disabling cover preserves all annotations, undo and rendered redaction");
    [e applyToolConfiguration:base]; choose(e, 4);
    CHECK(segment(e, 4) == 2 && e.properties.values.rgb == 0x00ff00 && fabs(e.properties.values.opacity - .25) < .001,
          "reenabling restores position and RGBA defaults");
    choose(e, 2);
    CHECK(e.properties.values.stroke == 7 && e.properties.values.rgb == 0xff0000, "other tools retain independent defaults");
    [e.canvas mouseDown:mouse(e.canvas, NSEventTypeLeftMouseDown, NSMakePoint(300, 300))];
    [e.canvas mouseDragged:mouse(e.canvas, NSEventTypeLeftMouseDragged, NSMakePoint(500, 400))];
    NSDictionary *noArrow = configuration(order, [NSSet setWithArray:@[@1,@2]]);
    [e applyToolConfiguration:noArrow];
    [e.canvas mouseUp:mouse(e.canvas, NSEventTypeLeftMouseUp, NSMakePoint(500, 400))];
    CHECK(e.activeTool == 0 && [e.document isEqual:before], "late mouseUp cannot commit a disabled tool's pending shape");
    choose(e, 3);
    [e.canvas mouseDown:mouse(e.canvas, NSEventTypeLeftMouseDown, NSMakePoint(420, 260))];
    [e.canvas.textView setMarkedText:@"zhongwen" selectedRange:NSMakeRange(8, 0) replacementRange:NSMakeRange(NSNotFound, 0)];
    NSResponder *responder = e.window.firstResponder;
    NSDictionary *noText = configuration(order, [NSSet setWithArray:@[@1,@2,@3]]);
    CHECK(![e canApplyToolConfiguration:noText error:NULL], "IME blocks disable without mutating the document");
    [e applyToolConfiguration:noText];
    CHECK(e.activeTool == 3 && e.canvas.textView.hasMarkedText && [e.toolConfiguration isEqual:noArrow] && [e.document isEqual:before],
          "defensive apply retains the old effective configuration and composition");
    NSDictionary *reordered = configuration(@[@4,@2,@3,@1], [NSSet setWithArray:@[@1,@2]]);
    CHECK([e canApplyToolConfiguration:reordered error:NULL], "pure reorder is allowed during composition");
    [e applyToolConfiguration:reordered];
    CHECK(e.activeTool == 3 && e.canvas.textView.hasMarkedText && e.window.firstResponder == responder, "reorder preserves text focus and IME draft");
    [e.canvas.textView insertText:@"完成输入" replacementRange:NSMakeRange(NSNotFound, 0)];
    CHECK([e canApplyToolConfiguration:noText error:NULL] && [e.document isEqual:before] && e.canvas.textView != nil,
          "successful preflight validates without prematurely committing text");
    [e applyToolConfiguration:noText];
    CHECK(e.activeTool == 0 && !e.canvas.textView && [e.document[@"annotations"] count] == [before[@"annotations"] count] + 1 &&
          [e.document[@"undo"] count] == [before[@"undo"] count] + 1, "disable commits text once then returns to host selection");
    [e undo:nil]; CHECK([e.document[@"annotations"] isEqual:before[@"annotations"]], "one undo restores the document before disabled text committed");
    [e cancel:nil];
    return passed;
}
static BOOL validationAndFanout(void) {
    BOOL passed = YES;
    NSDictionary *base = configuration(@[@1,@2,@3,@4], [NSSet set]);
    NSDictionary *none = configuration(@[@4,@3,@2,@1], [NSSet setWithArray:@[@1,@2,@3,@4,@100]]);
    MCImageEditorController *first = editor(), *second = editor(), *opened = editor();
    MCCaptureController *capture = [MCCaptureController new];
    [capture setValue:@[first, second] forKey:@"overlayEditors"];
    [capture setValue:opened forKey:@"editor"];
    [capture applyToolConfiguration:base];
    choose(first, 2); choose(second, 3);
    [second.canvas mouseDown:mouse(second.canvas, NSEventTypeLeftMouseDown, NSMakePoint(100, 100))];
    [second.canvas.textView setMarkedText:@"nihao" selectedRange:NSMakeRange(5, 0) replacementRange:NSMakeRange(NSNotFound, 0)];
    NSDictionary *firstDocument = first.document;
    CHECK(![capture canApplyToolConfiguration:none error:NULL], "one composing screen rejects the whole configuration update");
    [capture applyToolConfiguration:none];
    CHECK([first.toolConfiguration isEqual:base] && [opened.toolConfiguration isEqual:base] && [capture.toolConfiguration isEqual:base] &&
          first.activeTool == 2 && [first.document isEqual:firstDocument], "multi-editor preflight never applies half a configuration");
    [second.canvas.textView unmarkText];
    NSString *validText = second.canvas.textView.string;
    second.canvas.textView.string = [@"x" stringByPaddingToLength:10001 withString:@"x" startingAtIndex:0];
    CHECK([capture canApplyToolConfiguration:none error:NULL] && [second.canvas.textView.string isEqual:validText],
          "shared field rejects oversized replacement before it can corrupt the live draft");
    second.canvas.textView.string = @"你好";
    choose(first, 2);
    NSTextField *field = first.properties.strokeControl.field;
    [first.window makeFirstResponder:field];
    NSText *input = field.currentEditor;
    CHECK(input != nil, "numeric validation exercises a real native field editor");
    input.string = @"invalid";
    CHECK(![capture canApplyToolConfiguration:none error:NULL] && [input.string isEqual:@"invalid"], "invalid numeric input rejects disable without discarding input");
    input.string = @"11";
    CHECK([capture canApplyToolConfiguration:none error:NULL] && [first.document isEqual:firstDocument], "valid numeric and text edits preflight without mutation");
    [capture applyToolConfiguration:none];
    CHECK(first.tools.segmentCount == 1 && second.tools.segmentCount == 1 && opened.tools.segmentCount == 1 &&
          first.activeTool == 0 && second.activeTool == 0 && opened.activeTool == 0, "all editors keep only host selection after all optional tools close");
    CHECK([second.document[@"annotations"] count] == 1 && [second.document[@"undo"] count] == 1, "multi-screen apply commits the text exactly once");
    MCImageEditorController *late = [capture editorForSnapshot:@{@"png":pixels(), @"frame":[NSValue valueWithRect:NSMakeRect(0,0,800,500)]} error:NULL];
    CHECK(late.tools.segmentCount == 1 && [late.toolConfiguration isEqual:none], "late frozen-screen editors inherit the latest configuration");
    [capture applyToolConfiguration:base]; choose(first, 2);
    CHECK(first.properties.values.stroke == 11 && [first.document isEqual:firstDocument], "committing numeric defaults before disable preserves the style bank without adding undo");
    [capture setValue:nil forKey:@"overlayEditors"]; [capture setValue:nil forKey:@"editor"];
    for (MCImageEditorController *e in @[first, second, opened, late]) [e cancel:nil];
    return passed;
}
static BOOL pinAction(void) {
    BOOL passed = YES;
    MCImageEditorController *e = editor();
    __block NSInteger calls = 0;
    __block NSData *result = nil;
    BOOL (^pin)(NSData *) = ^BOOL(NSData *png) { calls++; result = png; return NO; };
    e.onPinPNGData = pin;
    choose(e, 2);
    color(e, [NSColor colorWithSRGBRed:1 green:0 blue:0 alpha:.4]);
    NSStepper *stroke = e.properties.strokeControl.stepper;
    stroke.doubleValue = 9; [stroke sendAction:stroke.action to:stroke.target];
    MCStyleValues values = e.properties.values;
    NSDictionary *before = e.document;
    NSArray *orders = @[@[@100,@1,@2,@3,@4], @[@1,@2,@100,@3,@4], @[@1,@2,@3,@4,@100]];
    for (NSUInteger index = 0; index < orders.count; index++) {
        NSDictionary *candidate = configuration(orders[index], [NSSet set]);
        CHECK([e canApplyToolConfiguration:candidate error:NULL], "pin action contract preflights without annotation kind");
        [e applyToolConfiguration:candidate];
        CHECK(segment(e, 100) == -1 && !e.pinButton.hidden && e.pinButton.enabled,
              "saved pin ordering never moves the terminal action into the editing group");
        choose(e, 100);
        CHECK(e.activeTool == 2 && [e.tools tagForSegment:e.tools.selectedSegment] == 2 && calls == (NSInteger)index + 1 &&
              [e.document isEqual:before] && e.window != nil, "failed pin is momentary and retains the editor and current annotation tool");
        CHECK(e.properties.values.rgb == values.rgb && e.properties.values.stroke == values.stroke &&
              fabs(e.properties.values.opacity - values.opacity) < .001, "pin action never changes the tool style bank");
    }
    NSBitmapImageRep *rendered = [NSBitmapImageRep imageRepWithData:result];
    CHECK(rendered.pixelsWide == 800 && rendered.pixelsHigh == 500, "pin still uses the real PNG rendering transaction");
    CHECK(e.pinButton.superview == e.toolbar && segment(e,100) == -1, "the workflow group owns the only pin button");
    e.onPinPNGData = nil;
    CHECK(!e.pinButton.enabled && [e.pinButton.toolTip containsString:@"已关闭"], "removing the shared pin gate immediately disables the workflow button");
    choose(e,100);
    CHECK(calls == 3 && e.activeTool == 2 && [e.document isEqual:before], "direct action dispatch cannot bypass a missing pin gate");
    e.onPinPNGData = pin;
    CHECK(segment(e,100) == -1 && e.pinButton.enabled, "restoring the gate enables pin without rebuilding the editor");
    choose(e,3);
    [e.canvas mouseDown:mouse(e.canvas, NSEventTypeLeftMouseDown, NSMakePoint(50,220))];
    [e.canvas.textView setMarkedText:@"zhongwen" selectedRange:NSMakeRange(8,0) replacementRange:NSMakeRange(NSNotFound,0)];
    NSResponder *responder = e.window.firstResponder;
    NSDictionary *hidden = configuration(@[@100,@4,@3,@2,@1], [NSSet setWithObject:@100]);
    CHECK([e canApplyToolConfiguration:hidden error:NULL], "managing pin is independent of the active text transaction");
    [e applyToolConfiguration:hidden];
    e.onPinPNGData = nil;
    CHECK(e.pinButton.hidden && e.canvas.textView.hasMarkedText && e.window.firstResponder == responder &&
          e.activeTool == 3 && [e.document isEqual:before], "hiding pin and changing its gate never consume background IME composition");
    NSDictionary *shown = configuration(@[@1,@100,@3,@2,@4], [NSSet set]);
    [e applyToolConfiguration:shown]; e.onPinPNGData = pin;
    CHECK(!e.pinButton.hidden && segment(e,100) == -1 && e.canvas.textView.hasMarkedText && e.window.firstResponder == responder,
          "reenabling and moving pin preserves IME and the chosen text tool");
    NSString *composed = e.canvas.textView.string;
    NSTextView *textView = e.canvas.textView;
    NSMutableDictionary *draft = e.canvas.textDraft;
    NSString *selection = e.canvas.selectedID;
    choose(e,100);
    CHECK(calls == 3 && e.activeTool == 3 && e.canvas.textView == textView && textView.hasMarkedText &&
          e.canvas.textDraft == draft && [e.canvas.selectedID isEqual:selection] && [e.document isEqual:before] &&
          [textView.string isEqual:composed] && e.window.firstResponder == responder,
          "explicit pin rejects IME without touching composition, selection, draft or history");
    [textView insertText:@"保留草稿" replacementRange:NSMakeRange(NSNotFound,0)];
    draft = e.canvas.textDraft;
    NSRange selectedRange = textView.selectedRange;
    NSData *unannotated = result;
    NSUndoManager *textUndo = textView.undoManager;
    BOOL canUndo = textUndo.canUndo;
    choose(e,100);
    CHECK(calls == 4 && e.activeTool == 3 && e.canvas.textView == textView && e.canvas.textDraft == draft &&
          [textView.string isEqual:@"保留草稿"] && [e.canvas.selectedID isEqual:selection] &&
          NSEqualRanges(textView.selectedRange,selectedRange) && e.window.firstResponder == responder &&
          textView.undoManager == textUndo && textUndo.canUndo == canUndo && [e.document isEqual:before],
          "handler failure retains the exact live text transaction and document history");
    CHECK(![result isEqual:unannotated], "candidate PNG includes the pending text without committing it into the editor");
    textNumber(e,@"style.fontSize",@"invalid");
    draft = e.canvas.textDraft;
    choose(e,100);
    CHECK(calls == 4 && e.activeTool == 3 && e.canvas.textView == textView &&
          [e.textPropertyInputs[@"style.fontSize"].string isEqual:@"invalid"] && e.canvas.textDraft == draft && [e.document isEqual:before],
          "pin cannot discard a numeric draft rejected by the shared field validator");
    [e.canvas finishTextEditing:NO];
    choose(e,2);
    CHECK(e.properties.values.stroke == 9 && e.properties.values.rgb == 0xff0000, "the prior arrow defaults survive pin attempts and text edits");
    [e.canvas mouseDown:mouse(e.canvas, NSEventTypeLeftMouseDown, NSMakePoint(300,300))];
    [e.canvas mouseDragged:mouse(e.canvas, NSEventTypeLeftMouseDragged, NSMakePoint(500,400))];
    choose(e,100);
    CHECK(calls == 4 && e.activeTool == 2, "pin during a drag neither invokes the handler nor switches the drawing tool");
    [e.canvas mouseUp:mouse(e.canvas, NSEventTypeLeftMouseUp, NSMakePoint(500,400))];
    CHECK([e.document[@"annotations"] count] == 1 && [e.document[@"annotations"][0][@"type"] isEqual:@"arrow"],
          "ignored pin during a drag preserves the pending annotation transaction");
    [e cancel:nil];
    MCImageEditorController *success = editor();
    choose(success,2);
    success.onPinPNGData = ^BOOL(NSData *png) { return [NSBitmapImageRep imageRepWithData:png] != nil; };
    choose(success,100);
    CHECK(!success.window && success.activeTool == 2, "successful pin closes through the existing action without selecting an action as a tool");
    return passed;
}
static BOOL userActions(void) {
    BOOL passed = YES;
    MCImageEditorController *e = editor();
    NSDictionary *base = configuration(@[@1,@2,@3,@4], [NSSet set]);
    NSMutableArray *entries = [base[@"groups"][@"screenshot"] mutableCopy];
    NSString *firstID = @"user.com.example.capture/info";
    [entries insertObject:@{@"id":firstID, @"pluginId":@"com.example.capture", @"toolId":@"info",
        @"type":@"action", @"action":@"run", @"target":@"screenshot", @"title":@"截图信息", @"enabled":@YES} atIndex:0];
    NSMutableArray *manifestTools = [NSMutableArray arrayWithObject:@{@"toolId":@"info",@"title":@"截图信息",@"target":@"screenshot",@"action":@"run"}];
    // Enough actions to overflow even a wide editor. All remain addressable by
    // stable identity while the annotation controls keep their semantic tags.
    for (NSUInteger index = 0; index < 15; index++) {
        NSString *tool = [NSString stringWithFormat:@"extra-%lu", (unsigned long)index];
        [manifestTools addObject:@{@"toolId":tool,@"title":tool,@"target":@"screenshot",@"action":@"run"}];
        [entries addObject:@{@"id":[@"user.com.example.capture/" stringByAppendingString:tool],
            @"pluginId":@"com.example.capture", @"toolId":tool, @"type":@"action", @"action":@"run",
            @"target":@"screenshot", @"title":tool, @"enabled":@YES}];
    }
    NSArray *manifests = @[@{@"apiVersion":@1,@"pluginId":@"com.example.capture",@"name":@"Capture fixture",@"version":@"1.0.0",
        @"entry":@"plugin.wasm",@"runtime":@"extism-1",@"capabilities":@[@"capture.metadata",@"result.text"],@"tools":manifestTools}];
    NSDictionary *candidate = registryConfiguration(entries,manifests);
    CHECK([e canApplyToolConfiguration:candidate error:NULL], "user action catalog is accepted alongside all built-ins");
    [e applyToolConfiguration:candidate];
    CHECK(e.tools.segmentCount == 21 && ![e.tools isEnabledForSegment:1], "user tools need a host callback before invocation");
    choose(e, 2);
    CHECK(e.activeTool == 2, "user action insertion does not remap annotation kinds");
    NSDictionary *before = e.document;
    __block NSUInteger calls = 0;
    __block NSString *calledID = nil;
    __block NSDictionary *metadata = nil;
    e.onUserTool = ^(MCImageEditorController *source, NSString *identifier) {
        calls++; calledID = identifier; metadata = source.pluginCaptureMetadata;
    };
    CHECK([e.tools isEnabledForSegment:1], "attaching the host enables existing user action segments");
    e.tools.selectedSegment = 1; [e.tools sendAction:e.tools.action to:e.tools.target];
    CHECK(calls == 1 && [calledID isEqual:firstID] && e.activeTool == 2 && [e.document isEqual:before],
          "real action dispatch uses global ID and preserves annotation mode, document and history");
    CHECK(([metadata isEqual:@{@"width":@800,@"height":@500,@"format":@"png",@"revision":@0}]),
          "the host exposes only current capture metadata");
    [e.window setContentSize:NSMakeSize(540,400)]; [e.window.contentView layoutSubtreeIfNeeded];
    NSScrollView *scroll = e.tools.enclosingScrollView;
    CHECK(scroll && scroll.documentVisibleRect.size.width < e.tools.frame.size.width &&
          scroll.frame.size.width <= 245 && e.toolbar.fittingSize.width <= 504,
          "many user actions scroll without forcing the editor toolbar beyond its minimum window width");
    [e.tools scrollRectToVisible:NSMakeRect(NSMaxX(e.tools.bounds)-30,0,30,28)];
    CHECK(NSMaxX(scroll.documentVisibleRect) >= NSMaxX(e.tools.bounds)-1,
          "the last user tool remains reachable through horizontal scrolling");
    // Use AppKit's actual segment tracking rather than assigning selectedSegment:
    // an OS bezel's extra per-segment spacing must not accumulate into wrong IDs.
    for (NSNumber *offset in @[@3,@15,@27]) {
        NSUInteger priorCalls = calls;
        clickSegment(e.tools, e.tools.segmentCount-1, offset.doubleValue);
        CHECK(calls == priorCalls+1 && [calledID isEqual:@"user.com.example.capture/extra-14"] && e.activeTool == 2,
              "the last visible 30pt slot dispatches the correct plugin at both edges and center without staying selected");
    }
    calls = 1;
    choose(e,3);
    [e.canvas mouseDown:mouse(e.canvas, NSEventTypeLeftMouseDown, NSMakePoint(50,220))];
    [e.canvas.textView setMarkedText:@"zhongwen" selectedRange:NSMakeRange(8,0) replacementRange:NSMakeRange(NSNotFound,0)];
    NSTextView *draft = e.canvas.textView; NSResponder *responder = e.window.firstResponder;
    e.tools.selectedSegment = 1; [e.tools sendAction:e.tools.action to:e.tools.target];
    CHECK(calls == 2 && e.canvas.textView == draft && draft.hasMarkedText && e.window.firstResponder == responder &&
          e.activeTool == 3 && [e.document isEqual:before], "metadata actions do not commit or discard ongoing IME input");
    NSMutableArray *moved = [entries mutableCopy]; [moved removeObjectAtIndex:0]; [moved addObject:entries[0]];
    NSDictionary *reordered = registryConfiguration(moved,manifests);
    [e applyToolConfiguration:reordered];
    e.tools.selectedSegment = e.tools.segmentCount-1; [e.tools sendAction:e.tools.action to:e.tools.target];
    CHECK(calls == 3 && [calledID isEqual:firstID] && draft.hasMarkedText && [e.document isEqual:before],
          "moving a live user tool preserves its identity and the current input transaction");
    __block NSString *closedOwner = nil;
    NSString *owner = e.pluginContextIdentifier;
    e.onPluginContextClosed = ^(NSString *identifier) { closedOwner = identifier; };
    [e cancel:nil];
    CHECK([closedOwner isEqual:owner] && e.pluginCaptureMetadata == nil,
          "closing the editor invalidates metadata and notifies its plugin invocation owner");
    return passed;
}
static BOOL declarativeComposite(void) {
    BOOL passed=YES;
    MCImageEditorController *e=editor();
    NSDictionary *base=configuration(@[@1,@2,@3,@4],[NSSet set]);
    NSString *identifier=@"builtin.image.numberedRectangle";
    CHECK(contributionSegment(e,identifier) == -1, "the declared composite tool starts disabled");
    NSDictionary *enabled=setConfiguredTool(base,identifier,YES);
    CHECK([e canApplyToolConfiguration:enabled error:NULL], "a generic drag contribution preflights through the real registry response");
    [e applyToolConfiguration:enabled];
    NSInteger numberSegment=contributionSegment(e,identifier);
    CHECK(numberSegment >= 0 && [e.tools isEnabledForSegment:numberSegment] &&
          [e.visibleTools[(NSUInteger)numberSegment][@"interaction"] isEqual:@"dragRect"],
          "the descriptor creates an available segment without a native numbered-tool button");
    NSData *baseline=[e renderPNGData:NULL];
    invokeContribution(e,identifier);
    draw(e,NSMakePoint(80,90),NSMakePoint(280,220));
    NSArray *annotations=e.document[@"annotations"];
    CHECK(annotations.count == 2 && [annotations[0][@"type"] isEqual:@"rect"] &&
          [annotations[1][@"type"] isEqual:@"text"] && [annotations[1][@"text"] isEqual:@"1"] &&
          [e.document[@"undo"] count] == 1,
          "dragRect routes one generic command into a rectangle and number in a single document transaction");
    NSData *rendered=[e renderPNGData:NULL];
    CHECK(rendered.length > 0 && ![rendered isEqual:baseline], "the composite renders through ordinary annotation/export paths");
    [e undo:nil];
    CHECK([e.document[@"annotations"] count] == 0 && [[e renderPNGData:NULL] isEqual:baseline], "one undo removes both composite annotations");
    [e redo:nil];
    CHECK([e.document[@"annotations"] isEqual:annotations] && [[e renderPNGData:NULL] isEqual:rendered], "one redo restores the composite and identical export");
    NSDictionary *document=e.document;
    NSDictionary *disabled=setConfiguredTool(enabled,identifier,NO);
    CHECK([e canApplyToolConfiguration:disabled error:NULL], "disabling the new contribution uses the ordinary preflight");
    [e applyToolConfiguration:disabled];
    CHECK(contributionSegment(e,identifier) == -1 && e.activeTool == 0 && [e.document isEqual:document] &&
          [[e renderPNGData:NULL] isEqual:rendered],
          "disabling removes the command entry while preserving existing document shapes, history and export");
    [e cancel:nil];
    return passed;
}
static BOOL objectSelection(CGFloat scale) {
    BOOL passed = YES;
    MCImageEditorController *e = editor();
    [e prepareOverlayInFrame:NSMakeRect(-800,50,800*scale,500*scale)];
    [e setCaptureRegion:NSMakeRect(10,10,780,480)];
    NSArray *objects = @[
        @{@"id":@"box",@"type":@"rect",@"x":@40,@"y":@50,@"width":@120,@"height":@80},
        @{@"id":@"arrow",@"type":@"arrow",@"x":@420,@"y":@160,@"x2":@300,@"y2":@60,@"width":@120,@"height":@100},
        @{@"id":@"text",@"type":@"text",@"x":@60,@"y":@250,@"width":@200,@"height":@70,@"text":@"选择与移动"},
        @{@"id":@"cover",@"type":@"redact",@"x":@450,@"y":@260,@"width":@160,@"height":@90}];
    for (NSDictionary *object in objects) CHECK([e applyAnnotation:object], "selection fixture annotations are accepted");
    NSArray *points = @[[NSValue valueWithPoint:NSMakePoint(40,90)], [NSValue valueWithPoint:NSMakePoint(360,110)],
        [NSValue valueWithPoint:NSMakePoint(150,280)], [NSValue valueWithPoint:NSMakePoint(530,300)]];
    NSDictionary *crop = e.document[@"viewport"];
    for (NSUInteger index = 0; index < objects.count; index++) {
        choose(e,0);
        NSDictionary *original = e.document[@"annotations"][index];
        NSPoint start = [points[index] pointValue], end = NSMakePoint(start.x+20,start.y+15);
        if (index == 0) {
            [e.canvas mouseDown:mouse(e.canvas,NSEventTypeLeftMouseDown,start)];
            [e.canvas mouseUp:mouse(e.canvas,NSEventTypeLeftMouseUp,start)];
            start = NSMakePoint(100,90); end = NSMakePoint(120,105);
        }
        NSUInteger undo = [e.document[@"undo"] count];
        [e.canvas mouseDown:mouse(e.canvas,NSEventTypeLeftMouseDown,start)];
        CHECK([e.canvas.selectedID isEqual:original[@"id"]], "selection tool hits each visible annotation kind");
        [e.canvas mouseDragged:mouse(e.canvas,NSEventTypeLeftMouseDragged,end)];
        CHECK([e.document[@"undo"] count] == undo, "object drag previews do not create history");
        [e.canvas mouseUp:mouse(e.canvas,NSEventTypeLeftMouseUp,end)];
        NSDictionary *moved = e.document[@"annotations"][index];
        CHECK(fabs([moved[@"x"] doubleValue]-[original[@"x"] doubleValue]-20)<.001 &&
              fabs([moved[@"y"] doubleValue]-[original[@"y"] doubleValue]-15)<.001 &&
              [e.document[@"undo"] count] == undo+1 && [e.document[@"viewport"] isEqual:crop],
              "moving an annotation at either zoom commits once without moving the screenshot crop");
        if (index == 1) CHECK([moved[@"x2"] doubleValue] == 320 && [moved[@"y2"] doubleValue] == 75,
                              "moving a reversed arrow preserves both directed endpoints");
        NSEvent *delete = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:0 timestamp:0
            windowNumber:e.window.windowNumber context:nil characters:@"\177" charactersIgnoringModifiers:@"\177" isARepeat:NO keyCode:51];
        [e.canvas keyDown:delete];
        CHECK([e.document[@"annotations"] count] == 3, "Delete removes the selected annotation of every kind");
        [e undo:nil];
        CHECK([e.document[@"annotations"][index] isEqual:moved], "undo restores the deleted object's complete state");
        [e undo:nil];
        CHECK([e.document[@"annotations"][index] isEqual:original], "undo restores the original object geometry");
    }
    // Rectangular objects use corner/side handles; arrows use their endpoints,
    // including a reversed arrow whose bounding rectangle starts elsewhere.
    for (NSNumber *index in @[@0,@1,@3]) {
        choose(e,0);
        NSPoint point = [points[index.unsignedIntegerValue] pointValue];
        [e.canvas mouseDown:mouse(e.canvas,NSEventTypeLeftMouseDown,point)];
        [e.canvas mouseUp:mouse(e.canvas,NSEventTypeLeftMouseUp,point)];
        NSDictionary *original = e.document[@"annotations"][index.unsignedIntegerValue];
        NSPoint handle = index.intValue == 1 ? NSMakePoint(300,60) :
            NSMakePoint([original[@"x"] doubleValue]+[original[@"width"] doubleValue],
                        [original[@"y"] doubleValue]+[original[@"height"] doubleValue]);
        NSPoint target = NSMakePoint(handle.x+30,handle.y+20);
        NSUInteger undo = [e.document[@"undo"] count];
        [e.canvas mouseDown:mouse(e.canvas,NSEventTypeLeftMouseDown,handle)];
        [e.canvas mouseDragged:mouse(e.canvas,NSEventTypeLeftMouseDragged,target)];
        [e.canvas mouseUp:mouse(e.canvas,NSEventTypeLeftMouseUp,target)];
        NSDictionary *resized = e.document[@"annotations"][index.unsignedIntegerValue];
        CHECK([e.document[@"undo"] count] == undo+1 && [e.document[@"viewport"] isEqual:crop],
              "object resize handles create one edit and cannot resize the screenshot region");
        if (index.intValue == 1) CHECK([resized[@"x"] doubleValue] == 420 && [resized[@"y"] doubleValue] == 160 &&
            [resized[@"x2"] doubleValue] == 330 && [resized[@"y2"] doubleValue] == 80,
            "arrow endpoint drag keeps the other endpoint anchored");
        else CHECK([resized[@"width"] doubleValue] == [original[@"width"] doubleValue]+30 &&
                   [resized[@"height"] doubleValue] == [original[@"height"] doubleValue]+20 && !resized[@"fontSize"],
                   "shape resize changes dimensions without adding text properties");
        [e undo:nil];
    }
    [e cancel:nil];
    return passed;
}
static NSBitmapImageRep *toolbarPixels(MCImageEditorController *editor) {
    [editor.window.contentView layoutSubtreeIfNeeded];
    NSView *view = editor.floatingToolbar ?: editor.toolbar;
    __block NSBitmapImageRep *bitmap;
    [editor.window.effectiveAppearance performAsCurrentDrawingAppearance:^{
        view.wantsLayer = YES;
        view.layer.backgroundColor = NSColor.windowBackgroundColor.CGColor;
        bitmap = [view bitmapImageRepForCachingDisplayInRect:view.bounds];
        [view cacheDisplayInRect:view.bounds toBitmapImageRep:bitmap];
    }];
    return bitmap;
}
// Compare rendered foreground against its actual neutral surface, not merely
// whether light and dark PNGs differ. Disabled actions are deliberately exempt.
static double linearChannel(double value) {
    return value <= .04045 ? value / 12.92 : pow((value + .055) / 1.055, 2.4);
}
static double luminance(NSColor *color) {
    color = [color colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    return .2126 * linearChannel(color.redComponent) + .7152 * linearChannel(color.greenComponent) + .0722 * linearChannel(color.blueComponent);
}
static double iconContrast(NSBitmapImageRep *bitmap, NSRect icon, NSView *surface) {
    double background = luminance([bitmap colorAtX:bitmap.pixelsWide/2 y:bitmap.pixelsHigh-3]);
    double result = 1;
    CGFloat sx = bitmap.pixelsWide / NSWidth(surface.bounds), sy = bitmap.pixelsHigh / NSHeight(surface.bounds);
    for (NSInteger y = MAX(0, floor((NSHeight(surface.bounds)-NSMaxY(icon))*sy)); y < MIN(bitmap.pixelsHigh,ceil((NSHeight(surface.bounds)-NSMinY(icon))*sy)); y++)
        for (NSInteger x = MAX(0,floor(NSMinX(icon)*sx)); x < MIN(bitmap.pixelsWide,ceil(NSMaxX(icon)*sx)); x++) {
            double foreground = luminance([bitmap colorAtX:x y:y]);
            result = MAX(result, (MAX(background,foreground)+.05)/(MIN(background,foreground)+.05));
        }
    return result;
}
static BOOL toolbarAppearance(void) {
    BOOL passed = YES;
    MCImageEditorController *e = [[MCImageEditorController alloc] initWithPNGData:pixels() error:NULL];
    [e prepareOverlayInFrame:NSMakeRect(0,0,800,500)];
    [e setCaptureRegion:NSMakeRect(20,20,760,460)];
    e.onOCR = ^(__unused MCImageEditorController *source) {};
    choose(e, 1);
    NSArray *items = e.toolbar.arrangedSubviews;
    NSUInteger divider = [items indexOfObject:e.workflowDivider];
    NSUInteger separatorCount = 0;
    for (NSView *view in items) for (NSView *child in view.subviews)
        if ([child isKindOfClass:NSBox.class] && ((NSBox *)child).boxType == NSBoxSeparator) separatorCount++;
    NSInteger ocrSegment=contributionSegment(e,@"builtin.capture.ocr");
    CHECK(separatorCount == 1 && ocrSegment >= 0 && [e.tools isEnabledForSegment:ocrSegment] &&
          [items indexOfObject:e.tools.enclosingScrollView] < divider &&
          [items indexOfObject:e.undoButton] < divider && [items indexOfObject:e.redoButton] < divider &&
          [items indexOfObject:e.pinButton] == divider + 1 && [items indexOfObject:e.cancelButton] == divider + 2 &&
          [items indexOfObject:e.confirmButton] == divider + 3,
          "exactly two groups: editing/OCR/history, then pin/cancel/confirm");
    for (NSString *mode in @[@"light", @"dark"]) {
        e.window.appearance = [NSAppearance appearanceNamed:[mode isEqual:@"dark"] ? NSAppearanceNameDarkAqua : NSAppearanceNameAqua];
        NSPoint hoverPoint = [e.tools convertPoint:NSMakePoint(ocrSegment*30+15,14) toView:nil];
        NSEvent *hover = [NSEvent mouseEventWithType:NSEventTypeMouseMoved location:hoverPoint modifierFlags:0
            timestamp:0 windowNumber:e.window.windowNumber context:nil eventNumber:0 clickCount:0 pressure:0];
        NSBitmapImageRep *normal = toolbarPixels(e);
        NSData *normalPNG = [normal representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
        NSRect pointer = [e.tools convertRect:NSMakeRect(6,5,18,18) toView:e.floatingToolbar];
        NSRect action = [e.tools convertRect:NSMakeRect(ocrSegment*30+6,5,18,18) toView:e.floatingToolbar];
        CHECK(iconContrast(normal,pointer,e.floatingToolbar) >= 4.5 && iconContrast(normal,action,e.floatingToolbar) >= 4.5,
              "enabled tool and action icons retain readable contrast in light and dark appearances");
        [e.undoButton mouseEntered:hover];
        CHECK([normalPNG isEqual:[toolbarPixels(e) representationUsingType:NSBitmapImageFileTypePNG properties:@{}]],
              "disabled actions do not acquire an enabled hover background in either appearance");
        [e.undoButton mouseExited:hover];
        [e.tools mouseMoved:hover];
        NSBitmapImageRep *hovered = toolbarPixels(e);
        CHECK(![normalPNG isEqual:[hovered representationUsingType:NSBitmapImageFileTypePNG properties:@{}]],
              "enabled native buttons and tool segments show their individual hover state");
        [e.tools setValue:@(ocrSegment) forKey:@"pressedSegment"];
        NSBitmapImageRep *pressed = toolbarPixels(e);
        CHECK(![[hovered representationUsingType:NSBitmapImageFileTypePNG properties:@{}]
                isEqual:[pressed representationUsingType:NSBitmapImageFileTypePNG properties:@{}]],
              "pressed feedback is distinct from hover without selecting a momentary action");
        [e.tools setValue:@(-1) forKey:@"pressedSegment"];
        [e.tools mouseExited:hover];
        CHECK(e.activeTool == 1 && e.tools.selectedSegment == segment(e, 1) && e.tools.selectedSegment != ocrSegment,
              "rendering hover/pressed states preserves the single selected annotation tool");
        CHECK([e.tools imageForSegment:ocrSegment].accessibilityDescription.length > 0 && e.tools.accessibilityLabel.length > 0 && [e.tools imageForSegment:1].accessibilityDescription.length > 0,
              "native action labels and per-tool accessibility descriptions remain intact");
        NSString *directory = NSProcessInfo.processInfo.environment[@"MOOJICUT_TOOLBAR_PREVIEW_DIR"];
        if (directory.length) {
            [[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:NULL];
            NSArray *images = @[normal, hovered, pressed]; NSArray *states = @[@"normal",@"hover",@"pressed"];
            for (NSUInteger index = 0; index < images.count; index++) {
                NSString *name = [NSString stringWithFormat:@"toolbar-%@-%@.png", mode, states[index]];
                [[images[index] representationUsingType:NSBitmapImageFileTypePNG properties:@{}]
                    writeToFile:[directory stringByAppendingPathComponent:name] atomically:YES];
            }
        }
    }
    [e cancel:nil]; return passed;
}

// These are production canvas events and exported pixels, not a mock toolbar.
static BOOL sharedGestureCases(void) {
    BOOL passed = YES;
    NSBitmapImageRep *source = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:800 pixelsHigh:500
        bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:3200 bitsPerPixel:32];
    [NSGraphicsContext saveGraphicsState];
    NSGraphicsContext.currentContext = [NSGraphicsContext graphicsContextWithBitmapImageRep:source];
    [[NSColor colorWithWhite:.96 alpha:1] setFill]; NSRectFill(NSMakeRect(0,0,800,500));
    [@"Screenshot tools" drawAtPoint:NSMakePoint(50,425) withAttributes:@{
        NSFontAttributeName:[NSFont systemFontOfSize:27 weight:NSFontWeightSemibold], NSForegroundColorAttributeName:NSColor.blackColor}];
    [@"Rectangle, arrow and cover — shared gesture examples" drawAtPoint:NSMakePoint(50,402)
        withAttributes:@{NSFontAttributeName:[NSFont systemFontOfSize:13], NSForegroundColorAttributeName:NSColor.darkGrayColor}];
    NSArray *names = @[@"01  Rectangle", @"02  Arrow", @"03  Cover"];
    for (NSUInteger index = 0; index < 3; index++) {
        CGFloat x = 50 + index * 245;
        [NSColor.whiteColor setFill];
        [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(x,175,210,165) xRadius:12 yRadius:12] fill];
        [names[index] drawAtPoint:NSMakePoint(x+16,311) withAttributes:@{
            NSFontAttributeName:[NSFont systemFontOfSize:14 weight:NSFontWeightSemibold], NSForegroundColorAttributeName:NSColor.blackColor}];
    }
    [@"Private account" drawAtPoint:NSMakePoint(556,273) withAttributes:@{NSFontAttributeName:[NSFont systemFontOfSize:12], NSForegroundColorAttributeName:NSColor.darkGrayColor}];
    [@"demo@example.com" drawAtPoint:NSMakePoint(556,245) withAttributes:@{NSFontAttributeName:[NSFont systemFontOfSize:14], NSForegroundColorAttributeName:NSColor.blackColor}];
    [NSGraphicsContext restoreGraphicsState];
    MCImageEditorController *e = [[MCImageEditorController alloc]
        initWithPNGData:[source representationUsingType:NSBitmapImageFileTypePNG properties:@{}] error:NULL];
    [e prepareOverlayInFrame:NSMakeRect(0,0,800,500)];
    [e setCaptureRegion:NSMakeRect(28,28,744,320)];
    e.onOCR = ^(__unused MCImageEditorController *editor) {};
    e.onPinPNGData = ^BOOL(__unused NSData *png) { return NO; };
    NSArray *kinds = @[@1,@2,@4];
    NSArray *starts = @[[NSValue valueWithPoint:NSMakePoint(244,310)], [NSValue valueWithPoint:NSMakePoint(486,292)], [NSValue valueWithPoint:NSMakePoint(553,239)]];
    NSArray *ends = @[[NSValue valueWithPoint:NSMakePoint(66,205)], [NSValue valueWithPoint:NSMakePoint(330,209)], [NSValue valueWithPoint:NSMakePoint(731,263)]];
    for (NSUInteger index = 0; index < kinds.count; index++) {
        choose(e, [kinds[index] integerValue]);
        NSDictionary *before = e.document;
        NSPoint start = [starts[index] pointValue], end = [ends[index] pointValue];
        [e.canvas mouseDown:mouse(e.canvas, NSEventTypeLeftMouseDown, start)];
        [e.canvas mouseDragged:mouse(e.canvas, NSEventTypeLeftMouseDragged, end)];
        NSDictionary *preview = e.canvas.pending;
        CHECK(preview && [e.document isEqual:before], "shared shape preview leaves the authoritative document and history unchanged");
        [e.canvas mouseDragged:mouse(e.canvas, NSEventTypeLeftMouseDragged, end)];
        CHECK([e.canvas.pending[@"id"] isEqual:preview[@"id"]], "a gesture retains one stable annotation identity during preview");
        [e.canvas mouseUp:mouse(e.canvas, NSEventTypeLeftMouseUp, end)];
        CHECK([[e.document[@"annotations"] lastObject] isEqual:preview] && [e.document[@"undo"] count] == index + 1,
              "the final native event applies exactly the shared preview through one image command");
        NSDictionary *committed = e.document;
        [e.canvas mouseUp:mouse(e.canvas, NSEventTypeLeftMouseUp, end)];
        CHECK([e.document isEqual:committed], "a repeated release cannot commit twice");
    }
    choose(e,1);
    NSDictionary *before = e.document;
    [e.canvas mouseDown:mouse(e.canvas, NSEventTypeLeftMouseDown, NSMakePoint(80,100))];
    [e.canvas mouseDragged:mouse(e.canvas, NSEventTypeLeftMouseDragged, NSMakePoint(160,140))];
    NSEvent *escape = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:0 timestamp:0
        windowNumber:e.window.windowNumber context:nil characters:@"\e" charactersIgnoringModifiers:@"\e" isARepeat:NO keyCode:53];
    [e.canvas keyDown:escape];
    [e.canvas mouseUp:mouse(e.canvas, NSEventTypeLeftMouseUp, NSMakePoint(160,140))];
    CHECK([e.document isEqual:before] && !e.canvas.pending && e.window != nil,
          "Escape cancels the shared draft; a late release cannot add it or close the editor");
    choose(e,0);
    NSString *directory = NSProcessInfo.processInfo.environment[@"MOOJICUT_TOOLBAR_PREVIEW_DIR"];
    if (directory.length) for (NSString *mode in @[@"light",@"dark"]) {
        e.window.appearance = [NSAppearance appearanceNamed:[mode isEqual:@"dark"] ? NSAppearanceNameDarkAqua : NSAppearanceNameAqua];
        (void)toolbarPixels(e);
        NSView *root = e.window.contentView;
        [root layoutSubtreeIfNeeded];
        NSBitmapImageRep *bitmap = [root bitmapImageRepForCachingDisplayInRect:root.bounds];
        [e.window.effectiveAppearance performAsCurrentDrawingAppearance:^{ [root cacheDisplayInRect:root.bounds toBitmapImageRep:bitmap]; }];
        [[bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}]
            writeToFile:[directory stringByAppendingPathComponent:[NSString stringWithFormat:@"capture-cases-%@.png",mode]] atomically:YES];
    }
    [e cancel:nil];
    return passed;
}
static void variant(MCImageEditorController *editor, NSInteger index) {
    editor.properties.shapeControl.selectedSegment = index;
    [editor.properties.shapeControl sendAction:editor.properties.shapeControl.action to:editor.properties.shapeControl.target];
}
static BOOL shapeVariants(void) {
    BOOL passed = YES;
    NSBitmapImageRep *glyph=[NSBitmapImageRep imageRepWithData:MCIconImage(MC_ICON_MOSAIC,@"马赛克").TIFFRepresentation];
    NSMutableArray<NSNumber *> *tones=[NSMutableArray array];
    for (NSValue *point in @[[NSValue valueWithPoint:NSMakePoint(5,5)],[NSValue valueWithPoint:NSMakePoint(12,5)],
        [NSValue valueWithPoint:NSMakePoint(5,12)],[NSValue valueWithPoint:NSMakePoint(12,12)]])
        [tones addObject:@([glyph colorAtX:point.pointValue.x*glyph.pixelsWide/18 y:point.pointValue.y*glyph.pixelsHigh/18].alphaComponent)];
    [tones sortUsingSelector:@selector(compare:)];
    CHECK(tones.firstObject.doubleValue>.2 && tones.lastObject.doubleValue>.9 &&
          tones[1].doubleValue-tones[0].doubleValue>.1 && tones[2].doubleValue-tones[1].doubleValue>.1 &&
          tones[3].doubleValue-tones[2].doubleValue>.1, "mosaic icon has four visibly distinct foreground tones");
    NSBitmapImageRep *source = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:800 pixelsHigh:500
        bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:3200 bitsPerPixel:32];
    for (NSInteger y=0;y<500;y++) for (NSInteger x=0;x<800;x++) {
        unsigned char *pixel=source.bitmapData+y*source.bytesPerRow+x*4;
        pixel[0]=x%2 ? 240:20; pixel[1]=y/3; pixel[2]=x/4; pixel[3]=255;
    }
    MCImageEditorController *e = [[MCImageEditorController alloc]
        initWithPNGData:[source representationUsingType:NSBitmapImageFileTypePNG properties:@{}] error:NULL];
    [e prepareOverlayInFrame:NSMakeRect(0,0,800,500)];
    [e setCaptureRegion:NSMakeRect(20,20,760,360)];
    NSBitmapImageRep *baseline=[NSBitmapImageRep imageRepWithData:[e renderPNGData:NULL]];
    choose(e,1); variant(e,1);
    CHECK(e.properties.shapeControl.segmentCount==2 && [e.document[@"undo"] count]==0,
          "outline offers two variants; changing its creation default does not edit the document");
    draw(e,NSMakePoint(60,50),NSMakePoint(260,150));
    CHECK([e.document[@"annotations"][0][@"type"] isEqual:@"ellipse"], "round outline is a real ellipse annotation");
    choose(e,4); variant(e,1);
    CHECK(e.properties.shapeControl.segmentCount==3 && !e.properties.colorControl.hidden,
          "cover offers rectangle, ellipse and mosaic with normal fill controls");
    draw(e,NSMakePoint(320,50),NSMakePoint(520,150));
    CHECK([e.document[@"annotations"][1][@"shape"] isEqual:@"ellipse"], "round cover carries its own shape geometry");
    variant(e,2);
    CHECK(e.properties.colorControl.hidden && !e.properties.blockControl.hidden,
          "mosaic exposes pixel size and hides irrelevant color/alpha controls");
    draw(e,NSMakePoint(540,50),NSMakePoint(740,150));
    NSBitmapImageRep *rendered=[NSBitmapImageRep imageRepWithData:[e renderPNGData:NULL]];
    CHECK([[rendered colorAtX:42 y:32] isEqual:[baseline colorAtX:42 y:32]] &&
          [[rendered colorAtX:140 y:80] isEqual:[baseline colorAtX:140 y:80]],
          "ellipse outline leaves its bounding corners and interior unchanged");
    CHECK([[rendered colorAtX:302 y:32] isEqual:[baseline colorAtX:302 y:32]] &&
          ![[rendered colorAtX:400 y:80] isEqual:[baseline colorAtX:400 y:80]],
          "filled ellipse covers its center without painting its rectangular corners");
    NSColor *a=[[rendered colorAtX:534 y:54] colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    NSColor *b=[[rendered colorAtX:540 y:60] colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    NSColor *expected=[[baseline colorAtX:538 y:58] colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    CHECK(fabs(a.redComponent-b.redComponent)<.01 && fabs(a.greenComponent-b.greenComponent)<.01 &&
          fabs(a.blueComponent-b.blueComponent)<.01 && a.redComponent>.25 && a.redComponent<.75 &&
          fabs(a.greenComponent-expected.greenComponent)<.03 && fabs(a.blueComponent-expected.blueComponent)<.03 && a.alphaComponent>.99,
          "mosaic exports flat sampled blocks with the original orientation and opaque pixels");
    choose(e,0);
    [e.canvas mouseDown:mouse(e.canvas,NSEventTypeLeftMouseDown,NSMakePoint(160,50))];
    [e.canvas mouseUp:mouse(e.canvas,NSEventTypeLeftMouseUp,NSMakePoint(160,50))];
    CHECK([e.canvas.selectedID isEqual:e.document[@"annotations"][0][@"id"]] && e.properties.shapeControl.selectedSegment==1,
          "ellipse stroke can be selected and restores the correct secondary property");
    NSUInteger count=[e.document[@"undo"] count]; variant(e,0);
    CHECK([e.document[@"annotations"][0][@"type"] isEqual:@"rect"] && [e.document[@"undo"] count]==count+1,
          "changing an existing shape is one undoable document command");
    [e undo:nil];
    CHECK([e.document[@"annotations"][0][@"type"] isEqual:@"ellipse"], "undo restores the former shape");
    choose(e,1);
    CHECK(e.properties.shapeControl.selectedSegment==1, "editing an existing shape preserves the remembered creation default");
    [e.window.contentView layoutSubtreeIfNeeded];
    MCColorSwatch *well = e.properties.colorControl.well;
    CHECK(NSWidth(well.frame) == editor_style_swatch_size() && NSHeight(well.frame) == editor_style_swatch_size(),
          "color control uses the shared circular size instead of a compressed system well");
    NSString *directory=NSProcessInfo.processInfo.environment[@"MOOJICUT_TOOLBAR_PREVIEW_DIR"];
    if (directory.length) for (NSString *mode in @[@"light",@"dark"]) {
        e.window.appearance=[NSAppearance appearanceNamed:[mode isEqual:@"dark"]?NSAppearanceNameDarkAqua:NSAppearanceNameAqua];
        for (NSUInteger i=0;i<3;i++) {
            choose(e,i==0?1:4); variant(e,i==2?2:1);
            NSData *png=[toolbarPixels(e) representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
            [png writeToFile:[directory stringByAppendingPathComponent:[NSString stringWithFormat:@"shape-options-%@-%lu.png",mode,(unsigned long)i]] atomically:YES];
        }
    }
    [e cancel:nil]; return passed;
}
static BOOL propertySpacing(void) {
    BOOL passed = YES;
    MCImageEditorController *e = editor();
    const NSInteger tools[] = {1, 1, 2, 3, 4, 4, 4};
    const NSInteger shapes[] = {0, 1, 0, 0, 0, 1, 2};
    NSString *directory = NSProcessInfo.processInfo.environment[@"MOOJICUT_TOOLBAR_PREVIEW_DIR"];
    for (NSString *mode in @[@"light", @"dark"]) {
        e.window.appearance = [NSAppearance appearanceNamed:[mode isEqual:@"dark"] ? NSAppearanceNameDarkAqua : NSAppearanceNameAqua];
        for (NSUInteger i = 0; i < sizeof(tools) / sizeof(tools[0]); i++) {
            choose(e, tools[i]);
            if (tools[i] == 1 || tools[i] == 4) variant(e, shapes[i]);
            [e.window.contentView layoutSubtreeIfNeeded];
            NSView *previous = nil;
            for (NSView *group in e.properties.arrangedSubviews) {
                if (group.hidden) continue;
                if (previous) {
                    CGFloat gap = NSMinX(group.frame) - NSMaxX(previous.frame);
                    CHECK(fabs(gap - editor_style_group_gap()) < .01,
                          "visible property groups keep the reference spacing after hidden groups detach");
                }
                if ([group isKindOfClass:NSStackView.class]) {
                    NSView *label = ((NSStackView *)group).arrangedSubviews.firstObject;
                    CHECK(fabs(NSMinX([label alignmentRectForFrame:label.frame])) < .01,
                          "property labels start at their group boundary without extra leading padding");
                }
                previous = group;
            }
            if (e.textEdit) {
                NSArray *children = e.textPropertiesCanvas.accessibilityChildren;
                for (MCSharedTextInputView *field in e.textPropertyInputs.allValues) {
                    CHECK(NSContainsRect(e.textPropertiesCanvas.bounds,field.frame), "shared numeric surface fits the actual property canvas");
                    CHECK([children containsObject:field] && [field.accessibilityRole isEqual:NSAccessibilityTextFieldRole],
                          "shared canvas exposes the real editable accessibility child once");
                    CHECK([[children filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(id item, NSDictionary *bindings) {
                        (void)bindings; return item == field;
                    }]] count] == 1, "field accessibility is not duplicated");
                }
            }
            MCColorSwatch *well = e.properties.colorControl.well;
            if (!e.textEdit && !e.properties.colorControl.hidden) {
                CHECK(NSWidth(well.frame) == editor_style_swatch_size() && NSHeight(well.frame) == editor_style_swatch_size(),
                      "light and dark swatches share a square drawing and input container");
                CHECK([well hitTest:NSMakePoint(NSMidX(well.frame), NSMidY(well.frame))] == well &&
                      [well hitTest:NSMakePoint(NSMinX(well.frame) + .5, NSMinY(well.frame) + .5)] == nil,
                      "the round color swatch accepts its center without an invisible corner hit area");
            }
            CHECK(previous && NSMaxX(previous.frame) <= NSWidth(e.properties.bounds) + .01,
                  "the last property fits the measured document width without a trailing gap");
            if (directory.length) {
                NSData *png = [toolbarPixels(e) representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
                [png writeToFile:[directory stringByAppendingPathComponent:
                    [NSString stringWithFormat:@"properties-%@-%lu.png", mode, (unsigned long)i]] atomically:YES];
            }
        }
    }
    [e cancel:nil];
    return passed;
}
static __weak id observedColorTarget;
static void (*originalColorTarget)(id, SEL, id);
static void observeColorTarget(id panel, SEL selector, id target) {
    observedColorTarget = target;
    originalColorTarget(panel, selector, target);
}
static void keepColorPanelHidden(id panel, SEL selector, id sender) {
    (void)panel; (void)selector; (void)sender;
}
static BOOL colorPanelLifetime(void) {
    BOOL passed = YES;
    // Exercise the real shared NSColorPanel binding, but prevent a visible
    // panel from interrupting the user while this isolated fixture runs.
    Method targetMethod = class_getInstanceMethod(NSColorPanel.class, @selector(setTarget:));
    originalColorTarget = (void (*)(id, SEL, id))method_setImplementation(targetMethod, (IMP)observeColorTarget);
    Method frontMethod = class_getInstanceMethod(NSColorPanel.class, @selector(orderFront:));
    IMP originalFront = method_getImplementation(frontMethod);
    const char *frontTypes = method_getTypeEncoding(frontMethod);
    class_replaceMethod(NSColorPanel.class, @selector(orderFront:), (IMP)keepColorPanelHidden, frontTypes);
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,500,100)
        styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
    MCColorControl *first = [[MCColorControl alloc] initWithFrame:NSZeroRect];
    MCColorControl *second = [[MCColorControl alloc] initWithFrame:NSZeroRect];
    [window.contentView addSubview:first]; [window.contentView addSubview:second];
    __block NSUInteger firstChanges = 0, secondChanges = 0;
    first.onChange = ^(__unused id sender) { firstChanges++; };
    second.onChange = ^(__unused id sender) { secondChanges++; };
    [first showColorPanel:nil];
    NSColorPanel *panel = NSColorPanel.sharedColorPanel;
    CHECK(observedColorTarget != nil && firstChanges == 0, "opening the system panel binds without changing a style");
    [second showColorPanel:nil];
    id router = observedColorTarget;
    second.color = [NSColor colorWithSRGBRed:.1 green:.8 blue:.2 alpha:.6];
    NSColor *rebound = [panel.color colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    CHECK(secondChanges == 0 && observedColorTarget == router && fabs(rebound.greenComponent - .8) < .001 &&
          fabs(rebound.alphaComponent - .6) < .001, "rebinding an open color panel stays synchronized without creating an edit");
    panel.color = [NSColor colorWithSRGBRed:.2 green:.4 blue:.8 alpha:.35];
    CHECK(firstChanges == 0 && observedColorTarget == router, "a former panel owner ignores a late color action");
    // NSColorPanel's color setter dispatches its real target/action. Do not
    // manually invoke the current owner and accidentally count the event twice.
    CHECK(secondChanges == 1 && fabs(second.color.alphaComponent - .35) < .001,
          "the current panel owner receives RGBA through its normal change callback");
    [first closePopover];
    CHECK(observedColorTarget == router, "closing a former owner does not detach the active panel owner");
    [second removeFromSuperview];
    CHECK(observedColorTarget == nil, "removing a property view detaches the system panel target");
    panel.color = [NSColor colorWithSRGBRed:.7 green:.2 blue:.3 alpha:.8];
    CHECK(secondChanges == 1, "a removed property view rejects a queued panel action");
    __weak MCColorControl *released;
    @autoreleasepool {
        MCColorControl *temporary = [[MCColorControl alloc] initWithFrame:NSZeroRect];
        [temporary showColorPanel:nil]; released = temporary;
        CHECK(observedColorTarget != nil, "a standalone color component can own the panel through its lease");
    }
    CHECK(released == nil && observedColorTarget == nil, "component deallocation clears its panel target without retaining it");
    NSStackView *content = (NSStackView *)first.popover.contentViewController.view;
    NSStackView *presets = (NSStackView *)content.arrangedSubviews.firstObject;
    MCColorSwatch *preset = (MCColorSwatch *)presets.arrangedSubviews.firstObject;
    [preset performClick:nil];
    CHECK(firstChanges == 1 && [preset.accessibilityRole isEqual:NSAccessibilityButtonRole] &&
          preset.accessibilityLabel.length > 0, "round palette buttons retain activation, accessibility and the change callback");
    [first closePopover]; [second closePopover];
    method_setImplementation(targetMethod, (IMP)originalColorTarget);
    class_replaceMethod(NSColorPanel.class, @selector(orderFront:), originalFront, frontTypes);
    return passed;
}
int main(void) {
    @autoreleasepool {
        [NSApplication sharedApplication]; [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
        moonbit_init();
        BOOL passed = interactions(); passed = validationAndFanout() && passed; passed = pinAction() && passed;
        passed = userActions() && passed;
        passed = declarativeComposite() && passed;
        passed = objectSelection(.5) && passed;
        passed = objectSelection(1.5) && passed;
        passed = toolbarAppearance() && passed;
        passed = sharedGestureCases() && passed;
        passed = shapeVariants() && passed;
        passed = propertySpacing() && passed;
        passed = colorPanelLifetime() && passed;
        puts(passed ? "PASS tool layout: stable bindings, styles, transactions, IME, pin/user actions, overflow and capture fanout" : "FAIL tool layout");
        return passed ? 0 : 1;
    }
}
