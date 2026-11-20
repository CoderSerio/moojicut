#import "MCSelectionSurface.h"
#import "components/theme/macos/MCChromeTheme.h"
#include <math.h>

BOOL MCSelectionMovedBeyondClick(NSPoint anchor, NSPoint point) {
    return hypot(point.x-anchor.x, point.y-anchor.y) >= 3;
}

@implementation MCSelectionSurface {
    MCSelectionGesture _regionGesture;
    NSTrackingArea *_selectionTrackingArea;
}
- (BOOL)isFlipped { return YES; }
- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)acceptsFirstMouse:(__unused NSEvent *)event { return YES; }
- (void)updateTrackingAreas {
    if (_selectionTrackingArea) [self removeTrackingArea:_selectionTrackingArea];
    _selectionTrackingArea = [[NSTrackingArea alloc] initWithRect:NSZeroRect options:NSTrackingMouseMoved |
        NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways | NSTrackingInVisibleRect owner:self userInfo:nil];
    [self addTrackingArea:_selectionTrackingArea];
    [super updateTrackingAreas];
}
- (NSDictionary *)windowCandidateAtPoint:(NSPoint)point {
    for (NSDictionary *candidate in self.windowCandidates) {
        if (NSPointInRect(point, [candidate[@"rect"] rectValue])) return candidate;
    }
    return nil;
}
- (MCSelectionGesture)regionGesture { return _regionGesture; }
- (BOOL)regionDragging { return _regionGesture.active; }
- (NSRect)selectionContentFrame { return self.bounds; }
- (NSSize)selectionContentSize { return self.bounds.size; }
- (NSPoint)selectionPointForEvent:(NSEvent *)event {
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    NSRect frame = self.selectionContentFrame; NSSize size = self.selectionContentSize;
    if (NSIsEmptyRect(frame)) return NSZeroPoint;
    return NSMakePoint(MAX(0,MIN(size.width,(point.x-frame.origin.x)*size.width/frame.size.width)),
                       MAX(0,MIN(size.height,(point.y-frame.origin.y)*size.height/frame.size.height)));
}
- (NSRect)selectionViewRect:(NSRect)rect {
    NSRect frame = self.selectionContentFrame; NSSize size = self.selectionContentSize;
    if (size.width <= 0 || size.height <= 0) return NSZeroRect;
    CGFloat sx = frame.size.width/size.width, sy = frame.size.height/size.height;
    return NSMakeRect(frame.origin.x+rect.origin.x*sx,frame.origin.y+rect.origin.y*sy,rect.size.width*sx,rect.size.height*sy);
}
- (NSRect)selectionContentRect:(NSRect)viewRect {
    NSRect frame = self.selectionContentFrame; NSSize size = self.selectionContentSize;
    if (NSIsEmptyRect(frame) || NSIsEmptyRect(viewRect)) return NSZeroRect;
    CGFloat sx = size.width/frame.size.width, sy = size.height/frame.size.height;
    return NSMakeRect((viewRect.origin.x-frame.origin.x)*sx, (viewRect.origin.y-frame.origin.y)*sy,
                      viewRect.size.width*sx, viewRect.size.height*sy);
}
- (BOOL)beginRegion:(NSInteger)operation event:(NSEvent *)event rect:(NSRect)rect {
    [self.window makeFirstResponder:self];
    return MCSelectionBegin(&_regionGesture,operation,[self selectionPointForEvent:event],rect,self.selectionContentSize);
}
- (void)updateRegion:(NSEvent *)event { MCSelectionUpdate(&_regionGesture,[self selectionPointForEvent:event]); }
- (BOOL)finishRegion:(NSEvent *)event rect:(NSRect *)rect { return MCSelectionFinish(&_regionGesture,[self selectionPointForEvent:event],rect); }
- (void)cancelRegion { MCSelectionCancel(&_regionGesture); }
- (void)drawRegion:(NSRect)region dimensions:(NSSize)pixels handles:(BOOL)handles hint:(NSString *)hint {
    NSBezierPath *shade = [NSBezierPath bezierPathWithRect:self.bounds];
    if (!NSIsEmptyRect(region)) [shade appendBezierPathWithRect:region];
    shade.windingRule = NSWindingRuleEvenOdd;
    [[NSColor colorWithWhite:0 alpha:0.48] setFill]; [shade fill];
    if (NSIsEmptyRect(region)) {
        if (!hint.length) return;
        NSDictionary *attributes = @{NSFontAttributeName:[NSFont systemFontOfSize:17 weight:NSFontWeightMedium],NSForegroundColorAttributeName:NSColor.whiteColor};
        NSSize size = [hint sizeWithAttributes:attributes];
        [hint drawAtPoint:NSMakePoint((NSWidth(self.bounds)-size.width)/2,MAX(30,NSHeight(self.bounds)*.12)) withAttributes:attributes];
        return;
    }
    NSBezierPath *border = [NSBezierPath bezierPathWithRect:region];
    [MCSelectionContrastColor() setStroke]; border.lineWidth=3.5; [border stroke];
    [MCSelectionColor() setStroke]; border.lineWidth=1.5; [border stroke];
    if (handles) for (NSInteger handle=0;handle<8;handle++) {
        NSPoint center = MCSelectionHandlePoint(handle,region);
        NSBezierPath *dot = [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(center.x-3,center.y-3,6,6)];
        [MCSelectionHandleColor() setFill]; [dot fill]; [MCSelectionContrastColor() setStroke]; [dot stroke];
    }
    NSString *dimensions = [NSString stringWithFormat:@"%.0f × %.0f px",pixels.width,pixels.height];
    NSDictionary *attributes = @{NSFontAttributeName:[NSFont monospacedDigitSystemFontOfSize:12 weight:NSFontWeightMedium],NSForegroundColorAttributeName:NSColor.whiteColor};
    NSSize size = [dimensions sizeWithAttributes:attributes];
    NSRect label = NSMakeRect(MAX(4,MIN(region.origin.x,NSWidth(self.bounds)-size.width-16)),MAX(4,region.origin.y-27),size.width+12,22);
    [[NSColor colorWithWhite:.1 alpha:.9] setFill];
    [[NSBezierPath bezierPathWithRoundedRect:label xRadius:5 yRadius:5] fill];
    [dimensions drawAtPoint:NSMakePoint(label.origin.x+6,label.origin.y+3) withAttributes:attributes];
}
@end

