#import <AppKit/AppKit.h>
#import "pinning/MCPinnedImageController.h"
#import "preferences/MCPinShortcutStore.h"
#include <math.h>

// The window and mouse fixtures are local to this process. They never order
// actual windows front, post input events, capture screens, or use the system
// clipboard. The spy records capture-hide/restore behavior without UI effects.
@interface MCPinnedImage : NSObject
@property NSPanel *panel;
@property NSView *view;
@property (nonatomic) BOOL selected;
@property (nonatomic) CGFloat opacity;
@property CGFloat scale;
@property NSSize sourceSize;
@property BOOL restoreVisible;
- (BOOL)handleKeyEvent:(NSEvent *)event;
- (void)applyAction:(NSString *)action;
- (BOOL)copyToPasteboard:(NSPasteboard *)pasteboard;
- (void)close:(id)sender;
- (void)reset:(id)sender;
@end
@interface MCPinnedImageController (Test)
@property (readonly) NSArray<MCPinnedImage *> *pins;
- (MCPinnedImage *)createPinPNGData:(NSData *)data display:(BOOL)display error:(NSError **)error;
- (void)selectPin:(MCPinnedImage *)pin focus:(BOOL)focus;
@end

@interface MCPinTestPanel : NSPanel
@property BOOL testVisible;
@property NSUInteger keyRequests;
@property NSUInteger frontRequests;
@end
@implementation MCPinTestPanel
- (BOOL)isVisible { return self.testVisible; }
- (void)orderFront:(id)sender { (void)sender; self.testVisible = YES; self.frontRequests++; }
- (void)orderOut:(id)sender { (void)sender; self.testVisible = NO; }
- (void)makeKeyWindow { self.keyRequests++; }
- (void)close {
    id<NSWindowDelegate> delegate = self.delegate;
    if ([delegate respondsToSelector:@selector(windowWillClose:)])
        [delegate windowWillClose:[NSNotification notificationWithName:NSWindowWillCloseNotification object:self]];
    self.testVisible = NO;
}
@end

static MCPinTestPanel *spyPanel(MCPinnedImage *pin) {
    NSPanel *old = pin.panel;
    MCPinTestPanel *panel = [[MCPinTestPanel alloc] initWithContentRect:old.frame
        styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
        backing:NSBackingStoreBuffered defer:NO];
    panel.releasedWhenClosed = NO;
    panel.delegate = old.delegate;
    old.delegate = nil;
    old.contentView = nil;
    panel.contentView = pin.view;
    pin.panel = panel;
    panel.alphaValue = pin.opacity;
    return panel;
}
static NSData *fixture(void) {
    NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:240 pixelsHigh:160
        bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:960 bitsPerPixel:32];
    for (NSInteger y = 0; y < 160; y++) for (NSInteger x = 0; x < 240; x++) {
        unsigned char *pixel = bitmap.bitmapData + y * bitmap.bytesPerRow + x * 4;
        pixel[0] = x; pixel[1] = y; pixel[2] = 180; pixel[3] = 255;
    }
    return [bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
}
static NSEvent *key(unsigned short code, NSEventModifierFlags flags) {
    return [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:flags
        timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:0 context:nil
        characters:code == 27 ? @"-" : @"+" charactersIgnoringModifiers:code == 27 ? @"-" : @"="
        isARepeat:NO keyCode:code];
}
static NSEvent *mouse(NSWindow *window, NSEventType type, NSPoint screenPoint) {
    return [NSEvent mouseEventWithType:type location:[window convertPointFromScreen:screenPoint] modifierFlags:0
        timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:window.windowNumber context:nil eventNumber:0 clickCount:1 pressure:1];
}
static BOOL near(CGFloat actual, CGFloat expected) { return fabs(actual - expected) < .01; }
#define CHECK(condition, message) do { if (!(condition)) { fprintf(stderr, "FAIL pinned image: %s\n", message); passed = NO; } } while (0)

