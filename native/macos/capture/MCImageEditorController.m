#import "MCImageEditorController.h"
#import "../MCChromeTheme.h"
#import "../MCIcon.h"
#include "moonbit.h"
#include <math.h>

extern moonbit_string_t image_create(moonbit_string_t);
extern moonbit_string_t image_apply(moonbit_string_t);
extern moonbit_string_t image_finalize(moonbit_string_t);

static NSError *MCEditorError(NSString *message) {
    return [NSError errorWithDomain:@"dev.moojicut.image-editor" code:1 userInfo:@{NSLocalizedDescriptionKey:message}];
}
static NSDictionary *MCCallImage(moonbit_string_t (*function)(moonbit_string_t), NSDictionary *request, NSError **error) {
    NSData *bytes = [NSJSONSerialization dataWithJSONObject:request options:0 error:error];
    if (!bytes) return nil;
    NSString *json = [[NSString alloc] initWithData:bytes encoding:NSUTF8StringEncoding];
    if (json.length > INT32_MAX) { if (error) *error = MCEditorError(@"标注内容过大。"); return nil; }
    moonbit_string_t input = moonbit_make_string_raw((int32_t)json.length);
    [json getCharacters:input range:NSMakeRange(0, json.length)];
    moonbit_string_t output = function(input);
    moonbit_decref(input);
    NSString *text = [[NSString alloc] initWithCharacters:output length:(NSUInteger)Moonbit_array_length(output)];
    moonbit_decref(output);
    id value = [NSJSONSerialization JSONObjectWithData:[text dataUsingEncoding:NSUTF8StringEncoding] options:0 error:error];
    if (![value isKindOfClass:NSDictionary.class] || ![value[@"ok"] boolValue]) {
        if (error) *error = MCEditorError([value isKindOfClass:NSDictionary.class] ? (value[@"error"][@"message"] ?: @"MoonBit 无法应用标注。") : @"无法读取编辑结果。");
        return nil;
    }
    return value[@"document"];
}
static NSColor *MCAnnotationColor(NSDictionary *annotation) {
    unsigned int rgb = 0;
    NSString *hex = annotation[@"color"] ?: @"#ef4444";
    if (hex.length == 7) [[NSScanner scannerWithString:[hex substringFromIndex:1]] scanHexInt:&rgb];
    return [NSColor colorWithSRGBRed:((rgb >> 16) & 255) / 255.0 green:((rgb >> 8) & 255) / 255.0
                              blue:(rgb & 255) / 255.0 alpha:[annotation[@"opacity"] doubleValue]];
}
static NSRect MCAnnotationRect(NSDictionary *annotation) {
    return NSMakeRect([annotation[@"x"] doubleValue], [annotation[@"y"] doubleValue],
                      [annotation[@"width"] doubleValue], [annotation[@"height"] doubleValue]);
}
static NSDictionary *MCTextAttributes(NSDictionary *annotation) {
    NSMutableParagraphStyle *paragraph = [NSMutableParagraphStyle new];
    paragraph.lineBreakMode = NSLineBreakByWordWrapping;
    return @{ NSFontAttributeName:[NSFont systemFontOfSize:[annotation[@"fontSize"] doubleValue] weight:NSFontWeightSemibold],
              NSForegroundColorAttributeName:MCAnnotationColor(annotation), NSParagraphStyleAttributeName:paragraph };
}
// The editor and PNG export use the same TextKit layout, without field-editor padding.
static NSLayoutManager *MCTextLayout(NSDictionary *annotation, NSTextStorage **storage) {
    *storage = [[NSTextStorage alloc] initWithString:annotation[@"text"] ?: @"" attributes:MCTextAttributes(annotation)];
    NSLayoutManager *layout = [NSLayoutManager new];
    NSTextContainer *container = [[NSTextContainer alloc] initWithContainerSize:NSMakeSize(MAX(1, [annotation[@"width"] doubleValue]), CGFLOAT_MAX)];
    container.lineFragmentPadding = 0;
    [layout addTextContainer:container];
    [*storage addLayoutManager:layout];
    [layout ensureLayoutForTextContainer:container];
    return layout;
}
static CGFloat MCTextHeight(NSDictionary *annotation) {
    NSTextStorage *storage;
    NSLayoutManager *layout = MCTextLayout(annotation, &storage);
    CGFloat height = NSMaxY([layout usedRectForTextContainer:layout.textContainers.firstObject]);
    if (layout.extraLineFragmentTextContainer) height = MAX(height, NSMaxY(layout.extraLineFragmentRect));
    return ceil(MAX(height, [annotation[@"fontSize"] doubleValue] * 1.25));
}
static void MCDrawAnnotation(NSDictionary *annotation) {
    NSString *kind = annotation[@"type"];
    NSRect rect = NSMakeRect([annotation[@"x"] doubleValue], [annotation[@"y"] doubleValue],
                             [annotation[@"width"] doubleValue], [annotation[@"height"] doubleValue]);
    NSColor *color = MCAnnotationColor(annotation);
    CGFloat stroke = [annotation[@"stroke"] doubleValue];
    if ([kind isEqualToString:@"redact"]) {
        // A cover is always solid black and is rendered after every other annotation.
        [NSColor.blackColor setFill];
        NSRectFill(rect);
    } else if ([kind isEqualToString:@"rect"]) {
        [color setStroke];
        NSBezierPath *path = [NSBezierPath bezierPathWithRect:rect];
        path.lineWidth = stroke;
        [path stroke];
    } else if ([kind isEqualToString:@"arrow"]) {
        NSPoint start = rect.origin, end = NSMakePoint([annotation[@"x2"] doubleValue], [annotation[@"y2"] doubleValue]);
        CGFloat angle = atan2(end.y - start.y, end.x - start.x);
        CGFloat head = MIN(hypot(end.x - start.x, end.y - start.y) * 0.45, MAX(14, stroke * 3.5));
        NSBezierPath *path = [NSBezierPath bezierPath];
        path.lineWidth = stroke;
        path.lineCapStyle = NSLineCapStyleRound;
        path.lineJoinStyle = NSLineJoinStyleRound;
        [path moveToPoint:start]; [path lineToPoint:end];
        [path moveToPoint:NSMakePoint(end.x - head * cos(angle - 0.5), end.y - head * sin(angle - 0.5))];
        [path lineToPoint:end];
        [path lineToPoint:NSMakePoint(end.x - head * cos(angle + 0.5), end.y - head * sin(angle + 0.5))];
        [color setStroke]; [path stroke];
    } else if ([kind isEqualToString:@"text"]) {
        NSTextStorage *storage;
        NSLayoutManager *layout = MCTextLayout(annotation, &storage);
        [NSGraphicsContext saveGraphicsState];
        NSRectClip(rect);
        [layout drawGlyphsForGlyphRange:[layout glyphRangeForTextContainer:layout.textContainers.firstObject] atPoint:rect.origin];
        [NSGraphicsContext restoreGraphicsState];
    }
}
static void MCDrawImage(NSImage *image, NSDictionary *document, NSDictionary *pending) {
    NSRect rect = NSMakeRect(0, 0, [document[@"width"] doubleValue], [document[@"height"] doubleValue]);
    [NSGraphicsContext saveGraphicsState];
    NSRectClip(rect);
    [image drawInRect:rect fromRect:NSZeroRect operation:NSCompositingOperationCopy fraction:1 respectFlipped:YES hints:nil];
    NSArray *annotations = document[@"annotations"];
    for (NSDictionary *annotation in annotations) if (![annotation[@"type"] isEqualToString:@"redact"]) MCDrawAnnotation(annotation);
    if (pending && ![pending[@"type"] isEqualToString:@"redact"]) MCDrawAnnotation(pending);
    for (NSDictionary *annotation in annotations) if ([annotation[@"type"] isEqualToString:@"redact"]) MCDrawAnnotation(annotation);
    if ([pending[@"type"] isEqualToString:@"redact"]) MCDrawAnnotation(pending);
    [NSGraphicsContext restoreGraphicsState];
}

