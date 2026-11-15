#import <AppKit/AppKit.h>
#import "plugins/feature/image_editor/macos/MCImageEditorController.h"
#import "components/style_controls/macos/MCStyleControls.h"
#include "moonbit.h"
#include <math.h>

// These are private interaction entry points, not an additional production API.
// All events stay inside this test's hidden window. No screen capture, global
// event posting, general clipboard writes, or interaction with other apps.
@interface MCImageCanvas : NSView
@property NSString *selectedID;
@property NSMutableDictionary *textDraft;
@property NSTextView *textView;
@property NSView *textHost;
- (NSRect)imageFrame;
- (NSDictionary *)selectedAnnotation;
- (void)beginEditingText:(NSDictionary *)annotation;
- (BOOL)finishTextEditing:(BOOL)commit;
- (void)deleteSelection;
@end

@interface MCImageEditorController (MCInlineTextTest)
@property (readonly) MCImageCanvas *canvas;
@property (readonly) NSSegmentedControl *tools;
@property (readonly) NSColorWell *color;
@property (readonly) MCColorControl *colorControl;
@property (readonly) NSTextField *fontSize;
@property (readonly) NSButton *confirmButton;
@property (readonly) NSButton *cancelButton;
- (void)prepareWindow;
- (void)chooseTool:(id)sender;
- (void)addTextAtPoint:(NSPoint)point;
- (void)styleChanged:(id)sender;
@end

#define CHECK(condition, message) do { \
    if (!(condition)) { fprintf(stderr, "FAIL inline text: %s\n", message); passed = NO; } \
} while (0)

static void selectTool(MCImageEditorController *editor, NSInteger kind) {
    for (NSInteger index = 0; index < editor.tools.segmentCount; index++) {
        if ([editor.tools tagForSegment:index] == kind) {
            editor.tools.selectedSegment = index;
            [editor chooseTool:editor.tools];
            return;
        }
    }
}

static MCImageEditorController *fixture(CGFloat scale, NSError **error) {
    NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc]
        initWithBitmapDataPlanes:NULL pixelsWide:800 pixelsHigh:500
        bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO
        colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:3200 bitsPerPixel:32];
    memset(bitmap.bitmapData, 255, bitmap.bytesPerRow * bitmap.pixelsHigh);
    NSData *png = [bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    MCImageEditorController *editor = [[MCImageEditorController alloc] initWithPNGData:png error:error];
    [editor prepareWindow];
    editor.canvas.frame = NSMakeRect(0, 48, 800 * scale + 32, 500 * scale + 32);
    selectTool(editor, 3);
    return editor;
}

static NSEvent *mouse(MCImageCanvas *canvas, NSEventType type, NSPoint imagePoint, NSInteger clicks) {
    NSRect frame = [canvas imageFrame];
    CGFloat scale = frame.size.width / 800.0;
    NSPoint viewPoint = NSMakePoint(frame.origin.x + imagePoint.x * scale,
                                   frame.origin.y + imagePoint.y * scale);
    return [NSEvent mouseEventWithType:type location:[canvas convertPoint:viewPoint toView:nil]
        modifierFlags:0 timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:canvas.window.windowNumber
        context:nil eventNumber:0 clickCount:clicks pressure:1];
}

static NSRect rect(NSDictionary *annotation) {
    return NSMakeRect([annotation[@"x"] doubleValue], [annotation[@"y"] doubleValue],
                     [annotation[@"width"] doubleValue], [annotation[@"height"] doubleValue]);
}

static BOOL near(CGFloat actual, CGFloat expected) { return fabs(actual - expected) < 0.01; }
static NSUInteger history(MCImageEditorController *editor) { return [editor.document[@"undo"] count]; }

