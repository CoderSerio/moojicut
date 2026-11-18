#ifndef MOOJICUT_CAPTURE_TOOLBAR_FIXTURE_H
#define MOOJICUT_CAPTURE_TOOLBAR_FIXTURE_H
#import "components/shared_canvas/macos/MCSharedCanvas.h"
#include "bindings/c/capture_toolbar.h"

// Real shared-canvas input and semantics, intentionally no NSButton/segment shim.
static inline NSDictionary *MCToolbarSemantic(MCSharedCanvasView *canvas, NSString *identifier) {
    for (NSDictionary *item in canvas.frameDescription[@"semantics"])
        if ([item[@"id"] isEqual:identifier]) return item;
    return nil;
}
static inline NSRect MCToolbarRect(NSDictionary *item) {
    return NSMakeRect([item[@"x"] doubleValue], [item[@"y"] doubleValue],
                     [item[@"width"] doubleValue], [item[@"height"] doubleValue]);
}
static inline NSEvent *MCToolbarMouse(MCSharedCanvasView *canvas, NSString *identifier, NSEventType type, CGFloat fraction) {
    NSRect rect = MCToolbarRect(MCToolbarSemantic(canvas,identifier));
    NSPoint point = [canvas convertPoint:NSMakePoint(NSMinX(rect)+NSWidth(rect)*fraction,NSMidY(rect)) toView:nil];
    return [NSEvent mouseEventWithType:type location:point modifierFlags:0 timestamp:0
        windowNumber:canvas.window.windowNumber context:nil eventNumber:0 clickCount:1 pressure:1];
}
static inline void MCToolbarPressVisible(MCSharedCanvasView *canvas, NSString *identifier, CGFloat fraction) {
    NSCAssert(MCToolbarSemantic(canvas,identifier) != nil,@"Missing toolbar semantic: %@",identifier);
    [canvas mouseDown:MCToolbarMouse(canvas,identifier,NSEventTypeLeftMouseDown,fraction)];
    [canvas mouseUp:MCToolbarMouse(canvas,identifier,NSEventTypeLeftMouseUp,fraction)];
}
static inline NSDictionary *MCToolbarReveal(MCSharedCanvasView *canvas, NSString *identifier) {
    NSDictionary *item = MCToolbarSemantic(canvas,identifier);
    if (item) return item;
    for (NSUInteger i=0; i<512; i++) {
        if (![MCToolbarSemantic(canvas,@"__toolbar.previous")[@"enabled"] boolValue]) break;
        MCToolbarPressVisible(canvas,@"__toolbar.previous",.5);
    }
    for (NSUInteger i=0; i<512; i++) {
        item = MCToolbarSemantic(canvas,identifier);
        if (item) return item;
        if (![MCToolbarSemantic(canvas,@"__toolbar.next")[@"enabled"] boolValue]) break;
        MCToolbarPressVisible(canvas,@"__toolbar.next",.5);
    }
    return nil;
}
static inline void MCToolbarClick(MCSharedCanvasView *canvas, NSString *identifier) {
    NSCAssert(MCToolbarReveal(canvas,identifier) != nil,@"Missing declared toolbar item: %@",identifier);
    MCToolbarPressVisible(canvas,identifier,.5);
}
static inline BOOL MCToolbarEnabled(MCSharedCanvasView *canvas, NSString *identifier) {
    return [MCToolbarReveal(canvas,identifier)[@"enabled"] boolValue];
}
static inline BOOL MCToolbarSelected(MCSharedCanvasView *canvas, NSString *identifier) {
    return [MCToolbarReveal(canvas,identifier)[@"value"] boolValue];
}
static inline NSString *MCToolbarToolID(NSInteger kind) {
    if (kind == 100) return @"builtin.image.pin";
    NSCAssert(kind >= 0 && kind <= 4,@"Invalid fixture tool kind");
    return @[@"host.select",@"builtin.image.rectangle",@"builtin.image.arrow",@"builtin.image.text",@"builtin.image.cover"][kind];
}
static inline NSInteger MCToolbarPosition(MCSharedCanvasView *canvas, NSString *identifier) {
    NSUInteger index = 0;
    for (NSDictionary *item in canvas.frameDescription[@"semantics"]) {
        if ([item[@"id"] isEqual:identifier]) return (NSInteger)index;
        index++;
    }
    return -1;
}
static inline BOOL MCToolbarAXPress(MCSharedCanvasView *canvas, NSString *identifier) {
    if (!MCToolbarReveal(canvas,identifier)) return NO;
    for (id<NSAccessibility> element in canvas.accessibilityChildren)
        if ([[element accessibilityIdentifier] isEqual:identifier]) return [(id)element accessibilityPerformPress];
    return NO;
}
#endif
