#define WIN32_LEAN_AND_MEAN
#include "selection.h"
#include <stdio.h>
#include <stdlib.h>

static int lower(int a, int b) { return a < b ? a : b; }
static int upper(int a, int b) { return a > b ? a : b; }
static int bound(int value, int low, int high) { return upper(low, lower(value, high)); }
RECT mc_selection_normalize(POINT first, POINT second) {
  RECT rect = {lower(first.x, second.x), lower(first.y, second.y),
               upper(first.x, second.x), upper(first.y, second.y)};
  return rect;
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
  POINT points[8] = {{rect.left, rect.top}, {(rect.left + rect.right) / 2, rect.top},
      {rect.right, rect.top}, {rect.right, (rect.top + rect.bottom) / 2},
      {rect.right, rect.bottom}, {(rect.left + rect.right) / 2, rect.bottom},
      {rect.left, rect.bottom}, {rect.left, (rect.top + rect.bottom) / 2}};
  for (int i = 0; i < 8; i++)
    if (abs(point.x - points[i].x) <= radius && abs(point.y - points[i].y) <= radius)
      return i;
  return -1;
}
RECT mc_selection_transform(RECT rect, POINT from, POINT to, int handle, RECT bounds, int minimum_size) {
  int dx = to.x - from.x, dy = to.y - from.y;
  if (handle < 0) {
    int width = rect.right - rect.left, height = rect.bottom - rect.top;
    rect.left = bound(rect.left + dx, bounds.left, bounds.right - width);
    rect.top = bound(rect.top + dy, bounds.top, bounds.bottom - height);
    rect.right = rect.left + width;
    rect.bottom = rect.top + height;
    return rect;
  }
  if (handle == 0 || handle == 6 || handle == 7)
    rect.left = bound(rect.left + dx, bounds.left, rect.right - minimum_size);
  if (handle == 2 || handle == 3 || handle == 4)
    rect.right = bound(rect.right + dx, rect.left + minimum_size, bounds.right);
  if (handle == 0 || handle == 1 || handle == 2)
    rect.top = bound(rect.top + dy, bounds.top, rect.bottom - minimum_size);
  if (handle == 4 || handle == 5 || handle == 6)
    rect.bottom = bound(rect.bottom + dy, rect.top + minimum_size, bounds.bottom);
  return rect;
}
BOOL mc_selection_smoke(void) {
  MCSelection first, second;
  mc_selection_init(&first, (RECT){0, 0, 640, 480}, 8);
  mc_selection_init(&second, (RECT){20, 30, 100, 120}, 8);
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
  if (mc_selection_update(&first, MC_SELECTION_END, (POINT){104, 105}).status == MC_SELECTION_COMMITTED)
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
  RECT moved = mc_selection_transform(rect, (POINT){0, 0}, (POINT){100, 100}, -1, second.bounds, 8);
  if (moved.left != 50 || moved.top != 70 || moved.right != 100 || moved.bottom != 120)
    return FALSE;
  RECT resized = mc_selection_transform(rect, (POINT){0, 0}, (POINT){100, 100}, 0, second.bounds, 8);
  if (resized.left != 72 || resized.top != 82 || resized.right != 80 || resized.bottom != 90)
    return FALSE;
  puts("Windows selection smoke: passed (independent gestures, bounds, reverse selection, cancellation, resize).");
  return TRUE;
}
