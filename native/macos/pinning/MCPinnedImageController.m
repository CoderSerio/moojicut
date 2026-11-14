#import "MCPinnedImageController.h"
#import "../MCChromeTheme.h"
#import "preferences/MCPinShortcutStore.h"
#include <math.h>

@class MCPinnedImage;
@interface MCPinnedPanel : NSPanel
@end
@implementation MCPinnedPanel
- (BOOL)canBecomeKeyWindow { return YES; }
- (BOOL)canBecomeMainWindow { return NO; }
@end

@interface MCPinnedImageView : NSView
@property (weak) MCPinnedImage *pin;
@property BOOL dragging;
@property NSPoint dragOrigin;
@property NSPoint dragMouse;
@end

@interface MCPinnedImageController ()
@property NSMutableArray<MCPinnedImage *> *pins;
@property MCPinShortcutStore *shortcuts;
@property (nonatomic) BOOL captureHidden;
- (nullable MCPinnedImage *)createPinPNGData:(NSData *)data display:(BOOL)display error:(NSError **)error;
- (void)selectPin:(nullable MCPinnedImage *)pin focus:(BOOL)focus;
- (void)removePin:(MCPinnedImage *)pin;
@end

@interface MCPinnedImage : NSObject <NSWindowDelegate>
@property (weak) MCPinnedImageController *owner;
@property MCPinnedPanel *panel;
@property MCPinnedImageView *view;
@property NSImage *image;
@property NSData *png;
@property NSSize sourceSize;
@property CGFloat scale;
@property (nonatomic) CGFloat opacity;
@property (nonatomic) BOOL selected;
@property BOOL restoreVisible;
@property BOOL pendingSelection;
- (void)applyAction:(NSString *)action;
- (void)updateTooltip;
- (void)reset:(nullable id)sender;
- (void)close:(nullable id)sender;
- (void)copyImage:(nullable id)sender;
- (BOOL)copyToPasteboard:(NSPasteboard *)pasteboard;
- (BOOL)handleKeyEvent:(NSEvent *)event;
- (void)zoomBy:(CGFloat)factor;
- (void)constrainPosition;
@end

static NSScreen *MCPinScreenForRect(NSRect rect) {
    NSScreen *best = NSScreen.mainScreen ?: NSScreen.screens.firstObject;
    CGFloat bestArea = -1;
    for (NSScreen *screen in NSScreen.screens) {
        NSRect overlap = NSIntersectionRect(rect, screen.visibleFrame);
        CGFloat area = overlap.size.width * overlap.size.height;
        if (area > bestArea) { bestArea = area; best = screen; }
    }
    return best;
}
static NSRect MCPinVisibleFrame(NSRect rect) {
    NSScreen *screen = MCPinScreenForRect(rect);
    return screen ? screen.visibleFrame : NSMakeRect(0, 0, 1280, 800);
}
static NSRect MCPinConstrainFrame(NSRect frame, NSRect screen) {
    // AppKit aligns window edges to backing pixels. Start on integral points so
    // a half-point centered origin does not enlarge the image by a whole row.
    frame.origin.x = floor(MAX(NSMinX(screen), MIN(NSMaxX(screen) - frame.size.width, frame.origin.x)));
    frame.origin.y = floor(MAX(NSMinY(screen), MIN(NSMaxY(screen) - frame.size.height, frame.origin.y)));
    return frame;
}

