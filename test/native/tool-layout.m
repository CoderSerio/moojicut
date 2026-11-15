#import <AppKit/AppKit.h>
#import "plugins/feature/image_editor/macos/MCImageEditorController.h"
#import "plugins/feature/capture/macos/MCCaptureController.h"
#import "components/style_controls/macos/MCStylePropertiesView.h"
#include "moonbit.h"
#include <math.h>

// Hidden synthetic windows only: no real capture, system clipboard or events.
@interface MCImageCanvas : NSView
@property NSTextView *textView;
- (NSRect)imageFrame;
@end
@interface MCImageEditorController (MCToolLayoutTest)
@property (readonly) MCImageCanvas *canvas;
@property (readonly) NSSegmentedControl *tools;
@property (readonly) NSInteger activeTool;
@property (readonly) MCStylePropertiesView *properties;
- (void)prepareWindow;
- (void)chooseTool:(id)sender;
@end
@interface MCCaptureController (MCToolLayoutTest)
- (MCImageEditorController *)editorForSnapshot:(NSDictionary *)snapshot error:(NSError **)error;
@end
#define CHECK(c, message) do { if (!(c)) { fprintf(stderr, "FAIL tool layout: %s\n", message); passed = NO; } } while (0)

static NSDictionary *configuration(NSArray<NSNumber *> *order, NSSet<NSNumber *> *disabled) {
    NSArray *ids = @[@"builtin.image.rectangle", @"builtin.image.arrow", @"builtin.image.text", @"builtin.image.cover"];
    NSArray *titles = @[@"矩形", @"箭头", @"文字", @"遮挡"];
    NSMutableArray *entries = [NSMutableArray array];
    for (NSNumber *kind in order) [entries addObject:@{@"id":ids[kind.integerValue - 1], @"kind":kind,
        @"title":titles[kind.integerValue - 1], @"enabled":@(![disabled containsObject:kind])}];
    return @{@"ok":@YES, @"layout":@{}, @"groups":@{@"screenshot":entries, @"recording":@[], @"videoEditing":@[]}};
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
    editor.tools.selectedSegment = segment(editor, kind);
    [editor.tools sendAction:editor.tools.action to:editor.tools.target];
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
    editor.properties.colorControl.color = color;
    NSColorWell *well = editor.properties.colorControl.well;
    [well sendAction:well.action to:well.target];
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
    NSStepper *font = e.properties.fontControl.stepper;
    font.doubleValue = 36; [font sendAction:font.action to:font.target];
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
    NSDictionary *none = configuration(@[@4,@3,@2,@1], [NSSet setWithArray:@[@1,@2,@3,@4]]);
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
    second.canvas.textView.string = [@"x" stringByPaddingToLength:10001 withString:@"x" startingAtIndex:0];
    CHECK(![capture canApplyToolConfiguration:none error:NULL] && second.canvas.textView.string.length == 10001,
          "MoonBit text validation failure retains the full uncommitted input");
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
int main(void) {
    @autoreleasepool {
        [NSApplication sharedApplication]; [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
        moonbit_init();
        BOOL passed = interactions(); passed = validationAndFanout() && passed;
        puts(passed ? "PASS tool layout: stable bindings, styles, transactions, IME and capture fanout" : "FAIL tool layout");
        return passed ? 0 : 1;
    }
}
