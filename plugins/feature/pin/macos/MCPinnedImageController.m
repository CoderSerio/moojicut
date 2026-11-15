#import "MCPinnedImageController.h"
#import "components/theme/macos/MCChromeTheme.h"
#import "native/macos/preferences/MCPinShortcutStore.h"
#include <math.h>
#import <Carbon/Carbon.h>
#import "native/macos/preferences/MCShortcutStore.h"
#import "native/macos/preferences/MCSystemShortcutCheck.h"
#include "native/shared/feature_runtime.h"

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

@interface MCPinnedImageController () {
    EventHotKeyRef _recoveryKeys[2];
}
@property NSMutableArray<MCPinnedImage *> *pins;
@property MCPinShortcutStore *shortcuts;
@property NSUserDefaults *defaults;
@property int32_t featureState;
@property BOOL observingShortcuts;
@property EventHandlerRef eventHandler;
@property (nonatomic) BOOL shortcutsSuspended;
@property (nonatomic, readwrite) NSString *shortcutRegistrationError;
- (BOOL)recoveryShortcutAvailable:(NSString *)action;
- (void)refreshRecoveryShortcuts;
- (OSStatus)handleRecoveryEvent:(EventRef)event;
- (void)applyVisibility:(MCPinnedImage *)pin;
@property (nonatomic) BOOL captureActive;
- (nullable MCPinnedImage *)createPinPNGData:(NSData *)data display:(BOOL)display error:(NSError **)error;
- (nullable MCPinnedImage *)createPinPNGData:(NSData *)data screenFrame:(NSRect)frame display:(BOOL)display error:(NSError **)error;
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
@property BOOL pendingSelection;
@property BOOL userHidden;
@property BOOL clickThrough;
@property BOOL displayed;
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
    if (self.pin.clickThrough || self.pin.userHidden || self.pin.owner.captureActive) return;
    [self.pin.owner selectPin:self.pin focus:YES];
    if (!self.pin.selected) return;
    if (event.clickCount > 1) { [self.pin close:nil]; return; }
    self.dragging = YES;
    self.dragOrigin = self.window.frame.origin;
    self.dragMouse = [self.window convertPointToScreen:event.locationInWindow];
}
- (void)mouseDragged:(NSEvent *)event {
    if (!self.dragging || self.pin.clickThrough || self.pin.userHidden || self.pin.owner.captureActive) return;
    NSPoint point = [self.window convertPointToScreen:event.locationInWindow];
    [self.window setFrameOrigin:NSMakePoint(self.dragOrigin.x + point.x - self.dragMouse.x,
                                           self.dragOrigin.y + point.y - self.dragMouse.y)];
}
- (void)mouseUp:(NSEvent *)event {
    (void)event;
    if (self.pin.clickThrough || self.pin.userHidden || self.pin.owner.captureActive) return;
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
    if (self.pin.clickThrough || self.pin.userHidden || self.pin.owner.captureActive) return nil;
    [self.pin.owner selectPin:self.pin focus:YES];
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"贴图"];
    for (NSDictionary *item in @[
        @{@"title":@"复制图片", @"action":NSStringFromSelector(@selector(copyImage:))},
        @{@"title":@"隐藏这张贴图", @"action":NSStringFromSelector(@selector(toggleVisibility:))},
        @{@"title":@"鼠标穿透", @"action":NSStringFromSelector(@selector(toggleClickThrough:))},
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
        @"拖动移动 · 单击选中\n%@ / %@ 缩放 · %@ / %@ 调整不透明度\n%@ 隐藏/恢复 · %@ 鼠标穿透\n双击或 Esc 关闭 · 右键更多操作\n缩放 %.0f%% · 不透明度 %.0f%%",
        label(@"zoomIn"), label(@"zoomOut"), label(@"opacityUp"), label(@"opacityDown"),
        label(@"visibilityToggle"), label(@"clickThroughToggle"), self.scale * 100, self.opacity * 100];
    self.view.accessibilityLabel = [NSString stringWithFormat:@"贴图，缩放 %.0f%%，不透明度 %.0f%%", self.scale * 100, self.opacity * 100];
}
- (void)setSelected:(BOOL)selected {
    _selected = selected;
    self.view.needsDisplay = YES;
}
- (void)setOpacity:(CGFloat)opacity {
    _opacity = MAX(0.1, MIN(1, opacity));
    self.panel.alphaValue = self.userHidden ? 0 : _opacity;
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
    if ([action isEqual:@"clickThroughToggle"]) { [self.owner toggleClickThrough]; return; }
    if (self.clickThrough) return;
    if ([action isEqual:@"visibilityToggle"]) { [self.owner toggleVisibility]; return; }
    if (self.userHidden) return;
    if ([action isEqual:@"zoomIn"]) [self zoomBy:1.1];
    else if ([action isEqual:@"zoomOut"]) [self zoomBy:1 / 1.1];
    else if ([action isEqual:@"opacityUp"]) self.opacity += 0.1;
    else if ([action isEqual:@"opacityDown"]) self.opacity -= 0.1;
}
- (BOOL)handleKeyEvent:(NSEvent *)event {
    if (!self.selected || self.owner.captureActive || event.type != NSEventTypeKeyDown) return NO;
    NSString *action = [self.owner.shortcuts actionForEvent:event];
    if (action) { [self applyAction:action]; return YES; }
    NSEventModifierFlags flags = event.modifierFlags & (NSEventModifierFlagCommand | NSEventModifierFlagControl |
        NSEventModifierFlagOption | NSEventModifierFlagShift);
    if (event.keyCode == 53 && flags == 0) {
        if (!self.clickThrough && !self.userHidden) [self close:nil];
        return YES;
    }
    if ((event.keyCode == 51 || event.keyCode == 117) && flags == 0) { [self close:nil]; return YES; }
    return NO;
}
- (void)toggleVisibility:(id)sender { (void)sender; [self.owner toggleVisibility]; }
- (void)toggleClickThrough:(id)sender { (void)sender; [self.owner toggleClickThrough]; }
- (void)reset:(id)sender {
    (void)sender;
    if (self.clickThrough || self.userHidden) return;
    self.opacity = 1;
    [self setScaleAroundCenter:1];
}
- (BOOL)copyToPasteboard:(NSPasteboard *)pasteboard {
    if (self.clickThrough || self.userHidden) return NO;
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
- (void)close:(id)sender { (void)sender; if (!self.clickThrough) [self.panel close]; }
- (void)windowDidBecomeKey:(NSNotification *)notification {
    (void)notification;
    [self.owner selectPin:self focus:NO];
}
- (void)windowDidResignKey:(NSNotification *)notification {
    (void)notification;
    if (!self.clickThrough && !self.userHidden && !self.owner.captureActive) self.selected = NO;
}
- (void)windowWillClose:(NSNotification *)notification {
    (void)notification;
    MCPinnedImageController *owner = self.owner;
    self.panel.delegate = nil;
    self.panel.contentView = nil;
    self.view.pin = nil;
    [owner removePin:self];
}
@end

static const UInt32 MCPinHotKeySignature = 0x4d4a504e;
static OSStatus MCPinHotKeyHandler(__unused EventHandlerCallRef next, EventRef event, void *context) {
    return [(__bridge MCPinnedImageController *)context handleRecoveryEvent:event];
}

@implementation MCPinnedImageController
- (instancetype)initWithDefaults:(NSUserDefaults *)defaults {
    if ((self = [super init])) {
        _pins = [NSMutableArray array];
        _defaults = defaults;
        _shortcuts = [[MCPinShortcutStore alloc] initWithDefaults:defaults];
        id saved = [defaults objectForKey:MCPinFeatureEnabledDefaultsKey];
        if (!saved || [saved boolValue]) [self setEnabled:YES];
    }
    return self;
}
- (BOOL)isEnabled { return feature_can_invoke(self.featureState) != 0; }
- (BOOL)disabling { return self.featureState == MC_FEATURE_DISABLING; }
- (void)setEnabled:(BOOL)enabled {
    NSAssert(NSThread.isMainThread, @"Feature lifecycle is main-thread only");
    if (self.disabling || enabled == self.enabled) return;
    if (enabled) {
        self.featureState = feature_transition(self.featureState, MC_FEATURE_ENABLE);
        if (!self.enabled) return;
        if (!self.observingShortcuts) {
            for (NSNotificationName name in @[MCPinShortcutsDidChangeNotification, MCShortcutsDidChangeNotification])
                [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(shortcutsChanged:) name:name object:self.defaults];
            self.observingShortcuts = YES;
        }
    } else {
        // Close the gate before any AppKit callback can re-enter pin creation.
        self.featureState = feature_transition(self.featureState, MC_FEATURE_REQUEST_DISABLE);
        [self closeAll];
        [self refreshRecoveryShortcuts];
        if (self.eventHandler) { RemoveEventHandler(self.eventHandler); self.eventHandler = NULL; }
        if (self.observingShortcuts) {
            for (NSNotificationName name in @[MCPinShortcutsDidChangeNotification, MCShortcutsDidChangeNotification])
                [NSNotificationCenter.defaultCenter removeObserver:self name:name object:self.defaults];
            self.observingShortcuts = NO;
        }
        self.shortcutRegistrationError = nil;
        if (self.onShortcutStatus) self.onShortcutStatus(nil);
        self.featureState = feature_transition(self.featureState, MC_FEATURE_CLEANUP_FINISHED);
    }
    [self.defaults setBool:self.enabled forKey:MCPinFeatureEnabledDefaultsKey];
}
- (void)shortcutsChanged:(NSNotification *)notification {
    (void)notification;
    if (!NSThread.isMainThread) {
        __weak MCPinnedImageController *weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf shortcutsChanged:nil]; });
        return;
    }
    if (!self.enabled) return;
    [self refreshRecoveryShortcuts];
    for (MCPinnedImage *pin in self.pins) [pin updateTooltip];
}
- (NSUInteger)count { return self.pins.count; }
- (NSSet<NSNumber *> *)visibleWindowNumbers {
    NSMutableSet *numbers = [NSMutableSet set];
    for (MCPinnedImage *pin in self.pins) {
        if (pin.panel.visible && !pin.userHidden && pin.panel.windowNumber > 0)
            [numbers addObject:@(pin.panel.windowNumber)];
    }
    return [numbers copy];
}
- (void)selectPin:(MCPinnedImage *)pin focus:(BOOL)focus {
    if (!self.enabled || self.captureActive) return;
    for (MCPinnedImage *candidate in self.pins) if (candidate.clickThrough && candidate != pin) return;
    for (MCPinnedImage *candidate in self.pins) candidate.selected = candidate == pin;
    if (focus && pin && !self.captureActive) {
        [pin.panel makeKeyWindow];
        [pin.panel makeFirstResponder:pin.view];
    }
}
- (MCPinnedImage *)createPinPNGData:(NSData *)data display:(BOOL)display error:(NSError **)error {
    return [self createPinPNGData:data screenFrame:NSZeroRect display:display error:error];
}
- (MCPinnedImage *)createPinPNGData:(NSData *)data screenFrame:(NSRect)screenFrame display:(BOOL)display error:(NSError **)error {
    NSAssert(NSThread.isMainThread, @"Pinned images are main-thread objects");
    if (!self.enabled) {
        if (error) *error = [NSError errorWithDomain:@"dev.moojicut.pinning" code:2
            userInfo:@{NSLocalizedDescriptionKey:@"贴图已关闭。可在设置的通用页面重新启用。"}];
        return nil;
    }
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
    if (isfinite(screenFrame.origin.x) && isfinite(screenFrame.origin.y) &&
        isfinite(screenFrame.size.width) && isfinite(screenFrame.size.height) &&
        screenFrame.size.width > 0 && screenFrame.size.height > 0) {
        // The editor supplies screen points, including Retina scaling and the
        // selected monitor's possibly negative origin. Preserve this placement.
        frame = screenFrame;
        pin.sourceSize = screenFrame.size;
        initial = 1;
        width = screenFrame.size.width; height = screenFrame.size.height;
    }
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
    pin.displayed = display;
    [self refreshRecoveryShortcuts];
    if (display) {
        pin.pendingSelection = self.captureActive;
        if (!self.captureActive) {
            [pin.panel orderFront:nil];
            [self selectPin:pin focus:YES];
        }
    }
    return pin;
}
- (BOOL)pinPNGData:(NSData *)data error:(NSError **)error { return [self createPinPNGData:data display:YES error:error] != nil; }
- (BOOL)pinPNGData:(NSData *)data screenFrame:(NSRect)frame error:(NSError **)error {
    return [self createPinPNGData:data screenFrame:frame display:YES error:error] != nil;
}
- (void)removePin:(MCPinnedImage *)pin {
    pin.owner = nil;
    [self.pins removeObjectIdenticalTo:pin];
    [self refreshRecoveryShortcuts];
}
- (void)setCaptureActive:(BOOL)active {
    if (self.captureActive == active) return;
    _captureActive = active;
    MCPinnedImage *newest = nil;
    for (MCPinnedImage *pin in self.pins) {
        pin.panel.ignoresMouseEvents = active || pin.clickThrough || pin.userHidden;
        pin.view.dragging = NO;
        if (!active && pin.pendingSelection) {
            pin.pendingSelection = NO;
            if (pin.displayed && !pin.userHidden) {
                [pin.panel orderFront:nil];
                newest = pin;
            }
        }
    }
    // A newly confirmed "pin" is an explicit action. Give just that new panel
    // keyboard focus; existing pins are never hidden, raised or activated.
    if (newest) [self selectPin:newest focus:YES];
    // Keep recovery registrations intact while their handlers are suspended.
    // Re-registering on every capture could fail and reveal user-hidden pins.
}
- (void)applyVisibility:(MCPinnedImage *)pin {
    pin.panel.alphaValue = pin.userHidden ? 0 : pin.opacity;
    pin.panel.ignoresMouseEvents = self.captureActive || pin.clickThrough || pin.userHidden;
    if (pin.userHidden || (self.captureActive && pin.pendingSelection)) [pin.panel orderOut:nil];
    else if (pin.displayed) [pin.panel orderFront:nil];
}
- (void)restoreHiddenPins {
    for (MCPinnedImage *pin in self.pins) if (pin.userHidden && !pin.clickThrough) {
        pin.userHidden = NO; [self applyVisibility:pin];
    }
}
- (void)disableClickThrough {
    for (MCPinnedImage *pin in self.pins) if (pin.clickThrough) {
        pin.clickThrough = NO; [self applyVisibility:pin];
    }
}
- (void)toggleVisibility {
    if (!self.enabled || self.captureActive || self.shortcutsSuspended) return;
    MCPinnedImage *selected = nil;
    BOOL hidden = NO;
    for (MCPinnedImage *pin in self.pins) { if (pin.selected) selected = pin; hidden = hidden || pin.userHidden; }
    if (selected.clickThrough) return;
    if (selected && selected.userHidden) {
        selected.userHidden = NO; [self applyVisibility:selected]; [self selectPin:selected focus:YES]; return;
    }
    if (!selected && hidden) { [self restoreHiddenPins]; return; }
    if (![self recoveryShortcutAvailable:@"visibilityToggle"]) { NSBeep(); return; }
    for (MCPinnedImage *pin in self.pins) if ((!selected || pin == selected) && !pin.clickThrough) {
        pin.userHidden = YES; [self applyVisibility:pin];
    }
}
- (void)toggleClickThrough {
    if (!self.enabled || self.captureActive || self.shortcutsSuspended) return;
    for (MCPinnedImage *pin in self.pins) if (pin.clickThrough) {
        pin.clickThrough = NO; [self applyVisibility:pin]; [self selectPin:pin focus:YES]; return;
    }
    if (![self recoveryShortcutAvailable:@"clickThroughToggle"]) { NSBeep(); return; }
    for (MCPinnedImage *pin in self.pins) if (pin.selected && !pin.userHidden) {
        pin.clickThrough = YES;
        [self applyVisibility:pin];
        // Mouse hits now go to the application below, while our logical target
        // remains selected for the globally registered recovery combination.
        [pin.panel resignKeyWindow];
        return;
    }
}
- (BOOL)recoveryShortcutAvailable:(NSString *)action {
    return _recoveryKeys[[action isEqual:@"visibilityToggle"] ? 0 : 1] != NULL;
}
- (void)setShortcutsSuspended:(BOOL)suspended {
    if (self.shortcutsSuspended == suspended) return;
    _shortcutsSuspended = suspended;
    // Losing the recovery key must never leave a mouse-inert window behind.
    if (suspended) { [self disableClickThrough]; [self restoreHiddenPins]; }
    [self refreshRecoveryShortcuts];
}
- (void)refreshRecoveryShortcuts {
    for (NSUInteger index = 0; index < 2; index++) if (_recoveryKeys[index]) {
        UnregisterEventHotKey(_recoveryKeys[index]); _recoveryKeys[index] = NULL;
    }
    BOOL active = NO;
    for (MCPinnedImage *pin in self.pins) active = active || pin.displayed;
    if (!self.enabled || !active || self.shortcutsSuspended) return;
    if (!self.eventHandler) {
        EventTypeSpec spec = {kEventClassKeyboard, kEventHotKeyPressed};
        EventHandlerRef handler = NULL;
        if (InstallEventHandler(GetApplicationEventTarget(), MCPinHotKeyHandler, 1, &spec, (__bridge void *)self, &handler) == noErr)
            self.eventHandler = handler;
    }
    NSArray *actions = @[@"visibilityToggle", @"clickThroughToggle"];
    NSMutableArray *errors = [NSMutableArray array];
    MCShortcutStore *global = [[MCShortcutStore alloc] initWithDefaults:self.defaults];
    for (NSUInteger index = 0; index < 2; index++) {
        NSDictionary *shortcut = [self.shortcuts shortcutForAction:actions[index]];
        NSEventModifierFlags flags = [shortcut[@"modifiers"] unsignedIntegerValue];
        unsigned short code = [shortcut[@"keyCode"] unsignedShortValue];
        BOOL valid = shortcut && (flags & (NSEventModifierFlagCommand | NSEventModifierFlagOption | NSEventModifierFlagControl));
        for (NSString *action in @[@"capture", @"record", @"stop"]) {
            NSDictionary *other = [global shortcutForAction:action];
            if ([shortcut[@"keyCode"] isEqual:other[@"keyCode"]] && [shortcut[@"modifiers"] isEqual:other[@"modifiers"]]) valid = NO;
        }
        if (valid && MCSystemShortcutConflict(code, flags)) valid = NO;
        UInt32 modifiers = 0;
        if (flags & NSEventModifierFlagCommand) modifiers |= cmdKey;
        if (flags & NSEventModifierFlagOption) modifiers |= optionKey;
        if (flags & NSEventModifierFlagControl) modifiers |= controlKey;
        if (flags & NSEventModifierFlagShift) modifiers |= shiftKey;
        EventHotKeyID identifier = {MCPinHotKeySignature, (UInt32)index + 1};
        if (!valid || !self.eventHandler || RegisterEventHotKey(code, modifiers, identifier,
            GetApplicationEventTarget(), kEventHotKeyExclusive, &_recoveryKeys[index]) != noErr) {
            if (_recoveryKeys[index]) { UnregisterEventHotKey(_recoveryKeys[index]); _recoveryKeys[index] = NULL; }
            if (shortcut) [errors addObject:index == 0 ? @"贴图隐藏快捷键不可用，请重新设置。" : @"鼠标穿透快捷键不可用，请重新设置。"];
            if (index == 0) [self restoreHiddenPins]; else [self disableClickThrough];
        }
    }
    self.shortcutRegistrationError = errors.count ? [errors componentsJoinedByString:@"\n"] : nil;
    if (self.onShortcutStatus) self.onShortcutStatus(self.shortcutRegistrationError);
}
- (OSStatus)handleRecoveryEvent:(EventRef)event {
    if (!self.enabled || self.captureActive) return eventNotHandledErr;
    EventHotKeyID key = {0};
    if (GetEventParameter(event, kEventParamDirectObject, typeEventHotKeyID, NULL, sizeof(key), NULL, &key) != noErr ||
        key.signature != MCPinHotKeySignature || key.id < 1 || key.id > 2 || !_recoveryKeys[key.id - 1]) return eventNotHandledErr;
    if (key.id == 1) [self toggleVisibility]; else [self toggleClickThrough];
    return noErr;
}
- (void)closeAll {
    for (MCPinnedImage *pin in [self.pins copy]) {
        // Explicit close-all / disable must also release mouse-inert pins.
        pin.clickThrough = NO;
        pin.panel.ignoresMouseEvents = NO;
        [pin close:nil];
    }
}
- (void)dealloc {
    for (NSUInteger index = 0; index < 2; index++) if (_recoveryKeys[index]) UnregisterEventHotKey(_recoveryKeys[index]);
    if (_eventHandler) RemoveEventHandler(_eventHandler);
    [NSNotificationCenter.defaultCenter removeObserver:self];
    for (MCPinnedImage *pin in self.pins) {
        pin.panel.delegate = nil;
        [pin.panel orderOut:nil];
        pin.panel.contentView = nil;
    }
}
@end
