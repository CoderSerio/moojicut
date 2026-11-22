#import "MCSharedCanvas.h"
#import <QuartzCore/QuartzCore.h>
#include <math.h>
#include "platform/shared/graphics/canvas.h"

static BOOL MCCanvasNumber(id value, CGFloat *result) {
    if (![value isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()) return NO;
    double number = [value doubleValue];
    if (!isfinite(number)) return NO;
    *result = number; return YES;
}
static BOOL MCCanvasDecodeRect(NSDictionary *value, NSRect *result) {
    if (![value isKindOfClass:NSDictionary.class]) return NO;
    CGFloat x, y, width, height;
    if (!MCCanvasNumber(value[@"x"], &x) || !MCCanvasNumber(value[@"y"], &y) ||
        !MCCanvasNumber(value[@"width"], &width) || !MCCanvasNumber(value[@"height"], &height) ||
        width < 0 || height < 0 || !isfinite(x + width) || !isfinite(y + height)) return NO;
    *result = NSMakeRect(x, y, width, height); return YES;
}
static NSString *MCCanvasString(id value) {
    return [value isKindOfClass:NSString.class] ? value : nil;
}
static NSColor *MCCanvasRGB(int32_t rgb) {
    return [NSColor colorWithSRGBRed:((rgb >> 16) & 255) / 255.0
        green:((rgb >> 8) & 255) / 255.0 blue:(rgb & 255) / 255.0 alpha:1];
}
static NSRect MCCanvasNativeRect(MCCanvasRect rect) {
    return NSMakeRect(rect.x,rect.y,rect.width,rect.height);
}
static void MCCanvasPaintRect(void *context, MCCanvasRect rect, double radius,
                              int32_t fill, int32_t stroke, double lineWidth) {
    (void)context;
    NSBezierPath *path = [NSBezierPath bezierPathWithRoundedRect:MCCanvasNativeRect(rect) xRadius:radius yRadius:radius];
    if (fill >= 0) { [MCCanvasRGB(fill) setFill]; [path fill]; }
    if (stroke >= 0) { [MCCanvasRGB(stroke) setStroke]; path.lineWidth = lineWidth; [path stroke]; }
}
static void MCCanvasPaintLine(void *context, double x1, double y1, double x2, double y2,
                              int32_t color, double width) {
    (void)context;
    NSBezierPath *path = [NSBezierPath bezierPath];
    [path moveToPoint:NSMakePoint(x1,y1)]; [path lineToPoint:NSMakePoint(x2,y2)];
    [MCCanvasRGB(color) setStroke]; path.lineWidth = width; [path stroke];
}
static void MCCanvasPaintText(void *context, const MCCanvasText *command) {
    (void)context;
    NSString *text = [[NSString alloc] initWithCharacters:command->text length:command->length];
    NSRect rect = MCCanvasNativeRect(command->rect);
    NSFontWeight weight = command->weight == MC_UI_WEIGHT_BOLD ? NSFontWeightBold :
        command->weight == MC_UI_WEIGHT_MEDIUM ? NSFontWeightMedium : NSFontWeightRegular;
    NSMutableParagraphStyle *paragraph = [NSMutableParagraphStyle new];
    paragraph.alignment = command->align == MC_UI_ALIGN_CENTER ? NSTextAlignmentCenter :
        command->align == MC_UI_ALIGN_RIGHT ? NSTextAlignmentRight : NSTextAlignmentLeft;
    paragraph.lineBreakMode = NSLineBreakByTruncatingTail;
    NSFont *font = [NSFont systemFontOfSize:command->size weight:weight];
    NSDictionary *attributes = @{NSFontAttributeName:font,
        NSForegroundColorAttributeName:MCCanvasRGB(command->color),NSParagraphStyleAttributeName:paragraph};
    NSRect textRect = rect;
    NSStringDrawingOptions options = command->single_line ? 0 : NSStringDrawingUsesLineFragmentOrigin;
    if (command->valign == MC_UI_VALIGN_CENTER) {
        CGFloat height = [text boundingRectWithSize:NSMakeSize(rect.size.width,CGFLOAT_MAX)
            options:options attributes:attributes].size.height;
        if (!isfinite(height) || height <= 0) height = font.ascender-font.descender+font.leading;
        height = ceil(height); textRect.origin.y += (rect.size.height-height)/2; textRect.size.height = height;
    }
    [NSGraphicsContext saveGraphicsState]; NSRectClip(rect);
    [text drawWithRect:textRect options:options | NSStringDrawingTruncatesLastVisibleLine
        attributes:attributes];
    [NSGraphicsContext restoreGraphicsState];
}
static void MCCanvasPaintAsset(void *context, MCCanvasRect rect, const uint16_t *key, size_t length) {
    MCSharedCanvasView *canvas = (__bridge MCSharedCanvasView *)context;
    NSString *identifier = [[NSString alloc] initWithCharacters:key length:length];
    NSImage *image = canvas.imageAssets[identifier];
    if (!image || image.size.width <= 0 || image.size.height <= 0 || rect.width <= 0 || rect.height <= 0) return;
    CGFloat scale = MIN(rect.width / image.size.width, rect.height / image.size.height);
    NSSize size = NSMakeSize(image.size.width * scale, image.size.height * scale);
    NSRect destination = NSMakeRect(rect.x + (rect.width-size.width)/2, rect.y + (rect.height-size.height)/2,
        size.width, size.height);
    [image drawInRect:destination fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1
        respectFlipped:YES hints:nil];
}
static NSString *MCCanvasOwnedString(moonbit_string_t value) {
    NSString *text = [[NSString alloc] initWithCharacters:value length:Moonbit_array_length(value)];
    moonbit_decref(value); return text;
}
static NSAccessibilityRole MCCanvasRole(NSDictionary *descriptor) {
    NSString *role = MCCanvasString(descriptor[@"role"]);
    if ([role isEqualToString:@"button"]) return NSAccessibilityButtonRole;
    if ([role isEqualToString:@"slider"]) return NSAccessibilitySliderRole;
    if ([role isEqualToString:@"checkbox"]) return NSAccessibilityCheckBoxRole;
    if ([role isEqualToString:@"staticText"] || [role isEqualToString:@"text"] || [role isEqualToString:@"label"])
        return NSAccessibilityStaticTextRole;
    return NSAccessibilityGroupRole;
}

@interface MCCanvasVideoSurface : NSView
@end
@implementation MCCanvasVideoSurface
- (NSView *)hitTest:(NSPoint)point { (void)point; return nil; }
- (BOOL)isAccessibilityElement { return NO; }
- (NSArray *)accessibilityChildren { return @[]; }
@end

@interface MCCanvasOverlaySurface : MCCanvasVideoSurface
@property (nonatomic, weak) MCSharedCanvasView *canvas;
@end

@class MCCanvasAccessibilityElement;
@interface MCSharedCanvasView () <NSViewToolTipOwner>
@property NSTrackingArea *pointerTracking;
@property MCCanvasVideoSurface *videoSurface;
@property AVPlayerLayer *videoLayer;
@property MCCanvasOverlaySurface *overlaySurface;
@property NSArray<MCCanvasAccessibilityElement *> *semanticElements;
@property NSArray<NSDictionary *> *tooltipRegions;
@property BOOL pointerDown, pointerInside, inputActive;
@property BOOL deliveredSize;
@property int32_t frameHandle;
@property (nonatomic, copy) NSString *serializedFrame;
@property CGSize lastDeliveredSize;
- (void)emitEvent:(NSDictionary *)event;
- (void)focusForPress;
- (void)cancelInput;
- (void)updateVideoSurface;
- (void)updateSemantics;
- (void)updateTooltips;
- (void)drawLayer:(int32_t)layer dirtyRect:(NSRect)dirtyRect;
@end

@implementation MCCanvasOverlaySurface
- (BOOL)isFlipped { return YES; }
- (void)drawRect:(NSRect)dirtyRect {
    [self.canvas drawLayer:MC_UI_LAYER_OVERLAY dirtyRect:dirtyRect];
}
@end

@interface MCCanvasAccessibilityElement : NSAccessibilityElement
@property (nonatomic, weak) MCSharedCanvasView *canvas;
@property (nonatomic, copy) NSDictionary *descriptor;
@end
@implementation MCCanvasAccessibilityElement
- (id)accessibilityParent { return self.canvas; }
- (NSString *)accessibilityIdentifier { return MCCanvasString(self.descriptor[@"id"]); }
- (NSAccessibilityRole)accessibilityRole { return MCCanvasRole(self.descriptor); }
- (NSString *)accessibilityLabel { return MCCanvasString(self.descriptor[@"label"]); }
- (NSString *)accessibilityHelp { return MCCanvasString(self.descriptor[@"tooltip"]) ?: self.accessibilityLabel; }
- (id)accessibilityValue {
    id value = self.descriptor[@"value"];
    return [value isKindOfClass:NSString.class] || [value isKindOfClass:NSNumber.class] ? value : nil;
}
- (id)accessibilityMinValue {
    id value = self.descriptor[@"min"]; return [value isKindOfClass:NSNumber.class] ? value : nil;
}
- (id)accessibilityMaxValue {
    id value = self.descriptor[@"max"]; return [value isKindOfClass:NSNumber.class] ? value : nil;
}
- (BOOL)isAccessibilityEnabled {
    id enabled = self.descriptor[@"enabled"];
    return [enabled isKindOfClass:NSNumber.class] ? [enabled boolValue] : YES;
}
- (BOOL)isAccessibilityFocused { return [self.descriptor[@"focused"] isEqual:@YES]; }
- (NSRect)accessibilityFrame {
    NSRect rect;
    MCSharedCanvasView *canvas = self.canvas;
    if (!canvas.window || !MCCanvasDecodeRect(self.descriptor, &rect)) return NSZeroRect;
    return [canvas.window convertRectToScreen:[canvas convertRect:rect toView:nil]];
}
- (BOOL)accessibilityPerformPress {
    NSString *identifier = self.accessibilityIdentifier;
    NSAccessibilityRole role = self.accessibilityRole;
    if ((![role isEqualToString:NSAccessibilityButtonRole] && ![role isEqualToString:NSAccessibilitySliderRole] &&
         ![role isEqualToString:NSAccessibilityCheckBoxRole]) ||
        !self.isAccessibilityEnabled || !identifier.length || !self.canvas.onEvent) return NO;
    [self.canvas focusForPress];
    [self.canvas emitEvent:@{ @"type":@"activate", @"id":identifier }];
    return YES;
}
- (BOOL)adjustWithKey:(NSString *)key {
    if (![self.accessibilityRole isEqualToString:NSAccessibilitySliderRole]) return NO;
    MCSharedCanvasView *canvas = self.canvas;
    if (![self accessibilityPerformPress] || self.canvas != canvas || !canvas.onEvent || !self.isAccessibilityEnabled) return NO;
    [canvas emitEvent:@{ @"type":@"key", @"key":key, @"mod":@NO, @"shift":@NO }];
    return YES;
}
- (BOOL)accessibilityPerformIncrement { return [self adjustWithKey:@"ArrowRight"]; }
- (BOOL)accessibilityPerformDecrement { return [self adjustWithKey:@"ArrowLeft"]; }
@end

@implementation MCSharedCanvasView
@synthesize frameDescription = _frameDescription;
- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) [self initializeCanvas];
    return self;
}
- (instancetype)initWithCoder:(NSCoder *)coder {
    if ((self = [super initWithCoder:coder])) [self initializeCanvas];
    return self;
}
- (void)initializeCanvas {
    _semanticElements = @[];
    _videoLayer = [AVPlayerLayer playerLayerWithPlayer:nil];
    _videoLayer.videoGravity = AVLayerVideoGravityResizeAspect;
    _videoSurface = [MCCanvasVideoSurface new];
    // AppKit owns the surface's backing-layer geometry. The player is a
    // child layer: setting its local bounds must never move the surface's
    // root layer away from the shared UI's videoRect.
    _videoSurface.wantsLayer = YES;
    [_videoSurface.layer addSublayer:_videoLayer];
    _videoSurface.hidden = YES;
    [self addSubview:_videoSurface];
    _overlaySurface = [[MCCanvasOverlaySurface alloc] initWithFrame:self.bounds];
    _overlaySurface.canvas = self;
    _overlaySurface.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    _overlaySurface.wantsLayer = YES;
    [self addSubview:_overlaySurface positioned:NSWindowAbove relativeTo:_videoSurface];
}
- (BOOL)isFlipped { return YES; }
- (void)viewDidChangeEffectiveAppearance {
    [super viewDidChangeEffectiveAppearance];
    NSAppearanceName match = [self.effectiveAppearance bestMatchFromAppearancesWithNames:
        @[NSAppearanceNameAqua, NSAppearanceNameDarkAqua]];
    [self emitEvent:@{@"type":@"appearance", @"mode":[match isEqualToString:NSAppearanceNameDarkAqua] ? @"dark" : @"light"}];
}
- (BOOL)wantsDefaultClipping { return YES; }
- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)acceptsFirstMouse:(NSEvent *)event { (void)event; return YES; }
- (BOOL)becomeFirstResponder {
    BOOL accepted = [super becomeFirstResponder];
    if (accepted) self.inputActive = YES;
    return accepted;
}
- (BOOL)resignFirstResponder {
    BOOL accepted = [super resignFirstResponder];
    if (accepted) [self cancelInput];
    return accepted;
}
- (void)setOnFrameNeeded:(void (^)(CGSize))onFrameNeeded {
    _onFrameNeeded = [onFrameNeeded copy];
    self.deliveredSize = NO; self.needsLayout = YES;
}
- (void)setFrameSize:(NSSize)size {
    [super setFrameSize:size]; self.needsLayout = YES;
}
- (void)setBoundsSize:(NSSize)size {
    [super setBoundsSize:size]; self.needsLayout = YES;
}
- (NSDictionary *)frameDescription {
    if (!_frameDescription && self.serializedFrame) {
        NSData *data = [self.serializedFrame dataUsingEncoding:NSUTF8StringEncoding];
        _frameDescription = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    }
    return _frameDescription;
}
- (void)setFrameDescription:(NSDictionary *)frameDescription {
    if (!frameDescription) {
        int32_t previous = self.frameHandle; self.frameHandle = 0;
        self.serializedFrame = nil; _frameDescription = nil;
        if (previous) ui_frame_close(previous);
        [self frameDidChange]; return;
    }
    if (![NSJSONSerialization isValidJSONObject:frameDescription]) return;
    NSData *data = [NSJSONSerialization dataWithJSONObject:frameDescription options:0 error:NULL];
    NSString *json = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
    if (!json || json.length > INT32_MAX) return;
    moonbit_string_t value = moonbit_make_string_raw((int32_t)json.length);
    [json getCharacters:value range:NSMakeRange(0,json.length)];
    [self setFrameJSON:value]; moonbit_decref(value);
}
- (BOOL)setFrameJSON:(moonbit_string_t)json {
    NSAssert(NSThread.isMainThread, @"Canvas frames belong to their UI thread");
    int32_t next = ui_frame_open(json);
    if (!next) return NO;
    NSString *source = [[NSString alloc] initWithCharacters:json length:Moonbit_array_length(json)];
    int32_t previous = self.frameHandle;
    self.frameHandle = next; self.serializedFrame = source; _frameDescription = nil;
    if (previous) ui_frame_close(previous);
    [self frameDidChange]; return YES;
}
- (void)frameDidChange {
    [self updateVideoSurface]; [self updateSemantics]; [self updateTooltips];
    self.needsDisplay = YES; self.overlaySurface.needsDisplay = YES;
    [self.window invalidateCursorRectsForView:self];
    if (self.pointerInside && self.window.isKeyWindow) [[self frameCursor] set];
}
- (void)setVideoPlayer:(AVPlayer *)player {
    self.videoLayer.player = player;
    [self updateVideoSurface];
}
- (void)updateVideoSurface {
    MCCanvasRect sharedRect;
    BOOL visible = self.videoLayer.player && mc_canvas_video_rect(self.frameHandle,&sharedRect) &&
        sharedRect.width > 0 && sharedRect.height > 0;
    NSRect rect = visible ? MCCanvasNativeRect(sharedRect) : NSZeroRect;
    self.videoSurface.hidden = !visible;
    if (!visible) return;
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    self.videoSurface.frame = rect;
    self.videoLayer.frame = self.videoSurface.bounds;
    [CATransaction commit];
}
- (void)layout {
    [super layout];
    [self updateVideoSurface];
    [self updateTooltips];
    CGSize size = self.bounds.size;
    if (self.onFrameNeeded && size.width > 0 && size.height > 0 &&
        (!self.deliveredSize || !CGSizeEqualToSize(size, self.lastDeliveredSize))) {
        self.deliveredSize = YES; self.lastDeliveredSize = size;
        void (^callback)(CGSize) = self.onFrameNeeded;
        callback(size);
    }
}
- (void)drawRect:(NSRect)dirtyRect {
    [self drawLayer:MC_UI_LAYER_COMMANDS dirtyRect:dirtyRect];
}
- (void)setImageAssets:(NSDictionary<NSString *, NSImage *> *)imageAssets {
    _imageAssets = [imageAssets copy];
    self.needsDisplay = YES;
    self.overlaySurface.needsDisplay = YES;
}
- (void)drawLayer:(int32_t)layer dirtyRect:(NSRect)dirtyRect {
    [NSGraphicsContext saveGraphicsState]; NSRectClip(NSIntersectionRect(dirtyRect,self.bounds));
    const MCCanvasPainter painter = {(__bridge void *)self,MCCanvasPaintRect,MCCanvasPaintLine,
        MCCanvasPaintText,MCCanvasPaintAsset};
    mc_canvas_draw_layer(self.frameHandle,layer,&painter);
    [NSGraphicsContext restoreGraphicsState];
}
- (NSCursor *)frameCursor {
    switch (ui_frame_value(self.frameHandle,MC_UI_FRAME_CURSOR)) {
        case MC_UI_CURSOR_RESIZE_HORIZONTAL: return NSCursor.resizeLeftRightCursor;
        case MC_UI_CURSOR_POINTER: return NSCursor.pointingHandCursor;
        case MC_UI_CURSOR_CROSSHAIR: return NSCursor.crosshairCursor;
        default: return NSCursor.arrowCursor;
    }
}
- (void)resetCursorRects {
    [super resetCursorRects]; [self addCursorRect:self.bounds cursor:[self frameCursor]];
}
- (void)updateTrackingAreas {
    if (self.pointerTracking) [self removeTrackingArea:self.pointerTracking];
    self.pointerTracking = [[NSTrackingArea alloc] initWithRect:NSZeroRect
        options:NSTrackingMouseMoved | NSTrackingMouseEnteredAndExited | NSTrackingCursorUpdate |
            NSTrackingActiveInKeyWindow | NSTrackingInVisibleRect | NSTrackingEnabledDuringMouseDrag
        owner:self userInfo:nil];
    [self addTrackingArea:self.pointerTracking]; [super updateTrackingAreas];
}
- (void)cursorUpdate:(NSEvent *)event { (void)event; [[self frameCursor] set]; }
- (void)emitEvent:(NSDictionary *)event {
    void (^callback)(NSDictionary *) = self.onEvent;
    if (!callback) return;
    NSArray *types=@[@"pointerDown",@"pointerMove",@"pointerUp",@"cancel",@"scroll",@"key",@"activate",@"appearance"];
    NSUInteger index=[types indexOfObject:event[@"type"]];
    if (index==NSNotFound) return;
    NSString *text=event[index==5 ? @"key" : index==6 ? @"id" : @"mode"] ?: @"";
    if (![text isKindOfClass:NSString.class] || text.length>256) return;
    uint16_t characters[256];
    [text getCharacters:characters range:NSMakeRange(0,text.length)];
    MCCanvasInput input={(int32_t)index+1,[event[@"x"] doubleValue],[event[@"y"] doubleValue],
        [event[@"deltaX"] doubleValue],[event[@"deltaY"] doubleValue],
        ([event[@"mod"] boolValue] ? MC_UI_INPUT_MOD : 0) |
        ([event[@"shift"] boolValue] ? MC_UI_INPUT_SHIFT : 0) |
        ([event[@"precise"] boolValue] ? MC_UI_INPUT_PRECISE : 0),characters,text.length};
    NSString *json=MCCanvasOwnedString(mc_canvas_input_json(&input));
    if (!json.length) return;
    NSDictionary *encoded=[NSJSONSerialization JSONObjectWithData:[json dataUsingEncoding:NSUTF8StringEncoding] options:0 error:NULL];
    if (encoded) callback(encoded);
}
- (void)sendPointer:(NSString *)type event:(NSEvent *)event {
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    [self emitEvent:@{ @"type":type, @"x":@(point.x), @"y":@(point.y) }];
}
- (void)mouseEntered:(NSEvent *)event { self.pointerInside = YES; [self sendPointer:@"pointerMove" event:event]; }
- (void)mouseExited:(NSEvent *)event { self.pointerInside = NO; [self sendPointer:@"pointerMove" event:event]; }
- (void)mouseMoved:(NSEvent *)event {
    // A missing mouse-up (for example a system interruption) must not leave a
    // drag armed when regular hover events resume.
    if (self.pointerDown && !(NSEvent.pressedMouseButtons & 1)) [self cancelInput];
    [self sendPointer:@"pointerMove" event:event];
}
- (void)mouseDown:(NSEvent *)event {
    [self focusForPress];
    self.inputActive = YES; self.pointerDown = YES;
    [self sendPointer:@"pointerDown" event:event];
}
- (void)focusForPress {
    if (!self.preserveFocusOnPress || !self.preserveFocusOnPress()) [self.window makeFirstResponder:self];
}
- (void)mouseDragged:(NSEvent *)event {
    if (self.pointerDown) [self sendPointer:@"pointerMove" event:event];
}
- (void)mouseUp:(NSEvent *)event {
    if (!self.pointerDown) return;
    self.pointerDown = NO; [self sendPointer:@"pointerUp" event:event];
}
- (void)scrollWheel:(NSEvent *)event {
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    // Forward device input only. The shared component decides whether this
    // point pans, zooms or leaves the current view unchanged.
    [self emitEvent:@{@"type":@"scroll", @"x":@(point.x), @"y":@(point.y),
        @"deltaX":@(event.scrollingDeltaX), @"deltaY":@(event.scrollingDeltaY),
        @"precise":event.hasPreciseScrollingDeltas ? @YES : @NO,
        @"shift":(event.modifierFlags & NSEventModifierFlagShift) ? @YES : @NO,
        @"mod":(event.modifierFlags & NSEventModifierFlagCommand) ? @YES : @NO}];
}
- (NSDictionary *)keyEvent:(NSEvent *)event {
    // This canvas is not a text client. Leave Option/Control composition and
    // every unrecognized text key to the responder/input-method machinery.
    if (self.window.firstResponder != self ||
        (event.modifierFlags & (NSEventModifierFlagOption | NSEventModifierFlagControl))) return nil;
    NSString *key = nil;
    switch (event.keyCode) {
        case 49: key = @"Space"; break;
        case 53: key = @"Escape"; break;
        case 123: key = @"ArrowLeft"; break;
        case 124: key = @"ArrowRight"; break;
        case 125: key = @"ArrowDown"; break;
        case 126: key = @"ArrowUp"; break;
        case 48: key = @"Tab"; break;
        case 36: case 76: key = @"Enter"; break;
        case 115: key = @"Home"; break;
        case 119: key = @"End"; break;
        case 51: key = @"Backspace"; break;
        case 117: key = @"Delete"; break;
        default: break;
    }
    BOOL mod = (event.modifierFlags & NSEventModifierFlagCommand) != 0;
    NSString *character = event.charactersIgnoringModifiers.lowercaseString;
    if (mod && [@[@"z", @"+", @"=", @"-", @"0"] containsObject:character]) key = character;
    if (!key) return nil;
    return @{ @"type":@"key", @"key":key, @"mod":mod ? @YES : @NO,
        @"shift":(event.modifierFlags & NSEventModifierFlagShift) ? @YES : @NO };
}
- (void)keyDown:(NSEvent *)event {
    NSDictionary *input = [self keyEvent:event];
    if (!input) { [super keyDown:event]; return; }
    self.inputActive = YES;
    if ([input[@"key"] isEqual:@"Escape"]) self.pointerDown = NO;
    [self emitEvent:input];
}
- (BOOL)performKeyEquivalent:(NSEvent *)event {
    NSDictionary *input = [self keyEvent:event];
    if ([input[@"mod"] boolValue] && [@[@"z", @"+", @"=", @"-", @"0"] containsObject:input[@"key"]]) {
        self.inputActive = YES; [self emitEvent:input]; return YES;
    }
    return [super performKeyEquivalent:event];
}
- (void)cancelOperation:(id)sender { (void)sender; [self cancelInput]; }
- (void)cancelInput {
    BOOL hadInput = self.inputActive || self.pointerDown;
    self.inputActive = NO; self.pointerDown = NO; self.pointerInside = NO;
    if (hadInput) [self emitEvent:@{ @"type":@"cancel" }];
}
- (void)hostBecameInactive:(NSNotification *)notification { (void)notification; [self cancelInput]; }
- (void)hostBecameKey:(NSNotification *)notification {
    (void)notification; if (self.window.firstResponder == self) self.inputActive = YES;
}
- (void)viewWillMoveToWindow:(NSWindow *)newWindow {
    if (newWindow != self.window) {
        [self cancelInput]; [[NSNotificationCenter defaultCenter] removeObserver:self];
    }
    [super viewWillMoveToWindow:newWindow];
}
- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    if (self.window) {
        NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
        [center addObserver:self selector:@selector(hostBecameInactive:) name:NSWindowDidResignKeyNotification object:self.window];
        [center addObserver:self selector:@selector(hostBecameInactive:) name:NSWindowWillCloseNotification object:self.window];
        [center addObserver:self selector:@selector(hostBecameInactive:) name:NSApplicationDidResignActiveNotification object:NSApp];
        [center addObserver:self selector:@selector(hostBecameKey:) name:NSWindowDidBecomeKeyNotification object:self.window];
    }
    self.needsLayout = YES;
}
- (void)viewDidHide { [super viewDidHide]; [self cancelInput]; }
- (BOOL)isAccessibilityElement { return YES; }
- (NSAccessibilityRole)accessibilityRole { return NSAccessibilityGroupRole; }
- (NSArray *)accessibilityChildren {
    NSMutableArray *children = [self.semanticElements mutableCopy] ?: [NSMutableArray array];
    // System input surfaces supply real editing accessibility. Frame producers
    // omit virtual nodes for those fields; media/overlay surfaces opt out.
    for (NSView *view in self.subviews) {
        if (!view.hiddenOrHasHiddenAncestor && view.isAccessibilityElement && ![children containsObject:view])
            [children addObject:view];
    }
    return children;
}
- (void)updateSemantics {
    NSMutableArray<NSDictionary *> *descriptors = [NSMutableArray array];
    for (int32_t index=0; index<ui_frame_semantic_count(self.frameHandle); index++) {
        const char *roles[] = {"group","button","slider","checkbox","text"};
        int32_t role=ui_frame_semantic_value(self.frameHandle,index,MC_UI_SEM_ROLE);
        if (role<MC_UI_ROLE_GROUP || role>MC_UI_ROLE_TEXT) continue;
        NSMutableDictionary *item = [@{@"role":@(roles[role]),
            @"id":MCCanvasOwnedString(ui_frame_semantic_text(self.frameHandle,index,MC_UI_SEM_ID)),
            @"label":MCCanvasOwnedString(ui_frame_semantic_text(self.frameHandle,index,MC_UI_SEM_LABEL)),
            @"tooltip":MCCanvasOwnedString(ui_frame_semantic_text(self.frameHandle,index,MC_UI_SEM_TOOLTIP)),
            @"enabled":@(ui_frame_semantic_value(self.frameHandle,index,MC_UI_SEM_ENABLED)==1),
            @"focused":@(ui_frame_semantic_value(self.frameHandle,index,MC_UI_SEM_FOCUSED)==1),
            @"x":@(ui_frame_semantic_number(self.frameHandle,index,MC_UI_SEM_X)),
            @"y":@(ui_frame_semantic_number(self.frameHandle,index,MC_UI_SEM_Y)),
            @"width":@(ui_frame_semantic_number(self.frameHandle,index,MC_UI_SEM_WIDTH)),
            @"height":@(ui_frame_semantic_number(self.frameHandle,index,MC_UI_SEM_HEIGHT))} mutableCopy];
        int32_t type=ui_frame_semantic_value(self.frameHandle,index,MC_UI_SEM_VALUE_TYPE);
        if (type==MC_UI_VALUE_NUMBER) item[@"value"]=@(ui_frame_semantic_number(self.frameHandle,index,MC_UI_SEM_VALUE));
        else if (type==MC_UI_VALUE_BOOL) item[@"value"]=@(ui_frame_semantic_number(self.frameHandle,index,MC_UI_SEM_VALUE)!=0);
        else if (type==MC_UI_VALUE_TEXT) item[@"value"]=MCCanvasOwnedString(ui_frame_semantic_text(self.frameHandle,index,MC_UI_SEM_VALUE_TEXT));
        if (ui_frame_semantic_value(self.frameHandle,index,MC_UI_SEM_HAS_MIN)==1) item[@"min"]=@(ui_frame_semantic_number(self.frameHandle,index,MC_UI_SEM_MIN));
        if (ui_frame_semantic_value(self.frameHandle,index,MC_UI_SEM_HAS_MAX)==1) item[@"max"]=@(ui_frame_semantic_number(self.frameHandle,index,MC_UI_SEM_MAX));
        if (ui_frame_semantic_value(self.frameHandle,index,MC_UI_SEM_HAS_STEP)==1) item[@"step"]=@(ui_frame_semantic_number(self.frameHandle,index,MC_UI_SEM_STEP));
        [descriptors addObject:item];
    }
    NSMutableDictionary<NSString *, MCCanvasAccessibilityElement *> *previous = [NSMutableDictionary dictionary];
    for (MCCanvasAccessibilityElement *element in self.semanticElements) previous[element.accessibilityIdentifier] = element;
    NSMutableArray<MCCanvasAccessibilityElement *> *elements = [NSMutableArray array];
    NSMutableSet<NSString *> *identifiers = [NSMutableSet set];
    BOOL changedLayout = NO;
    for (id entry in descriptors) {
        if (![entry isKindOfClass:NSDictionary.class]) continue;
        NSString *identifier = MCCanvasString(entry[@"id"]); NSRect rect;
        if (!identifier.length || [identifiers containsObject:identifier] || !MCCanvasDecodeRect(entry, &rect)) continue;
        [identifiers addObject:identifier];
        MCCanvasAccessibilityElement *element = previous[identifier];
        NSDictionary *old = element.descriptor;
        if (!element) { element = [MCCanvasAccessibilityElement new]; element.canvas = self; changedLayout = YES; }
        element.descriptor = entry;
        [elements addObject:element];
        for (NSString *key in @[@"role", @"label", @"x", @"y", @"width", @"height"]) {
            if (old && !((old[key] == entry[key]) || [old[key] isEqual:entry[key]])) changedLayout = YES;
        }
        if (self.window && old && !((old[@"value"] == entry[@"value"]) || [old[@"value"] isEqual:entry[@"value"]]))
            NSAccessibilityPostNotification(element, NSAccessibilityValueChangedNotification);
        if (self.window && [entry[@"focused"] isEqual:@YES] && ![old[@"focused"] isEqual:@YES])
            NSAccessibilityPostNotification(element, NSAccessibilityFocusedUIElementChangedNotification);
    }
    if (![self.semanticElements isEqualToArray:elements]) changedLayout = YES;
    // Accessibility clients may retain objects beyond the frame that exposed
    // them. Retired nodes must not send actions into the current shared UI.
    for (NSString *identifier in previous) {
        if (![identifiers containsObject:identifier]) previous[identifier].canvas = nil;
    }
    self.semanticElements = elements;
    if (self.window && changedLayout) NSAccessibilityPostNotification(self, NSAccessibilityLayoutChangedNotification);
}
- (void)updateTooltips {
    NSMutableArray<NSDictionary *> *regions = [NSMutableArray array];
    for (MCCanvasAccessibilityElement *element in self.semanticElements) {
        NSDictionary *descriptor = element.descriptor;
        NSString *label = MCCanvasString(descriptor[@"tooltip"]) ?: MCCanvasString(descriptor[@"label"]);
        NSRect rect;
        if (!label.length || !MCCanvasDecodeRect(descriptor, &rect)) continue;
        rect = NSIntersectionRect(rect, self.bounds);
        if (NSIsEmptyRect(rect)) continue;
        // Keep disabled controls discoverable too. The shared component owns
        // their names/reasons; the adapter never infers text from an action ID.
        [regions addObject:@{@"rect":[NSValue valueWithRect:rect], @"label":label}];
    }
    // The playback clock redraws frequently. Reinstalling identical regions
    // would continually restart AppKit's tooltip delay.
    if ([self.tooltipRegions isEqualToArray:regions]) return;
    [self removeAllToolTips];
    self.tooltipRegions = regions;
    for (NSDictionary *region in regions)
        [self addToolTipRect:[region[@"rect"] rectValue] owner:self userData:NULL];
}
- (NSString *)view:(NSView *)view stringForToolTip:(NSToolTipTag)tag point:(NSPoint)point userData:(void *)data {
    (void)tag; (void)data;
    if (view != self || self.pointerDown) return @"";
    // Semantic order follows painting order, so an open menu takes priority
    // over the timeline or buttons underneath it.
    for (NSDictionary *region in self.tooltipRegions.reverseObjectEnumerator)
        if (NSPointInRect(point, [region[@"rect"] rectValue])) return region[@"label"];
    return @"";
}
- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    _videoLayer.player = nil;
    if (_frameHandle) ui_frame_close(_frameHandle);
}
@end
