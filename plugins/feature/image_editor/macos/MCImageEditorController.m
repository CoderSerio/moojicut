#import "MCImageEditorController.h"
#import "components/theme/macos/MCChromeTheme.h"
#include "bindings/c/editor_style.h"
#import "components/selection/macos/MCSelectionSurface.h"
#import "components/image_effects/macos/MCPixelate.h"
#import "components/shared_canvas/macos/MCSharedCanvas.h"
#import "platform/macos/graphics/MCSharedTextInput.h"
#import "platform/macos/graphics/MCSystemColorPanel.h"
#include "moonbit.h"
#include "bindings/c/image_session.h"
#include "bindings/c/capture_edit.h"
#include "bindings/c/capture_ui.h"
#include "bindings/c/capture_toolbar.h"
#include "bindings/c/tool_registry.h"
#include <math.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

extern moonbit_string_t image_finalize(moonbit_string_t);
extern moonbit_string_t image_selection(moonbit_string_t);

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
static moonbit_string_t MCEditString(NSString *text) {
    moonbit_string_t result = moonbit_make_string_raw((int32_t)text.length);
    [text getCharacters:result range:NSMakeRange(0,text.length)];
    return result;
}
static moonbit_string_t MCEditJSON(id value) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:value ?: NSNull.null options:NSJSONWritingFragmentsAllowed error:NULL];
    return MCEditString(data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"");
}
static id MCEditRead(moonbit_string_t value) {
    NSString *text = [[NSString alloc] initWithCharacters:value length:(NSUInteger)Moonbit_array_length(value)];
    moonbit_decref(value);
    return [NSJSONSerialization JSONObjectWithData:[text dataUsingEncoding:NSUTF8StringEncoding] options:NSJSONReadingFragmentsAllowed error:NULL];
}
static NSString *MCEditReadString(moonbit_string_t value) {
    NSString *text = [[NSString alloc] initWithCharacters:value length:(NSUInteger)Moonbit_array_length(value)];
    moonbit_decref(value); return text;
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
        if ([annotation[@"shape"] isEqual:@"ellipse"]) [[NSBezierPath bezierPathWithOvalInRect:rect] fill];
        else NSRectFillUsingOperation(rect, NSCompositingOperationSourceOver);
    } else if ([kind isEqualToString:@"rect"] || [kind isEqualToString:@"ellipse"]) {
        [color setStroke];
        NSBezierPath *path = [kind isEqual:@"ellipse"] ? [NSBezierPath bezierPathWithOvalInRect:rect] : [NSBezierPath bezierPathWithRect:rect];
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
static BOOL MCIsMask(NSDictionary *annotation) {
    return [annotation[@"type"] isEqual:@"redact"] || [annotation[@"type"] isEqual:@"mosaic"];
}
static void MCDrawBase(NSImage *image, NSDictionary *document, NSArray *annotations) {
    NSRect rect = NSMakeRect(0, 0, [document[@"width"] doubleValue], [document[@"height"] doubleValue]);
    [image drawInRect:rect fromRect:NSZeroRect operation:NSCompositingOperationCopy fraction:1 respectFlipped:YES hints:nil];
    for (NSDictionary *annotation in annotations) if (!MCIsMask(annotation)) MCDrawAnnotation(annotation);
}
static void MCDrawMask(NSDictionary *render) {
    NSDictionary *annotation = render[@"annotation"];
    if (![annotation[@"type"] isEqual:@"mosaic"]) { MCDrawAnnotation(annotation); return; }
    [NSGraphicsContext saveGraphicsState];
    NSRect rect = MCAnnotationRect(annotation);
    NSRectClip(rect);
    // Mosaic is always opaque, including a transparent source or allocation failure.
    [NSColor.blackColor setFill]; NSRectFill(rect);
    NSGraphicsContext.currentContext.imageInterpolation = NSImageInterpolationNone;
    NSImage *image = render[@"image"];
    [image drawInRect:[render[@"grid"] rectValue] fromRect:NSZeroRect
        operation:NSCompositingOperationSourceOver fraction:1 respectFlipped:YES hints:nil];
    [NSGraphicsContext restoreGraphicsState];
}
static void MCDrawImage(NSImage *image, NSDictionary *document, NSDictionary *pending, NSRect liveTextRect) {
    NSRect rect = NSMakeRect(0, 0, [document[@"width"] doubleValue], [document[@"height"] doubleValue]);
    [NSGraphicsContext saveGraphicsState];
    NSRectClip(rect);
    NSMutableArray *annotations = [document[@"annotations"] mutableCopy];
    if (pending) [annotations addObject:pending];
    MCDrawBase(image, document, annotations);
    NSMutableArray *masks = [NSMutableArray array];
    for (NSDictionary *annotation in annotations) if (MCIsMask(annotation)) {
        NSMutableDictionary *render = [@{@"annotation":annotation} mutableCopy];
        if ([annotation[@"type"] isEqual:@"mosaic"]) {
            NSRect grid = NSZeroRect;
            NSImage *sample = MCPixelatedRegion(NSIntersectionRect(rect,MCAnnotationRect(annotation)),
                [annotation[@"blockSize"] doubleValue], ^{
                    MCDrawBase(image, document, annotations);
                    for (NSDictionary *prior in masks) MCDrawMask(prior);
                }, &grid);
            if (sample) { render[@"image"] = sample; render[@"grid"] = [NSValue valueWithRect:grid]; }
        }
        [masks addObject:render];
    }
    // The native text view paints covers above its glyphs. Exclude that area
    // here so translucent covers are blended once, including blank text space.
    NSRect excluded = NSIntersectionRect(rect, liveTextRect);
    if (!NSIsEmptyRect(excluded)) {
        NSBezierPath *clip = [NSBezierPath bezierPathWithRect:rect];
        [clip appendBezierPathWithRect:excluded];
        clip.windingRule = NSWindingRuleEvenOdd;
        [clip addClip];
    }
    for (NSDictionary *render in masks) MCDrawMask(render);
    [NSGraphicsContext restoreGraphicsState];
}

typedef NS_ENUM(NSInteger, MCImageTool) { MCSelectTool, MCRectTool, MCArrowTool, MCTextTool, MCRedactTool };
static NSDictionary *MCDefaultImageToolConfiguration(void) {
    static NSDictionary *configuration;
    if (!configuration) configuration = MCCallCore(tool_registry_resolve,
        @{ @"layout":NSNull.null, @"manifests":@[] }, NULL);
    return configuration;
}
static int32_t MCImageToolSnapshot(NSDictionary *candidate) {
    if (![candidate isKindOfClass:NSDictionary.class] || ![NSJSONSerialization isValidJSONObject:candidate]) return 0;
    moonbit_string_t input = MCEditJSON(candidate);
    int capabilities = MC_TOOL_CAP_OCR | MC_TOOL_CAP_TRANSLATE | MC_TOOL_CAP_SCROLL |
        MC_TOOL_CAP_COMMANDS | MC_TOOL_CAP_USER;
    int32_t snapshot = tool_registry_snapshot_open_packages(input, capabilities);
    // Keep the current product's legacy registry until its application cutover.
    // Both openers independently reconstruct/verify the complete descriptor set.
    if (!snapshot) snapshot = tool_registry_snapshot_open(input,
        capabilities);
    moonbit_decref(input);
    return snapshot;
}
@class MCImageCanvas;
@interface MCImageEditorController ()
@property (nonatomic, readwrite) NSWindow *window;
@property (nonatomic, readwrite) NSDictionary *document;
@property NSImage *image;
@property MCImageCanvas *canvas;
@property (nonatomic, copy, readwrite) NSString *pluginContextIdentifier;
@property MCSharedCanvasView *toolbar;
@property NSScrollView *propertiesScroll;
@property NSDictionary<NSString *, NSString *> *toolbarAssetIDs;
@property int32_t toolbarHandle, toolbarGeneration;
@property NSTextField *propertyStatus;
@property int32_t styleHandle;
@property int32_t captureUIHandle;
@property int32_t imageSession;
@property int32_t textEdit;
@property NSDictionary *textSnapshot;
@property MCSharedCanvasView *textPropertiesCanvas;
@property NSMutableDictionary<NSString *, MCSharedTextInputView *> *textPropertyInputs;
@property BOOL syncingText;
@property BOOL endingText;
@property MCSystemColorPanelLease *textColorLease;
@property NSDictionary *configurationCandidate;
@property int32_t configurationTicket;
- (BOOL)beginTextTransaction:(NSInteger)mode annotation:(NSDictionary *)annotation;
- (BOOL)beginPropertyTransaction:(NSDictionary *)annotation;
- (BOOL)sendTextEvent:(NSDictionary *)event;
- (void)syncSharedText;
- (void)endNativeTextInput;
- (BOOL)finishSharedText:(BOOL)commit;
- (double)textMeasurement;
- (void)sharedColorChanged:(id)sender;
- (void)sharedColorPicked:(NSColor *)color;
- (BOOL)handleSharedTextUIEvent:(NSDictionary *)event;
@property (readonly) MCImageTool activeTool;
@property (nonatomic, copy, readonly) NSString *activeToolIdentifier;
@property (nonatomic, copy, readonly) NSString *activeCommand;
@property (nonatomic, copy) NSString *gestureCommand;
@property NSNumber *gestureRevision;
@property (nonatomic, copy, readwrite) NSDictionary *toolConfiguration;
- (BOOL)isToolEnabled:(MCImageTool)tool;
- (NSDictionary *)pendingEditCommitPlan:(NSError **)error;
- (NSData *)renderDocumentPNGData:(NSDictionary *)document error:(NSError **)error;
@property NSVisualEffectView *floatingToolbar;
@property BOOL overlayMode;
@property BOOL hasCaptureRegion;
- (void)prepareWindow;
- (void)refresh;
- (BOOL)applyCommand:(NSDictionary *)command;
- (void)showError:(NSError *)error;
- (NSString *)colorHex;
- (void)syncTextControls;
- (void)positionFloatingToolbar;
- (BOOL)openToolbar;
- (BOOL)syncToolbarContext;
- (BOOL)activateToolbarItem:(NSString *)identifier;
- (void)handleToolbarEffect;
- (BOOL)writePNG:(NSData *)png toPasteboard:(NSPasteboard *)pasteboard error:(NSError **)error;
- (void)updateToolbarFrame:(CGFloat)available;
- (void)handleToolbarEvent:(NSDictionary *)event;
- (BOOL)setCaptureRegion:(NSRect)rect;
- (void)pinImage:(id)sender;
- (NSDictionary *)shapeEvent:(NSString *)phase point:(NSPoint)point;
- (void)addTextAtPoint:(NSPoint)point;
- (void)confirm:(id)sender;
@end

@interface MCInlineTextView : MCSharedTextInputView
@property (weak) MCImageCanvas *canvas;
@end

@interface MCImageCanvas : MCSelectionSurface <NSTextViewDelegate>
@property (weak) MCImageEditorController *editor;
@property NSPoint start;
@property NSPoint windowClickAnchor;
@property NSRect hoveredWindowRect, pressedWindowRect;
@property BOOL draggedFromWindow;
@property NSDictionary *pending;
@property BOOL dragging;
@property NSString *selectedID;
@property NSDictionary *textDraft;
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
- (void)updateWindowHover:(NSPoint)point;
@end

@implementation MCInlineTextView
- (void)drawRect:(NSRect)dirtyRect {
    [NSGraphicsContext saveGraphicsState];
    NSDictionary *draft = self.canvas.textDraft;
    NSRect crop = MCAnnotationRect(self.canvas.editor.document[@"viewport"]);
    crop.origin.x -= [draft[@"x"] doubleValue];
    crop.origin.y -= [draft[@"y"] doubleValue];
    NSRectClip(NSIntersectionRect(crop, self.bounds));
    [super drawRect:dirtyRect];
    // Match the document's cover ordering without double-compositing alpha.
    NSAffineTransform *transform = [NSAffineTransform transform];
    [transform translateXBy:-[draft[@"x"] doubleValue] yBy:-[draft[@"y"] doubleValue]];
    [transform concat];
    NSBezierPath *maskClip = [NSBezierPath bezierPath];
    NSMutableArray *annotations = [NSMutableArray array];
    for (NSDictionary *annotation in self.canvas.editor.document[@"annotations"]) {
        if (![annotation[@"id"] isEqual:draft[@"id"]]) [annotations addObject:annotation];
        if (!MCIsMask(annotation)) continue;
        if ([annotation[@"shape"] isEqual:@"ellipse"] && [annotation[@"type"] isEqual:@"redact"])
            [maskClip appendBezierPathWithOvalInRect:MCAnnotationRect(annotation)];
        else [maskClip appendBezierPathWithRect:MCAnnotationRect(annotation)];
    }
    if (!maskClip.empty) {
        [maskClip addClip];
        [annotations addObject:draft];
        NSMutableDictionary *document = [self.canvas.editor.document mutableCopy]; document[@"annotations"] = annotations;
        MCDrawImage(self.canvas.editor.image, document, nil, NSZeroRect);
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
    if (![self.editor isToolEnabled:MCTextTool] || ![self finishTextEditing:YES]) return;
    BOOL existing = NO;
    for (NSDictionary *item in self.editor.document[@"annotations"])
        if ([item[@"id"] isEqual:annotation[@"id"]]) existing = YES;
    if (![self.editor beginTextTransaction:existing ? MC_CAPTURE_TEXT_EXISTING : MC_CAPTURE_TEXT_NEW annotation:annotation]) return;
    self.selectedID = MCEditReadString(capture_text_text(self.editor.imageSession,self.editor.textEdit,MC_CAPTURE_TEXT_ANNOTATION_ID));
    self.textHost = [[NSView alloc] initWithFrame:NSZeroRect];
    self.textView = [[MCInlineTextView alloc] initWithFrame:NSZeroRect];
    self.textView.canvas = self;
    __weak MCImageEditorController *editor = self.editor;
    self.textView.onEdit = ^BOOL(NSDictionary *event) { return [editor sendTextEvent:event]; };
    self.textView.onAction = ^(NSString *action) {
        if ([action isEqual:@"commit"]) { if ([editor.canvas finishTextEditing:YES]) [editor syncTextControls]; }
        else if ([action isEqual:@"cancel"]) { [editor.canvas finishTextEditing:NO]; [editor refresh]; }
    };
    [self.textHost addSubview:self.textView]; [self addSubview:self.textHost];
    [self.editor syncSharedText]; [self.editor syncTextControls];
    [self.window makeFirstResponder:self.textView];
}
- (BOOL)finishTextEditing:(BOOL)commit { return [self.editor finishSharedText:commit]; }
// AppKit mutation notifications are consumed by the generic input bridge.
- (void)textDidChange:(NSNotification *)notification { (void)notification; [self.editor syncSharedText]; }
- (void)updateWindowHover:(NSPoint)point {
    if (!self.editor.overlayMode || self.editor.hasCaptureRegion || self.regionDragging) return;
    NSDictionary *candidate = [self windowCandidateAtPoint:point];
    NSRect target = candidate ? [candidate[@"rect"] rectValue] : NSZeroRect;
    if (NSEqualRects(target,self.hoveredWindowRect)) return;
    self.hoveredWindowRect = target;
    self.needsDisplay = YES;
}
- (void)mouseEntered:(NSEvent *)event { [self mouseMoved:event]; }
- (void)mouseMoved:(NSEvent *)event { [self updateWindowHover:[self convertPoint:event.locationInWindow fromView:nil]]; }
- (void)mouseExited:(__unused NSEvent *)event {
    if (NSIsEmptyRect(self.hoveredWindowRect)) return;
    self.hoveredWindowRect = NSZeroRect;
    self.needsDisplay = YES;
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
            [annotations addObject:self.transformPreview ?: self.textDraft ?: annotation];
        } else [annotations addObject:annotation];
    }
    display[@"annotations"] = annotations;
    MCDrawImage(self.editor.image, display, self.pending, self.textView ? MCAnnotationRect(self.textDraft) : NSZeroRect);
    [NSGraphicsContext restoreGraphicsState];
    if (self.editor.overlayMode) {
        NSRect capture = [self captureRect];
        BOOL idle = !self.editor.hasCaptureRegion && !self.regionDragging;
        BOOL pendingClick = self.regionDragging && !NSIsEmptyRect(self.pressedWindowRect) && !self.draggedFromWindow;
        NSRect hover = idle ? self.hoveredWindowRect : pendingClick ? self.pressedWindowRect : NSZeroRect;
        if (!NSIsEmptyRect(hover)) {
            [self drawRegion:hover dimensions:[self selectionContentRect:hover].size handles:NO hint:nil];
        } else {
            NSString *hint = self.windowCandidates.count ? @"拖动框选或单击窗口 · Esc 取消" : @"拖动框选截图范围 · Esc 取消";
            [self drawRegion:[self viewRectForImageRect:capture] dimensions:capture.size handles:YES hint:hint];
        }
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
            if (event.clickCount >= 2 && [annotation[@"type"] isEqual:@"text"]) [self beginEditingText:annotation];
            else { self.transformOriginal = annotation; self.resizeHandle = -1; self.dragging = YES; }
            [self.editor syncTextControls];
            [self updateTextFrame];
            return;
        }
    }
    NSInteger operation = self.editor.overlayMode ? MCSelectionHitTest(self.editor.hasCaptureRegion,
        region, [self viewRectForImageRect:region], self.start, local) : MCSelectionNone;
    if (operation != MCSelectionNone) {
        if (!self.editor.hasCaptureRegion) [self updateWindowHover:local];
        if ([self beginRegion:operation event:event rect:region]) {
            if (!self.editor.hasCaptureRegion) {
                self.pressedWindowRect = self.hoveredWindowRect;
                self.windowClickAnchor = local;
                self.draggedFromWindow = NO;
            }
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
        if (!NSIsEmptyRect(self.pressedWindowRect) && !self.draggedFromWindow) {
            NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
            if (!MCSelectionMovedBeyondClick(self.windowClickAnchor,point)) return;
            self.draggedFromWindow = YES;
        }
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
        NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
        BOOL valid;
        if (!NSIsEmptyRect(self.pressedWindowRect) && !self.draggedFromWindow &&
                !MCSelectionMovedBeyondClick(self.windowClickAnchor,point)) {
            rect = [self selectionContentRect:self.pressedWindowRect];
            [self cancelRegion];
            valid = YES;
        } else {
            valid = [self finishRegion:event rect:&rect];
        }
        self.pressedWindowRect = NSZeroRect;
        self.hoveredWindowRect = NSZeroRect;
        if (valid) [self.editor setCaptureRegion:rect];
        else [self updateWindowHover:point];
        self.needsDisplay = YES;
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
    self.pressedWindowRect = NSZeroRect;
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
    if (event.keyCode == 48) {
        [self.window makeFirstResponder:self.editor.toolbar];
        [self.editor handleToolbarEvent:@{@"type":@"key", @"key":@"Tab",
            @"shift":(event.modifierFlags & NSEventModifierFlagShift) ? @YES : @NO, @"mod":@NO}];
    } else if (event.keyCode == 36 || event.keyCode == 76) {
        [self.editor confirm:nil];
    } else if (event.keyCode == 53) {
        if (self.dragging || self.regionDragging) [self cancelGesture];
        else if (self.selectedID) { if (![self finishTextEditing:YES]) return; self.selectedID = nil; [self.editor refresh]; }
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
- (BOOL)performKeyEquivalent:(NSEvent *)event {
    if (self.window.firstResponder == self &&
        (event.modifierFlags & (NSEventModifierFlagCommand | NSEventModifierFlagControl | NSEventModifierFlagOption)) ==
             NSEventModifierFlagCommand) {
        NSString *key = event.charactersIgnoringModifiers.lowercaseString;
        if ([key isEqual:@"z"]) {
            [self.editor activateToolbarItem:(event.modifierFlags & NSEventModifierFlagShift) ? @"host.redo" : @"host.undo"];
            return YES;
        }
        if ([key isEqual:@"c"]) {
            [self.editor confirm:nil];
            return YES;
        }
    }
    return [super performKeyEquivalent:event];
}
@end

@implementation MCImageEditorController
- (BOOL)beginTextTransaction:(NSInteger)mode annotation:(NSDictionary *)annotation {
    if (self.textEdit && ![self finishSharedText:YES]) return NO;
    moonbit_string_t identifier = MCEditString(mode == MC_CAPTURE_TEXT_EXISTING ? annotation[@"id"] : @"");
    self.textEdit = capture_text_begin(self.imageSession,self.styleHandle,(int32_t)mode,identifier,
        image_session_revision(self.imageSession),[annotation[@"x"] doubleValue],[annotation[@"y"] doubleValue],
        [annotation[@"width"] doubleValue],[annotation[@"height"] doubleValue]);
    moonbit_decref(identifier);
    return self.textEdit != 0;
}
- (BOOL)beginPropertyTransaction:(NSDictionary *)annotation {
    if ([annotation[@"type"] isEqual:@"text"] || (!annotation && self.activeTool == MCTextTool))
        return [self beginTextTransaction:annotation ? MC_CAPTURE_TEXT_EXISTING : MC_CAPTURE_TEXT_DEFAULTS annotation:annotation];
    if (self.textEdit && ![self finishSharedText:YES]) return NO;
    NSString *type = annotation[@"type"];
    MCImageTool tool = !annotation ? self.activeTool :
        ([type isEqual:@"rect"] || [type isEqual:@"ellipse"]) ? MCRectTool :
        [type isEqual:@"arrow"] ? MCArrowTool :
        ([type isEqual:@"redact"] || [type isEqual:@"mosaic"]) ? MCRedactTool : MCSelectTool;
    if (tool == MCSelectTool) return NO;
    moonbit_string_t identifier = MCEditString(annotation[@"id"] ?: @"");
    moonbit_string_t command = MCEditString(annotation ? @"" : self.activeCommand ?: @"");
    self.textEdit = capture_properties_begin(self.imageSession,self.styleHandle,(int32_t)tool,identifier,
        image_session_revision(self.imageSession),command);
    moonbit_decref(identifier); moonbit_decref(command);
    return self.textEdit != 0;
}
- (NSDictionary *)textRenderAnnotation {
    id annotation = self.textSnapshot[@"previewAnnotation"];
    return [annotation isKindOfClass:NSDictionary.class] ? annotation : nil;
}
- (double)textMeasurement {
    NSDictionary *annotation = [self textRenderAnnotation];
    return [annotation[@"type"] isEqual:@"text"] ? MCTextHeight(annotation) : 0;
}
- (BOOL)sendTextEvent:(NSDictionary *)event {
    if (!self.textEdit || self.endingText) return NO;
    int32_t token = self.textEdit;
    moonbit_string_t request = MCEditJSON(event);
    int accepted = capture_text_event_json(self.imageSession,token,
        (int32_t)capture_text_value(self.imageSession,token,MC_CAPTURE_TEXT_VERSION),request);
    moonbit_decref(request);
    if (token == self.textEdit) [self syncSharedText];
    return accepted != 0;
}
- (void)syncSharedText {
    if (!self.textEdit || self.syncingText || self.endingText) return;
    self.syncingText = YES;
    @try {
        self.textSnapshot = MCEditRead(capture_text_snapshot(self.imageSession,self.textEdit));
        if (![self.textSnapshot[@"ok"] boolValue]) return;
        if (self.textColorLease.active) {
            if (((int32_t)capture_text_value(self.imageSession,self.textEdit,MC_CAPTURE_TEXT_VISIBLE_MASK) & (1 << MC_STYLE_COLOR)) == 0) {
                [self.textColorLease invalidate]; self.textColorLease = nil;
                [NSColorPanel.sharedColorPanel orderOut:nil];
            } else {
                unsigned rgb = (unsigned)capture_text_value(self.imageSession,self.textEdit,MC_CAPTURE_TEXT_RGB);
                [self.textColorLease updateColor:[NSColor colorWithSRGBRed:((rgb >> 16) & 255)/255.0
                    green:((rgb >> 8) & 255)/255.0 blue:(rgb & 255)/255.0 alpha:1]];
            }
        }
        NSMutableDictionary *annotation = [[self textRenderAnnotation] mutableCopy];
        double measured = [self textMeasurement];
        if ([annotation[@"type"] isEqual:@"text"]) {
            double height = capture_text_measured_height(self.imageSession,self.textEdit,
                [self.textSnapshot[@"version"] intValue],measured);
            if (height > 0) annotation[@"height"] = @(height);
        }
        self.canvas.textDraft = [annotation copy];
        int dark = [[self.window.effectiveAppearance bestMatchFromAppearancesWithNames:@[NSAppearanceNameAqua,NSAppearanceNameDarkAqua]] isEqual:NSAppearanceNameDarkAqua];
        if (self.canvas.textView && annotation) {
            NSDictionary *frame = MCEditRead(capture_text_frame(self.imageSession,self.textEdit,MC_CAPTURE_TEXT_INLINE,
                [annotation[@"width"] doubleValue],[annotation[@"height"] doubleValue],1,dark));
            NSDictionary *field = [frame[@"editableFields"] firstObject];
            if (field) [self.canvas.textView applyFieldDescription:field];
            [self.canvas updateTextFrame];
        }
        double width = capture_text_value(self.imageSession,self.textEdit,MC_CAPTURE_TEXT_ROW_WIDTH);
        double height = capture_text_value(self.imageSession,self.textEdit,MC_CAPTURE_TEXT_ROW_HEIGHT);
        if (width > 0 && height > 0 && self.textPropertiesCanvas) {
            NSDictionary *frame = MCEditRead(capture_text_frame(self.imageSession,self.textEdit,MC_CAPTURE_TEXT_PROPERTIES,width,height,1,dark));
            self.textPropertiesCanvas.frameDescription = frame;
            NSMutableSet *remaining = [NSMutableSet setWithArray:self.textPropertyInputs.allKeys];
            for (NSDictionary *field in frame[@"editableFields"]) {
                NSString *identifier = field[@"id"];
                MCSharedTextInputView *input = self.textPropertyInputs[identifier];
                if (!input) {
                    input = [[MCSharedTextInputView alloc] initWithFrame:NSZeroRect];
                    __weak MCImageEditorController *weakSelf = self;
                    input.onEdit = ^BOOL(NSDictionary *event) { return [weakSelf sendTextEvent:event]; };
                    input.onKey = ^BOOL(NSDictionary *event) { return [weakSelf handleSharedTextUIEvent:event]; };
                    input.onScroll = ^BOOL(NSEvent *event) {
                        MCImageEditorController *editor = weakSelf;
                        if (!editor.textPropertiesCanvas || !editor.textEdit) return NO;
                        NSPoint point = [editor.textPropertiesCanvas convertPoint:event.locationInWindow fromView:nil];
                        return [editor handleSharedTextUIEvent:@{@"type":@"scroll", @"x":@(point.x), @"y":@(point.y),
                            @"deltaX":@(event.scrollingDeltaX), @"deltaY":@(event.scrollingDeltaY),
                            @"precise":event.hasPreciseScrollingDeltas ? @YES : @NO,
                            @"shift":(event.modifierFlags & NSEventModifierFlagShift) ? @YES : @NO,
                            @"mod":(event.modifierFlags & NSEventModifierFlagCommand) ? @YES : @NO}];
                    };
                    input.shouldResign = ^BOOL {
                        MCImageEditorController *editor = weakSelf;
                        return !editor || editor.endingText || !editor.textEdit ||
                            capture_text_value(editor.imageSession,editor.textEdit,MC_CAPTURE_TEXT_VALID) == 1;
                    };
                    input.onAction = ^(NSString *action) {
                        MCImageEditorController *editor = weakSelf;
                        if (!editor || editor.syncingText || editor.endingText) return;
                        if ([action isEqual:@"cancel"]) { if ([editor finishSharedText:NO]) [editor refresh]; }
                        else if ([action isEqual:@"commit"] &&
                            capture_text_value(editor.imageSession,editor.textEdit,MC_CAPTURE_TEXT_MODE) == MC_CAPTURE_TEXT_DEFAULTS) {
                            if ([editor finishSharedText:YES]) [editor syncTextControls];
                        } else if ([action isEqual:@"blur"]) {
                            int32_t edit = editor.textEdit;
                            dispatch_async(dispatch_get_main_queue(), ^{
                                MCImageEditorController *owner = weakSelf;
                                if (!owner.window || owner.textEdit != edit || !edit) return;
                                NSResponder *responder = owner.window.firstResponder;
                                if (responder == owner.toolbar ||
                                    ([responder isKindOfClass:NSView.class] && [(NSView *)responder isDescendantOf:owner.textPropertiesCanvas])) return;
                                if (capture_text_value(owner.imageSession,edit,MC_CAPTURE_TEXT_MODE) == MC_CAPTURE_TEXT_DEFAULTS &&
                                    [owner finishSharedText:YES]) [owner syncTextControls];
                            });
                        }
                    };
                    self.textPropertyInputs[identifier] = input;
                    [self.textPropertiesCanvas addSubview:input];
                }
                input.frame = MCAnnotationRect(field);
                [input applyFieldDescription:field]; [remaining removeObject:identifier];
            }
            for (NSString *identifier in remaining) {
                [self.textPropertyInputs[identifier] invalidate];
                [self.textPropertyInputs[identifier] removeFromSuperview];
                [self.textPropertyInputs removeObjectForKey:identifier];
            }
        }
        self.canvas.needsDisplay = YES;
        [self positionFloatingToolbar];
    } @finally { self.syncingText = NO; }
}
- (void)endNativeTextInput {
    self.endingText = YES;
    self.textEdit = 0; self.textSnapshot = nil;
    [self.canvas.textView invalidate];
    for (MCSharedTextInputView *input in self.textPropertyInputs.allValues) { [input invalidate]; [input removeFromSuperview]; }
    [self.textPropertyInputs removeAllObjects];
    [self.canvas.textHost removeFromSuperview]; self.canvas.textHost = nil; self.canvas.textView = nil; self.canvas.textDraft = nil;
    BOOL ownedPanel = self.textColorLease.active;
    [self.textColorLease invalidate]; self.textColorLease = nil;
    if (ownedPanel) [NSColorPanel.sharedColorPanel orderOut:nil];
    self.endingText = NO;
}
- (BOOL)finishSharedText:(BOOL)commit {
    if (!self.textEdit) return YES;
    if (commit) {
        [self syncSharedText];
        int32_t ticket = capture_text_prepare(self.imageSession,self.textEdit,
            (int32_t)capture_text_value(self.imageSession,self.textEdit,MC_CAPTURE_TEXT_VERSION),
            MC_CAPTURE_CANDIDATE_PUBLISH,[self textMeasurement]);
        if (!ticket || !capture_candidate_commit(self.imageSession,ticket)) {
            if (ticket) capture_candidate_close(ticket);
            [self showError:MCEditorError(MCEditReadString(capture_text_text(self.imageSession,self.textEdit,MC_CAPTURE_TEXT_ERROR)))];
            return NO;
        }
        self.document = MCEditRead(image_session_document(self.imageSession));
    } else {
        capture_text_cancel(self.imageSession,self.textEdit,
            (int32_t)capture_text_value(self.imageSession,self.textEdit,MC_CAPTURE_TEXT_VERSION));
    }
    [self endNativeTextInput]; [self.window makeFirstResponder:self.canvas];
    // Refresh document rendering without immediately reopening a defaults edit.
    self.canvas.needsDisplay = YES; [self.canvas updateTextFrame];
    return YES;
}
- (void)sharedColorChanged:(id)sender {
    [self sharedColorPicked:[sender color]];
}
- (void)sharedColorPicked:(NSColor *)input {
    NSColor *color = [input colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    if (!color || !self.textEdit) return;
    unsigned rgb = ((unsigned)lround(color.redComponent*255) << 16) |
        ((unsigned)lround(color.greenComponent*255) << 8) | (unsigned)lround(color.blueComponent*255);
    [self sendTextEvent:@{@"type":@"color",@"rgb":@(rgb)}];
}
- (BOOL)handleSharedTextUIEvent:(NSDictionary *)event {
    if (!self.textEdit) return NO;
    moonbit_string_t input = MCEditJSON(event);
    int result = capture_text_ui_event(self.imageSession,self.textEdit,
        (int32_t)capture_text_value(self.imageSession,self.textEdit,MC_CAPTURE_TEXT_VERSION),input,
        capture_text_value(self.imageSession,self.textEdit,MC_CAPTURE_TEXT_ROW_WIDTH),
        capture_text_value(self.imageSession,self.textEdit,MC_CAPTURE_TEXT_ROW_HEIGHT));
    moonbit_decref(input); [self syncSharedText];
    if (result == MC_CAPTURE_TEXT_CHOOSE_COLOR) {
        NSColorPanel *panel = NSColorPanel.sharedColorPanel;
        NSColor *color = MCAnnotationColor(@{@"color":[NSString stringWithFormat:@"#%06x",(unsigned)capture_text_value(self.imageSession,self.textEdit,MC_CAPTURE_TEXT_RGB)],@"opacity":@1});
        int32_t session = self.imageSession, edit = self.textEdit;
        self.textColorLease = [MCSystemColorPanelLease beginWithOwner:self color:color showsAlpha:NO
            onColor:^(id owner, NSColor *picked) {
                MCImageEditorController *editor = owner;
                if (editor.imageSession == session && editor.textEdit == edit) [editor sharedColorPicked:picked];
            }];
        panel.level = self.window.level + 1; [panel orderFront:nil];
    }
    return result != MC_CAPTURE_TEXT_REJECTED;
}
- (MCImageTool)activeTool {
    return (MCImageTool)MAX(0, capture_toolbar_value(self.toolbarHandle, MC_CAPTURE_TOOLBAR_KIND));
}
- (NSString *)activeToolIdentifier {
    return MCEditReadString(capture_toolbar_text(self.toolbarHandle, MC_CAPTURE_TOOLBAR_ACTIVE_ID));
}
- (NSString *)activeCommand {
    return MCEditReadString(capture_toolbar_text(self.toolbarHandle, MC_CAPTURE_TOOLBAR_COMMAND));
}
- (BOOL)isToolEnabled:(MCImageTool)tool {
    return capture_toolbar_tool_enabled(self.toolbarHandle, (int32_t)tool) == 1;
}
- (BOOL)openToolbar {
    int32_t snapshot = MCImageToolSnapshot(self.toolConfiguration ?: MCDefaultImageToolConfiguration());
    if (!snapshot) return NO;
    self.toolbarHandle = capture_toolbar_open(self.imageSession, self.styleHandle, snapshot);
    tool_registry_snapshot_close(snapshot);
    return self.toolbarHandle > 0;
}
- (BOOL)nativeFieldFocused {
    return [self.window.firstResponder isKindOfClass:MCSharedTextInputView.class];
}
- (BOOL)syncToolbarContext {
    if (!self.toolbarHandle) return NO;
    BOOL blocked = self.canvas.dragging || self.canvas.regionDragging || self.window.attachedSheet != nil;
    int capabilities = MC_TOOL_CAP_COMMANDS |
        (self.onOCR ? MC_TOOL_CAP_OCR : 0) |
        (self.onTranslate ? MC_TOOL_CAP_TRANSLATE : 0) |
        (self.overlayMode && self.onScrollCapture ? MC_TOOL_CAP_SCROLL : 0) |
        ((self.onUserToolV2 || self.onUserTool) ? MC_TOOL_CAP_USER : 0);
    moonbit_string_t request = MCEditJSON(@{
        @"hasRegion":(!self.overlayMode || self.hasCaptureRegion) ? @YES : @NO, @"blocked":@(blocked),
        @"fieldFocused":@([self nativeFieldFocused]), @"pinAvailable":self.onPinPNGData ? @YES : @NO,
        @"toolbarFocused":(self.toolbar && self.window.firstResponder == self.toolbar) ? @YES : @NO,
        @"bodyEditing":self.canvas.textView ? @YES : @NO,
        @"capabilities":@(capabilities), @"assets":self.toolbarAssetIDs ?: @{},
        @"edit":@(self.textEdit),
        @"editVersion":@(self.textEdit ? capture_text_value(self.imageSession, self.textEdit, MC_CAPTURE_TEXT_VERSION) : 0),
        @"measuredHeight":@([self textMeasurement])});
    int accepted = capture_toolbar_context(self.toolbarHandle, request);
    moonbit_decref(request);
    return accepted == 1;
}
- (void)updateToolbarFrame:(CGFloat)available {
    if (!self.toolbar || available < 32 || ![self syncToolbarContext]) return;
    NSAppearanceName appearance = [self.toolbar.effectiveAppearance bestMatchFromAppearancesWithNames:
        @[NSAppearanceNameAqua, NSAppearanceNameDarkAqua]];
    moonbit_string_t frame = capture_toolbar_frame(self.toolbarHandle, available,
        [appearance isEqualToString:NSAppearanceNameDarkAqua]);
    if ([self.toolbar setFrameJSON:frame])
        self.toolbarGeneration = (int32_t)capture_toolbar_value(self.toolbarHandle, MC_CAPTURE_TOOLBAR_GENERATION);
    moonbit_decref(frame);
}
- (BOOL)activateToolbarItem:(NSString *)identifier {
    if (![self syncToolbarContext]) return NO;
    moonbit_string_t idValue = MCEditString(identifier);
    int32_t generation = (int32_t)capture_toolbar_value(self.toolbarHandle, MC_CAPTURE_TOOLBAR_GENERATION);
    BOOL handled = capture_toolbar_activate(self.toolbarHandle, generation, idValue) == 1;
    moonbit_decref(idValue);
    if (handled) [self handleToolbarEffect];
    else {
        NSString *message = MCEditReadString(capture_toolbar_text(self.toolbarHandle, MC_CAPTURE_TOOLBAR_ERROR));
        if (message.length) [self showError:MCEditorError(message)];
    }
    return handled;
}
- (void)handleToolbarEvent:(NSDictionary *)event {
    if ([event[@"type"] isEqual:@"appearance"]) { [self positionFloatingToolbar]; return; }
    if (![self syncToolbarContext]) return;
    moonbit_string_t input = MCEditJSON(event);
    BOOL handled = capture_toolbar_event(self.toolbarHandle, self.toolbarGeneration, input) == 1;
    moonbit_decref(input);
    if (handled) [self handleToolbarEffect];
    else [self positionFloatingToolbar];
}
- (void)chooseScreenshotDestination:(void (^)(NSURL *))completion {
    NSSavePanel *panel = NSSavePanel.savePanel;
    panel.allowedContentTypes = @[UTTypePNG];
    panel.canCreateDirectories = YES;
    NSDateFormatter *format = [NSDateFormatter new];
    format.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    format.dateFormat = @"yyyyMMdd_HHmmss";
    panel.nameFieldStringValue = [NSString stringWithFormat:@"moojicut_%@.png", [format stringFromDate:NSDate.date]];
    [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
        completion(response == NSModalResponseOK ? panel.URL : nil);
    }];
}
- (void)saveScreenshotForToolbar:(int32_t)toolbar ticket:(int32_t)ticket {
    [self chooseScreenshotDestination:^(NSURL *url) {
        if (self.toolbarHandle != toolbar || capture_toolbar_value(toolbar, MC_CAPTURE_TOOLBAR_TICKET) != ticket) return;
        NSError *error = nil;
        BOOL saved = NO;
        if (url) {
            int32_t candidate = (int32_t)capture_toolbar_value(toolbar, MC_CAPTURE_TOOLBAR_CANDIDATE);
            NSDictionary *document = MCEditRead(capture_candidate_document(candidate));
            NSData *png = [self renderDocumentPNGData:document error:&error];
            saved = [png writeToURL:url options:NSDataWritingAtomic error:&error];
        }
        moonbit_string_t detail = MCEditString(error.localizedDescription ?: @"");
        BOOL accepted = capture_toolbar_ack(toolbar, ticket, saved, detail) == 1;
        moonbit_decref(detail);
        if (accepted && saved) {
            [self.window close];
        } else {
            [self positionFloatingToolbar];
            if (error) [self showError:error];
        }
    }];
}
- (void)handleToolbarEffect {
    int32_t toolbar = self.toolbarHandle;
    int32_t effect = (int32_t)capture_toolbar_value(toolbar, MC_CAPTURE_TOOLBAR_EFFECT);
    int32_t ticket = (int32_t)capture_toolbar_value(toolbar, MC_CAPTURE_TOOLBAR_TICKET);
    NSString *identifier = MCEditReadString(capture_toolbar_text(toolbar, MC_CAPTURE_TOOLBAR_EFFECT_ID));
    NSString *message = MCEditReadString(capture_toolbar_text(toolbar, MC_CAPTURE_TOOLBAR_ERROR));
    if (effect == MC_CAPTURE_TOOLBAR_NONE) {
        if (message.length) [self showError:MCEditorError(message)];
        else [self positionFloatingToolbar];
        return;
    }
    if (self.textEdit && capture_text_value(self.imageSession, self.textEdit, MC_CAPTURE_TEXT_VERSION) < 0)
        [self endNativeTextInput];
    self.document = MCEditRead(image_session_document(self.imageSession));
    NSError *error = nil;
    BOOL success = YES;
    switch (effect) {
        case MC_CAPTURE_TOOLBAR_SAVE:
            [self saveScreenshotForToolbar:toolbar ticket:ticket];
            return;
        case MC_CAPTURE_TOOLBAR_COPY:
            success = [self writePNG:[self renderDocumentPNGData:self.document error:&error]
                toPasteboard:NSPasteboard.generalPasteboard error:&error];
            break;
        case MC_CAPTURE_TOOLBAR_PIN: {
            int32_t candidate = (int32_t)capture_toolbar_value(toolbar, MC_CAPTURE_TOOLBAR_CANDIDATE);
            NSDictionary *document = MCEditRead(capture_candidate_document(candidate));
            NSData *png = document ? [self renderDocumentPNGData:document error:&error] : nil;
            success = png && self.onPinPNGData && self.onPinPNGData(png);
            if (!success && !error) error = MCEditorError(@"贴图未能创建，已保留当前编辑。");
            break;
        }
        case MC_CAPTURE_TOOLBAR_REFRESH:
        case MC_CAPTURE_TOOLBAR_CANCEL:
            break;
        case MC_CAPTURE_TOOLBAR_OCR: success = self.onOCR != nil; if (success) self.onOCR(self); break;
        case MC_CAPTURE_TOOLBAR_TRANSLATE: success = self.onTranslate != nil; if (success) self.onTranslate(self); break;
        case MC_CAPTURE_TOOLBAR_SCROLL: success = self.onScrollCapture != nil; if (success) self.onScrollCapture(self); break;
        case MC_CAPTURE_TOOLBAR_USER_TOOL: {
            BOOL (^dispatch)(MCImageEditorController *, NSString *, NSString *, int32_t) = self.onUserToolV2;
            if (dispatch) {
                NSString *payload = MCEditReadString(capture_toolbar_text(toolbar, MC_CAPTURE_TOOLBAR_PAYLOAD));
                success = dispatch(self, identifier, payload, self.imageSession);
            } else {
                success = self.onUserTool != nil;
                if (success) self.onUserTool(self,identifier);
            }
            break;
        }
        default: success = NO; break;
    }
    if (self.toolbarHandle != toolbar) return;
    moonbit_string_t detail = MCEditString(error.localizedDescription ?: @"");
    BOOL acknowledged = capture_toolbar_ack(toolbar, ticket, success, detail) == 1;
    moonbit_decref(detail);
    if (!success || !acknowledged) {
        if (error) [self showError:error];
        else [self positionFloatingToolbar];
        return;
    }
    if (effect == MC_CAPTURE_TOOLBAR_COPY || effect == MC_CAPTURE_TOOLBAR_PIN || effect == MC_CAPTURE_TOOLBAR_CANCEL) {
        [self.window close];
        return;
    }
    if (effect == MC_CAPTURE_TOOLBAR_REFRESH) {
        if (![identifier isEqual:@"host.undo"] && ![identifier isEqual:@"host.redo"]) {
            self.canvas.selectedID = nil;
            [self.window makeFirstResponder:self.canvas];
            [self.canvas cancelGesture];
        }
        [self refresh];
    } else {
        [self positionFloatingToolbar];
    }
}
// Construct the exact document change without changing the editor, its field editor,
// IME state, style bank or history. Capture preflights every screen before applying.
- (NSDictionary *)pendingEditCommitPlanForPurpose:(int32_t)purpose error:(NSError **)error {
    int32_t ticket = 0;
    if (self.textEdit) {
        self.textSnapshot = MCEditRead(capture_text_snapshot(self.imageSession,self.textEdit));
        ticket = capture_text_prepare(self.imageSession,self.textEdit,
            (int32_t)capture_text_value(self.imageSession,self.textEdit,MC_CAPTURE_TEXT_VERSION),purpose,[self textMeasurement]);
        if (!ticket && error) *error = MCEditorError(MCEditReadString(capture_text_text(self.imageSession,self.textEdit,MC_CAPTURE_TEXT_ERROR)));
    } else {
        moonbit_string_t empty = MCEditJSON(nil);
        ticket = image_session_prepare_command(self.imageSession,self.styleHandle,image_session_revision(self.imageSession),empty,empty);
        moonbit_decref(empty);
        if (!ticket && error) *error = MCEditorError(@"无法准备当前截图，请重试。");
    }
    if (!ticket) return nil;
    NSDictionary *document = MCEditRead(capture_candidate_document(ticket));
    if (!document) { capture_candidate_close(ticket); return nil; }
    return @{@"ticket":@(ticket),@"document":document};
}
- (NSDictionary *)pendingEditCommitPlan:(NSError **)error {
    return [self pendingEditCommitPlanForPurpose:MC_CAPTURE_CANDIDATE_PREVIEW error:error];
}
- (NSDictionary *)preparedToolConfigurationPublication:(NSDictionary *)candidate error:(NSError **)error {
    if (![self syncToolbarContext]) return nil;
    int32_t snapshot = MCImageToolSnapshot(candidate);
    if (!snapshot) {
        if (error) *error = MCEditorError(@"无法读取截图工具配置。");
        return nil;
    }
    if (![self.configurationCandidate isEqual:candidate] ||
        !capture_toolbar_config_ready(self.toolbarHandle, self.configurationTicket)) {
        if (self.configurationTicket) capture_toolbar_config_close(self.configurationTicket);
        self.configurationTicket = capture_toolbar_config_prepare(self.toolbarHandle, snapshot);
        self.configurationCandidate = self.configurationTicket ? candidate : nil;
    }
    tool_registry_snapshot_close(snapshot);
    if (!self.configurationTicket) {
        NSString *message = MCEditReadString(capture_toolbar_text(self.toolbarHandle, MC_CAPTURE_TOOLBAR_ERROR));
        if (error) *error = MCEditorError(message.length ? message : @"请先完成当前截图输入再调整工具。");
        return nil;
    }
    return @{@"toolbar":@(self.toolbarHandle), @"candidate":@(self.configurationTicket)};
}
- (BOOL)canApplyToolConfiguration:(NSDictionary *)candidate error:(NSError **)error {
    NSAssert(NSThread.isMainThread,@"Tool configuration must be applied on the main thread");
    return [self preparedToolConfigurationPublication:candidate error:error] != nil;
}
- (void)discardToolConfigurationPublication {
    if (self.configurationTicket) capture_toolbar_config_close(self.configurationTicket);
    self.configurationTicket = 0; self.configurationCandidate = nil;
}
- (BOOL)refreshPluginDocumentForSession:(int32_t)session {
    NSAssert(NSThread.isMainThread,@"Plugin document refresh belongs to the main thread");
    if (!self.window || session <= 0 || session != self.imageSession) return NO;
    NSDictionary *document = MCEditRead(image_session_document(session));
    if (!document) return NO;
    self.document = document;
    [self refresh];
    return YES;
}
- (void)completeToolConfigurationPublication:(NSDictionary *)candidate {
    self.configurationTicket = 0; self.configurationCandidate = nil;
    self.toolConfiguration = candidate;
    if (self.textEdit && capture_text_value(self.imageSession, self.textEdit, MC_CAPTURE_TEXT_VERSION) < 0) {
        self.document = MCEditRead(image_session_document(self.imageSession));
        [self endNativeTextInput];
        self.canvas.selectedID = nil;
        [self.window makeFirstResponder:self.canvas];
        [self.canvas cancelGesture];
    }
    [self refresh];
}
- (void)applyToolConfiguration:(NSDictionary *)candidate {
    NSDictionary *publication = [self preparedToolConfigurationPublication:candidate error:NULL];
    if (!publication) return;
    if (publication.count) {
        moonbit_string_t request = MCEditJSON(@[publication]);
        int accepted = capture_toolbar_config_commit_many(request); moonbit_decref(request);
        if (!accepted) return;
    }
    [self completeToolConfigurationPublication:candidate];
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
    _imageSession = image_session_create((int32_t)bitmap.pixelsWide,(int32_t)bitmap.pixelsHigh);
    _document = _imageSession ? MCEditRead(image_session_document(_imageSession)) : nil;
    if (!_document) return nil;
    _pluginContextIdentifier = NSUUID.UUID.UUIDString;
    _pluginIcons = @{};
    _styleHandle = editor_style_create();
    _captureUIHandle = capture_ui_open(bitmap.pixelsWide, bitmap.pixelsHigh);
    if (!_styleHandle || !_captureUIHandle || ![self openToolbar]) {
        if (error) *error = MCEditorError(@"无法创建标注样式，请关闭其他编辑窗口后重试。");
        return nil;
    }
    _image = [[NSImage alloc] initWithSize:NSMakeSize(bitmap.pixelsWide, bitmap.pixelsHigh)];
    [_image addRepresentation:bitmap];
    return self;
}
- (void)dealloc {
    capture_toolbar_close(_toolbarHandle);
    image_session_dispose(_imageSession);
    editor_style_dispose(_styleHandle);
    capture_ui_close(_captureUIHandle);
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
        __weak MCImageEditorController *weakSelf = self;
        self.toolbar = [[MCSharedCanvasView alloc] initWithFrame:NSMakeRect(18, height - 46, width - 36, 32)];
        self.toolbar.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
        self.toolbar.accessibilityLabel = @"截图工具";
        self.toolbar.onEvent = ^(NSDictionary *event) { [weakSelf handleToolbarEvent:event]; };
        self.toolbar.preserveFocusOnPress = ^BOOL { return [weakSelf nativeFieldFocused]; };
        self.toolbar.onFrameNeeded = ^(CGSize size) {
            if (!weakSelf.overlayMode) [weakSelf updateToolbarFrame:size.width];
        };
        [root addSubview:self.toolbar];
        self.propertyStatus = [NSTextField labelWithString:@""];
        self.propertyStatus.font = [NSFont systemFontOfSize:11];
        self.propertyStatus.textColor = NSColor.secondaryLabelColor;
        self.propertyStatus.lineBreakMode = NSLineBreakByTruncatingTail;
        self.propertyStatus.hidden = YES;
        self.textPropertyInputs = [NSMutableDictionary dictionary];
        self.textPropertiesCanvas = [[MCSharedCanvasView alloc] initWithFrame:NSZeroRect];
        self.textPropertiesCanvas.hidden = YES;
        self.textPropertiesCanvas.onEvent = ^(NSDictionary *event) { [weakSelf handleSharedTextUIEvent:event]; };
        self.textPropertiesCanvas.preserveFocusOnPress = ^BOOL { return [weakSelf nativeFieldFocused]; };
        self.propertyStatus.frame = NSMakeRect(24, height - 104, width - 48, 18);
        self.propertyStatus.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
        [root addSubview:self.propertyStatus];
        self.textPropertiesCanvas.frame = NSMakeRect(24, height - 86, width - 48, 34);
        self.textPropertiesCanvas.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
        [root addSubview:self.textPropertiesCanvas];
        self.pluginIcons = _pluginIcons;
        [self updateToolbarFrame:self.toolbar.bounds.size.width];
        if ([self isToolEnabled:MCRectTool]) [self activateToolbarItem:@"builtin.image.rectangle"];
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
    self.floatingToolbar.layer.masksToBounds = YES;
    self.floatingToolbar.hidden = YES;
    [self.toolbar removeFromSuperview]; self.toolbar.autoresizingMask = NSViewNotSizable;
    [self.floatingToolbar addSubview:self.toolbar];
    [self.textPropertiesCanvas removeFromSuperview]; self.textPropertiesCanvas.autoresizingMask = NSViewNotSizable;
    self.propertiesScroll = [NSScrollView new];
    self.propertiesScroll.drawsBackground = NO; self.propertiesScroll.borderType = NSNoBorder;
    self.propertiesScroll.hasHorizontalScroller = YES; self.propertiesScroll.autohidesScrollers = YES;
    self.propertiesScroll.scrollerStyle = NSScrollerStyleOverlay;
    self.propertiesScroll.documentView = self.textPropertiesCanvas;
    [self.floatingToolbar addSubview:self.propertiesScroll];
    [self.propertyStatus removeFromSuperview];
    self.propertyStatus.autoresizingMask = NSViewNotSizable;
    [self.floatingToolbar addSubview:self.propertyStatus];
    [root addSubview:self.floatingToolbar];
    [self positionFloatingToolbar];
    // The system color panel must remain above the capture overlay.
    NSColorPanel.sharedColorPanel.level = self.window.level + 1;
    self.canvas.needsDisplay = YES;
}
- (void)setWindowCandidates:(NSArray<NSDictionary *> *)candidates { self.canvas.windowCandidates = candidates; }
- (BOOL)setCaptureRegion:(NSRect)rect {
    CGFloat left = floor(rect.origin.x), top = floor(rect.origin.y);
    CGFloat right = MIN([self.document[@"width"] doubleValue], ceil(NSMaxX(rect)));
    CGFloat bottom = MIN([self.document[@"height"] doubleValue], ceil(NSMaxY(rect)));
    NSDictionary *viewport = @{@"x":@(left), @"y":@(top), @"width":@(right - left), @"height":@(bottom - top)};
    BOOL passed = YES;
    if (!self.hasCaptureRegion) {
        NSError *error = nil;
        int32_t created = image_session_create_viewport([self.document[@"width"] intValue],[self.document[@"height"] intValue],
            (int32_t)left,(int32_t)top,(int32_t)(right-left),(int32_t)(bottom-top));
        if (!created) { [self showError:error ?: MCEditorError(@"无法创建截图选区。")]; return NO; }
        int32_t originalSession = self.imageSession, originalToolbar = self.toolbarHandle;
        self.imageSession = created;
        if (![self openToolbar]) {
            self.imageSession = originalSession; self.toolbarHandle = originalToolbar;
            image_session_dispose(created);
            return NO;
        }
        [self endNativeTextInput];
        capture_toolbar_close(originalToolbar); image_session_dispose(originalSession);
        self.document = MCEditRead(image_session_document(created));
        self.hasCaptureRegion = YES;
    } else if (![viewport isEqual:self.document[@"viewport"]]) {
        passed = [self applyCommand:@{@"type":@"crop", @"rect":viewport}];
    }
    [self refresh]; [self positionFloatingToolbar];
    return passed;
}
- (void)positionFloatingToolbar {
    if (!self.overlayMode || !self.floatingToolbar) {
        [self updateToolbarFrame:self.toolbar.bounds.size.width];
        return;
    }
    self.floatingToolbar.hidden = !self.hasCaptureRegion || self.canvas.regionDragging;
    [self.window invalidateCursorRectsForView:self.canvas];
    if (self.floatingToolbar.hidden) return;
    NSView *root = self.window.contentView;
    NSRect region = [self.canvas viewRectForImageRect:MCAnnotationRect(self.document[@"viewport"])];
    region = [self.canvas convertRect:region toView:root];
    CGFloat margin = MIN(8, NSWidth(root.bounds) / 8);
    CGFloat available = MAX(1, NSWidth(root.bounds) - 2 * margin);
    CGFloat inset = MIN(4, available / 8);
    CGFloat contentAvailable = MAX(1, available - 2 * inset);
    [self updateToolbarFrame:contentAvailable];
    CGFloat rowWidth = capture_toolbar_value(self.toolbarHandle, MC_CAPTURE_TOOLBAR_WIDTH);
    // The shared frame owns the complete property row; narrow screens scroll it.
    BOOL hasProperties = self.textEdit != 0;
    CGFloat propertiesWidth = hasProperties ? capture_text_value(self.imageSession,self.textEdit,MC_CAPTURE_TEXT_ROW_WIDTH) : 0;
    NSView *propertyRow = self.textPropertiesCanvas;
    CGFloat rowHeight = capture_toolbar_value(self.toolbarHandle, MC_CAPTURE_TOOLBAR_HEIGHT), padding = 4;
    CGFloat propertyHeight = hasProperties ? capture_text_value(self.imageSession,self.textEdit,MC_CAPTURE_TEXT_ROW_HEIGHT) : 0;
    CGFloat statusHeight = self.propertyStatus.hidden ? 0 : 20;
    CGFloat statusWidth = self.propertyStatus.hidden ? 0 : MIN(contentAvailable, self.propertyStatus.fittingSize.width);
    double *frame = capture_ui_measured_toolbar_frame(NSWidth(root.bounds), NSHeight(root.bounds),
        NSMinX(region), NSHeight(root.bounds) - NSMaxY(region), NSWidth(region), NSHeight(region),
        MAX(MAX(rowWidth,propertiesWidth),statusWidth) + 2*inset,
        2*padding + rowHeight + (hasProperties ? propertyHeight + 2 : 0) + statusHeight);
    CGFloat x = frame[0], width = frame[2], height = frame[3];
    CGFloat y = NSHeight(root.bounds) - frame[1] - height;
    moonbit_decref(frame);
    self.floatingToolbar.frame = NSMakeRect(x, y, width, height);
    CGFloat viewportWidth = MAX(1, width - 2 * inset);
    self.toolbar.frame = NSMakeRect(inset, height - padding - rowHeight, MIN(rowWidth, viewportWidth), rowHeight);
    self.propertiesScroll.hidden = !hasProperties;
    self.propertiesScroll.frame = NSMakeRect(inset, padding + statusHeight, viewportWidth, propertyHeight);
    self.propertyStatus.frame = NSMakeRect(inset, padding, viewportWidth, statusHeight);
    propertyRow.frame = NSMakeRect(0, 0, MAX(1, propertiesWidth), propertyHeight);
    [self.floatingToolbar layoutSubtreeIfNeeded];
    [self.window invalidateCursorRectsForView:self.canvas];
}
- (void)show {
    if (!self.window) [self prepareWindow];
    [NSApp unhide:nil];
    [NSApp activateIgnoringOtherApps:YES];
    [self.window makeKeyAndOrderFront:nil];
    [self.window makeFirstResponder:self.canvas];
    [self.canvas updateWindowHover:[self.canvas convertPoint:self.window.mouseLocationOutsideOfEventStream fromView:nil]];
}
- (void)refresh {
    if (self.canvas.selectedID && ![self.canvas selectedAnnotation]) self.canvas.selectedID = nil;
    self.canvas.needsDisplay = YES;
    [self.canvas updateTextFrame];
    [self syncTextControls];
    [self positionFloatingToolbar];
}
- (void)setOnUserTool:(void (^)(MCImageEditorController *,NSString *))handler {
    _onUserTool = [handler copy]; [self positionFloatingToolbar];
}
- (void)setOnUserToolV2:(BOOL (^)(MCImageEditorController *,NSString *,NSString *,int32_t))handler {
    _onUserToolV2 = [handler copy]; [self positionFloatingToolbar];
}
- (void)setPluginIcons:(NSDictionary<NSString *,NSImage *> *)icons {
    _pluginIcons = [icons copy] ?: @{};
    NSMutableDictionary *keys = [NSMutableDictionary dictionary], *assets = [NSMutableDictionary dictionary];
    for (NSString *identifier in [_pluginIcons.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        NSString *key = [NSString stringWithFormat:@"plugin-icon-%lu", (unsigned long)keys.count];
        keys[identifier] = key;
        assets[key] = _pluginIcons[identifier];
    }
    self.toolbarAssetIDs = keys;
    self.toolbar.imageAssets = assets;
    [self positionFloatingToolbar];
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
    NSDictionary *identity = @{@"context":self.pluginContextIdentifier, @"width":document[@"width"], @"height":document[@"height"],
        @"viewport":annotation(document[@"viewport"]), @"annotations":[annotations copy]};
    capture_candidate_close([plan[@"ticket"] intValue]);
    return identity;
}
- (void)showPluginMessage:(NSString *)message {
    self.propertyStatus.stringValue = message; self.propertyStatus.hidden = NO;
    [self positionFloatingToolbar];
}
- (void)setOnOCR:(void (^)(MCImageEditorController *))handler {
    _onOCR = [handler copy]; [self positionFloatingToolbar];
}
- (void)setOnTranslate:(void (^)(MCImageEditorController *))handler {
    _onTranslate = [handler copy]; [self positionFloatingToolbar];
}
- (void)setOnScrollCapture:(void (^)(MCImageEditorController *))handler {
    _onScrollCapture = [handler copy]; [self positionFloatingToolbar];
}
- (void)setOnPinPNGData:(BOOL (^)(NSData *))handler {
    _onPinPNGData = [handler copy];
    [self positionFloatingToolbar];
}
- (void)showError:(NSError *)error {
    self.propertyStatus.stringValue = error.localizedDescription ?: @"";
    self.propertyStatus.hidden = self.propertyStatus.stringValue.length == 0;
    [self positionFloatingToolbar];
    NSBeep();
}
- (NSString *)colorHex {
    return [NSString stringWithFormat:@"#%06x",(unsigned)editor_style_get(self.styleHandle,(int32_t)self.activeTool,MC_STYLE_COLOR)];
}
- (void)syncTextControls {
    self.propertyStatus.hidden = YES; self.propertyStatus.stringValue = @"";
    NSDictionary *annotation = [self.canvas selectedAnnotation];
    if (!self.textEdit && !self.endingText && !self.canvas.dragging && !self.canvas.regionDragging) {
        [self beginPropertyTransaction:annotation];
    }
    self.textPropertiesCanvas.hidden = self.textEdit == 0;
    if (self.textEdit) {
        [self syncSharedText];
        if (!self.overlayMode) {
            NSRect row = self.textPropertiesCanvas.frame;
            row.size.height = capture_text_value(self.imageSession,self.textEdit,MC_CAPTURE_TEXT_ROW_HEIGHT);
            self.textPropertiesCanvas.frame = row;
        }
    }
    [self positionFloatingToolbar];
    [self.window invalidateCursorRectsForView:self.canvas];
}
- (NSDictionary *)shapeEvent:(NSString *)phase point:(NSPoint)point {
    BOOL beginning = [phase isEqual:@"begin"];
    // The shared image/toolbar session owns plugin drag geometry, generation,
    // crop-relative release payload and one-shot dispatch. Native never creates
    // a provisional annotation or translates the plugin selection itself.
    BOOL pluginGesture = [(beginning ? self.activeCommand : self.gestureCommand) isEqual:@"plugin.run"];
    if (pluginGesture) {
        if (beginning) {
            if (![self finishSharedText:YES] || ![self syncToolbarContext]) return nil;
            moonbit_string_t command = MCEditString(@"plugin.run");
            int32_t kind = (int32_t)self.activeTool;
            int accepted = image_session_tool_begin(self.imageSession, command, point.x, point.y,
                (int32_t)editor_style_get(self.styleHandle,kind,MC_STYLE_COLOR),
                editor_style_get(self.styleHandle,kind,MC_STYLE_STROKE),
                editor_style_get(self.styleHandle,kind,MC_STYLE_OPACITY), 0,
                editor_style_get(self.styleHandle,kind,MC_STYLE_BLOCK));
            moonbit_decref(command);
            self.gestureCommand = accepted ? @"plugin.run" : nil;
            return accepted ? @{@"active":@YES, @"command":NSNull.null, @"preview":NSNull.null} : nil;
        }
        int32_t event = [phase isEqual:@"move"] ? 0 : [phase isEqual:@"end"] ? 1 : [phase isEqual:@"cancel"] ? 2 : -1;
        if (event < 0) return nil;
        BOOL accepted = image_session_shape_event(self.imageSession,event,point.x,point.y) == 1;
        NSDictionary *preview = nil;
        if (accepted && event == 0 && image_session_preview_value(self.imageSession,0) == 1) {
            unsigned rgb = (unsigned)image_session_preview_value(self.imageSession,5);
            preview = @{@"type":@"rect", @"x":@(image_session_preview_value(self.imageSession,1)),
                @"y":@(image_session_preview_value(self.imageSession,2)),
                @"width":@(image_session_preview_value(self.imageSession,3)),
                @"height":@(image_session_preview_value(self.imageSession,4)),
                @"color":[NSString stringWithFormat:@"#%06x",rgb],
                @"stroke":@(image_session_preview_value(self.imageSession,6)),
                @"opacity":@(image_session_preview_value(self.imageSession,8))};
        }
        if (event != 0 || !accepted) {
            if (!accepted) image_session_shape_event(self.imageSession,2,0,0);
            self.gestureCommand = nil; self.gestureRevision = nil;
            self.canvas.pending = nil;
        }
        if (accepted && event == 1 && capture_toolbar_value(self.toolbarHandle,MC_CAPTURE_TOOLBAR_EFFECT) != MC_CAPTURE_TOOLBAR_NONE)
            [self handleToolbarEffect];
        return accepted ? @{@"active":@(event == 0), @"preview":preview ?: NSNull.null, @"command":NSNull.null} : nil;
    }
    NSMutableDictionary *request = [@{@"session":@(self.captureUIHandle), @"type":phase,
        @"x":@(point.x), @"y":@(point.y)} mutableCopy];
    if ([phase isEqual:@"begin"]) {
        if (![self finishSharedText:YES]) return nil;
        if (self.activeTool == MCSelectTool || self.activeTool == MCTextTool ||
            (!self.activeCommand.length && ![self isToolEnabled:self.activeTool])) return nil;
        self.gestureCommand = self.activeCommand; self.gestureRevision = self.document[@"revision"];
        [request addEntriesFromDictionary:@{@"id":NSUUID.UUID.UUIDString, @"kind":@(self.activeTool),
            @"stroke":@(editor_style_get(self.styleHandle,(int32_t)self.activeTool,MC_STYLE_STROKE)),
            @"opacity":@(editor_style_get(self.styleHandle,(int32_t)self.activeTool,MC_STYLE_OPACITY)), @"color":[self colorHex],
            @"shape":self.activeCommand.length ? @0 : @(editor_style_get(self.styleHandle,(int32_t)self.activeTool,MC_STYLE_SHAPE)),
            @"blockSize":@(editor_style_get(self.styleHandle,(int32_t)self.activeTool,MC_STYLE_BLOCK))}];
    }
    NSDictionary *result = MCCallCore(capture_ui_event,request,NULL);
    if ([phase isEqual:@"end"] && [result[@"command"] isKindOfClass:NSDictionary.class]) {
        if (![self.gestureRevision isEqual:self.document[@"revision"]]) result = nil;
        else if (self.gestureCommand.length) {
            NSError *error = nil;
            NSDictionary *generated = MCCallCore(image_contribution_command,@{@"document":self.document,
                @"expectedRevision":self.gestureRevision, @"command":self.gestureCommand,
                @"rectangle":result[@"command"][@"annotations"][0]},&error);
            if (generated) { NSMutableDictionary *changed = [result mutableCopy]; changed[@"command"] = generated[@"command"]; result = changed; }
            else { [self showError:error]; result = nil; }
        }
    }
    if ([phase isEqual:@"cancel"] || [phase isEqual:@"end"]) { self.gestureCommand = nil; self.gestureRevision = nil; }
    return result;
}
- (void)addTextAtPoint:(NSPoint)point {
    if (![self isToolEnabled:MCTextTool]) return;
    if (![self finishSharedText:YES]) return;
    CGFloat size = editor_style_get(self.styleHandle,MCTextTool,MC_STYLE_FONT);
    CGFloat width = [self.document[@"width"] doubleValue], height = [self.document[@"height"] doubleValue];
    NSRect region = self.overlayMode && self.hasCaptureRegion ? MCAnnotationRect(self.document[@"viewport"]) : NSMakeRect(0, 0, width, height);
    CGFloat boxWidth = MIN(280, region.size.width), boxHeight = MIN(ceil(size * 1.5), region.size.height);
    CGFloat x = MAX(NSMinX(region), MIN(point.x, NSMaxX(region) - MIN(boxWidth, 80)));
    CGFloat y = MAX(NSMinY(region), MIN(point.y, NSMaxY(region) - boxHeight));
    [self.canvas beginEditingText:@{@"id":NSUUID.UUID.UUIDString, @"type":@"text", @"text":@"",
        @"x":@(x), @"y":@(y), @"width":@(MIN(boxWidth, NSMaxX(region) - x)), @"height":@(boxHeight),
        @"fontSize":@(size), @"stroke":@(editor_style_default(MC_STYLE_STROKE)),
        @"opacity":@(editor_style_get(self.styleHandle,MCTextTool,MC_STYLE_OPACITY)), @"color":[self colorHex]}];
}
- (BOOL)applyCommand:(NSDictionary *)command {
    if (self.textEdit && ![self finishSharedText:YES]) return NO;
    moonbit_string_t input = MCEditJSON(command);
    int accepted = image_session_command(self.imageSession,image_session_revision(self.imageSession),input);
    moonbit_decref(input);
    if (!accepted) { [self showError:MCEditorError(@"MoonBit 无法应用标注。")]; return NO; }
    self.document = MCEditRead(image_session_document(self.imageSession)); [self refresh]; return YES;
}
- (BOOL)applyAnnotation:(NSDictionary *)annotation { return [self applyCommand:@{@"type":@"add", @"annotations":@[annotation]}]; }
- (void)undo:(id)sender { (void)sender; [self activateToolbarItem:@"host.undo"]; }
- (void)redo:(id)sender { (void)sender; [self activateToolbarItem:@"host.redo"]; }
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
    NSData *png = plan ? [self renderDocumentPNGData:plan[@"document"] ?: self.document error:error] : nil;
    if (plan) capture_candidate_close([plan[@"ticket"] intValue]);
    return png;
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
    return [self writePNG:[self renderPNGData:error] toPasteboard:pasteboard error:error];
}
- (BOOL)writePNG:(NSData *)png toPasteboard:(NSPasteboard *)pasteboard error:(NSError **)error {
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
- (void)confirm:(id)sender { (void)sender; [self activateToolbarItem:@"host.confirm"]; }
- (NSRect)pinScreenFrame {
    if (!self.window || !self.canvas) return NSZeroRect;
    NSRect region = [self.canvas viewRectForImageRect:MCAnnotationRect(self.document[@"viewport"])];
    return [self.window convertRectToScreen:[self.canvas convertRect:region toView:nil]];
}
- (NSRect)captureScreenFrame {
    if (self.overlayMode && !self.hasCaptureRegion) return NSZeroRect;
    return self.pinScreenFrame;
}
- (void)pinImage:(id)sender { (void)sender; [self activateToolbarItem:@"builtin.image.pin"]; }
- (void)cancel:(id)sender { (void)sender; [self activateToolbarItem:@"host.cancel"]; }
- (void)windowWillClose:(NSNotification *)notification {
    (void)notification;
    [self discardToolConfigurationPublication];
    if (self.textEdit) capture_text_cancel(self.imageSession,self.textEdit,
        (int32_t)capture_text_value(self.imageSession,self.textEdit,MC_CAPTURE_TEXT_VERSION));
    [self endNativeTextInput];
    capture_toolbar_close(self.toolbarHandle); self.toolbarHandle = 0;
    image_session_dispose(self.imageSession); self.imageSession = 0;
    capture_ui_close(self.captureUIHandle);
    self.captureUIHandle = 0;
    void (^closed)(void) = self.onClose;
    self.onClose = nil;
    if (self.onPluginContextClosed) self.onPluginContextClosed(self.pluginContextIdentifier);
    self.window.delegate = nil;
    self.window.contentView = nil;
    self.window = nil;
    self.canvas = nil;
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
