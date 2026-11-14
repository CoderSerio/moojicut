#ifndef MOOJICUT_LINUX_SELECTION_H
#define MOOJICUT_LINUX_SELECTION_H

#include <stdbool.h>

/* Image-space geometry only. GTK event ownership, document commits and text
 * measurement remain with the editor; no feature or toolkit handles cross here. */
typedef struct { double x, y; } MCSelectionPoint;
typedef struct { double x, y, width, height; } MCSelectionRect;
typedef struct {
  double offset_x, offset_y, zoom, image_width, image_height;
} MCSelectionViewport;
typedef struct {
  MCSelectionPoint anchor, current;
  MCSelectionRect original;
  int handle; /* -1 = move; 0..7 = clockwise handles starting at top left. */
} MCSelectionDrag;

MCSelectionPoint mc_selection_from_surface(MCSelectionPoint point, MCSelectionViewport viewport);
bool mc_selection_contains(MCSelectionRect rect, MCSelectionPoint point);
int mc_selection_handle_at(MCSelectionRect rect, MCSelectionPoint point, double zoom);
void mc_selection_begin(MCSelectionDrag *drag, MCSelectionPoint anchor,
                         MCSelectionRect original, int handle);
void mc_selection_update(MCSelectionDrag *drag, MCSelectionPoint current);
MCSelectionRect mc_selection_region(const MCSelectionDrag *drag);
MCSelectionRect mc_selection_vector(const MCSelectionDrag *drag);
MCSelectionRect mc_selection_transform(const MCSelectionDrag *drag,
                                       double image_width, double image_height, double minimum_edge);
bool mc_selection_smoke(void);

#endif
