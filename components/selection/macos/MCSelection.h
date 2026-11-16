#import <Foundation/Foundation.h>

// Content geometry only: image pixels or display points. The host owns drawing, focus and
// event routing; a gesture owns no views, callbacks or system resources.
typedef NS_ENUM(NSInteger, MCSelectionOperation) {
    MCSelectionNone = -3,
    MCSelectionMove = -2,
    MCSelectionCreate = -1,
    // Resize handles 0..7 run clockwise from the top-left in flipped coordinates.
};

typedef struct {
    BOOL active;
    NSInteger operation;
    NSPoint anchor;
    NSRect original;
    NSRect preview;
    NSSize bounds;
} MCSelectionGesture;

NSPoint MCSelectionHandlePoint(NSInteger handle, NSRect rect);
NSInteger MCSelectionHandleAtPoint(NSPoint point, NSRect rect, CGFloat radius);
BOOL MCSelectionBorderContains(NSPoint point, NSRect rect, CGFloat radius);
// Hit radii are view points, independent of image scale. Returns None for the
// interior so the editor can route that click to annotation tools instead.
NSInteger MCSelectionHitTest(BOOL hasSelection, NSRect imageRect, NSRect viewRect,
                            NSPoint imagePoint, NSPoint viewPoint);
BOOL MCSelectionBegin(MCSelectionGesture *gesture, NSInteger operation,
                      NSPoint point, NSRect selection, NSSize imageSize);
void MCSelectionUpdate(MCSelectionGesture *gesture, NSPoint point);
// Finish ends the gesture even when a too-small new region is rejected.
BOOL MCSelectionFinish(MCSelectionGesture *gesture, NSPoint point, NSRect *selection);
void MCSelectionCancel(MCSelectionGesture *gesture);