typedef NS_ENUM(NSInteger, MCImageTool) { MCSelectTool, MCRectTool, MCArrowTool, MCTextTool, MCRedactTool };
@interface MCImageEditorWindow : NSWindow
@end
@implementation MCImageEditorWindow
- (BOOL)canBecomeKeyWindow { return YES; }
@end
@class MCImageCanvas;
@interface MCImageEditorController ()
@property (nonatomic, readwrite) NSWindow *window;
@property (nonatomic, readwrite) NSDictionary *document;
@property NSImage *image;
@property MCImageCanvas *canvas;
@property NSSegmentedControl *tools;
@property NSColorWell *color;
@property NSButton *undoButton;
@property NSButton *redoButton;
@property NSButton *confirmButton;
@property NSButton *cancelButton;
@property NSTextField *fontSize;
@property NSStepper *fontStepper;
@property NSTextField *status;
@property NSStackView *toolbar;
@property NSButton *pinButton;
@property NSVisualEffectView *floatingToolbar;
@property BOOL overlayMode;
@property BOOL hasCaptureRegion;
- (void)prepareWindow;
- (void)refresh;
- (BOOL)applyCommand:(NSDictionary *)command;
- (void)showError:(NSError *)error;
- (NSString *)colorHex;
- (void)syncTextControls;
- (void)styleChanged:(id)sender;
- (void)positionFloatingToolbar;
- (BOOL)setCaptureRegion:(NSRect)rect;
- (void)pinImage:(id)sender;
- (void)chooseTool:(id)sender;
- (NSDictionary *)annotationFrom:(NSPoint)start to:(NSPoint)end;
- (void)addTextAtPoint:(NSPoint)point;
- (void)confirm:(id)sender;
@end

@interface MCInlineTextView : NSTextView
@property (weak) MCImageCanvas *canvas;
@property NSUndoManager *textUndo;
@end

@interface MCImageCanvas : NSView <NSTextViewDelegate>
@property (weak) MCImageEditorController *editor;
@property NSPoint start;
@property NSDictionary *pending;
@property BOOL dragging;
@property NSString *selectedID;
@property NSMutableDictionary *textDraft;
@property MCInlineTextView *textView;
@property NSView *textHost;
@property NSDictionary *transformOriginal;
@property NSDictionary *transformPreview;
@property NSInteger resizeHandle;
@property BOOL regionDragging;
@property NSRect regionOriginal;
@property NSRect regionPreview;
@property NSInteger regionHandle;
- (NSPoint)imagePoint:(NSEvent *)event;
- (NSRect)imageFrame;
- (NSDictionary *)selectedAnnotation;
- (void)beginEditingText:(NSDictionary *)annotation;
- (BOOL)finishTextEditing:(BOOL)commit;
- (void)updateTextFrame;
- (void)deleteSelection;
- (void)cancelGesture;
@end

@implementation MCInlineTextView
- (NSUndoManager *)undoManager {
    if (!self.textUndo) self.textUndo = [NSUndoManager new];
    return self.textUndo;
}
- (BOOL)performKeyEquivalent:(NSEvent *)event {
    NSEventModifierFlags flags = event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
    if ((flags & NSEventModifierFlagCommand) && [event.charactersIgnoringModifiers.lowercaseString isEqualToString:@"z"]) {
        if (self.hasMarkedText) return [super performKeyEquivalent:event];
        if (flags & NSEventModifierFlagShift) [self.undoManager redo]; else [self.undoManager undo];
        return YES;
    }
    if (event.keyCode == 36 && (flags & NSEventModifierFlagCommand) && !self.hasMarkedText) {
        [self.canvas finishTextEditing:YES];
        return YES;
    }
    return [super performKeyEquivalent:event];
}
- (void)keyDown:(NSEvent *)event {
    if (event.keyCode == 53 && !self.hasMarkedText) { [self.canvas finishTextEditing:NO]; return; }
    [super keyDown:event];
}
- (void)cancelOperation:(id)sender {
    (void)sender;
    if (self.hasMarkedText) [self unmarkText];
    else [self.canvas finishTextEditing:NO];
}
- (void)drawRect:(NSRect)dirtyRect {
    [NSGraphicsContext saveGraphicsState];
    NSDictionary *draft = self.canvas.textDraft;
    NSRect crop = MCAnnotationRect(self.canvas.editor.document[@"viewport"]);
    crop.origin.x -= [draft[@"x"] doubleValue];
    crop.origin.y -= [draft[@"y"] doubleValue];
    NSRectClip(NSIntersectionRect(crop, self.bounds));
    [super drawRect:dirtyRect];
    // An active text editor must not paint over a privacy cover.
    for (NSDictionary *annotation in self.canvas.editor.document[@"annotations"]) {
        if (![annotation[@"type"] isEqual:@"redact"]) continue;
        NSRect cover = MCAnnotationRect(annotation);
        cover.origin.x -= [draft[@"x"] doubleValue];
        cover.origin.y -= [draft[@"y"] doubleValue];
        [NSColor.blackColor setFill];
        NSRectFill(NSIntersectionRect(cover, self.bounds));
    }
    [NSGraphicsContext restoreGraphicsState];
}
@end

