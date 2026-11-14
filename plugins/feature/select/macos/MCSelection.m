#import "MCSelection.h"
#include <math.h>

NSPoint MCSelectionHandlePoint(NSInteger handle, NSRect rect) {
    static const CGFloat xs[] = {0, .5, 1, 1, 1, .5, 0, 0};
    static const CGFloat ys[] = {0, 0, 0, .5, 1, 1, 1, .5};
    if (handle < 0 || handle >= 8) return NSZeroPoint;
    return NSMakePoint(rect.origin.x + xs[handle] * rect.size.width,
                      rect.origin.y + ys[handle] * rect.size.height);
}
NSInteger MCSelectionHandleAtPoint(NSPoint point, NSRect rect, CGFloat radius) {
    for (NSInteger handle = 0; handle < 8; handle++) {
        NSPoint center = MCSelectionHandlePoint(handle, rect);
        if (NSPointInRect(point, NSMakeRect(center.x - radius, center.y - radius,
                                          radius * 2, radius * 2))) return handle;
    }
    return -1;
}
BOOL MCSelectionBorderContains(NSPoint point, NSRect rect, CGFloat radius) {
    return NSPointInRect(point, NSInsetRect(rect, -radius, -radius)) &&
           !NSPointInRect(point, NSInsetRect(rect, radius, radius));
}
NSInteger MCSelectionHitTest(BOOL hasSelection, NSRect imageRect, NSRect viewRect,
                            NSPoint imagePoint, NSPoint viewPoint) {
    if (!hasSelection) return MCSelectionCreate;
    NSInteger handle = MCSelectionHandleAtPoint(viewPoint, viewRect, 6);
    if (handle >= 0) return handle;
    if (MCSelectionBorderContains(viewPoint, viewRect, 5)) return MCSelectionMove;
    return NSPointInRect(imagePoint, imageRect) ? MCSelectionNone : MCSelectionCreate;
}
BOOL MCSelectionBegin(MCSelectionGesture *gesture, NSInteger operation,
                      NSPoint point, NSRect selection, NSSize imageSize) {
    if (!gesture || operation < MCSelectionMove || operation > 7 ||
        !isfinite(point.x) || !isfinite(point.y) || !isfinite(imageSize.width) ||
        !isfinite(imageSize.height) || imageSize.width <= 0 || imageSize.height <= 0) return NO;
    point.x = MAX(0, MIN(imageSize.width, point.x));
    point.y = MAX(0, MIN(imageSize.height, point.y));
    *gesture = (MCSelectionGesture){YES, operation, point, selection,
        operation == MCSelectionCreate ? NSMakeRect(point.x, point.y, 0, 0) : selection, imageSize};
    return YES;
}
void MCSelectionUpdate(MCSelectionGesture *gesture, NSPoint point) {
    if (!gesture || !gesture->active || !isfinite(point.x) || !isfinite(point.y)) return;
    point.x = MAX(0, MIN(gesture->bounds.width, point.x));
    point.y = MAX(0, MIN(gesture->bounds.height, point.y));
    CGFloat dx = point.x - gesture->anchor.x, dy = point.y - gesture->anchor.y;
    NSRect rect = gesture->original;
    if (gesture->operation == MCSelectionCreate) {
        rect = NSMakeRect(MIN(gesture->anchor.x, point.x), MIN(gesture->anchor.y, point.y), fabs(dx), fabs(dy));
    } else if (gesture->operation == MCSelectionMove) {
        rect.origin.x = MAX(0, MIN(gesture->bounds.width - rect.size.width, rect.origin.x + dx));
        rect.origin.y = MAX(0, MIN(gesture->bounds.height - rect.size.height, rect.origin.y + dy));
    } else {
        CGFloat left = NSMinX(rect), right = NSMaxX(rect), top = NSMinY(rect), bottom = NSMaxY(rect);
        NSInteger handle = gesture->operation;
        if (handle == 0 || handle == 6 || handle == 7) left = MIN(right - 2, MAX(0, left + dx));
        if (handle == 2 || handle == 3 || handle == 4) right = MAX(left + 2, MIN(gesture->bounds.width, right + dx));
        if (handle == 0 || handle == 1 || handle == 2) top = MIN(bottom - 2, MAX(0, top + dy));
        if (handle == 4 || handle == 5 || handle == 6) bottom = MAX(top + 2, MIN(gesture->bounds.height, bottom + dy));
        rect = NSMakeRect(left, top, right - left, bottom - top);
    }
    gesture->preview = rect;
}
BOOL MCSelectionFinish(MCSelectionGesture *gesture, NSPoint point, NSRect *selection) {
    if (!gesture || !gesture->active) return NO;
    MCSelectionUpdate(gesture, point);
    gesture->active = NO;
    if (gesture->preview.size.width < 2 || gesture->preview.size.height < 2) return NO;
    if (selection) *selection = gesture->preview;
    return YES;
}
void MCSelectionCancel(MCSelectionGesture *gesture) {
    if (gesture) *gesture = (MCSelectionGesture){0};
}
