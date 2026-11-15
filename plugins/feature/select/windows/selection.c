#define WIN32_LEAN_AND_MEAN
#include "selection.h"
#include "../../../../native/shared/selection.h"
#include <stdio.h>

static int lower(int a, int b) { return a < b ? a : b; }
static int upper(int a, int b) { return a > b ? a : b; }
static int bound(int value, int low, int high) { return upper(low, lower(value, high)); }
static MCCorePoint core_point(POINT point) { return (MCCorePoint){point.x, point.y}; }
static MCCoreRect core_rect(RECT rect) {
  return (MCCoreRect){rect.left, rect.top, (double)rect.right - rect.left, (double)rect.bottom - rect.top};
}
static RECT native_rect(MCCoreRect rect) {
  return (RECT){(LONG)rect.x, (LONG)rect.y, (LONG)(rect.x + rect.width), (LONG)(rect.y + rect.height)};
}
RECT mc_selection_normalize(POINT first, POINT second) {
  return native_rect(mc_core_region(core_point(first), core_point(second)));
}
void mc_selection_init(MCSelection *selection, RECT bounds, int minimum_size) {
  *selection = (MCSelection){0};
  selection->bounds = bounds;
  selection->minimum_size = upper(1, minimum_size);
  selection->anchor = selection->current = (POINT){bounds.left, bounds.top};
}
RECT mc_selection_rect(const MCSelection *selection) {
  return mc_selection_normalize(selection->anchor, selection->current);
}
MCSelectionResult mc_selection_update(MCSelection *selection, MCSelectionEvent event, POINT point) {
  MCSelectionResult result = {MC_SELECTION_NONE, mc_selection_rect(selection)};
  point.x = bound(point.x, selection->bounds.left, selection->bounds.right);
  point.y = bound(point.y, selection->bounds.top, selection->bounds.bottom);
  if (event == MC_SELECTION_BEGIN) {
    selection->anchor = selection->current = point;
    selection->dragging = TRUE;
    result.status = MC_SELECTION_CHANGED;
  } else if (selection->dragging && (event == MC_SELECTION_MOVE || event == MC_SELECTION_END)) {
    selection->current = point;
    result.status = MC_SELECTION_CHANGED;
    if (event == MC_SELECTION_END) {
      selection->dragging = FALSE;
      RECT rect = mc_selection_rect(selection);
      if (rect.right - rect.left >= selection->minimum_size &&
          rect.bottom - rect.top >= selection->minimum_size)
        result.status = MC_SELECTION_COMMITTED;
    }
  } else if (event == MC_SELECTION_CANCEL || event == MC_SELECTION_LOST_CAPTURE) {
    if (selection->dragging || event == MC_SELECTION_CANCEL)
      result.status = MC_SELECTION_CANCELLED;
    selection->dragging = FALSE;
  }
  result.rect = mc_selection_rect(selection);
  return result;
}
int mc_selection_hit_handle(RECT rect, POINT point, int radius) {
  return mc_core_hit_handle(core_rect(rect), core_point(point), radius,
                            MC_SELECTION_MIDPOINT_INTEGER);
}
RECT mc_selection_transform(RECT rect, POINT from, POINT to, int handle, RECT bounds, int minimum_size) {
  return native_rect(mc_core_transform(core_rect(rect), core_point(from), core_point(to), handle,
                                        core_rect(bounds), minimum_size));
}
BOOL mc_selection_smoke(void) {
  MCSelection first, second;
  mc_selection_init(&first, (RECT){0, 0, 640, 480}, 2);
  mc_selection_init(&second, (RECT){20, 30, 100, 120}, 2);
  mc_selection_update(&first, MC_SELECTION_BEGIN, (POINT){330, 220});
  mc_selection_update(&second, MC_SELECTION_BEGIN, (POINT){-20, -30});
  MCSelectionResult result = mc_selection_update(&first, MC_SELECTION_END, (POINT){10, 20});
  if (result.status != MC_SELECTION_COMMITTED || result.rect.left != 10 || result.rect.top != 20 ||
      result.rect.right != 330 || result.rect.bottom != 220 || !second.dragging || first.dragging)
    return FALSE;
  result = mc_selection_update(&second, MC_SELECTION_END, (POINT){200, 220});
  if (result.status != MC_SELECTION_COMMITTED || !EqualRect(&result.rect, &second.bounds))
    return FALSE;
  if (mc_selection_update(&first, MC_SELECTION_END, (POINT){600, 450}).status != MC_SELECTION_NONE)
    return FALSE;
  mc_selection_update(&first, MC_SELECTION_BEGIN, (POINT){100, 100});
  if (mc_selection_update(&first, MC_SELECTION_END, (POINT){101, 101}).status == MC_SELECTION_COMMITTED)
    return FALSE;
  mc_selection_update(&first, MC_SELECTION_BEGIN, (POINT){100, 100});
  if (mc_selection_update(&first, MC_SELECTION_END, (POINT){102, 102}).status != MC_SELECTION_COMMITTED)
    return FALSE;
  mc_selection_update(&first, MC_SELECTION_BEGIN, (POINT){100, 100});
  if (mc_selection_update(&first, MC_SELECTION_CANCEL, (POINT){0, 0}).status != MC_SELECTION_CANCELLED ||
      mc_selection_update(&first, MC_SELECTION_END, (POINT){300, 300}).status != MC_SELECTION_NONE)
    return FALSE;
  mc_selection_update(&first, MC_SELECTION_BEGIN, (POINT){100, 100});
  mc_selection_update(&first, MC_SELECTION_LOST_CAPTURE, (POINT){0, 0});
  if (mc_selection_update(&first, MC_SELECTION_END, (POINT){300, 300}).status != MC_SELECTION_NONE)
    return FALSE;
  RECT rect = {30, 40, 80, 90};
  if (mc_selection_hit_handle(rect, (POINT){80, 90}, 7) != 4 ||
      mc_selection_hit_handle(rect, (POINT){60, 60}, 7) != -1)
    return FALSE;
  // Keep native integer midpoints while matching macOS's half-open hit edges.
  RECT odd = {30, 40, 81, 91};
  if (mc_selection_hit_handle(odd, (POINT){54, 40}, 1) != 1 ||
      mc_selection_hit_handle(odd, (POINT){75, 85}, 6) != 4 ||
      mc_selection_hit_handle(odd, (POINT){87, 91}, 6) != -1 ||
      mc_selection_hit_handle(odd, (POINT){81, 97}, 6) != -1)
    return FALSE;
  RECT moved = mc_selection_transform(rect, (POINT){0, 0}, (POINT){100, 100}, -1, second.bounds, 8);
  if (moved.left != 50 || moved.top != 70 || moved.right != 100 || moved.bottom != 120)
    return FALSE;
  RECT resized = mc_selection_transform(rect, (POINT){0, 0}, (POINT){100, 100}, 0, second.bounds, 8);
  if (resized.left != 72 || resized.top != 82 || resized.right != 80 || resized.bottom != 90)
    return FALSE;
  puts("Windows selection smoke: passed (independent gestures, bounds, reverse selection, cancellation, resize).");
  return TRUE;
}
