#import <AppKit/AppKit.h>
#import "pinning/MCPinnedImageController.h"
#import "preferences/MCPinShortcutStore.h"
#include <math.h>
#import <Carbon/Carbon.h>
#include <stdlib.h>

static BOOL registrationFails;
static NSUInteger registrations, unregistrations;
OSStatus MCTestRegisterPinHotKey(UInt32 code, UInt32 modifiers, EventHotKeyID identity, EventTargetRef target, OptionBits options, EventHotKeyRef *reference) {
    (void)code; (void)modifiers; (void)identity; (void)target; (void)options;
    if (registrationFails) { *reference = NULL; return eventHotKeyExistsErr; }
    *reference = (EventHotKeyRef)malloc(1); registrations++; return noErr;
}
OSStatus MCTestUnregisterPinHotKey(EventHotKeyRef reference) { free(reference); unregistrations++; return noErr; }

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
@property BOOL userHidden;
@property BOOL clickThrough;
@property BOOL displayed;
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
- (MCPinnedImage *)createPinPNGData:(NSData *)data screenFrame:(NSRect)frame display:(BOOL)display error:(NSError **)error;
- (void)refreshRecoveryShortcuts;
- (OSStatus)handleRecoveryEvent:(EventRef)event;
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
static OSStatus recoveryEvent(MCPinnedImageController *controller, UInt32 action) {
    EventRef event = NULL;
    CreateEvent(NULL, kEventClassKeyboard, kEventHotKeyPressed, 0, kEventAttributeNone, &event);
    EventHotKeyID key = {0x4d4a504e, action};
    SetEventParameter(event, kEventParamDirectObject, typeEventHotKeyID, sizeof(key), &key);
    OSStatus status = [controller handleRecoveryEvent:event];
    ReleaseEvent(event);
    return status;
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
        MCPinnedImage *escaped = [controller createPinPNGData:png display:NO error:&error];
        spyPanel(escaped);
        [controller selectPin:escaped focus:NO];
        CHECK([escaped handleKeyEvent:key(53, 0)] && controller.count == 2,
            "Escape closes the selected pin without quitting the app");

        NSRect sourceFrame = NSMakeRect(-700, 120, 120, 80);
        MCPinnedImage *placed = [controller createPinPNGData:png screenFrame:sourceFrame display:NO error:&error];
        CHECK(NSEqualRects(placed.panel.frame, sourceFrame) && NSEqualSizes(placed.sourceSize, sourceFrame.size),
            "pin placement preserves screen point dimensions, Retina scale and negative monitor origin");
        spyPanel(placed);
        NSEvent *doubleClick = [NSEvent mouseEventWithType:NSEventTypeLeftMouseDown location:NSMakePoint(20, 20)
            modifierFlags:0 timestamp:0 windowNumber:placed.panel.windowNumber context:nil eventNumber:0 clickCount:2 pressure:1];
        [placed.view mouseDown:doubleClick];
        CHECK(controller.count == 2, "double clicking a pin closes just that pin");

        first.opacity = .3;
        [first applyAction:@"zoomIn"];
        NSPasteboard *clipboard = [NSPasteboard pasteboardWithUniqueName];
        CHECK([first copyToPasteboard:clipboard] && [[clipboard dataForType:NSPasteboardTypePNG] isEqualToData:png],
            "copy preserves source pixels without UI selection, scale, or display opacity");
        [clipboard releaseGlobally];

        first.displayed = second.displayed = YES;
        firstPanel.testVisible = secondPanel.testVisible = YES;
        [controller refreshRecoveryShortcuts];
        CHECK(registrations == 2, "recovery combinations register while pins exist");
        [controller selectPin:first focus:NO];
        [controller toggleVisibility];
        CHECK(first.userHidden && first.selected && !firstPanel.visible && near(firstPanel.alphaValue, 0) &&
              near(first.opacity, .3) && secondPanel.visible, "selected hide preserves target and prior opacity");
        [controller toggleVisibility];
        CHECK(!first.userHidden && firstPanel.visible && near(firstPanel.alphaValue, .3), "toggle restores the exact prior opacity");
        [controller selectPin:nil focus:NO];
        [controller toggleVisibility];
        CHECK(first.userHidden && second.userHidden, "no selection hides all visible pins");
        [controller toggleVisibility];
        CHECK(!first.userHidden && !second.userHidden, "no selection restores hidden pins before hiding anything else");
        [controller selectPin:first focus:NO];
        [controller toggleClickThrough];
        CGFloat lockedScale = first.scale, lockedOpacity = first.opacity;
        CHECK(first.clickThrough && first.selected && firstPanel.ignoresMouseEvents, "click-through retains logical selection with mouse pass-through");
        [first handleKeyEvent:key(53, 0)]; [first applyAction:@"zoomIn"]; [first applyAction:@"opacityUp"];
        [first reset:nil]; [first close:nil]; [controller toggleVisibility];
        [first.view mouseDown:doubleClick];
        CHECK(controller.count == 2 && first.clickThrough && first.selected && !first.userHidden &&
              near(first.scale, lockedScale) && near(first.opacity, lockedOpacity), "locked pin ignores close, double-click, styles, reset and hide");
        NSPasteboard *lockedClipboard = [NSPasteboard pasteboardWithUniqueName];
        CHECK(![first copyToPasteboard:lockedClipboard], "locked pin ignores copy");
        [lockedClipboard releaseGlobally];
        [controller setCaptureHidden:YES];
        CHECK(first.clickThrough && first.selected && !firstPanel.visible && recoveryEvent(controller, 2) == eventNotHandledErr,
            "capture temporarily suspends recovery while preserving the logical pass-through target");
        [controller setCaptureHidden:NO];
        CHECK(first.clickThrough && first.selected && firstPanel.visible, "capture restore retains pass-through mode and selection");
        CHECK(recoveryEvent(controller, 2) == noErr && !first.clickThrough && !firstPanel.ignoresMouseEvents && first.selected,
            "global recovery event makes the same pin interactive after focus loss");
        CHECK(recoveryEvent(controller, 3) == eventNotHandledErr, "unrelated hotkey identifiers are not consumed");
        registrationFails = YES;
        [controller refreshRecoveryShortcuts];
        [controller toggleClickThrough]; [controller toggleVisibility];
        CHECK(!first.clickThrough && !first.userHidden && controller.shortcutRegistrationError.length > 0,
            "failed global registration refuses inaccessible modes");
        registrationFails = NO;
        [controller refreshRecoveryShortcuts];
        [controller toggleVisibility];
        [store setShortcut:nil forAction:@"visibilityToggle" error:NULL];
        CHECK(!first.userHidden && near(firstPanel.alphaValue, .3), "clearing the recovery key restores hidden pins");
        [store restoreDefaults];
        [controller toggleClickThrough];
        [controller setShortcutsSuspended:YES];
        CHECK(!first.clickThrough && !firstPanel.ignoresMouseEvents, "recording a shortcut safely releases mouse-inert pins before unregistering");
        [controller setShortcutsSuspended:NO];
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
        CHECK(registrations == unregistrations, "closing the final pin releases all global recovery registrations");
        [defaults removePersistentDomainForName:domain];
        puts(passed ? "PASS pinned images: floating lifecycle, selected drag/zoom/opacity, configurable keys, finalized clipboard, capture hide/restore"
                    : "FAIL pinned images");
        return passed ? 0 : 1;
    }
}
