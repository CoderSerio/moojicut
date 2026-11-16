#import "MCImageEditorController.h"
#import "components/theme/macos/MCChromeTheme.h"
#import "components/icons/macos/MCIcon.h"
#import "components/style_controls/macos/MCStylePropertiesView.h"
#import "components/selection/macos/MCSelectionSurface.h"
#include "moonbit.h"
#include "native/shared/image_session.h"
#include "native/shared/capture_ui.h"
#include <math.h>

extern moonbit_string_t image_create(moonbit_string_t);
extern moonbit_string_t image_apply(moonbit_string_t);
extern moonbit_string_t image_finalize(moonbit_string_t);
extern moonbit_string_t image_selection(moonbit_string_t);

static const CGFloat MCEditorToolWidth = 30;
static const CGFloat MCEditorToolHeight = 28;

// Keep native tracking/accessibility, but draw both groups with the same
// foreground. AppKit's segmented tint assumes a bezel we deliberately omit.
static void MCDrawToolIcon(NSImage *image, NSRect frame, BOOL enabled) {
    if (!image) return;
    NSImage *display = image;
    if (image.isTemplate) {
        NSColor *foreground = NSColor.labelColor;
        display = [NSImage imageWithSize:image.size flipped:NO drawingHandler:^BOOL(NSRect rect) {
            [image drawInRect:rect fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1];
            [foreground setFill];
            NSRectFillUsingOperation(rect, NSCompositingOperationSourceIn);
            return YES;
        }];
    }
    NSSize size = display.size;
    CGFloat scale = MIN(1, MIN(NSWidth(frame) / MAX(1, size.width), NSHeight(frame) / MAX(1, size.height)));
    NSRect rect = NSMakeRect(NSMidX(frame) - size.width * scale / 2, NSMidY(frame) - size.height * scale / 2,
                            size.width * scale, size.height * scale);
    [display drawInRect:rect fromRect:NSZeroRect operation:NSCompositingOperationSourceOver
              fraction:enabled ? 1 : .3 respectFlipped:YES hints:nil];
}

static void MCDrawToolBackground(NSRect frame, BOOL enabled, BOOL selected, BOOL hovered, BOOL pressed) {
    if (!enabled || !(selected || hovered || pressed)) return;
    NSColor *color = selected ? NSColor.controlAccentColor : NSColor.labelColor;
    CGFloat alpha = selected ? (pressed ? .28 : .18) : (pressed ? .16 : .08);
    [[color colorWithAlphaComponent:alpha] setFill];
    [[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(frame, 2, 2) xRadius:5 yRadius:5] fill];
}
@interface MCEditorToolButton : NSButton
@property BOOL toolHovered;
@property NSTrackingArea *toolTrackingArea;
@end
@implementation MCEditorToolButton
- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (self.toolTrackingArea) [self removeTrackingArea:self.toolTrackingArea];
    self.toolTrackingArea = [[NSTrackingArea alloc] initWithRect:NSZeroRect
        options:NSTrackingMouseEnteredAndExited | NSTrackingActiveInKeyWindow | NSTrackingInVisibleRect owner:self userInfo:nil];
    [self addTrackingArea:self.toolTrackingArea];
}
- (void)mouseEntered:(__unused NSEvent *)event { self.toolHovered = YES; self.needsDisplay = YES; }
- (void)mouseExited:(__unused NSEvent *)event { self.toolHovered = NO; self.needsDisplay = YES; }
- (void)drawRect:(NSRect)dirtyRect {
    MCDrawToolBackground(self.bounds, self.enabled, NO, self.toolHovered, self.cell.highlighted);
    if (self.image) MCDrawToolIcon(self.image, NSInsetRect(self.bounds, 6, 5), self.enabled);
    else [super drawRect:dirtyRect];
}
- (BOOL)allowsVibrancy { return NO; }
- (void)viewDidChangeEffectiveAppearance { [super viewDidChangeEffectiveAppearance]; self.needsDisplay = YES; }
@end

@interface MCEditorToolControl : NSSegmentedControl
@property NSInteger hoveredSegment;
@property NSInteger pressedSegment;
@property NSTrackingArea *toolTrackingArea;
@end
@interface MCEditorToolCell : NSSegmentedCell
@end
@implementation MCEditorToolCell
- (void)drawWithFrame:(NSRect)frame inView:(NSView *)view {
    MCEditorToolControl *control = (MCEditorToolControl *)view;
    for (NSInteger index = 0; index < self.segmentCount; index++) {
        NSRect slot = NSMakeRect(NSMinX(frame) + index * MCEditorToolWidth, NSMinY(frame), MCEditorToolWidth, NSHeight(frame));
        MCDrawToolBackground(slot, self.enabled && [self isEnabledForSegment:index], [self isSelectedForSegment:index],
                            control.hoveredSegment == index, control.pressedSegment == index);
        NSRect content = NSMakeRect(NSMinX(slot), NSMidY(slot) - 9, NSWidth(slot), 18);
        NSImage *image = [self imageForSegment:index];
        if (image) MCDrawToolIcon(image, content, self.enabled && [self isEnabledForSegment:index]);
        else [self drawSegment:index inFrame:content withView:view];
    }
}
@end
@implementation MCEditorToolControl
+ (Class)cellClass { return MCEditorToolCell.class; }
- (BOOL)allowsVibrancy { return NO; }
- (void)viewDidChangeEffectiveAppearance { [super viewDidChangeEffectiveAppearance]; self.needsDisplay = YES; }
- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) { _hoveredSegment = -1; _pressedSegment = -1; }
    return self;
}
- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (self.toolTrackingArea) [self removeTrackingArea:self.toolTrackingArea];
    self.toolTrackingArea = [[NSTrackingArea alloc] initWithRect:NSZeroRect
        options:NSTrackingMouseMoved | NSTrackingMouseEnteredAndExited | NSTrackingActiveInKeyWindow | NSTrackingInVisibleRect
        owner:self userInfo:nil];
    [self addTrackingArea:self.toolTrackingArea];
}
- (void)mouseMoved:(NSEvent *)event {
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    NSInteger index = (NSInteger)floor(point.x / MCEditorToolWidth);
    self.hoveredSegment = NSPointInRect(point, self.bounds) && index >= 0 && index < self.segmentCount ? index : -1;
    self.needsDisplay = YES;
}
- (void)mouseEntered:(NSEvent *)event { [self mouseMoved:event]; }
- (void)mouseExited:(__unused NSEvent *)event { self.hoveredSegment = -1; self.needsDisplay = YES; }
- (void)mouseDown:(NSEvent *)event {
    [self mouseMoved:event]; self.pressedSegment = self.hoveredSegment; self.needsDisplay = YES;
    [super mouseDown:event];
    self.pressedSegment = -1; self.needsDisplay = YES;
}
- (NSRect)focusRingMaskBounds { return self.bounds; }
- (void)drawFocusRingMask {
    NSInteger index = self.selectedSegment;
    if (index < 0) return;
    NSRect slot = NSMakeRect(index * MCEditorToolWidth, 0, MCEditorToolWidth, NSHeight(self.bounds));
    [[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(slot, 2, 2) xRadius:5 yRadius:5] fill];
}
@end