int main(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
        NSString *domain = [@"dev.moojicut.pin-test." stringByAppendingString:NSUUID.UUID.UUIDString];
        NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:domain];
        MCPinnedImageController *controller = [[MCPinnedImageController alloc] initWithDefaults:defaults];
        BOOL passed = YES;
        NSError *error = nil;
        CHECK(![controller createPinPNGData:[NSData data] display:NO error:&error] && error != nil && controller.count == 0,
            "invalid input does not create a window");
        NSData *png = fixture();
        MCPinnedImage *first = [controller createPinPNGData:png display:NO error:&error];
        MCPinnedImage *second = [controller createPinPNGData:png display:NO error:&error];
        CHECK(first && second && controller.count == 2, "independent pins retain their own finalized images");
        CHECK(!first.panel.visible && !second.panel.visible, "fixtures never show native windows");
        CHECK(first.panel.level == NSFloatingWindowLevel && !first.panel.hidesOnDeactivate &&
            (first.panel.styleMask & NSWindowStyleMaskNonactivatingPanel) && !(first.panel.styleMask & NSWindowStyleMaskTitled),
            "pins are nonactivating, untitled floating panels");
        MCPinTestPanel *firstPanel = spyPanel(first), *secondPanel = spyPanel(second);

        [controller selectPin:first focus:NO];
        CHECK(first.selected && !second.selected, "only one pin is selected");
        NSRect original = first.panel.frame;
        CGFloat originalScale = first.scale;
        CHECK([first handleKeyEvent:key(24, 0)], "selected pin accepts the default zoom key");
        CHECK(near(first.scale, originalScale * 1.1) && near(NSMidX(first.panel.frame), NSMidX(original)) &&
              near(NSMidY(first.panel.frame), NSMidY(original)), "zoom preserves image aspect and center");
        CHECK(near(first.panel.frame.size.width / first.panel.frame.size.height, 1.5), "zoom preserves aspect ratio");
        CHECK(![second handleKeyEvent:key(24, 0)] && near(second.scale, originalScale),
            "unselected pins never process local keyboard actions");
        for (NSInteger i = 0; i < 30; i++) [first handleKeyEvent:key(27, NSEventModifierFlagCommand)];
        CHECK(near(first.opacity, .1) && near(first.panel.alphaValue, .1), "opacity is clamped at ten percent");
        for (NSInteger i = 0; i < 30; i++) [first handleKeyEvent:key(24, NSEventModifierFlagCommand)];
        CHECK(near(first.opacity, 1), "opacity is clamped at full opacity");
        for (NSInteger i = 0; i < 70; i++) [first handleKeyEvent:key(24, 0)];
        NSScreen *screen = first.panel.screen ?: NSScreen.mainScreen;
        CHECK(first.scale <= 8 && (!screen || (first.panel.frame.size.width <= screen.visibleFrame.size.width &&
              first.panel.frame.size.height <= screen.visibleFrame.size.height)), "zoom cannot grow an unreachable panel");
        [first reset:nil];

        // User remapping takes effect in already-open pins and leaves old keys free.
        MCPinShortcutStore *store = [[MCPinShortcutStore alloc] initWithDefaults:defaults];
        NSString *shortcutError = nil;
        CHECK([store setShortcut:[MCPinShortcutStore shortcutWithKeyCode:124 modifiers:0] forAction:@"zoomIn" error:&shortcutError],
            "zoom key is configurable");
        originalScale = first.scale;
        CHECK(![first handleKeyEvent:key(24, 0)] && [first handleKeyEvent:key(124, 0)] && first.scale > originalScale,
            "open pins read updated key mappings");
        [store restoreDefaults];

        [controller selectPin:second focus:NO];
        [second reset:nil];
        NSRect beforeDrag = second.panel.frame;
        NSPoint down = NSMakePoint(NSMidX(beforeDrag), NSMidY(beforeDrag));
        NSPoint drag = NSMakePoint(down.x + 35, down.y - 25);
        [second.view mouseDown:mouse(second.panel, NSEventTypeLeftMouseDown, down)];
        [second.view mouseDragged:mouse(second.panel, NSEventTypeLeftMouseDragged, drag)];
        [second.view mouseUp:mouse(second.panel, NSEventTypeLeftMouseUp, drag)];
        CHECK(near(second.panel.frame.origin.x, beforeDrag.origin.x + 35) &&
              near(second.panel.frame.origin.y, beforeDrag.origin.y - 25), "drag moves the existing panel using screen coordinates");
        CHECK(secondPanel.keyRequests == 1 && second.selected && !first.selected, "single click selects rather than creating a window");
        CHECK([second handleKeyEvent:key(53, 0)] && !second.selected && controller.count == 2,
            "Escape deselects without deleting pins or quitting the app");

        first.opacity = .3;
        [first applyAction:@"zoomIn"];
        NSPasteboard *clipboard = [NSPasteboard pasteboardWithUniqueName];
        CHECK([first copyToPasteboard:clipboard] && [[clipboard dataForType:NSPasteboardTypePNG] isEqualToData:png],
            "copy preserves source pixels without UI selection, scale, or display opacity");
        [clipboard releaseGlobally];

        firstPanel.testVisible = YES;
        secondPanel.testVisible = NO;
        [controller setCaptureHidden:YES];
        CHECK(!firstPanel.visible && !secondPanel.visible && first.restoreVisible && !second.restoreVisible,
            "capture hides only visible pins while remembering their visibility");
        [controller selectPin:first focus:NO];
        CHECK(![first handleKeyEvent:key(24, 0)], "hidden capture pins do not accept actions");
        [controller setCaptureHidden:YES];
        CHECK(first.restoreVisible, "repeated capture-hide does not lose restore intent");
        NSUInteger firstKeys = firstPanel.keyRequests, secondKeys = secondPanel.keyRequests;
        [controller setCaptureHidden:NO];
        CHECK(firstPanel.visible && !secondPanel.visible && firstPanel.keyRequests == firstKeys &&
              secondPanel.keyRequests == secondKeys, "restoring pins preserves visibility without stealing key focus");

        [controller setCaptureHidden:YES];
        CHECK([controller pinPNGData:png error:&error], "new pins can be queued while capture is ending");
        MCPinnedImage *queued = controller.pins.lastObject;
        CHECK(queued.restoreVisible && !queued.panel.visible, "new queued pin remains hidden until capture completes");
        MCPinTestPanel *queuedPanel = spyPanel(queued);
        [controller setCaptureHidden:NO];
        CHECK(queuedPanel.visible && queuedPanel.keyRequests == 1 && queued.selected && !first.selected,
            "only a newly confirmed pin takes local keyboard focus when capture ends");

        [second close:nil];
        CHECK(controller.count == 2 && ![controller.pins containsObject:second], "closing one pin releases only that pin");
        [controller closeAll];
        CHECK(controller.count == 0, "closing all pins releases every retained panel");
        [defaults removePersistentDomainForName:domain];
        puts(passed ? "PASS pinned images: floating lifecycle, selected drag/zoom/opacity, configurable keys, finalized clipboard, capture hide/restore"
                    : "FAIL pinned images");
        return passed ? 0 : 1;
    }
}
