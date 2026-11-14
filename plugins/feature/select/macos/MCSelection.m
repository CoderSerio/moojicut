#import "MCSelection.h"
#include <math.h>
#include "../../../../native/shared/selection.h"

static MCCoreRect CoreRect(NSRect rect) {
    return (MCCoreRect){rect.origin.x, rect.origin.y, rect.size.width, rect.size.height};
}
static MCCorePoint CorePoint(NSPoint point) { return (MCCorePoint){point.x, point.y}; }
static NSRect NativeRect(MCCoreRect rect) { return NSMakeRect(rect.x, rect.y, rect.width, rect.height); }

NSPoint MCSelectionHandlePoint(NSInteger handle, NSRect rect) {
    if (handle < 0 || handle >= 8) return NSZeroPoint;
    MCCorePoint point = mc_core_handle_point(CoreRect(rect), (int32_t)handle, MC_SELECTION_MIDPOINT_EXACT);
    return NSMakePoint(point.x, point.y);
}
NSInteger MCSelectionHandleAtPoint(NSPoint point, NSRect rect, CGFloat radius) {
    return mc_core_hit_handle(CoreRect(rect), CorePoint(point), radius,
                             MC_SELECTION_MIDPOINT_EXACT);
}
BOOL MCSelectionBorderContains(NSPoint point, NSRect rect, CGFloat radius) {
    return mc_core_border_contains(CoreRect(rect), CorePoint(point), radius) != 0;
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
    MCCoreRect preview;
    if (gesture->operation == MCSelectionCreate) {
        preview = mc_core_region(CorePoint(gesture->anchor), CorePoint(point));
    } else {
        preview = mc_core_transform(CoreRect(gesture->original), CorePoint(gesture->anchor),
            CorePoint(point), (int32_t)gesture->operation,
            (MCCoreRect){0, 0, gesture->bounds.width, gesture->bounds.height},
            2);
    }
    gesture->preview = NativeRect(preview);
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