@implementation MCImageCanvas
- (BOOL)isFlipped { return YES; }
- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)acceptsFirstMouse:(NSEvent *)event { (void)event; return YES; }
- (NSRect)imageFrame {
    if (self.editor.overlayMode) return self.bounds;
    CGFloat width = [self.editor.document[@"width"] doubleValue], height = [self.editor.document[@"height"] doubleValue];
    CGFloat scale = MIN((self.bounds.size.width - 32) / width, (self.bounds.size.height - 32) / height);
    scale = MAX(0.01, scale);
    return NSMakeRect((self.bounds.size.width - width * scale) / 2, (self.bounds.size.height - height * scale) / 2, width * scale, height * scale);
}
- (NSRect)captureRect {
    if (self.regionDragging) return self.regionPreview;
    return self.editor.hasCaptureRegion ? MCAnnotationRect(self.editor.document[@"viewport"]) : NSZeroRect;
}
- (NSRect)viewRectForImageRect:(NSRect)rect {
    NSRect image = [self imageFrame];
    CGFloat scale = image.size.width / [self.editor.document[@"width"] doubleValue];
    return NSMakeRect(image.origin.x + rect.origin.x * scale, image.origin.y + rect.origin.y * scale,
                      rect.size.width * scale, rect.size.height * scale);
}
- (NSInteger)captureHandleAtPoint:(NSPoint)point {
    if (!self.editor.overlayMode || !self.editor.hasCaptureRegion) return -1;
    NSRect frame = [self viewRectForImageRect:[self captureRect]];
    for (NSInteger handle = 0; handle < 8; handle++) {
        NSPoint center = [self handlePoint:handle inRect:frame];
        if (NSPointInRect(point, NSMakeRect(center.x - 6, center.y - 6, 12, 12))) return handle;
    }
    return -1;
}
- (NSPoint)imagePoint:(NSEvent *)event {
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    NSRect frame = [self imageFrame];
    CGFloat scale = frame.size.width / [self.editor.document[@"width"] doubleValue];
    return NSMakePoint(MAX(0, MIN([self.editor.document[@"width"] doubleValue], (point.x - frame.origin.x) / scale)),
                       MAX(0, MIN([self.editor.document[@"height"] doubleValue], (point.y - frame.origin.y) / scale)));
}
- (NSDictionary *)selectedAnnotation {
    if (self.transformPreview) return self.transformPreview;
    if (self.textDraft) return self.textDraft;
    for (NSDictionary *annotation in self.editor.document[@"annotations"])
        if ([annotation[@"id"] isEqual:self.selectedID]) return annotation;
    return nil;
}
- (NSRect)selectionFrame {
    NSDictionary *annotation = [self selectedAnnotation];
    if (!annotation) return NSZeroRect;
    NSRect image = [self imageFrame], rect = MCAnnotationRect(annotation);
    CGFloat scale = image.size.width / [self.editor.document[@"width"] doubleValue];
    return NSMakeRect(image.origin.x + rect.origin.x * scale, image.origin.y + rect.origin.y * scale,
                      rect.size.width * scale, rect.size.height * scale);
}
- (NSPoint)handlePoint:(NSInteger)handle inRect:(NSRect)rect {
    static const CGFloat xs[] = {0, .5, 1, 1, 1, .5, 0, 0};
    static const CGFloat ys[] = {0, 0, 0, .5, 1, 1, 1, .5};
    return NSMakePoint(rect.origin.x + xs[handle] * rect.size.width, rect.origin.y + ys[handle] * rect.size.height);
}
- (NSInteger)handleAtPoint:(NSPoint)point {
    if (![self selectedAnnotation]) return -1;
    NSRect frame = [self selectionFrame];
    for (NSInteger handle = 0; handle < 8; handle++) {
        NSPoint center = [self handlePoint:handle inRect:frame];
        if (NSPointInRect(point, NSMakeRect(center.x - 6, center.y - 6, 12, 12))) return handle;
    }
    return -1;
}
- (BOOL)selectionBorderAtPoint:(NSPoint)point {
    NSRect frame = [self selectionFrame];
    return [self selectedAnnotation] && NSPointInRect(point, NSInsetRect(frame, -5, -5)) &&
        !NSPointInRect(point, NSInsetRect(frame, 5, 5));
}
- (NSView *)hitTest:(NSPoint)point {
    NSPoint local = [self convertPoint:point fromView:self.superview];
    if ([self handleAtPoint:local] >= 0 || [self selectionBorderAtPoint:local]) return self;
    return [super hitTest:point];
}
- (void)resetCursorRects {
    [super resetCursorRects];
    if (self.editor.overlayMode) {
        [self addCursorRect:self.bounds cursor:NSCursor.crosshairCursor];
        if (self.editor.hasCaptureRegion) {
            NSRect region = [self viewRectForImageRect:[self captureRect]];
            [self addCursorRect:region cursor:self.editor.tools.selectedSegment == MCTextTool ? NSCursor.IBeamCursor : NSCursor.crosshairCursor];
            for (NSInteger handle = 0; handle < 8; handle++) {
                NSPoint center = [self handlePoint:handle inRect:region];
                [self addCursorRect:NSMakeRect(center.x - 6, center.y - 6, 12, 12) cursor:NSCursor.crosshairCursor];
            }
        }
    }
    if (![self selectedAnnotation]) return;
    NSRect frame = [self selectionFrame];
    [self addCursorRect:NSInsetRect(frame, -4, -4) cursor:NSCursor.openHandCursor];
    if (self.textView) [self addCursorRect:NSInsetRect(frame, 6, 6) cursor:NSCursor.IBeamCursor];
    for (NSInteger handle = 0; handle < 8; handle++) {
        NSPoint center = [self handlePoint:handle inRect:frame];
        NSCursor *cursor = (handle == 1 || handle == 5) ? NSCursor.resizeUpDownCursor :
            (handle == 3 || handle == 7) ? NSCursor.resizeLeftRightCursor : NSCursor.crosshairCursor;
        [self addCursorRect:NSMakeRect(center.x - 6, center.y - 6, 12, 12) cursor:cursor];
    }
}
- (void)setFrameSize:(NSSize)size {
    [super setFrameSize:size];
    [self updateTextFrame];
}
- (void)updateTextFrame {
    if (self.textView) {
        NSRect rect = MCAnnotationRect(self.textDraft);
        // Scale the view coordinate system instead of changing font metrics.
        // Text wrapping consequently matches the exported image at every zoom.
        self.textHost.frame = [self selectionFrame];
        self.textHost.bounds = NSMakeRect(0, 0, rect.size.width, rect.size.height);
        self.textView.frame = self.textHost.bounds;
        self.textView.textContainer.containerSize = NSMakeSize(rect.size.width, CGFLOAT_MAX);
    }
    self.needsDisplay = YES;
    [self.window invalidateCursorRectsForView:self];
}
- (void)beginEditingText:(NSDictionary *)annotation {
    if (![self finishTextEditing:YES]) return;
    self.selectedID = annotation[@"id"];
    self.textDraft = [annotation mutableCopy];
    self.textHost = [[NSView alloc] initWithFrame:NSZeroRect];
    self.textView = [[MCInlineTextView alloc] initWithFrame:NSZeroRect];
    self.textView.canvas = self;
    self.textView.delegate = self;
    self.textView.richText = NO;
    self.textView.importsGraphics = NO;
    self.textView.drawsBackground = NO;
    self.textView.textContainerInset = NSZeroSize;
    self.textView.textContainer.lineFragmentPadding = 0;
    self.textView.textContainer.widthTracksTextView = YES;
    self.textView.textContainer.heightTracksTextView = NO;
    self.textView.horizontallyResizable = NO;
    self.textView.verticallyResizable = NO;
    self.textView.allowsUndo = YES;
    self.textView.automaticQuoteSubstitutionEnabled = NO;
    self.textView.automaticDashSubstitutionEnabled = NO;
    self.textView.accessibilityLabel = @"画布文字编辑";
    [self.textView.textStorage setAttributedString:[[NSAttributedString alloc] initWithString:annotation[@"text"] ?: @"" attributes:MCTextAttributes(annotation)]];
    self.textView.typingAttributes = MCTextAttributes(annotation);
    [self.textHost addSubview:self.textView];
    [self addSubview:self.textHost];
    [self updateTextFrame];
    [self.editor syncTextControls];
    self.editor.confirmButton.keyEquivalent = @"";
    self.editor.cancelButton.keyEquivalent = @"";
    self.editor.confirmButton.toolTip = @"确认并复制（点击完成；回车用于换行）";
    self.editor.cancelButton.toolTip = @"取消截图";
    [self.window makeFirstResponder:self.textView];
    self.textView.selectedRange = NSMakeRange(self.textView.string.length, 0);
    self.editor.status.stringValue = @"直接输入 · 回车换行 · ⌘回车完成 · 拖动边框移动 · 拖角缩放";
}
- (BOOL)finishTextEditing:(BOOL)commit {
    if (!self.textView) return YES;
    // A click on a canvas action accepts the input method's current text.
    // Return/Escape while composing are handled by NSTextView instead.
    if (self.textView.hasMarkedText) [self.textView unmarkText];
    self.textDraft[@"text"] = self.textView.string;
    NSDictionary *original = nil;
    for (NSDictionary *annotation in self.editor.document[@"annotations"])
        if ([annotation[@"id"] isEqual:self.selectedID]) original = annotation;
    BOOL empty = [self.textView.string stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].length == 0;
    if (commit) {
        BOOL applied = YES;
        if (empty && original) applied = [self.editor applyCommand:@{@"type":@"remove", @"ids":@[self.selectedID]}];
        else if (!empty && ![original isEqual:self.textDraft])
            applied = original ? [self.editor applyCommand:@{@"type":@"update", @"id":self.selectedID, @"patch":self.textDraft}] :
                                 [self.editor applyAnnotation:self.textDraft];
        if (!applied) return NO;
    }
    if ((!commit && !original) || (commit && empty)) self.selectedID = nil;
    [self.window makeFirstResponder:self];
    self.textView.delegate = nil;
    [self.textHost removeFromSuperview];
    self.textView = nil;
    self.textHost = nil;
    self.textDraft = nil;
    self.editor.confirmButton.keyEquivalent = @"\r";
    self.editor.cancelButton.keyEquivalent = @"\e";
    self.editor.confirmButton.toolTip = @"确认并复制（Return）";
    self.editor.cancelButton.toolTip = @"取消截图（Esc）";
    [self.editor refresh];
    [self updateTextFrame];
    return YES;
}
- (BOOL)textView:(NSTextView *)textView shouldChangeTextInRange:(NSRange)range replacementString:(NSString *)replacement {
    if (replacement && textView.string.length - range.length + replacement.length > 10000) {
        [self.editor showError:MCEditorError(@"文字最多支持 10000 个字符。")];
        return NO;
    }
    return YES;
}
- (void)textDidChange:(NSNotification *)notification {
    (void)notification;
    self.textDraft[@"text"] = self.textView.string;
    self.textDraft[@"height"] = @(MIN(MCTextHeight(self.textDraft),
        [self.editor.document[@"height"] doubleValue] - [self.textDraft[@"y"] doubleValue]));
    [self updateTextFrame];
    self.editor.undoButton.enabled = self.textView.undoManager.canUndo;
    self.editor.redoButton.enabled = self.textView.undoManager.canRedo;
}
- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    [NSColor.underPageBackgroundColor setFill]; NSRectFill(self.bounds);
    NSRect frame = [self imageFrame];
    [NSGraphicsContext saveGraphicsState];
    NSAffineTransform *transform = [NSAffineTransform transform];
    [transform translateXBy:frame.origin.x yBy:frame.origin.y];
    [transform scaleBy:frame.size.width / [self.editor.document[@"width"] doubleValue]];
    [transform concat];
    NSMutableDictionary *display = [self.editor.document mutableCopy];
    NSMutableArray *annotations = [NSMutableArray array];
    for (NSDictionary *annotation in self.editor.document[@"annotations"]) {
        if ([annotation[@"id"] isEqual:self.selectedID]) {
            if (self.textView) continue; // The live native text view draws this object.
            [annotations addObject:self.transformPreview ?: annotation];
        } else [annotations addObject:annotation];
    }
    display[@"annotations"] = annotations;
    MCDrawImage(self.editor.image, display, self.pending);
    [NSGraphicsContext restoreGraphicsState];
    if (self.editor.overlayMode) {
        NSRect region = [self viewRectForImageRect:[self captureRect]];
        NSBezierPath *shade = [NSBezierPath bezierPathWithRect:self.bounds];
        if (!NSIsEmptyRect(region)) [shade appendBezierPathWithRect:region];
        shade.windingRule = NSWindingRuleEvenOdd;
        [[NSColor colorWithWhite:0 alpha:0.48] setFill]; [shade fill];
        if (NSIsEmptyRect(region)) {
            NSString *hint = @"拖动框选截图范围 · Esc 取消";
            NSDictionary *attributes = @{NSFontAttributeName:[NSFont systemFontOfSize:17 weight:NSFontWeightMedium],
                NSForegroundColorAttributeName:NSColor.whiteColor};
            NSSize size = [hint sizeWithAttributes:attributes];
            [hint drawAtPoint:NSMakePoint((NSWidth(self.bounds) - size.width) / 2, MAX(30, NSHeight(self.bounds) * .12)) withAttributes:attributes];
        } else {
            NSBezierPath *border = [NSBezierPath bezierPathWithRect:region];
            [MCSelectionContrastColor() setStroke]; border.lineWidth = 3.5; [border stroke];
            [MCSelectionColor() setStroke]; border.lineWidth = 1.5; [border stroke];
            for (NSInteger handle = 0; handle < 8; handle++) {
                NSPoint center = [self handlePoint:handle inRect:region];
                NSBezierPath *dot = [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(center.x - 3, center.y - 3, 6, 6)];
                [MCSelectionHandleColor() setFill]; [dot fill]; [MCSelectionContrastColor() setStroke]; [dot stroke];
            }
            NSRect pixels = [self captureRect];
            NSString *dimensions = [NSString stringWithFormat:@"%.0f × %.0f px", pixels.size.width, pixels.size.height];
            NSDictionary *attributes = @{NSFontAttributeName:[NSFont monospacedDigitSystemFontOfSize:12 weight:NSFontWeightMedium],
                NSForegroundColorAttributeName:NSColor.whiteColor};
            NSSize size = [dimensions sizeWithAttributes:attributes];
            NSRect label = NSMakeRect(MAX(4, MIN(region.origin.x, NSWidth(self.bounds) - size.width - 16)),
                MAX(4, region.origin.y - 27), size.width + 12, 22);
            [[NSColor colorWithWhite:.1 alpha:.9] setFill];
            [[NSBezierPath bezierPathWithRoundedRect:label xRadius:5 yRadius:5] fill];
            [dimensions drawAtPoint:NSMakePoint(label.origin.x + 6, label.origin.y + 3) withAttributes:attributes];
        }
    }
    if ([self selectedAnnotation]) {
        NSRect selection = [self selectionFrame];
        NSBezierPath *outline = [NSBezierPath bezierPathWithRect:NSInsetRect(selection, -1, -1)];
        [MCSelectionContrastColor() setStroke]; outline.lineWidth = 3; [outline stroke];
        [MCSelectionColor() setStroke]; outline.lineWidth = 1; [outline stroke];
        for (NSInteger handle = 0; handle < 8; handle++) {
            NSPoint point = [self handlePoint:handle inRect:selection];
            NSBezierPath *box = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(point.x - 3, point.y - 3, 6, 6) xRadius:1 yRadius:1];
            [MCSelectionHandleColor() setFill]; [box fill];
            [MCSelectionContrastColor() setStroke]; [box stroke];
        }
    }
}
- (void)mouseDown:(NSEvent *)event {
    NSPoint local = [self convertPoint:event.locationInWindow fromView:nil];
    NSInteger handle = [self handleAtPoint:local];
    BOOL border = [self selectionBorderAtPoint:local];
    if (handle >= 0 || border) {
        if (![self finishTextEditing:YES]) return;
        self.transformOriginal = [self selectedAnnotation];
        self.resizeHandle = handle;
        self.start = [self imagePoint:event];
        self.dragging = self.transformOriginal != nil;
        [self.window makeFirstResponder:self];
        return;
    }
    if (![self finishTextEditing:YES]) return;
    [self.window makeFirstResponder:self];
    if (!NSPointInRect(local, [self imageFrame])) { self.selectedID = nil; [self.editor refresh]; return; }
    self.start = [self imagePoint:event];
    NSInteger regionHandle = [self captureHandleAtPoint:local];
    NSRect regionFrame = [self viewRectForImageRect:[self captureRect]];
    BOOL regionBorder = self.editor.hasCaptureRegion && NSPointInRect(local, NSInsetRect(regionFrame, 5, 5)) == NO &&
        NSPointInRect(local, NSInsetRect(regionFrame, -5, -5));
    if (self.editor.overlayMode && (!self.editor.hasCaptureRegion || regionHandle >= 0 || regionBorder ||
        !NSPointInRect(self.start, [self captureRect]))) {
        self.selectedID = nil;
        self.regionOriginal = [self captureRect];
        self.regionHandle = regionHandle >= 0 ? regionHandle : regionBorder ? -2 : -1;
        self.regionPreview = self.regionHandle == -1 ? NSMakeRect(self.start.x, self.start.y, 0, 0) : self.regionOriginal;
        self.regionDragging = YES;
        self.editor.floatingToolbar.hidden = YES;
        self.needsDisplay = YES;
        return;
    }
    if (self.editor.tools.selectedSegment == MCSelectTool || self.editor.tools.selectedSegment == MCTextTool) {
        for (NSDictionary *annotation in [self.editor.document[@"annotations"] reverseObjectEnumerator]) {
            if ([annotation[@"type"] isEqual:@"text"] && NSPointInRect(self.start, MCAnnotationRect(annotation))) {
                self.selectedID = annotation[@"id"];
                [self.editor syncTextControls];
                if (event.clickCount >= 2) [self beginEditingText:annotation];
                else { self.transformOriginal = annotation; self.resizeHandle = -1; self.dragging = YES; }
                [self updateTextFrame];
                return;
            }
        }
    }
    self.selectedID = nil;
    [self.editor syncTextControls];
    if (self.editor.tools.selectedSegment == MCTextTool) { [self.editor addTextAtPoint:self.start]; return; }
    if (self.editor.tools.selectedSegment == MCSelectTool) { self.needsDisplay = YES; return; }
    self.dragging = YES;
}
- (NSDictionary *)transformedAnnotationAt:(NSPoint)point {
    NSMutableDictionary *result = [self.transformOriginal mutableCopy];
    NSRect original = MCAnnotationRect(result), rect = original;
    CGFloat width = [self.editor.document[@"width"] doubleValue], height = [self.editor.document[@"height"] doubleValue];
    CGFloat dx = point.x - self.start.x, dy = point.y - self.start.y;
    NSInteger handle = self.resizeHandle;
    if (handle < 0) {
        rect.origin.x = MAX(0, MIN(width - rect.size.width, rect.origin.x + dx));
        rect.origin.y = MAX(0, MIN(height - rect.size.height, rect.origin.y + dy));
    } else if (handle % 2 == 0) {
        // Corners scale both the box and type; side handles reflow the text.
        BOOL left = handle == 0 || handle == 6, top = handle == 0 || handle == 2;
        CGFloat sx = left ? -1 : 1, sy = top ? -1 : 1;
        CGFloat factor = 1 + (dx * sx * rect.size.width + dy * sy * rect.size.height) /
            (rect.size.width * rect.size.width + rect.size.height * rect.size.height);
        CGFloat size = [result[@"fontSize"] doubleValue];
        CGFloat anchorX = left ? NSMaxX(rect) : NSMinX(rect), anchorY = top ? NSMaxY(rect) : NSMinY(rect);
        CGFloat maximum = MIN(128 / size, MIN((left ? anchorX : width - anchorX) / rect.size.width,
                                               (top ? anchorY : height - anchorY) / rect.size.height));
        factor = MAX(MIN(8 / size, maximum), MIN(maximum, factor));
        rect.size.width *= factor; rect.size.height *= factor;
        rect.origin.x = left ? anchorX - rect.size.width : anchorX;
        rect.origin.y = top ? anchorY - rect.size.height : anchorY;
        result[@"fontSize"] = @(MAX(8, MIN(128, size * factor)));
    } else if (handle == 3 || handle == 7) {
        CGFloat minWidth = MIN(24, original.size.width);
        if (handle == 3) rect.size.width = MAX(minWidth, MIN(width - rect.origin.x, rect.size.width + dx));
        else { rect.origin.x = MAX(0, MIN(NSMaxX(original) - minWidth, original.origin.x + dx)); rect.size.width = NSMaxX(original) - rect.origin.x; }
        result[@"width"] = @(rect.size.width);
        rect.size.height = MIN(height - rect.origin.y, MCTextHeight(result));
    } else {
        CGFloat minHeight = MIN(MCTextHeight(result), height - rect.origin.y);
        if (handle == 5) rect.size.height = MAX(minHeight, MIN(height - rect.origin.y, rect.size.height + dy));
        else {
            rect.origin.y = MAX(0, MIN(NSMaxY(original) - minHeight, original.origin.y + dy));
            rect.size.height = NSMaxY(original) - rect.origin.y;
        }
    }
    result[@"x"] = @(rect.origin.x); result[@"y"] = @(rect.origin.y);
    result[@"width"] = @(rect.size.width); result[@"height"] = @(rect.size.height);
    return result;
}
- (void)mouseDragged:(NSEvent *)event {
    if (self.regionDragging) {
        NSPoint point = [self imagePoint:event];
        CGFloat dx = point.x - self.start.x, dy = point.y - self.start.y;
        NSRect rect = self.regionOriginal;
        if (self.regionHandle == -1) {
            rect = NSMakeRect(MIN(self.start.x, point.x), MIN(self.start.y, point.y), fabs(dx), fabs(dy));
        } else if (self.regionHandle == -2) {
            rect.origin.x = MAX(0, MIN([self.editor.document[@"width"] doubleValue] - rect.size.width, rect.origin.x + dx));
            rect.origin.y = MAX(0, MIN([self.editor.document[@"height"] doubleValue] - rect.size.height, rect.origin.y + dy));
        } else {
            CGFloat left = NSMinX(rect), right = NSMaxX(rect), top = NSMinY(rect), bottom = NSMaxY(rect);
            NSInteger h = self.regionHandle;
            if (h == 0 || h == 6 || h == 7) left = MIN(right - 2, MAX(0, left + dx));
            if (h == 2 || h == 3 || h == 4) right = MAX(left + 2, MIN([self.editor.document[@"width"] doubleValue], right + dx));
            if (h == 0 || h == 1 || h == 2) top = MIN(bottom - 2, MAX(0, top + dy));
            if (h == 4 || h == 5 || h == 6) bottom = MAX(top + 2, MIN([self.editor.document[@"height"] doubleValue], bottom + dy));
            rect = NSMakeRect(left, top, right - left, bottom - top);
        }
        self.regionPreview = rect; self.needsDisplay = YES;
        return;
    }
    if (!self.dragging) return;
    if (self.transformOriginal) {
        self.transformPreview = [self transformedAnnotationAt:[self imagePoint:event]];
        [self.editor syncTextControls];
    } else self.pending = [self.editor annotationFrom:self.start to:[self imagePoint:event]];
    self.needsDisplay = YES;
}
- (void)mouseUp:(NSEvent *)event {
    if (self.regionDragging) {
        [self mouseDragged:event];
        NSRect rect = self.regionPreview;
        self.regionDragging = NO;
        if (rect.size.width >= 2 && rect.size.height >= 2) [self.editor setCaptureRegion:rect];
        [self.editor positionFloatingToolbar]; [self updateTextFrame];
        return;
    }
    if (!self.dragging) return;
    self.dragging = NO;
    if (self.transformOriginal) {
        NSDictionary *transformed = self.transformPreview ? [self transformedAnnotationAt:[self imagePoint:event]] : nil;
        if (transformed && ![transformed isEqual:self.transformOriginal])
            [self.editor applyCommand:@{@"type":@"update", @"id":self.selectedID, @"patch":transformed}];
        self.transformOriginal = nil; self.transformPreview = nil;
        [self updateTextFrame]; [self.editor syncTextControls];
        return;
    }
    NSDictionary *annotation = [self.editor annotationFrom:self.start to:[self imagePoint:event]];
    self.pending = nil;
    if (annotation) [self.editor applyAnnotation:annotation];
    self.needsDisplay = YES;
}
- (void)cancelGesture {
    self.dragging = NO; self.pending = nil; self.transformOriginal = nil; self.transformPreview = nil;
    self.regionDragging = NO;
    [self.editor positionFloatingToolbar];
    [self updateTextFrame]; [self.editor syncTextControls];
}
- (void)deleteSelection {
    if (self.selectedID && [self.editor applyCommand:@{@"type":@"remove", @"ids":@[self.selectedID]}]) {
        self.selectedID = nil; [self.editor refresh];
    }
}
- (void)keyDown:(NSEvent *)event {
    if (event.keyCode == 53) {
        if (self.dragging || self.regionDragging) [self cancelGesture];
        else if (self.selectedID) { self.selectedID = nil; [self.editor refresh]; }
        else [self.editor cancel:nil];
    } else if ((event.keyCode == 51 || event.keyCode == 117) && self.selectedID) {
        [self deleteSelection];
    } else if (event.keyCode >= 123 && event.keyCode <= 126 && self.selectedID) {
        CGFloat step = event.modifierFlags & NSEventModifierFlagShift ? 10 : 1;
        self.transformOriginal = [self selectedAnnotation]; self.start = NSZeroPoint; self.resizeHandle = -1;
        NSDictionary *moved = [self transformedAnnotationAt:NSMakePoint(event.keyCode == 123 ? -step : event.keyCode == 124 ? step : 0,
            event.keyCode == 126 ? -step : event.keyCode == 125 ? step : 0)];
        self.transformOriginal = nil;
        [self.editor applyCommand:@{@"type":@"update", @"id":self.selectedID, @"patch":moved}];
    } else [super keyDown:event];
}
@end

