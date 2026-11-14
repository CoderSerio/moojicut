#include "selection.h"
#include <math.h>

static double clamp(double value, double low, double high) {
  return value > high ? high : value < low ? low : value;
}
MCSelectionPoint mc_selection_from_surface(MCSelectionPoint point, MCSelectionViewport viewport) {
  if (!isfinite(viewport.zoom) || viewport.zoom <= 0)
    return (MCSelectionPoint){0, 0};
  return (MCSelectionPoint){clamp(floor((point.x - viewport.offset_x) / viewport.zoom), 0, viewport.image_width),
                             clamp(floor((point.y - viewport.offset_y) / viewport.zoom), 0, viewport.image_height)};
}
bool mc_selection_contains(MCSelectionRect rect, MCSelectionPoint point) {
  double left = fmin(rect.x, rect.x + rect.width), top = fmin(rect.y, rect.y + rect.height);
  return point.x >= left && point.x <= left + fabs(rect.width) &&
         point.y >= top && point.y <= top + fabs(rect.height);
}
int mc_selection_handle_at(MCSelectionRect rect, MCSelectionPoint point, double zoom) {
  if (!isfinite(zoom) || zoom <= 0)
    return -1;
  static const double xs[] = {0, .5, 1, 1, 1, .5, 0, 0}, ys[] = {0, 0, 0, .5, 1, 1, 1, .5};
  for (int i = 0; i < 8; i++)
    if (fabs(point.x - rect.x - rect.width * xs[i]) <= 7 / zoom &&
        fabs(point.y - rect.y - rect.height * ys[i]) <= 7 / zoom)
      return i;
  return -1;
}
void mc_selection_begin(MCSelectionDrag *drag, MCSelectionPoint anchor,
                         MCSelectionRect original, int handle) {
  *drag = (MCSelectionDrag){anchor, anchor, original, handle};
}
void mc_selection_update(MCSelectionDrag *drag, MCSelectionPoint current) { drag->current = current; }
MCSelectionRect mc_selection_vector(const MCSelectionDrag *drag) {
  return (MCSelectionRect){drag->anchor.x, drag->anchor.y,
                            drag->current.x - drag->anchor.x, drag->current.y - drag->anchor.y};
}
MCSelectionRect mc_selection_region(const MCSelectionDrag *drag) {
  return (MCSelectionRect){fmin(drag->anchor.x, drag->current.x), fmin(drag->anchor.y, drag->current.y),
                            fabs(drag->current.x - drag->anchor.x), fabs(drag->current.y - drag->anchor.y)};
}
MCSelectionRect mc_selection_transform(const MCSelectionDrag *drag,
                                       double image_width, double image_height, double minimum_edge) {
  MCSelectionRect r = drag->original;
  double dx = drag->current.x - drag->anchor.x, dy = drag->current.y - drag->anchor.y;
  if (drag->handle < 0) {
    r.x = clamp(r.x + dx, fmax(0, -r.width), image_width - fmax(0, r.width));
    r.y = clamp(r.y + dy, fmax(0, -r.height), image_height - fmax(0, r.height));
  } else {
    int h = drag->handle;
    double left = r.x, top = r.y, right = r.x + r.width, bottom = r.y + r.height;
    if (h == 0 || h == 6 || h == 7)
      left = clamp(left + dx, 0, right - minimum_edge);
    if (h == 2 || h == 3 || h == 4)
      right = clamp(right + dx, left + minimum_edge, image_width);
    if (h <= 2)
      top = clamp(top + dy, 0, bottom - minimum_edge);
    if (h >= 4 && h <= 6)
      bottom = clamp(bottom + dy, top + minimum_edge, image_height);
    r = (MCSelectionRect){left, top, right - left, bottom - top};
  }
  return r;
}

/* Real geometry cases used by the existing native --smoke suite. */
bool mc_selection_smoke(void) {
  MCSelectionViewport viewport = {20, 30, 2, 640, 400};
  MCSelectionPoint p = mc_selection_from_surface((MCSelectionPoint){85, 109}, viewport);
  if (p.x != 32 || p.y != 39)
    return false;
  p = mc_selection_from_surface((MCSelectionPoint){-100, 2000}, viewport);
  if (p.x != 0 || p.y != 400)
    return false;
  MCSelectionDrag drag;
  mc_selection_begin(&drag, (MCSelectionPoint){350, 250}, (MCSelectionRect){0}, -1);
  mc_selection_update(&drag, (MCSelectionPoint){30, 50});
  MCSelectionRect r = mc_selection_region(&drag);
  if (r.x != 30 || r.y != 50 || r.width != 320 || r.height != 200)
    return false;
  MCSelectionRect vector = mc_selection_vector(&drag);
  if (vector.width != -320 || vector.height != -200 ||
      !mc_selection_contains(vector, (MCSelectionPoint){200, 100}))
    return false;
  mc_selection_begin(&drag, (MCSelectionPoint){200, 100}, vector, -1);
  mc_selection_update(&drag, (MCSelectionPoint){-200, -200});
  r = mc_selection_transform(&drag, 640, 400, 8);
  if (r.x != 320 || r.y != 200 || r.width != -320 || r.height != -200)
    return false;
  MCSelectionRect original = {30, 50, 320, 200};
  static const double xs[] = {30, 190, 350, 350, 350, 190, 30, 30};
  static const double ys[] = {50, 50, 50, 150, 250, 250, 250, 150};
  for (int h = 0; h < 8; h++)
    if (mc_selection_handle_at(original, (MCSelectionPoint){xs[h], ys[h]}, 2) != h)
      return false;
  if (mc_selection_handle_at(original, (MCSelectionPoint){34, 50}, 2) != -1)
    return false;
  mc_selection_begin(&drag, (MCSelectionPoint){30, 50}, original, 0);
  mc_selection_update(&drag, (MCSelectionPoint){500, 500});
  r = mc_selection_transform(&drag, 640, 400, 8);
  if (r.x != 342 || r.y != 242 || r.width != 8 || r.height != 8)
    return false;
  mc_selection_begin(&drag, (MCSelectionPoint){350, 250}, original, 4);
  mc_selection_update(&drag, (MCSelectionPoint){900, 900});
  r = mc_selection_transform(&drag, 640, 400, 8);
  return r.x == 30 && r.y == 50 && r.width == 610 && r.height == 350;
}