static BOOL creationAndEditing(void) {
    BOOL passed = YES;
    NSError *error = nil;
    MCImageEditorController *editor = fixture(1, &error);
    CHECK(editor != nil, "fixture loads and constructs its editor");
    if (!editor) return NO;
    MCImageCanvas *canvas = editor.canvas;
    [editor addTextAtPoint:NSMakePoint(70, 60)];
    NSTextView *text = canvas.textView;
    CHECK(text != nil && editor.window.attachedSheet == nil, "adding text creates an inline editor without a sheet");
    if (!text) { [editor cancel:nil]; return NO; }
    CHECK(!editor.window.visible, "test window stays hidden");
    CHECK(editor.confirmButton.keyEquivalent.length == 0 && editor.cancelButton.keyEquivalent.length == 0,
          "window Return and Escape shortcuts do not steal text input");
    CHECK([editor.document[@"annotations"] count] == 0 && history(editor) == 0,
          "an unfinished input is a draft, not an undoable document mutation");

    // Exercise AppKit's marked-text replacement rather than assigning string:
    // candidates are not stored as a series of document edits.
    [text setMarkedText:@"zhongwen" selectedRange:NSMakeRange(8, 0)
        replacementRange:NSMakeRange(NSNotFound, 0)];
    CHECK(text.hasMarkedText, "marked IME input remains inside NSTextView");
    CHECK(history(editor) == 0, "IME composition does not create document undo entries");
    [text insertText:@"中文" replacementRange:NSMakeRange(NSNotFound, 0)];
    [text insertNewline:nil];
    [text insertText:@"第二行 👩🏽‍💻 ✅" replacementRange:NSMakeRange(NSNotFound, 0)];
    NSString *contents = @"中文\n第二行 👩🏽‍💻 ✅";
    CHECK([text.string isEqualToString:contents] && !text.hasMarkedText, "Chinese, multiline input and composed emoji are preserved");
    [editor undo:nil];
    CHECK(![text.string isEqualToString:contents] && history(editor) == 0,
          "undo during typing edits text instead of document history");
    [editor redo:nil];
    CHECK([text.string isEqualToString:contents] && history(editor) == 0,
          "redo during typing restores text without committing the draft");
    CHECK([canvas finishTextEditing:YES], "the draft commits successfully");
    CHECK(canvas.textView == nil && [editor.document[@"annotations"] count] == 1 && history(editor) == 1,
          "a completed text edit produces exactly one annotation and undo entry");
    NSDictionary *original = [editor.document[@"annotations"] firstObject];
    CHECK([original[@"text"] isEqualToString:contents], "committed MoonBit text matches the inline content");
    CHECK(editor.confirmButton.keyEquivalent.length > 0, "confirm keyboard shortcut returns outside text editing");

    [canvas beginEditingText:original];
    [canvas.textView selectAll:nil];
    [canvas.textView insertText:@"重新编辑\nHello 🌙" replacementRange:NSMakeRange(NSNotFound, 0)];
    editor.color.color = [NSColor colorWithSRGBRed:0.1 green:0.5 blue:0.9 alpha:1];
    [editor styleChanged:editor.color];
    editor.fontSize.doubleValue = 40;
    [editor styleChanged:editor.fontSize];
    CHECK([canvas.textView.string isEqualToString:@"重新编辑\nHello 🌙"], "style changes preserve current typing");
    CHECK([canvas finishTextEditing:YES], "re-editing commits successfully");
    NSDictionary *updated = [editor.document[@"annotations"] firstObject];
    CHECK([updated[@"id"] isEqual:original[@"id"]] && [editor.document[@"annotations"] count] == 1,
          "re-editing updates the existing text object");
    CHECK([updated[@"text"] isEqualToString:@"重新编辑\nHello 🌙"] && [updated[@"fontSize"] doubleValue] == 40,
          "content and font size reach the shared document");
    CHECK([updated[@"color"] isEqualToString:@"#1a80e6"], "chosen text color reaches the shared document");
    CHECK(history(editor) == 2, "typing and style changes during an edit are a single undo step");
    [editor undo:nil];
    CHECK([[editor.document[@"annotations"] firstObject] isEqual:original], "undo restores the original text and style together");
    [editor redo:nil];
    CHECK([[editor.document[@"annotations"] firstObject] isEqual:updated], "redo restores the completed text edit");

    // Export must contain only document content, independent of selection UI.
    canvas.selectedID = updated[@"id"];
    NSData *selectedPNG = [editor renderPNGData:&error];
    canvas.selectedID = nil;
    NSData *plainPNG = [editor renderPNGData:&error];
    CHECK(selectedPNG.length > 0 && [selectedPNG isEqualToData:plainPNG], "selection outlines and handles never enter PNG export");
    NSPasteboard *pasteboard = [NSPasteboard pasteboardWithUniqueName];
    CHECK([editor copyToPasteboard:pasteboard error:&error], "confirmed text exports to a private clipboard");
    NSBitmapImageRep *result = [NSBitmapImageRep imageRepWithData:[pasteboard dataForType:NSPasteboardTypePNG]];
    CHECK(result.pixelsWide == 800 && result.pixelsHigh == 500, "clipboard keeps full source resolution");
    NSUInteger coloredPixels = 0;
    for (NSInteger y = 40; y < 240; y++) for (NSInteger x = 50; x < 550; x++) {
        NSColor *pixel = [[result colorAtX:x y:y] colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
        if (pixel.blueComponent > 0.7 && pixel.redComponent < 0.6) coloredPixels++;
    }
    CHECK(coloredPixels > 100, "export actually contains the edited colored glyphs");
    [pasteboard releaseGlobally];
    [editor cancel:nil];
    return passed;
}

static BOOL manipulationAtScale(CGFloat scale) {
    BOOL passed = YES;
    NSError *error = nil;
    MCImageEditorController *editor = fixture(scale, &error);
    CHECK(editor != nil, "scaled fixture loads");
    if (!editor) return NO;
    NSDictionary *annotation = @{@"id":@"movable", @"type":@"text", @"text":@"拖动文字 🌙",
        @"x":@80, @"y":@80, @"width":@240, @"height":@80,
        @"fontSize":@28, @"stroke":@3, @"opacity":@1, @"color":@"#dd2222"};
    CHECK([editor applyAnnotation:annotation], "fixture text is valid");
    MCImageCanvas *canvas = editor.canvas;
    canvas.selectedID = @"movable";
    NSUInteger before = history(editor);
    NSPoint start = NSMakePoint(160, 110), end = NSMakePoint(210, 145);
    [canvas mouseDown:mouse(canvas, NSEventTypeLeftMouseDown, start, 1)];
    [canvas mouseDragged:mouse(canvas, NSEventTypeLeftMouseDragged, NSMakePoint(185, 125), 1)];
    [canvas mouseDragged:mouse(canvas, NSEventTypeLeftMouseDragged, end, 1)];
    CHECK(history(editor) == before, "drag previews do not create document history entries");
    [canvas mouseUp:mouse(canvas, NSEventTypeLeftMouseUp, end, 1)];
    NSDictionary *moved = [canvas selectedAnnotation];
    NSRect movedRect = rect(moved);
    CHECK(near(movedRect.origin.x, 130) && near(movedRect.origin.y, 115), "drag maps view points to the same image coordinates at any zoom");
    CHECK(history(editor) == before + 1 && [editor.document[@"annotations"] count] == 1,
          "a drag commits one move without duplicating the object");
    CHECK(canvas.textView == nil, "single-click dragging does not enter text editing");

    before = history(editor);
    NSPoint corner = NSMakePoint(NSMaxX(movedRect), NSMaxY(movedRect));
    NSPoint resizedCorner = NSMakePoint(corner.x + movedRect.size.width * 0.25,
                                       corner.y + movedRect.size.height * 0.25);
    [canvas mouseDown:mouse(canvas, NSEventTypeLeftMouseDown, corner, 1)];
    [canvas mouseDragged:mouse(canvas, NSEventTypeLeftMouseDragged, resizedCorner, 1)];
    CHECK(history(editor) == before, "resize preview does not flood undo history");
    [canvas mouseUp:mouse(canvas, NSEventTypeLeftMouseUp, resizedCorner, 1)];
    NSDictionary *resized = [canvas selectedAnnotation];
    NSRect resizedRect = rect(resized);
    CHECK(near(resizedRect.origin.x, movedRect.origin.x) && near(resizedRect.origin.y, movedRect.origin.y) &&
          near(resizedRect.size.width, movedRect.size.width * 1.25) && near(resizedRect.size.height, movedRect.size.height * 1.25) &&
          near([resized[@"fontSize"] doubleValue], [moved[@"fontSize"] doubleValue] * 1.25),
          "bottom-right handle scales both the text box and font in image coordinates");
    CHECK(history(editor) == before + 1, "resize commits one undoable change");
    [editor undo:nil];
    CHECK([[editor.document[@"annotations"] firstObject] isEqual:moved], "one undo restores the box before resizing");
    [editor redo:nil];
    CHECK([[editor.document[@"annotations"] firstObject] isEqual:resized], "redo restores the resized text box");

    // Side handles reflow without changing font size, unlike corner scaling.
    before = history(editor);
    NSPoint rightMiddle = NSMakePoint(NSMaxX(resizedRect), NSMidY(resizedRect));
    NSPoint narrower = NSMakePoint(rightMiddle.x - resizedRect.size.width * 0.5, rightMiddle.y);
    [canvas mouseDown:mouse(canvas, NSEventTypeLeftMouseDown, rightMiddle, 1)];
    [canvas mouseDragged:mouse(canvas, NSEventTypeLeftMouseDragged, narrower, 1)];
    [canvas mouseUp:mouse(canvas, NSEventTypeLeftMouseUp, narrower, 1)];
    NSDictionary *reflowed = [canvas selectedAnnotation];
    CHECK(near([reflowed[@"width"] doubleValue], resizedRect.size.width * 0.5) &&
          near([reflowed[@"fontSize"] doubleValue], [resized[@"fontSize"] doubleValue]) && history(editor) == before + 1,
          "side resize reflows the text at the same font size in one undo step");
    [editor undo:nil];
    CHECK([[editor.document[@"annotations"] firstObject] isEqual:resized], "undo restores the box before reflow");

    NSPoint center = NSMakePoint(NSMidX(resizedRect), NSMidY(resizedRect));
    [canvas mouseDown:mouse(canvas, NSEventTypeLeftMouseDown, center, 2)];
    CHECK(canvas.textView != nil && [canvas.textView.string isEqualToString:annotation[@"text"]],
          "double-click enters editing for the existing object");
    [canvas.textView selectAll:nil];
    [canvas.textView insertText:@"取消的修改" replacementRange:NSMakeRange(NSNotFound, 0)];
    before = history(editor);
    CHECK([canvas finishTextEditing:NO], "cancel exits inline editing");
    CHECK(history(editor) == before && [[editor.document[@"annotations"] firstObject] isEqual:resized],
          "cancel preserves the original text and history");
    canvas.selectedID = @"movable";
    [canvas deleteSelection];
    CHECK([editor.document[@"annotations"] count] == 0 && history(editor) == before + 1,
          "deleting a selected text object is undoable");
    [editor undo:nil];
    CHECK([[editor.document[@"annotations"] firstObject] isEqual:resized], "undo restores a deleted text object");
    [editor cancel:nil];
    return passed;
}

static BOOL emptyAndCancelledInput(void) {
    BOOL passed = YES;
    NSError *error = nil;
    MCImageEditorController *editor = fixture(1, &error);
    if (!editor) return NO;
    [editor addTextAtPoint:NSMakePoint(30, 30)];
    CHECK([editor.canvas finishTextEditing:YES], "leaving an empty draft succeeds without adding text");
    CHECK([editor.document[@"annotations"] count] == 0 && history(editor) == 0,
          "empty text does not create an annotation or undo entry");
    [editor addTextAtPoint:NSMakePoint(30, 30)];
    [editor.canvas.textView insertText:@"不要保留" replacementRange:NSMakeRange(NSNotFound, 0)];
    CHECK([editor.canvas finishTextEditing:NO], "a new text draft can be cancelled");
    CHECK([editor.document[@"annotations"] count] == 0 && history(editor) == 0,
          "cancelled text does not enter the document");
    [editor cancel:nil];
    return passed;
}

// Compare live composition with exported pixels: translucent covers must be
// applied once even where a native inline editor overlaps their background.
static BOOL rgbaStyles(void) {
    BOOL passed = YES;
    NSError *error = nil;
    MCImageEditorController *editor = fixture(1, &error);
    MCImageCanvas *canvas = editor.canvas;
    selectTool(editor, 4);
    editor.colorControl.color = [NSColor colorWithSRGBRed:0 green:1 blue:0 alpha:1];
    [editor.color sendAction:editor.color.action to:editor.color.target];
    editor.colorControl.opacityControl.stepper.doubleValue = 25;
    NSStepper *opacityStepper = editor.colorControl.opacityControl.stepper;
    [opacityStepper sendAction:opacityStepper.action to:opacityStepper.target];
    [canvas mouseDown:mouse(canvas, NSEventTypeLeftMouseDown, NSMakePoint(20, 20), 1)];
    [canvas mouseDragged:mouse(canvas, NSEventTypeLeftMouseDragged, NSMakePoint(320, 120), 1)];
    [canvas mouseUp:mouse(canvas, NSEventTypeLeftMouseUp, NSMakePoint(320, 120), 1)];
    NSDictionary *cover = [editor.document[@"annotations"] firstObject];
    CHECK([cover[@"color"] isEqual:@"#00ff00"] && near([cover[@"opacity"] doubleValue], .25),
          "shared color component commits colored translucent fill to MoonBit");
    NSBitmapImageRep *exported = [NSBitmapImageRep imageRepWithData:[editor renderPNGData:&error]];
    NSColor *pixel = [[exported colorAtX:250 y:50] colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    // Device RGB profiles differ; this range still rejects opaque or twice-blended fills.
    CHECK(pixel.redComponent > .70 && pixel.redComponent < .85 && pixel.greenComponent > .95 && pixel.blueComponent > .70 && pixel.blueComponent < .85,
          "export blends a 25 percent green cover over white instead of forcing black/opaque");
    selectTool(editor, 3);
    editor.colorControl.color = [NSColor colorWithSRGBRed:1 green:0 blue:0 alpha:.5];
    [editor.color sendAction:editor.color.action to:editor.color.target];
    [editor addTextAtPoint:NSMakePoint(30, 30)];
    [canvas.textView insertText:@"A" replacementRange:NSMakeRange(NSNotFound, 0)];
    CHECK(near([canvas.textDraft[@"opacity"] doubleValue], .5), "new text uses the shared color alpha");
    NSRect frame = canvas.imageFrame;
    [canvas layoutSubtreeIfNeeded];
    NSBitmapImageRep *live = [canvas bitmapImageRepForCachingDisplayInRect:canvas.bounds];
    [canvas cacheDisplayInRect:canvas.bounds toBitmapImageRep:live];
    CGFloat backing = live.pixelsWide / NSWidth(canvas.bounds);
    NSInteger x = (frame.origin.x + 250 * frame.size.width / 800) * backing;
    NSInteger y = (frame.origin.y + 50 * frame.size.height / 500) * backing;
    NSColor *livePixel = [[live colorAtX:x y:y] colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    CHECK(fabs(livePixel.redComponent - pixel.redComponent) < .03 && fabs(livePixel.blueComponent - pixel.blueComponent) < .03,
          "translucent cover is composited once behind and above the native inline editor");
    [canvas finishTextEditing:YES];
    NSDictionary *text = editor.document[@"annotations"][1];
    CHECK(near([text[@"opacity"] doubleValue], .5), "text alpha survives inline commit");
    [editor undo:nil];
    CHECK([editor.document[@"annotations"] count] == 1 && near([editor.document[@"annotations"][0][@"opacity"] doubleValue], .25),
          "undoing text preserves the previous cover color and opacity");
    [editor cancel:nil];
    return passed;
}

int main(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
        moonbit_init();
        BOOL passed = creationAndEditing();
        passed = manipulationAtScale(0.5) && passed;
        passed = manipulationAtScale(1.5) && passed;
        passed = emptyAndCancelledInput() && passed;
        passed = rgbaStyles() && passed;
        puts(passed ? "PASS inline text: hidden AppKit editor, IME/multiline, re-edit/style, scaled drag/resize, undo and PNG clipboard"
                    : "FAIL inline text interaction");
        return passed ? 0 : 1;
    }
}
