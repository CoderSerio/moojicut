#import "MCSharedCanvas.h"
#import <QuartzCore/QuartzCore.h>
#include <math.h>

static BOOL MCCanvasNumber(id value, CGFloat *result) {
    if (![value isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()) return NO;
    double number = [value doubleValue];
    if (!isfinite(number)) return NO;
    *result = number; return YES;
}
static BOOL MCCanvasRect(NSDictionary *value, NSRect *result) {
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
static NSColor *MCCanvasColor(id value) {
    NSString *text = MCCanvasString(value);
    if (text.length != 7 || [text characterAtIndex:0] != '#') return nil;
    unsigned rgb = 0;
    for (NSUInteger i = 1; i < 7; i++) {
        unichar c = [text characterAtIndex:i];
        unsigned digit;
        if (c >= '0' && c <= '9') digit = c - '0';
        else if (c >= 'a' && c <= 'f') digit = c - 'a' + 10;
        else if (c >= 'A' && c <= 'F') digit = c - 'A' + 10;
        else return nil;
        rgb = (rgb << 4) | digit;
    }
    return [NSColor colorWithSRGBRed:((rgb >> 16) & 255) / 255.0
        green:((rgb >> 8) & 255) / 255.0 blue:(rgb & 255) / 255.0 alpha:1];
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
@property CGSize lastDeliveredSize;
- (void)emitEvent:(NSDictionary *)event;
- (void)cancelInput;
- (void)updateVideoSurface;
- (void)updateSemantics;
- (void)updateTooltips;
- (void)drawCommands:(NSArray *)commands dirtyRect:(NSRect)dirtyRect;
@end

@implementation MCCanvasOverlaySurface
- (BOOL)isFlipped { return YES; }
- (void)drawRect:(NSRect)dirtyRect {
    [self.canvas drawCommands:self.canvas.frameDescription[@"overlayCommands"] dirtyRect:dirtyRect];
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
    if (!canvas.window || !MCCanvasRect(self.descriptor, &rect)) return NSZeroRect;
    return [canvas.window convertRectToScreen:[canvas convertRect:rect toView:nil]];
}
- (BOOL)accessibilityPerformPress {
    NSString *identifier = self.accessibilityIdentifier;
    NSAccessibilityRole role = self.accessibilityRole;
    if ((![role isEqualToString:NSAccessibilityButtonRole] && ![role isEqualToString:NSAccessibilitySliderRole] &&
         ![role isEqualToString:NSAccessibilityCheckBoxRole]) ||
        !self.isAccessibilityEnabled || !identifier.length || !self.canvas.onEvent) return NO;
    [self.canvas.window makeFirstResponder:self.canvas];
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
- (void)setFrameDescription:(NSDictionary *)frameDescription {
    _frameDescription = [frameDescription isKindOfClass:NSDictionary.class] ? [frameDescription copy] : nil;
    [self updateVideoSurface];
    [self updateSemantics];
    [self updateTooltips];
    self.needsDisplay = YES;
    self.overlaySurface.needsDisplay = YES;
    [self.window invalidateCursorRectsForView:self];
    if (self.pointerInside && self.window.isKeyWindow) [[self frameCursor] set];
}
- (void)setVideoPlayer:(AVPlayer *)player {
    self.videoLayer.player = player;
    [self updateVideoSurface];
}
- (void)updateVideoSurface {
    NSRect rect;
    BOOL visible = self.videoLayer.player && MCCanvasRect(self.frameDescription[@"videoRect"], &rect) &&
        rect.size.width > 0 && rect.size.height > 0;
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
    [self drawCommands:self.frameDescription[@"commands"] dirtyRect:dirtyRect];
}
- (void)drawCommands:(NSArray *)commands dirtyRect:(NSRect)dirtyRect {
    [NSGraphicsContext saveGraphicsState];
    NSRectClip(NSIntersectionRect(dirtyRect, self.bounds));
    if (![commands isKindOfClass:NSArray.class]) commands = @[];
    for (id entry in commands) {
        if (![entry isKindOfClass:NSDictionary.class]) continue;
        NSDictionary *command = entry;
        NSString *type = MCCanvasString(command[@"type"]);
        if ([type isEqualToString:@"rect"]) {
            NSRect rect; CGFloat radius = 0, lineWidth = 1;
            if (!MCCanvasRect(command, &rect)) continue;
            if (command[@"radius"] && (!MCCanvasNumber(command[@"radius"], &radius) || radius < 0)) continue;
            if (command[@"lineWidth"] && (!MCCanvasNumber(command[@"lineWidth"], &lineWidth) || lineWidth < 0)) continue;
            NSBezierPath *path = [NSBezierPath bezierPathWithRoundedRect:rect xRadius:radius yRadius:radius];
            NSColor *fill = MCCanvasColor(command[@"fill"]), *stroke = MCCanvasColor(command[@"stroke"]);
            if (fill) { [fill setFill]; [path fill]; }
            if (stroke) { [stroke setStroke]; path.lineWidth = lineWidth; [path stroke]; }
        } else if ([type isEqualToString:@"line"]) {
            CGFloat x1, y1, x2, y2, width = 1;
            NSColor *color = MCCanvasColor(command[@"color"]);
            if (!color || !MCCanvasNumber(command[@"x1"], &x1) || !MCCanvasNumber(command[@"y1"], &y1) ||
                !MCCanvasNumber(command[@"x2"], &x2) || !MCCanvasNumber(command[@"y2"], &y2) ||
                (command[@"lineWidth"] && !MCCanvasNumber(command[@"lineWidth"], &width)) || width < 0) continue;
            NSBezierPath *path = [NSBezierPath bezierPath];
            [path moveToPoint:NSMakePoint(x1, y1)]; [path lineToPoint:NSMakePoint(x2, y2)];
            [color setStroke]; path.lineWidth = width; [path stroke];
        } else if ([type isEqualToString:@"text"]) {
            NSRect rect; CGFloat size;
            NSString *text = MCCanvasString(command[@"text"]);
            NSColor *color = MCCanvasColor(command[@"color"]);
            if (!text || !color || !MCCanvasRect(command, &rect) || !MCCanvasNumber(command[@"size"], &size) || size <= 0) continue;
            NSString *weight = MCCanvasString(command[@"weight"]), *align = MCCanvasString(command[@"align"]);
            NSFontWeight fontWeight = [weight isEqualToString:@"bold"] ? NSFontWeightBold :
                [weight isEqualToString:@"medium"] ? NSFontWeightMedium : NSFontWeightRegular;
            NSMutableParagraphStyle *paragraph = [NSMutableParagraphStyle new];
            paragraph.alignment = [align isEqualToString:@"center"] ? NSTextAlignmentCenter :
                [align isEqualToString:@"right"] ? NSTextAlignmentRight : NSTextAlignmentLeft;
            paragraph.lineBreakMode = NSLineBreakByTruncatingTail;
            NSFont *font = [NSFont systemFontOfSize:size weight:fontWeight];
            NSDictionary *attributes = @{ NSFontAttributeName:font,
                NSForegroundColorAttributeName:color, NSParagraphStyleAttributeName:paragraph };
            NSRect textRect = rect;
            if ([MCCanvasString(command[@"valign"]) isEqualToString:@"center"]) {
                CGFloat height = [text boundingRectWithSize:NSMakeSize(rect.size.width, CGFLOAT_MAX)
                    options:NSStringDrawingUsesLineFragmentOrigin attributes:attributes].size.height;
                if (!isfinite(height) || height <= 0) height = font.ascender - font.descender + font.leading;
                height = ceil(height);
                textRect.origin.y += (rect.size.height - height) / 2;
                textRect.size.height = height;
            }
            [NSGraphicsContext saveGraphicsState]; NSRectClip(rect);
            [text drawWithRect:textRect options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingTruncatesLastVisibleLine
                attributes:attributes];
            [NSGraphicsContext restoreGraphicsState];
        }
    }
    [NSGraphicsContext restoreGraphicsState];
}
- (NSCursor *)frameCursor {
    NSString *cursor = MCCanvasString(self.frameDescription[@"cursor"]);
    if ([cursor isEqualToString:@"resize"] || [cursor isEqualToString:@"resize-horizontal"]) return NSCursor.resizeLeftRightCursor;
    if ([cursor isEqualToString:@"pointingHand"] || [cursor isEqualToString:@"pointer"]) return NSCursor.pointingHandCursor;
    if ([cursor isEqualToString:@"crosshair"]) return NSCursor.crosshairCursor;
    return NSCursor.arrowCursor;
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
    if (callback) callback(event);
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
    [self.window makeFirstResponder:self];
    self.inputActive = YES; self.pointerDown = YES;
    [self sendPointer:@"pointerDown" event:event];
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
- (NSArray *)accessibilityChildren { return self.semanticElements; }
- (void)updateSemantics {
    NSArray *descriptors = self.frameDescription[@"semantics"];
    if (![descriptors isKindOfClass:NSArray.class]) descriptors = @[];
    NSMutableDictionary<NSString *, MCCanvasAccessibilityElement *> *previous = [NSMutableDictionary dictionary];
    for (MCCanvasAccessibilityElement *element in self.semanticElements) previous[element.accessibilityIdentifier] = element;
    NSMutableArray<MCCanvasAccessibilityElement *> *elements = [NSMutableArray array];
    NSMutableSet<NSString *> *identifiers = [NSMutableSet set];
    BOOL changedLayout = NO;
    for (id entry in descriptors) {
        if (![entry isKindOfClass:NSDictionary.class]) continue;
        NSString *identifier = MCCanvasString(entry[@"id"]); NSRect rect;
        if (!identifier.length || [identifiers containsObject:identifier] || !MCCanvasRect(entry, &rect)) continue;
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
        if (!label.length || !MCCanvasRect(descriptor, &rect)) continue;
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
}
@end
