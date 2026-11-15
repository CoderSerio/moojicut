#include "selection.h"
#include "../../../../native/shared/selection.h"
#include <math.h>

static double clamp(double value, double low, double high) {
  return value > high ? high : value < low ? low : value;
}
static MCCorePoint core_point(MCSelectionPoint point) { return (MCCorePoint){point.x, point.y}; }
static MCCoreRect core_rect(MCSelectionRect rect) {
  return (MCCoreRect){rect.x, rect.y, rect.width, rect.height};
}
static MCSelectionRect native_rect(MCCoreRect rect) {
  return (MCSelectionRect){rect.x, rect.y, rect.width, rect.height};
}
MCSelectionPoint mc_selection_from_surface(MCSelectionPoint point, MCSelectionViewport viewport) {
  if (!isfinite(viewport.zoom) || viewport.zoom <= 0)
    return (MCSelectionPoint){0, 0};
  return (MCSelectionPoint){clamp(floor((point.x - viewport.offset_x) / viewport.zoom), 0, viewport.image_width),
                             clamp(floor((point.y - viewport.offset_y) / viewport.zoom), 0, viewport.image_height)};
}
bool mc_selection_contains(MCSelectionRect rect, MCSelectionPoint point) {
  return mc_core_contains(core_rect(rect), core_point(point));
}
int mc_selection_handle_at(MCSelectionRect rect, MCSelectionPoint point, double zoom) {
  if (!isfinite(zoom) || zoom <= 0)
    return -1;
  return mc_core_hit_handle(core_rect(rect), core_point(point), 6 / zoom,
                            MC_SELECTION_MIDPOINT_EXACT);
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
  return native_rect(mc_core_region(core_point(drag->anchor), core_point(drag->current)));
}
MCSelectionRect mc_selection_transform(const MCSelectionDrag *drag,
                                       double image_width, double image_height, double minimum_edge) {
  MCCoreRect bounds = {0, 0, image_width, image_height};
  return native_rect(mc_core_transform_directed(core_rect(drag->original), core_point(drag->anchor),
                                        core_point(drag->current), drag->handle, bounds,
                                        minimum_edge));
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
  if (mc_selection_handle_at(original, (MCSelectionPoint){27, 50}, 2) != 0 ||
      mc_selection_handle_at(original, (MCSelectionPoint){33, 50}, 2) != -1)
    return false;
  mc_selection_begin(&drag, (MCSelectionPoint){30, 50}, original, 0);
  mc_selection_update(&drag, (MCSelectionPoint){500, 500});
  r = mc_selection_transform(&drag, 640, 400, 8);
  if (r.x != 342 || r.y != 242 || r.width != 8 || r.height != 8)
    return false;
  mc_selection_begin(&drag, (MCSelectionPoint){350, 250}, original, 4);
  mc_selection_update(&drag, (MCSelectionPoint){900, 900});
  r = mc_selection_transform(&drag, 640, 400, 8);
  if (r.x != 30 || r.y != 50 || r.width != 610 || r.height != 350)
    return false;
  // Small annotations can be smaller than the eight-pixel resize minimum.
  // Both drag directions follow macOS's leading-edge clamp for an inverted interval.
  mc_selection_begin(&drag, (MCSelectionPoint){0, 0}, (MCSelectionRect){0, 0, 2, 2}, 0);
  mc_selection_update(&drag, (MCSelectionPoint){1, 1});
  r = mc_selection_transform(&drag, 640, 400, 8);
  if (r.x != -6 || r.y != -6 || r.width != 8 || r.height != 8)
    return false;
  mc_selection_update(&drag, (MCSelectionPoint){-10, -10});
  r = mc_selection_transform(&drag, 640, 400, 8);
  return r.x == -6 && r.y == -6 && r.width == 8 && r.height == 8;
}
