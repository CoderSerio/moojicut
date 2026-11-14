#import "plugins/feature/select/macos/MCSelection.h"
#include <math.h>
#include <stdio.h>

#define CHECK(condition, message) do { if (!(condition)) { \
    fprintf(stderr, "FAIL selection: %s\n", message); passed = NO; } } while (0)

int main(void) {
    @autoreleasepool {
        BOOL passed = YES;
        NSSize bounds = NSMakeSize(320, 200);
        MCSelectionGesture first = {0}, second = {0};
        NSRect result = NSZeroRect;
        CHECK(MCSelectionBegin(&first, MCSelectionCreate, NSMakePoint(250, 160), NSZeroRect, bounds),
              "a new selection starts without a window or document");
        MCSelectionUpdate(&first, NSMakePoint(40, 30));
        CHECK(NSEqualRects(first.preview, NSMakeRect(40, 30, 210, 130)),
              "reverse dragging normalizes the preview in image pixels");
        CHECK(MCSelectionFinish(&first, NSMakePoint(-50, 240), &result) &&
              NSEqualRects(result, NSMakeRect(0, 160, 250, 40)) && !first.active,
              "finishing uses the final clamped pointer and ends the gesture");

        NSRect original = NSMakeRect(40, 30, 80, 60);
        CHECK(MCSelectionBegin(&first, MCSelectionMove, NSMakePoint(70, 30), original, bounds),
              "a border drag moves an existing region");
        MCSelectionUpdate(&first, NSMakePoint(310, 195));
        CHECK(NSEqualRects(first.preview, NSMakeRect(240, 140, 80, 60)),
              "moving at image edges preserves the selection dimensions");
        MCSelectionBegin(&second, MCSelectionCreate, NSMakePoint(10, 10), NSZeroRect, bounds);
        MCSelectionUpdate(&second, NSMakePoint(50, 50));
        MCSelectionCancel(&first);
        CHECK(!first.active && second.active && NSEqualRects(second.preview, NSMakeRect(10, 10, 40, 40)),
              "cancelling one canvas gesture does not affect another");
        CHECK(!MCSelectionFinish(&first, NSZeroPoint, &result), "a cancelled gesture cannot commit");

        const NSRect expected[] = {
            {{50, 35}, {70, 55}}, {{40, 35}, {80, 55}}, {{40, 35}, {90, 55}}, {{40, 30}, {90, 60}},
            {{40, 30}, {90, 65}}, {{40, 30}, {80, 65}}, {{50, 30}, {70, 65}}, {{50, 30}, {70, 60}}
        };
        for (NSInteger handle = 0; handle < 8; handle++) {
            NSPoint anchor = MCSelectionHandlePoint(handle, original);
            MCSelectionBegin(&first, handle, anchor, original, bounds);
            CHECK(MCSelectionFinish(&first, NSMakePoint(anchor.x + 10, anchor.y + 5), &result) &&
                  NSEqualRects(result, expected[handle]), "each resize handle changes only its own edges");
        }
        MCSelectionBegin(&first, 0, original.origin, original, bounds);
        MCSelectionFinish(&first, NSMakePoint(300, 190), &result);
        CHECK(NSEqualRects(result, NSMakeRect(118, 88, 2, 2)), "resize handles retain the minimum two-pixel region");
        MCSelectionBegin(&first, MCSelectionCreate, NSMakePoint(10, 10), NSZeroRect, bounds);
        result = original;
        CHECK(!MCSelectionFinish(&first, NSMakePoint(11, 10), &result) && !first.active && NSEqualRects(result, original),
              "a tiny fresh selection is rejected without replacing the committed region");

        NSRect pixels = NSMakeRect(100, 60, 400, 300), view = NSMakeRect(50, 30, 200, 150);
        CHECK(MCSelectionHitTest(YES, pixels, view, NSMakePoint(92, 52), NSMakePoint(46, 26)) == 0,
              "handle hit testing keeps a view-point radius on scaled canvases");
        CHECK(MCSelectionHitTest(YES, pixels, view, NSMakePoint(170, 60), NSMakePoint(85, 30)) == MCSelectionMove,
              "the border routes to moving while avoiding the resize handles");
        CHECK(MCSelectionHitTest(YES, pixels, view, NSMakePoint(200, 200), NSMakePoint(100, 100)) == MCSelectionNone,
              "the interior remains available to annotation tools");
        CHECK(MCSelectionHitTest(YES, pixels, view, NSMakePoint(20, 20), NSMakePoint(10, 10)) == MCSelectionCreate &&
              MCSelectionHitTest(NO, pixels, view, NSMakePoint(200, 200), NSMakePoint(100, 100)) == MCSelectionCreate,
              "outside clicks and a missing selection begin a fresh region");
        CHECK(!MCSelectionBegin(&first, MCSelectionNone, NSZeroPoint, NSZeroRect, bounds) &&
              !MCSelectionBegin(&first, MCSelectionCreate, NSMakePoint(NAN, 0), NSZeroRect, bounds),
              "non-gesture operations and nonfinite pointer coordinates are rejected");
        puts(passed ? "PASS selection: independent value state, hit routing, movement, eight handles and cancellation"
                    : "FAIL selection");
        return passed ? 0 : 1;
    }
}
