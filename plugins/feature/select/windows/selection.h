#ifndef MOOJICUT_WINDOWS_SELECTION_H
#define MOOJICUT_WINDOWS_SELECTION_H
#include <windows.h>

/* Image-pixel geometry only. The host owns capture, windows, painting and the
 * transition into editing; this module neither acquires pixels nor edits them. */
typedef struct {
  RECT bounds;
  POINT anchor, current;
  int minimum_size;
  BOOL dragging;
} MCSelection;
typedef enum {
  MC_SELECTION_BEGIN, MC_SELECTION_MOVE, MC_SELECTION_END,
  MC_SELECTION_CANCEL, MC_SELECTION_LOST_CAPTURE
} MCSelectionEvent;
typedef enum {
  MC_SELECTION_NONE, MC_SELECTION_CHANGED, MC_SELECTION_COMMITTED, MC_SELECTION_CANCELLED
} MCSelectionStatus;
typedef struct { MCSelectionStatus status; RECT rect; } MCSelectionResult;

void mc_selection_init(MCSelection *selection, RECT bounds, int minimum_size);
MCSelectionResult mc_selection_update(MCSelection *selection, MCSelectionEvent event, POINT point);
RECT mc_selection_rect(const MCSelection *selection);
RECT mc_selection_normalize(POINT first, POINT second);
int mc_selection_hit_handle(RECT rect, POINT point, int radius);
RECT mc_selection_transform(RECT rect, POINT from, POINT to, int handle, RECT bounds, int minimum_size);
BOOL mc_selection_smoke(void);
#endif