@implementation MCPinnedImageView
- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)acceptsFirstMouse:(NSEvent *)event { (void)event; return YES; }
- (BOOL)needsPanelToBecomeKey { return YES; }
- (void)resetCursorRects {
    [super resetCursorRects];
    [self addCursorRect:self.bounds cursor:NSCursor.openHandCursor];
}
- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    [self.pin.image drawInRect:self.bounds fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1];
    if (self.pin.selected) {
        NSBezierPath *outline = [NSBezierPath bezierPathWithRect:NSInsetRect(self.bounds, 2, 2)];
        [MCSelectionContrastColor() setStroke]; outline.lineWidth = 4; [outline stroke];
        [MCSelectionColor() setStroke]; outline.lineWidth = 2; [outline stroke];
    }
}
- (void)mouseDown:(NSEvent *)event {
    [self.pin.owner selectPin:self.pin focus:YES];
    self.dragging = YES;
    self.dragOrigin = self.window.frame.origin;
    self.dragMouse = [self.window convertPointToScreen:event.locationInWindow];
}
- (void)mouseDragged:(NSEvent *)event {
    if (!self.dragging) return;
    NSPoint point = [self.window convertPointToScreen:event.locationInWindow];
    [self.window setFrameOrigin:NSMakePoint(self.dragOrigin.x + point.x - self.dragMouse.x,
                                           self.dragOrigin.y + point.y - self.dragMouse.y)];
}
- (void)mouseUp:(NSEvent *)event {
    (void)event;
    self.dragging = NO;
    [self.pin constrainPosition];
}
- (void)keyDown:(NSEvent *)event {
    if (![self.pin handleKeyEvent:event]) [super keyDown:event];
}
- (BOOL)performKeyEquivalent:(NSEvent *)event {
    return [self.pin handleKeyEvent:event] || [super performKeyEquivalent:event];
}
- (NSMenu *)menuForEvent:(NSEvent *)event {
    (void)event;
    [self.pin.owner selectPin:self.pin focus:YES];
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"贴图"];
    for (NSDictionary *item in @[
        @{@"title":@"复制图片", @"action":NSStringFromSelector(@selector(copyImage:))},
        @{@"title":@"恢复尺寸与不透明度", @"action":NSStringFromSelector(@selector(reset:))},
        @{@"title":@"关闭这张贴图", @"action":NSStringFromSelector(@selector(close:))}
    ]) {
        NSMenuItem *entry = [[NSMenuItem alloc] initWithTitle:item[@"title"] action:NSSelectorFromString(item[@"action"]) keyEquivalent:@""];
        entry.target = self.pin;
        [menu addItem:entry];
    }
    return menu;
}
@end