@implementation MCImageEditorController
- (instancetype)initWithPNGData:(NSData *)data error:(NSError **)error {
    self = [super init];
    if (!self) return nil;
    NSBitmapImageRep *bitmap = [NSBitmapImageRep imageRepWithData:data];
    if (!bitmap || bitmap.pixelsWide < 1 || bitmap.pixelsHigh < 1 || bitmap.pixelsWide > 32768 || bitmap.pixelsHigh > 32768 ||
        bitmap.pixelsWide * bitmap.pixelsHigh > 80000000) {
        if (error) *error = MCEditorError(@"截图无法读取，或图片尺寸过大。");
        return nil;
    }
    _document = MCCallImage(image_create, @{@"width":@(bitmap.pixelsWide), @"height":@(bitmap.pixelsHigh)}, error);
    if (!_document) return nil;
    _image = [[NSImage alloc] initWithSize:NSMakeSize(bitmap.pixelsWide, bitmap.pixelsHigh)];
    [_image addRepresentation:bitmap];
    return self;
}
- (NSButton *)button:(NSString *)title action:(SEL)action key:(NSString *)key {
    NSButton *button = [NSButton buttonWithTitle:title target:self action:action];
    button.bezelStyle = NSBezelStyleRounded;
    if (key) button.keyEquivalent = key;
    return button;
}
- (void)configureIconButton:(NSButton *)button icon:(MCIcon)icon label:(NSString *)label shortcut:(NSString *)shortcut {
    NSImage *image = MCIconImage(icon, label);
    button.accessibilityLabel = label;
    button.toolTip = shortcut.length ? [NSString stringWithFormat:@"%@（%@）", label, shortcut] : label;
    button.image = image;
    button.imagePosition = NSImageOnly;
    button.bordered = NO;
    button.contentTintColor = NSColor.labelColor;
    button.title = @"";
    button.bezelStyle = NSBezelStyleTexturedRounded;
}
- (void)prepareWindow {
    if (!self.window) {
        NSScreen *screen = NSScreen.mainScreen ?: NSScreen.screens.firstObject;
        CGFloat width = MIN(1100, screen.visibleFrame.size.width - 80), height = MIN(760, screen.visibleFrame.size.height - 100);
        self.window = [[MCImageEditorWindow alloc] initWithContentRect:NSMakeRect(0, 0, width, height)
            styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable backing:NSBackingStoreBuffered defer:NO];
        self.window.releasedWhenClosed = NO;
        self.window.delegate = self;
        self.window.title = @"Mooji Cut · 标注截图";
        self.window.minSize = NSMakeSize(540, 400);
        NSView *root = self.window.contentView;
        self.canvas = [[MCImageCanvas alloc] initWithFrame:NSMakeRect(0, 48, width, height - 108)];
        self.canvas.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        self.canvas.editor = self;
        self.canvas.accessibilityLabel = @"截图标注画布";
        [root addSubview:self.canvas];
        self.tools = [NSSegmentedControl segmentedControlWithLabels:@[@"选择", @"矩形", @"箭头", @"文字", @"遮挡"] trackingMode:NSSegmentSwitchTrackingSelectOne target:self action:@selector(chooseTool:)];
        const MCIcon toolIcons[] = {MC_ICON_SELECT, MC_ICON_RECTANGLE, MC_ICON_ARROW, MC_ICON_TEXT, MC_ICON_REDACT};
        for (NSInteger index = 0; index < self.tools.segmentCount; index++) {
            NSString *label = [self.tools labelForSegment:index];
            NSImage *image = MCIconImage(toolIcons[index], label);
            [self.tools setToolTip:label forSegment:index];
            [self.tools setTag:index forSegment:index];
            if (image) {
                [self.tools setImage:image forSegment:index];
                [self.tools setImageScaling:NSImageScaleProportionallyDown forSegment:index];
                [self.tools setLabel:@"" forSegment:index];
                [self.tools setWidth:30 forSegment:index];
            }
        }
        self.tools.selectedSegmentBezelColor = MCSelectedToolColor();
        self.tools.selectedSegment = MCRectTool;
        self.tools.accessibilityLabel = @"标注工具";
        self.color = [[NSColorWell alloc] initWithFrame:NSMakeRect(0, 0, 28, 28)];
        self.color.color = [NSColor colorWithSRGBRed:0.94 green:0.27 blue:0.27 alpha:1];
        self.color.accessibilityLabel = @"标注颜色";
        self.color.toolTip = @"标注颜色";
        [self.color.widthAnchor constraintEqualToConstant:28].active = YES;
        self.color.colorWellStyle = NSColorWellStyleMinimal;
        self.color.target = self;
        self.color.action = @selector(styleChanged:);
        self.fontSize = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 52, 24)];
        self.fontSize.doubleValue = 28;
        self.fontSize.alignment = NSTextAlignmentRight;
        self.fontSize.accessibilityLabel = @"文字字号";
        self.fontSize.target = self; self.fontSize.action = @selector(styleChanged:);
        NSNumberFormatter *formatter = [NSNumberFormatter new];
        formatter.minimum = @8; formatter.maximum = @128;
        formatter.maximumFractionDigits = 1;
        self.fontSize.formatter = formatter;
        self.fontSize.cell.sendsActionOnEndEditing = YES;
        [self.fontSize.widthAnchor constraintEqualToConstant:44].active = YES;
        self.fontStepper = [NSStepper new];
        self.fontStepper.minValue = 8; self.fontStepper.maxValue = 128;
        self.fontStepper.increment = 1; self.fontStepper.doubleValue = 28;
        self.fontStepper.valueWraps = NO;
        self.fontStepper.target = self; self.fontStepper.action = @selector(styleChanged:);
        self.fontStepper.accessibilityLabel = @"调整文字字号";
        self.undoButton = [self button:@"撤销" action:@selector(undo:) key:@"z"];
        self.redoButton = [self button:@"重做" action:@selector(redo:) key:@"z"];
        [self configureIconButton:self.undoButton icon:MC_ICON_UNDO label:@"撤销" shortcut:@"⌘Z"];
        [self configureIconButton:self.redoButton icon:MC_ICON_REDO label:@"重做" shortcut:@"⇧⌘Z"];
        [self.undoButton.widthAnchor constraintEqualToConstant:32].active = YES;
        [self.redoButton.widthAnchor constraintEqualToConstant:32].active = YES;
        self.undoButton.keyEquivalentModifierMask = NSEventModifierFlagCommand;
        self.redoButton.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagShift;
        NSImageView *fontIcon = [NSImageView imageViewWithImage:MCIconImage(MC_ICON_FONT_SIZE, @"字号")];
        fontIcon.toolTip = @"文字字号";
        [fontIcon.widthAnchor constraintEqualToConstant:18].active = YES;
        NSStackView *toolbar = [NSStackView stackViewWithViews:@[self.tools, self.color,
            fontIcon, self.fontSize, self.fontStepper, self.undoButton, self.redoButton]];
        self.toolbar = toolbar;
        toolbar.orientation = NSUserInterfaceLayoutOrientationHorizontal;
        toolbar.spacing = 8;
        toolbar.frame = NSMakeRect(18, height - 48, width - 36, 32);
        toolbar.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
        [root addSubview:toolbar];
        self.status = [NSTextField labelWithString:@""];
        self.status.frame = NSMakeRect(18, 15, width - 400, 20);
        self.status.autoresizingMask = NSViewWidthSizable;
        self.status.textColor = NSColor.secondaryLabelColor;
        self.status.lineBreakMode = NSLineBreakByTruncatingTail;
        [root addSubview:self.status];
        self.pinButton = [self button:@"贴图" action:@selector(pinImage:) key:nil];
        [self configureIconButton:self.pinButton icon:MC_ICON_PIN label:@"贴图置顶" shortcut:nil];
        self.pinButton.frame = NSMakeRect(width - 140, 9, 36, 32);
        self.pinButton.autoresizingMask = NSViewMinXMargin;
        self.pinButton.toolTip = @"将编辑结果置顶显示在桌面";
        [root addSubview:self.pinButton];
        NSButton *cancel = [self button:@"取消" action:@selector(cancel:) key:@"\e"];
        [self configureIconButton:cancel icon:MC_ICON_CLOSE label:@"取消截图" shortcut:@"Esc"];
        self.cancelButton = cancel;
        cancel.keyEquivalentModifierMask = 0;
        cancel.frame = NSMakeRect(width - 96, 9, 36, 32);
        cancel.autoresizingMask = NSViewMinXMargin;
        [root addSubview:cancel];
        NSButton *confirm = [self button:@"确认并复制" action:@selector(confirm:) key:@"\r"];
        [self configureIconButton:confirm icon:MC_ICON_CHECK label:@"确认并复制" shortcut:@"Return"];
        self.confirmButton = confirm;
        confirm.keyEquivalentModifierMask = 0;
        confirm.frame = NSMakeRect(width - 52, 9, 36, 32);
        confirm.autoresizingMask = NSViewMinXMargin;
        [root addSubview:confirm];
        [self.window center];
    }
    [self refresh];
}
- (void)prepareOverlayInFrame:(NSRect)screenFrame {
    [self prepareWindow];
    self.overlayMode = YES;
    self.hasCaptureRegion = NO;
    self.window.styleMask = NSWindowStyleMaskBorderless;
    self.window.minSize = NSZeroSize;
    self.window.level = NSScreenSaverWindowLevel;
    self.window.hasShadow = NO;
    self.window.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorFullScreenAuxiliary;
    [self.window setFrame:screenFrame display:NO];
    NSView *root = self.window.contentView;
    self.canvas.frame = root.bounds;
    self.canvas.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.floatingToolbar = [[NSVisualEffectView alloc] initWithFrame:NSZeroRect];
    self.floatingToolbar.material = NSVisualEffectMaterialHUDWindow;
    self.floatingToolbar.blendingMode = NSVisualEffectBlendingModeWithinWindow;
    self.floatingToolbar.state = NSVisualEffectStateActive;
    self.floatingToolbar.wantsLayer = YES;
    self.floatingToolbar.layer.cornerRadius = 12;
    self.floatingToolbar.layer.masksToBounds = YES;
    self.floatingToolbar.hidden = YES;
    for (NSView *view in @[self.toolbar, self.status, self.pinButton, self.cancelButton, self.confirmButton]) {
        [view removeFromSuperview];
        view.autoresizingMask = NSViewNotSizable;
        [self.floatingToolbar addSubview:view];
    }
    [root addSubview:self.floatingToolbar];
    // The system color panel must remain above the capture overlay.
    NSColorPanel.sharedColorPanel.level = self.window.level + 1;
    self.canvas.needsDisplay = YES;
}
- (BOOL)setCaptureRegion:(NSRect)rect {
    CGFloat left = floor(rect.origin.x), top = floor(rect.origin.y);
    CGFloat right = MIN([self.document[@"width"] doubleValue], ceil(NSMaxX(rect)));
    CGFloat bottom = MIN([self.document[@"height"] doubleValue], ceil(NSMaxY(rect)));
    NSDictionary *viewport = @{@"x":@(left), @"y":@(top), @"width":@(right - left), @"height":@(bottom - top)};
    BOOL passed = YES;
    if (!self.hasCaptureRegion) {
        NSError *error = nil;
        NSDictionary *created = MCCallImage(image_create, @{@"width":self.document[@"width"], @"height":self.document[@"height"],
            @"viewport":viewport}, &error);
        if (!created) { [self showError:error]; return NO; }
        self.document = created;
        self.hasCaptureRegion = YES;
        // Text is immediately available once the selection is complete.
        self.tools.selectedSegment = MCSelectTool;
    } else if (![viewport isEqual:self.document[@"viewport"]]) {
        passed = [self applyCommand:@{@"type":@"crop", @"rect":viewport}];
    }
    [self refresh]; [self positionFloatingToolbar];
    return passed;
}
- (void)positionFloatingToolbar {
    if (!self.overlayMode) return;
    self.floatingToolbar.hidden = !self.hasCaptureRegion || self.canvas.regionDragging;
    if (self.floatingToolbar.hidden) return;
    NSView *root = self.window.contentView;
    NSRect region = [self.canvas viewRectForImageRect:MCAnnotationRect(self.document[@"viewport"])];
    region = [self.canvas convertRect:region toView:root];
    CGFloat width = MIN(460, NSWidth(root.bounds) - 24), height = 86;
    CGFloat x = MAX(12, MIN(NSMinX(region), NSWidth(root.bounds) - width - 12));
    CGFloat y = NSMinY(region) - height - 10;
    if (y < 12) y = NSMaxY(region) + 10;
    y = MAX(12, MIN(y, NSHeight(root.bounds) - height - 12));
    self.floatingToolbar.frame = NSMakeRect(x, y, width, height);
    self.toolbar.spacing = width < 420 ? 4 : 8;
    self.toolbar.frame = NSMakeRect(12, 44, width - 24, 32);
    self.status.frame = NSMakeRect(14, 12, width - 154, 20);
    self.status.font = [NSFont systemFontOfSize:11];
    self.pinButton.frame = NSMakeRect(width - 132, 8, 36, 28);
    self.cancelButton.frame = NSMakeRect(width - 92, 8, 36, 28);
    self.confirmButton.frame = NSMakeRect(width - 52, 8, 40, 28);
}
- (void)show {
    if (!self.window) [self prepareWindow];
    [NSApp unhide:nil];
    [NSApp activateIgnoringOtherApps:YES];
    [self.window makeKeyAndOrderFront:nil];
    [self.window makeFirstResponder:self.canvas];
}
- (void)refresh {
    if (self.canvas.selectedID && ![self.canvas selectedAnnotation]) self.canvas.selectedID = nil;
    self.undoButton.enabled = [self.document[@"undo"] count] > 0;
    self.redoButton.enabled = [self.document[@"redo"] count] > 0;
    self.canvas.needsDisplay = YES;
    [self.canvas updateTextFrame];
    [self syncTextControls];
    self.pinButton.enabled = self.onPinPNGData != nil;
    [self positionFloatingToolbar];
    self.status.stringValue = [NSString stringWithFormat:@"%@ × %@ 像素 · %lu 条标注", self.document[@"width"], self.document[@"height"], (unsigned long)[self.document[@"annotations"] count]];
    if (self.canvas.selectedID) self.status.stringValue = @"拖动文字移动 · 拖角缩放 · 拖左右边框换行 · 双击编辑 · Delete 删除";
}
- (void)showError:(NSError *)error {
    self.status.stringValue = error.localizedDescription;
    NSBeep();
}
- (NSString *)colorHex {
    NSColor *color = [self.color.color colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    return [NSString stringWithFormat:@"#%02x%02x%02x", (unsigned)lround(color.redComponent * 255),
        (unsigned)lround(color.greenComponent * 255), (unsigned)lround(color.blueComponent * 255)];
}
- (void)syncTextControls {
    NSDictionary *annotation = [self.canvas selectedAnnotation];
    BOOL hasText = [annotation[@"type"] isEqual:@"text"];
    self.fontSize.enabled = self.fontStepper.enabled = hasText || self.tools.selectedSegment == MCTextTool;
    self.color.enabled = hasText || self.tools.selectedSegment != MCRedactTool;
    if (hasText) {
        self.color.color = MCAnnotationColor(annotation);
        self.fontSize.doubleValue = [annotation[@"fontSize"] doubleValue];
        self.fontStepper.doubleValue = self.fontSize.doubleValue;
    }
}
- (void)styleChanged:(id)sender {
    double size = MAX(8, MIN(128, sender == self.fontStepper ? self.fontStepper.doubleValue : self.fontSize.doubleValue));
    self.fontSize.doubleValue = self.fontStepper.doubleValue = size;
    NSDictionary *selected = [self.canvas selectedAnnotation];
    if (![selected[@"type"] isEqual:@"text"]) return;
    NSMutableDictionary *changed = [selected mutableCopy];
    changed[@"fontSize"] = @(size);
    changed[@"color"] = [self colorHex];
    changed[@"height"] = @(MIN(MCTextHeight(changed), [self.document[@"height"] doubleValue] - [changed[@"y"] doubleValue]));
    if (self.canvas.textView) {
        self.canvas.textDraft = changed;
        NSDictionary *attributes = MCTextAttributes(changed);
        // Preserve the string, selected range, and input-method composition.
        [self.canvas.textView.textStorage addAttributes:attributes range:NSMakeRange(0, self.canvas.textView.string.length)];
        self.canvas.textView.typingAttributes = attributes;
        [self.canvas updateTextFrame];
    } else if (![selected isEqual:changed]) {
        [self applyCommand:@{@"type":@"update", @"id":self.canvas.selectedID, @"patch":changed}];
    }
}
- (void)chooseTool:(id)sender {
    (void)sender;
    if (![self.canvas finishTextEditing:YES]) return;
    [self.canvas cancelGesture];
    self.canvas.selectedID = nil;
    [self syncTextControls];
    [self.window makeFirstResponder:self.canvas];
    self.status.stringValue = self.tools.selectedSegment == MCTextTool ? @"点击画面直接输入文字，双击已有文字继续编辑。" :
        self.tools.selectedSegment == MCRedactTool ? @"拖动画面添加不透明遮挡。" :
        self.tools.selectedSegment == MCSelectTool ? @"选择文字后拖动、缩放，或双击编辑。" : @"在画面上拖动添加标注。";
}
- (NSDictionary *)annotationFrom:(NSPoint)start to:(NSPoint)end {
    if (hypot(end.x - start.x, end.y - start.y) < 3) return nil;
    BOOL arrow = self.tools.selectedSegment == MCArrowTool, redact = self.tools.selectedSegment == MCRedactTool;
    if (!arrow && (fabs(end.x - start.x) < 2 || fabs(end.y - start.y) < 2)) return nil;
    NSMutableDictionary *annotation = [@{
        @"id":NSUUID.UUID.UUIDString, @"type":arrow ? @"arrow" : redact ? @"redact" : @"rect",
        @"x":@(arrow ? start.x : MIN(start.x,end.x)), @"y":@(arrow ? start.y : MIN(start.y,end.y)),
        @"width":@(MAX(1,fabs(end.x-start.x))), @"height":@(MAX(1,fabs(end.y-start.y))),
        @"stroke":@4, @"opacity":@1, @"color":redact ? @"#000000" : [self colorHex] } mutableCopy];
    if (arrow) { annotation[@"x2"] = @(end.x); annotation[@"y2"] = @(end.y); }
    return annotation;
}
- (void)addTextAtPoint:(NSPoint)point {
    CGFloat size = MAX(8, MIN(128, self.fontSize.doubleValue));
    CGFloat width = [self.document[@"width"] doubleValue], height = [self.document[@"height"] doubleValue];
    NSRect region = self.overlayMode && self.hasCaptureRegion ? MCAnnotationRect(self.document[@"viewport"]) : NSMakeRect(0, 0, width, height);
    CGFloat boxWidth = MIN(280, region.size.width), boxHeight = MIN(ceil(size * 1.5), region.size.height);
    CGFloat x = MAX(NSMinX(region), MIN(point.x, NSMaxX(region) - MIN(boxWidth, 80)));
    CGFloat y = MAX(NSMinY(region), MIN(point.y, NSMaxY(region) - boxHeight));
    [self.canvas beginEditingText:@{@"id":NSUUID.UUID.UUIDString, @"type":@"text", @"text":@"",
        @"x":@(x), @"y":@(y), @"width":@(MIN(boxWidth, NSMaxX(region) - x)), @"height":@(boxHeight),
        @"fontSize":@(size), @"stroke":@3, @"opacity":@1, @"color":[self colorHex]}];
}
- (BOOL)applyCommand:(NSDictionary *)command {
    NSError *error = nil;
    NSDictionary *document = MCCallImage(image_apply, @{@"document":self.document, @"expectedRevision":self.document[@"revision"], @"command":command}, &error);
    if (!document) { [self showError:error]; return NO; }
    self.document = document;
    [self refresh];
    return YES;
}
- (BOOL)applyAnnotation:(NSDictionary *)annotation { return [self applyCommand:@{@"type":@"add", @"annotations":@[annotation]}]; }
- (void)undo:(id)sender {
    (void)sender;
    if (self.canvas.textView) { [self.canvas.textView.undoManager undo]; return; }
    [self.canvas cancelGesture]; [self applyCommand:@{@"type":@"undo"}];
}
- (void)redo:(id)sender {
    (void)sender;
    if (self.canvas.textView) { [self.canvas.textView.undoManager redo]; return; }
    [self.canvas cancelGesture]; [self applyCommand:@{@"type":@"redo"}];
}
- (NSData *)renderPNGData:(NSError **)error {
    if (self.overlayMode && !self.hasCaptureRegion) {
        if (error) *error = MCEditorError(@"请先框选截图范围。");
        return nil;
    }
    if (self.canvas && ![self.canvas finishTextEditing:YES]) {
        if (error) *error = MCEditorError(@"文字尚未保存，请检查后重试。");
        return nil;
    }
    NSDictionary *finalized = MCCallImage(image_finalize, @{@"document":self.document}, error);
    if (!finalized) return nil;
    NSInteger width = [finalized[@"width"] integerValue], height = [finalized[@"height"] integerValue];
    NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:width pixelsHigh:height
        bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:width*4 bitsPerPixel:32];
    if (!bitmap) { if (error) *error = MCEditorError(@"内存不足，无法生成截图。"); return nil; }
    NSGraphicsContext *context = [NSGraphicsContext graphicsContextWithBitmapImageRep:bitmap];
    if (!context) { if (error) *error = MCEditorError(@"无法创建图片画布。"); return nil; }
    [NSGraphicsContext saveGraphicsState];
    CGContextRef cg = context.CGContext;
    CGContextTranslateCTM(cg, 0, height);
    CGContextScaleCTM(cg, 1, -1);
    CGContextTranslateCTM(cg, -[self.document[@"viewport"][@"x"] doubleValue], -[self.document[@"viewport"][@"y"] doubleValue]);
    [NSGraphicsContext setCurrentContext:[NSGraphicsContext graphicsContextWithCGContext:cg flipped:YES]];
    MCDrawImage(self.image, self.document, nil);
    [NSGraphicsContext restoreGraphicsState];
    NSData *png = [bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    if (!png && error) *error = MCEditorError(@"无法编码 PNG 图片。");
    return png;
}
- (BOOL)copyToPasteboard:(NSPasteboard *)pasteboard error:(NSError **)error {
    NSData *png = [self renderPNGData:error];
    if (!png) return NO;
    NSPasteboardItem *item = [NSPasteboardItem new];
    [item setData:png forType:NSPasteboardTypePNG];
    // TIFF is also provided for applications whose image paste support predates PNG.
    NSData *tiff = [[NSImage alloc] initWithData:png].TIFFRepresentation;
    if (tiff) [item setData:tiff forType:NSPasteboardTypeTIFF];
    [pasteboard clearContents];
    BOOL written = [pasteboard writeObjects:@[item]];
    if (!written && error) *error = MCEditorError(@"图片未能写入剪贴板，请重试。");
    return written;
}
- (void)confirm:(id)sender {
    (void)sender;
    if (self.canvas.dragging || self.canvas.regionDragging || self.window.attachedSheet ||
        (self.overlayMode && !self.hasCaptureRegion)) return;
    // Validate/commit a pending numeric field before serializing the image.
    if (self.fontSize.currentEditor) [self styleChanged:self.fontSize];
    if (![self.canvas finishTextEditing:YES]) return;
    NSError *error = nil;
    if ([self copyToPasteboard:NSPasteboard.generalPasteboard error:&error]) [self.window close];
    else [self showError:error];
}
- (void)pinImage:(id)sender {
    (void)sender;
    if (!self.onPinPNGData || self.canvas.dragging || self.canvas.regionDragging) return;
    NSError *error = nil;
    NSData *png = [self renderPNGData:&error];
    if (!png) { [self showError:error]; return; }
    if (self.onPinPNGData(png)) [self.window close];
    else [self showError:MCEditorError(@"贴图未能创建，已保留当前编辑。")];
}
- (void)cancel:(id)sender { (void)sender; [self.canvas finishTextEditing:NO]; [self.window close]; }
- (void)windowWillClose:(NSNotification *)notification {
    (void)notification;
    void (^closed)(void) = self.onClose;
    self.onClose = nil;
    self.window.delegate = nil;
    self.window.contentView = nil;
    self.window = nil;
    self.canvas = nil;
    [self.color deactivate];
    [NSColorPanel.sharedColorPanel orderOut:nil];
    NSColorPanel.sharedColorPanel.level = NSFloatingWindowLevel;
    if (closed) closed();
}
+ (BOOL)runSmokeInDirectory:(NSString *)directory error:(NSError **)error {
    NSBitmapImageRep *sample = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:320 pixelsHigh:200
        bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:1280 bitsPerPixel:32];
    for (NSInteger y=0; y<200; y++) for (NSInteger x=0; x<320; x++) {
        unsigned char *pixel = sample.bitmapData + y * sample.bytesPerRow + x * 4;
        pixel[0] = pixel[1] = y < 100 ? 255 : 0;
        pixel[2] = pixel[3] = 255;
    }
    NSData *png = [sample representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    MCImageEditorController *editor = [[self alloc] initWithPNGData:png error:error];
    if (!editor) return NO;
    [editor show];
    NSArray *annotations = @[
        @{@"id":@"rect",@"type":@"rect",@"x":@20,@"y":@20,@"width":@100,@"height":@50,@"stroke":@4,@"opacity":@1,@"color":@"#ff0000"},
        @{@"id":@"arrow",@"type":@"arrow",@"x":@140,@"y":@30,@"x2":@240,@"y2":@70,@"stroke":@4,@"opacity":@1,@"color":@"#00aa00"},
        @{@"id":@"text",@"type":@"text",@"x":@20,@"y":@125,@"width":@200,@"height":@45,@"text":@"中文标注 ✅",@"fontSize":@24,@"stroke":@3,@"opacity":@1,@"color":@"#ffffff"},
        @{@"id":@"mask",@"type":@"redact",@"x":@250,@"y":@130,@"width":@50,@"height":@45,@"stroke":@3,@"opacity":@1,@"color":@"#000000"}
    ];
    BOOL passed = YES;
    for (NSDictionary *annotation in annotations) passed = [editor applyAnnotation:annotation] && passed;
    [editor undo:nil]; passed = passed && [editor.document[@"annotations"] count] == 3;
    [editor redo:nil]; passed = passed && [editor.document[@"annotations"] count] == 4;
    NSData *rendered = [editor renderPNGData:error];
    NSBitmapImageRep *result = rendered ? [NSBitmapImageRep imageRepWithData:rendered] : nil;
    NSColor *top = [[result colorAtX:5 y:5] colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    NSColor *bottom = [[result colorAtX:5 y:195] colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    NSColor *cover = [[result colorAtX:275 y:150] colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    passed = passed && result.pixelsWide == 320 && result.pixelsHigh == 200 && top.redComponent > 0.9 &&
        bottom.blueComponent > 0.9 && bottom.redComponent < 0.1 && cover.redComponent < 0.05 && cover.alphaComponent > 0.99;
    NSPasteboard *pasteboard = [NSPasteboard pasteboardWithUniqueName];
    passed = [editor copyToPasteboard:pasteboard error:error] && passed;
    passed = passed && [pasteboard dataForType:NSPasteboardTypePNG].length > 0;
    [pasteboard releaseGlobally];
    if (rendered && directory.length) {
        [[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:NULL];
        passed = [rendered writeToFile:[directory stringByAppendingPathComponent:@"annotated.png"] atomically:YES] && passed;
        NSView *content = editor.window.contentView;
        [content layoutSubtreeIfNeeded];
        [editor.window displayIfNeeded];
        NSBitmapImageRep *preview = [content bitmapImageRepForCachingDisplayInRect:content.bounds];
        [content cacheDisplayInRect:content.bounds toBitmapImageRep:preview];
        [[preview representationUsingType:NSBitmapImageFileTypePNG properties:@{}]
            writeToFile:[directory stringByAppendingPathComponent:@"editor.png"] atomically:YES];
    }
    [editor cancel:nil];
    passed = passed && editor.window == nil;
    if (!passed && error && !*error) *error = MCEditorError(@"截图编辑器验证未通过。");
    return passed;
}
@end