static NSError *MCEditorError(NSString *message) {
    return [NSError errorWithDomain:@"dev.moojicut.image-editor" code:1 userInfo:@{NSLocalizedDescriptionKey:message}];
}
static NSDictionary *MCCallCore(moonbit_string_t (*function)(moonbit_string_t), NSDictionary *request, NSError **error) {
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
    return value;
}
static NSDictionary *MCCallImage(moonbit_string_t (*function)(moonbit_string_t), NSDictionary *request, NSError **error) {
    return MCCallCore(function, request, error)[@"document"];
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
static NSRect MCAnnotationSelectionRect(NSDictionary *annotation) {
    if (![annotation[@"type"] isEqual:@"arrow"]) return MCAnnotationRect(annotation);
    CGFloat x = [annotation[@"x"] doubleValue], y = [annotation[@"y"] doubleValue];
    CGFloat x2 = [annotation[@"x2"] doubleValue], y2 = [annotation[@"y2"] doubleValue];
    return NSMakeRect(MIN(x,x2), MIN(y,y2), fabs(x2-x), fabs(y2-y));
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
        // Filled covers use the same RGBA style as every other annotation.
        [color setFill];
        NSRectFillUsingOperation(rect, NSCompositingOperationSourceOver);
    } else if ([kind isEqualToString:@"rect"]) {
        [color setStroke];
        NSBezierPath *path = [NSBezierPath bezierPathWithRect:rect];
        path.lineWidth = stroke;
        [path stroke];
    } else if ([kind isEqualToString:@"arrow"]) {
        NSPoint start = rect.origin, end = NSMakePoint([annotation[@"x2"] doubleValue], [annotation[@"y2"] doubleValue]);
        NSBezierPath *path = [NSBezierPath bezierPath];
        path.lineWidth = stroke;
        path.lineCapStyle = NSLineCapStyleRound;
        path.lineJoinStyle = NSLineJoinStyleRound;
        [path moveToPoint:start]; [path lineToPoint:end];
        [path moveToPoint:NSMakePoint(image_arrowhead_value(start.x, start.y, end.x, end.y, stroke, 0),
                                     image_arrowhead_value(start.x, start.y, end.x, end.y, stroke, 1))];
        [path lineToPoint:end];
        [path lineToPoint:NSMakePoint(image_arrowhead_value(start.x, start.y, end.x, end.y, stroke, 2),
                                     image_arrowhead_value(start.x, start.y, end.x, end.y, stroke, 3))];
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
static void MCDrawImage(NSImage *image, NSDictionary *document, NSDictionary *pending, NSRect liveTextRect) {
    NSRect rect = NSMakeRect(0, 0, [document[@"width"] doubleValue], [document[@"height"] doubleValue]);
    [NSGraphicsContext saveGraphicsState];
    NSRectClip(rect);
    [image drawInRect:rect fromRect:NSZeroRect operation:NSCompositingOperationCopy fraction:1 respectFlipped:YES hints:nil];
    NSArray *annotations = document[@"annotations"];
    for (NSDictionary *annotation in annotations) if (![annotation[@"type"] isEqualToString:@"redact"]) MCDrawAnnotation(annotation);
    if (pending && ![pending[@"type"] isEqualToString:@"redact"]) MCDrawAnnotation(pending);
    // The native text view paints covers above its glyphs. Exclude that area
    // here so translucent covers are blended once, including blank text space.
    NSRect excluded = NSIntersectionRect(rect, liveTextRect);
    if (!NSIsEmptyRect(excluded)) {
        NSBezierPath *clip = [NSBezierPath bezierPathWithRect:rect];
        [clip appendBezierPathWithRect:excluded];
        clip.windingRule = NSWindingRuleEvenOdd;
        [clip addClip];
    }
    for (NSDictionary *annotation in annotations) if ([annotation[@"type"] isEqualToString:@"redact"]) MCDrawAnnotation(annotation);
    if ([pending[@"type"] isEqualToString:@"redact"]) MCDrawAnnotation(pending);
    [NSGraphicsContext restoreGraphicsState];
}

typedef NS_ENUM(NSInteger, MCImageTool) { MCSelectTool, MCRectTool, MCArrowTool, MCTextTool, MCRedactTool };
static NSArray<NSDictionary *> *MCImageToolDescriptors(NSDictionary *configuration) {
    return configuration ? configuration[@"groups"][@"screenshot"] : @[
        @{@"id":@"builtin.image.rectangle", @"type":@"annotation", @"kind":@1, @"title":@"矩形", @"enabled":@YES},
        @{@"id":@"builtin.image.arrow", @"type":@"annotation", @"kind":@2, @"title":@"箭头", @"enabled":@YES},
        @{@"id":@"builtin.image.text", @"type":@"annotation", @"kind":@3, @"title":@"文字", @"enabled":@YES},
        @{@"id":@"builtin.image.cover", @"type":@"annotation", @"kind":@4, @"title":@"遮挡", @"enabled":@YES},
        @{@"id":@"builtin.image.pin", @"pluginId":@"builtin.pin", @"type":@"action", @"action":@"pin", @"title":@"贴图", @"enabled":@YES}];
}
static BOOL MCImageToolEnabled(NSDictionary *configuration, MCImageTool tool) {
    if (tool == MCSelectTool) return YES; // Host selection is not a configurable annotation tool.
    for (NSDictionary *entry in MCImageToolDescriptors(configuration))
        if ([entry[@"type"] isEqual:@"annotation"] && [entry[@"kind"] integerValue] == tool) return [entry[@"enabled"] boolValue];
    return NO;
}
static BOOL MCValidImageToolConfiguration(NSDictionary *candidate, NSError **error) {
    NSDictionary *groups = [candidate isKindOfClass:NSDictionary.class] ? candidate[@"groups"] : nil;
    NSArray *entries = [groups isKindOfClass:NSDictionary.class] ? groups[@"screenshot"] : nil;
    NSArray *ids = @[@"builtin.image.rectangle", @"builtin.image.arrow", @"builtin.image.text", @"builtin.image.cover"];
    NSMutableSet *seen = [NSMutableSet set];
    BOOL valid = [candidate isKindOfClass:NSDictionary.class] && [candidate[@"ok"] isKindOfClass:NSNumber.class] && [candidate[@"ok"] boolValue] &&
        [entries isKindOfClass:NSArray.class] && entries.count >= ids.count + 1 && entries.count <= 69;
    NSUInteger builtins = 0;
    if (valid) for (id entry in entries) {
        if (![entry isKindOfClass:NSDictionary.class] || ![entry[@"enabled"] isKindOfClass:NSNumber.class] ||
            ![entry[@"title"] isKindOfClass:NSString.class] || ![entry[@"id"] isKindOfClass:NSString.class] ||
            [seen containsObject:entry[@"id"]]) { valid = NO; break; }
        if ([entry[@"id"] isEqual:@"builtin.image.pin"]) {
            if (![entry[@"type"] isEqual:@"action"] || ![entry[@"action"] isEqual:@"pin"] ||
                ![entry[@"pluginId"] isEqual:@"builtin.pin"] || entry[@"kind"]) { valid = NO; break; }
            builtins++;
        } else if ([entry[@"action"] isEqual:@"run"]) {
            if (![entry[@"type"] isEqual:@"action"] || ![entry[@"pluginId"] isKindOfClass:NSString.class] ||
                ![entry[@"toolId"] isKindOfClass:NSString.class] || entry[@"kind"] ||
                ![entry[@"id"] isEqual:[NSString stringWithFormat:@"user.%@/%@",entry[@"pluginId"],entry[@"toolId"]]]) { valid = NO; break; }
        } else {
            if (![entry[@"type"] isEqual:@"annotation"] || ![entry[@"kind"] isKindOfClass:NSNumber.class]) { valid = NO; break; }
            NSInteger kind = [entry[@"kind"] integerValue];
            if (kind < MCRectTool || kind > MCRedactTool || [entry[@"kind"] doubleValue] != kind ||
                ![entry[@"id"] isEqual:ids[kind - 1]]) { valid = NO; break; }
            builtins++;
        }
        [seen addObject:entry[@"id"]];
    }
    valid = valid && builtins == 5;
    if (!valid && error) *error = MCEditorError(@"无法读取截图工具配置。");
    return valid;
}
@class MCImageCanvas;
@interface MCImageEditorController ()
@property (nonatomic, readwrite) NSWindow *window;
@property (nonatomic, readwrite) NSDictionary *document;
@property NSImage *image;
@property MCImageCanvas *canvas;
@property NSSegmentedControl *tools;
@property NSScrollView *toolScroll;
@property NSLayoutConstraint *toolScrollWidth;
@property NSArray<NSDictionary *> *visibleTools;
@property (nonatomic, copy, readwrite) NSString *pluginContextIdentifier;
@property (readonly) NSColorWell *color;
@property NSButton *undoButton;
@property NSButton *redoButton;
@property NSButton *confirmButton;
@property NSButton *cancelButton;
@property (readonly) NSTextField *fontSize;
@property (readonly) NSStepper *fontStepper;
@property NSStackView *toolbar;
@property NSScrollView *toolbarScroll;
@property NSScrollView *propertiesScroll;
@property NSView *workflowDivider;
@property MCStylePropertiesView *properties;
@property int32_t styleHandle;
@property int32_t captureUIHandle;
@property (readonly) NSStackView *colorGroup;
@property (readonly) NSStackView *fontGroup;
@property (readonly) NSStackView *strokeGroup;
@property (readonly) MCNumberControl *fontControl;
@property (readonly) MCNumberControl *strokeControl;
@property (readonly) MCColorControl *colorControl;
@property (readonly) NSTextField *lineWidth;
@property (readonly) NSStepper *strokeStepper;
@property NSButton *ocrButton;
@property NSButton *translateButton;
@property NSButton *scrollCaptureButton;
@property MCImageTool activeTool;
@property (nonatomic, copy, readwrite) NSDictionary *toolConfiguration;
- (BOOL)isToolEnabled:(MCImageTool)tool;
- (void)rebuildToolSegments;
- (void)selectActiveToolSegment;
- (BOOL)isPinActionConfigured;
- (void)syncPinAction;
- (NSDictionary *)pendingEditCommitPlan:(NSError **)error;
- (NSData *)renderDocumentPNGData:(NSDictionary *)document error:(NSError **)error;
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
- (void)syncContentActions;
- (BOOL)setCaptureRegion:(NSRect)rect;
- (void)pinImage:(id)sender;
- (void)chooseTool:(id)sender;
- (NSDictionary *)shapeEvent:(NSString *)phase point:(NSPoint)point;
- (void)addTextAtPoint:(NSPoint)point;
- (void)confirm:(id)sender;
@end

@interface MCInlineTextView : NSTextView
@property (weak) MCImageCanvas *canvas;
@property NSUndoManager *textUndo;
@end

@interface MCImageCanvas : MCSelectionSurface <NSTextViewDelegate>
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
    // Match the document's cover ordering without double-compositing alpha.
    for (NSDictionary *annotation in self.canvas.editor.document[@"annotations"]) {
        if (![annotation[@"type"] isEqual:@"redact"]) continue;
        NSRect cover = MCAnnotationRect(annotation);
        cover.origin.x -= [draft[@"x"] doubleValue];
        cover.origin.y -= [draft[@"y"] doubleValue];
        [MCAnnotationColor(annotation) setFill];
        NSRectFillUsingOperation(NSIntersectionRect(cover, self.bounds), NSCompositingOperationSourceOver);
    }
    [NSGraphicsContext restoreGraphicsState];
}
@end

@implementation MCImageCanvas
- (NSRect)imageFrame {
    if (self.editor.overlayMode) return self.bounds;
    CGFloat width = [self.editor.document[@"width"] doubleValue], height = [self.editor.document[@"height"] doubleValue];
    CGFloat scale = MIN((self.bounds.size.width - 32) / width, (self.bounds.size.height - 32) / height);
    scale = MAX(0.01, scale);
    return NSMakeRect((self.bounds.size.width - width * scale) / 2, (self.bounds.size.height - height * scale) / 2, width * scale, height * scale);
}
- (NSRect)captureRect {
    if (self.regionDragging) return self.regionGesture.preview;
    return self.editor.hasCaptureRegion ? MCAnnotationRect(self.editor.document[@"viewport"]) : NSZeroRect;
}
- (NSRect)selectionContentFrame { return self.imageFrame; }
- (NSSize)selectionContentSize { return NSMakeSize([self.editor.document[@"width"] doubleValue],[self.editor.document[@"height"] doubleValue]); }
- (NSRect)viewRectForImageRect:(NSRect)rect { return [self selectionViewRect:rect]; }
- (NSPoint)imagePoint:(NSEvent *)event { return [self selectionPointForEvent:event]; }
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
    NSRect image = [self imageFrame], rect = MCAnnotationSelectionRect(annotation);
    CGFloat scale = image.size.width / [self.editor.document[@"width"] doubleValue];
    return NSMakeRect(image.origin.x + rect.origin.x * scale, image.origin.y + rect.origin.y * scale,
                      rect.size.width * scale, rect.size.height * scale);
}
- (NSPoint)handlePoint:(NSInteger)handle inRect:(NSRect)rect {
    return MCSelectionHandlePoint(handle, rect);
}
- (NSInteger)handleAtPoint:(NSPoint)point {
    NSDictionary *annotation = [self selectedAnnotation];
    if (!annotation) return -1;
    if ([annotation[@"type"] isEqual:@"arrow"]) {
        for (NSNumber *handle in @[@0,@4]) {
            NSPoint center = [self selectionHandlePoint:handle.integerValue];
            if (MCSelectionHandleAtPoint(point, NSMakeRect(center.x,center.y,0,0), 6) >= 0) return handle.integerValue;
        }
        return -1;
    }
    return MCSelectionHandleAtPoint(point, [self selectionFrame], 6);
}
- (NSArray<NSNumber *> *)selectionHandles {
    return [[[self selectedAnnotation] objectForKey:@"type"] isEqual:@"arrow"] ? @[@0,@4] : @[@0,@1,@2,@3,@4,@5,@6,@7];
}
- (NSPoint)selectionHandlePoint:(NSInteger)handle {
    NSDictionary *annotation = [self selectedAnnotation];
    if (![annotation[@"type"] isEqual:@"arrow"]) return [self handlePoint:handle inRect:[self selectionFrame]];
    CGFloat x = [annotation[handle == 0 ? @"x" : @"x2"] doubleValue];
    CGFloat y = [annotation[handle == 0 ? @"y" : @"y2"] doubleValue];
    return [self viewRectForImageRect:NSMakeRect(x,y,0,0)].origin;
}
- (BOOL)selectionBorderAtPoint:(NSPoint)point {
    NSRect frame = [self selectionFrame];
    return [self selectedAnnotation] && ![[[self selectedAnnotation] objectForKey:@"type"] isEqual:@"arrow"] &&
        MCSelectionBorderContains(point, frame, 5);
}
- (NSView *)hitTest:(NSPoint)point {
    NSPoint local = [self convertPoint:point fromView:self.superview];
    if ([self handleAtPoint:local] >= 0 || [self selectionBorderAtPoint:local]) return self;
    return [super hitTest:point];
}
- (void)resetCursorRects {
    [super resetCursorRects];
    if (self.editor.overlayMode && !self.editor.hasCaptureRegion) {
        [self addCanvasCursorRect:self.bounds cursor:NSCursor.crosshairCursor];
    } else {
        NSRect region = [self viewRectForImageRect:self.editor.overlayMode ? [self captureRect] : MCAnnotationRect(self.editor.document[@"viewport"])];
        if (self.editor.activeTool != MCSelectTool)
            [self addCanvasCursorRect:region cursor:self.editor.activeTool == MCTextTool ? NSCursor.IBeamCursor : NSCursor.crosshairCursor];
        if (self.editor.overlayMode) for (NSInteger handle = 0; handle < 8; handle++) {
            NSPoint center = [self handlePoint:handle inRect:region];
            [self addCanvasCursorRect:NSMakeRect(center.x - 6, center.y - 6, 12, 12) cursor:NSCursor.crosshairCursor];
        }
    }
    if (![self selectedAnnotation]) return;
    NSRect frame = [self selectionFrame];
    if (![[[self selectedAnnotation] objectForKey:@"type"] isEqual:@"arrow"])
        [self addCanvasCursorRect:NSInsetRect(frame, -4, -4) cursor:NSCursor.openHandCursor];
    if (self.textView) [self addCanvasCursorRect:NSInsetRect(frame, 6, 6) cursor:NSCursor.IBeamCursor];
    for (NSNumber *number in [self selectionHandles]) {
        NSInteger handle = number.integerValue;
        NSPoint center = [self selectionHandlePoint:handle];
        NSCursor *cursor = (handle == 1 || handle == 5) ? NSCursor.resizeUpDownCursor :
            (handle == 3 || handle == 7) ? NSCursor.resizeLeftRightCursor : NSCursor.crosshairCursor;
        [self addCanvasCursorRect:NSMakeRect(center.x - 6, center.y - 6, 12, 12) cursor:cursor];
    }
}
- (void)addCanvasCursorRect:(NSRect)rect cursor:(NSCursor *)cursor {
    rect = NSIntersectionRect(rect, self.bounds);
    if (NSIsEmptyRect(rect)) return;
    NSView *hud = self.editor.floatingToolbar;
    NSRect occlusion = hud && !hud.hidden ? [self convertRect:hud.bounds fromView:hud] : NSZeroRect;
    NSRect overlap = NSIntersectionRect(rect, occlusion);
    if (NSIsEmptyRect(overlap)) { [self addCursorRect:rect cursor:cursor]; return; }
    // Cursor rectangles ignore sibling-view hit testing. Subtract the floating
    // controls explicitly, including when they overlap a selection/resize handle.
    NSRect pieces[] = {
        NSMakeRect(NSMinX(rect), NSMinY(rect), NSWidth(rect), NSMinY(overlap) - NSMinY(rect)),
        NSMakeRect(NSMinX(rect), NSMaxY(overlap), NSWidth(rect), NSMaxY(rect) - NSMaxY(overlap)),
        NSMakeRect(NSMinX(rect), NSMinY(overlap), NSMinX(overlap) - NSMinX(rect), NSHeight(overlap)),
        NSMakeRect(NSMaxX(overlap), NSMinY(overlap), NSMaxX(rect) - NSMaxX(overlap), NSHeight(overlap)),
    };
    for (NSUInteger index = 0; index < 4; index++)
        if (!NSIsEmptyRect(pieces[index])) [self addCursorRect:pieces[index] cursor:cursor];
}
- (void)setFrameSize:(NSSize)size {
    [super setFrameSize:size];
    [self updateTextFrame];
    [self.editor positionFloatingToolbar];
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
    if (![self.editor isToolEnabled:MCTextTool]) return;
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
    MCDrawImage(self.editor.image, display, self.pending, self.textView ? MCAnnotationRect(self.textDraft) : NSZeroRect);
    [NSGraphicsContext restoreGraphicsState];
    if (self.editor.overlayMode) {
        NSRect region = [self viewRectForImageRect:[self captureRect]];
        [self drawRegion:region dimensions:[self captureRect].size handles:YES hint:@"拖动框选截图范围 · Esc 取消"];
    }
    if ([self selectedAnnotation]) {
        NSRect selection = [self selectionFrame];
        if (![[[self selectedAnnotation] objectForKey:@"type"] isEqual:@"arrow"]) {
            NSBezierPath *outline = [NSBezierPath bezierPathWithRect:NSInsetRect(selection, -1, -1)];
            [NSColor.controlAccentColor setStroke]; outline.lineWidth = 1; [outline stroke];
        }
        for (NSNumber *number in [self selectionHandles]) {
            NSPoint point = [self selectionHandlePoint:number.integerValue];
            NSBezierPath *box = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(point.x - 3, point.y - 3, 6, 6) xRadius:1 yRadius:1];
            [MCSelectionHandleColor() setFill]; [box fill];
            [NSColor.controlAccentColor setStroke]; [box stroke];
        }
    }
}
- (void)mouseDown:(NSEvent *)event {
    NSPoint local = [self convertPoint:event.locationInWindow fromView:nil];
    NSInteger handle = [self handleAtPoint:local];
    BOOL border = [self selectionBorderAtPoint:local];
    if (handle >= 0 || (border && self.textView)) {
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
    NSRect region = [self captureRect];
    if ((self.editor.activeTool == MCSelectTool || self.editor.activeTool == MCTextTool) &&
        (!self.editor.overlayMode || NSPointInRect(self.start, region))) {
        CGFloat scale = [self imageFrame].size.width / [self.editor.document[@"width"] doubleValue];
        NSDictionary *hit = MCCallImage(image_selection, @{@"action":@"hit", @"annotations":self.editor.document[@"annotations"],
            @"x":@(self.start.x), @"y":@(self.start.y), @"tolerance":@(5 / scale),
            @"selectedID":self.selectedID ?: @"",
            @"textOnly":@(self.editor.activeTool == MCTextTool)}, NULL);
        for (NSDictionary *annotation in self.editor.document[@"annotations"]) {
            if (![annotation[@"id"] isEqual:hit[@"id"]]) continue;
            self.selectedID = annotation[@"id"];
            [self.editor syncTextControls];
            if (event.clickCount >= 2 && [annotation[@"type"] isEqual:@"text"]) [self beginEditingText:annotation];
            else { self.transformOriginal = annotation; self.resizeHandle = -1; self.dragging = YES; }
            [self updateTextFrame];
            return;
        }
    }
    NSInteger operation = self.editor.overlayMode ? MCSelectionHitTest(self.editor.hasCaptureRegion,
        region, [self viewRectForImageRect:region], self.start, local) : MCSelectionNone;
    if (operation != MCSelectionNone) {
        if ([self beginRegion:operation event:event rect:region]) {
            self.selectedID = nil;
            [self.editor positionFloatingToolbar];
            self.needsDisplay = YES;
        }
        return;
    }
    self.selectedID = nil;
    [self.editor syncTextControls];
    if (self.editor.activeTool == MCTextTool) { [self.editor addTextAtPoint:self.start]; return; }
    if (self.editor.activeTool == MCSelectTool) { self.needsDisplay = YES; return; }
    NSDictionary *begun = [self.editor shapeEvent:@"begin" point:self.start];
    self.dragging = [begun[@"active"] boolValue];
}
- (NSDictionary *)transformedAnnotationAt:(NSPoint)point {
    if (self.resizeHandle < 0 || ![self.transformOriginal[@"type"] isEqual:@"text"]) {
        return MCCallImage(image_selection, @{@"action":@"transform", @"annotation":self.transformOriginal,
            @"anchorX":@(self.start.x), @"anchorY":@(self.start.y), @"x":@(point.x), @"y":@(point.y),
            @"handle":@(self.resizeHandle), @"sourceWidth":self.editor.document[@"width"],
            @"sourceHeight":self.editor.document[@"height"]}, NULL) ?: self.transformOriginal;
    }
    NSMutableDictionary *result = [self.transformOriginal mutableCopy];
    NSRect original = MCAnnotationRect(result), rect = original;
    CGFloat width = [self.editor.document[@"width"] doubleValue], height = [self.editor.document[@"height"] doubleValue];
    CGFloat dx = point.x - self.start.x, dy = point.y - self.start.y;
    NSInteger handle = self.resizeHandle;
    if (handle % 2 == 0) {
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
        [self updateRegion:event];
        self.needsDisplay = YES;
        [self.window invalidateCursorRectsForView:self];
        return;
    }
    if (!self.dragging) return;
    if (self.transformOriginal) {
        self.transformPreview = [self transformedAnnotationAt:[self imagePoint:event]];
        [self.editor syncTextControls];
    } else {
        id preview = [self.editor shapeEvent:@"move" point:[self imagePoint:event]][@"preview"];
        self.pending = [preview isKindOfClass:NSDictionary.class] ? preview : nil;
    }
    self.needsDisplay = YES;
}
- (void)mouseUp:(NSEvent *)event {
    if (self.regionDragging) {
        NSRect rect;
        if ([self finishRegion:event rect:&rect]) [self.editor setCaptureRegion:rect];
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
    id command = [self.editor shapeEvent:@"end" point:[self imagePoint:event]][@"command"];
    self.pending = nil;
    if ([command isKindOfClass:NSDictionary.class]) [self.editor applyCommand:command];
    self.needsDisplay = YES;
}
- (void)cancelGesture {
    [self.editor shapeEvent:@"cancel" point:NSZeroPoint];
    self.dragging = NO; self.pending = nil; self.transformOriginal = nil; self.transformPreview = nil;
    [self cancelRegion];
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
- (BOOL)isToolEnabled:(MCImageTool)tool { return MCImageToolEnabled(self.toolConfiguration, tool); }
- (BOOL)isPinActionConfigured {
    for (NSDictionary *entry in MCImageToolDescriptors(self.toolConfiguration))
        if ([entry[@"id"] isEqual:@"builtin.image.pin"]) return [entry[@"enabled"] boolValue];
    return NO;
}
- (void)syncPinAction {
    BOOL enabled = [self isPinActionConfigured] && self.onPinPNGData != nil;
    NSString *hint = enabled ? @"贴图置顶" : @"贴图已关闭，可在设置中启用";
    self.pinButton.enabled = enabled;
    self.pinButton.hidden = ![self isPinActionConfigured];
    self.pinButton.toolTip = hint;
}

- (void)selectActiveToolSegment {
    self.tools.selectedSegment = -1;
    for (NSInteger index = 0; index < self.tools.segmentCount; index++)
        if ([self.tools tagForSegment:index] == self.activeTool) { self.tools.selectedSegment = index; break; }
}
- (void)rebuildToolSegments {
    if (!self.tools) return;
    NSMutableArray *visible = [NSMutableArray arrayWithObject:@{@"kind":@0, @"title":@"选择"}];
    for (NSDictionary *entry in MCImageToolDescriptors(self.toolConfiguration))
        if ([entry[@"enabled"] boolValue] && ![entry[@"id"] isEqual:@"builtin.image.pin"]) [visible addObject:entry];
    self.visibleTools = visible;
    self.tools.segmentCount = visible.count;
    const MCIcon icons[] = {MC_ICON_SELECT, MC_ICON_RECTANGLE, MC_ICON_ARROW, MC_ICON_TEXT, MC_ICON_REDACT};
    for (NSUInteger index = 0; index < visible.count; index++) {
        NSDictionary *entry = visible[index];
        NSInteger kind = [entry[@"kind"] integerValue];
        NSString *title = entry[@"title"];
        BOOL userAction = [entry[@"action"] isEqual:@"run"];
        NSImage *icon = userAction ? (self.pluginIcons[entry[@"id"]] ?: [NSImage imageWithSystemSymbolName:@"puzzlepiece.extension" accessibilityDescription:title]) : MCIconImage(icons[kind], title);
        icon = [icon copy];
        CGFloat extent = MAX(icon.size.width, icon.size.height);
        if (extent > 0) icon.size = NSMakeSize(icon.size.width * 18 / extent, icon.size.height * 18 / extent);
        icon.accessibilityDescription = title;
        [self.tools setTag:userAction ? (NSInteger)(1000 + index) : kind forSegment:index];
        [self.tools setEnabled:!userAction || self.onUserTool != nil forSegment:index];
        [self.tools setToolTip:title forSegment:index];
        [self.tools setImage:icon forSegment:index];
        [self.tools setLabel:icon ? @"" : title forSegment:index];
        [self.tools setImageScaling:NSImageScaleProportionallyDown forSegment:index];
        // AppKit adds a one-point segment separator to the tracking geometry.
        // Reserve it inside the 30pt slot so the last plugin is not clipped and
        // hit targets cannot drift progressively from our borderless drawing.
        [self.tools setWidth:MCEditorToolWidth - 1 forSegment:index];
    }
    [self selectActiveToolSegment];
    [self syncPinAction];
    [self.tools setFrameSize:NSMakeSize(visible.count * MCEditorToolWidth, MCEditorToolHeight)];
    self.toolScrollWidth.constant = MIN(8 * MCEditorToolWidth, NSWidth(self.tools.frame));
    [self positionFloatingToolbar];
}
- (BOOL)configurationEndsCurrentTool:(NSDictionary *)candidate {
    return !MCImageToolEnabled(candidate, self.activeTool) ||
        (self.canvas.textView && [self isToolEnabled:MCTextTool] && !MCImageToolEnabled(candidate, MCTextTool));
}
// Construct the exact document change without changing the editor, its field editor,
// IME state, style bank or history. Capture preflights every screen before applying.
- (NSDictionary *)toolConfigurationCommitPlan:(NSDictionary *)candidate error:(NSError **)error {
    if (!MCValidImageToolConfiguration(candidate, error)) return nil;
    if (![self configurationEndsCurrentTool:candidate]) return @{};
    return [self pendingEditCommitPlan:error];
}
- (NSDictionary *)pendingEditCommitPlan:(NSError **)error {
    if (self.canvas.textView.hasMarkedText) {
        if (error) *error = MCEditorError(@"请先完成中文输入，再执行此操作。");
        return nil;
    }
    NSMutableDictionary *fields = [NSMutableDictionary dictionary];
    NSArray<MCNumberControl *> *controls = self.properties ?
        @[self.fontControl, self.strokeControl, self.colorControl.opacityControl] : @[];
    const int32_t properties[] = {MC_STYLE_FONT, MC_STYLE_STROKE, MC_STYLE_OPACITY};
    for (NSUInteger index = 0; index < controls.count; index++) {
        MCNumberControl *control = controls[index];
        NSText *editor = control.field.currentEditor;
        if (!editor) continue;
        if ([editor isKindOfClass:NSTextView.class] && [(NSTextView *)editor hasMarkedText]) {
            if (error) *error = MCEditorError(@"请先完成输入，再执行此操作。");
            return nil;
        }
        NSScanner *scanner = [NSScanner scannerWithString:[editor.string stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]];
        scanner.locale = [(NSNumberFormatter *)control.field.formatter locale];
        double value = 0;
        if (![scanner scanDouble:&value] || !scanner.isAtEnd || !isfinite(value) ||
            value < control.stepper.minValue || value > control.stepper.maxValue) {
            if (error) *error = MCEditorError(@"请先填写有效的标注属性，再执行此操作。");
            return nil;
        }
        fields[@(properties[index])] = @(properties[index] == MC_STYLE_OPACITY ? value / 100 : value);
    }
    NSDictionary *selected = [self.canvas selectedAnnotation];
    NSDictionary *original = nil;
    for (NSDictionary *annotation in self.document[@"annotations"])
        if ([annotation[@"id"] isEqual:self.canvas.selectedID]) { original = annotation; break; }
    NSMutableDictionary *annotation = [selected mutableCopy];
    if (self.canvas.textView) annotation[@"text"] = self.canvas.textView.string;
    if (fields[@(MC_STYLE_STROKE)]) annotation[@"stroke"] = fields[@(MC_STYLE_STROKE)];
    if (fields[@(MC_STYLE_OPACITY)]) annotation[@"opacity"] = fields[@(MC_STYLE_OPACITY)];
    if (fields[@(MC_STYLE_FONT)]) {
        annotation[@"fontSize"] = fields[@(MC_STYLE_FONT)];
        if (annotation) annotation[@"height"] = @(MIN(MCTextHeight(annotation), [self.document[@"height"] doubleValue] - [annotation[@"y"] doubleValue]));
    }
    NSDictionary *command = nil;
    if (self.canvas.textView) {
        BOOL empty = [self.canvas.textView.string stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].length == 0;
        if (empty && original) command = @{@"type":@"remove", @"ids":@[self.canvas.selectedID]};
        else if (!empty && ![original isEqual:annotation]) command = original ?
            @{@"type":@"update", @"id":self.canvas.selectedID, @"patch":annotation} : @{@"type":@"add", @"annotations":@[annotation]};
    } else if (selected && fields.count && ![selected isEqual:annotation]) {
        command = @{@"type":@"update", @"id":self.canvas.selectedID, @"patch":annotation};
    }
    NSMutableDictionary *plan = [@{@"fields":fields} mutableCopy];
    if (!selected || (self.canvas.textView && !original)) plan[@"defaultTool"] = @(self.canvas.textView ? MCTextTool : self.activeTool);
    if (annotation) plan[@"annotation"] = annotation;
    if (command) {
        NSDictionary *document = MCCallImage(image_apply, @{@"document":self.document,
            @"expectedRevision":self.document[@"revision"], @"command":command}, error);
        if (!document) return nil;
        plan[@"document"] = document;
    }
    return plan;
}
- (BOOL)canApplyToolConfiguration:(NSDictionary *)candidate error:(NSError **)error {
    NSAssert(NSThread.isMainThread, @"Tool configuration must be applied on the main thread");
    return [self toolConfigurationCommitPlan:candidate error:error] != nil;
}
- (void)applyToolConfiguration:(NSDictionary *)candidate {
    NSAssert(NSThread.isMainThread, @"Tool configuration must be applied on the main thread");
    NSError *error = nil;
    NSDictionary *plan = [self toolConfigurationCommitPlan:candidate error:&error];
    if (!plan) return; // A defensive caller must not force a failed preflight through.
    if ([self configurationEndsCurrentTool:candidate]) {
        NSDictionary *fields = plan[@"fields"];
        if (plan[@"defaultTool"]) for (NSNumber *property in fields)
            editor_style_set(self.styleHandle, [plan[@"defaultTool"] intValue], property.intValue, [fields[property] doubleValue]);
        if (plan[@"document"]) self.document = plan[@"document"];
        if (self.canvas.textView) self.canvas.textDraft = [plan[@"annotation"] mutableCopy];
        if (fields[@(MC_STYLE_FONT)]) self.fontControl.value = [fields[@(MC_STYLE_FONT)] doubleValue];
        if (fields[@(MC_STYLE_STROKE)]) self.strokeControl.value = [fields[@(MC_STYLE_STROKE)] doubleValue];
        if (fields[@(MC_STYLE_OPACITY)]) self.colorControl.color = [self.colorControl.color colorWithAlphaComponent:[fields[@(MC_STYLE_OPACITY)] doubleValue]];
        // The document already contains the validated edit; this only ends the
        // native text transaction and restores shortcuts, without a second undo.
        if (![self.canvas finishTextEditing:YES]) return;
        [self.window makeFirstResponder:self.canvas];
        [self.canvas cancelGesture];
        self.canvas.selectedID = nil;
        self.activeTool = MCSelectTool;
        self.toolConfiguration = candidate;
        [self rebuildToolSegments];
        [self refresh];
    } else {
        self.toolConfiguration = candidate;
        // A reorder or unrelated disable must not replace controls, reset style
        // defaults, end marked text, or clear a gesture in progress.
        [self rebuildToolSegments];
    }
}
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
    _pluginContextIdentifier = NSUUID.UUID.UUIDString;
    _pluginIcons = @{};
    _styleHandle = editor_style_create();
    _captureUIHandle = capture_ui_open(bitmap.pixelsWide, bitmap.pixelsHigh);
    if (!_styleHandle || !_captureUIHandle) {
        if (error) *error = MCEditorError(@"无法创建标注样式，请关闭其他编辑窗口后重试。");
        return nil;
    }
    _image = [[NSImage alloc] initWithSize:NSMakeSize(bitmap.pixelsWide, bitmap.pixelsHigh)];
    [_image addRepresentation:bitmap];
    return self;
}
- (void)dealloc { editor_style_dispose(_styleHandle); capture_ui_close(_captureUIHandle); }
- (NSColorWell *)color { return self.properties.colorControl.well; }
- (NSTextField *)fontSize { return self.properties.fontControl.field; }
- (NSStepper *)fontStepper { return self.properties.fontControl.stepper; }
- (NSStackView *)colorGroup { return self.properties.colorControl; }
- (NSStackView *)fontGroup { return self.properties.fontControl; }
- (NSStackView *)strokeGroup { return self.properties.strokeControl; }
- (MCColorControl *)colorControl { return self.properties.colorControl; }
- (MCNumberControl *)fontControl { return self.properties.fontControl; }
- (MCNumberControl *)strokeControl { return self.properties.strokeControl; }
- (NSTextField *)lineWidth { return self.properties.strokeControl.field; }
- (NSStepper *)strokeStepper { return self.properties.strokeControl.stepper; }
- (NSButton *)button:(NSString *)title action:(SEL)action key:(NSString *)key {
    NSButton *button = [MCEditorToolButton buttonWithTitle:title target:self action:action];
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
    ((NSButtonCell *)button.cell).highlightsBy = NSNoCellMask;
    ((NSButtonCell *)button.cell).showsStateBy = NSNoCellMask;
    // MCEditorToolButton and MCEditorToolCell share explicit template drawing.
    button.contentTintColor = nil;
    button.title = @"";
    button.bezelStyle = NSBezelStyleTexturedRounded;
    [button.widthAnchor constraintEqualToConstant:MCEditorToolWidth].active = YES;
    [button.heightAnchor constraintEqualToConstant:MCEditorToolHeight].active = YES;
}
- (NSButton *)unavailableButton:(MCIcon)icon label:(NSString *)label {
    NSButton *button = [self button:label action:NULL key:nil];
    [self configureIconButton:button icon:icon label:label shortcut:nil];
    button.enabled = NO;
    button.toolTip = [label stringByAppendingString:@" · 尚未开放"];
    button.accessibilityHelp = @"尚未开放";
    return button;
}
- (NSView *)toolbarDivider {
    // Separators own their group padding; icon centers otherwise stay exactly
    // one tool width apart on both sides of the segmented control.
    NSView *container = [NSView new];
    NSBox *divider = [[NSBox alloc] initWithFrame:NSMakeRect(4, 0, 1, 18)];
    divider.boxType = NSBoxSeparator;
    [container addSubview:divider];
    [container.widthAnchor constraintEqualToConstant:9].active = YES;
    [container.heightAnchor constraintEqualToConstant:18].active = YES;
    return container;
}
- (void)prepareWindow {
    if (!self.window) {
        if (!self.captureUIHandle) self.captureUIHandle = capture_ui_open([self.document[@"width"] doubleValue], [self.document[@"height"] doubleValue]);
        NSScreen *screen = NSScreen.mainScreen ?: NSScreen.screens.firstObject;
        CGFloat width = MIN(1100, screen.visibleFrame.size.width - 80), height = MIN(760, screen.visibleFrame.size.height - 100);
        self.window = [[MCSelectionWindow alloc] initWithContentRect:NSMakeRect(0, 0, width, height)
            styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable backing:NSBackingStoreBuffered defer:NO];
        self.window.releasedWhenClosed = NO;
        self.window.delegate = self;
        self.window.title = @"Mooji Cut · 标注截图";
        self.window.minSize = NSMakeSize(540, 400);
        NSView *root = self.window.contentView;
        self.canvas = [[MCImageCanvas alloc] initWithFrame:NSMakeRect(0, 0, width, height - 104)];
        self.canvas.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        self.canvas.editor = self;
        self.canvas.accessibilityLabel = @"截图标注画布";
        [root addSubview:self.canvas];
        self.tools = [MCEditorToolControl segmentedControlWithLabels:@[@"选择"] trackingMode:NSSegmentSwitchTrackingSelectOne target:self action:@selector(chooseTool:)];
        // Native segment tracking with our own consistent, bezel-free drawing.
        self.tools.segmentStyle = NSSegmentStyleTexturedSquare;
        self.tools.cell.bordered = NO;
        self.tools.cell.bezeled = NO;
        self.activeTool = [self isToolEnabled:MCRectTool] ? MCRectTool : MCSelectTool;
        [self rebuildToolSegments];
        self.tools.accessibilityLabel = @"截图工具";
        self.properties = [[MCStylePropertiesView alloc] initWithFrame:NSZeroRect];
        __weak MCImageEditorController *weakSelf = self;
        self.properties.onChange = ^(id sender) { [weakSelf styleChanged:sender]; };
        self.undoButton = [self button:@"撤销" action:@selector(undo:) key:@"z"];
        self.redoButton = [self button:@"重做" action:@selector(redo:) key:@"z"];
        [self configureIconButton:self.undoButton icon:MC_ICON_UNDO label:@"撤销" shortcut:@"⌘Z"];
        [self configureIconButton:self.redoButton icon:MC_ICON_REDO label:@"重做" shortcut:@"⇧⌘Z"];
        self.undoButton.keyEquivalentModifierMask = NSEventModifierFlagCommand;
        self.redoButton.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagShift;
        self.pinButton = [self button:@"贴图" action:@selector(pinImage:) key:nil];
        [self configureIconButton:self.pinButton icon:MC_ICON_PIN label:@"贴图置顶" shortcut:nil];
        self.pinButton.toolTip = @"将编辑结果置顶显示在桌面";
        self.cancelButton = [self button:@"取消" action:@selector(cancel:) key:@"\e"];
        [self configureIconButton:self.cancelButton icon:MC_ICON_CLOSE label:@"取消截图" shortcut:@"Esc"];
        self.cancelButton.keyEquivalentModifierMask = 0;
        self.confirmButton = [self button:@"确认并复制" action:@selector(confirm:) key:@"\r"];
        [self configureIconButton:self.confirmButton icon:MC_ICON_CHECK label:@"确认并复制" shortcut:@"Return"];
        self.confirmButton.keyEquivalentModifierMask = 0;
        self.ocrButton = [self unavailableButton:MC_ICON_OCR label:@"文字识别与翻译"];
        self.translateButton = [self unavailableButton:MC_ICON_TRANSLATE label:@"翻译"];
        self.scrollCaptureButton = [self unavailableButton:MC_ICON_CHEVRON_DOWN label:@"滚动截图"];
        NSView *spacer = [NSView new];
        [spacer setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
        self.toolScroll = [NSScrollView new];
        self.toolScroll.drawsBackground = NO; self.toolScroll.borderType = NSNoBorder;
        self.toolScroll.hasHorizontalScroller = YES; self.toolScroll.autohidesScrollers = YES;
        self.toolScroll.scrollerStyle = NSScrollerStyleOverlay; self.toolScroll.documentView = self.tools;
        self.toolScrollWidth = [self.toolScroll.widthAnchor constraintEqualToConstant:MIN(8 * MCEditorToolWidth, NSWidth(self.tools.frame))];
        self.toolScrollWidth.active = YES; [self.toolScroll.heightAnchor constraintEqualToConstant:MCEditorToolHeight].active = YES;
        self.workflowDivider = [self toolbarDivider];
        self.toolbar = [NSStackView stackViewWithViews:@[self.toolScroll, self.ocrButton,
            self.translateButton, self.scrollCaptureButton, self.undoButton, self.redoButton, spacer,
            self.workflowDivider, self.pinButton, self.cancelButton, self.confirmButton]];
        self.toolbar.orientation = NSUserInterfaceLayoutOrientationHorizontal;
        self.toolbar.alignment = NSLayoutAttributeCenterY;
        self.toolbar.detachesHiddenViews = YES;
        self.toolbar.spacing = 0;
        self.toolbar.frame = NSMakeRect(18, height - 46, width - 36, 32);
        self.toolbar.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
        [root addSubview:self.toolbar];
        self.properties.frame = NSMakeRect(24, height - 86, width - 48, 28);
        self.properties.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
        [root addSubview:self.properties];
        [self syncContentActions];
        [self.window center];
    }
    [self refresh];
}
- (void)prepareOverlayInFrame:(NSRect)screenFrame {
    [self prepareWindow];
    self.overlayMode = YES;
    self.hasCaptureRegion = NO;
    [(MCSelectionWindow *)self.window configureForScreenFrame:screenFrame];
    NSView *root = self.window.contentView;
    self.canvas.frame = root.bounds;
    self.canvas.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.floatingToolbar = [[NSVisualEffectView alloc] initWithFrame:NSZeroRect];
    self.floatingToolbar.material = NSVisualEffectMaterialPopover;
    self.floatingToolbar.blendingMode = NSVisualEffectBlendingModeWithinWindow;
    self.floatingToolbar.state = NSVisualEffectStateActive;
    self.floatingToolbar.wantsLayer = YES;
    self.floatingToolbar.layer.cornerRadius = 8;
    self.properties.spacing = 8;
    self.floatingToolbar.layer.masksToBounds = YES;
    self.floatingToolbar.hidden = YES;
    for (NSView *view in @[self.toolbar, self.properties]) {
        [view removeFromSuperview];
        view.autoresizingMask = NSViewNotSizable;
        NSScrollView *scroll = [NSScrollView new];
        scroll.drawsBackground = NO; scroll.borderType = NSNoBorder;
        scroll.hasHorizontalScroller = YES; scroll.autohidesScrollers = YES;
        scroll.scrollerStyle = NSScrollerStyleOverlay; scroll.documentView = view;
        [self.floatingToolbar addSubview:scroll];
        if (view == self.toolbar) self.toolbarScroll = scroll; else self.propertiesScroll = scroll;
    }
    [root addSubview:self.floatingToolbar];
    [self syncContentActions];
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
        self.activeTool = MCSelectTool;
        [self selectActiveToolSegment];
    } else if (![viewport isEqual:self.document[@"viewport"]]) {
        passed = [self applyCommand:@{@"type":@"crop", @"rect":viewport}];
    }
    [self refresh]; [self positionFloatingToolbar];
    return passed;
}
- (void)positionFloatingToolbar {
    if (!self.overlayMode || !self.floatingToolbar) return;
    self.floatingToolbar.hidden = !self.hasCaptureRegion || self.canvas.regionDragging;
    [self.window invalidateCursorRectsForView:self.canvas];
    if (self.floatingToolbar.hidden) return;
    NSView *root = self.window.contentView;
    NSRect region = [self.canvas viewRectForImageRect:MCAnnotationRect(self.document[@"viewport"])];
    region = [self.canvas convertRect:region toView:root];
    CGFloat margin = MIN(8, NSWidth(root.bounds) / 8);
    CGFloat available = MAX(1, NSWidth(root.bounds) - 2 * margin);
    CGFloat inset = MIN(6, available / 8);
    CGFloat contentAvailable = MAX(1, available - 2 * inset);
    self.toolbar.spacing = 0;
    self.toolScrollWidth.constant = MIN(8 * MCEditorToolWidth, NSWidth(self.tools.frame));
    CGFloat rowWidth = ceil(self.toolbar.fittingSize.width);
    if (rowWidth > contentAvailable) {
        self.toolScrollWidth.constant = MAX(35, self.toolScrollWidth.constant - (rowWidth - contentAvailable));
        rowWidth = ceil(self.toolbar.fittingSize.width);
    }
    // Hidden property groups detach from the stack, so each tool contributes
    // only its actual controls. Keep numeric/text fields at their natural width;
    // exceptionally narrow displays scroll the row instead of squeezing input.
    BOOL hasProperties = NO;
    for (NSView *view in self.properties.arrangedSubviews) if (!view.hidden) { hasProperties = YES; break; }
    CGFloat propertiesWidth = hasProperties ? ceil(self.properties.fittingSize.width) : 0;
    CGFloat rowHeight = MCEditorToolHeight, padding = 6;
    double *frame = capture_ui_toolbar_frame(NSWidth(root.bounds), NSHeight(root.bounds),
        NSMinX(region), NSHeight(root.bounds) - NSMaxY(region), NSWidth(region), NSHeight(region), rowWidth, propertiesWidth);
    CGFloat x = frame[0], width = frame[2], height = frame[3];
    CGFloat y = NSHeight(root.bounds) - frame[1] - height;
    moonbit_decref(frame);
    self.floatingToolbar.frame = NSMakeRect(x, y, width, height);
    CGFloat viewportWidth = MAX(1, width - 2 * inset);
    self.toolbarScroll.frame = NSMakeRect(inset, height - padding - rowHeight, viewportWidth, rowHeight);
    self.propertiesScroll.hidden = !hasProperties;
    self.propertiesScroll.frame = NSMakeRect(inset, padding, viewportWidth, rowHeight);
    self.toolbar.frame = NSMakeRect(0, 0, MAX(rowWidth, viewportWidth), rowHeight);
    self.properties.frame = NSMakeRect(0, 0, MAX(propertiesWidth, viewportWidth), rowHeight);
    [self.floatingToolbar layoutSubtreeIfNeeded];
    [self.window invalidateCursorRectsForView:self.canvas];
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
    [self syncPinAction];
    [self positionFloatingToolbar];
}
- (void)setOnUserTool:(void (^)(MCImageEditorController *,NSString *))handler {
    _onUserTool = [handler copy]; [self rebuildToolSegments];
}
- (void)setPluginIcons:(NSDictionary<NSString *,NSImage *> *)icons {
    _pluginIcons = [icons copy] ?: @{}; [self rebuildToolSegments];
}
- (NSDictionary *)pluginCaptureMetadata {
    if (!self.window || (self.overlayMode && !self.hasCaptureRegion)) return nil;
    NSDictionary *viewport = self.document[@"viewport"];
    return @{@"width":viewport[@"width"], @"height":viewport[@"height"], @"format":@"png", @"revision":self.document[@"revision"]};
}
- (NSDictionary *)captureContentSnapshot {
    NSAssert(NSThread.isMainThread, @"Capture content snapshots belong to the editor's main thread");
    if (!self.window || !self.canvas || self.canvas.dragging || self.canvas.regionDragging ||
        (self.overlayMode && !self.hasCaptureRegion)) return nil;
    NSDictionary *plan = [self pendingEditCommitPlan:NULL];
    if (!plan) return nil; // Invalid fields and IME composition cannot retain a lease.
    NSDictionary *document = plan[@"document"] ?: self.document;
    // Compare exactly the document content used by capturePNGData, without
    // rendering pixels on the lease timer. Committing an unchanged draft may
    // alter revision/history, focus, selection and tool defaults, but not the
    // image supplied to OCR. Those UI/transaction details are not content.
    NSDictionary *(^annotation)(NSDictionary *) = ^NSDictionary *(NSDictionary *value) {
        return [[NSDictionary alloc] initWithDictionary:value ?: @{} copyItems:YES];
    };
    // Annotation and viewport values are scalar JSON. Copy the scalars too so
    // the saved identity can never alias live mutable text storage.
    NSMutableArray *annotations = [NSMutableArray array];
    for (NSDictionary *value in document[@"annotations"]) [annotations addObject:annotation(value)];
    return @{@"context":self.pluginContextIdentifier, @"width":document[@"width"], @"height":document[@"height"],
        @"viewport":annotation(document[@"viewport"]), @"annotations":[annotations copy]};
}
- (void)showPluginMessage:(NSString *)message {
    self.properties.status.stringValue = message; self.properties.status.hidden = NO;
    [self positionFloatingToolbar];
}
- (void)setOnOCR:(void (^)(MCImageEditorController *))handler {
    _onOCR = [handler copy]; [self syncContentActions];
}
- (void)setOnTranslate:(void (^)(MCImageEditorController *))handler {
    _onTranslate = [handler copy]; [self syncContentActions];
}
- (void)setOnScrollCapture:(void (^)(MCImageEditorController *))handler {
    _onScrollCapture = [handler copy]; [self syncContentActions];
}
- (void)syncContentActions {
    self.ocrButton.enabled = self.onOCR != nil; self.translateButton.enabled = NO;
    self.ocrButton.hidden = self.overlayMode && !self.onOCR;
    self.translateButton.hidden = YES; // Translation is a page in the same text window.
    self.scrollCaptureButton.enabled = self.onScrollCapture != nil;
    self.scrollCaptureButton.hidden = !self.overlayMode || !self.onScrollCapture;
    self.ocrButton.target = self; self.ocrButton.action = @selector(runOCR:);
    self.translateButton.target = self; self.translateButton.action = @selector(runTranslate:);
    self.scrollCaptureButton.target = self; self.scrollCaptureButton.action = @selector(runScrollCapture:);
    self.scrollCaptureButton.toolTip = @"滚动截图";
    self.scrollCaptureButton.accessibilityHelp = nil;
    self.ocrButton.toolTip = self.onOCR ? @"文字识别与翻译" : @"文字识别与翻译 · 尚未开放";
    self.translateButton.toolTip = self.onTranslate ? @"翻译" : @"翻译 · 尚未开放";
    self.ocrButton.accessibilityHelp = self.onOCR ? nil : @"尚未开放";
    self.translateButton.accessibilityHelp = self.onTranslate ? nil : @"尚未开放";
    [self positionFloatingToolbar];
}
- (void)runOCR:(__unused id)sender { if (self.onOCR && self.pluginCaptureMetadata) self.onOCR(self); }
- (void)runTranslate:(__unused id)sender { if (self.onTranslate && self.pluginCaptureMetadata) self.onTranslate(self); }
- (void)runScrollCapture:(__unused id)sender {
    if (self.overlayMode && self.onScrollCapture && self.pluginCaptureMetadata) self.onScrollCapture(self);
}
- (void)setOnPinPNGData:(BOOL (^)(NSData *))handler {
    _onPinPNGData = [handler copy];
    [self syncPinAction];
    [self positionFloatingToolbar];
}
- (void)showError:(NSError *)error {
    [self.properties showMessage:error.localizedDescription];
    [self positionFloatingToolbar];
    NSBeep();
}
- (NSString *)colorHex {
    NSColor *color = [self.color.color colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    return [NSString stringWithFormat:@"#%02x%02x%02x", (unsigned)lround(color.redComponent * 255),
        (unsigned)lround(color.greenComponent * 255), (unsigned)lround(color.blueComponent * 255)];
}
- (void)syncTextControls {
    NSDictionary *annotation = [self.canvas selectedAnnotation];
    NSInteger tool = self.activeTool;
    if (annotation) {
        NSDictionary *kinds = @{@"rect":@(MCRectTool), @"arrow":@(MCArrowTool),
            @"text":@(MCTextTool), @"redact":@(MCRedactTool)};
        tool = [kinds[annotation[@"type"]] integerValue];
        self.colorControl.color = MCAnnotationColor(annotation);
        self.fontControl.value = annotation[@"fontSize"] ? [annotation[@"fontSize"] doubleValue] : editor_style_default(MC_STYLE_FONT);
        self.strokeControl.value = [annotation[@"stroke"] doubleValue];
    } else if (tool >= MCRectTool && tool <= MCRedactTool) {
        self.properties.values = (MCStyleValues){
            (int32_t)editor_style_get(self.styleHandle, (int32_t)tool, MC_STYLE_COLOR),
            editor_style_get(self.styleHandle, (int32_t)tool, MC_STYLE_OPACITY),
            editor_style_get(self.styleHandle, (int32_t)tool, MC_STYLE_STROKE),
            editor_style_get(self.styleHandle, (int32_t)tool, MC_STYLE_FONT)};
    }
    self.properties.propertyMask = editor_style_property_mask((int32_t)tool);
    [self positionFloatingToolbar];
    [self.window invalidateCursorRectsForView:self.canvas];
}
- (void)styleChanged:(id)sender {
    int32_t fields = [self.properties syncFromSender:sender];
    if (!fields) return;
    MCStyleValues values = self.properties.values;
    NSDictionary *selected = [self.canvas selectedAnnotation];
    BOOL isNewText = self.canvas.textDraft != nil;
    for (NSDictionary *annotation in self.document[@"annotations"])
        if ([annotation[@"id"] isEqual:self.canvas.selectedID]) isNewText = NO;
    // Only explicit default edits and a new text draft update the tool bank.
    // Selecting or styling an existing object never overwrites creation defaults.
    if (!selected || isNewText) {
        int32_t tool = isNewText ? MCTextTool : (int32_t)self.activeTool;
        const double valuesByField[] = {values.rgb, values.opacity, values.stroke, values.fontSize};
        for (int32_t field = MC_STYLE_COLOR; field <= MC_STYLE_FONT; field++)
            if (fields & (1 << field)) editor_style_set(self.styleHandle, tool, field, valuesByField[field]);
    }
    if (!selected) return;
    NSMutableDictionary *changed = [selected mutableCopy];
    if (fields & (1 << MC_STYLE_COLOR)) changed[@"color"] = [self colorHex];
    if (fields & (1 << MC_STYLE_OPACITY)) changed[@"opacity"] = @(values.opacity);
    if (fields & (1 << MC_STYLE_STROKE)) changed[@"stroke"] = @(values.stroke);
    if (fields & (1 << MC_STYLE_FONT)) {
        changed[@"fontSize"] = @(values.fontSize);
        changed[@"height"] = @(MIN(MCTextHeight(changed), [self.document[@"height"] doubleValue] - [changed[@"y"] doubleValue]));
    }
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
    NSInteger segment = self.tools.selectedSegment;
    NSInteger tag = segment >= 0 ? [self.tools tagForSegment:segment] : MCSelectTool;
    NSDictionary *entry = segment >= 0 && segment < (NSInteger)self.visibleTools.count ? self.visibleTools[(NSUInteger)segment] : nil;
    if ([entry[@"action"] isEqual:@"run"]) {
        [self selectActiveToolSegment];
        if (self.onUserTool && self.pluginCaptureMetadata) self.onUserTool(self, entry[@"id"]);
        return;
    }
    if (self.canvas.textView.hasMarkedText) {
        [self selectActiveToolSegment];
        return;
    }
    if (![self.canvas finishTextEditing:YES]) { [self selectActiveToolSegment]; return; }
    MCImageTool tool = tag;
    if (![self isToolEnabled:tool]) { [self selectActiveToolSegment]; return; }
    self.activeTool = tool;
    [self.canvas cancelGesture];
    self.canvas.selectedID = nil;
    [self syncTextControls];
    [self.window makeFirstResponder:self.canvas];
}
- (NSDictionary *)shapeEvent:(NSString *)phase point:(NSPoint)point {
    NSMutableDictionary *request = [@{@"session":@(self.captureUIHandle), @"type":phase,
        @"x":@(point.x), @"y":@(point.y)} mutableCopy];
    if ([phase isEqual:@"begin"]) {
        if (![self isToolEnabled:self.activeTool] || self.activeTool == MCSelectTool || self.activeTool == MCTextTool) return nil;
        [request addEntriesFromDictionary:@{@"id":NSUUID.UUID.UUIDString, @"kind":@(self.activeTool),
            @"stroke":@(self.strokeControl.value), @"opacity":@(self.color.color.alphaComponent), @"color":[self colorHex]}];
    }
    return MCCallCore(capture_ui_event, request, NULL);
}
- (void)addTextAtPoint:(NSPoint)point {
    if (![self isToolEnabled:MCTextTool]) return;
    CGFloat size = MAX(editor_style_min(MC_STYLE_FONT), MIN(editor_style_max(MC_STYLE_FONT), self.fontSize.doubleValue));
    CGFloat width = [self.document[@"width"] doubleValue], height = [self.document[@"height"] doubleValue];
    NSRect region = self.overlayMode && self.hasCaptureRegion ? MCAnnotationRect(self.document[@"viewport"]) : NSMakeRect(0, 0, width, height);
    CGFloat boxWidth = MIN(280, region.size.width), boxHeight = MIN(ceil(size * 1.5), region.size.height);
    CGFloat x = MAX(NSMinX(region), MIN(point.x, NSMaxX(region) - MIN(boxWidth, 80)));
    CGFloat y = MAX(NSMinY(region), MIN(point.y, NSMaxY(region) - boxHeight));
    [self.canvas beginEditingText:@{@"id":NSUUID.UUID.UUIDString, @"type":@"text", @"text":@"",
        @"x":@(x), @"y":@(y), @"width":@(MIN(boxWidth, NSMaxX(region) - x)), @"height":@(boxHeight),
        @"fontSize":@(size), @"stroke":@(editor_style_default(MC_STYLE_STROKE)),
        @"opacity":@(self.color.color.alphaComponent), @"color":[self colorHex]}];
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
    return [self renderDocumentPNGData:self.document error:error];
}
- (NSData *)capturePNGData:(NSError **)error {
    if (self.canvas.dragging || self.canvas.regionDragging || (self.overlayMode && !self.hasCaptureRegion)) {
        if (error) *error = MCEditorError(@"请先完成当前截图选区或标注操作。");
        return nil;
    }
    NSDictionary *plan = [self pendingEditCommitPlan:error];
    return plan ? [self renderDocumentPNGData:plan[@"document"] ?: self.document error:error] : nil;
}
- (NSData *)renderDocumentPNGData:(NSDictionary *)document error:(NSError **)error {
    if (self.overlayMode && !self.hasCaptureRegion) {
        if (error) *error = MCEditorError(@"请先框选截图范围。");
        return nil;
    }
    NSDictionary *finalized = MCCallImage(image_finalize, @{@"document":document}, error);
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
    CGContextTranslateCTM(cg, -[document[@"viewport"][@"x"] doubleValue], -[document[@"viewport"][@"y"] doubleValue]);
    [NSGraphicsContext setCurrentContext:[NSGraphicsContext graphicsContextWithCGContext:cg flipped:YES]];
    MCDrawImage(self.image, document, nil, NSZeroRect);
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
    if (self.lineWidth.currentEditor) [self styleChanged:self.lineWidth];
    if (self.colorControl.opacityControl.field.currentEditor) [self styleChanged:self.colorControl.opacityControl.field];
    if (![self.canvas finishTextEditing:YES]) return;
    NSError *error = nil;
    if ([self copyToPasteboard:NSPasteboard.generalPasteboard error:&error]) [self.window close];
    else [self showError:error];
}
- (NSRect)pinScreenFrame {
    if (!self.window || !self.canvas) return NSZeroRect;
    NSRect region = [self.canvas viewRectForImageRect:MCAnnotationRect(self.document[@"viewport"])];
    return [self.window convertRectToScreen:[self.canvas convertRect:region toView:nil]];
}
- (NSRect)captureScreenFrame {
    if (self.overlayMode && !self.hasCaptureRegion) return NSZeroRect;
    return self.pinScreenFrame;
}
- (void)pinImage:(id)sender {
    (void)sender;
    if (![self isPinActionConfigured] || !self.onPinPNGData || self.canvas.dragging || self.canvas.regionDragging) return;
    NSError *error = nil;
    NSDictionary *plan = [self pendingEditCommitPlan:&error];
    NSData *png = plan ? [self renderDocumentPNGData:plan[@"document"] ?: self.document error:&error] : nil;
    if (png && self.onPinPNGData(png)) { [self.window close]; return; }
    // Keep the original text/field editor, selection and undo state intact on
    // failure. showError: hides property controls, which could end field input.
    self.properties.status.stringValue = error.localizedDescription ?: @"贴图未能创建，已保留当前编辑。";
    self.properties.status.hidden = NO;
    [self positionFloatingToolbar];
    NSBeep();
}
- (void)cancel:(id)sender { (void)sender; [self.canvas finishTextEditing:NO]; [self.window close]; }
- (void)windowWillClose:(NSNotification *)notification {
    (void)notification;
    capture_ui_close(self.captureUIHandle);
    self.captureUIHandle = 0;
    void (^closed)(void) = self.onClose;
    self.onClose = nil;
    if (self.onPluginContextClosed) self.onPluginContextClosed(self.pluginContextIdentifier);
    self.window.delegate = nil;
    self.window.contentView = nil;
    self.window = nil;
    self.canvas = nil;
    [self.colorControl closePopover];
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