@implementation MCPinnedImage
- (void)updateTooltip {
    MCPinShortcutStore *store = self.owner.shortcuts;
    NSString *(^label)(NSString *) = ^NSString *(NSString *action) {
        return [MCPinShortcutStore displayStringForShortcut:[store shortcutForAction:action]];
    };
    self.view.toolTip = [NSString stringWithFormat:
        @"拖动移动 · 单击选中\n%@ / %@ 缩放 · %@ / %@ 调整不透明度\n右键：复制、复位、关闭 · Esc 取消选中\n缩放 %.0f%% · 不透明度 %.0f%%",
        label(@"zoomIn"), label(@"zoomOut"), label(@"opacityUp"), label(@"opacityDown"), self.scale * 100, self.opacity * 100];
    self.view.accessibilityLabel = [NSString stringWithFormat:@"贴图，缩放 %.0f%%，不透明度 %.0f%%", self.scale * 100, self.opacity * 100];
}
- (void)setSelected:(BOOL)selected {
    _selected = selected;
    self.view.needsDisplay = YES;
}
- (void)setOpacity:(CGFloat)opacity {
    _opacity = MAX(0.1, MIN(1, opacity));
    self.panel.alphaValue = _opacity;
    [self updateTooltip];
}
- (void)setScaleAroundCenter:(CGFloat)scale {
    NSRect old = self.panel.frame, screen = MCPinVisibleFrame(old);
    // Keep the complete image reachable even after a move to a smaller screen.
    CGFloat maximum = MIN(8, MIN(screen.size.width * 0.95 / self.sourceSize.width,
                                 screen.size.height * 0.95 / self.sourceSize.height));
    CGFloat minimum = MIN(0.1, maximum);
    _scale = MAX(minimum, MIN(maximum, scale));
    NSSize size = NSMakeSize(self.sourceSize.width * _scale, self.sourceSize.height * _scale);
    NSRect frame = NSMakeRect(NSMidX(old) - size.width / 2, NSMidY(old) - size.height / 2, size.width, size.height);
    [self.panel setFrame:MCPinConstrainFrame(frame, screen) display:YES];
    [self updateTooltip];
}
- (void)zoomBy:(CGFloat)factor { [self setScaleAroundCenter:self.scale * factor]; }
- (void)constrainPosition {
    [self setScaleAroundCenter:self.scale];
}
- (void)applyAction:(NSString *)action {
    if ([action isEqual:@"zoomIn"]) [self zoomBy:1.1];
    else if ([action isEqual:@"zoomOut"]) [self zoomBy:1 / 1.1];
    else if ([action isEqual:@"opacityUp"]) self.opacity += 0.1;
    else if ([action isEqual:@"opacityDown"]) self.opacity -= 0.1;
}
- (BOOL)handleKeyEvent:(NSEvent *)event {
    if (!self.selected || self.owner.captureHidden || event.type != NSEventTypeKeyDown) return NO;
    NSString *action = [self.owner.shortcuts actionForEvent:event];
    if (action) { [self applyAction:action]; return YES; }
    NSEventModifierFlags flags = event.modifierFlags & (NSEventModifierFlagCommand | NSEventModifierFlagControl |
        NSEventModifierFlagOption | NSEventModifierFlagShift);
    if (event.keyCode == 53 && flags == 0) {
        [self.owner selectPin:nil focus:NO];
        [self.panel resignKeyWindow];
        return YES;
    }
    if ((event.keyCode == 51 || event.keyCode == 117) && flags == 0) { [self close:nil]; return YES; }
    return NO;
}
- (void)reset:(id)sender {
    (void)sender;
    self.opacity = 1;
    [self setScaleAroundCenter:1];
}
- (BOOL)copyToPasteboard:(NSPasteboard *)pasteboard {
    NSPasteboardItem *item = [NSPasteboardItem new];
    [item setData:self.png forType:NSPasteboardTypePNG];
    NSData *tiff = self.image.TIFFRepresentation;
    if (tiff) [item setData:tiff forType:NSPasteboardTypeTIFF];
    [pasteboard clearContents];
    return [pasteboard writeObjects:@[item]];
}
- (void)copyImage:(id)sender {
    (void)sender;
    if (![self copyToPasteboard:NSPasteboard.generalPasteboard]) NSBeep();
}
- (void)close:(id)sender { (void)sender; [self.panel close]; }
- (void)windowDidBecomeKey:(NSNotification *)notification {
    (void)notification;
    [self.owner selectPin:self focus:NO];
}
- (void)windowDidResignKey:(NSNotification *)notification { (void)notification; self.selected = NO; }
- (void)windowWillClose:(NSNotification *)notification {
    (void)notification;
    MCPinnedImageController *owner = self.owner;
    self.panel.delegate = nil;
    self.panel.contentView = nil;
    self.view.pin = nil;
    [owner removePin:self];
}
@end