@implementation MCSelectionWindow
- (BOOL)canBecomeKeyWindow { return YES; }
- (void)configureForScreenFrame:(NSRect)frame {
    self.styleMask = NSWindowStyleMaskBorderless; self.minSize = NSZeroSize;
    self.level = NSScreenSaverWindowLevel; self.hasShadow = NO;
    self.opaque = YES; self.backgroundColor = NSColor.blackColor;
    self.ignoresMouseEvents = NO; self.acceptsMouseMovedEvents = YES;
    self.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorFullScreenAuxiliary;
    [self setFrame:frame display:NO];
}
@end

void MCSelectionWhenKeysReleased(NSUInteger attempts, BOOL (^isCurrent)(void),
        NSEventModifierFlags (^modifiers)(void), void (^completion)(BOOL)) {
    if (!isCurrent()) return;
    NSEventModifierFlags held = modifiers() & (NSEventModifierFlagCommand | NSEventModifierFlagShift | NSEventModifierFlagControl | NSEventModifierFlagOption);
    if (!held) { completion(YES); return; }
    if (attempts >= 40) { completion(NO); return; }
    MCSelectionAfter(0.05, ^{
        MCSelectionWhenKeysReleased(attempts+1,isCurrent,modifiers,completion);
    });
}

void MCSelectionPerformOnMain(void (^action)(void)) {
    // Main GCD work can be deferred by nested event-tracking loops. A common
    // mode run-loop block retains main-thread ordering without closing menus.
    CFRunLoopPerformBlock(CFRunLoopGetMain(), kCFRunLoopCommonModes, action);
    CFRunLoopWakeUp(CFRunLoopGetMain());
}
void MCSelectionAfter(NSTimeInterval seconds, void (^action)(void)) {
    NSCAssert(NSThread.isMainThread, @"Selection timers belong to the main thread");
    NSTimer *timer = [NSTimer timerWithTimeInterval:seconds repeats:NO block:^(__unused NSTimer *timer) { action(); }];
    [NSRunLoop.mainRunLoop addTimer:timer forMode:NSRunLoopCommonModes];
}
NSEventModifierFlags MCSelectionCurrentModifiers(void) {
    // NSEvent.modifierFlags can still describe the triggering key event while
    // another app or a menu consumes subsequent key-up events.
    return (NSEventModifierFlags)CGEventSourceFlagsState(kCGEventSourceStateCombinedSessionState);
}