@implementation MCPinnedImageController
- (instancetype)initWithDefaults:(NSUserDefaults *)defaults {
    if ((self = [super init])) {
        _pins = [NSMutableArray array];
        _shortcuts = [[MCPinShortcutStore alloc] initWithDefaults:defaults];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(shortcutsChanged:)
            name:MCPinShortcutsDidChangeNotification object:defaults];
    }
    return self;
}
- (void)shortcutsChanged:(NSNotification *)notification {
    (void)notification;
    for (MCPinnedImage *pin in self.pins) [pin updateTooltip];
}
- (NSUInteger)count { return self.pins.count; }
- (void)selectPin:(MCPinnedImage *)pin focus:(BOOL)focus {
    if (self.captureHidden) pin = nil;
    for (MCPinnedImage *candidate in self.pins) candidate.selected = candidate == pin;
    if (focus && pin && !self.captureHidden) {
        [pin.panel makeKeyWindow];
        [pin.panel makeFirstResponder:pin.view];
    }
}
- (MCPinnedImage *)createPinPNGData:(NSData *)data display:(BOOL)display error:(NSError **)error {
    NSAssert(NSThread.isMainThread, @"Pinned images are main-thread objects");
    NSBitmapImageRep *bitmap = [NSBitmapImageRep imageRepWithData:data];
    if (!bitmap || bitmap.pixelsWide < 1 || bitmap.pixelsHigh < 1 ||
        bitmap.pixelsWide > 32768 || bitmap.pixelsHigh > 32768 || bitmap.pixelsWide * bitmap.pixelsHigh > 80000000) {
        if (error) *error = [NSError errorWithDomain:@"dev.moojicut.pinning" code:1
            userInfo:@{NSLocalizedDescriptionKey:@"无法贴图：图片无法读取，或尺寸过大。"}];
        return nil;
    }
    MCPinnedImage *pin = [MCPinnedImage new];
    pin.owner = self;
    pin.png = [data copy];
    pin.image = [[NSImage alloc] initWithSize:NSMakeSize(bitmap.pixelsWide, bitmap.pixelsHigh)];
    [pin.image addRepresentation:bitmap];
    NSScreen *screen = NSScreen.mainScreen ?: NSScreen.screens.firstObject;
    CGFloat backing = screen ? MAX(1, screen.backingScaleFactor) : 1;
    pin.sourceSize = NSMakeSize(bitmap.pixelsWide / backing, bitmap.pixelsHigh / backing);
    NSRect visible = screen ? screen.visibleFrame : NSMakeRect(0, 0, 1280, 800);
    CGFloat initial = MIN(1, MIN(visible.size.width * 0.75 / pin.sourceSize.width, visible.size.height * 0.75 / pin.sourceSize.height));
    CGFloat width = pin.sourceSize.width * initial, height = pin.sourceSize.height * initial;
    CGFloat offset = (self.pins.count % 8) * 20;
    NSRect frame = MCPinConstrainFrame(NSMakeRect(NSMidX(visible) - width / 2 + offset,
        NSMidY(visible) - height / 2 - offset, width, height), visible);
    pin.panel = [[MCPinnedPanel alloc] initWithContentRect:frame
        styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
        backing:NSBackingStoreBuffered defer:NO];
    pin.panel.releasedWhenClosed = NO;
    pin.panel.delegate = pin;
    pin.panel.level = NSFloatingWindowLevel;
    pin.panel.hidesOnDeactivate = NO;
    pin.panel.becomesKeyOnlyIfNeeded = NO;
    pin.panel.opaque = NO;
    pin.panel.backgroundColor = NSColor.clearColor;
    pin.panel.hasShadow = YES;
    pin.panel.title = @"Mooji Cut · 贴图";
    pin.panel.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorFullScreenAuxiliary;
    pin.view = [[MCPinnedImageView alloc] initWithFrame:NSMakeRect(0, 0, width, height)];
    pin.view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    pin.view.pin = pin;
    pin.panel.contentView = pin.view;
    pin.scale = initial;
    pin.opacity = 1;
    [self.pins addObject:pin];
    if (display) {
        pin.restoreVisible = YES;
        pin.pendingSelection = self.captureHidden;
        if (!self.captureHidden) {
            [pin.panel orderFront:nil];
            [self selectPin:pin focus:YES];
        }
    }
    return pin;
}
- (BOOL)pinPNGData:(NSData *)data error:(NSError **)error { return [self createPinPNGData:data display:YES error:error] != nil; }
- (void)removePin:(MCPinnedImage *)pin {
    pin.owner = nil;
    [self.pins removeObjectIdenticalTo:pin];
}
- (void)setCaptureHidden:(BOOL)hidden {
    if (self.captureHidden == hidden) return;
    _captureHidden = hidden;
    MCPinnedImage *newest = nil;
    for (MCPinnedImage *pin in self.pins) {
        if (hidden) {
            pin.restoreVisible = pin.panel.visible;
            pin.selected = NO;
            [pin.panel orderOut:nil];
        } else if (pin.restoreVisible) {
            // Do not steal focus back from the editor, settings, or another app.
            [pin.panel orderFront:nil];
            if (pin.pendingSelection) newest = pin;
            pin.pendingSelection = NO;
        }
    }
    // A newly confirmed "pin" is an explicit action. Give just that new panel
    // keyboard focus; old pins merely reappear without app activation.
    if (newest) [self selectPin:newest focus:YES];
}
- (void)closeAll {
    for (MCPinnedImage *pin in [self.pins copy]) [pin close:nil];
}
- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
    for (MCPinnedImage *pin in self.pins) {
        pin.panel.delegate = nil;
        [pin.panel orderOut:nil];
        pin.panel.contentView = nil;
    }
}
@end
